"""
Migrates Services (Reserves, TransmissionInterfaces, AGC) to `region_sys` for surviving devices.
Audits contributing device memberships against `main_sys`:
  - Drops services where `length(kept_devices) / length(orig_devices) < min_service_device_fraction`
    and logs `[DROPPED_SPLIT_SERVICE]`.
  - Retains split services meeting the threshold (updating contributing devices and
    `TransmissionInterface` `direction_mapping` to only in-region components) and logs `[SPLIT_SERVICE]`.
"""
function migrate_regional_services!(
    region_sys::PSY.System,
    main_sys::PSY.System,
    orig_injections::Vector{PSY.StaticInjection},
    orig_branches::Vector{PSY.Branch};
    fallback_bus_ext_reserves::Bool = false,
    min_service_device_fraction::Float64 = 0.0,
)
    (0.0 <= min_service_device_fraction <= 1.0) ||
        ArgumentError("min_service_device_fraction must be between 0.0 and 1.0, got $min_service_device_fraction") |> throw

    srv_to_new_devices = Dict{PSY.Service, Vector{PSY.Device}}()

    for orig_dev in Iterators.flatten((orig_injections, orig_branches))
        !hasproperty(orig_dev, :services) && continue
        dev_type = typeof(orig_dev)
        dev_name = PSY.get_name(orig_dev)
        !PSY.has_component(dev_type, region_sys, dev_name) && continue

        new_dev = PSY.get_component(dev_type, region_sys, dev_name)
        for srv in PSY.get_services(orig_dev)
            srv isa PSY.ConstantReserveGroup && continue
            if hasproperty(srv, :area) && !isnothing(PSY.get_area(srv))
                area_name = PSY.get_name(PSY.get_area(srv))
                !PSY.has_component(PSY.Area, region_sys, area_name) && continue
            end
            push!(get!(srv_to_new_devices, srv, PSY.Device[]), new_dev)
        end
    end

    # Build total contributing device counts in main_sys for candidate services
    candidate_srvs = Set(keys(srv_to_new_devices))
    srv_to_orig_count = Dict{PSY.Service, Int}(s => 0 for s in candidate_srvs)
    if !isempty(candidate_srvs)
        for dev in PSY.get_components(PSY.Device, main_sys)
            !hasproperty(dev, :services) && continue
            for srv in PSY.get_services(dev)
                if srv in candidate_srvs
                    srv_to_orig_count[srv] += 1
                end
            end
        end
    end

    # Optional Fallback: Match unattached Reserves via bus ext["region"]
    if isempty(srv_to_new_devices) && fallback_bus_ext_reserves
        gen_buses = [
            PSY.get_bus(x) for x in PSY.get_components(
                d -> !(d isa PSY.StaticLoad) && !(d isa PSY.StaticInjectionSubsystem) && hasproperty(d, :bus),
                PSY.StaticInjection,
                region_sys,
            )
        ]
        res_regions = unique(filter(r -> r != "None", [get(PSY.get_ext(b), "region", "None") for b in gen_buses]))
        if !isempty(res_regions)
            matched_reserves = collect(
                PSY.get_components(
                    r -> !(r isa PSY.ConstantReserveGroup) && any(occursin(z, PSY.get_name(r)) for z in res_regions),
                    PSY.Reserve,
                    main_sys,
                )
            )
            contri_devs = collect(
                PSY.get_components(
                    x -> !(x isa PSY.StaticLoad) && !(x isa PSY.StaticInjectionSubsystem) && hasproperty(x, :services),
                    PSY.StaticInjection,
                    region_sys,
                )
            )
            for r in matched_reserves
                srv_to_new_devices[r] = contri_devs
                srv_to_orig_count[r] = length(contri_devs)
            end
        end
    end

    migrated_services = Pair{PSY.Service, PSY.Service}[]
    split_logs = String[]
    dropped_logs = String[]

    for (orig_srv, new_devs) in sort!(collect(srv_to_new_devices), by = kv -> PSY.get_name(kv[1]))
        isempty(new_devs) && continue
        unique!(new_devs)

        srv_name = PSY.get_name(orig_srv)
        srv_type = nameof(typeof(orig_srv))
        n_kept = length(new_devs)
        n_orig = max(n_kept, get(srv_to_orig_count, orig_srv, n_kept))
        n_dropped = n_orig - n_kept
        kept_frac = n_kept / n_orig

        if kept_frac < min_service_device_fraction
            push!(
                dropped_logs,
                "  • [SERVICE_TOPOLOGY] [DROPPED_SPLIT_SERVICE] $srv_type '$srv_name' DROPPED: retained $n_kept of $n_orig device(s) " *
                "($(round(kept_frac * 100, digits=1))% < threshold $(round(min_service_device_fraction * 100, digits=1))%; $n_dropped external device(s) excluded).",
            )
            continue
        elseif n_dropped > 0
            extra_info = orig_srv isa PSY.TransmissionInterface ?
                         " (direction_mapping updated to $n_kept in-region branch(es))" : ""
            push!(
                split_logs,
                "  • [SERVICE_TOPOLOGY] [SPLIT_SERVICE] $srv_type '$srv_name' spans boundary: retained $n_kept of $n_orig device(s) " *
                "($(round(kept_frac * 100, digits=1))% >= threshold $(round(min_service_device_fraction * 100, digits=1))%; $n_dropped external device(s) removed)$extra_info.",
            )
        end

        new_srv = clone_service(orig_srv, region_sys, new_devs)
        PSY.add_service!(region_sys, new_srv, new_devs)
        push!(migrated_services, orig_srv => new_srv)
    end

    if !isempty(split_logs)
        @warn "[SERVICE_TOPOLOGY] $(length(split_logs)) boundary-spanning service(s) were trimmed to in-region components:\n" *
              join(split_logs, "\n")
    end

    if !isempty(dropped_logs)
        @warn "[SERVICE_TOPOLOGY] $(length(dropped_logs)) boundary-spanning service(s) were DROPPED due to device retention threshold (min_service_device_fraction=$min_service_device_fraction):\n" *
              join(dropped_logs, "\n")
    end

    return migrated_services
end
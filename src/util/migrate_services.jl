"""
Migrates Services (Reserves, TransmissionInterfaces, AGC) to `region_sys` for surviving devices.
"""
function migrate_regional_services!(
    region_sys::PSY.System,
    main_sys::PSY.System,
    orig_injections::Vector{PSY.StaticInjection},
    orig_branches::Vector{PSY.Branch};
    fallback_bus_ext_reserves::Bool = false,
)
    srv_to_new_devices = Dict{PSY.Service, Vector{PSY.Device}}()

    for orig_dev in vcat(orig_injections, orig_branches)
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
            end
        end
    end

    migrated_services = Pair{PSY.Service, PSY.Service}[]
    for (orig_srv, new_devs) in srv_to_new_devices
        isempty(new_devs) && continue
        unique!(new_devs)
        new_srv = clone_service(orig_srv, region_sys)
        PSY.add_service!(region_sys, new_srv, new_devs)
        push!(migrated_services, orig_srv => new_srv)
    end

    return migrated_services
end
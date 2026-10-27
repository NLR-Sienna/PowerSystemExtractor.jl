"""
Discovers candidate `HydroReservoir`s linked to retained regional injections, pulls in any
cascade/pumped-storage `upstream_reservoirs`, audits all turbine/reservoir memberships,
logs explicit `[HYDRO_TOPOLOGY]` warnings for any split/orphaned memberships, and drops
any `HydroReservoir` that ends up with 0 retained turbines in the region.
"""
function collect_and_audit_hydro_reservoirs(
    main_sys::PSY.System,
    all_region_bus_set::Set{PSY.ACBus},
    region_injections::Vector{PSY.StaticInjection},
)
    all_main_reservoirs = collect(PSY.get_components(PSY.HydroReservoir, main_sys))
    isempty(all_main_reservoirs) && return PSY.HydroReservoir[]

    retained_inj_set = Set(region_injections)
    retained_inj_names = Set(PSY.get_name.(region_injections))

    # Initial candidate selection: any reservoir with a turbine on a regional bus or in ext["plants"]
    candidate_reservoirs = filter(all_main_reservoirs) do res
        for t in vcat(PSY.get_upstream_turbines(res), PSY.get_downstream_turbines(res))
            if (t in retained_inj_set) || (hasproperty(t, :bus) && PSY.get_bus(t) in all_region_bus_set)
                return true
            end
        end
        ext = PSY.get_ext(res)
        # This might not be avialable in future EI.jl System builds
        if haskey(ext, "plants") && (ext["plants"] isa AbstractVector)
            if any(p -> string(p) in retained_inj_names, ext["plants"])
                return true
            end
        end
        return false
    end

    # 2. Pull in any upstream_reservoirs referenced by candidate reservoirs (cascade/pumped-storage chains)
    res_set = Set(candidate_reservoirs)
    added_upstream = true
    while added_upstream
        added_upstream = false
        for res in copy(candidate_reservoirs)
            for up_res in PSY.get_upstream_reservoirs(res)
                if up_res isa PSY.HydroReservoir && !(up_res in res_set)
                    push!(candidate_reservoirs, up_res)
                    push!(res_set, up_res)
                    added_upstream = true
                end
            end
        end
    end

    # Audit every candidate reservoir for split turbines or 0 retained turbines (orphans)
    issues = String[]
    valid_reservoirs = PSY.HydroReservoir[]

    for res in sort(candidate_reservoirs, by = PSY.get_name)
        res_name = PSY.get_name(res)
        up_t = PSY.get_upstream_turbines(res)
        dn_t = PSY.get_downstream_turbines(res)

        kept_up_t = filter(t -> t in retained_inj_set, up_t)
        miss_up_t = filter(t -> !(t in retained_inj_set), up_t)

        kept_dn_t = filter(t -> t in retained_inj_set, dn_t)
        miss_dn_t = filter(t -> !(t in retained_inj_set), dn_t)

        total_kept_turbines = length(kept_up_t) + length(kept_dn_t)

        if total_kept_turbines == 0
            # Orphaned reservoir: 0 retained upstream or downstream turbines in the region
            orig_t_info = [
                "$(PSY.get_name(t)) ($(nameof(typeof(t))) @ $(hasproperty(t, :bus) ? format_bus_info(PSY.get_bus(t)) : "no bus"))"
                for t in vcat(up_t, dn_t)
            ]
            orig_str = isempty(orig_t_info) ? "none in main_sys" : join(orig_t_info, ", ")
            push!(
                issues,
                "  • [HYDRO_TOPOLOGY] [DROPPED_ORPHAN_RESERVOIR] HydroReservoir '$res_name' has 0 retained upstream or downstream turbines in the extracted region and will be DROPPED! (Original turbines in main_sys: [$orig_str])",
            )
            continue
        end

        # Reservoir has >= 1 retained turbine; check if it had split membership (some turbines inside, some outside)
        if !isempty(miss_up_t)
            kept_str = join(["$(PSY.get_name(t)) @ $(format_bus_info(PSY.get_bus(t)))" for t in kept_up_t], ", ")
            miss_str = join(["$(PSY.get_name(t)) @ $(format_bus_info(PSY.get_bus(t)))" for t in miss_up_t], ", ")
            push!(
                issues,
                "  • [HYDRO_TOPOLOGY] [SPLIT_UPSTREAM_TURBINES] HydroReservoir '$res_name' is missing $(length(miss_up_t)) of $(length(up_t)) upstream turbine(s) because their buses are outside the region! " *
                "Retained=[$kept_str] | Detached External=[$miss_str] (Add bus to `extra_bus_numbers` if needed)",
            )
        end

        if !isempty(miss_dn_t)
            kept_str = join(["$(PSY.get_name(t)) @ $(format_bus_info(PSY.get_bus(t)))" for t in kept_dn_t], ", ")
            miss_str = join(["$(PSY.get_name(t)) @ $(format_bus_info(PSY.get_bus(t)))" for t in miss_dn_t], ", ")
            push!(
                issues,
                "  • [HYDRO_TOPOLOGY] [SPLIT_DOWNSTREAM_TURBINES] HydroReservoir '$res_name' is missing $(length(miss_dn_t)) of $(length(dn_t)) downstream turbine(s) because their buses are outside the region! " *
                "Retained=[$kept_str] | Detached External=[$miss_str] (Add bus to `extra_bus_numbers` if needed)",
            )
        end

        push!(valid_reservoirs, res)
    end

    valid_res_set = Set(valid_reservoirs)

    # Check if any surviving reservoir references an upstream_reservoir that was dropped
    for res in valid_reservoirs
        res_name = PSY.get_name(res)
        up_r = PSY.get_upstream_reservoirs(res)
        miss_up_r = filter(r -> !(r in valid_res_set), up_r)
        if !isempty(miss_up_r)
            miss_r_names = join(PSY.get_name.(miss_up_r), ", ")
            push!(
                issues,
                "  • [HYDRO_TOPOLOGY] [MISSING_UPSTREAM_RESERVOIR] HydroReservoir '$res_name' references upstream reservoir(s) [$miss_r_names] that were dropped or outside the region (detaching link).",
            )
        end
    end

    #  Check if any retained regional HydroUnit was linked to a reservoir in main_sys,
    #  but is now missing a reservoir (or missing its head/tail partner for pumped hydro)
    main_turbine_to_res = Dict{PSY.StaticInjection, Vector{PSY.HydroReservoir}}()
    for res in all_main_reservoirs
        for t in vcat(PSY.get_upstream_turbines(res), PSY.get_downstream_turbines(res))
            push!(get!(main_turbine_to_res, t, PSY.HydroReservoir[]), res)
        end
    end

    for inj in region_injections
        if inj isa PSY.HydroUnit && haskey(main_turbine_to_res, inj)
            orig_res_list = unique(main_turbine_to_res[inj])
            kept_res_list = filter(r -> r in valid_res_set, orig_res_list)
            miss_res_list = filter(r -> !(r in valid_res_set), orig_res_list)

            if !isempty(miss_res_list)
                kept_r_str = isempty(kept_res_list) ? "NONE" : join(PSY.get_name.(kept_res_list), ", ")
                miss_r_str = join(PSY.get_name.(miss_res_list), ", ")
                push!(
                    issues,
                    "  • [HYDRO_TOPOLOGY] [TURBINE_MISSING_RESERVOIR] Regional hydro unit '$(PSY.get_name(inj))' ($(nameof(typeof(inj))) @ $(format_bus_info(PSY.get_bus(inj)))) " *
                    "lost linked HydroReservoir(s) [$miss_r_str] (Retained reservoirs for this unit: [$kept_r_str]).",
                )
            end
        end
    end

    if !isempty(issues)
        @warn "[HYDRO_TOPOLOGY] Identified $(length(issues)) hydro reservoir/turbine membership issue(s):\n" *
              join(issues, "\n")
    else
        @info "[HYDRO_TOPOLOGY] All $(length(valid_reservoirs)) regional HydroReservoir(s) have complete turbine/reservoir memberships."
    end

    return valid_reservoirs
end
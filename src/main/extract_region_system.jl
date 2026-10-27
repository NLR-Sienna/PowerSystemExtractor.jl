# ==============================================================================
# Main Regional System Extraction Function (Compatible with PSY 5)
# ==============================================================================

"""
    extract_region_system(
        main_sys::PSY.System;
        area_names::Vector{String},
        extra_bus_numbers::Vector{Int} = Int[],
        extra_bus_names::Vector{String} = String[],
        keep_only_largest_island::Bool = true,
        auto_include_1hop_bridges::Bool = true,
        min_island_size_to_bridge::Int = 2,
        include_services::Bool = true,
        fallback_bus_ext_reserves::Bool = false,
        system_name::String = join(area_names, "_") * "_Carved_System",
        log_file::Union{Nothing, String} = nothing,
    ) -> PSY.System

Extracts a standalone regional `PSY.System` from `main_sys` without mutating `main_sys`.
"""
function extract_region_system(
    main_sys::PSY.System;
    area_names::Vector{String},
    extra_bus_numbers::Vector{Int} = Int[],
    extra_bus_names::Vector{String} = String[],
    keep_only_largest_island::Bool = true,
    auto_include_1hop_bridges::Bool = true,
    min_island_size_to_bridge::Int = 2,
    include_services::Bool = true,
    fallback_bus_ext_reserves::Bool = false,
    system_name::String = join(area_names, "_") * "_Carved_System",
    log_file::Union{Nothing, String} = nothing,
    _allowed_bus_numbers::Union{Nothing, Set{Int}} = nothing,
    _warn_tielines::Bool = true,
)
    # Open MultiLogger once on top-level call; recursive rebuilds inherit the logger
    if !isnothing(log_file)
        return _with_optional_logfile(log_file) do
            extract_region_system(
                main_sys;
                area_names = area_names,
                extra_bus_numbers = extra_bus_numbers,
                extra_bus_names = extra_bus_names,
                keep_only_largest_island = keep_only_largest_island,
                auto_include_1hop_bridges = auto_include_1hop_bridges,
                min_island_size_to_bridge = min_island_size_to_bridge,
                include_services = include_services,
                fallback_bus_ext_reserves = fallback_bus_ext_reserves,
                system_name = system_name,
                log_file = nothing,
                _allowed_bus_numbers = _allowed_bus_numbers,
                _warn_tielines = _warn_tielines,
            )
        end
    end

    area_name_set = Set(area_names)
    extra_num_set = Set(extra_bus_numbers)
    extra_name_set = Set(extra_bus_names)

    # Identify all 3W internal star buses in main_sys so Step 1 only selects physical (non-fictitious) buses
    all_main_star_buses = get_all_star_buses(main_sys)

    # Collect candidate physical buses
    physical_buses = collect(
        PSY.get_components(PSY.ACBus, main_sys) do b
            b in all_main_star_buses && return false
            if !isnothing(_allowed_bus_numbers)
                return PSY.get_number(b) in _allowed_bus_numbers
            end
            in_area = !isnothing(PSY.get_area(b)) && (PSY.get_name(PSY.get_area(b)) in area_name_set)
            in_extra = (PSY.get_number(b) in extra_num_set) || (PSY.get_name(b) in extra_name_set)
            return in_area || in_extra
        end
    )
    isempty(physical_buses) && error("No buses found matching area_names=$area_names or extra_buses.")
    physical_bus_set = Set(physical_buses)

    # Classify Intra-Regional Branches vs. Cut Tie-Lines & Warn User
    region_branches, cut_tielines = classify_regional_branches(main_sys, physical_bus_set)
    _warn_tielines && warn_cut_tielines(cut_tielines, physical_bus_set)

    # Add Internal Star Buses for Retained 3W Transformers
    star_buses = PSY.get_star_bus.(filter(x -> x isa PSY.ThreeWindingTransformer, region_branches))
    unique!(star_buses)
    star_bus_nums = Set(PSY.get_number.(star_buses))

    all_region_buses = vcat(physical_buses, star_buses)
    all_region_bus_set = Set(all_region_buses)

    # Collect Unique Arcs for 2W and 3W Branches
    region_arcs = PSY.Arc[]
    for br in region_branches
        for arc in get_branch_arcs(br)
            push!(region_arcs, arc)
        end
    end
    unique!(region_arcs)

    # Collect All StaticInjections (Gen, Storage, Load, SynchronousCondenser, Admittances, etc.)
    region_injections = collect(
        PSY.get_components(
            x -> hasproperty(x, :bus) &&
                 (PSY.get_bus(x) in all_region_bus_set) &&
                 !(x isa PSY.StaticInjectionSubsystem),
            PSY.StaticInjection,
            main_sys,
        )
    )

    # Collect, Audit, and Filter HydroReservoirs (Logs explicit [HYDRO_TOPOLOGY] warnings)
    # Ensuring all Reservoirs "connected" to HydroUnits part of the region are retained, and any orphaned reservoirs are dropped.
    region_reservoirs = collect_and_audit_hydro_reservoirs(
        main_sys,
        all_region_bus_set,
        region_injections,
    )

    # Collect Areas, LoadZones & Internal AreaInterchanges
    region_areas = unique(filter(!isnothing, PSY.get_area.(all_region_buses)))
    region_area_set = Set(region_areas)
    region_loadzones = unique(filter(!isnothing, PSY.get_load_zone.(all_region_buses)))

    region_interchanges = collect(
        PSY.get_components(
            ai -> (PSY.get_from_area(ai) in region_area_set) && (PSY.get_to_area(ai) in region_area_set),
            PSY.AreaInterchange,
            main_sys,
        )
    )

    # Clone Components Without Mutating main_sys
    cloned = clone_regional_components(
        region_areas,
        region_loadzones,
        all_region_buses,
        region_arcs,
        region_branches,
        region_injections,
        region_reservoirs,
        region_interchanges,
    )

    cloned_physical_buses = filter(b -> !(PSY.get_number(b) in star_bus_nums), cloned.buses)
    ensure_reference_bus!(cloned_physical_buses)

    # Build Standalone Regional System
    region_sys = PSY.System(
        PSY.get_base_power(main_sys);
        runchecks = false,
        enable_compression = true,
        compression = PSY.CompressionSettings(; enabled = true, level = 5),
    )
    PSY.set_name!(region_sys, system_name)
    PSY.set_units_base_system!(region_sys, PSY.UnitSystem.SYSTEM_BASE)

    foreach(a -> PSY.add_component!(region_sys, a), cloned.areas)
    foreach(lz -> PSY.add_component!(region_sys, lz), cloned.loadzones)
    foreach(b -> PSY.add_component!(region_sys, b), cloned.buses)
    foreach(arc -> PSY.add_component!(region_sys, arc), cloned.arcs)
    foreach(br -> PSY.add_component!(region_sys, br), cloned.branches)
    foreach(inj -> PSY.add_component!(region_sys, inj), cloned.injections)
    foreach(res -> PSY.add_component!(region_sys, res), cloned.reservoirs)
    foreach(ai -> PSY.add_component!(region_sys, ai), cloned.interchanges)

    # Check Subnetwork Connectivity via PowerNetworkMatrices (PNM.find_subnetworks)
    sub_nws = copy(PNM.find_subnetworks(region_sys))

    # Strip 3W dummy star bus numbers so island sizes reflect physical buses
    for (_, bus_nums) in sub_nws
        setdiff!(bus_nums, star_bus_nums)
    end
    filter!(kv -> !isempty(kv[2]), sub_nws)

    # Ensure any completely isolated physical bus (0 internal branches) is accounted for
    accounted_bus_nums = isempty(sub_nws) ? Set{Int}() : union(values(sub_nws)...)
    for b in cloned_physical_buses
        b_num = PSY.get_number(b)
        if !(b_num in accounted_bus_nums)
            sub_nws[b_num] = Set([b_num])
        end
    end

    if length(sub_nws) > 1
        sorted_sub_nws = sort(collect(sub_nws), by = kv -> length(kv[2]), rev = true)
        main_ref_num, main_bus_nums = sorted_sub_nws[1]

        # Optional 1-Hop Bridge Bus Auto-Healing
        if auto_include_1hop_bridges
            bridge_buses = find_pnm_bridge_buses(
                sorted_sub_nws,
                cut_tielines,
                physical_bus_set;
                min_island_size_to_bridge = min_island_size_to_bridge,
            )
            if !isempty(bridge_buses)
                bridge_nums = PSY.get_number.(bridge_buses)
                @warn "[BRIDGE_AUTO_HEAL] Auto-including $(length(bridge_buses)) 1-hop external bridge bus(es) " *
                      "($(join(format_bus_info.(bridge_buses), ", "))) and rebuilding regional system..."
                return extract_region_system(
                    main_sys;
                    area_names = area_names,
                    extra_bus_numbers = unique(vcat(extra_bus_numbers, bridge_nums)),
                    extra_bus_names = extra_bus_names,
                    keep_only_largest_island = keep_only_largest_island,
                    auto_include_1hop_bridges = false, # Prevent recursion beyond 1 hop
                    min_island_size_to_bridge = min_island_size_to_bridge,
                    include_services = include_services,
                    fallback_bus_ext_reserves = fallback_bus_ext_reserves,
                    system_name = system_name,
                    log_file = nothing,
                    _warn_tielines = false,
                )
            end
        end

        # Log Disconnected Islands & Cross-Referenced Cut Tie-Lines
        island_details = String[]
        for (idx, (rep_num, bus_nums)) in enumerate(sorted_sub_nws[2:end])
            island_tielines = filter(cut_tielines) do br
                any(b -> PSY.get_number(b) in bus_nums, get_physical_buses(br))
            end
            tl_names = isempty(island_tielines) ? "None" : join(PSY.get_name.(island_tielines), ", ")
            push!(
                island_details,
                "  • [ISLAND] Island #$(idx + 1) ($(length(bus_nums)) physical bus(es), rep bus #$rep_num): " *
                "bus_numbers=$(sort(collect(bus_nums))) | Cut tie-lines touching this island: [$tl_names]",
            )
        end

        @warn "[ISLAND] PNM.find_subnetworks detected $(length(sub_nws)) disconnected subnetworks in '$system_name'!\n" *
              "Main subnetwork (ref bus #$main_ref_num) has $(length(main_bus_nums)) physical buses.\n" *
              "Secondary disconnected subnetworks:\n" * join(island_details, "\n")

        # Optional Pruning of Disconnected Islands via Clean Rebuild
        if keep_only_largest_island
            @warn "[ISLAND] Rebuilding '$system_name' with only the largest connected subnetwork ($(length(main_bus_nums)) physical buses)..."
            return extract_region_system(
                main_sys;
                area_names = area_names,
                extra_bus_numbers = extra_bus_numbers,
                extra_bus_names = extra_bus_names,
                keep_only_largest_island = false,
                auto_include_1hop_bridges = false,
                min_island_size_to_bridge = min_island_size_to_bridge,
                include_services = include_services,
                fallback_bus_ext_reserves = fallback_bus_ext_reserves,
                system_name = system_name,
                log_file = nothing,
                _allowed_bus_numbers = main_bus_nums,
                _warn_tielines = false,
            )
        end
    else
        @info "[ISLAND] PNM.find_subnetworks confirmed '$system_name' is a single connected network ($(length(first(values(sub_nws)))) physical buses)."
    end

    # Migrate Services & Reserves (Attached to surviving devices in region_sys)
    migrated_services = Pair{PSY.Service, PSY.Service}[]
    if include_services
        migrated_services = migrate_regional_services!(
            region_sys,
            main_sys,
            region_injections,
            region_branches;
            fallback_bus_ext_reserves = fallback_bus_ext_reserves,
        )
    end

    # Copy StaticTimeSeries for Surviving Injections, HydroReservoirs, and Migrated Services
    ts_count = 0
    for orig_dev in vcat(region_injections, region_reservoirs)
        dev_type = typeof(orig_dev)
        dev_name = PSY.get_name(orig_dev)
        if PSY.has_component(dev_type, region_sys, dev_name) && PSY.has_time_series(orig_dev)
            new_dev = PSY.get_component(dev_type, region_sys, dev_name)
            for key in PSY.get_time_series_keys(orig_dev)
                ts = PSY.get_time_series(orig_dev, key)
                if ts isa PSY.StaticTimeSeries
                    PSY.add_time_series!(region_sys, new_dev, ts)
                    ts_count += 1
                end
            end
        end
    end

    for (orig_srv, new_srv) in migrated_services
        if PSY.has_time_series(orig_srv)
            for key in PSY.get_time_series_keys(orig_srv)
                ts = PSY.get_time_series(orig_srv, key)
                if ts isa PSY.StaticTimeSeries
                    PSY.add_time_series!(region_sys, new_srv, ts)
                    ts_count += 1
                end
            end
        end
    end

    retained_star_count = count(
        b -> PSY.get_number(b) in star_bus_nums,
        PSY.get_components(PSY.ACBus, region_sys),
    )

    @info """
    Regional Extraction Complete ('$system_name'):
      - Retained Areas:     $(length(PSY.get_components(PSY.Area, region_sys))) ($(join(PSY.get_name.(PSY.get_components(PSY.Area, region_sys)), ", ")))
      - Retained Buses:     $(length(PSY.get_components(PSY.ACBus, region_sys))) ($retained_star_count 3W star buses)
      - Retained Branches:  $(length(PSY.get_components(PSY.Branch, region_sys)))
      - Cut Tie-Lines:      $(length(cut_tielines))
      - Static Injections:  $(length(PSY.get_components(PSY.StaticInjection, region_sys)))
      - Hydro Reservoirs:   $(length(PSY.get_components(PSY.HydroReservoir, region_sys)))
      - Services/Reserves:  $(length(migrated_services))
      - Time Series Copied: $ts_count
    """

    return region_sys
end


# ==============================================================================
# Main Regional System Extraction Function (Compatible with PSY 5)
# ==============================================================================

"""
    extract_region_system(
        sys_loc::String;
        area_names::Vector{String},
        extra_bus_numbers::Vector{Int} = Int[],
        extra_bus_names::Vector{String} = String[],
        keep_only_largest_island::Bool = true,
        auto_include_1hop_bridges::Bool = true,
        min_island_size_to_bridge::Int = 2,
        include_services::Bool = true,
        fallback_bus_ext_reserves::Bool = false,
        system_name::String = join(area_names, "_") * "_Carved_System",
        log_file::Union{Nothing, String} = nothing,
    ) -> PSY.System

Extracts a standalone regional `PSY.System` from `main_sys` without mutating `main_sys`.
"""
function extract_region_system(
    sys_loc::String;
    area_names::Vector{String},
    extra_bus_numbers::Vector{Int} = Int[],
    extra_bus_names::Vector{String} = String[],
    keep_only_largest_island::Bool = true,
    auto_include_1hop_bridges::Bool = true,
    min_island_size_to_bridge::Int = 2,
    include_services::Bool = true,
    fallback_bus_ext_reserves::Bool = false,
    system_name::String = join(area_names, "_") * "_Carved_System",
    log_file::Union{Nothing, String} = nothing,
    _allowed_bus_numbers::Union{Nothing, Set{Int}} = nothing,
    _warn_tielines::Bool = true,
)
    @warn "Loading system from '$sys_loc' for regional extraction with run checks disabled. Ensure this is a valid PSY 5 System file."
    main_sys = PSY.System(
        sys_loc;
        runchecks = false,
    )

    PSY.set_units_base_system!(main_sys, PSY.UnitSystem.SYSTEM_BASE)

    extract_region_system(
        main_sys;
        area_names = area_names,
        extra_bus_numbers = extra_bus_numbers,
        extra_bus_names = extra_bus_names,
        keep_only_largest_island = keep_only_largest_island,
        auto_include_1hop_bridges = auto_include_1hop_bridges,
        min_island_size_to_bridge = min_island_size_to_bridge,
        include_services = include_services,
        fallback_bus_ext_reserves = fallback_bus_ext_reserves,
        system_name = system_name,
        log_file = nothing,
        _allowed_bus_numbers = _allowed_bus_numbers,
        _warn_tielines = _warn_tielines,
    )
       
end
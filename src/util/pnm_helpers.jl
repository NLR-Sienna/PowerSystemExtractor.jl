# ==============================================================================
# Branch, 3W Transformer & HydroReservoir Topology Helpers
# ==============================================================================

"""
Returns the Set of all 3W transformer internal star buses in `sys`.
"""
function get_all_star_buses(sys::PSY.System)
    star_buses = Set{PSY.ACBus}(PSY.get_star_bus.(PSY.get_components(PSY.ThreeWindingTransformer, sys)))
    return star_buses
end

"""
Returns the physical ACBus terminals of a 2W branch, 3W transformer, or 2-terminal HVDC line.
(Returns an empty tuple for AreaInterchange).
"""
function get_physical_buses(br::PSY.Branch)
    if br isa PSY.ThreeWindingTransformer
        return (
            PSY.get_from(PSY.get_primary_star_arc(br)),
            PSY.get_from(PSY.get_secondary_star_arc(br)),
            PSY.get_from(PSY.get_tertiary_star_arc(br)),
        )
    elseif hasproperty(br, :arc) && PSY.get_arc(br) isa PSY.Arc
        arc = PSY.get_arc(br)
        return (PSY.get_from(arc), PSY.get_to(arc))
    else
        return ()
    end
end

"""
Returns all Arcs associated with a 2W or 3W branch.
"""
function get_branch_arcs(br::PSY.Branch)
    if br isa PSY.ThreeWindingTransformer
        return (
            PSY.get_primary_star_arc(br),
            PSY.get_secondary_star_arc(br),
            PSY.get_tertiary_star_arc(br),
        )
    elseif hasproperty(br, :arc) && PSY.get_arc(br) isa PSY.Arc
        return (PSY.get_arc(br),)
    else
        return ()
    end
end

"""
Classifies all branches in `main_sys` into:
  - `internal_branches`: all physical terminals are inside `bus_set`
  - `cut_tielines`: at least one terminal is inside `bus_set` and at least one is outside
"""
function classify_regional_branches(main_sys::PSY.System, bus_set::Set{PSY.ACBus})
    internal_branches = PSY.Branch[]
    cut_tielines = PSY.Branch[]

    for br in PSY.get_components(PSY.Branch, main_sys)
        p_buses = get_physical_buses(br)
        isempty(p_buses) && continue

        n_in = count(b -> b in bus_set, p_buses)
        if n_in == length(p_buses)
            push!(internal_branches, br)
        elseif n_in > 0
            push!(cut_tielines, br)
        end
    end

    return internal_branches, cut_tielines
end

"""
Formats bus metadata for readable diagnostic messages.
"""
function format_bus_info(b::PSY.ACBus)
    area_name = isnothing(PSY.get_area(b)) ? "None" : PSY.get_name(PSY.get_area(b))
    kv = something(PSY.get_base_voltage(b), 0.0)
    return "$(PSY.get_name(b)) (#$(PSY.get_number(b)), Area=$area_name, $(kv)kV)"
end

"""
Emits structured logs with [CUT_TIELINE] and [BRIDGE_CANDIDATE] tags.
"""
function warn_cut_tielines(cut_tielines::Vector{PSY.Branch}, bus_set::Set{PSY.ACBus})
    if isempty(cut_tielines)
        @info "[CUT_TIELINE] No cut tie-lines detected across the region boundary."
        return
    end

    ext_bus_to_tielines = Dict{PSY.ACBus, Vector{PSY.Branch}}()
    lines_msg = String[]

    for br in sort(cut_tielines, by = PSY.get_name)
        p_buses = get_physical_buses(br)
        in_buses = filter(b -> b in bus_set, collect(p_buses))
        out_buses = filter(b -> !(b in bus_set), collect(p_buses))

        for ob in out_buses
            push!(get!(ext_bus_to_tielines, ob, PSY.Branch[]), br)
        end

        avail_str = PSY.get_available(br) ? "avail" : "UNAVAIL"
        in_str = join(format_bus_info.(in_buses), ", ")
        out_str = join(format_bus_info.(out_buses), ", ")
        push!(
            lines_msg,
            "  • [CUT_TIELINE] [$(nameof(typeof(br))), $avail_str] $(PSY.get_name(br)): IN=[$in_str] <--> OUT=[$out_str]",
        )
    end

    bridge_candidates = filter(kv -> length(kv[2]) >= 2, ext_bus_to_tielines)
    bridge_msg = String[]
    for (eb, brs) in bridge_candidates
        push!(
            bridge_msg,
            "  • [BRIDGE_CANDIDATE] External Bus $(format_bus_info(eb)) connects $(length(brs)) cut tie-lines: $(join(PSY.get_name.(brs), ", "))",
        )
    end

    @warn "[CUT_TIELINE] Identified $(length(cut_tielines)) cut tie-line(s) at the region boundary:\n" *
          join(lines_msg, "\n")
    if !isempty(bridge_msg)
        @warn "[BRIDGE_CANDIDATE] External buses touching multiple cut tie-lines (potential 1-hop boundary bridges):\n" *
              join(bridge_msg, "\n")
    end
end

"""
Ensures at least one ACBusTypes.REF or ACBusTypes.SLACK bus exists among `physical_buses`.
"""
function ensure_reference_bus!(physical_buses::Vector{PSY.ACBus})
    isempty(physical_buses) && return
    any(b -> PSY.get_bustype(b) in (PSY.ACBusTypes.REF, PSY.ACBusTypes.SLACK), physical_buses) && return

    pv_buses = filter(b -> PSY.get_bustype(b) == PSY.ACBusTypes.PV, physical_buses)
    candidates = isempty(pv_buses) ? physical_buses : pv_buses
    sort!(candidates, by = b -> something(PSY.get_base_voltage(b), 0.0), rev = true)
    new_ref = first(candidates)
    PSY.set_bustype!(new_ref, PSY.ACBusTypes.REF)
    @warn "[SLACK_BUS] No REF/SLACK bus found in region; promoted physical bus $(format_bus_info(new_ref)) to REF."
end

"""
Finds 1-hop external bridge buses using PNM subnetworks and cut tie-lines.
"""
function find_pnm_bridge_buses(
    sorted_sub_nws::Vector{Pair{Int, Set{Int}}},
    cut_tielines::Vector{PSY.Branch},
    physical_bus_set::Set{PSY.ACBus};
    min_island_size_to_bridge::Int = 2,
)
    length(sorted_sub_nws) <= 1 && return PSY.ACBus[]
    main_bus_nums = sorted_sub_nws[1][2]

    sec_bus_nums = Set{Int}()
    for (_, bus_nums) in sorted_sub_nws[2:end]
        length(bus_nums) >= min_island_size_to_bridge && union!(sec_bus_nums, bus_nums)
    end
    isempty(sec_bus_nums) && return PSY.ACBus[]

    touches_main = Set{PSY.ACBus}()
    touches_sec = Set{PSY.ACBus}()

    for br in cut_tielines
        !PSY.get_available(br) && continue
        p_buses = get_physical_buses(br)
        has_main = any(b -> (b in physical_bus_set) && (PSY.get_number(b) in main_bus_nums), p_buses)
        has_sec = any(b -> (b in physical_bus_set) && (PSY.get_number(b) in sec_bus_nums), p_buses)

        for b in p_buses
            if !(b in physical_bus_set)
                has_main && push!(touches_main, b)
                has_sec && push!(touches_sec, b)
            end
        end
    end

    return collect(intersect(touches_main, touches_sec))
end

"""
Returns the Set of sorted `(area_name_1, area_name_2)` pairs that are physically connected
by at least one available branch in `region_branches`.
"""
function get_connected_area_pairs(
    region_branches::Vector{PSY.Branch};
    only_available::Bool = true,
)
    connected_pairs = Set{Tuple{String, String}}()

    for br in region_branches
        only_available && !PSY.get_available(br) && continue
        p_buses = get_physical_buses(br)
        n = length(p_buses)
        for i in 1:(n - 1), j in (i + 1):n
            a1 = PSY.get_area(p_buses[i])
            a2 = PSY.get_area(p_buses[j])
            if !isnothing(a1) && !isnothing(a2)
                n1, n2 = PSY.get_name(a1), PSY.get_name(a2)
                if n1 != n2
                    push!(connected_pairs, minmax(n1, n2))
                end
            end
        end
    end

    return connected_pairs
end

"""
Collects and audits `AreaInterchange` components from `main_sys`.
Retains an `AreaInterchange` ONLY if both `from_area` and `to_area` are in `region_area_set`
AND at least one available `ACBranch` in `region_branches` physically connects the two areas.
"""
function collect_and_audit_area_interchanges(
    main_sys::PSY.System,
    region_area_set::Set{PSY.Area},
    region_branches::Vector{PSY.Branch},
)
    length(region_area_set) < 2 && return PSY.AreaInterchange[]

    connected_pairs = get_connected_area_pairs(region_branches; only_available = true)
    valid_interchanges = PSY.AreaInterchange[]
    dropped_logs = String[]

    for ai in PSY.get_components(PSY.AreaInterchange, main_sys)
        from_a = PSY.get_from_area(ai)
        to_a   = PSY.get_to_area(ai)
        (isnothing(from_a) || isnothing(to_a)) && continue

        # Skip silently if either Area is not present in the extracted region
        if !(from_a in region_area_set) || !(to_a in region_area_set)
            continue
        end

        pair = minmax(PSY.get_name(from_a), PSY.get_name(to_a))
        if !(pair in connected_pairs)
            push!(
                dropped_logs,
                "  • [DROPPED_AREA_INTERCHANGE] AreaInterchange '$(PSY.get_name(ai))' ($(pair[1]) <-> $(pair[2])) dropped: both Areas exist in region, but 0 available ACBranches connect them.",
            )
            continue
        end

        push!(valid_interchanges, ai)
    end

    if !isempty(dropped_logs)
        @warn "[AREA_INTERCHANGE_TOPOLOGY] Dropped $(length(dropped_logs)) AreaInterchange(s) lacking physical ACBranch connections:\n" *
              join(dropped_logs, "\n")
    end

    return valid_interchanges
end
"""
Clones a self-consistent set of regional components without mutating `main_sys`.
Handles `Device`s without a `:services` field (such as `HydroReservoir`) and ensures
`HydroReservoir` turbine/reservoir vectors only reference retained regional objects.
"""
function clone_regional_components(
    areas::Vector{PSY.Area},
    loadzones::Vector{PSY.LoadZone},
    buses::Vector{PSY.ACBus},
    arcs::Vector{PSY.Arc},
    branches::Vector{PSY.Branch},
    injections::Vector{PSY.StaticInjection},
    reservoirs::Vector{PSY.HydroReservoir},
    interchanges::Vector{PSY.AreaInterchange},
)
    all_objs = vcat(areas, loadzones, buses, arcs, branches, injections, reservoirs, interchanges)
    retained_set = IdDict{Any, Bool}(x => true for x in all_objs)

    orig_refs = IdDict{Any, Any}()
    orig_services = IdDict{PSY.Device, Vector{PSY.Service}}()
    orig_dyn = IdDict{PSY.StaticInjection, Any}() 
    orig_res_links = IdDict{PSY.HydroReservoir, NamedTuple}()

    try
        # Here we are making sure we remove all references to the main system and services so that deepcopy does not copy them over
        for obj in all_objs
            # Detach SharedSystemReferences directly on the component
            orig_refs[obj] = IS.get_shared_system_references(obj)
            IS.set_shared_system_references!(obj, nothing)

            # 2. Detach services ONLY on Devices that have a `:services` field (skips HydroReservoir)
            if obj isa PSY.Device && hasproperty(obj, :services)
                orig_services[obj] = copy(PSY.get_services(obj))
                PSY.clear_services!(obj)
            end

            # 3. Detach dynamic_injector if present so it doesn't leak references
            if obj isa PSY.StaticInjection && !isnothing(PSY.get_dynamic_injector(obj))
                orig_dyn[obj] = PSY.get_dynamic_injector(obj)
                PSY.set_dynamic_injector!(obj, nothing)
            end

            # 4. Temporarily filter HydroReservoir turbine/reservoir vectors to retained regional objects
            if obj isa PSY.HydroReservoir
                up_t = PSY.get_upstream_turbines(obj)
                dn_t = PSY.get_downstream_turbines(obj)
                up_r = PSY.get_upstream_reservoirs(obj)
                orig_res_links[obj] = (up_t = copy(up_t), dn_t = copy(dn_t), up_r = copy(up_r))

                filter!(x -> haskey(retained_set, x), up_t)
                filter!(x -> haskey(retained_set, x), dn_t)
                filter!(x -> haskey(retained_set, x), up_r)
            end
        end

        return deepcopy((
            areas = areas,
            loadzones = loadzones,
            buses = buses,
            arcs = arcs,
            branches = branches,
            injections = injections,
            reservoirs = reservoirs,
            interchanges = interchanges,
        ))
    finally
        # We are restoring the original state of the objects to avoid side effects on `main_sys`
        for (obj, ref) in orig_refs
            IS.set_shared_system_references!(obj, ref)
        end
        for (dev, srvs) in orig_services
            for s in srvs
                push!(PSY.get_services(dev), s)
            end
        end
        for (inj, dyn) in orig_dyn
            PSY.set_dynamic_injector!(inj, dyn)
        end
        for (res, links) in orig_res_links
            empty!(PSY.get_upstream_turbines(res))
            append!(PSY.get_upstream_turbines(res), links.up_t)
            empty!(PSY.get_downstream_turbines(res))
            append!(PSY.get_downstream_turbines(res), links.dn_t)
            empty!(PSY.get_upstream_reservoirs(res))
            append!(PSY.get_upstream_reservoirs(res), links.up_r)
        end
    end
end

"""
Clones a single PSY.Service without mutating `main_sys` or copying its TimeSeriesManager.
"""
function clone_service(srv::PSY.Service, region_sys::PSY.System)
    orig_ref = IS.get_shared_system_references(srv)
    orig_area = hasproperty(srv, :area) ? PSY.get_area(srv) : nothing

    try
        IS.set_shared_system_references!(srv, nothing)
        if hasproperty(srv, :area) && !isnothing(orig_area)
            PSY.set_area!(srv, nothing)
        end
        new_srv = deepcopy(srv)
        if hasproperty(new_srv, :area) && !isnothing(orig_area)
            new_area = PSY.get_component(PSY.Area, region_sys, PSY.get_name(orig_area))
            PSY.set_area!(new_srv, new_area)
        end
        return new_srv
    finally
        IS.set_shared_system_references!(srv, orig_ref)
        if hasproperty(srv, :area) && !isnothing(orig_area)
            PSY.set_area!(srv, orig_area)
        end
    end
end

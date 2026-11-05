"""
    migrate_supplemental_attributes!(
        region_sys::PSY.System,
        main_sys::PSY.System;
        strict_contingencies::Bool = false,
    ) -> Tuple{Int, Int}

Audits, clones, and migrates `SupplementalAttribute`s from `main_sys` to `region_sys`,
along with any `StaticTimeSeries` attached to those attributes.
"""
function migrate_supplemental_attributes!(
    region_sys::PSY.System,
    main_sys::PSY.System;
    strict_contingencies::Bool = false,
)
    # Build component lookup map
    region_comp_map = Dict{Tuple{DataType, String}, PSY.Component}()
    for comp in PSY.get_components(PSY.Component, region_sys)
        region_comp_map[(typeof(comp), PSY.get_name(comp))] = comp
    end

    migrated_attrs = 0
    migrated_attr_ts = 0
    split_warnings = String[]
    dropped_contingencies = String[]

    for orig_attr in PSY.get_supplemental_attributes(IS.SupplementalAttribute, main_sys)
        assoc_comps = PSY.get_associated_components(main_sys, orig_attr)
        isempty(assoc_comps) && continue

        retained_new_comps = PSY.Component[]
        dropped_orig_comps = PSY.Component[]

        for orig_c in assoc_comps
            key = (typeof(orig_c), PSY.get_name(orig_c))
            if haskey(region_comp_map, key)
                push!(retained_new_comps, region_comp_map[key])
            else
                push!(dropped_orig_comps, orig_c)
            end
        end

        isempty(retained_new_comps) && continue

        if !isempty(dropped_orig_comps)
            attr_type_name = nameof(typeof(orig_attr))
            attr_label = hasmethod(PSY.get_name, Tuple{typeof(orig_attr)}) ?
                         "'$(PSY.get_name(orig_attr))'" : "UUID=$(IS.get_uuid(orig_attr))"
            retained_names = join(["$(nameof(typeof(c))):$(PSY.get_name(c))" for c in retained_new_comps], ", ")
            dropped_names  = join(["$(nameof(typeof(c))):$(PSY.get_name(c))" for c in dropped_orig_comps], ", ")

            if orig_attr isa PSY.Contingency && strict_contingencies
                push!(
                    dropped_contingencies,
                    "  - [DROPPED_SPLIT_CONTINGENCY] $attr_type_name $attr_label dropped because external element(s) [$dropped_names] are outside region.",
                )
                continue
            end

            if !(orig_attr isa IS.GeographicInfo)
                push!(
                    split_warnings,
                    "  - [SPLIT_SUPPLEMENTAL_ATTRIBUTE] $attr_type_name $attr_label spans boundary: attached to $(length(retained_new_comps)) in-region component(s), detached from $(length(dropped_orig_comps)) external component(s).",
                )
            end
        end

        new_attr = _clone_supplemental_attribute(orig_attr)
        for new_c in retained_new_comps
            PSY.add_supplemental_attribute!(region_sys, new_c, new_attr)
        end
        migrated_attrs += 1

        if PSY.has_time_series(orig_attr)
            for ts_key in PSY.get_time_series_keys(orig_attr)
                ts = PSY.get_time_series(orig_attr, ts_key)
                if ts isa PSY.StaticTimeSeries
                    PSY.add_time_series!(region_sys, new_attr, ts)
                    migrated_attr_ts += 1
                end
            end
        end
    end

    if !isempty(split_warnings)
        @warn "[SUPPLEMENTAL_ATTRIBUTE_TOPOLOGY] $(length(split_warnings)) SupplementalAttribute(s) spanned the regional boundary:\n" *
              join(split_warnings, "\n")
    end

    if !isempty(dropped_contingencies)
        @warn "[SUPPLEMENTAL_ATTRIBUTE_TOPOLOGY] $(length(dropped_contingencies)) boundary-spanning Contingency attribute(s) were dropped (strict_contingencies=true):\n" *
              join(dropped_contingencies, "\n")
    end

    return migrated_attrs, migrated_attr_ts
end
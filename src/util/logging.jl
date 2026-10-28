"""
Runs `f()` while teeing all `@info`, `@warn`, and `@error` messages to both the console
and `log_file` (if provided) using `InfrastructureSystems.MultiLogger`.
"""
function _with_optional_logfile(f::Function, log_file::Union{Nothing, String})
    isnothing(log_file) && return f()

    mkpath(dirname(abspath(log_file)))
    open(log_file, "w") do io
        console_logger = Logging.ConsoleLogger(stderr, Logging.Info)
        file_logger = IS.FileLogger(io, Logging.Info)
        multi_logger = IS.MultiLogger([console_logger, file_logger])

        println(io, "=== Regional System Extraction Log ($(Dates.now())) ===\n")
        try
            return Logging.with_logger(multi_logger) do
                f()
            end
        finally
            flush(io)
        end
    end
end

"""
Safely extracts the maximum active power (in MW) of a true `ElectricLoad`
(excluding shunt admittances like `FixedAdmittance` and `SwitchedAdmittance`).
"""
function _safe_load_mw(inj::PSY.StaticInjection, base_power::Float64)::Union{Float64, Nothing}
    if !(inj isa PSY.ElectricLoad) || inj isa PSY.FixedAdmittance || inj isa PSY.SwitchedAdmittance
        return nothing
    end
    if hasfield(typeof(inj), :max_active_power)
        return Float64(getfield(inj, :max_active_power)) * base_power
    elseif hasfield(typeof(inj), :active_power)
        return Float64(getfield(inj, :active_power)) * base_power
    elseif hasfield(typeof(inj), :constant_active_power)
        # StandardLoad / ExponentialLoad / InterruptibleStandardLoad
        p = getfield(inj, :max_constant_active_power) +
            getfield(inj, :max_impedance_active_power) +
            getfield(inj, :max_current_active_power)
        return Float64(p) * base_power
    end
    return nothing
end

"""
Safely extracts the capacity/rating (in MW) of a `Generator` or `Storage` device.
"""
function _safe_gen_mw(inj::PSY.StaticInjection, base_power::Float64)::Union{Float64, Nothing}
    if !(inj isa PSY.Generator || inj isa PSY.Storage) || inj isa PSY.SynchronousCondenser
        return nothing
    end
    if hasfield(typeof(inj), :active_power_limits)
        lims = getfield(inj, :active_power_limits)
        if !isnothing(lims) && hasproperty(lims, :max)
            return Float64(lims.max) * base_power
        end
    end
    if hasfield(typeof(inj), :rating)
        val = getfield(inj, :rating)
        !isnothing(val) && return Float64(val) * base_power
    end
    if hasfield(typeof(inj), :active_power)
        val = getfield(inj, :active_power)
        !isnothing(val) && return Float64(val) * base_power
    end
    return nothing
end

"""
Audits and logs all buses, generators, loads, shunts, and storage devices sitting on
secondary subnetworks that are about to be pruned by `keep_only_largest_island = true`.
"""
function log_pruned_islands_audit(
    region_sys::PSY.System,
    secondary_subnetworks::Vector{Pair{Int, Set{Int}}},
)
    num_to_bus = Dict{Int, PSY.ACBus}(
        PSY.get_number(b) => b for b in PSY.get_components(PSY.ACBus, region_sys)
    )
    bus_to_injections = Dict{Int, Vector{PSY.StaticInjection}}()
    for inj in PSY.get_components(PSY.StaticInjection, region_sys)
        b_num = PSY.get_number(PSY.get_bus(inj))
        push!(get!(bus_to_injections, b_num, PSY.StaticInjection[]), inj)
    end

    total_pruned_buses = 0
    total_single_bus_pockets = 0
    total_pruned_gen_mw = 0.0
    total_pruned_load_mw = 0.0
    pruned_lines = String[]

    base_power = PSY.get_base_power(region_sys)

    for (idx, (ref_bus_num, bus_nums)) in enumerate(secondary_subnetworks)
        n_buses = length(bus_nums)
        total_pruned_buses += n_buses
        n_buses == 1 && (total_single_bus_pockets += 1)

        sorted_nums = sort(collect(bus_nums))
        bus_labels = [
            haskey(num_to_bus, n) ?
            "$(PSY.get_name(num_to_bus[n])) (#$n, $(round(PSY.get_base_voltage(num_to_bus[n]), digits=1)) kV)" :
            "#$n" for n in sorted_nums
        ]

        island_inj_summaries = String[]
        island_gen_mw = 0.0
        island_load_mw = 0.0

        for n in sorted_nums
            for inj in get(bus_to_injections, n, PSY.StaticInjection[])
                avail_str = PSY.get_available(inj) ? "avail" : "unavail"
                load_mw = _safe_load_mw(inj, base_power)
                gen_mw = _safe_gen_mw(inj, base_power)

                if !isnothing(load_mw)
                    PSY.get_available(inj) && (island_load_mw += load_mw)
                    push!(
                        island_inj_summaries,
                        "    - [PRUNED_INJECTION] Load $(nameof(typeof(inj))) '$(PSY.get_name(inj))' @ bus #$n ($avail_str, max_p = $(round(load_mw, digits=2)) MW)",
                    )
                elseif !isnothing(gen_mw)
                    PSY.get_available(inj) && (island_gen_mw += gen_mw)
                    push!(
                        island_inj_summaries,
                        "    - [PRUNED_INJECTION] Gen/Storage $(nameof(typeof(inj))) '$(PSY.get_name(inj))' @ bus #$n ($avail_str, max_p = $(round(gen_mw, digits=2)) MW)",
                    )
                else
                    # Shunts (FixedAdmittance, SwitchedAdmittance), SynchronousCondensers, Sources, etc.
                    push!(
                        island_inj_summaries,
                        "    - [PRUNED_INJECTION] Other $(nameof(typeof(inj))) '$(PSY.get_name(inj))' @ bus #$n ($avail_str)",
                    )
                end
            end
        end

        total_pruned_gen_mw += island_gen_mw
        total_pruned_load_mw += island_load_mw

        pocket_tag = n_buses == 1 ? "1-BUS_POCKET" : "$(n_buses)-BUS_ISLAND"
        header = "  [PRUNED_ISLAND] #$idx ($pocket_tag, ref=#$ref_bus_num, avail_gen=$(round(island_gen_mw, digits=2)) MW, avail_load=$(round(island_load_mw, digits=2)) MW): $(join(bus_labels, ", "))"
        push!(pruned_lines, header)
        append!(pruned_lines, island_inj_summaries)
    end

    @warn """
    [PRUNED_ISLAND_SUMMARY] Pruning $(length(secondary_subnetworks)) secondary subnetwork(s) ($total_pruned_buses total buses; $total_single_bus_pockets are 1-bus pockets).
      Total available generation dropped: $(round(total_pruned_gen_mw, digits=2)) MW
      Total available load dropped:       $(round(total_pruned_load_mw, digits=2)) MW
    $(join(pruned_lines, "\n"))
    """
end
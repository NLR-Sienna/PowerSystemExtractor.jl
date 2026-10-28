import PowerSystems as PSY
import InfrastructureSystems as IS
import Dates
import TimeSeries

# ==============================================================================
# 2. Synthetic 2-Area Test System Builder (3W Tx, 1-Hop Bridge, HydroReservoir)
# ==============================================================================

function build_synthetic_two_area_system()
    sys = PSY.System(100.0)
    PSY.set_units_base_system!(sys, PSY.UnitSystem.SYSTEM_BASE)

    area_a = PSY.Area("Area_A", 10.0, 0.0, 0.0)
    area_b = PSY.Area("Area_B", 10.0, 0.0, 0.0)
    lz_a = PSY.LoadZone("LZ_A", 10.0, 2.0)
    lz_b = PSY.LoadZone("LZ_B", 10.0, 2.0)
    PSY.add_components!(sys, [area_a, area_b, lz_a, lz_b])

    # --- Area A Main Island (Buses 101, 102, 103 + 3W Star Bus 9001) ---
    b101 = PSY.ACBus(101, "Bus_A1", true, PSY.ACBusTypes.REF, 0.0, 1.0, (min = 0.9, max = 1.1), 230.0, area_a, lz_a)
    b102 = PSY.ACBus(102, "Bus_A2", true, PSY.ACBusTypes.PV, 0.0, 1.0, (min = 0.9, max = 1.1), 230.0, area_a, lz_a)
    b103 = PSY.ACBus(103, "Bus_A3", true, PSY.ACBusTypes.PQ, 0.0, 1.0, (min = 0.9, max = 1.1), 115.0, area_a, lz_a)
    b_star = PSY.ACBus(9001, "Star_A_3W", true, PSY.ACBusTypes.PQ, 0.0, 1.0, (min = 0.9, max = 1.1), 1.0, area_a, lz_a)

    # --- Area A 2-Bus Secondary Island (Buses 104, 105) -> Reconnected via 1-hop bridge Bus_B1 (201) ---
    b104 = PSY.ACBus(104, "Bus_A4", true,  PSY.ACBusTypes.PQ, 0.0, 1.0, (min = 0.9, max = 1.1), 230.0, area_a, lz_a)
    b105 = PSY.ACBus(105, "Bus_A5", true, PSY.ACBusTypes.PQ, 0.0, 1.0, (min = 0.9, max = 1.1), 230.0, area_a, lz_a)

    # --- Area A 1-Bus Pocket (Bus 106) -> Smaller than min_island_size_to_bridge=2, will be pruned ---
    b106 = PSY.ACBus(106, "Bus_A6_Isolated", true,  PSY.ACBusTypes.PQ, 0.0, 1.0, (min = 0.9, max = 1.1), 230.0, area_a, lz_a)

    # --- Area B Buses (Bus 201 is the 1-hop bridge; Bus 202 is deep external) ---
    b201 = PSY.ACBus(201, "Bus_B1_Bridge", true,  PSY.ACBusTypes.PV, 0.0, 1.0, (min = 0.9, max = 1.1), 230.0, area_b, lz_b)
    b202 = PSY.ACBus(202, "Bus_B2_External", true,  PSY.ACBusTypes.REF, 0.0, 1.0, (min = 0.9, max = 1.1), 230.0, area_b, lz_b)

    PSY.add_components!(sys, [b101, b102, b103, b_star, b104, b105, b106, b201, b202])

    # --- 3-Winding Transformer connecting b101, b102, b103 via b_star ---
    arc_p = PSY.Arc(b101, b_star)
    arc_s = PSY.Arc(b102, b_star)
    arc_t = PSY.Arc(b103, b_star)
    PSY.add_components!(sys, [arc_p, arc_s, arc_t])

    tx3w = PSY.Transformer3W(
        name = "Tx3W_AreaA",
        available = true,
        primary_star_arc = arc_p,
        secondary_star_arc = arc_s,
        tertiary_star_arc = arc_t,
        star_bus = b_star,
        active_power_flow_primary = 0.0,
        reactive_power_flow_primary = 0.0,
        active_power_flow_secondary = 0.0,
        reactive_power_flow_secondary = 0.0,
        active_power_flow_tertiary = 0.0,
        reactive_power_flow_tertiary = 0.0,
        r_primary = 0.001,
        x_primary = 0.01,
        r_secondary = 0.001,
        x_secondary = 0.01,
        r_tertiary = 0.001,
        x_tertiary = 0.01,
        r_12 = 0.002,
        x_12 = 0.02,
        r_23 = 0.002,
        x_23 = 0.02,
        r_13 = 0.002,
        x_13 = 0.02,
        base_power_12 = 100.0,
        base_power_23 = 100.0,
        base_power_13 = 100.0,
        g = 0.0,
        b = 0.0,
        primary_turns_ratio = 1.0,
        secondary_turns_ratio = 1.0,
        tertiary_turns_ratio = 1.0,
        rating = 2.0,
        rating_primary = 2.0,
        rating_secondary = 2.0,
        rating_tertiary = 2.0,
    )
    PSY.add_component!(sys, tx3w)

    # --- 2W Lines ---
    mk_line(name, from_b, to_b) = begin
        arc = PSY.Arc(from_b, to_b)
        PSY.add_component!(sys, arc)
        line = PSY.Line(
            name = name,
            available = true,
            active_power_flow = 0.0,
            reactive_power_flow = 0.0,
            arc = arc,
            r = 0.002,
            x = 0.02,
            b = (from = 0.01, to = 0.01),
            rating = 2.0,
            angle_limits = (min = -0.7, max = 0.7),
        )
        PSY.add_component!(sys, line)
    end

    # Internal line in Area A secondary island (104 <-> 105)
    mk_line("Line_A4_A5", b104, b105)
    # 1-hop external bridge lines via b201 (102 <-> 201 and 201 <-> 104)
    mk_line("Tie_A2_B1", b102, b201)
    mk_line("Tie_B1_A4", b201, b104)
    # Cut tie-line to 1-bus isolated pocket (106 <-> 202)
    mk_line("Tie_A6_B2", b106, b202)
    # External line inside Area B (201 <-> 202)
    mk_line("Line_B1_B2", b201, b202)

    # --- Generators & Loads ---
    gen_a1 = PSY.ThermalStandard(
        name = "Gen_A1",
        available = true,
        status = true,
        bus = b101,
        active_power = 1.0,
        reactive_power = 0.0,
        rating = 2.0,
        active_power_limits = (min = 0.0, max = 2.0),
        reactive_power_limits = (min = -1.0, max = 1.0),
        ramp_limits = nothing,
        operation_cost = PSY.ThermalGenerationCost(nothing),
        base_power = 100.0,
        time_limits = nothing,
        prime_mover_type = PSY.PrimeMovers.ST,
        fuel = PSY.ThermalFuels.COAL,
    )
    gen_b1 = PSY.ThermalStandard(
        name = "Gen_B1",
        available = true,
        status = true,
        bus = b201,
        active_power = 0.5,
        reactive_power = 0.0,
        rating = 1.0,
        active_power_limits = (min = 0.0, max = 1.0),
        reactive_power_limits = (min = -0.5, max = 0.5),
        ramp_limits = nothing,
        operation_cost = PSY.ThermalGenerationCost(nothing),
        base_power = 100.0,
        time_limits = nothing,
        prime_mover_type = PSY.PrimeMovers.ST,
        fuel = PSY.ThermalFuels.COAL,
    )
    load_a3 = PSY.PowerLoad(
        name = "Load_A3",
        available = true,
        bus = b103,
        active_power = 0.8,
        reactive_power = 0.1,
        base_power = 100.0,
        max_active_power = 1.0,
        max_reactive_power = 0.2,
    )
    PSY.add_components!(sys, [gen_a1, gen_b1, load_a3])

    # --- HydroTurbines & HydroReservoirs ---
    mk_turbine(name, bus) = PSY.HydroTurbine(
        name = name,
        available = true,
        bus = bus,
        active_power = 0.5,
        reactive_power = 0.0,
        rating = 1.0,
        active_power_limits = (min = 0.0, max = 1.0),
        reactive_power_limits = (min = -0.5, max = 0.5),
        ramp_limits = nothing,
         time_limits = nothing,
        base_power = 100.0,
        operation_cost = PSY.HydroGenerationCost(nothing),
        outflow_limits = nothing,
        powerhouse_elevation = 0.0,
        conversion_factor = 1.0,
    )

    ht_a2 = mk_turbine("Hydro_A2", b102)
    ht_b2 = mk_turbine("Hydro_B2_External", b202)
    PSY.add_components!(sys, [ht_a2, ht_b2])

    # Res_Main has 1 turbine in Area_A (ht_a2) and 1 split turbine in Area_B (ht_b2)
    res_main = PSY.HydroReservoir(
        name = "Res_Main_A",
        available = true,
        storage_level_limits = (min = 0.0, max = 1000.0),
        initial_level = 0.5,
        spillage_limits = nothing,
        inflow = 10.0,
        outflow = 5.0,
        level_targets = 0.5,
        intake_elevation = 100.0,
        head_to_volume_factor = IS.LinearCurve(1.0),
        upstream_turbines = PSY.HydroUnit[],
        downstream_turbines = PSY.HydroUnit[ht_a2, ht_b2],
        upstream_reservoirs = PSY.Device[],
    )

    # Res_Orphan is referenced via ext["plants"] to trigger candidate check, but has 0 retained turbines
    res_orphan = PSY.HydroReservoir(
        name = "Res_Orphan_B",
        available = true,
        storage_level_limits = (min = 0.0, max = 500.0),
        initial_level = 0.5,
        spillage_limits = nothing,
        inflow = 5.0,
        outflow = 2.0,
        level_targets = 0.5,
        intake_elevation = 50.0,
        head_to_volume_factor = IS.LinearCurve(1.0),
        upstream_turbines = PSY.HydroUnit[],
        downstream_turbines = PSY.HydroUnit[ht_b2],
        upstream_reservoirs = PSY.Device[],
        ext = Dict{String, Any}("plants" => ["Hydro_A2"]),
    )
    PSY.add_components!(sys, [res_main, res_orphan])

    # --- Reserve Service ---
    reg_up = PSY.VariableReserve{PSY.ReserveUp}("RegUp_AreaA", true, 5.0, 0.2)
    PSY.add_service!(sys, reg_up, [gen_a1, ht_a2])

    # --- StaticTimeSeries on Load_A3 and Res_Main_A ---
    dates = collect(
        Dates.DateTime("2026-01-01T00:00:00"):Dates.Hour(1):Dates.DateTime("2026-01-01T23:00:00")
    )
    ts_load = PSY.SingleTimeSeries("max_active_power", TimeSeries.TimeArray(dates, ones(24) .* 0.8))
    ts_res = PSY.SingleTimeSeries("inflow", TimeSeries.TimeArray(dates, ones(24) .* 10.0))
    PSY.add_time_series!(sys, load_a3, ts_load)
    PSY.add_time_series!(sys, res_main, ts_res)

    return sys
end

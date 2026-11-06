using Test
using PowerSystemExtractor

import PowerSystems as PSY
import InfrastructureSystems as IS

include("two_area_system.jl")

@testset verbose = true "PowerSystemExtractor.jl Test Suite" begin
    @test isdefined(Main, :PowerSystemExtractor)

    TEST_TMPDIR = mktempdir(cleanup = true)

    try
        main_sys = build_synthetic_two_area_system()

        log_path = joinpath(TEST_TMPDIR, "region_extraction.log")
        region_sys = PowerSystemExtractor.extract_region_system(
            main_sys;
            area_names = ["Area_A"],
            keep_only_largest_island = true,
            auto_include_1hop_bridges = true,
            min_island_size_to_bridge = 2,
            include_services = true,
            system_name = "Area_A_Carved",
            log_file = log_path,
        )

        output_path = joinpath(TEST_TMPDIR, "extracted_region.json")
        PSY.to_json(region_sys, output_path; pretty = true, force = true)
        reloaded_sys = PSY.System(output_path; runchecks = false)

        @testset verbose = true "PowerSystemExtractor.jl Unit Tests" begin
            # Verify expected topology counts:
            # - Physical buses retained: 101, 102, 103, 104, 105 + 1-hop bridge 201 (6 physical buses)
            # - 3W Star bus retained: 9001 (1 star bus) -> Total = 7 buses
            # - Isolated 1-bus pocket 106 and external 202 should NOT be in region_sys
            @test length(PSY.get_components(PSY.ACBus, region_sys)) == 7
            @test !isnothing(PSY.get_component(PSY.ACBus, region_sys, "Bus_B1_Bridge"))
            @test !isnothing(PSY.get_component(PSY.ACBus, region_sys, "Star_A_3W"))
            @test isnothing(PSY.get_component(PSY.ACBus, region_sys, "Bus_A6_Isolated"))
            @test isnothing(PSY.get_component(PSY.ACBus, region_sys, "Bus_B2_External"))
            @test isnothing(PSY.get_component(PSY.SwitchedAdmittance, region_sys, "Shunt_A6"))
            @test isnothing(PSY.get_component(PSY.StandardLoad, region_sys, "StdLoad_A6"))
        
            # Verify 3W transformer survived
            @test length(PSY.get_components(PSY.ThreeWindingTransformer, region_sys)) == 1
        
            # Verify HydroReservoir filtering:
            # - Res_Main_A should survive with ONLY 1 downstream turbine (Hydro_A2; Hydro_B2_External detached)
            # - Res_Orphan_B had 0 retained turbines and should be automatically dropped
            @test length(PSY.get_components(PSY.HydroReservoir, region_sys)) == 1
            cloned_res = PSY.get_component(PSY.HydroReservoir, region_sys, "Res_Main_A")
            @test !isnothing(cloned_res)
            @test length(PSY.get_downstream_turbines(cloned_res)) == 1
            @test PSY.get_name(first(PSY.get_downstream_turbines(cloned_res))) == "Hydro_A2"
            @test isnothing(PSY.get_component(PSY.HydroReservoir, region_sys, "Res_Orphan_B"))
        
            # Verify main_sys Res_Main_A was NOT mutated (still has 2 downstream turbines)
            orig_res = PSY.get_component(PSY.HydroReservoir, main_sys, "Res_Main_A")
            @test length(PSY.get_downstream_turbines(orig_res)) == 2
        
            # Verify Service migration
            @test !isnothing(PSY.get_component(PSY.VariableReserve{PSY.ReserveUp}, region_sys, "RegUp_AreaA"))
        
            # Verify structured log file tags were written
            @test isfile(log_path)
            log_text = read(log_path, String)
            @test occursin("[CUT_TIELINE]", log_text)
            @test occursin("[BRIDGE_CANDIDATE]", log_text)
            @test occursin("[BRIDGE_AUTO_HEAL]", log_text)
            @test occursin("[HYDRO_TOPOLOGY]", log_text)
            @test occursin("[SPLIT_DOWNSTREAM_TURBINES]", log_text)
            @test occursin("[DROPPED_ORPHAN_RESERVOIR]", log_text)
            @test occursin("[PRUNED_ISLAND_SUMMARY]", log_text)
            @test occursin("Other SwitchedAdmittance 'Shunt_A6' @ bus #106", log_text)
            @test occursin("Load StandardLoad 'StdLoad_A6' @ bus #106 (avail, max_p = 30.0 MW)", log_text)
        end
        
        @testset verbose = true "Supplemental Attributes Migration & Cloning" begin
            
            carved_bus = PSY.get_component(PSY.ACBus, region_sys, "Bus_A1")
            @test carved_bus !== nothing
            @test PSY.has_supplemental_attributes(carved_bus)
            
            geo_attrs = PSY.get_supplemental_attributes(IS.GeographicInfo, region_sys)
            @test length(geo_attrs) == 1
            carved_geo = first(geo_attrs)
            @test carved_geo.geo_json["coordinates"] == [-86.7816, 36.1627]
        
            # 2. Verify GeometricDistributionForcedOutage migrated to the carved generator
            carved_gen = PSY.get_component(PSY.ThermalStandard, region_sys, "Gen_A1")
            @test carved_gen !== nothing
            @test PSY.has_supplemental_attributes(carved_gen)
        
            outage_attrs = PSY.get_supplemental_attributes(PSY.GeometricDistributionForcedOutage, region_sys)
            @test length(outage_attrs) == 1
            carved_outage = first(outage_attrs)
            @test PSY.get_mean_time_to_recovery(carved_outage) == 24.0
            @test PSY.get_outage_transition_probability(carved_outage) == 0.01
        
            # 3. Verify main_sys was NOT mutated (shared_system_references untouched)
            orig_bus = PSY.get_component(PSY.ACBus, main_sys, "BusA")
            orig_geo = first(PSY.get_supplemental_attributes(IS.GeographicInfo, main_sys))
            @test IS.get_shared_system_references(orig_geo) !== nothing
            @test IS.get_shared_system_references(carved_geo) !== nothing
            @test IS.get_uuid(orig_geo) == IS.get_uuid(carved_geo) # UUID preserved
        end
        
        @testset verbose = true "Extracted System Integrity ($(PSY.get_name(region_sys)))" begin
        
            @testset verbose = true "In-memory SharedSystemReferences isolation" begin
                region_comps = collect(PSY.get_components(PSY.Component, region_sys))
                @test !isempty(region_comps)
        
                expected_ref = IS.get_shared_system_references(first(region_comps))
                @test !isnothing(expected_ref)
        
                leaked_region_comps = filter(region_comps) do comp
                    IS.get_shared_system_references(comp) !== expected_ref
                end
                @test isempty(leaked_region_comps)
        
                if !isnothing(main_sys)
                    main_comps = collect(PSY.get_components(PSY.Component, main_sys))
                    main_ref = IS.get_shared_system_references(first(main_comps))
                    @test expected_ref !== main_ref
        
                    mutated_main_comps = filter(main_comps) do comp
                        IS.get_shared_system_references(comp) !== main_ref
                    end
                    @test isempty(mutated_main_comps)
                end
            end
        
            @testset verbose = true "PowerSystems topology & component checks" begin
                @test isnothing(PSY.check(region_sys))
                @test isnothing(PSY.check_components(region_sys))
            end
        
            @testset verbose = true "Round-trip JSON/HDF5 serialization & deserialization" begin
                @test reloaded_sys isa PSY.System
                @test length(PSY.get_components(PSY.ACBus, reloaded_sys)) ==
                      length(PSY.get_components(PSY.ACBus, region_sys))
                @test length(PSY.get_components(PSY.Branch, reloaded_sys)) ==
                      length(PSY.get_components(PSY.Branch, region_sys))
                @test length(PSY.get_components(PSY.StaticInjection, reloaded_sys)) ==
                      length(PSY.get_components(PSY.StaticInjection, region_sys))
                @test length(PSY.get_components(PSY.HydroReservoir, reloaded_sys)) ==
                      length(PSY.get_components(PSY.HydroReservoir, region_sys))
            end
        
            @testset verbose = true "Deserialized HDF5 time-series read test" begin
                ts_verified = false
                for comp in PSY.get_components(PSY.has_time_series, PSY.Component, reloaded_sys)
                    keys = PSY.get_time_series_keys(comp)
                    if !isempty(keys)
                        ts = PSY.get_time_series(comp, first(keys))
                        @test !isempty(ts)
                        ts_verified = true
                        break
                    end
                end
                @test ts_verified
            end
        end
        
        @testset verbose = true "AreaInterchange Filtering (Connected vs. Orphaned)" begin
           
            @test !isnothing(PSY.get_component(PSY.AreaInterchange, region_sys, "Interchange_A_B"))
        
            sys_ai_test = build_synthetic_two_area_system()
            area_b_test = PSY.get_component(PSY.Area, sys_ai_test, "Area_B")
            area_c_test = PSY.Area("Area_C", 10.0, 0.0, 0.0)
            PSY.add_component!(sys_ai_test, area_c_test)
        
            # Reassign Bus_A3 (connected only to Star_A_3W in Area_A) to Area_C
            b103_test = PSY.get_component(PSY.ACBus, sys_ai_test, "Bus_A3")
            PSY.set_area!(b103_test, area_c_test)
        
            # Valid AreaInterchange (Area_A <-> Area_C, connected via Tx3W_AreaA)
            ai_ac_valid = PSY.AreaInterchange(
                name = "Interchange_A_C_Valid",
                available = true,
                active_power_flow = 0.0,
                from_area = PSY.get_component(PSY.Area, sys_ai_test, "Area_A"),
                to_area = area_c_test,
                flow_limits = (from_to = 1.5, to_from = 1.5),
            )
            # Orphaned AreaInterchange (Area_B <-> Area_C: both areas in region_sys, 0 direct ACBranches)
            ai_bc_orphan = PSY.AreaInterchange(
                name = "Interchange_B_C_Orphan",
                available = true,
                active_power_flow = 0.0,
                from_area = area_b_test,
                to_area = area_c_test,
                flow_limits = (from_to = 1.0, to_from = 1.0),
            )
            PSY.add_components!(sys_ai_test, [ai_ac_valid, ai_bc_orphan])
        
            ai_log_path = joinpath(TEST_TMPDIR, "ai_extraction.log")
            carved_ai_sys = PowerSystemExtractor.extract_region_system(
                sys_ai_test;
                area_names = ["Area_A", "Area_C"],
                keep_only_largest_island = true,
                auto_include_1hop_bridges = true,
                log_file = ai_log_path,
            )
        
            # Area_A, Area_B (via bridge), and Area_C are all in carved_ai_sys
            @test length(PSY.get_components(PSY.Area, carved_ai_sys)) == 3
            # Area_A <-> Area_B and Area_A <-> Area_C have physical ACBranches (including 3WT!) -> Retained
            @test !isnothing(PSY.get_component(PSY.AreaInterchange, carved_ai_sys, "Interchange_A_B"))
            @test !isnothing(PSY.get_component(PSY.AreaInterchange, carved_ai_sys, "Interchange_A_C_Valid"))
            # Area_B <-> Area_C has 0 connecting ACBranches -> Dropped!
            @test isnothing(PSY.get_component(PSY.AreaInterchange, carved_ai_sys, "Interchange_B_C_Orphan"))
        
            ai_log_text = read(ai_log_path, String)
            @test occursin("[DROPPED_AREA_INTERCHANGE]", ai_log_text)
            @test occursin("Interchange_B_C_Orphan", ai_log_text)
        end
        
        @testset verbose = true "Service Threshold Filtering & TransmissionInterface Cleanup" begin
            sys_srv_test = build_synthetic_two_area_system()
        
            # Grab existing buses and branches
            b202_ext = PSY.get_component(PSY.ACBus, sys_srv_test, "Bus_B2_External")
            gen_a1   = PSY.get_component(PSY.ThermalStandard, sys_srv_test, "Gen_A1")
            line_a4_a5 = PSY.get_component(PSY.Line, sys_srv_test, "Line_A4_A5")
            tie_a2_b1  = PSY.get_component(PSY.Line, sys_srv_test, "Tie_A2_B1")
            line_b1_b2 = PSY.get_component(PSY.Line, sys_srv_test, "Line_B1_B2")
        
            # Add 2 external thermal generators on Bus_B2_External (which is outside the carved region)
            gen_b2_1 = PSY.ThermalStandard(
                name = "Gen_B2_Ext1",
                available = true,
                status = true,
                bus = b202_ext,
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
            gen_b2_2 = PSY.ThermalStandard(
                name = "Gen_B2_Ext2",
                available = true,
                status = true,
                bus = b202_ext,
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
            PSY.add_components!(sys_srv_test, [gen_b2_1, gen_b2_2])
        
            # Reserve with 1 in-region gen and 2 external gens (1/3 = 33.3% kept)
            wide_res = PSY.VariableReserve{PSY.ReserveUp}("WideArea_RegUp", true, 5.0, 0.5)
            PSY.add_service!(sys_srv_test, wide_res, [gen_a1, gen_b2_1, gen_b2_2])
        
            # 2. TransmissionInterface with 2 in-region lines and 1 external line (2/3 = 66.7% kept)
            tx_iface = PSY.TransmissionInterface(
                name = "Corridor_Interface",
                available = true,
                active_power_flow_limits = (min = -3.0, max = 3.0),
                violation_penalty = 1000.0,
                direction_mapping = Dict(
                    "Line_A4_A5" => 1,
                    "Tie_A2_B1"  => 1,
                    "Line_B1_B2" => -1, # External line (not in region_sys)
                ),
            )
            PSY.add_service!(sys_srv_test, tx_iface, [line_a4_a5, tie_a2_b1, line_b1_b2])
        
            # Extract with min_service_device_fraction = 0.5:
            srv_log_path = joinpath(TEST_TMPDIR, "srv_extraction.log")
            carved_srv_sys = PowerSystemExtractor.extract_region_system(
                sys_srv_test;
                area_names = ["Area_A"],
                keep_only_largest_island = true,
                auto_include_1hop_bridges = true,
                include_services = true,
                min_service_device_fraction = 0.5,
                log_file = srv_log_path,
            )
        
             # - WideArea_RegUp (33.3% < 50%) should be DROPPED
            @test isnothing(PSY.get_component(PSY.VariableReserve{PSY.ReserveUp}, carved_srv_sys, "WideArea_RegUp"))
           
            # - RegUp_AreaA (100% >= 50%) should be RETAINED
            @test !isnothing(PSY.get_component(PSY.VariableReserve{PSY.ReserveUp}, carved_srv_sys, "RegUp_AreaA"))
        
             # - Corridor_Interface (66.7% >= 50%) should be RETAINED with cleaned direction_mapping
            carved_iface = PSY.get_component(PSY.TransmissionInterface, carved_srv_sys, "Corridor_Interface")
            @test !isnothing(carved_iface)
            dir_map = PSY.get_direction_mapping(carved_iface)
            @test length(dir_map) == 2
            @test haskey(dir_map, "Line_A4_A5") && haskey(dir_map, "Tie_A2_B1")
            @test !haskey(dir_map, "Line_B1_B2")
        
            # Verify parent system's TransmissionInterface direction_mapping was NOT mutated
            @test length(PSY.get_direction_mapping(tx_iface)) == 3
        
            srv_log_text = read(srv_log_path, String)
            @test occursin("[SERVICE_TOPOLOGY]", srv_log_text)
            @test occursin("[DROPPED_SPLIT_SERVICE]", srv_log_text)
            @test occursin("WideArea_RegUp", srv_log_text)
            @test occursin("[SPLIT_SERVICE]", srv_log_text)
            @test occursin("Corridor_Interface", srv_log_text)
        end
    finally
        rm(TEST_TMPDIR; recursive = true, force = true)
    end
end


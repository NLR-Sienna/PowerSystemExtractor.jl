using Test
using PowerSystemExtractor

import PowerSystems as PSY
import InfrastructureSystems as IS


@test isdefined(Main, :PowerSystemExtractor)

const TEST_TMPDIR = mktempdir(cleanup = true) 

EI_sys = PSY.System(
    "/Users/sdhulipa/Old Mac Backup/Desktop/OneDrive-Backup/Projects/PACES/EI-PSY5/EI_sys_L2035_W2012_area_agg.json";
    runchecks = false,
);
PSY.set_units_base_system!(EI_sys, PSY.UnitSystem.SYSTEM_BASE)

# Extract region system
log_path = joinpath(TEST_TMPDIR, "region_extraction.log")
region_sys = PowerSystemExtractor.extract_region_system(
    EI_sys;
    area_names = ["TVA"],
    keep_only_largest_island = true,
    auto_include_1hop_bridges = true,
    min_island_size_to_bridge = 1,
    include_services = true,
    fallback_bus_ext_reserves = false,
    log_file = log_path,);

output_path = joinpath(TEST_TMPDIR, "extracted_region.json")
PSY.to_json(region_sys, output_path; pretty = true, force = true)


reloaded_sys = PSY.System(output_path; runchecks = false);

@testset "Extracted region system verification" begin
    @test reloaded_sys isa PSY.System
    @test PSY.get_name(reloaded_sys) == PSY.get_name(region_sys)
    @test length(PSY.get_components(PSY.Component, reloaded_sys)) == length(PSY.get_components(PSY.Component, region_sys))
    @test length(PSY.get_components(PSY.has_time_series, PSY.Component, reloaded_sys)) == length(PSY.get_components(PSY.has_time_series, PSY.Component, region_sys))

    @test length(PSY.get_components(PSY.ACBus, reloaded_sys)) ==
                  length(PSY.get_components(PSY.ACBus, region_sys))
    @test length(PSY.get_components(PSY.Branch, reloaded_sys)) ==
            length(PSY.get_components(PSY.Branch, region_sys))
    @test length(PSY.get_components(PSY.StaticInjection, reloaded_sys)) ==
            length(PSY.get_components(PSY.StaticInjection, region_sys))
    @test length(PSY.get_components(PSY.HydroReservoir, reloaded_sys)) ==
            length(PSY.get_components(PSY.HydroReservoir, region_sys))
end

@testset "PowerSystemExtractor.jl Unit Tests" begin
    main_sys = build_synthetic_two_area_system()

    mktempdir() do tmpdir
        log_path = joinpath(tmpdir, "test_extraction.log")

        # 1. Extract Area_A with 1-hop bridge auto-healing & island pruning enabled
        region_sys = extract_region_system(
            main_sys;
            area_names = ["Area_A"],
            keep_only_largest_island = true,
            auto_include_1hop_bridges = true,
            min_island_size_to_bridge = 2,
            include_services = true,
            system_name = "Area_A_Carved",
            log_file = log_path,
        )

        # Verify expected topology counts:
        # - Physical buses retained: 101, 102, 103, 104, 105 + 1-hop bridge 201 (6 physical buses)
        # - 3W Star bus retained: 9001 (1 star bus) -> Total = 7 buses
        # - Isolated 1-bus pocket 106 and external 202 should NOT be in region_sys
        @test length(PSY.get_components(PSY.ACBus, region_sys)) == 7
        @test !isnothing(PSY.get_component(PSY.ACBus, region_sys, "Bus_B1_Bridge"))
        @test !isnothing(PSY.get_component(PSY.ACBus, region_sys, "Star_A_3W"))
        @test isnothing(PSY.get_component(PSY.ACBus, region_sys, "Bus_A6_Isolated"))
        @test isnothing(PSY.get_component(PSY.ACBus, region_sys, "Bus_B2_External"))

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

        # 2. Run the 4-stage integrity & round-trip serialization suite
        test_extracted_system_integrity(
            region_sys;
            main_sys = main_sys,
            runchecks = true,
            expect_time_series = true,
        )

        # 3. Test the JSON file path dispatch method for extract_region_system
        master_json = joinpath(tmpdir, "master_two_area.json")
        PSY.to_json(main_sys, master_json; pretty = false, force = true)
        region_from_json = extract_region_system(
            master_json;
            area_names = ["Area_A"],
            keep_only_largest_island = true,
            auto_include_1hop_bridges = true,
        )
        @test length(PSY.get_components(PSY.ACBus, region_from_json)) == 7
    end
end


@testset "Extracted System Integrity ($(PSY.get_name(region_sys)))" begin

    @testset "1. In-memory SharedSystemReferences isolation" begin
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

    @testset "2. PowerSystems topology & component checks" begin
        @test isnothing(PSY.check(region_sys))
        @test isnothing(PSY.check_components(region_sys))
    end

    @testset "3. Round-trip JSON/HDF5 serialization & deserialization" begin
        reloaded_sys = if !isnothing(json_path) && isfile(json_path)
            PSY.System(json_path; runchecks = runchecks)
        else
            mktempdir() do tmpdir
                tmp_json = joinpath(tmpdir, "test_region_sys.json")
                PSY.to_json(region_sys, tmp_json; pretty = false, force = true)
                @test isfile(tmp_json)
                PSY.System(tmp_json; runchecks = runchecks)
            end
        end

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

    @testset "4. Deserialized HDF5 time-series read test" begin
        if expect_time_series
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
        else
            @test isempty(PSY.get_components(PSY.has_time_series, PSY.Component, reloaded_sys))
        end
    end
end


rm(TEST_TMPDIR; recursive = true, force = true)






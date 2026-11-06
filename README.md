# PowerSystemExtractor.jl

`PowerSystemExtractor.jl` is a high-performance Julia package designed to carve out self-consistent, simulation-ready regional sub-systems from large-scale power interconnect models (`PowerSystems.System`) by interconnect `Area` and custom bus lists. It preserves topological integrity, time-series data, regional services, `AreaInterchange` components, and `SupplementalAttribute` records without mutating the parent `PowerSystems.System`.

## Key Features

* **Topological Connectivity & Island Management:** Leverages `PowerNetworkMatrices.jl` (`PNM`) to validate subnetwork connectivity, automatically accounting for zero-impedance station jumpers (reduced_map) and pruning isolated secondary islands.
* **1-Hop Bridge Auto-Healing:** Automatically identifies regional loops extending into neighbor substations and pulls in necessary external boundary bridge buses.
* **3-Winding Transformer Support:** Properly tracks and retains internal star buses and arcs across transformations.
* **AreaInterchange Validation:** Retains inter-area flow interfaces (`AreaInterchange`) only when both areas exist in the carved system and are physically connected by at least one available `ACBranch`.
* **Service & Interface Migration:** Audits and migrates `Reserve`, `AGC`, and `TransmissionInterface` services, automatically pruning external branches from `TransmissionInterface` `direction_mapping` dictionaries and filtering boundary-spanning services via `min_service_device_fraction`.
* **Supplemental Attribute Migration:** Audits, clones, and migrates `SupplementalAttribute` records (such as `GeographicInfo`, `EmissionsData`, `ImpedanceCorrectionData`, and forced outage models like `GeometricDistributionForcedOutage`) along with attached time series.
* **Hydro Topology Auditing:** Re-links hydro reservoir/turbine hierarchies, logs split turbine memberships, and drops orphaned reservoirs.
* **Structured Audit Logging:** Tees diagnostic logs to both the console and file streams via `InfrastructureSystems.MultiLogger`.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/NLR-Sienna/PowerSystemExtractor.jl")
```

## Quickstart Usage

```julia
using PowerSystems
using PowerSystemExtractor

# Load your parent interconnect system (e.g., Eastern Interconnect / MMWG)
main_sys = PSY.System("path/to/main_system.json"; runchecks = false)

# Extract the TVA regional system
region_sys = extract_region_system(
    main_sys;
    area_names = ["TVA"],
    extra_bus_numbers = [360185], # Optional out-of-area boundary buses to include
    keep_only_largest_island = true,
    auto_include_1hop_bridges = true,
    include_services = true,
    min_service_device_fraction = 0.5,
    log_file = "TVA_extraction.log",
)
```

## Keyword Arguments (`extract_region_system`)

| Keyword | Default | Description |
| :--- | :--- | :--- |
| `area_names` | *(Required)* | Interconnect area names (`Vector{String}`) to carve out from the parent model (e.g., `["TVA"]`). |
| `extra_bus_numbers` | `Int[]` | Specific out-of-area bus numbers (`Vector{Int}`) to force-include in the regional system. |
| `extra_bus_names` | `String[]` | Specific out-of-area bus names (`Vector{String}`) to force-include in the regional system. |
| `keep_only_largest_island` | `true` | Automatically prune disconnected secondary subnetworks or 1-bus pockets (`Bool`). |
| `auto_include_1hop_bridges` | `true` | Automatically include 1-hop external boundary bridge buses (`Bool`) when a regional pocket loops through a neighbor's substation. |
| `min_island_size_to_bridge` | `2` | Minimum physical bus count (`Int`) of a secondary island required to trigger 1-hop bridge auto-healing. |
| `include_services` | `true` | Migrate regional `Service` and reserve definitions (`Bool`) attached to surviving in-region devices. |
| `min_service_device_fraction` | `0.0` | Minimum fraction (`Float64` in `[0.0, 1.0]`) of a service's original contributing devices that must survive in `region_sys` for the service to be retained. |
| `fallback_bus_ext_reserves` | `false` | Fallback handling for bus-level external reserves (`Bool`) during service migration. |
| `strict_contingencies` | `false` | Controls whether boundary-spanning multi-element contingencies are dropped entirely (`true`) or trimmed to in-region components (`false`). |
| `system_name` | Generated | Name assigned (`String`) to the extracted regional `PSY.System`. |
| `log_file` | `nothing` | Optional file path (`String`) to tee all console logs, warnings, and diagnostics using `InfrastructureSystems.MultiLogger`. |
| `warn_tielines` | `true` | Controls whether cut boundary tie-lines trigger console warnings (`Bool`) during initial classification. |

## Greppable Audit & Diagnostic Tags

* **`[CUT_TIELINE]`**: Lists every severed branch across the regional boundary.
* **`[BRIDGE_CANDIDATE]`**: Identifies external substations touching $\ge 2$ cut tie-lines (potential 1-hop loop/bridge candidates).
* **`[BRIDGE_AUTO_HEAL]`**: Logs when 1-hop external bridge buses are automatically pulled in to reconnect split regional corridors.
* **`[ISLAND]`**: Details secondary disconnected subnetworks and the specific cut tie-lines touching them.
* **`[PRUNED_ISLAND_SUMMARY]` / `[PRUNED_ISLAND]` / `[PRUNED_INJECTION]`**: Audits all buses, branches, and active power injections/withdrawals (MW) dropped when secondary islands are pruned.
* **`[SLACK_BUS]`**: Logs when no `REF`/`SLACK` bus exists in the carved region and the highest-voltage `PV` bus is promoted to `REF`.
* **`[AREA_INTERCHANGE_TOPOLOGY]` / `[DROPPED_AREA_INTERCHANGE]`**: Logs `AreaInterchange` components dropped because no available physical `ACBranch` connects their `from_area` and `to_area` in the extracted system.
* **`[HYDRO_TOPOLOGY]`**: Audits `HydroReservoir` and `HydroUnit` memberships, warning on split turbine memberships (`[SPLIT_UPSTREAM_TURBINES]`, `[SPLIT_DOWNSTREAM_TURBINES]`, `[MISSING_UPSTREAM_RESERVOIR]`, `[TURBINE_MISSING_RESERVOIR]`) and automatically dropping orphaned reservoirs with 0 retained turbines (`[DROPPED_ORPHAN_RESERVOIR]`).
* **`[SERVICE_TOPOLOGY]` / `[SPLIT_SERVICE]` / `[DROPPED_SPLIT_SERVICE]`**: Audits boundary-spanning `Service`s (`Reserve`, `TransmissionInterface`, `AGC`), logging services trimmed to in-region devices or dropped when their device survival ratio falls below `min_service_device_fraction`.
* **`[SUPPLEMENTAL_ATTRIBUTE_TOPOLOGY]`**: Summary grouping log detailing boundary-spanning `SupplementalAttribute` records that were trimmed or dropped during migration.
* **`[SPLIT_SUPPLEMENTAL_ATTRIBUTE]`**: Logs `SupplementalAttribute` instances (such as multi-unit `PowerPlant` aggregators or shared outage models) that span the regional boundary and were trimmed to include only surviving in-region components.
* **`[DROPPED_SPLIT_CONTINGENCY]`**: Logs boundary-spanning multi-element `Contingency` definitions that were dropped entirely when `strict_contingencies = true`.

## TODO / Future Enhancements

* **`monitored_components` Migration:** Support cloning `GeometricDistributionForcedOutage` SupplementalAttribute and re-linking their `monitored_components` vectors to surviving migrated regional branches.
* **`ConstantReserveGroup` Migration:** Support cloning `ConstantReserveGroup` services and re-linking their `contributing_services` vectors to surviving migrated regional services.
* **Proportional Scaling for Split Services:** Optional capability to scale `Reserve` requirements (`requirement` / time series) or `TransmissionInterface` flow limits proportionally to the retained MW capacity/rating of surviving contributing devices when a wide-area service is split across the boundary.
* **Boundary Tie-Line Equivalencing (Ward / Static Injections):** Optional mode to convert severed `[CUT_TIELINE]` branches into equivalent boundary power injections/withdrawals (`FixedAdmittance` or scheduled `PowerLoad`/`Source`) based on solved power flow flows.
* **`StaticInjectionSubsystem` & Dynamic Component Support:** Support re-attaching dynamic injectors (`DynamicInverter`, `DynamicGenerator`) and composite `StaticInjectionSubsystem` wrappers when extracting dynamic simulation models.

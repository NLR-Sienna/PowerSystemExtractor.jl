# PowerSystemExtractor.jl

`PowerSystemExtractor.jl` is a robust, non-mutating regional subnetwork extraction tool built for **PowerSystems.jl (PSY) 5.0**. It allows you to carve self-consistent regional models (such as TVA, PJM, or MISO) out of massive interconnect datasets (like the EI, WECC, etc.) while handling 3-winding transformers, area interchanges, services, hydro reservoir topologies, and time-series migration.

---

## Installation

To install the package locally during development:

```julia
using Pkg
Pkg.develop(path = "/path/to/PowerSystemExtractor.jl")

```

---

## Quick Start & Usage

```julia
using PowerSystemExtractor
import PowerSystems as PSY
import Dates

# Extract a regional system directly from a master system JSON file path
region_sys = extract_region_system(
    "/path/to/EI_sys_master.json";
    area_names = ["TVA"],
    extra_bus_numbers = Int[300101, 300105], # Optional extra boundary/backbone buses
    keep_only_largest_island = true,         # Prunes disconnected boundary pockets
    auto_include_1hop_bridges = true,        # Auto-heals split regional corridors
    include_services = true,                 # Migrates reserves and AGC services
    system_name = "TVA_Carved_System",
    log_file = "TVA_extraction.log",         # Tees all diagnostics to a log file
)
```

---

## Arguments Reference

### Positional Arguments

| Argument | Type | Description |
| --- | --- | --- |
| `system_or_path` | `PSY.System` or `AbstractString` | Either an in-memory master `PSY.System` instance or a file path (`.json`) to the master system on disk. |

### Keyword Arguments

| Keyword Argument | Default | Description |
| --- | --- | --- |
| `area_names` | *(Required)* | `Vector{String}` of `PSY.Area` names to carve out (e.g., `["TVA"]`). |
| `extra_bus_numbers` | `Int[]` | Explicit list of non-regional bus numbers to include alongside `area_names`. |
| `extra_bus_names` | `String[]` | Explicit list of non-regional bus names to include alongside `area_names`. |
| `keep_only_largest_island` | `true` | Uses `PNM.find_subnetworks` to prune smaller disconnected secondary subnetworks and orphaned `Area`/`LoadZone` objects. |
| `auto_include_1hop_bridges` | `true` | Cross-references subnetwork connectivity and cut tie-lines to automatically pull in 1-hop external bridging substations. |
| `min_island_size_to_bridge` | `2` | Minimum bus count of a secondary island required to trigger 1-hop bridge auto-healing. |
| `include_services` | `true` | Clones `Reserve`, `TransmissionInterface`, and `AGC` services attached to surviving regional devices, along with their time series. |
| `fallback_bus_ext_reserves` | `false` | Fallback matching for legacy systems where `Reserve` objects are unattached in the master system and matched via `bus.ext["region"]`. |
| `system_name` | `"<Areas>_Carved_System"` | Name assigned to the newly created regional `PSY.System`. |
| `log_file` | `nothing` | Optional file path (`String`) to tee all console logs, warnings, and diagnostics using `InfrastructureSystems.MultiLogger`. |

---

## Greppable Diagnostic Tags

When `log_file` is specified, all boundary cuts, topological warnings, and hydro reservoir audits are tagged for easy `grep` inspection:

* **`[CUT_TIELINE]`**: Lists every severed branch across the regional boundary.
* **`[BRIDGE_CANDIDATE]`**: Identifies external substations touching $\ge 2$ cut tie-lines (potential 1-hop loop/bridge candidates).
* **`[BRIDGE_AUTO_HEAL]`**: Logs when 1-hop external bridge buses are automatically pulled in to reconnect split regional corridors.
* **`[ISLAND]`**: Details secondary disconnected subnetworks and the specific cut tie-lines touching them.
* **`[HYDRO_TOPOLOGY]`**: Audits `HydroReservoir` and `HydroUnit` memberships, warning on split turbine memberships and automatically dropping orphaned reservoirs with 0 retained turbines.

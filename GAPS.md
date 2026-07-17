# Powsybl.jl vs pypowsybl — feature gap analysis & roadmap

This document inventories what Powsybl.jl currently exposes, compares it with the
feature set offered by [pypowsybl](https://github.com/powsybl/pypowsybl), and lays out
a concrete, prioritized plan for closing the gaps.

## Key architectural fact

Powsybl.jl and pypowsybl are **both thin language bindings over the exact same C++
layer**, `powsybl-cpp` (which itself drives the PowSyBl Java core through GraalVM).
`build_local.jl` compiles `powsybl-cpp` from the pinned pypowsybl commit and links our
Julia wrapper (`cpp/powsybljl-cpp/powsybl_jl.cpp`) against it.

**Consequence:** every feature pypowsybl has is already reachable from Julia. Nothing
needs to be reimplemented in Java or C++ — closing a gap means adding a small wrapper
method in `powsybl_jl.cpp` (mirroring the ~200 functions already declared in
`powsybl-cpp.h`) plus an ergonomic Julia function. The dev CI
(`.github/workflows/dev-ci.yml`) rebuilds `Powsybl_jll` from the local `cpp/` source on
every branch push, so wrapper additions are validated end-to-end by CI.

## Coverage snapshot

The `powsybl-cpp` C API exposes ~200 functions. Before this work Powsybl.jl wrapped
about **11** of them. Coverage by feature area:

| Feature area | pypowsybl | Powsybl.jl (before) | Powsybl.jl (now) |
| --- | :---: | :---: | :---: |
| Load network (files/formats) | ✅ | ✅ | ✅ |
| Load network from string | ✅ | ❌ | ❌ |
| Save network (files/formats) | ✅ | ✅ | ✅ |
| Save network to string | ✅ | ❌ | ❌ |
| Import/export **parameter metadata** | ✅ | ❌ | ✅ |
| Import supported extensions | ✅ | ❌ | ✅ |
| Read elements → dataframe | ✅ | ✅ | ✅ |
| Read extensions → dataframe | ✅ | ✅ | ✅ |
| **Create** elements | ✅ | ❌ | ❌ |
| **Update** elements | ✅ | ❌ | ❌ |
| **Remove** elements | ✅ | ❌ | ✅ |
| Update switch / connectable status | ✅ | ❌ | ✅ |
| Element id queries + filtering | ✅ | ❌ | ✅ |
| Node/breaker & bus/breaker views | ✅ | ❌ | ✅ |
| **Variants** (clone/set/remove/list) | ✅ | ❌ | ✅ |
| Create/update/remove extensions | ✅ | partial (read) | partial (read) |
| Custom properties / aliases | ✅ | ❌ | ❌ |
| Merge / detach / reduce networks | ✅ | ❌ | ❌ |
| Validation level control | ✅ | ❌ | ❌ |
| Load flow (AC/DC) | ✅ | ✅ | ✅ |
| Load flow provider selection / defaults | ✅ | partial | partial |
| Load flow validation | ✅ | ❌ | ❌ |
| LF parameters ↔ JSON | ✅ | ❌ | ❌ |
| **Security analysis** | ✅ | ❌ | ❌ |
| **Sensitivity analysis** | ✅ | ❌ | ❌ |
| Short-circuit analysis | ✅ | ❌ | ❌ |
| Dynamic simulation | ✅ | ❌ | ❌ |
| Flow decomposition | ✅ | ❌ | ❌ |
| Single-line diagram (SVG) | ✅ | ❌ | ❌ |
| Network-area diagram (SVG) | ✅ | ❌ | ❌ |
| Voltage initializer (OpenReac) | ✅ | ❌ | ❌ |
| RAO (OpenRAO) | ✅ | ❌ | ❌ |
| GLSK | ✅ | ❌ | ❌ |
| Grid2op backend | ✅ | ❌ | ❌ |
| Per-unit view | ✅ | partial (globals) | partial |
| Reporting / ReportNode | ✅ | ❌ | ❌ |

## What this change set adds (the "easy wins")

These were selected because they are low-risk (they mirror wrapper patterns already
proven in `powsybl_jl.cpp`), directly improve *IIDM network handling* — the area the
request called out first — and require no new result-struct marshalling:

- **Import/export format metadata** — `get_import_parameters`, `get_export_parameters`,
  `get_network_import_supported_extensions`. Lets users discover the parameters each
  format accepts (previously the README pointed to external docs only).
- **Variant management** — `get_variants_ids`, `get_working_variant_id`,
  `clone_variant`, `set_working_variant`, `remove_variant`. Foundation for running
  multiple study cases (contingencies, what-ifs) on one network.
- **Network mutation** — `remove_elements`, `update_switch_position`,
  `update_connectable_status`. First write access to the grid model.
- **Element id queries** — `get_elements_ids` with nominal-voltage / country /
  component filtering.
- **Topology views** — node/breaker (`get_node_breaker_view_nodes` / `_switches` /
  `_internal_connections`) and bus/breaker (`get_bus_breaker_view_buses` / `_switches`
  / `_elements`). Core to inspecting substation-level IIDM topology.
- **Version reporting** — `Powsybl.get_version_table()` (the C++ binding already
  existed but was never surfaced).

## Roadmap for the remaining gaps (prioritized)

Ordered by value-to-effort. Each item lists the underlying `powsybl-cpp` functions to
wrap.

### 1. Full element write access (create/update) — *high value, medium effort*
Wrap `updateNetworkElementsWithSeries`, `createElement`,
`getNetworkDataframeMetadata`, `getNetworkElementCreationDataframesMetadata`. The
effort here is marshalling a Julia `DataFrame` into the C `dataframe` struct (arrays of
`series`) — the inverse of the existing `create_dataframe_from_series_array`. Once this
helper exists, element creation/update *and* extension create/update come almost for
free. This is the single most impactful next step: it turns Powsybl.jl from a
read-mostly viewer into a network editor.

### 2. Security analysis — *high value, medium effort (explicitly requested)*
Wrap `createSecurityAnalysis`, `addContingency`, `addMonitoredElements`,
`createSecurityAnalysisParameters`, `runSecurityAnalysis`, and the result getters
(`getPreContingencyResult`, `getPostContingencyResults`, `getLimitViolations`,
`getBranchResults`, `getBusResults`, ...). Pattern: the analysis context is a
`JavaHandle`; results come back as arrays that convert to DataFrames much like the load
flow results already do. A `SecurityAnalysis` submodule mirroring `LoadFlow.jl` is the
natural home.

### 3. Sensitivity analysis — *high value, medium effort*
Wrap `createSensitivityAnalysis`, `addFactorMatrix`, `setZones`,
`runSensitivityAnalysis`, `getSensitivityMatrix`, `getReferenceMatrix`. Returns
matrices rather than DataFrames — a thin `Matrix{Float64}` conversion is needed.

### 4. Single-line & network-area diagrams — *high visibility, low/medium effort*
Wrap `writeSingleLineDiagramSvg` / `getSingleLineDiagramSvg` and
`writeNetworkAreaDiagramSvg` / `getNetworkAreaDiagramSvg` (+ their `*Parameters`
constructors). Mostly string/file I/O, so low marshalling risk; produces SVGs that are
easy to display in Pluto/IJulia notebooks.

### 5. Per-unit view ergonomics — *low effort*
`Network.per_unit` / `Network.nominal_apparent_power` are module globals with no public
setter. Add `set_per_unit(::Bool)` / `set_nominal_apparent_power(::Float64)` +
getters (pure Julia, no C++). Note: the argument names of the
`create_network_elements_series_array` C++ lambda are transposed relative to their
meaning (the values still flow correctly) — worth renaming for clarity when this area
is touched.

### 6. Network composition — *medium effort*
`merge`, `getSubNetwork`, `detachSubNetwork`, `reduceNetwork`.

### 7. Short-circuit, dynamic simulation, flow decomposition, OpenReac, RAO, GLSK,
Grid2op — *specialised, larger efforts*
Each follows the same context-handle → run → result-getters shape as security
analysis. Prioritize by user demand.

### Cross-cutting
- **Reporting** (`createReportNode`, `printReport`, `jsonReport`) threads through most
  analyses; add it alongside item 1/2 so diagnostics can be captured.
- **LF parameters ↔ JSON** (`createLoadFlowParametersFromJson`,
  `writeLoadFlowParametersToJson`) is a quick, self-contained add.
- A reusable **Julia `DataFrame` → C `dataframe`** marshaller unlocks items 1, and the
  create/update paths of extensions and analyses — build it once, reuse everywhere.

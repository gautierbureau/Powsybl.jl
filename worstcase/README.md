# PowsyblWorstCase

Worst-case (robust) security analysis of a power grid on a **DC network model**, built on the
Powsybl.jl APIs with JuMP + HiGHS. It answers, for a *fixed* preventive dispatch:

> under the **worst** realisation of injection uncertainty, can **corrective** control keep every
> monitored branch within its limit — across the base state and each N-1 contingency?

This is the *feasibility oracle* (the medial-level program) of the three-level worst-case
formulation for power grids. It sits on top of the DC power-flow model (the same θ-formulation
as [`PowsyblDcOpf`](../dcopf)) and, conceptually, is the min-max separation that the
[`SemiInfinite`](../sip) solvers use — specialised here to the grid.

## What it computes

```
φ = max_{v ∈ V}  min_{u_c ∈ U_c}  max_{(e, s)}  ( |P_{e,s}(v, u_c)| / P̂_{e,s} − 1 )
```

* `v` — injection deviations at the uncertain buses (within a box `V`)
* `u_c` — corrective phase-shifting-transformer angles (within their range `U_c`)
* the inner `max` — the worst per-unit overload over every monitored branch `e` and state `s`
  (base **N** plus each **N-1** contingency)

The grid is **secure** iff `φ ≤ 0`: for *every* uncertainty there *exists* a corrective response
keeping all flows within limits. `φ > 0` is the residual overload that even the best correction
cannot remove — and the oracle returns the worst-case injection `v*` that causes it.

## How

`φ` is a saddle (min-max), solved by Falk–Hoffman-style discretization: a mixed-integer
**relaxed medial** problem (the uncertainty maximises the worst overload against a growing menu
of corrective candidates, with a binary picking the binding branch) alternates with a linear
**corrective-response** problem (the correctives minimise the worst overload for the current
worst uncertainty), until the bounds meet.

## Usage

```julia
using PowsyblWorstCase

sol = worst_case_oracle(network;
    uncertain    = Dict("VL3_0" => (-100.0, 0.0)),   # ±injection-deviation box per bus (MW)
    monitored    = Dict("L12a" => 110.0),            # branch => limit (MW)
    correctives  = ["PST_T"],                        # PSTs usable as corrective control
    contingencies = ["L1_2a"],                       # extra N-1 states (base N always included)
)

sol.phi     # worst achievable overload (> 0 ⇒ insecure)
sol.secure  # φ ≤ tol
sol.worst_injection  # the worst-case v*
sol.corrective       # the best corrective PST angles for v* (rad)
```

## Scope (first slice)

Uncertainty = injection deviations; correctives = **continuous PST angles**; states =
base + single-branch N-1 outages. Deferred: the integer-mode PST/HVDC models, topology
switching (bus splitting), redispatch/participation-factor balancing, and the outer
flexibility-maximisation objective (which turns this oracle into the full three-level program).

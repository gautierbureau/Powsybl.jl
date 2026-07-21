# PowsyblWorstCase

Worst-case (robust) security analysis of a power grid on a **DC network model**, built on the
Powsybl.jl APIs with JuMP + HiGHS. It answers, for a *fixed* preventive dispatch:

> under the **worst** realisation of injection uncertainty, can **corrective** control keep every
> monitored branch within its limit — across the base state and each N-1 contingency?

This is the *feasibility oracle* (the medial-level program) of the three-level worst-case
formulation for power grids. It sits on top of the DC power-flow model (the same θ-formulation
as [`PowsyblDcOpf`](../dcopf)) and, conceptually, is the min-max separation that the
[`SemiInfinite`](../sip) solvers use — specialised here to the grid.

## The four states

The model distinguishes the four operating states of the reference formulation, which is what
makes the preventive/corrective distinction meaningful:

| State | uncertainty | contingency | PST angle |
|---|---|---|---|
| **0** nominal | — | — | preventive `α⁰` |
| **N** base | ✓ | — | preventive `α⁰` |
| **N-1** post-contingency | ✓ | ✓ | preventive `α⁰` (no correction yet) |
| **N-1/c** post-corrective | ✓ | ✓ | **corrective** `α` |

Corrective control acts **only in the post-corrective state**, and is **per-contingency
recourse** (you observe which contingency occurred, then choose the correction). Each state has
its own limit, so a branch may use a higher *temporary* rating in N-1 and a *permanent* rating
in N-1/c.

## What it computes

```
φ = max_{v ∈ V}  min_{u_c ∈ U_c}  max_{(e, s)}  ( |P_{e,s}(v, u_c)| / P̂_{e,s}^{s} − 1 )
```

* `v` — injection deviations at the uncertain buses (within a box `V`)
* `u_c` — per-contingency corrective PST angles, acting only post-corrective (range `U_c`)
* the inner `max` — the worst per-unit overload over every monitored branch `e` and state `s`,
  each with its own limit `P̂^{s}`

The grid is **secure** iff `φ ≤ 0`: for *every* uncertainty there *exists* a corrective response
keeping all flows within every state's limits. `φ > 0` is the residual overload that even the
best correction cannot remove — and the oracle returns the worst-case injection `v*`.

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
    uncertain     = Dict("VL3_0" => (-100.0, 0.0)),  # ±injection-deviation box per bus (MW)
    monitored     = Dict("L12a" => (base = 110.0, contingency = 150.0, corrective = 110.0)),
    correctives   = ["PST_T"],                       # PSTs usable as post-contingency correction
    contingencies = ["L_B"],                         # N-1 outages (nominal + base always included)
)

sol.phi     # worst achievable overload (> 0 ⇒ insecure)
sol.secure  # φ ≤ tol
sol.worst_injection  # the worst-case v*
sol.corrective       # best corrective PST angles per contingency: Dict(cont => Dict(pst => α))
```

A `monitored` limit may be a plain number (same in every state) or a `NamedTuple`
`(; base, contingency, corrective)` selecting per-state limits (`base` is also used for the
nominal state and as the fallback).

## Scope (first slice)

Uncertainty = injection deviations; correctives = **continuous PST angles**; the four states
nominal / N / N-1 / N-1/c with single-branch N-1 outages and per-state limits. Deferred: the
integer-mode PST/HVDC models, topology switching (bus splitting),
redispatch/participation-factor balancing, and the outer flexibility-maximisation objective
(which turns this oracle into the full three-level program).

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

## Load balancing (secondary frequency response)

The imbalance an uncertainty realisation creates is absorbed by the participating generators as
a **secondary frequency response**: each participating generator settles at

```
P_g = mid( P_g⁻ ,  P_g⁰ + λ · f_g ,  P_g⁺ )
```

— its nominal output plus its participation factor `f_g` times a system-wide demand signal `λ`
(the frequency-deviation proxy), **saturating** at its limits `[P_g⁻, P_g⁺]`. `λ` is set so the
total response covers the imbalance. Modelled exactly (the `mid`/clamp is an MILP). Pass
`participation = Dict(gen_id => f_g)`; omit it to keep a single slack bus (which unrealistically
dumps the whole imbalance on one bus).

## Integer-mode devices

Two devices whose behaviour is a **disjunction** (modelled with binaries):

* **HVDC in AC-emulation** — its flow follows `P⁰ + K·Δθ` but is **clamped** to a hard limit
  `±P^lim` (a 3-mode disjunction, the same `mid` clamp). Declare with
  `hvdc = [(; id, bus1, bus2, k, p_zero, p_lim)]`.
* **PST over-current disconnection** — a corrective PST either **regulates within its rating**
  (`|P| ≤ P^lim`) or **trips** to zero flow. Enable per PST with `switchable = [pst_id]` and
  `pst_limits = Dict(pst_id => P^lim)`.

## Full PST automaton

Beyond the simple switchable-PST above, a PST can be modelled as the **full protection
automaton**: a physical device (not a free corrective) whose behaviour in each state is decided
by its own logic, with the trip decision **propagating** forward through the states.

Per contingency, in the post-corrective state the PST:

* **activates** its regulation only once the pre-corrective flow crosses a threshold,
  `|P^{N-1}| ≥ P^act`;
* when active, **regulates toward** `±P^tar`, i.e. it settles at the median
  `mid( h(Δθ + α̲) , clamp(h(Δθ + α⁰), −P^tar, P^tar) , h(Δθ + ᾱ) )` over its angle range;
* **trips** on over-current (`|P| ≥ P^lim`) in any state, and a trip **propagates**: a device
  open in `N` stays open in `N-1`, and one open in `N-1` stays open post-corrective.

Enable it per PST with

```julia
pst_model = Dict("PST_T" => (p_lim = 300.0, p_act = 50.0, p_tar = 30.0))
```

The over-current protection is **self-referential** — an open device decouples its buses, so the
*would-be* natural flow can be arranged to exceed the rating and "justify" a spurious trip. Such
a disconnected state is only **locally consistent** (Aachen Remark 1); the physical equilibrium
is the one that keeps a device connected unless it genuinely over-currents. It is selected
**lexicographically**: among the consistent equilibria, minimise the number of disconnections
first, then the overload.

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
    participation = Dict("G1" => 1.0, "G2" => 1.0),  # secondary frequency response (else single slack)
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
nominal / N / N-1 / N-1/c with single-branch N-1 outages and per-state limits; the
**participation-factor secondary frequency response** with generator-limit saturation;
**integer-mode devices** — HVDC AC-emulation clamp and PST over-current disconnection; and the
**full PST automaton** — activation, target regulation and over-current protection with forward
trip propagation, its multiple equilibria resolved by the local-consistency tie-break. Deferred:
the automaton's adversarial discretization when the full PST is combined with *free* correctives
(the "ignore-discretization-point" consistency machinery for the min-max), topology switching
(bus splitting), and the outer flexibility-maximisation objective (which turns this oracle into
the full three-level program).

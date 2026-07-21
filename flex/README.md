# PowsyblFlexibility

Flexibility maximisation on a power grid — the **outer** level of the three-level worst-case
formulation, built on top of [`PowsyblWorstCase`](../worstcase)'s feasibility oracle with
JuMP + HiGHS.

Flexibility is the *amount of injection uncertainty* a grid can absorb while still being
securable in the worst case. For a `δ`-parameterised uncertainty region `T(δ)` (a box around the
forecast that grows with `δ`),

```
δ* = max { δ ≥ 0 :  for every y ∈ T(δ), a corrective response keeps all limits met }
```

The inner test — *for every `y` there exists a corrective response* — is exactly the oracle's
`φ ≤ 0`. Since `φ(δ)` increases monotonically with `δ`, `δ*` is found by **bisection**, each step
a single oracle call.

## The copper-plate oracle (upper bound + pre-filter)

Dropping **every branch limit** collapses the grid to a single bus: the only requirement left is
that the responding generation can rebalance the net injection change within its capacity. This
**copper-plate** model is cheap (an interval check — the worst `y` over a box is a vertex) and
gives two things:

* an **upper bound** `δ_cp ≥ δ*` — removing constraints can only enlarge the manageable region,
  so the adequacy limit is never below the network-constrained flexibility;
* a **fast feasibility pre-filter** — copper-plate infeasibility implies network infeasibility,
  so a region that already fails power-balance adequacy is rejected without the MILP oracle.

`δ_cp` also brackets the bisection from above, and cleanly separates two regimes: the network
(a line limit) binding, or generation **adequacy** running out first (`δ* = δ_cp`).

## The δ-parameterised region

`T(δ)` grows each forecast box `(lo, hi)` outward by `δ · weight` per side. A weight may be a
scalar (symmetric growth) or a pair `(w_lo, w_hi)` for asymmetric growth — e.g. `(1.0, 0.0)` to
grow only the load (extra-demand) side. This is the *scaled-hyperbox* parameterisation; the
*power-transfer* parameterisation (a directional `y = y⁰ + δ·d`) is a later slice.

## Usage

```julia
using PowsyblFlexibility

r = flexibility_max(network;
    base          = Dict("VL2_0" => (0.0, 0.0)),     # forecast box (MW deviations)
    weights       = Dict("VL2_0" => (1.0, 0.0)),     # grow only the load side by δ
    monitored     = Dict("L12" => 150.0),            # forwarded to the oracle
    participation = Dict("G1" => 1.0, "G2" => 1.0),  # secondary frequency response
    tol           = 0.05,                            # bisection tolerance on δ
)

r.delta            # δ*  the flexibility metric
r.delta_cp         # copper-plate upper bound (≥ δ*)
r.secure_at_base   # is the forecast box T(0) itself secure?
r.worst_injection  # the binding worst-case injection y*
```

Any further keyword (`correctives`, `contingencies`, `hvdc`, `switchable`, `pst_limits`,
`pst_model`, `bigM`, …) is forwarded to
[`PowsyblWorstCase.worst_case_oracle`](../worstcase), so flexibility can be measured against the
four-state model with correctives, integer-mode devices, and the full PST automaton.

## Scope (first slice)

Fixed preventive dispatch; the **scaled-hyperbox** region parameterisation; the **copper-plate
oracle** for the upper bound and pre-filter; and **bisection** on `δ` driving the worst-case
oracle. Deferred: the **power-transfer** parameterisation, and jointly optimising the
**preventive actions** `x` (generator set-points) with `δ` via the existence-constrained SIP
outer loop ([`SemiInfinite`](../sip)) — the full three-level program.

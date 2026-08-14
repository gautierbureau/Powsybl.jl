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

## Two senses of "worst case" — and how this package uses the other one

The phrase is overloaded, so to be explicit:

* **[`PowsyblWorstCase`](../worstcase)** — the *security oracle*. Given a **fixed** uncertainty
  set it answers *is this grid securable?*, returning `φ` (`≤ 0` ⇔ secure) and the binding
  injection. The uncertainty set is an **input**.
* **This package** — the *outer search*. It makes that set the **unknown** and asks *how large can
  it be?*, calling the oracle repeatedly.

So the whole of `PowsyblFlexibility` is a search wrapped around the oracle. Concretely it uses
exactly two things from it:

```julia
W.GridModel(network)        # for the copper-plate (generation headroom only)
W.worst_case_oracle(...)    # the security test inside each bisection step
```

Everything else here — the region parameterisations, the copper-plate bounds, the bisection — is
search logic; none of the grid physics lives in this package.

**A third thing is *not* the same:** producing the explicit scenario that *certifies* a reported
answer. That is a different objective over the same model (maximise the violation across the whole
reported range, rather than test one set), and it is a deferred item. To keep it distinct from the
oracle we call it a **certifying scenario**, not "worst-case generation".

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

## Maximum exchange (the power-transfer parameterisation)

The second parameterisation asks a different question: not *how far can each injection move*, but
**how much power can this zone import** before the grid stops being securable. The **exchange** is
the net injection deviation of a zone of buses, and

```julia
r = max_exchange(network;
    zone      = ["VL2_0"],                       # the buses whose net deviation is the exchange
    box       = Dict("VL2_0" => (-1000.0, 0.0)), # bounds how a transfer may be *composed*
    monitored = Dict("L12" => 150.0),
)

r.emax      # the largest manageable exchange (MW)
r.interval  # the copper-plate exchange interval — an outer bound on what is attainable at all
```

Here the per-bus `box` bounds how an exchange may be **composed**, while the exchange bound itself
is what gets maximised. The security test is monotone in that bound, so the maximum is bisected
inside the copper-plate interval.

Passing `restriction = ε` requires the grid to be secure *with a margin* rather than merely
secure. The answer is then **conservative** — guaranteed achievable rather than sitting exactly on
the frontier — which is what lets a cheap restricted pass stand in for the exact one.

`copperplate_exchange_interval` gives that interval directly: with every branch limit dropped,
only power balance and generator capacity remain, so an import must be covered by the responding
generation's **up**-regulating headroom and an export by its **down**-regulating headroom. It
brackets the search and rejects hopeless targets without an MILP — and cleanly separates the two
regimes, the network binding or generation adequacy binding first.

## The δ-parameterised region

`T(δ)` grows each forecast box `(lo, hi)` outward by `δ · weight` per side. A weight may be a
scalar (symmetric growth) or a pair `(w_lo, w_hi)` for asymmetric growth — e.g. `(1.0, 0.0)` to
grow only the load (extra-demand) side.

Use this when the question is *how far each injection may move independently*; use
[`max_exchange`](#maximum-exchange-the-power-transfer-parameterisation) when it is *how much
power a zone may import*, which is the aggregate the reference optimises.

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

Fixed preventive dispatch; both region parameterisations — the **scaled hyperbox** (`δ`) and the
**power transfer** (`max_exchange`); the **copper-plate** bound and pre-filter for each; and
**bisection** driving the worst-case oracle, with a **restriction** for conservative answers.
Deferred: racing the restricted pass against the exact one (a pure wall-clock win, no change to
the answer), a **certifying-scenario** pass to certify the reported interval, the medial's
low-exchange/high-violation balance term (which belongs with an exchange *discretization* loop
rather than bisection), and jointly optimising the **preventive actions** `x` with the metric via
the existence-constrained SIP outer loop ([`SemiInfinite`](../sip)).

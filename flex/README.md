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
answer — `certifying_scenario`, below. That is a different question over the same model (search the
whole reported range for the worst violation, rather than test one set). To keep it distinct from
the oracle we call it a **certifying scenario**, not "worst-case generation".

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

Here the per-bus `box` bounds how an exchange may be **composed**, while the exchange itself is
what gets maximised.

**How it is solved.** Not by searching over transfer levels. The exchange is the *objective*: one
solve returns the **smallest exchange at which correction fails**, and since everything below that
is correctable by construction, that value *is* the frontier. Internally the corrective menu is
grown by verifying each candidate scenario against the full corrective freedom, so the answer is
exact rather than tolerance-limited. Pass `method = :bisection` for the older level-probing search;
it is slower and only as accurate as `tol`, and is kept as an independent cross-check (the tests
assert the two agree).

Passing `restriction = ε` requires the grid to be secure *with a margin* rather than merely
secure. The answer is then **conservative** — guaranteed achievable rather than sitting exactly on
the frontier — which is what lets a cheap restricted pass stand in for the exact one.

### Bounding the answer from both sides

The restriction says what counts as *failing*, and its sign decides which side of the frontier the
answer lands on. Demand a margin and failure arrives sooner, so the reported transfer is one the
grid can certainly hold; tolerate an overload and failure arrives later, so nothing above the
reported transfer can be held. `exchange_bracket` runs both under a shrinking restriction:

```julia
b = exchange_bracket(network;
    zone = ["VL2_0"], box = box, monitored = Dict("L12" => 150.0),
    init_restriction = 0.1, reduction = 0.25, tol = 0.5)

b.lower   # guaranteed achievable — the grid is securable across [0, lower]
b.upper   # certified outer bound — no transfer above it can be held
b.rounds  # restriction levels tried, two solves each
```

Both bounds are valid from the first round rather than only on convergence, because each leg's
exit test verifies its candidate against the full corrective freedom. So a bracket stopped early
is still a usable answer — quote `lower` to be safe, `upper` to know what is ruled out. Where a
single exact solve is affordable, `max_exchange` is the cheaper route; the bracket earns its keep
when it is not, or when the answer must come with a proof on each side.

`copperplate_exchange_interval` gives that interval directly: with every branch limit dropped,
only power balance and generator capacity remain, so an import must be covered by the responding
generation's **up**-regulating headroom and an export by its **down**-regulating headroom. It
brackets the search and rejects hopeless targets without an MILP — and cleanly separates the two
regimes, the network binding or generation adequacy binding first.

### Certifying the answer

A reported maximum exchange is a claim about a whole *range* — that every transfer up to it can be
held against every uncertainty. `certifying_scenario` settles that claim by searching the range for
the worst violation:

```julia
c = certifying_scenario(network; zone = ["VL2_0"], box = box,
                        monitored = Dict("L12" => 150.0), emax = r.emax)

c.clear      # true ⇒ nothing in [0, emax] violates: the range is confirmed
c.phi        # …and if it is false, the rest of the result is the counter-example:
c.exchange   # the transfer the failing scenario sits at
c.binding    # which branch, in which state and direction, gave way
c.injection  # the deviations realising it
```

So the frontier search says where the boundary is, and this says whether the region below it really
holds — naming what breaks if it does not. It is the same model with the exchange constrained to
the reported range instead of fixed, so it costs one oracle call and no new modelling.

`extension` widens the search past the boundary by a percentage. That is an *illustration* — a
failure it finds says nothing about the interval, since it was told to look outside it. Only
`extension = 0` tests the reported answer.

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
**cutting** — the exchange as the objective, landing on the frontier in one solve — with
bisection retained as a cross-check, a **restriction** for conservative answers, and
**two-sided bounding** (`exchange_bracket`) enclosing the answer between an achievable and a
certified value; and a **certifying scenario** (`certifying_scenario`) that confirms a reported
range or produces the counter-example that breaks it.
Deferred: racing the two bounding legs against each other (a pure wall-clock win, no change to
the answer), the medial's low-exchange/high-violation balance term (which belongs with an exchange
*discretization* loop rather than bisection), and jointly optimising the **preventive actions** `x` with the metric via
the existence-constrained SIP outer loop ([`SemiInfinite`](../sip)).

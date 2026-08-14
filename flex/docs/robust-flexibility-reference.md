<!--
Copyright (c) 2025, RTE (http://www.rte-france.com)
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at http://mozilla.org/MPL/2.0/.
SPDX-License-Identifier: MPL-2.0
-->

# Robust flexibility analysis — design notes and reference comparison

This note records how the Julia packages in this repository (`SemiInfinite`, `PowsyblWorstCase`,
`PowsyblDcOpf`, `PowsyblFlexibility`) reproduce the robust security / flexibility-analysis method,
and how they map onto the reference C++ implementation studied alongside this work. It is meant to
orient the next implementation slices — it is not user documentation.

The underlying method is published:

* *Optimizing Flexibility in Power Systems by Maximizing the Region of Manageable Uncertainties*
  (Optimization and Engineering, 2025) — the flexibility-maximisation formulation.
* The worst-case security papers (hierarchical three-level worst-case analysis of power grids).

## The problem

For a **fixed preventive dispatch**, the grid is **secure** iff, under the worst injection
uncertainty, corrective control can keep every monitored branch within its limit across all four
operating states. That inner question is a min–max feasibility test:

```
φ = max_{v ∈ V}  min_{u_c ∈ U_c}  max_{(e, s)}  ( |P_{e,s}(v, u_c)| / P̂_{e,s}^{s} − 1 )
```

Secure ⇔ `φ ≤ 0`. **Flexibility** wraps this: grow the uncertainty region `T(δ)` (a scaled
hyperbox, or a power-transfer/"exchange" direction) and maximise the `δ` that stays secure — an
**existence-constrained semi-infinite program** (ESIP):

```
max_{δ ≥ 0, x ∈ X} δ   s.t.   ∀ y ∈ T(δ, x)  ∃ u_c :  all limits met
```

with `x` the preventive actions (generator set-points). This is a three-level program:
**outer** (maximise `δ`, choose `x`) / **medial** (find the worst `y`) / **lower** (best corrective
`u_c`).

## Layer mapping

| Concept | This repo | Reference implementation |
|---|---|---|
| DC power flow (θ / PTDF) | `PowsyblDcOpf` | `edge/*` admittance line models |
| Min–max feasibility oracle | `PowsyblWorstCase.worst_case_oracle` | the grid solver (MLP↔LLP) |
| Blankenship–Falk cutting plane | `SemiInfinite.solve_bnf` | discretization loop |
| RRHS (restriction of the RHS) | `SemiInfinite.solve_rrhs` | AUX upper-bounding heuristic |
| Falk–Hoffman min–max | `SemiInfinite.solve_minmax` | worst-case scenario generation |
| Existence-constrained SIP | `SemiInfinite.solve_esip_bnf` | outer ESIP driver |
| Flexibility maximisation | `PowsyblFlexibility.flexibility_max` | the flexibility solver |
| Copper-plate bound / pre-filter | `PowsyblFlexibility.copperplate_bound` | the copper-plate feasibility interval |

The factoring lines up almost one-to-one, which is good evidence the split is the right one.

## Model structure (three levels, four states)

Each device carries one sub-model **per level**:

* **Upper (preventive)** — enforces limits on the *discretized* worst-cases, with a **right-hand-side
  restriction** `ratio − 1 ≤ slack·bigM − ε_R`. The `ε_R > 0` restriction is what makes the upper
  bounding conservative-but-feasible (the RRHS idea).
* **Medial (worst-case)** — the overload `max_{e,s}(P/limit − 1)` modelled with "exactly one
  violation binary active" (`Σ vio = 1`). This is exactly the selection-binary pattern in
  `PowsyblWorstCase._relaxed_medial`.
* **Lower (corrective)** — minimise the max overload ratio (`PowsyblWorstCase._corrective_response`).

The **four states** are `nominal / base(N) / contingency(N-1) / corrective(N-1/c)`, each indexed by
a discretization point. A **coupling** step feeds worst-cases from the medial up into the outer
discretization and corrective responses from the lower level into the medial — the bidirectional
Falk–Hoffman/Blankenship exchange.

Two modelling details worth adopting in our code:

* **Asymmetric per-direction limits** (`P_limit_lower` / `P_limit_upper`) — a branch can have
  different ratings per flow direction. We currently use a symmetric `|P|/lim`.
* **Border-inclusive activation** — an activation threshold expressed as `Σ mode ≤ 1` (a state on
  the boundary counts as *both* active and inactive) rather than a strict `= 1`, avoiding an
  ε-discontinuity that our strict threshold introduces.

## Full PST automaton — two resolutions of the same problem

Both implementations model the same automaton: a phase-shifter that **activates** when its flow
crosses `P_act`, **regulates** toward a target, **trips** on over-current (`|P| ≥ P_lim`) and
**propagates** the trip forward (`N → N-1 → N-1/c`). Both hit the same difficulty: when a device is
open its buses decouple, so its *would-be* natural flow can be arranged to exceed the rating and
"justify" a **spurious trip** — a state that is only locally consistent.

The two resolutions differ:

| | Reference | This repo |
|---|---|---|
| Where resolved | across the discretization loop | within each solve |
| Mechanism | fix the automaton mode/trip **pattern per discretization point** from the lower-level solution; in the medial, `mode_violation` binaries detect when that fixed pattern is inconsistent with the newly-chosen worst-case; a point may be **ignored only if it genuinely violates** (`ignore_disc ≤ Σ device_violation`) | a deterministic **connected-reference flow** `P_ref` (a second DC solve with every full-PST forced connected at α⁰); the trip is pinned to `|P_ref| ≥ P_lim`, which is a determined function of the injection, so no spurious trip can form in either the medial or the lower level |
| Medial linearity | linear (trip is a fixed parameter) | MILP (trip is a variable) |
| Generality | handles the implicit automaton response fully | assumes a single acting device per corridor (no within-state cascade between several full-PSTs) |
| Cost | more machinery, more discretization points | self-contained, simpler |

Our reference-flow route is a **modelling** fix; theirs is an **algorithmic** (discretization) fix.
They should agree on any single-full-PST case; a shared fixture cross-check is a good validation
task. The reference route becomes necessary if/when we support several interacting full-PSTs whose
trips cascade within one state.

## Copper-plate

Dropping every branch **limit** (keeping power balance and generator capacity) collapses the grid to
a single bus. The largest region still balanceable by the responding generation is an **upper bound**
`δ_cp ≥ δ*` (removing constraints only enlarges the manageable region) and a **fast feasibility
pre-filter** (copper-plate infeasibility ⇒ network infeasibility, no MILP needed). The reference
computes this as an **exchange interval**: the min/max exchange achievable with the controllable
uncertain injections at zero, solved in both directions and intersected, then widened by the
generator-sum bound. Our `copperplate_bound` implements the scaled-hyperbox equivalent (an interval
check on `Σy` against up/down regulating headroom); the exchange version is the next slice.

## Solver structure — what the reference actually runs

Worth recording, because it changes what "matching the reference" means.

The reference decomposes into **eight** programs, which split into two groups.

**Prior/standalone procedures**, each its own binary, run before the main solve (none of them
appears in the solver loop):

* **`obbt`** — optimisation-based bound tightening: conservative bounds on the variables.
* **`cpf`** — copper-plate feasibility: the exchange interval attainable ignoring line limits,
  which brackets the search range (see *Copper-plate* above).
* **`filter`** — monitored-line screening ("check if given monitored lines have potential for
  having a violation"). It maximises the largest flow/limit ratio over the **OBBT-relaxed** grid,
  across all three cases and both directions. Being computed on the relaxed grid it is
  deliberately conservative, so a monitored line whose ratio cannot reach 1 can never be violated
  and may be dropped — shrinking the expensive MILPs that follow.

**The iteration itself** uses the two outer levels plus **three MLP-shaped programs**:

* **`ulp`** (preventive) and **`llp`** (corrective) — the upper and lower levels.
* **`mlp`** — the canonical medial (worst-case) program.
* **`aux`** — the RRHS-style auxiliary upper-bounding heuristic (a variant of the medial that
  maximises one quantity while constraining the other to stay positive).
* **`wcgen`** — worst-case scenario generation: the medial with a revised objective, used to
  certify the reported interval.

`cpf` and `wcgen` (and `aux`) are all *derived from* the medial formulation — each is the medial
with a modified objective and an extra constraint — which is why they share its variables.

### The AUX ∥ MLP race

The parallelism that matters algorithmically is between **`aux` and the canonical `mlp`**: both
are launched concurrently, and *whichever first proves a result that terminates the step aborts
the other*. The cheap restricted heuristic and the exact medial race, and the step costs the
**minimum** of the two rather than the exact solve every time — the heuristic often settles the
iteration, and when it cannot, the exact medial is already running rather than starting late.

There is a second, outer layer of threading — a lower-bounding and an upper-bounding procedure
differing in the RHS restriction (`ε_R = 0` vs `ε_R > 0`) — but each of those instantiates the
same canonical medial, so it is two *instances* of one program, not two distinct programs.

This race is worth reproducing before any joint preventive optimisation: it is a pure
wall-clock win that does not change the answer.

### The three medial programs, formulated

All three share the *same* medial model — node balance, the exchange definition, the four states,
every device — and differ only in objective and a couple of constraints. Writing `V[d]` for the
worst limit violation at discretization point `d` (plus its ignore term), `E` for the exchange and
`E_max` for the current exchange bound:

| Program | Problem | Solved by |
|---|---|---|
| **`mlp`** (canonical) | `max min( min_d V[d] , 0.001·(E_max − E) )` | min–max |
| **`wcgen`** | `max min_d V[d]`  s.t. `0 ≤ E ≤ E_max` | min–max (**same solver**) |
| **`aux`** | `min E`  s.t. `V[d] ≥ ε_R  ∀d` | SIP-RRHS |

* **`mlp`** maximises the *minimum* of the violation and a small term rewarding **low** exchange —
  a deliberately **balanced** scenario search (low exchange *and* high violation). The main
  program's help text names this directly ("balanced scenario generation").
* **`wcgen`** drops that balance term and instead *constrains* the exchange to the range, so it is
  the **pure worst-violation search** — the same quantity as our oracle's `φ`.
* **`aux`** is the odd one out and is genuinely a different algorithm: it **minimises the
  exchange** subject to a violation of at least the restriction `ε_R` being forced at every point.
  That is the restriction-of-the-right-hand-side scheme — solve a *restricted* problem to obtain a
  valid **upper** bound on the safe exchange. Its two knobs are an initial restriction and a
  reduction factor, matching `solve_rrhs`'s `epsilon` and `beta`.

The decisive structural fact: **`mlp` and `wcgen` are solved by the same call** —
`minmax_solver.solve(⟨max program⟩, llp, disc)` — with only the maximisation program swapped.
In our code they should likewise be one model assembly with a different objective, which the
shared `_build_program!` in `PowsyblWorstCase` now makes natural (the state loop is written once
and the objective enters through a callback).

### Do we have the algorithms?

**Yes, for all three.** `SemiInfinite` exports `solve_bnf`, `solve_rrhs`, `solve_minmax` and
`solve_esip_bnf`; the min–max covers `mlp` and `wcgen` (in grid-specialised form it *is*
`worst_case_oracle`'s medial↔lower loop), and `solve_rrhs` covers `aux`. What is missing is not
algorithms but **orchestration and parameterization**:

1. all three objectives are written in terms of the **exchange** variable — without the exchange
   parameterization none of them can even be *stated* in reference form, which is why it is the
   first roadmap item;
2. the auxiliary/medial **race**;
3. one grid model assembly whose objective is swapped to give `mlp` vs `wcgen`.

The dependency library carries several schemes we have not reproduced — an oracle-based SIP,
generalized SIP/min–max variants, bilevel programs, and hybrid bounding solvers. None is needed
for parity on this problem; the hybrid schemes are the natural direction only if the two-sided
bounding is later tightened.

### Binaries

`grid-screen` (the main solver, driving the grid-solver class), plus `validate_model`,
`calculate_copper_plate_interval`, `obbt` and `filter` — the last two confirming that bound
tightening and monitored-line screening are standalone prior steps.

**The outer (preventive) optimisation is currently disabled.** The specialised flexibility solver
— the subclass that would optimise the preventive actions `x` together with `δ`, with the dual
AUX threads — is compiled but its instantiation is commented out; the shipped tool always uses the
base solver and **reports the maximum exchange for a fixed preventive dispatch**.

That matters for us: our `flexibility_max` over a *fixed* dispatch is therefore comparable to what
the reference actually ships, and jointly optimising `x` is beyond what either currently does.

## Gaps / roadmap (highest leverage first)

1. **Exchange (power-transfer) parameterization** — the reference's *primary* objective is
   max-exchange, not hyperbox-δ. Add a directional region `y = y⁰ + δ·d` and the matching
   copper-plate exchange interval so results are directly comparable. This is the single change
   that would put us on the same footing as the shipped reference.
2. **Two-sided bounding + worst-case-generation certificate** — replace our plain bisection with a
   lower/upper bounding pair (the RRHS restriction gives the conservative side, via
   `SemiInfinite.solve_rrhs`), and add a final worst-case-generation pass that certifies the
   reported interval. Jointly optimising the preventive actions `x` (`solve_esip_bnf` as the outer
   driver) sits *above* this and is disabled in the reference — treat it as exploratory, not as
   parity work.
3. **Richer load balancing** — merit-order (generators hit bounds in a fixed order) and **emergency
   generators** (inject only when all others are capped), on top of our participation + saturation.
4. **`discrete_shifter`** (discrete-tap PST) and a **corrective line automaton** as device types.
5. **Asymmetric per-direction limits** and **border-inclusive activation** (cheap, do alongside the
   above).

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
| Falk–Hoffman min–max | `SemiInfinite.solve_minmax` | the medial solver (serves both `mlp` and `wcgen`) |
| Existence-constrained SIP | `SemiInfinite.solve_esip_bnf` | outer ESIP driver |
| Flexibility maximisation | `PowsyblFlexibility.flexibility_max` | the flexibility solver |
| Copper-plate bound / pre-filter | `PowsyblFlexibility.copperplate_bound`, `copperplate_exchange_interval` | the copper-plate feasibility interval |
| Exchange parameterisation | `PowsyblWorstCase` `exchange=`, `PowsyblFlexibility.max_exchange` | the exchange variable the objectives are written in |
| Two-sided bounding | `PowsyblFlexibility.exchange_bracket` | the `aux` restriction schedule |
| Exchange master ↔ balanced medial | `PowsyblWorstCase.discretization_exchange` | `ulp` ↔ `mlp` (the `solve_lbd` / `solve_ubd` loop) |
| Certifying scenario | `PowsyblFlexibility.certifying_scenario` | `wcgen` post-processing |
| Monitored screening | `PowsyblWorstCase.screen_monitored` | the `filter` binary |
| End-to-end driver | `PowsyblFlexibility.analyse_exchange` | `grid_solver::solve` (all `main.cpp` does is parse options and call it) |

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

**Per-direction ratings** are now done on our side: a monitored limit may be a `(lower, upper)`
pair, read as the rating for the flow's own direction, so a violation is `ratio > 1` either way —
the same device the reference uses. **Discrete taps** likewise: a corrective phase shifter may be
restricted to its own tap table by a one-hot choice, as the reference's discrete variant does,
though we keep the susceptance tap-independent rather than varying it per tap. **Border-inclusive
activation** — a state exactly on the activation threshold counting as both active and inactive —
turns out to need no work: our dichotomy is written with non-strict big-M inequalities on both
sides, so at `|P^{N-1}| = P^act` both branches are admissible and the solver takes the better one.
That is verified from both sides in the test suite (a fixture where activating is favourable and
one where staying inactive is, each pinned at the exact threshold), so the strict-`= 1` mode
selection carries no ε-discontinuity.

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
generator-sum bound. We now have both: `copperplate_bound` for the scaled hyperbox and
`copperplate_exchange_interval` for the transfer form, each an interval check of the net deviation
against up/down regulating headroom.

## Solver structure — what the reference actually runs

Worth recording, because it changes what "matching the reference" means.

The reference decomposes into **eight** programs, which split into two groups.

**Prior/standalone procedures**, each its own binary, run before the main solve (none of them
appears in the solver loop):

* **`obbt`** — bound tightening. Despite the name it is not a per-variable loop: it is a *single*
  solve returning one physically meaningful number, a rigorous bound on the largest angle
  difference across any edge in any state. Every device big-M is then derived from it —
  `min(admittance·(angle_bound + shift), currentBigM)` for a line, similarly for HVDC and
  shifters — with `currentBigM`, a coarse user-supplied cap, as a safety net. One computed
  quantity, per-device consequences.
* **`cpf`** — copper-plate feasibility: the exchange interval attainable ignoring line limits,
  which brackets the search range (see *Copper-plate* above).
* **`filter`** — monitored-line screening ("check if given monitored lines have potential for
  having a violation"). It maximises the largest flow/limit ratio over the **OBBT-relaxed** grid,
  across all three cases and both directions, picking the argmax with a one-hot binary. Being
  computed on the relaxed grid it is deliberately conservative, so a monitored line whose ratio
  cannot reach 1 can never be violated and may be dropped — shrinking the expensive MILPs that
  follow. Its big-M needs care and the file says why: against a reverse rating of `−0.1` and a
  forward one of `10`, a flow of 20 gives ratios of `−200` and `2`, and a big-M of 150 silently
  breaks the disjunction. They take `max(25, max_limit / min_limit)`.

  `PowsyblWorstCase.screen_monitored` implements **both** readings, so they can be compared on the
  same case. `method = :bounds` needs no solve: the per-branch flow bounds (below) already
  over-estimate what a branch can carry, so comparing that bound with the rating in each state
  settles it, with every bus free to take its worst injection independently. `method = :lp` is
  theirs — maximise the ratio over the model, with balance enforced and the corrective controls
  free and maximised (which is what keeps it an over-estimate rather than an answer).

  Measured on the `build_ext` fixture, the largest ratio each monitored branch can reach:

  | branch | `:bounds` | `:lp` |
  |---|---|---|
  | `L12a`  | 3.6021 | 1.9481 |
  | `L1_2a` | 0.0203 | 0.0086 |
  | `L2b_3` | 0.7500 | 0.5000 |
  | `L_B`   | 0.0508 | 0.0152 |
  | `PST_T` | 0.4067 | 0.1714 |

  Enforcing balance is worth roughly a factor of two, and it decides real cases: rate `L2b_3` at
  350 MW and the arithmetic cannot rule it out (450/350) while the optimisation can (300/350). Both
  screens are sound and both leave the verdict unchanged; they differ only in how much slack they
  leave on the table.

  Two departures from the reference, both deliberate. We solve over the *real* per-contingency
  topologies rather than one generic post-contingency case, which is tighter. And we maximise each
  ratio separately instead of packing the whole set into one solve with a one-hot selection: that
  yields the same global number (`filter_ratio`, their binary's output) plus the per-branch detail
  their formulation discards, and it removes the big-M their own file warns about.

**The iteration itself** uses the two outer levels plus **three MLP-shaped programs**:

* **`ulp`** (preventive) and **`llp`** (corrective) — the upper and lower levels.
* **`mlp`** — the canonical medial (worst-case) program.
* **`aux`** — the RRHS-style auxiliary upper-bounding heuristic (a variant of the medial that
  maximises one quantity while constraining the other to stay positive).
* **`wcgen`** — worst-case scenario generation: the medial with a revised objective, used to
  certify the reported interval. It runs as a **post-processing step** over the reported answer,
  not inside the loop. Note the term is the *reference's*: it is **not** our `PowsyblWorstCase`
  (a security test at a fixed uncertainty set) but the production of the explicit binding scenario
  for a reported range. We call that a *certifying scenario* to keep the two apart.

`cpf` and `wcgen` (and `aux`) are all *derived from* the medial formulation — each is the medial
with a modified objective and an extra constraint — which is why they share its variables.

### What the driver actually sequences

`main.cpp` is only option parsing: it builds a `grid_solver`, forwards ~18 options, and calls
`solve()`. That function is the pipeline:

1. `generate_problem_description` reads the formulation files into the eight programs.
2. **`solve_init`** — one initial iteration. Solve the `ulp` once (`solve_ulp_grid`); launch `aux`
   asynchronously; launch the `mlp` feasibility check on the `ulp` candidate unless the record is
   already global; then **race** them (poll at 50 ms, abort the loser once both bounds are done).
   Discretize whatever came back, and finally run `wcgen` if the force level calls for it.
3. **Early exit** if that iteration already settled it — infeasible, global, or feasible with
   `lbd > 0` (an established violation).
4. Otherwise spawn `solve_lbd` and `solve_ubd` as two threads and join them. `lbd` runs the exact
   side; `ubd` carries a right-hand-side restriction `ub_restrict`, starting at `eps_g = 0.05` and
   halved (`red_g = 2`) as the iteration makes progress.

`analyse_exchange` mirrors that shape: copper plate, bound tightening, screen, the security
question at zero exchange (with the same early exit), the frontier — the single exact solve, the
two-sided bracket, or the master/medial loop — and the certificate under a gate matching
`--force-worst-case-gen`.

**A correction to an earlier reading of this note.** The `ulp` is *not* a preventive-dispatch
optimisation, and `assume_fixed_upper` does not switch it off (it only changes which bound gets
recorded, at `grid_solver.cpp:500`). For `MAX_EXCHANGE` the `ulp` is the **Blankenship–Falk master
over the exchange**:

```
objective: −ulp_exchange_max                                   # i.e. maximise it
forall d in ulp_disc:
    ulp_exchange_cont_curr[d] ≥ ulp_exchange_max
                               − BigE·(1 − ulp_ignore_disc[d])
                               + ub_restrict·BigE
forall d in ulp_disc:  ulp_unit_slack[d] ≤ ulp_ignore_disc[d]
```

Read it through the slack chain — `simple_line_bound_unit_slack[d] ≤ unit_slack[d] ≤
ignore_disc[d]` — and it says: each stored point must either **satisfy its limits outright**
(`ignore = 0`, no slack granted) or be **pushed to an exchange at or above the candidate**
(`ignore = 1`). So the master maximises the exchange subject to every scenario collected so far
being either correctable or out of range, and `ub_restrict` shifts the second branch up, making
the answer conservative. That is a whole algorithm we did not have, not a step that degenerates.

The restriction schedule is theirs: `exchange_bracket` defaults to `init_res = 0.05` and a
reduction of `1/4`, matching what `solve_aux` sets (`init_res` 0.05, `red_res` 4.0), and
`solve_ubd` runs its own `eps_g = 0.05` halved by `red_g = 2`.

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
| **`mlp`** (canonical) | `max min( min_d V[d] , 0.001·(E_max − E) , 100·E )` | min–max |
| **`wcgen`** | `max min_d V[d]`  s.t. `0 ≤ E ≤ E_max` | min–max (**same solver**) |
| **`aux`** | `min E`  s.t. `V[d] ≥ ε_R  ∀d` | SIP-RRHS |

* **`mlp`** maximises the *minimum* of the violation and two caps: a small term rewarding **low**
  exchange, and one forbidding an exchange near zero. A deliberately **balanced** scenario search
  (low exchange *and* high violation) — the main program's help text names it directly.

  This is not a flourish; it is what makes the loop move. A plain worst-violation search returns a
  scenario sitting at the *top* of the allowed range, which cuts the master by nothing and stalls
  it. The `0.001` cap prices a low exchange so the medial returns the strongest cut it can find,
  and the `100·E` cap stops it collapsing onto the worthless scenario at zero. Both are
  non-negative exactly on `0 ≤ E ≤ E_max`, so `obj > 0` still means precisely "a violation exists
  strictly inside the range", which is the termination test. `PowsyblWorstCase.discretization_exchange`
  implements the pair, and the weight is small on purpose: raising `0.001` *loosens* the cap, which
  weakens the cuts — measured, `1e-2` fails to converge in 30 rounds where `1e-3` takes 8.

  The blind spot is the flip side. A balanced medial says nothing about the **ends** of the range,
  so the master stops a hair above the truth: on the corridor fixture it returns 50.0057 where the
  cut programme returns 50.0 exactly. That is what "balanced scenario generation did not finish"
  guards against, and why level 1 of `--force-worst-case-gen` asks for an unbalanced sweep
  afterwards — our certificate catches exactly that overshoot (`φ = 3.8e-5` at `E = 50.0057`).
* **`wcgen`** drops that balance term and instead *constrains* the exchange to the range, so it is
  the **pure worst-violation search** — the same quantity as our oracle's `φ`.
* **`aux`** is the odd one out and is genuinely a different algorithm: it **minimises the
  exchange** subject to a violation of at least the restriction `ε_R` being forced at every point —
  the restriction-of-the-right-hand-side scheme. Its two knobs are an initial restriction and a
  reduction factor, matching `solve_rrhs`'s `epsilon` and `beta`.

**`aux` is a program we already had.** `min E` subject to a forced violation at every menu point is
exactly `PowsyblWorstCase.min_violating_exchange`, and its `restriction` is `ε_R` **negated**: ours
is a margin the grid must keep, theirs an overload the scenario must reach. So one function covers
both directions, and running it at `+ε` and `−ε` encloses the answer —
`PowsyblFlexibility.exchange_bracket` is that pair under a geometric restriction schedule, which is
the reference's initial-restriction/reduction-factor pair. The lower bound is a transfer shown to be
securable, the upper one a transfer shown not to be; both hold from the first round, because the
exit test verifies each candidate against the full corrective freedom rather than against the menu.

What is *not* yet reproduced is running the two concurrently. Our two legs are independent solves
and could be raced the way the reference races `aux` against `mlp`; today they run in sequence.

**`wcgen` reads across just as directly.** Dropping the balance term and constraining the exchange
to `[0, E_max]` leaves `max_v min_{u_c} max_{e,s} ratio` over that range — the oracle's `φ` with an
exchange range instead of a fixed set. `PowsyblFlexibility.certifying_scenario` is that call plus
the bookkeeping the reference wraps around it: the range is stepped just inside the reported bound
(their `− 0.25·abs_tol`) so a scenario sitting on the boundary cannot fail on rounding, and an
optional percentage extension looks deliberately *past* the bound to produce an illustrative
failure — which, as their own help text says, is why only a zero extension tests the interval.

Answering "where does it fail" needed one addition on the worst-case side: the oracle now reports
the [`Binding`](../../worstcase) element — branch, state, outage, direction — that `φ` was attained
on. Each overload expression is labelled as it is built, and whichever epigraph bound the response
ends up sitting on is the one named. Without it the certificate is a number, not evidence.

### The bound bookkeeping (settled from the solver sources)

The scheme **minimises internally**, which flips the sign of the objective and swaps which bound is
which — the source says so in as many words. With that fixed, the rules are:

* the **relaxation** branch (`ε_R = 0`) records its objective as a valid bound **unconditionally**,
  whether or not the point turns out feasible for the full problem;
* the **restricted** branch (`ε_R > 0`) stores an incumbent **only after** the candidate passes the
  actual lower-level check, and only when it improves on the best so far (the incumbent is
  monotone);
* `ε_R` is divided by the reduction factor in **two** situations: when the restricted problem comes
  back infeasible (the restriction was too aggressive) *and* when it succeeds (tighten it for a
  better incumbent next round);
* the relaxation and the restriction each carry **their own discretization**, and a point is added
  only when its lower-level solution actually produces a cut.

Reading this settled a defect on our side: `restriction` had drifted to mean opposite things in our
two formulations — tightening the security test reports a *smaller* (conservative) frontier, while
demanding a larger violation in the minimum-exchange program reported a *larger* (optimistic) one.
It is now a security margin in both, so tightening always moves the reported frontier down.

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

## Cross-validation against the reference six-bus benchmark

The reference ships a six-bus instance with a closed-form maximum exchange and manually computed
expected values (≈ 354.5 MW in one transfer sense, ≈ 991.0 MW in the other, at a balancing bound of
2000 MW). Porting it produced a clean split of results.

**The network ports exactly.** All six branch susceptances match the reference parameters to 1e-9
(`100/x_pu` in MW/rad), all six nodal injections match, and the nominal case balances to exactly
0.0 MW. Impedances, topology, per-unit scaling and injection signs are therefore all correct.

**The uncertainty model needed one addition, which the benchmark pinpointed.** We modelled
uncertainty as an independent box per bus; the reference couples its uncertain generators through a
shared budget and a single sign, so they all move the same way. Independent boxes therefore allowed
one generator at `+bound` while another sat at `−bound` — an internal transfer a common-mode
forecast error cannot produce. A sweep confirmed the diagnosis before the fix: at the reference's
own setting our frontier collapsed to zero, at a quarter of the freedom the frontiers were finite
and of the right order, and with it removed nothing violated.

With `uncertain_generators` added, **the benchmark reproduces**: all four published maximum
exchanges — both transfer senses at each of two balancing bounds — match to **0.001 MW**, inside
the reference's own 1e-4 pu tolerance. It is now a regression test.

### Bound tightening, our version

We take the same idea but bound **flows per branch** rather than one global angle, which is
tighter and needs no solve: `|P_e| ≤ Σ_n |PTDF_{e,n}|·M_n + Σ_p |PSDF_{e,p}|·max|α_p|`, with `M_n`
following from each bus's generator limits, load and share of the uncertainty. It is evaluated
over every reachable topology — intact, each contingency, and each of those with a trippable
protected shifter removed — and covers every branch, since an out or tripped one still enters the
model through its would-be flow. On the six-bus benchmark this is **4.3× tighter** than the
constant it replaces, and the benchmark reproduces with no hand-tuned setting.

## Gaps / roadmap (highest leverage first)

The model-fidelity list is now closed: per-direction ratings, coupled uncertain generation,
merit-order balancing with emergency reserve, discrete taps and border-inclusive activation are all
covered, and the six-bus benchmark reproduces exactly. What is left is performance and scope:

1. **Jointly optimising the preventive actions `x`** (`solve_esip_bnf` as the outer driver) — the
   only level still missing. Note this is *not* the `ulp`, which is the exchange master and is now
   covered; it is the `flexibility_solver` that `main.cpp` leaves commented out. Exploratory rather
   than parity work.
2. **Racing the two bounding legs** — `analyse_exchange` runs them in sequence; the reference runs
   `aux` and `mlp` concurrently, polling at 50 ms and aborting the loser once both bounds are done.
   Pure wall-clock, and it cannot change the answer. The design question is not the race but
   Julia threads around HiGHS and the Powsybl JNI layer, which is why it is still open.
3. A **corrective line automaton** as a device type, **per-tap admittance** (we keep the susceptance
   tap-independent), and **several cascading full shifters within one state** — scope extensions
   rather than fidelity gaps on the cases we model today.

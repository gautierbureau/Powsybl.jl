# PowsyblRao — remaining work

A native Julia RAO optimizer (JuMP) on top of the Powsybl.jl APIs, implementing the inner
**linear range-action problem** of OpenRAO's `SearchTreeRao`. This document tracks what is
done and what remains. It lives on `claude/rao-jump-base` (PR #28).

Reference: OpenRAO source (upstream `powsybl/powsybl-open-rao`). The linear problem is built
from modular "fillers" under
`ra-optimisation/search-tree-rao/src/main/java/com/powsybl/openrao/searchtreerao/linearoptimisation/algorithms/fillers/`.
Our `_solve_step` / `solve_*` in `rao/src/PowsyblRao.jl` is the monolithic equivalent.

---

## Done (implemented + validated on the real 1.15.0 engine)

- Preventive PST range action, MAX_MIN_MARGIN objective — matches OpenRAO's optimized tap and
  functional cost on the PST-parade fixture (`MarginCoreProblemFiller` + `MaxMinMarginFiller`).
- Discrete-tap MILP (`DiscretePstTapFiller`) and continuous LP.
- SLP outer loop (re-linearize at chosen tap; `max-mip-iterations`).
- PST-movement penalty.
- N-1: post-contingency (outage/curative) CNECs via per-contingency sensitivities.
- Injection (redispatching) range actions via a keyed sensitivity zone
  (`ContinuousRangeActionGroupFiller`) — matches OpenRAO's set point on the redispatch fixture.
- Multiple range actions of mixed types optimized together.
- Deploy to network: `apply!` (PST taps) + `is_secure`.
- Inter-temporal (Marmot-style) ramp coupling: `solve_intertemporal`
  (`GeneratorConstraintsFiller` power gradients).

---

## Remaining work

### A. Objectives
- [ ] **MAX_MIN_RELATIVE_MARGIN** (`MaxMinRelativeMarginFiller`). Divide each CNEC margin by
      its `ptdfZonalSum` (sum of absolute zonal PTDFs to the region boundaries); MILP with a
      sign binary that falls back to the absolute margin when unsecure. Denominator needs the
      relative-margin PTDF boundaries + GLSK (see Blockers). Formula is fully understood from
      the filler.
- [ ] **MIN_COST** (`CostCoreProblemFiller`, `rao-parameters-costly-*` fixtures). Minimize RA
      activation + variation costs subject to security; exercises the injection RA non-trivially
      (the redispatch fixtures expect set point 500, not 0). Different objective, new formulation.
- [ ] **SECURE_FLOW** (the default OpenRAO objective) — stop once all margins ≥ 0.

### B. Range action types
- [ ] **HVDC range actions** (`HVDC_LINE_ACTIVE_POWER` variable). Trivial mirror of injection
      (continuous set point). Sensitivity path already verified on `network_crac.xiidm` (2 real
      HVDC lines). Blocked only on a solvable HVDC fixture for end-to-end validation.
- [ ] **Counter-trade range actions** (`getCracCounterTradeRangeActions`).

### C. Constraints / virtual costs
- [ ] **Loop-flow** (`MaxLoopFlowFiller`) — loop-flow constraints + virtual cost; needs GLSK.
- [ ] **MNEC** (`MnecFiller`) — monitored-only CNECs with an acceptable-margin-decrease and a
      violation virtual cost.
- [ ] **RA usage limits** (`RaUsageLimitsFiller`) — max RAs / max PST / per-TSO caps
      (`get_crac_max_*_usage_limits` accessors already exist).
- [ ] **Do-not-optimize curative CNECs** (`UnoptimizedCnecFiller`).

### D. Multi-instant / curative optimization
- [ ] Optimize **curative** range actions per curative state (not just monitor N-1 CNECs), and
      the **second-preventive** re-optimization (`CastorContingencyScenarios`,
      `CastorSecondPreventive`). We currently deploy only preventive RAs.

### E. Search tree (topological / network actions)
- [ ] The **outer search tree** over discrete topological actions (switch open/close, bus
      splits) whose effect can't be linearized (`searchtree/algorithms/SearchTree.java`). This
      is the single biggest architectural gap; everything above is the *inner* linear problem.

### F. Inter-temporal (Marmot)
- [ ] **Generator unit-commitment**: on/off state, start-up/shut-down, minimum up/down times
      (lead/lag) — the rest of `GeneratorConstraintsFiller` beyond the power gradient.
- [ ] Per-RA / per-generator gradients and durations from real inter-temporal parameters
      (currently a single `gradient` argument in the RA's native unit).

### G. Deploy / evaluation
- [ ] Deploy **injection** (via the `Scalable` module) and **HVDC** range actions in `apply!`
      (currently PST only). Needs the `Scalable` module in the base (see Integration notes) and
      settled keyed-shift semantics.
- [ ] **AC evaluation**: after solving, apply RAs and re-run a full AC load flow to evaluate the
      true margins (OpenRAO does this each iteration), rather than the DC-linear prediction.

### H. API / usability
- [ ] Return per-CNEC flows/margins as a DataFrame; per-instant breakdown.
- [ ] Solver choice / parameters plumbed from a Julia `RaoParameters`-like struct.
- [ ] Read objective/thresholds/units from the CRAC + parameters instead of assuming
      MAX_MIN_MARGIN / MEGAWATT.

---

## Blockers / validation gaps

- **No OpenRAO-solvable fixture** ships for: HVDC, relative margins, or multiple PSTs.
  `crac-v2.8.json` (the only multi-RA-type CRAC) mixes AMPERE/MW thresholds and counter-trade /
  network actions, and **OpenRAO itself fails on it**. These items can be implemented and
  self-validated but not cross-checked against OpenRAO without new fixtures.
- **Relative margins / loop-flow need GLSK PTDFs.** The `ptdfZonalSum` denominator and the
  loop-flow constraints require zonal PTDFs (GLSK-based). The GLSK document reader
  (`Powsybl.GLSK`, PR #26) is **not** in the `rao-jump-base` integration; the
  `SensitivityAnalysis` zones API *is* (so zones can be built if GLSK factors are available).
- **Non-MW thresholds** (AMPERE, etc.) are rejected today; several fixtures use AMPERE.

---

## Integration / infra notes

- `PowsyblRao` (`rao/`) is a sub-package depending on `Powsybl` + `JuMP` + `HiGHS`, kept out of
  the binding library's deps.
- It builds on `claude/rao-jump-base`, the integration branch (PR #28, base = the throwaway
  `claude/rao-jump-integration`) that merges, onto the 1.15 JLL bump: `sensitivity-zones`,
  `rao-crac-depth`, `network-modification`. Once those feature PRs land on `main`, rebase
  `PowsyblRao` onto `main`.
- **The `Scalable` module is NOT in the integration** (it was a separate branch). Needed for
  item G (injection deploy). Either merge it in or add `Network.update_*`-based redispatch.
- Local build/test loop (native libs are the genuine 1.15.0 stack, not a registered JLL):
  1. relax `Project.toml` `Powsybl_jll = "0.4"` → `"0.3, 0.4"` for the artifact override;
  2. rebuild the wrapper `.so` into the overridden artifact dir
     (`/root/.julia/artifacts/c7359a18…`) against `/tmp/bld/pf15` headers/libs;
  3. `Pkg.develop` both `Powsybl` and `rao/`, then `Pkg.test("PowsyblRao")`
     (with `LD_LIBRARY_PATH` = artifact lib + jlcxx lib + `/tmp/jl12/lib`);
  4. **restore `Powsybl_jll = "0.4"` before committing.**
- Don't commit test artifacts (`test/simple-eu.mat`, `test/simple-eu.zip`).

---

## OpenRAO filler → status map

| Filler | Purpose | Status |
|---|---|---|
| `MarginCoreProblemFiller` / `AbstractCoreProblemFiller` | flow = f_ref + Σ sensitivity·Δsetpoint | done |
| `MaxMinMarginFiller` | min-margin objective | done |
| `DiscretePstTapFiller` / `DiscretePstGroupFiller` | discrete PST taps | done (tap; groups TODO) |
| `ContinuousRangeActionGroupFiller` | continuous range actions | done (injection) |
| `GeneratorConstraintsFiller` | inter-temporal ramp + unit-commitment | ramp done; UC TODO |
| `MaxMinRelativeMarginFiller` | relative margins | TODO (A) |
| `CostCoreProblemFiller` | MIN_COST objective | TODO (A) |
| `MaxLoopFlowFiller` | loop-flow constraints/cost | TODO (C) |
| `MnecFiller` | MNEC constraints/cost | TODO (C) |
| `RaUsageLimitsFiller` | RA usage caps | TODO (C) |
| `UnoptimizedCnecFiller` | do-not-optimize curative CNECs | TODO (C) |
| `SearchTree` (outer) | topological actions | TODO (E) — not a filler |

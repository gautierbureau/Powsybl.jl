# PowsyblDcOpf

A native Julia **DC optimal power flow** (DC-OPF) built on the Powsybl.jl APIs with
[JuMP](https://jump.dev) + [HiGHS](https://highs.dev). It reproduces two classic linear-OPF
formulations of a network with a phase-shifting transformer (PST) as a continuous control,
and cross-validates them against a DC load flow on the real engine.

It is a sub-package (its own `Project.toml`), kept out of the `Powsybl` binding library's
dependencies, and dev-depends on the in-repo `Powsybl` plus `JuMP` and `HiGHS`.

## Two formulations

Both minimise `Σ costᵍ·Pg + C_PST·Σ|φ|` subject to nodal balance and branch thermal limits,
with the PST phase-shift angle `φ` a continuous decision variable (`|φ| ≤ 30°`).

* **`theta_formulation`** — the bus-angle (B-θ) formulation. Bus voltage angles `θ`, branch
  flows `P` and PST angles `φ` are variables tied by `P = h·(θ₁ − θ₂ (+ φ))` with
  `h = V₂²/x`, plus Kirchhoff nodal balance at every bus. Uses only the network topology
  (reactances + nominal voltages).
* **`ptdf_formulation`** — the PTDF formulation. Bus angles are eliminated; branch flows are
  `F = PTDF·(nodal injection) + PSDF·φ`, where the **PTDF** (branch flow vs bus injection)
  and **PSDF** (branch flow vs PST phase) matrices come from a DC sensitivity analysis
  (`Powsybl.SensitivityAnalysis`) on the engine.

The two are mathematically equivalent and agree branch-by-branch on the test fixture.

## Fixture

`build_pst_network()` builds the `pst_focus` case: two parallel paths S1→S2 — one bypassing
the PST (`L12a`) and one feeding it (`L1_2a` → `PST_T`) — merging at B2b and exiting to S3 via
`L2b_3`, with generators G1 (cheap, at B1) and G2 (at B3) serving a 250 MW load at B3.

```
              ┌──── L12a ───────────────────────────┐
              │                                      ↓
G1 ────B1────┤                                      B2b ──── L2b_3 ──── B3 ──── G2 / load
              │                                      ↑
              └──── L1_2a ──── B2a ──[ PST_T φ ]─────┘
```

When `L12a` is congested (limit 110 MW), the PST shifts flow onto its own path so that both
generators can keep their least-cost dispatch. The uncongested case leaves the PST at neutral.

## Usage

```julia
using PowsyblDcOpf
const D = PowsyblDcOpf

net = D.build_pst_network()

th = D.theta_formulation(net)   # bus-angle formulation
pt = D.ptdf_formulation(net)    # PTDF formulation (identical result)

th.generation      # Dict("G1" => 200.0, "G2" => 50.0)
th.flows["L12a"]   # 110.0  (binding)
rad2deg(th.phi["PST_T"])   # ≈ 13.18°

# Deploy the dispatch + PST tap and check against a DC load flow
lf = D.validate_with_dc_loadflow(net, th)
```

Thermal limits, generator costs, the solver and the PST penalty are keyword arguments
(`line_max_p`, `tfo_max_p`, `cost`, `optimizer`, `pst_cost`).

## Reference

Ports the DC-OPF experiments from
[`tests-optim/DCOPF`](https://github.com/gautierbureau/tests-optim) (the `theta_formulation`
and `ptdf_formulation` scripts and the `pst_focus` builder) from pypowsybl + pyoptinterface to
Powsybl.jl + JuMP.

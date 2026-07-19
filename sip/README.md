# SemiInfinite

Problem-agnostic solvers for **semi-infinite programs** (SIP) built on [JuMP](https://jump.dev):

```
min_{x ∈ X}  f(x)
s.t.         gᵢ(x, y) ≤ 0    for all y ∈ Y,   i = 1 … m
```

— finitely many decision variables `x`, but infinitely many inequality constraints, one for
every value of a continuous parameter `y ∈ Y`. This is the canonical form of **robust /
worst-case optimisation**, which is the eventual target (worst-case constraints in power
systems); for now the package is deliberately problem-agnostic.

It is a sub-package (its own `Project.toml`) with no dependency on the `Powsybl` bindings — just
JuMP and a solver.

## Design

The **problem** and the **algorithm** are fully separated. A [`SIPProblem`](src/SemiInfinite.jl)
is a plain data object — the objective `f(x)`, the semi-infinite constraint functions
`gᵢ(x, y)`, and the boxes `X` and `Y`. A solver turns it into a sequence of ordinary JuMP
subproblems it hands to an **injectable optimizer** (HiGHS by default). Nothing in the solver
knows anything about the concrete problem, so the same code drives a two-line linear SIP or a
nonlinear robust model.

Each `gᵢ(x, y)` is written once and reused for both subproblems the algorithms need:

* the **decision problem** — minimise `f(x)` subject to `gᵢ(x, y) ≤ 0` at the finitely many
  parameter points discovered so far (a relaxation, so its optimum bounds the true optimum);
* the **separation problem** — for a fixed decision `x̂`, maximise `gᵢ(x̂, y)` over `y ∈ Y` to
  find the worst-case parameter and the largest constraint violation.

so `gᵢ` must accept arguments that are either numbers or JuMP variables.

## Algorithms

* **`solve_bnf`** — Blankenship & Falk (1976) cutting-plane / discretization. Alternate between
  the decision problem over the current discretization and the separation problem at the
  incumbent; when the worst-case violation is within tolerance the incumbent is globally
  optimal, otherwise the worst-case parameter is added and the loop repeats.

_(further solvers — a restriction-based feasible-point variant, the existence-constrained SIP,
and a min-max formulation — are being added incrementally.)_

## Usage

```julia
using SemiInfinite

# min x  s.t.  x ≥ y  ∀ y ∈ [0, 0.5]   →   x* = 0.5
problem = SIPProblem(
    nx = 1, ny = 1,
    x_lower = -10.0, x_upper = 10.0,
    y_lower = 0.0,   y_upper = 0.5,
    objective   = x -> x[1],
    constraints = (x, y) -> y[1] - x[1],   # g(x, y) = y - x ≤ 0
)

result = solve_bnf(problem)
result.status         # :optimal
result.x              # [0.5]
result.discretization # [[0.5]]  — the worst-case parameter that was generated
```

Inject a nonlinear/global optimizer for the separation problem when `gᵢ` is nonconvex in `y`:

```julia
import Ipopt
result = solve_bnf(problem, SIPOptions(llp_optimizer = Ipopt.Optimizer))
```

The default optimizer (HiGHS) covers problems whose subproblems are linear/MILP. `SIPOptions`
also exposes `feas_tol`, `max_iter`, per-role optimizer overrides (`lbp_optimizer`,
`llp_optimizer`) and `verbose`.

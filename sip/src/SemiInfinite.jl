# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

"""
    SemiInfinite

Problem-agnostic solvers for **semi-infinite programs** (SIP) built on JuMP:

    min_{x ∈ X}  f(x)
    s.t.         gᵢ(x, y) ≤ 0   for all y ∈ Y,   i = 1 … m

i.e. finitely many decision variables `x` constrained by infinitely many inequalities, one for
every value of the parameter `y` in a continuous set `Y`. Such problems are the backbone of
robust / worst-case optimisation.

The design keeps the *problem* (objective, semi-infinite constraints, the boxes `X` and `Y`)
completely separate from the *algorithm*: a [`SIPProblem`](@ref) is a plain data object, and a
solver such as [`solve_bnf`](@ref) turns it into a sequence of ordinary JuMP subproblems it
solves with an injectable optimizer (HiGHS by default). Nothing in the solvers knows anything
about the concrete problem — the exact same code drives a two-line linear SIP or a nonlinear
robust power-system model.
"""
module SemiInfinite

using JuMP
import HiGHS

export SIPProblem, SIPOptions, SIPResult, solve_bnf

# ---------------------------------------------------------------------------
# Problem definition
# ---------------------------------------------------------------------------
"""
    SIPProblem(; nx, ny, x_lower, x_upper, y_lower, y_upper,
               objective, constraints, sense = :Min, x_integer = false)

A semi-infinite program.

* `nx`, `ny` — dimensions of the decision `x` and the parameter `y`.
* `x_lower`/`x_upper`, `y_lower`/`y_upper` — box bounds (scalars are broadcast to every
  component).
* `objective` — `f(x)`: a function of the length-`nx` vector `x` returning a scalar JuMP
  expression (or number).
* `constraints` — one function `gᵢ(x, y)` per semi-infinite constraint (a single function is
  wrapped in a vector). Each returns a scalar expression; the constraint is `gᵢ(x, y) ≤ 0` for
  all `y ∈ Y`. Every `gᵢ` must accept `x`/`y` that are either numbers or JuMP variables, so it
  is reused verbatim to build both the decision subproblem (numeric `y`) and the separation
  subproblem (numeric `x`).
* `sense` — `:Min` (default) or `:Max` for the objective.
* `x_integer` — per-component integrality of `x` (scalar broadcast).
"""
struct SIPProblem
    nx::Int
    ny::Int
    x_lower::Vector{Float64}
    x_upper::Vector{Float64}
    y_lower::Vector{Float64}
    y_upper::Vector{Float64}
    objective::Function
    constraints::Vector{Function}
    sense::Symbol
    x_integer::Vector{Bool}
end

_vec(v, n) = v isa AbstractVector ? collect(Float64, v) : fill(Float64(v), n)
_bvec(v, n) = v isa AbstractVector ? collect(Bool, v) : fill(Bool(v), n)

function SIPProblem(; nx::Int, ny::Int, x_lower, x_upper, y_lower, y_upper,
                    objective::Function, constraints, sense::Symbol = :Min, x_integer = false)
    cs = constraints isa Function ? Function[constraints] : Function[c for c in constraints]
    sense in (:Min, :Max) || throw(ArgumentError("sense must be :Min or :Max"))
    return SIPProblem(nx, ny, _vec(x_lower, nx), _vec(x_upper, nx), _vec(y_lower, ny),
                      _vec(y_upper, ny), objective, cs, sense, _bvec(x_integer, nx))
end

"Number of semi-infinite constraint families."
n_constraints(p::SIPProblem) = length(p.constraints)

# ---------------------------------------------------------------------------
# Options and result
# ---------------------------------------------------------------------------
"""
    SIPOptions(; optimizer = HiGHS.Optimizer, lbp_optimizer = nothing,
               llp_optimizer = nothing, feas_tol = 1e-6, opt_tol = 1e-6,
               max_iter = 100, verbose = false, silent = true, dedup_tol = 1e-8)

Solver settings. `optimizer` is used for every subproblem unless a role-specific override is
given: `lbp_optimizer` for the (lower-bounding) decision problem and `llp_optimizer` for the
(lower-level) separation problem — inject a nonlinear/global optimizer there when the
separation is nonconvex in `y`. `feas_tol` is the maximum constraint violation accepted at
termination; `dedup_tol` avoids adding duplicate discretization points.
"""
Base.@kwdef struct SIPOptions
    optimizer = HiGHS.Optimizer
    lbp_optimizer = nothing
    llp_optimizer = nothing
    feas_tol::Float64 = 1e-6
    opt_tol::Float64 = 1e-6
    max_iter::Int = 100
    verbose::Bool = false
    silent::Bool = true
    dedup_tol::Float64 = 1e-8
end

_lbp_opt(o::SIPOptions) = o.lbp_optimizer === nothing ? o.optimizer : o.lbp_optimizer
_llp_opt(o::SIPOptions) = o.llp_optimizer === nothing ? o.optimizer : o.llp_optimizer

"""
    SIPResult

* `status`        — `:optimal`, `:infeasible` or `:max_iter`.
* `x`             — the incumbent decision (certified feasible when `status == :optimal`).
* `objective`     — `f(x)` at the incumbent.
* `bound`         — the last valid bound on the optimum from the decision subproblem.
* `iterations`    — outer iterations performed.
* `max_violation` — the largest `gᵢ(x, y*)` over the separation problems at termination.
* `discretization`— the accumulated worst-case parameter points `y*` (the generated cuts).
* `history`       — per-iteration `(iter, bound, max_violation, n_disc)` records.
"""
struct SIPResult
    status::Symbol
    x::Vector{Float64}
    objective::Float64
    bound::Float64
    iterations::Int
    max_violation::Float64
    discretization::Vector{Vector{Float64}}
    history::Vector{NamedTuple}
end

# ---------------------------------------------------------------------------
# Subproblem builders
# ---------------------------------------------------------------------------
# Decision (lower-bounding) problem: minimise/maximise f(x) subject to the semi-infinite
# constraints enforced only at the accumulated parameter points `Y`. `restriction ≥ 0` tightens
# each constraint to gᵢ(x, y) ≤ -restriction (used by the restriction-based feasible-point
# variants); 0 gives the plain relaxation whose optimum bounds the true SIP optimum.
function _build_decision_problem(p::SIPProblem, Y, opts::SIPOptions; restriction::Float64 = 0.0)
    model = Model(_lbp_opt(opts))
    opts.silent && set_silent(model)
    @variable(model, x[i = 1:p.nx])
    for i in 1:p.nx
        set_lower_bound(x[i], p.x_lower[i])
        set_upper_bound(x[i], p.x_upper[i])
        p.x_integer[i] && set_integer(x[i])
    end
    @objective(model, p.sense == :Min ? MOI.MIN_SENSE : MOI.MAX_SENSE, p.objective(x))
    for y in Y, i in 1:n_constraints(p)
        @constraint(model, p.constraints[i](x, y) <= -restriction)
    end
    return model, x
end

# Separation (lower-level) problem for constraint i at a fixed decision x̂: maximise
# gᵢ(x̂, y) over y ∈ Y. Its optimal value is the worst-case violation (> 0 ⇒ x̂ infeasible)
# and its argmax is the parameter point to add to the discretization.
function _solve_separation(p::SIPProblem, x_hat, i::Int, opts::SIPOptions)
    model = Model(_llp_opt(opts))
    opts.silent && set_silent(model)
    @variable(model, y[j = 1:p.ny])
    for j in 1:p.ny
        set_lower_bound(y[j], p.y_lower[j])
        set_upper_bound(y[j], p.y_upper[j])
    end
    @objective(model, Max, p.constraints[i](x_hat, y))
    optimize!(model)
    st = termination_status(model)
    st in (MOI.OPTIMAL, MOI.LOCALLY_SOLVED) ||
        error("separation problem $i terminated with status $st")
    return value.(y), objective_value(model)
end

_is_duplicate(y, Y, tol) = any(z -> all(k -> abs(y[k] - z[k]) <= tol, eachindex(y)), Y)

# ---------------------------------------------------------------------------
# Blankenship & Falk (1976) cutting-plane / discretization algorithm
# ---------------------------------------------------------------------------
"""
    solve_bnf(problem::SIPProblem, options::SIPOptions = SIPOptions()) -> SIPResult

Solve `problem` with the Blankenship & Falk cutting-plane algorithm.

Each iteration solves the decision problem over the current finite discretization `Y ⊂ Y`
(a valid bound on the optimum), then, for every semi-infinite constraint, solves the
separation problem `max_y gᵢ(x̂, y)` at the incumbent `x̂`. If the largest violation is within
`feas_tol`, `x̂` is feasible for the full (infinite) constraint set and, being optimal for a
relaxation, is globally optimal — the algorithm stops. Otherwise the worst-case parameter
points are appended to `Y` and the process repeats.
"""
function solve_bnf(problem::SIPProblem, options::SIPOptions = SIPOptions())
    Y = Vector{Float64}[]
    history = NamedTuple[]
    bound = problem.sense == :Min ? -Inf : Inf
    x_inc = fill(NaN, problem.nx)
    f_inc = NaN
    max_violation = Inf
    status = :max_iter
    iterations = 0

    for k in 1:options.max_iter
        iterations = k

        model, x = _build_decision_problem(problem, Y, options)
        optimize!(model)
        st = termination_status(model)
        if st in (MOI.INFEASIBLE, MOI.INFEASIBLE_OR_UNBOUNDED)
            status = :infeasible
            break
        end
        st in (MOI.OPTIMAL, MOI.LOCALLY_SOLVED) ||
            error("decision problem terminated with status $st")

        bound = objective_value(model)
        x_hat = value.(x)
        x_inc = x_hat
        f_inc = bound

        max_violation = -Inf
        cuts = Vector{Float64}[]
        for i in 1:n_constraints(problem)
            y_star, violation = _solve_separation(problem, x_hat, i, options)
            violation > max_violation && (max_violation = violation)
            violation > options.feas_tol && push!(cuts, y_star)
        end

        push!(history, (iter = k, bound = bound, max_violation = max_violation, n_disc = length(Y)))
        options.verbose &&
            @info "BNF" iter = k bound = bound max_violation = max_violation n_disc = length(Y)

        if max_violation <= options.feas_tol
            status = :optimal
            break
        end
        for y in cuts
            _is_duplicate(y, Y, options.dedup_tol) || push!(Y, y)
        end
    end

    return SIPResult(status, x_inc, f_inc, bound, iterations, max_violation, Y, history)
end

end # module

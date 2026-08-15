# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

"""
    PowsyblFlexibility

Flexibility maximisation on a power grid — the **outer** level of the three-level worst-case
formulation, built on top of [`PowsyblWorstCase`](../worstcase)'s feasibility oracle.

Flexibility is the *amount of injection uncertainty* the grid can absorb while staying secure in
the worst case. For a `δ`-parameterised uncertainty region `T(δ)` (a box that grows with `δ`),

    δ* = max { δ ≥ 0 : the grid is secure for every y ∈ T(δ) }

The security test `∀ y ∈ T(δ) ∃ corrective : all limits met` is exactly the oracle's `φ ≤ 0`.
Since `φ` increases monotonically with `δ`, `δ*` is found by bisection ([`flexibility_max`](@ref)).

A cheap **copper-plate oracle** ([`copperplate_bound`](@ref)) — the grid with *all branch limits
removed*, so only global power balance and generator capacity remain — provides an upper bound
`δ_cp ≥ δ*` (removing constraints can only enlarge the manageable region) and a fast feasibility
pre-filter (copper-plate infeasibility implies network infeasibility, no MILP needed).
"""
module PowsyblFlexibility

using Powsybl
using PowsyblWorstCase
const W = PowsyblWorstCase

export flexibility_max, copperplate_bound, FlexibilityResult
export max_exchange, copperplate_exchange_interval, ExchangeResult
export exchange_bracket, BracketResult
export certifying_scenario, CertificateResult

# ---------------------------------------------------------------------------
# δ-parameterised uncertainty region
# ---------------------------------------------------------------------------
# A per-bus growth weight is either a scalar `w` (symmetric) or a pair `(w_lo, w_hi)` (per side).
_wpair(wv) = wv isa Tuple ? (Float64(wv[1]), Float64(wv[2])) : (Float64(wv), Float64(wv))

# T(δ) grows each base box `(lo, hi)` outward by `δ · weight` per side:
#   T(δ) = { lo − δ·w_lo ≤ y ≤ hi + δ·w_hi }.
function _region(base, w, δ)
    out = Dict{String,Tuple{Float64,Float64}}()
    for (b, (lo, hi)) in base
        wlo, whi = _wpair(get(w, b, 0.0))
        out[b] = (lo - δ * wlo, hi + δ * whi)
    end
    return out
end

# ---------------------------------------------------------------------------
# Copper-plate oracle (network-free adequacy)
# ---------------------------------------------------------------------------
# With every branch limit dropped the grid collapses to a single bus: the only requirement is
# that the responding generation can rebalance the net injection change ΣΔ = −Σy within its
# limits. The worst y over a box is a vertex, so feasibility reduces to an interval check on Σy.
function _responding(gm, participation)
    if participation === nothing
        return [g for g in gm.generators if g.bus == gm.slack]
    end
    return [g for g in gm.generators if haskey(participation, g.id)]
end

# Up/down regulating headroom of the responding set (MW).
function _headroom(gm, participation)
    resp = _responding(gm, participation)
    up = sum((g.pmax - g.p0 for g in resp); init = 0.0)      # extra generation available
    down = sum((g.p0 - g.pmin for g in resp); init = 0.0)    # generation that can be shed
    return up, down
end

# Copper-plate over-adequacy of a box (MW): > 0 ⇒ some y ∈ box cannot be balanced.
function _copperplate_phi(gm, box, participation)
    up, down = _headroom(gm, participation)
    Σlo = sum((lo for (lo, hi) in values(box)); init = 0.0)
    Σhi = sum((hi for (lo, hi) in values(box)); init = 0.0)
    # surplus (Σy > 0) needs down-headroom; deficit (Σy < 0) needs up-headroom.
    return max(Σhi - down, -Σlo - up)
end

"""
    copperplate_bound(network, base; weights = nothing, participation = nothing,
                      slack = nothing) -> (delta_cp, phi0)

Copper-plate upper bound on the flexibility. `delta_cp` is the largest `δ` for which the
`δ`-grown region is still balanceable by the responding generation *ignoring all branch limits*
— hence `delta_cp ≥ δ*`. `phi0` is the copper-plate over-adequacy of the base box (`> 0` ⇒ the
forecast box itself cannot be balanced, so `δ* = 0`). `delta_cp` is `Inf` when the region does
not grow (all weights zero).
"""
function copperplate_bound(network, base::AbstractDict; weights = nothing,
                           participation = nothing, slack = nothing)
    gm = W.GridModel(network; slack = slack)
    w = weights === nothing ? Dict(b => 1.0 for b in keys(base)) : weights
    up, down = _headroom(gm, participation)
    Σlo = sum((lo for (lo, hi) in values(base)); init = 0.0)
    Σhi = sum((hi for (lo, hi) in values(base)); init = 0.0)
    Σwlo = sum((_wpair(get(w, b, 0.0))[1] for b in keys(base)); init = 0.0)
    Σwhi = sum((_wpair(get(w, b, 0.0))[2] for b in keys(base)); init = 0.0)
    phi0 = max(Σhi - down, -Σlo - up)
    # surplus grows Σhi against down-headroom; deficit grows −Σlo against up-headroom.
    δ_cp = Inf
    Σwhi > 0 && (δ_cp = min(δ_cp, (down - Σhi) / Σwhi))
    Σwlo > 0 && (δ_cp = min(δ_cp, (up + Σlo) / Σwlo))
    return (isfinite(δ_cp) ? max(0.0, δ_cp) : Inf, phi0)
end

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
"""
    FlexibilityResult

* `delta`           — the flexibility metric `δ*` (largest manageable region scaling).
* `delta_cp`        — the copper-plate upper bound (`delta_cp ≥ delta`).
* `secure_at_base`  — whether the forecast box `T(0)` is itself secure (else `delta = 0`).
* `worst_injection` — the binding worst-case injection `y*` at `T(δ*)`.
* `iterations`      — bisection steps taken.
"""
struct FlexibilityResult
    delta::Float64
    delta_cp::Float64
    secure_at_base::Bool
    worst_injection::Dict{String,Float64}
    iterations::Int
end

# ---------------------------------------------------------------------------
# Flexibility maximisation (fixed preventive dispatch)
# ---------------------------------------------------------------------------
"""
    flexibility_max(network; base, monitored, weights = nothing, participation = nothing,
                    slack = nothing, delta_max = 1e4, tol = 1e-2, oracle_kwargs...) -> FlexibilityResult

Maximise the flexibility `δ` for a *fixed* preventive dispatch: the largest scaling of the
uncertainty region `T(δ)` for which the grid stays secure in the worst case.

* `base` — the forecast uncertainty box `Dict(bus => (lo, hi))` (deviations in MW); `T(δ)` grows
  it outward by `δ · weight` per side.
* `weights` — per-bus growth weights (default `1.0` for every bus in `base`).
* `monitored`, `participation`, and any further `oracle_kwargs` (`correctives`, `contingencies`,
  `hvdc`, `switchable`, `pst_limits`, `pst_model`, `bigM`, …) are forwarded to
  [`PowsyblWorstCase.worst_case_oracle`](@ref).

`φ(δ)` is monotone in `δ`, so `δ*` is bisected on `[0, min(delta_cp, delta_max)]`; each step is
gated by the copper-plate pre-filter (skips the MILP oracle when the region already fails
power-balance adequacy). `tol` is the bisection tolerance on `δ`.
"""
function flexibility_max(network; base::AbstractDict, monitored::AbstractDict,
                         weights = nothing, participation = nothing, slack = nothing,
                         delta_max = 1e4, tol = 1e-2, oracle_kwargs...)
    gm = W.GridModel(network; slack = slack)
    w = weights === nothing ? Dict(b => 1.0 for b in keys(base)) : weights
    delta_cp, _ = copperplate_bound(network, base; weights = w, participation = participation, slack = slack)

    last_worst = Ref(Dict{String,Float64}(b => 0.0 for b in keys(base)))
    iters = Ref(0)
    function secure(δ)
        box = _region(base, w, δ)
        _copperplate_phi(gm, box, participation) > 1e-9 && return false   # cheap reject
        iters[] += 1
        sol = W.worst_case_oracle(network; uncertain = box, monitored = monitored,
                                  participation = participation, slack = slack, oracle_kwargs...)
        last_worst[] = sol.worst_injection
        return W.is_secure(sol)
    end

    if !secure(0.0)
        return FlexibilityResult(0.0, delta_cp, false, last_worst[], iters[])
    end
    upper = min(delta_cp, delta_max)
    if upper <= tol || secure(upper)
        return FlexibilityResult(upper, delta_cp, true, last_worst[], iters[])
    end
    lo, hi = 0.0, upper
    while hi - lo > tol
        mid = 0.5 * (lo + hi)
        secure(mid) ? (lo = mid) : (hi = mid)
    end
    return FlexibilityResult(lo, delta_cp, true, last_worst[], iters[])
end

# ---------------------------------------------------------------------------
# Maximum exchange (the power-transfer parameterisation)
# ---------------------------------------------------------------------------
"""
    ExchangeResult

* `emax`      — the largest manageable exchange (zone import beyond forecast, MW).
* `interval`  — the copper-plate exchange interval `(lo, hi)`, an outer bound on what is
                attainable at all; `emax ≤ hi`.
* `secure_at_zero` — whether the forecast exchange itself is secure (else `emax = 0`).
* `worst_injection`, `iterations`.
"""
struct ExchangeResult
    emax::Float64
    interval::Tuple{Float64,Float64}
    secure_at_zero::Bool
    worst_injection::Dict{String,Float64}
    iterations::Int
end

"""
    copperplate_exchange_interval(network, zone; participation = nothing, slack = nothing)
        -> (lo, hi)

The exchange interval attainable **ignoring every branch limit** — the copper plate. Only global
power balance and generator capacity remain, so an import of `E` by `zone` must be covered by the
responding generation's up-regulating headroom and an export by its down-regulating headroom.
Removing the line limits can only enlarge the manageable set, so the true maximum exchange lies
inside this interval; it brackets the search and rejects hopeless targets without an MILP.

Following the reference construction the interval is computed in both directions and intersected.
"""
function copperplate_exchange_interval(network, zone; participation = nothing, slack = nothing)
    gm = W.GridModel(network; slack = slack)
    up, down = _headroom(gm, participation)
    # zone imports E > 0 ⇒ deficit E covered by up-regulation; exports E < 0 ⇒ surplus by down.
    return (-down, up)
end

"""
    max_exchange(network; zone, box, monitored, participation = nothing, slack = nothing,
                 emax_cap = nothing, method = :cuts, tol = 1e-2, oracle_kwargs...) -> ExchangeResult

Largest **exchange** — net import by `zone` beyond its forecast — for which the grid stays secure
in the worst case, for a fixed preventive dispatch.

* `zone` — the buses whose net injection deviation is the exchange.
* `box`  — per-bus deviation bounds `Dict(bus => (lo, hi))`, bounding how an exchange may be
  *composed*; the exchange itself is what is maximised.
* `method` — `:cuts` (default) makes the exchange the *objective*: one solve returns the smallest
  exchange at which correction fails, which **is** the frontier. `:bisection` instead probes
  transfer levels with the security oracle; it is slower and only as accurate as `tol`, and is
  kept as an independent cross-check.
* everything else is forwarded to [`PowsyblWorstCase.worst_case_oracle`](@ref).

The copper-plate interval bounds the search in either case.
"""
function max_exchange(network; zone, box::AbstractDict, monitored::AbstractDict,
                      participation = nothing, slack = nothing, emax_cap = nothing,
                      method::Symbol = :cuts, tol = 1e-2, oracle_kwargs...)
    zone = collect(String, zone)
    lo_cp, hi_cp = copperplate_exchange_interval(network, zone; participation = participation, slack = slack)
    if method === :cuts
        cap = emax_cap === nothing ? hi_cp : min(hi_cp, emax_cap)
        isfinite(cap) || throw(ArgumentError("unbounded exchange search: pass `emax_cap` or give " *
                                             "the responding generators finite limits"))
        r = W.min_violating_exchange(network; zone = zone, uncertain = box, monitored = monitored,
                                     e_cap = cap, participation = participation, slack = slack,
                                     oracle_kwargs...)
        r === nothing && return ExchangeResult(cap, (lo_cp, hi_cp), true,
                                               Dict{String,Float64}(n => 0.0 for n in keys(box)), 1)
        e, v = r
        return ExchangeResult(e, (lo_cp, hi_cp), e > 0.0, v, 1)
    end
    method === :bisection || throw(ArgumentError("unknown method $(method); use :cuts or :bisection"))
    last_worst = Ref(Dict{String,Float64}(n => 0.0 for n in keys(box)))
    iters = Ref(0)
    # import is a *negative* injection deviation in the zone, so an import cap of `e` is the
    # exchange range [-e, 0].
    function secure(e)
        e > hi_cp + 1e-9 && return false            # beyond copper-plate adequacy
        iters[] += 1
        sol = W.worst_case_oracle(network; uncertain = box, monitored = monitored,
                                  participation = participation, slack = slack,
                                  exchange = (buses = zone, lo = -e, hi = 0.0), oracle_kwargs...)
        last_worst[] = sol.worst_injection
        return W.is_secure(sol)
    end

    if !secure(0.0)
        return ExchangeResult(0.0, (lo_cp, hi_cp), false, last_worst[], iters[])
    end
    upper = emax_cap === nothing ? hi_cp : min(hi_cp, emax_cap)
    if !isfinite(upper)
        throw(ArgumentError("unbounded exchange search: pass `emax_cap` or give the responding " *
                            "generators finite limits"))
    end
    if upper <= tol || secure(upper)
        return ExchangeResult(upper, (lo_cp, hi_cp), true, last_worst[], iters[])
    end
    lo, hi = 0.0, upper
    while hi - lo > tol
        mid = 0.5 * (lo + hi)
        secure(mid) ? (lo = mid) : (hi = mid)
    end
    return ExchangeResult(lo, (lo_cp, hi_cp), true, last_worst[], iters[])
end

# ---------------------------------------------------------------------------
# Two-sided bounding of the maximum exchange
# ---------------------------------------------------------------------------
# The same menu program bounds the frontier from either side depending on the sign of its
# restriction: demanding a margin makes failure easier to reach and reports an achievable value
# *below* the frontier, tolerating an overload makes it harder and reports a value *above* it. Run
# both under a shrinking restriction and the two meet, each carrying its own guarantee — which is
# what the reference obtains by running its auxiliary heuristic alongside the canonical medial
# programme, its restriction parameter being ours with the opposite sign.
#
# Where a single exact solve is affordable this is strictly more work for the same number. It earns
# its keep when it is not: the bounds are valid from the first round, so the loop can be stopped on
# a bracket that is merely good enough, and the lower one is a transfer that has been shown to be
# securable rather than one believed to be.
# ---------------------------------------------------------------------------

"""
Result of [`exchange_bracket`](@ref) — the maximum exchange enclosed from both sides.

`lower` is **guaranteed achievable** (the grid is securable across `[0, lower]`), `upper` is a
**certified outer bound** (no transfer above it can be held), and the answer lies in between.
`restriction` is the margin the bracket closed at, `rounds` the number of restriction levels
tried — each costing two solves — and `worst_injection` the scenario witnessing `upper`.
"""
struct BracketResult
    lower::Float64
    upper::Float64
    restriction::Float64
    rounds::Int
    interval::Tuple{Float64,Float64}
    worst_injection::Dict{String,Float64}
end

"""
    exchange_bracket(network; zone, box, monitored, init_restriction = 0.1, reduction = 0.25,
                     tol = 1e-2, max_rounds = 8, emax_cap = nothing, ...) -> BracketResult

Enclose the maximum exchange between a **guaranteed-achievable** lower bound and a **certified**
upper bound, by running [`PowsyblWorstCase.min_violating_exchange`](@ref) at `+ε` and at `−ε` for a
geometrically shrinking `ε`.

The restriction starts at `init_restriction` and is multiplied by `reduction` each round; the loop
stops once `upper − lower ≤ tol` or after `max_rounds`. Bounds accumulate monotonically, so the
result is the tightest pair seen and remains valid however early the loop is cut short.

Both bounds carry a guarantee at every round, not only on convergence, so a bracket that has not
closed is still a usable answer: report `lower` to be safe, `upper` to know what is ruled out.
Arguments are those of [`max_exchange`](@ref); everything beyond them is forwarded to the oracle.
"""
function exchange_bracket(network; zone, box::AbstractDict, monitored::AbstractDict,
                          participation = nothing, slack = nothing, emax_cap = nothing,
                          init_restriction = 0.1, reduction = 0.25, tol = 1e-2, max_rounds = 8,
                          oracle_kwargs...)
    init_restriction > 0 || throw(ArgumentError("init_restriction must be positive"))
    0 < reduction < 1 || throw(ArgumentError("reduction must lie strictly between 0 and 1"))
    zone = collect(String, zone)
    lo_cp, hi_cp = copperplate_exchange_interval(network, zone; participation = participation, slack = slack)
    cap = emax_cap === nothing ? hi_cp : min(hi_cp, emax_cap)
    isfinite(cap) || throw(ArgumentError("unbounded exchange search: pass `emax_cap` or give the " *
                                         "responding generators finite limits"))

    # `nothing` means no scenario within the cap defeats correction at that restriction, so the cap
    # itself is the best the leg can say.
    function leg(ε)
        r = W.min_violating_exchange(network; zone = zone, uncertain = box, monitored = monitored,
                                     e_cap = cap, participation = participation, slack = slack,
                                     restriction = ε, oracle_kwargs...)
        return r === nothing ? (cap, Dict{String,Float64}(n => 0.0 for n in keys(box))) : r
    end

    lower, upper = 0.0, cap
    witness = Dict{String,Float64}(n => 0.0 for n in keys(box))
    ε = float(init_restriction)
    closed_at = ε
    rounds = 0
    for _ in 1:max_rounds
        rounds += 1
        closed_at = ε
        lower = max(lower, leg(ε)[1])              # margin demanded ⇒ achievable
        u, w = leg(-ε)                             # overload tolerated ⇒ outer bound
        u < upper && (upper = u; witness = w)
        upper - lower <= tol && break
        ε *= reduction
    end
    # Both legs are exact bounds, so any crossing is solver noise at a bracket already inside `tol`.
    lower = min(lower, upper)
    return BracketResult(lower, upper, closed_at, rounds, (lo_cp, hi_cp), witness)
end

# ---------------------------------------------------------------------------
# Certifying scenario
# ---------------------------------------------------------------------------
# A reported maximum exchange is a claim about a whole range: *every* transfer up to it can be held
# against every uncertainty. Searching that range for the worst violation settles the claim — no
# violation and the range is confirmed, a violation and the scenario producing it is exactly the
# counter-example. Either way the answer stops being a number the solver asserts and becomes one
# that can be checked, which is why the reference runs this as a post-processing step over its own
# reported interval rather than as part of the loop.
#
# It is the same medial programme the frontier search uses, with the low-exchange preference
# dropped and the exchange constrained to the reported range instead — so it is the oracle's `φ`
# over that range, and no new grid model is needed.
# ---------------------------------------------------------------------------

"""
Result of [`certifying_scenario`](@ref).

`clear` is `true` when nothing in the searched range violates. With `extension = 0` that confirms
the reported interval; with an extension it merely reports what was found beyond it. When `clear`
is `false`, the remaining fields *are* the counter-example: `phi` how badly it fails, `exchange` the
transfer it sits at, `injection` the deviations realising it, `binding` the branch, state and
direction that gave way, and `corrective` the best response that still could not save it.
"""
struct CertificateResult
    clear::Bool
    phi::Float64
    exchange::Float64
    injection::Dict{String,Float64}
    binding::Union{Nothing,W.Binding}
    corrective::Dict{String,Dict{String,Float64}}
    tested::Tuple{Float64,Float64}
end

"""
    certifying_scenario(network; zone, box, monitored, emax, extension = 0.0, step_in = 1e-6, ...)
        -> CertificateResult

Search the whole reported exchange range `[0, emax]` for the worst violation, certifying the range
if none exists and producing the binding scenario if one does.

This is the check that turns a reported maximum exchange into a claim that can be verified: the
frontier search says where the boundary is, this says whether the region below it really holds, and
names what gives way if it does not.

`extension` widens the searched range by that percentage of `emax`. **Only `extension = 0` is a
valid test of the reported interval** — a widened search deliberately looks past the boundary to
produce an illustrative failure, so a violation it finds says nothing about the interval itself.
`step_in` (MW) nudges the upper end just inside the reported bound so that a scenario sitting
exactly on the boundary cannot fail the test on rounding alone.

Arguments otherwise match [`max_exchange`](@ref); everything beyond them is forwarded to the oracle.
"""
function certifying_scenario(network; zone, box::AbstractDict, monitored::AbstractDict, emax::Real,
                             extension = 0.0, step_in = 1e-6, participation = nothing,
                             slack = nothing, oracle_kwargs...)
    extension >= 0 || throw(ArgumentError("extension must be a non-negative percentage"))
    zone = collect(String, zone)
    hi = max(0.0, float(emax) * (1 + extension / 100) - step_in)
    sol = W.worst_case_oracle(network; uncertain = box, monitored = monitored,
                              participation = participation, slack = slack,
                              exchange = (buses = zone, lo = -hi, hi = 0.0), oracle_kwargs...)
    # an import is a negative deviation, so the transfer the scenario realises is minus the sum
    e = -sum(get(sol.worst_injection, n, 0.0) for n in zone; init = 0.0)
    return CertificateResult(W.is_secure(sol), sol.phi, e, sol.worst_injection, sol.binding,
                             sol.corrective, (0.0, hi))
end

end # module

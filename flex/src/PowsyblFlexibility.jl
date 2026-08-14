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
                 emax_cap = nothing, tol = 1e-2, oracle_kwargs...) -> ExchangeResult

Largest **exchange** — net import by `zone` beyond its forecast — for which the grid stays secure
in the worst case, for a fixed preventive dispatch.

* `zone` — the buses whose net injection deviation is the exchange.
* `box`  — per-bus deviation bounds `Dict(bus => (lo, hi))`, bounding how an exchange may be
  *composed*; the exchange bound itself is what is maximised.
* everything else is forwarded to [`PowsyblWorstCase.worst_case_oracle`](@ref).

The security test is monotone in the exchange bound, so the maximum is bisected inside the
copper-plate interval, with the copper plate also acting as a pre-filter.
"""
function max_exchange(network; zone, box::AbstractDict, monitored::AbstractDict,
                      participation = nothing, slack = nothing, emax_cap = nothing,
                      tol = 1e-2, oracle_kwargs...)
    zone = collect(String, zone)
    lo_cp, hi_cp = copperplate_exchange_interval(network, zone; participation = participation, slack = slack)
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

end # module

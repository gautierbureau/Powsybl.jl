# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

"""
    PowsyblWorstCase

Worst-case (robust) security analysis of a power grid, on a DC network model, built on the
Powsybl.jl APIs with JuMP + HiGHS.

This implements the **feasibility oracle** of the three-level worst-case formulation, with the
four operating **states** of the reference model:

* **0 (nominal)** — forecast injections, no contingency, PST at its preventive angle `α⁰`.
* **N (base)** — pre-contingency but *with* uncertainty; PST still at `α⁰` (no corrective yet).
* **N-1 (post-contingency)** — after a contingency, with uncertainty, *before* correction (`α⁰`).
* **N-1/c (post-corrective)** — after a contingency, with uncertainty *and* the corrective PST
  action. Corrective actions are **per-contingency recourse**: you observe which contingency
  occurred, then choose the correction.

For a fixed preventive dispatch it evaluates

    φ = max_{v ∈ V}  min_{u_c ∈ U_c}  max_{(e, s)}  ( |P_{e,s}(v, u_c)| / P̂_{e,s}^{s} − 1 )

where `v` is the uncertain injection deviation, `u_c` the per-contingency corrective PST angles
(acting only in the post-corrective states), and the inner `max` is the worst per-unit overload
over every monitored branch `e` and state `s`, each with its own (possibly state-dependent)
limit `P̂^{s}`. The grid is **secure** iff `φ ≤ 0`.

`φ` is a min-max and is solved by Falk–Hoffman-style discretization ([`worst_case_oracle`](@ref)):
a mixed-integer *relaxed medial* problem (uncertainty maximises the worst overload against a
growing menu of corrective candidates) alternating with a linear *corrective response* problem,
until the bounds meet.

Scope: uncertainty = injection deviations; correctives = continuous PST phase angles; states =
nominal + base + per-contingency N-1 / N-1/c. The integer-mode PST/HVDC models, topology
switching and redispatch are left out.
"""
module PowsyblWorstCase

using Powsybl
using JuMP
import HiGHS
import DataFrames

const NET = Powsybl.Network

export GridModel, WorstCaseSolution, worst_case_oracle, is_secure

# ---------------------------------------------------------------------------
# DC grid data extracted from a Powsybl network
# ---------------------------------------------------------------------------
struct Branch
    id::String
    bus1::String
    bus2::String
    h::Float64          # DC susceptance V²/x (MW/rad)
    is_pst::Bool
    alpha0::Float64     # preventive/initial phase angle (rad); 0 for plain lines
    alpha_min::Float64
    alpha_max::Float64
end

"""
    GridModel(network; slack = nothing)

Extract a DC model from a Powsybl `network`: buses, a slack bus (its nodal balance is dropped
and its angle fixed to 0), the forecast net injection per bus (`Σ gen.target_p − Σ load.p0`),
and the branches (lines and phase-shifting transformers) with their DC susceptance `h = V₂²/x`,
preventive angle `α⁰` (from the current tap) and corrective angle range.
"""
struct GridModel
    buses::Vector{String}
    slack::String
    injection::Dict{String,Float64}
    branches::Vector{Branch}
end

_rows(df) = 1:DataFrames.nrow(df)

function GridModel(network; slack::Union{Nothing,String} = nothing)
    gens  = NET.get_generators(network, true)
    loads = NET.get_loads(network, true)
    buses = NET.get_buses(network, true)
    lines = NET.get_lines(network, true)
    tfos  = NET.get_2_windings_transformers(network, true)
    psts  = NET.get_phase_tap_changers(network, true)
    steps = NET.get_phase_tap_changer_steps(network, true)
    vls   = NET.get_voltage_levels(network, true)

    nominal_v = Dict(vls[i, :id] => vls[i, :nominal_v] for i in _rows(vls))
    bus_ids = collect(buses.id)

    injection = Dict(b => 0.0 for b in bus_ids)
    for i in _rows(gens); injection[gens[i, :bus_id]] += gens[i, :target_p]; end
    for i in _rows(loads); injection[loads[i, :bus_id]] -= loads[i, :p0]; end

    pst_ids = Set(collect(psts.id))
    # step angles per PST, in tap order (low → high); plus min/max and the current-tap angle.
    alphas = Dict{String,Vector{Float64}}()
    for i in _rows(steps)
        push!(get!(alphas, steps[i, :id], Float64[]), deg2rad(steps[i, :alpha]))
    end
    tap = Dict(psts[i, :id] => psts[i, :tap] for i in _rows(psts))
    lowtap = Dict(psts[i, :id] => psts[i, :low_tap] for i in _rows(psts))
    alpha0 = Dict(id => a[tap[id] - lowtap[id] + 1] for (id, a) in alphas)

    branches = Branch[]
    for i in _rows(lines)
        v2 = nominal_v[lines[i, :voltage_level2_id]]
        push!(branches, Branch(lines[i, :id], lines[i, :bus1_id], lines[i, :bus2_id],
                               v2^2 / lines[i, :x], false, 0.0, 0.0, 0.0))
    end
    for i in _rows(tfos)
        id = tfos[i, :id]
        v2 = nominal_v[tfos[i, :voltage_level2_id]]
        is_pst = id in pst_ids
        a = get(alphas, id, Float64[0.0])
        push!(branches, Branch(id, tfos[i, :bus1_id], tfos[i, :bus2_id],
                               v2^2 / tfos[i, :x_at_current_tap], is_pst,
                               get(alpha0, id, 0.0), minimum(a), maximum(a)))
    end

    sl = slack === nothing ? (isempty(gens.id) ? bus_ids[1] : gens[1, :bus_id]) : slack
    return GridModel(bus_ids, sl, injection, branches)
end

_pst_alpha0(gm::GridModel) = Dict(b.id => b.alpha0 for b in gm.branches if b.is_pst)

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
"""
    WorstCaseSolution

* `phi`            — the worst achievable overload `max_v min_{u_c} max_{e,s}` (`> 0` ⇒ insecure).
* `secure`         — whether `phi ≤ tol`.
* `worst_injection`— the worst-case injection deviation `v*` per uncertain bus (MW).
* `corrective`     — the best corrective PST angles (rad), per contingency: `Dict(cont => Dict(pst => α))`.
* `iterations`     — Falk–Hoffman iterations.
* `lower_bound`/`upper_bound` — the final bracket on `phi`.
"""
struct WorstCaseSolution
    phi::Float64
    secure::Bool
    worst_injection::Dict{String,Float64}
    corrective::Dict{String,Dict{String,Float64}}
    iterations::Int
    lower_bound::Float64
    upper_bound::Float64
end

is_secure(sol::WorstCaseSolution) = sol.secure

# ---------------------------------------------------------------------------
# States (the four-state model)
# ---------------------------------------------------------------------------
# A state carries its outaged branch, whether uncertainty is realised, and — for a
# post-corrective state — the contingency whose corrective PST angles apply in it.
struct State
    name::String
    kind::Symbol                       # :nominal | :base | :contingency | :corrective
    outage::Union{Nothing,String}
    uncertainty::Bool
    corrective_for::Union{Nothing,String}
end

function _states(contingencies)
    out = State[State("nominal", :nominal, nothing, false, nothing),
                State("N", :base, nothing, true, nothing)]
    for c in contingencies
        push!(out, State("N-1[$c]", :contingency, c, true, nothing))
        push!(out, State("N-1/c[$c]", :corrective, c, true, c))
    end
    return out
end

_active(gm::GridModel, out) = out === nothing ? gm.branches : filter(b -> b.id != out, gm.branches)

# Per-state branch limit: a plain number applies to all states; a NamedTuple selects a limit by
# state kind — `base` (used for nominal/base and as the fallback), optional `contingency`
# (temporary N-1 rating) and `corrective` (post-corrective rating).
_limit(v::Number, kind) = v
function _limit(v::NamedTuple, kind)
    kind === :contingency && haskey(v, :contingency) && return v.contingency
    kind === :corrective && haskey(v, :corrective) && return v.corrective
    return v.base
end

# ---------------------------------------------------------------------------
# DC grid layer for one state. `angle_of(pst_id)` returns the angle (variable or number) to use
# for a PST *in this state*; `inj` maps a bus to its injection expression. Returns branch → flow.
# ---------------------------------------------------------------------------
function _add_state!(model, gm::GridModel, out, angle_of, inj, tag)
    active = _active(gm, out)
    θ = Dict(b => @variable(model, base_name = "θ_$(tag)_$(b)") for b in gm.buses)
    fix(θ[gm.slack], 0.0; force = true)
    P = Dict{String,Any}()
    for br in active
        p = @variable(model, base_name = "P_$(tag)_$(br.id)")
        shift = br.is_pst ? angle_of(br.id) : 0.0
        @constraint(model, p == br.h * (θ[br.bus1] - θ[br.bus2] + shift))
        P[br.id] = p
    end
    for n in gm.buses
        n == gm.slack && continue
        out_flow = sum(P[br.id] for br in active if br.bus1 == n; init = AffExpr(0.0))
        in_flow  = sum(P[br.id] for br in active if br.bus2 == n; init = AffExpr(0.0))
        @constraint(model, out_flow - in_flow == inj[n])
    end
    return P
end

# Signed per-unit overloads (both directions) for the monitored branches present in a state,
# using that state's limit. Returns a vector of expressions ±P/P̂ − 1.
function _overloads(P, monitored, kind)
    out = Any[]
    for (id, limspec) in monitored
        haskey(P, id) || continue
        lim = _limit(limspec, kind)
        push!(out, P[id] / lim - 1)
        push!(out, -P[id] / lim - 1)
    end
    return out
end

# Resolve the PST angle for a state, given the corrective angles available for its contingency.
# `corr(pst_id)` returns the corrective angle (variable/number) or `nothing` if none applies.
function _angle_of(gm, st::State, correctives, corr)
    a0 = _pst_alpha0(gm)
    return function (pst_id)
        if st.kind === :corrective && pst_id in correctives
            c = corr(pst_id)
            c === nothing || return c
        end
        return a0[pst_id]
    end
end

# ---------------------------------------------------------------------------
# Corrective-response problem (LLP): min over per-contingency correctives of the worst overload,
# for a fixed uncertainty v*. Correctives act only in the post-corrective states.
# ---------------------------------------------------------------------------
function _corrective_response(gm, states, monitored, correctives, contingencies, vstar, opt, silent)
    model = Model(opt); silent && set_silent(model)
    ranges = Dict(b.id => (b.alpha_min, b.alpha_max) for b in gm.branches if b.is_pst)
    α = Dict{Tuple{String,String},VariableRef}()
    for c in contingencies, pid in correctives
        a = @variable(model, base_name = "α_$(pid)_$(c)")
        set_lower_bound(a, ranges[pid][1]); set_upper_bound(a, ranges[pid][2])
        α[(pid, c)] = a
    end
    @variable(model, η)
    for st in states
        corr = pid -> (st.corrective_for === nothing ? nothing : get(α, (pid, st.corrective_for), nothing))
        angle_of = _angle_of(gm, st, correctives, corr)
        inj = Dict(n => gm.injection[n] + (st.uncertainty ? get(vstar, n, 0.0) : 0.0) for n in gm.buses)
        P = _add_state!(model, gm, st.outage, angle_of, inj, st.name)
        for o in _overloads(P, monitored, st.kind)
            @constraint(model, η >= o)
        end
    end
    @objective(model, Min, η)
    optimize!(model)
    ac = Dict((pid, c) => value(α[(pid, c)]) for c in contingencies, pid in correctives)
    return objective_value(model), ac
end

# ---------------------------------------------------------------------------
# Relaxed medial problem (MLP): the uncertainty maximises the worst overload against a menu of
# corrective candidates. A binary per candidate selects the binding (state, branch) overload.
# ---------------------------------------------------------------------------
function _relaxed_medial(gm, states, monitored, uncertain, correctives, contingencies,
                         candidates, bigM, opt, silent)
    model = Model(opt); silent && set_silent(model)
    v = Dict{String,Any}()
    for (n, (lo, hi)) in uncertain
        vn = @variable(model, base_name = "v_$(n)"); set_lower_bound(vn, lo); set_upper_bound(vn, hi)
        v[n] = vn
    end
    @variable(model, η)
    for (j, cand) in enumerate(candidates)
        sel = VariableRef[]
        for st in states
            corr = pid -> (st.corrective_for === nothing ? nothing :
                           get(cand, (pid, st.corrective_for), nothing))
            angle_of = _angle_of(gm, st, correctives, corr)
            inj = Dict(n => gm.injection[n] + (st.uncertainty && haskey(v, n) ? v[n] : 0.0)
                       for n in gm.buses)
            P = _add_state!(model, gm, st.outage, angle_of, inj, "c$(j)_$(st.name)")
            for o in _overloads(P, monitored, st.kind)
                b = @variable(model, binary = true); push!(sel, b)
                @constraint(model, η <= o + bigM * (1 - b))
            end
        end
        @constraint(model, sum(sel) == 1)
    end
    @objective(model, Max, η)
    optimize!(model)
    return objective_value(model), Dict(n => value(v[n]) for n in keys(uncertain))
end

# ---------------------------------------------------------------------------
# The oracle
# ---------------------------------------------------------------------------
"""
    worst_case_oracle(network; uncertain, monitored, correctives = String[],
                      contingencies = String[], slack = nothing,
                      optimizer = HiGHS.Optimizer, tol = 1e-5, max_iter = 30,
                      bigM = 100.0, silent = true) -> WorstCaseSolution

Evaluate the worst-case security oracle on `network` over the four-state model.

* `uncertain`  — `Dict(bus_id => (lo, hi))`: the injection-deviation range at each uncertain bus.
* `monitored`  — `Dict(branch_id => limit)`, where `limit` is a number (all states) or a
  `NamedTuple` `(; base, contingency, corrective)` of per-state limits.
* `correctives`— PST ids usable as **post-contingency corrective** control (per-contingency recourse).
* `contingencies` — branch ids to consider as N-1 outages. Correctives act only in the resulting
  post-corrective states; the base state uses the preventive angle `α⁰`.

Returns a [`WorstCaseSolution`](@ref); `secure` is `true` when the worst uncertainty can be kept
within every state's limits.
"""
function worst_case_oracle(network;
                           uncertain::AbstractDict, monitored::AbstractDict,
                           correctives = String[], contingencies = String[],
                           slack::Union{Nothing,String} = nothing,
                           optimizer = HiGHS.Optimizer, tol = 1e-5, max_iter = 30,
                           bigM = 100.0, silent = true)
    gm = GridModel(network; slack = slack)
    conts = collect(String, contingencies)
    correctives = collect(String, correctives)
    states = _states(conts)

    candidates = [Dict{Tuple{String,String},Float64}()]   # empty ⇒ all PSTs at α⁰
    best_lb = -Inf
    vstar = Dict(n => 0.0 for n in keys(uncertain))
    corrective = Dict{Tuple{String,String},Float64}()
    ub = Inf
    iterations = 0

    for k in 1:max_iter
        iterations = k
        ub, vstar = _relaxed_medial(gm, states, monitored, uncertain, correctives, conts,
                                    candidates, bigM, optimizer, silent)
        lb, ac = _corrective_response(gm, states, monitored, correctives, conts, vstar, optimizer, silent)
        if lb > best_lb
            best_lb = lb
            corrective = ac
        end
        ub - lb <= tol && break
        push!(candidates, ac)
    end

    # Group corrective angles per contingency for reporting.
    corr_by_c = Dict{String,Dict{String,Float64}}()
    for c in conts
        corr_by_c[c] = Dict(pid => corrective[(pid, c)] for pid in correctives if haskey(corrective, (pid, c)))
    end

    phi = best_lb
    return WorstCaseSolution(phi, phi <= tol, vstar, corr_by_c, iterations, best_lb, ub)
end

end # module

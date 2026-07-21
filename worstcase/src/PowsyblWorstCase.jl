# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

"""
    PowsyblWorstCase

Worst-case (robust) security analysis of a power grid, on a DC network model, built on the
Powsybl.jl APIs with JuMP + HiGHS.

This implements the **feasibility oracle** of the three-level worst-case formulation: for a
*fixed* preventive dispatch and a set of monitored states (base **N** plus **N-1**
contingencies), decide whether the grid stays within its branch limits under the *worst*
realisation of injection uncertainty, allowing *corrective* control (phase-shifting
transformer set points) to respond after the uncertainty is known. Formally it evaluates the
medial-level program

    φ = max_{v ∈ V}  min_{u_c ∈ U_c}  max_{(e, s)}  ( |P_{e,s}(v, u_c)| / P̂_{e,s} − 1 )

where `v` is the uncertain injection deviation, `u_c` the corrective PST angles, and the inner
`max` is the worst per-unit overload over every monitored branch `e` and state `s`. The grid is
**secure** iff `φ ≤ 0`: for every uncertainty there exists a corrective response keeping all
flows within limits.

`φ` is a min-max (a saddle) and is solved by Falk–Hoffman-style discretization
([`worst_case_oracle`](@ref)): a mixed-integer *relaxed medial* problem (the uncertainty
maximises the worst overload against a growing menu of corrective candidates) alternating with
a linear *corrective response* problem (the correctives minimise the worst overload for the
current worst uncertainty), until the bounds meet.

Scope of this first slice: uncertainty = injection deviations at chosen buses; correctives =
continuous PST phase angles; states = base + single-branch N-1 outages. The richer
integer-mode PST/HVDC models, topology switching and redispatch are deliberately left out.
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
    alpha0::Float64     # initial phase angle (rad); 0 for plain lines
    alpha_min::Float64
    alpha_max::Float64
end

"""
    GridModel(network; slack = nothing)

Extract a DC model from a Powsybl `network`: buses, a slack bus (its nodal balance is dropped
and its angle fixed to 0), the forecast net injection per bus (`Σ gen.target_p − Σ load.p0`),
and the branches (lines and phase-shifting transformers) with their DC susceptance `h = V₂²/x`.
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
    vls   = NET.get_voltage_levels(network, true)

    nominal_v = Dict(vls[i, :id] => vls[i, :nominal_v] for i in _rows(vls))
    bus_ids = collect(buses.id)

    injection = Dict(b => 0.0 for b in bus_ids)
    for i in _rows(gens)
        injection[gens[i, :bus_id]] += gens[i, :target_p]
    end
    for i in _rows(loads)
        injection[loads[i, :bus_id]] -= loads[i, :p0]
    end

    pst_ids = Set(collect(psts.id))
    # phase-angle bounds per PST come from its step table (min/max alpha, in degrees → rad)
    steps = NET.get_phase_tap_changer_steps(network, true)
    amin = Dict{String,Float64}(); amax = Dict{String,Float64}()
    for i in _rows(steps)
        id = steps[i, :id]; a = deg2rad(steps[i, :alpha])
        amin[id] = haskey(amin, id) ? min(amin[id], a) : a
        amax[id] = haskey(amax, id) ? max(amax[id], a) : a
    end

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
        push!(branches, Branch(id, tfos[i, :bus1_id], tfos[i, :bus2_id],
                               v2^2 / tfos[i, :x_at_current_tap], is_pst, 0.0,
                               get(amin, id, 0.0), get(amax, id, 0.0)))
    end

    sl = slack === nothing ? (isempty(gens.id) ? bus_ids[1] : gens[1, :bus_id]) : slack
    return GridModel(bus_ids, sl, injection, branches)
end

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
"""
    WorstCaseSolution

* `phi`            — the worst achievable overload `max_v min_{u_c} max_{e,s}` (`> 0` ⇒ insecure).
* `secure`         — whether `phi ≤ tol` (every uncertainty can be corrected within limits).
* `worst_injection`— the worst-case injection deviation `v*` per uncertain bus (MW).
* `corrective`     — the best corrective PST angles for `v*` (rad).
* `iterations`     — Falk–Hoffman iterations.
* `lower_bound`/`upper_bound` — the final bracket on `phi`.
"""
struct WorstCaseSolution
    phi::Float64
    secure::Bool
    worst_injection::Dict{String,Float64}
    corrective::Dict{String,Float64}
    iterations::Int
    lower_bound::Float64
    upper_bound::Float64
end

is_secure(sol::WorstCaseSolution) = sol.secure

# ---------------------------------------------------------------------------
# States and monitored overloads
# ---------------------------------------------------------------------------
# A state is (name, outaged branch id or nothing). Its active branch set drops the outage.
_states(contingencies) = vcat([(:N, nothing)], [(Symbol("N-1_", c), c) for c in contingencies])
_active(gm::GridModel, out) = out === nothing ? gm.branches : filter(b -> b.id != out, gm.branches)

# ---------------------------------------------------------------------------
# DC grid layer: add θ / flow variables and constraints to a model for one state.
# `alpha` maps a PST id to its angle (a JuMP variable or a number); `inj` maps a bus to its
# injection expression (number or AffExpr). Returns branch-id → flow variable.
# ---------------------------------------------------------------------------
function _add_state!(model, gm::GridModel, out, alpha, inj, tag)
    active = _active(gm, out)
    θ = Dict(b => @variable(model, base_name = "θ_$(tag)_$(b)") for b in gm.buses)
    fix(θ[gm.slack], 0.0; force = true)
    P = Dict{String,Any}()
    for br in active
        p = @variable(model, base_name = "P_$(tag)_$(br.id)")
        shift = br.is_pst ? alpha[br.id] : 0.0
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

# Signed per-unit overloads (both directions) for the monitored branches present in a state.
# Returns a vector of (label, expr) with expr = ±P/limit − 1.
function _overloads(P, monitored, state_name)
    out = Tuple{String,Any}[]
    for (id, lim) in monitored
        haskey(P, id) || continue
        push!(out, ("$(id)@$(state_name)+", P[id] / lim - 1))
        push!(out, ("$(id)@$(state_name)-", -P[id] / lim - 1))
    end
    return out
end

# ---------------------------------------------------------------------------
# Corrective-response problem (LLP): min over correctives of the worst overload, for fixed v.
# ---------------------------------------------------------------------------
function _corrective_response(gm, states, monitored, correctives, vstar, opt, silent)
    model = Model(opt); silent && set_silent(model)
    alpha = Dict{String,Any}()
    for br in gm.branches
        br.is_pst || continue
        if br.id in correctives
            a = @variable(model, base_name = "α_$(br.id)")
            set_lower_bound(a, br.alpha_min); set_upper_bound(a, br.alpha_max)
            alpha[br.id] = a
        else
            alpha[br.id] = br.alpha0
        end
    end
    @variable(model, η)
    for (name, out) in states
        inj = Dict(n => gm.injection[n] + get(vstar, n, 0.0) for n in gm.buses)
        P = _add_state!(model, gm, out, alpha, inj, name)
        for (_, o) in _overloads(P, monitored, name)
            @constraint(model, η >= o)
        end
    end
    @objective(model, Min, η)
    optimize!(model)
    ac = Dict(id => value(alpha[id]) for id in correctives)
    return objective_value(model), ac
end

# ---------------------------------------------------------------------------
# Relaxed medial problem (MLP): the uncertainty maximises the worst overload against the current
# menu of corrective candidates. A binary per candidate selects the binding overload (linearising
# the max over branches/states); η is the min over candidates of that selected worst overload.
# ---------------------------------------------------------------------------
function _relaxed_medial(gm, states, monitored, uncertain, candidates, bigM, opt, silent)
    model = Model(opt); silent && set_silent(model)
    v = Dict{String,Any}()
    for (n, (lo, hi)) in uncertain
        vn = @variable(model, base_name = "v_$(n)")
        set_lower_bound(vn, lo); set_upper_bound(vn, hi)
        v[n] = vn
    end
    @variable(model, η)
    for (j, cand) in enumerate(candidates)
        alpha = Dict(br.id => (br.is_pst ? get(cand, br.id, br.alpha0) : 0.0) for br in gm.branches)
        sel = VariableRef[]
        for (name, out) in states
            inj = Dict(n => gm.injection[n] + (haskey(v, n) ? v[n] : 0.0) for n in gm.buses)
            P = _add_state!(model, gm, out, alpha, inj, "c$(j)_$(name)")
            for (_, o) in _overloads(P, monitored, name)
                b = @variable(model, binary = true)
                push!(sel, b)
                @constraint(model, η <= o + bigM * (1 - b))   # η ≤ selected overload of candidate j
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

Evaluate the worst-case security oracle on `network`.

* `uncertain`  — `Dict(bus_id => (lo, hi))`: the injection-deviation range at each uncertain bus.
* `monitored`  — `Dict(branch_id => limit)`: branches whose per-unit overload is policed.
* `correctives`— PST ids usable as corrective control (their angle range comes from the network).
* `contingencies` — branch ids to also consider as N-1 outages (base state is always included).

Returns a [`WorstCaseSolution`](@ref); `secure` is `true` when the worst uncertainty can be kept
within all limits by the correctives.
"""
function worst_case_oracle(network;
                           uncertain::AbstractDict, monitored::AbstractDict,
                           correctives = String[], contingencies = String[],
                           slack::Union{Nothing,String} = nothing,
                           optimizer = HiGHS.Optimizer, tol = 1e-5, max_iter = 30,
                           bigM = 100.0, silent = true)
    gm = GridModel(network; slack = slack)
    states = _states(collect(contingencies))
    correctives = collect(String, correctives)

    # Initial corrective candidate: every PST at its initial angle.
    candidates = [Dict(id => 0.0 for id in correctives)]
    best_lb = -Inf
    vstar = Dict(n => 0.0 for n in keys(uncertain))
    corrective = Dict(id => 0.0 for id in correctives)
    ub = Inf
    iterations = 0

    for k in 1:max_iter
        iterations = k
        ub, vstar = _relaxed_medial(gm, states, monitored, uncertain, candidates, bigM, optimizer, silent)
        lb, ac = _corrective_response(gm, states, monitored, correctives, vstar, optimizer, silent)
        if lb > best_lb
            best_lb = lb
            corrective = ac
        end
        if ub - lb <= tol
            break
        end
        push!(candidates, ac)
    end

    phi = best_lb
    return WorstCaseSolution(phi, phi <= tol, vstar, corrective, iterations, best_lb, ub)
end

end # module

# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

"""
    PowsyblWorstCase

Worst-case (robust) security analysis of a power grid, on a DC network model, built on the
Powsybl.jl APIs with JuMP + HiGHS.

This implements the **feasibility oracle** of the three-level worst-case formulation, over the
four operating states (**0** nominal, **N** base, **N-1** post-contingency, **N-1/c**
post-corrective). For a fixed preventive dispatch it evaluates

    φ = max_{v ∈ V}  min_{u_c ∈ U_c}  max_{(e, s)}  ( |P_{e,s}(v, u_c)| / P̂_{e,s}^{s} − 1 )

and the grid is **secure** iff `φ ≤ 0`: for every uncertainty there exists a corrective response
keeping every monitored branch within its (per-state) limit.

Modelled: uncertainty = injection deviations; **secondary frequency response** (participation
factors, saturating at generator limits); corrective **PST** angles (per-contingency recourse);
**integer-mode devices** — an **HVDC** in AC-emulation whose flow `P⁰ + K·Δθ` is clamped to a
hard limit `±P^lim` (a 3-mode disjunction), and **PST over-current disconnection** (a corrective
PST either regulates within its rating `|P| ≤ P^lim` or trips to `P = 0`); and the **full PST
automaton** — activation (`|P^{N-1}| ≥ P^act`), target regulation toward `±P^tar`, and
over-current protection with forward trip propagation, whose multiple equilibria are resolved to
the physical (maximally-connected) one by a lexicographic local-consistency tie-break.

`φ` is solved by Falk–Hoffman-style discretization ([`worst_case_oracle`](@ref)).
"""
module PowsyblWorstCase

using Powsybl
using JuMP
import HiGHS
import DataFrames

const NET = Powsybl.Network

export GridModel, WorstCaseSolution, worst_case_oracle, is_secure

# ---------------------------------------------------------------------------
# Branches (lines, PSTs, HVDC) and generators
# ---------------------------------------------------------------------------
struct Branch
    id::String
    bus1::String
    bus2::String
    kind::Symbol           # :line | :pst | :hvdc
    h::Float64             # DC susceptance V²/x (line, pst)
    alpha0::Float64        # pst preventive angle (rad)
    alpha_min::Float64
    alpha_max::Float64
    p_zero::Float64        # hvdc set point (MW)
    k::Float64             # hvdc AC-emulation coefficient (MW/rad)
    p_lim::Float64         # hvdc clamp limit (Inf ⇒ none)
end

_line(id, b1, b2, h) = Branch(id, b1, b2, :line, h, 0.0, 0.0, 0.0, 0.0, 0.0, Inf)
_pst(id, b1, b2, h, a0, amin, amax) = Branch(id, b1, b2, :pst, h, a0, amin, amax, 0.0, 0.0, Inf)
_hvdc(id, b1, b2, k, pz, plim) = Branch(id, b1, b2, :hvdc, 0.0, 0.0, 0.0, 0.0, pz, k, plim)

struct Gen
    id::String
    bus::String
    p0::Float64
    pmin::Float64
    pmax::Float64
end

"""
    GridModel(network; slack = nothing)

Extract a DC model from a Powsybl `network`: buses, angle-reference (slack) bus, generators
(nominal set point + P limits), load per bus, and the branches (lines and phase-shifting
transformers) with DC susceptance `h = V₂²/x`, preventive angle `α⁰` and corrective angle range.
HVDC branches are added separately by the oracle.
"""
struct GridModel
    buses::Vector{String}
    slack::String
    generators::Vector{Gen}
    load_by_bus::Dict{String,Float64}
    branches::Vector{Branch}
end

_rows(df) = 1:DataFrames.nrow(df)

function GridModel(network; slack::Union{Nothing,String} = nothing)
    gens_df = NET.get_generators(network, true)
    loads   = NET.get_loads(network, true)
    buses   = NET.get_buses(network, true)
    lines   = NET.get_lines(network, true)
    tfos    = NET.get_2_windings_transformers(network, true)
    psts    = NET.get_phase_tap_changers(network, true)
    steps   = NET.get_phase_tap_changer_steps(network, true)
    vls     = NET.get_voltage_levels(network, true)

    nominal_v = Dict(vls[i, :id] => vls[i, :nominal_v] for i in _rows(vls))
    bus_ids = collect(buses.id)

    generators = [Gen(gens_df[i, :id], gens_df[i, :bus_id], gens_df[i, :target_p],
                      gens_df[i, :min_p], gens_df[i, :max_p]) for i in _rows(gens_df)]
    load_by_bus = Dict{String,Float64}()
    for i in _rows(loads)
        load_by_bus[loads[i, :bus_id]] = get(load_by_bus, loads[i, :bus_id], 0.0) + loads[i, :p0]
    end

    pst_ids = Set(collect(psts.id))
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
        push!(branches, _line(lines[i, :id], lines[i, :bus1_id], lines[i, :bus2_id], v2^2 / lines[i, :x]))
    end
    for i in _rows(tfos)
        id = tfos[i, :id]; v2 = nominal_v[tfos[i, :voltage_level2_id]]
        h = v2^2 / tfos[i, :x_at_current_tap]
        if id in pst_ids
            a = get(alphas, id, Float64[0.0])
            push!(branches, _pst(id, tfos[i, :bus1_id], tfos[i, :bus2_id], h, get(alpha0, id, 0.0),
                                 minimum(a), maximum(a)))
        else
            push!(branches, _line(id, tfos[i, :bus1_id], tfos[i, :bus2_id], h))
        end
    end

    sl = slack === nothing ? (isempty(generators) ? bus_ids[1] : generators[1].bus) : slack
    return GridModel(bus_ids, sl, generators, load_by_bus, branches)
end

_pst_alpha0(gm::GridModel) = Dict(b.id => b.alpha0 for b in gm.branches if b.kind === :pst)
_nominal_injection(gm::GridModel) =
    Dict(n => sum((g.p0 for g in gm.generators if g.bus == n); init = 0.0) -
              get(gm.load_by_bus, n, 0.0) for n in gm.buses)

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
"""
    WorstCaseSolution

* `phi`            — the worst achievable overload `max_v min_{u_c} max_{e,s}` (`> 0` ⇒ insecure).
* `secure`         — whether `phi ≤ tol`.
* `worst_injection`— the worst-case injection deviation `v*` per uncertain bus (MW).
* `corrective`     — best corrective PST angles (rad), per contingency: `Dict(cont => Dict(pst => α))`.
* `iterations`, `lower_bound`, `upper_bound`.
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
# States
# ---------------------------------------------------------------------------
struct State
    name::String
    kind::Symbol
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

_active(branches, out) = out === nothing ? branches : filter(b -> b.id != out, branches)

_limit(v::Number, kind) = v
function _limit(v::NamedTuple, kind)
    kind === :contingency && haskey(v, :contingency) && return v.contingency
    kind === :corrective && haskey(v, :corrective) && return v.corrective
    return v.base
end

# ---------------------------------------------------------------------------
# Injection model (secondary frequency response / single slack)
# ---------------------------------------------------------------------------
# y = mid(lo, x, hi) = clamp(x, lo, hi), modelled exactly with two big-M selections.
function _clamp!(model, x, lo, hi, M)
    m = @variable(model); δ = @variable(model, binary = true)
    @constraint(model, m <= hi); @constraint(model, m <= x)
    @constraint(model, m >= hi - M * (1 - δ)); @constraint(model, m >= x - M * δ)
    y = @variable(model); γ = @variable(model, binary = true)
    @constraint(model, y >= lo); @constraint(model, y >= m)
    @constraint(model, y <= lo + M * (1 - γ)); @constraint(model, y <= m + M * γ)
    return y
end

function _injection_model!(model, gm, participation, v, balance_M)
    nom = _nominal_injection(gm)
    if participation === nothing
        inj = Dict{String,Any}(n => nom[n] + (haskey(v, n) ? v[n] : 0.0) for n in gm.buses)
        return inj, nom, true
    end
    λ = @variable(model, base_name = "λ")
    Pg = Dict{String,Any}()
    for g in gm.generators
        haskey(participation, g.id) || continue
        Pg[g.id] = _clamp!(model, g.p0 + λ * participation[g.id], g.pmin, g.pmax, balance_M)
    end
    inj = Dict{String,Any}()
    for n in gm.buses
        e = AffExpr(0.0)
        for g in gm.generators
            g.bus == n || continue
            add_to_expression!(e, haskey(Pg, g.id) ? Pg[g.id] : g.p0)
        end
        add_to_expression!(e, -get(gm.load_by_bus, n, 0.0))
        haskey(v, n) && add_to_expression!(e, v[n])
        inj[n] = e
    end
    return inj, nom, false
end

# ---------------------------------------------------------------------------
# Per-branch DC flow, including the integer-mode devices.
#   line:  P = h·Δθ
#   hvdc:  P = clamp(P⁰ + K·Δθ, ±P^lim)                                   (3-mode disjunction)
#   pst :  regulate  P = h·(Δθ + α),  |P| ≤ P^lim   OR   trip  P = 0      (disconnection disjunction)
# `open` is `nothing` (no switching), a `Bool` (fixed candidate) or a binary `VariableRef`.
# ---------------------------------------------------------------------------
function _branch_flow!(model, br, θ, angle, open, plim, M)
    Δθ = θ[br.bus1] - θ[br.bus2]
    if br.kind === :line
        p = @variable(model); @constraint(model, p == br.h * Δθ); return p
    elseif br.kind === :hvdc
        return _clamp!(model, br.p_zero + br.k * Δθ, -br.p_lim, br.p_lim, M)
    end
    # PST
    nat = br.h * (Δθ + angle)
    if open === nothing
        p = @variable(model); @constraint(model, p == nat); return p
    elseif open isa Bool
        open && return AffExpr(0.0)                    # tripped: no flow, buses decoupled
        p = @variable(model); @constraint(model, p == nat)
        isfinite(plim) && @constraint(model, -plim <= p <= plim)
        return p
    else                                               # `open` is a binary variable
        p = @variable(model)
        @constraint(model, p <= nat + M * open); @constraint(model, p >= nat - M * open)   # closed ⇒ p = nat
        @constraint(model, p <= M * (1 - open)); @constraint(model, p >= -M * (1 - open))  # open ⇒ p = 0
        if isfinite(plim)
            @constraint(model, p <= plim + M * open); @constraint(model, p >= -plim - M * open)
        end
        return p
    end
end

function _add_state!(model, gm::GridModel, out, angle_of, open_of, plim_of, inj, drop_slack, M, tag;
                    pst_model = Dict{String,Any}(), st = nothing, ctx = nothing)
    active = _active(gm.branches, out)
    θ = Dict(b => @variable(model, base_name = "θ_$(tag)_$(b)") for b in gm.buses)
    fix(θ[gm.slack], 0.0; force = true)
    P = Dict{String,Any}()
    for br in active
        if br.kind === :pst && haskey(pst_model, br.id)
            P[br.id] = _full_pst_flow!(model, br, θ, st, ctx, pst_model[br.id], M)
        elseif br.kind === :pst
            op  = open_of(br.id)
            P[br.id] = _branch_flow!(model, br, θ, angle_of(br.id), op, plim_of(br.id, op), M)
        else
            P[br.id] = _branch_flow!(model, br, θ, 0.0, nothing, Inf, M)
        end
    end
    for n in gm.buses
        (drop_slack && n == gm.slack) && continue
        out_flow = sum(P[br.id] for br in active if br.bus1 == n; init = AffExpr(0.0))
        in_flow  = sum(P[br.id] for br in active if br.bus2 == n; init = AffExpr(0.0))
        @constraint(model, out_flow - in_flow == inj[n])
    end
    return P
end

# ---------------------------------------------------------------------------
# Full PST automaton (Aachen §2.1.6): over-current protection with N→N-1→N-1/c trip
# propagation, an activation threshold, and target regulation.
# ---------------------------------------------------------------------------
# Inactive branch: P = h·(Δθ + α⁰) within the rating, else trip (over-current, local consistency).
# `conn_max` (a binary or nothing) forbids reconnection if a prior state tripped.
function _inactive_flow!(model, br, Δθ, plim, M; conn_max = nothing)
    nat0 = br.h * (Δθ + br.alpha0)
    conn = @variable(model, binary = true); dhi = @variable(model, binary = true)
    dlo = @variable(model, binary = true);  dinh = @variable(model, binary = true)  # inherited trip
    @constraint(model, conn + dhi + dlo + dinh == 1)
    if conn_max === nothing
        @constraint(model, dinh == 0)
    else
        @constraint(model, conn <= conn_max); @constraint(model, dinh <= 1 - conn_max)
    end
    P = @variable(model)
    @constraint(model, P <= nat0 + M * (1 - conn)); @constraint(model, P >= nat0 - M * (1 - conn))  # conn ⇒ P = nat0
    @constraint(model, nat0 <= plim + M * (1 - conn)); @constraint(model, nat0 >= -plim - M * (1 - conn))  # conn ⇒ |nat0| ≤ P^lim
    @constraint(model, P <= M * conn); @constraint(model, P >= -M * conn)                            # ¬conn ⇒ P = 0
    @constraint(model, nat0 >= plim - M * (1 - dhi))                                                 # trip-high justified by over-current
    @constraint(model, nat0 <= -plim + M * (1 - dlo))
    return P, conn
end

# Active branch: regulate toward ±P^tar within the angle range (median of clamps), trip on
# over-current. `reg` reproduces Aachen Eq. 5 modes 4–10 exactly.
function _active_flow!(model, br, Δθ, plim, ptar, M; conn_max = nothing)
    lo = br.h * (Δθ + br.alpha_min); hi = br.h * (Δθ + br.alpha_max); nat0 = br.h * (Δθ + br.alpha0)
    reg = _clamp!(model, _clamp!(model, nat0, -ptar, ptar, M), lo, hi, M)
    conn = @variable(model, binary = true); dhi = @variable(model, binary = true)
    dlo = @variable(model, binary = true);  dinh = @variable(model, binary = true)
    @constraint(model, conn + dhi + dlo + dinh == 1)
    if conn_max === nothing
        @constraint(model, dinh == 0)
    else
        @constraint(model, conn <= conn_max); @constraint(model, dinh <= 1 - conn_max)
    end
    P = @variable(model)
    @constraint(model, P <= reg + M * (1 - conn)); @constraint(model, P >= reg - M * (1 - conn))
    @constraint(model, reg <= plim + M * (1 - conn)); @constraint(model, reg >= -plim - M * (1 - conn))
    @constraint(model, P <= M * conn); @constraint(model, P >= -M * conn)
    @constraint(model, reg >= plim - M * (1 - dhi)); @constraint(model, reg <= -plim + M * (1 - dlo))
    return P, conn
end

function _full_pst_flow!(model, br, θ, st::State, ctx, fp, M)
    conns = get!(ctx, :conns, VariableRef[])
    Δθ = θ[br.bus1] - θ[br.bus2]
    if st.kind === :nominal
        P, c = _inactive_flow!(model, br, Δθ, fp.p_lim, M); push!(conns, c); return P
    elseif st.kind === :base
        P, conn = _inactive_flow!(model, br, Δθ, fp.p_lim, M); push!(conns, conn)
        ctx[(br.id, :conn_N)] = conn; return P
    elseif st.kind === :contingency
        P, conn = _inactive_flow!(model, br, Δθ, fp.p_lim, M; conn_max = ctx[(br.id, :conn_N)])
        push!(conns, conn); ctx[(br.id, st.outage, :conn_N1)] = conn; ctx[(br.id, st.outage, :P_N1)] = P; return P
    end
    # post-corrective (N-1/c): activation from |P^{N-1}| ≥ P^act, then active or inactive.
    conn_N1 = ctx[(br.id, st.corrective_for, :conn_N1)]; P_N1 = ctx[(br.id, st.corrective_for, :P_N1)]
    P_ia, c_ia = _inactive_flow!(model, br, Δθ, fp.p_lim, M; conn_max = conn_N1)
    P_a, c_a   = _active_flow!(model, br, Δθ, fp.p_lim, fp.p_tar, M; conn_max = conn_N1)
    push!(conns, c_ia); push!(conns, c_a)
    act = @variable(model, binary = true); sgn = @variable(model, binary = true)
    @constraint(model, P_N1 <= fp.p_act + M * act); @constraint(model, P_N1 >= -fp.p_act - M * act)   # ¬act ⇒ |P_N1| ≤ P^act
    @constraint(model, P_N1 >= fp.p_act - M * (1 - act) - M * (1 - sgn))                              # act ⇒ |P_N1| ≥ P^act
    @constraint(model, P_N1 <= -fp.p_act + M * (1 - act) + M * sgn)
    P = @variable(model)
    @constraint(model, P <= P_a + M * (1 - act));  @constraint(model, P >= P_a - M * (1 - act))       # act ⇒ P = active flow
    @constraint(model, P <= P_ia + M * act);       @constraint(model, P >= P_ia - M * act)            # ¬act ⇒ P = inactive flow
    return P
end

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

function _angle_of(gm, st::State, correctives, corr)
    a0 = _pst_alpha0(gm)
    return function (pst_id)
        if st.kind === :corrective && pst_id in correctives
            c = corr(pst_id)
            c === nothing || return c
        end
        return get(a0, pst_id, 0.0)
    end
end

# PST over-current limit applies only where a disconnection mode is available (corrective states
# of switchable PSTs) — elsewhere the PST is at α⁰ and unrestricted (temporary rating assumed).
_plim_of(pst_limits) = (pst_id, open) -> (open === nothing ? Inf : get(pst_limits, pst_id, Inf))

# ---------------------------------------------------------------------------
# Corrective-response problem (LLP)
# ---------------------------------------------------------------------------
function _corrective_response(gm, states, monitored, correctives, switchable, contingencies,
                              participation, pst_limits, pst_model, vstar, opt, silent, bigM, balance_M)
    model = Model(opt); silent && set_silent(model)
    inj_unc, inj_nom, drop_slack = _injection_model!(model, gm, participation, vstar, balance_M)
    ranges = Dict(b.id => (b.alpha_min, b.alpha_max) for b in gm.branches if b.kind === :pst)
    α = Dict{Tuple{String,String},VariableRef}()
    op = Dict{Tuple{String,String},VariableRef}()
    for c in contingencies, pid in correctives
        a = @variable(model, base_name = "α_$(pid)_$(c)")
        set_lower_bound(a, ranges[pid][1]); set_upper_bound(a, ranges[pid][2])
        α[(pid, c)] = a
        pid in switchable && (op[(pid, c)] = @variable(model, binary = true, base_name = "open_$(pid)_$(c)"))
    end
    plim_of = _plim_of(pst_limits)
    ctx = Dict{Any,Any}()
    @variable(model, η)
    for st in states
        corr_a = pid -> (st.corrective_for === nothing ? nothing : get(α, (pid, st.corrective_for), nothing))
        open_of = pid -> (st.kind === :corrective && pid in switchable ?
                          get(op, (pid, st.corrective_for), nothing) : nothing)
        P = _add_state!(model, gm, st.outage, _angle_of(gm, st, correctives, corr_a), open_of,
                        plim_of, st.uncertainty ? inj_unc : inj_nom, drop_slack, bigM, st.name;
                        pst_model = pst_model, st = st, ctx = ctx)
        for o in _overloads(P, monitored, st.kind)
            @constraint(model, η >= o)
        end
    end
    # Connection-preference (Aachen Remark 1): the over-current protection of an inactive PST
    # is self-referential — when the device is open its buses decouple, and the *would-be*
    # natural flow can be arranged to exceed the rating, "justifying" a spurious trip. Such a
    # disconnected state is only *locally* consistent; the physical equilibrium is the one that
    # trips a device only when it genuinely over-currents while connected. We select it
    # lexicographically: first minimise the number of disconnections (so a device stays
    # connected whenever a connected equilibrium exists), then minimise the overload η.
    conns = get(ctx, :conns, VariableRef[])
    if !isempty(conns)
        @objective(model, Min, sum(1 - c for c in conns))
        optimize!(model)
        dstar = objective_value(model)
        @constraint(model, sum(1 - c for c in conns) <= dstar + 1e-6)
    end
    @objective(model, Min, η)
    optimize!(model)
    ac = Dict((pid, c) => (alpha = value(α[(pid, c)]),
                           open = haskey(op, (pid, c)) ? value(op[(pid, c)]) > 0.5 : false)
              for c in contingencies, pid in correctives)
    return objective_value(model), ac
end

# ---------------------------------------------------------------------------
# Relaxed medial problem (MLP)
# ---------------------------------------------------------------------------
function _relaxed_medial(gm, states, monitored, uncertain, correctives, switchable, contingencies,
                         participation, pst_limits, pst_model, candidates, bigM, opt, silent, balance_M)
    model = Model(opt); silent && set_silent(model)
    v = Dict{String,Any}()
    for (n, (lo, hi)) in uncertain
        vn = @variable(model, base_name = "v_$(n)"); set_lower_bound(vn, lo); set_upper_bound(vn, hi)
        v[n] = vn
    end
    inj_unc, inj_nom, drop_slack = _injection_model!(model, gm, participation, v, balance_M)
    plim_of = _plim_of(pst_limits)
    @variable(model, η)
    for (j, cand) in enumerate(candidates)
        sel = VariableRef[]
        ctx = Dict{Any,Any}()
        for st in states
            corr_a = pid -> (st.corrective_for === nothing ? nothing :
                             (haskey(cand, (pid, st.corrective_for)) ? cand[(pid, st.corrective_for)].alpha : nothing))
            open_of = pid -> (st.kind === :corrective && pid in switchable &&
                              haskey(cand, (pid, st.corrective_for)) ? cand[(pid, st.corrective_for)].open : nothing)
            P = _add_state!(model, gm, st.outage, _angle_of(gm, st, correctives, corr_a), open_of,
                            plim_of, st.uncertainty ? inj_unc : inj_nom, drop_slack, bigM, "c$(j)_$(st.name)";
                            pst_model = pst_model, st = st, ctx = ctx)
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
                      contingencies = String[], participation = nothing,
                      hvdc = NamedTuple[], switchable = String[], pst_limits = Dict(),
                      slack = nothing, optimizer = HiGHS.Optimizer, tol = 1e-5,
                      max_iter = 30, bigM = 1e4, balance_bigM = 1e5, silent = true)
        -> WorstCaseSolution

Evaluate the worst-case security oracle on `network` over the four-state model.

Besides `uncertain`, `monitored`, `correctives`, `contingencies` and `participation`
(see the module docstring), integer-mode devices are configured by:

* `hvdc` — a vector of `(; id, bus1, bus2, k, p_zero, p_lim)`: HVDC branches in AC-emulation
  whose flow `p_zero + k·Δθ` is clamped to `±p_lim`.
* `switchable` — PST ids whose over-current disconnection is modelled: as a corrective mode
  such a PST either regulates within `pst_limits[id]` or trips to zero flow.
* `pst_limits` — `Dict(pst_id => P^lim)` thermal ratings for the switchable PSTs.
* `pst_model` — `Dict(pst_id => (; p_lim, p_act, p_tar))` to model a PST as the **full
  protection automaton** (a physical device, not a free corrective): it activates once
  `|P^{N-1}| ≥ p_act`, then regulates toward `±p_tar`, and trips on over-current `|P| ≥ p_lim`
  with the trip propagating forward through the states. Its multiple (locally-consistent)
  equilibria are resolved to the physical, maximally-connected one.
"""
function worst_case_oracle(network;
                           uncertain::AbstractDict, monitored::AbstractDict,
                           correctives = String[], contingencies = String[],
                           participation::Union{Nothing,AbstractDict} = nothing,
                           hvdc = NamedTuple[], switchable = String[], pst_limits::AbstractDict = Dict{String,Float64}(),
                           pst_model::AbstractDict = Dict{String,Any}(),
                           slack::Union{Nothing,String} = nothing,
                           optimizer = HiGHS.Optimizer, tol = 1e-5, max_iter = 30,
                           bigM = 1e4, balance_bigM = 1e5, silent = true)
    gm = GridModel(network; slack = slack)
    for h in hvdc
        push!(gm.branches, _hvdc(h.id, h.bus1, h.bus2, h.k, h.p_zero, h.p_lim))
    end
    conts = collect(String, contingencies)
    correctives = collect(String, correctives)
    switch = Set(collect(String, switchable))
    states = _states(conts)

    Cand = Dict{Tuple{String,String},NamedTuple{(:alpha, :open),Tuple{Float64,Bool}}}
    candidates = Cand[Cand()]
    best_lb = -Inf
    vstar = Dict(n => 0.0 for n in keys(uncertain))
    corrective = Cand()
    ub = Inf
    iterations = 0

    # When the full-PST automaton is the acting device and there is no *free* corrective to
    # discretize, the PST is part of the grid model. Its mode/connection binaries are resolved
    # *cooperatively* (the physical device stays connected when it can, and regulates to help) —
    # i.e. by the corrective-response (min) problem — while the worst uncertainty comes from the
    # relaxed-medial (max) problem. A spurious "disconnected" equilibrium that is only locally
    # consistent (Aachen Remark 1) is thereby rejected in favour of the connected one.
    if isempty(correctives) && isempty(switch)
        ub, vstar = _relaxed_medial(gm, states, monitored, uncertain, correctives, switch, conts,
                                    participation, pst_limits, pst_model, candidates, bigM, optimizer, silent, balance_bigM)
        lb, _ = _corrective_response(gm, states, monitored, correctives, switch, conts,
                                     participation, pst_limits, pst_model, vstar, optimizer, silent, bigM, balance_bigM)
        return WorstCaseSolution(lb, lb <= tol, vstar, Dict{String,Dict{String,Float64}}(), 1, lb, ub)
    end

    for k in 1:max_iter
        iterations = k
        ub, vstar = _relaxed_medial(gm, states, monitored, uncertain, correctives, switch, conts,
                                    participation, pst_limits, pst_model, candidates, bigM, optimizer, silent, balance_bigM)
        lb, ac = _corrective_response(gm, states, monitored, correctives, switch, conts,
                                      participation, pst_limits, pst_model, vstar, optimizer, silent, bigM, balance_bigM)
        if lb > best_lb
            best_lb = lb
            corrective = ac
        end
        ub - lb <= tol && break
        push!(candidates, ac)
    end

    corr_by_c = Dict{String,Dict{String,Float64}}()
    for c in conts
        corr_by_c[c] = Dict(pid => corrective[(pid, c)].alpha
                            for pid in correctives if haskey(corrective, (pid, c)))
    end

    phi = best_lb
    return WorstCaseSolution(phi, phi <= tol, vstar, corr_by_c, iterations, best_lb, ub)
end

end # module

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
the physical one by a **connected-reference** trip test (deterministic in both the max and min
problems, so the automaton composes with free correctives and the bounds meet).

`φ` is solved by Falk–Hoffman-style discretization ([`worst_case_oracle`](@ref)).
"""
module PowsyblWorstCase

using Powsybl
using JuMP
import HiGHS
import DataFrames

const NET = Powsybl.Network

export GridModel, WorstCaseSolution, worst_case_oracle, is_secure, zone_exchange, min_violating_exchange

# ---------------------------------------------------------------------------
# Branches (lines, PSTs, HVDC) and generators
#
# Each device is its own type carrying only its own data, and its DC flow equation is a method
# of `_flow!` selected by dispatch — the equation is written once and instantiated per state.
# All branches share `id`, `bus1`, `bus2`.
# ---------------------------------------------------------------------------
abstract type Branch end

"A plain line (or non-regulating transformer): `P = h·Δθ`."
struct Line <: Branch
    id::String
    bus1::String
    bus2::String
    h::Float64             # DC susceptance V²/x
end

"A phase-shifting transformer: `P = h·(Δθ + α)`, `α` preventive or corrective."
struct Pst <: Branch
    id::String
    bus1::String
    bus2::String
    h::Float64
    alpha0::Float64        # preventive angle (rad)
    alpha_min::Float64
    alpha_max::Float64
end

"An HVDC link in AC emulation: `P = clamp(P⁰ + K·Δθ, ±P^lim)`."
struct Hvdc <: Branch
    id::String
    bus1::String
    bus2::String
    p_zero::Float64        # set point (MW)
    k::Float64             # AC-emulation coefficient (MW/rad)
    p_lim::Float64         # clamp limit (Inf ⇒ none)
end

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
        push!(branches, Line(lines[i, :id], lines[i, :bus1_id], lines[i, :bus2_id], v2^2 / lines[i, :x]))
    end
    for i in _rows(tfos)
        id = tfos[i, :id]; v2 = nominal_v[tfos[i, :voltage_level2_id]]
        h = v2^2 / tfos[i, :x_at_current_tap]
        if id in pst_ids
            a = get(alphas, id, Float64[0.0])
            push!(branches, Pst(id, tfos[i, :bus1_id], tfos[i, :bus2_id], h, get(alpha0, id, 0.0),
                                minimum(a), maximum(a)))
        else
            push!(branches, Line(id, tfos[i, :bus1_id], tfos[i, :bus2_id], h))
        end
    end

    sl = slack === nothing ? (isempty(generators) ? bus_ids[1] : generators[1].bus) : slack
    return GridModel(bus_ids, sl, generators, load_by_bus, branches)
end

_pst_alpha0(gm::GridModel) = Dict(b.id => b.alpha0 for b in gm.branches if b isa Pst)
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
# The four operating states
#
# Each state is a type, so anything that varies by state (per-state limits, the PST automaton's
# behaviour) is expressed as methods dispatching on it rather than as a branch on a tag. The DC
# equations themselves are written once and instantiated per state by `_build_program!`.
# ---------------------------------------------------------------------------
abstract type State end

"State 0 — nominal: forecast injections, intact grid, preventive control."
struct NominalState <: State end
"State N — base: uncertain injections, intact grid, preventive control."
struct BaseState <: State end
"State N-1 — post-contingency: uncertain injections, outage, no correction yet."
struct ContingencyState <: State
    outage::String
end
"State N-1/c — post-corrective: uncertain injections, outage, corrective control."
struct CorrectiveState <: State
    outage::String
end

statename(::NominalState) = "nominal"
statename(::BaseState) = "N"
statename(s::ContingencyState) = "N-1[$(s.outage)]"
statename(s::CorrectiveState) = "N-1/c[$(s.outage)]"

outage(::Union{NominalState,BaseState}) = nothing
outage(s::Union{ContingencyState,CorrectiveState}) = s.outage

# Only the nominal state uses the forecast (certain) injection.
has_uncertainty(::NominalState) = false
has_uncertainty(::State) = true

# Corrective control acts only post-corrective, as per-contingency recourse.
corrective_for(s::CorrectiveState) = s.outage
corrective_for(::State) = nothing

function _states(contingencies)
    out = State[NominalState(), BaseState()]
    for c in contingencies
        push!(out, ContingencyState(c))
        push!(out, CorrectiveState(c))
    end
    return out
end

_active(branches, out) = out === nothing ? branches : filter(b -> b.id != out, branches)

# A monitored limit is either one number for every state, or a per-state NamedTuple.
_limit(v::Number, ::State) = v
_limit(v::NamedTuple, s::ContingencyState) = get(v, :contingency, v.base)
_limit(v::NamedTuple, s::CorrectiveState) = get(v, :corrective, v.base)
_limit(v::NamedTuple, ::State) = v.base

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
# Per-branch DC flow — one method per device type, selected by dispatch.
#   Line:  P = h·Δθ
#   Hvdc:  P = clamp(P⁰ + K·Δθ, ±P^lim)                                  (3-mode disjunction)
#   Pst :  regulate P = h·(Δθ + α), |P| ≤ P^lim  OR  trip P = 0          (disconnection disjunction)
#          — or, where `pst_model` gives its parameters, the full protection automaton.
# ---------------------------------------------------------------------------
"""
    StateBuilder

Everything one state needs in order to instantiate the shared equations: the state itself, how
corrective control enters it (`angle_of`, `open_of`, `plim_of`), its injection, and a `memo`
carrying the PST automaton's couplings *across* states (a trip in N is inherited in N-1, and
again post-corrective).
"""
struct StateBuilder
    gm::GridModel
    st::State
    angle_of::Function
    open_of::Function
    plim_of::Function
    pst_model::AbstractDict
    inj::AbstractDict
    drop_slack::Bool
    M::Float64
    tag::String
    memo::Dict{Any,Any}
end

_dθ(br::Branch, θ) = θ[br.bus1] - θ[br.bus2]
_is_automaton(sb::StateBuilder, br::Branch) = br isa Pst && haskey(sb.pst_model, br.id)
_pref(sb::StateBuilder, br::Branch) = sb.memo[(:pref, br.id)]

function _flow!(model, br::Line, θ, sb::StateBuilder)
    p = @variable(model); @constraint(model, p == br.h * _dθ(br, θ)); return p
end

_flow!(model, br::Hvdc, θ, sb::StateBuilder) =
    _clamp!(model, br.p_zero + br.k * _dθ(br, θ), -br.p_lim, br.p_lim, sb.M)

function _flow!(model, br::Pst, θ, sb::StateBuilder)
    _is_automaton(sb, br) && return _automaton_flow!(model, br, θ, sb.st, sb, sb.pst_model[br.id])
    return _switchable_pst_flow!(model, br, θ, sb)
end

# A PST held at a given angle, optionally switchable: `open` is `nothing` (no switching), a
# `Bool` (a fixed candidate) or a binary variable.
function _switchable_pst_flow!(model, br::Pst, θ, sb::StateBuilder)
    open = sb.open_of(br.id); plim = sb.plim_of(br.id, open); M = sb.M
    nat = br.h * (_dθ(br, θ) + sb.angle_of(br.id))
    if open === nothing
        p = @variable(model); @constraint(model, p == nat); return p
    elseif open isa Bool
        open && return AffExpr(0.0)                    # tripped: no flow, buses decoupled
        p = @variable(model); @constraint(model, p == nat)
        isfinite(plim) && @constraint(model, -plim <= p <= plim)
        return p
    end
    p = @variable(model)                               # `open` is a binary variable
    @constraint(model, p <= nat + M * open); @constraint(model, p >= nat - M * open)   # closed ⇒ p = nat
    @constraint(model, p <= M * (1 - open)); @constraint(model, p >= -M * (1 - open))  # open ⇒ p = 0
    if isfinite(plim)
        @constraint(model, p <= plim + M * open); @constraint(model, p >= -plim - M * open)
    end
    return p
end

# The connected-reference layer flows a full-automaton PST as a plain branch at α⁰; every other
# device behaves exactly as in the actual layer.
_reference_flow!(model, br::Branch, θ, sb::StateBuilder) = _flow!(model, br, θ, sb)
function _reference_flow!(model, br::Pst, θ, sb::StateBuilder)
    _is_automaton(sb, br) || return _switchable_pst_flow!(model, br, θ, sb)
    p = @variable(model); @constraint(model, p == br.h * (_dθ(br, θ) + br.alpha0)); return p
end

# One DC layer: bus angles, a flow per active branch, nodal balance. Written once, and reused
# for both the actual state and its connected reference.
function _dc_layer!(model, sb::StateBuilder, tag, flow)
    active = _active(sb.gm.branches, outage(sb.st))
    θ = Dict(b => @variable(model, base_name = "θ_$(tag)_$(b)") for b in sb.gm.buses)
    fix(θ[sb.gm.slack], 0.0; force = true)
    P = Dict{String,Any}(br.id => flow(br, θ) for br in active)
    for n in sb.gm.buses
        (sb.drop_slack && n == sb.gm.slack) && continue
        out_flow = sum(P[br.id] for br in active if br.bus1 == n; init = AffExpr(0.0))
        in_flow  = sum(P[br.id] for br in active if br.bus2 == n; init = AffExpr(0.0))
        @constraint(model, out_flow - in_flow == sb.inj[n])
    end
    return P
end

function _add_state!(model, sb::StateBuilder)
    full = [br for br in _active(sb.gm.branches, outage(sb.st)) if _is_automaton(sb, br)]
    if !isempty(full)
        pref = _dc_layer!(model, sb, "ref_" * sb.tag, (br, θ) -> _reference_flow!(model, br, θ, sb))
        for br in full
            sb.memo[(:pref, br.id)] = pref[br.id]
        end
    end
    return _dc_layer!(model, sb, sb.tag, (br, θ) -> _flow!(model, br, θ, sb))
end

# ---------------------------------------------------------------------------
# Full PST automaton: over-current protection with N→N-1→N-1/c trip propagation, an activation
# threshold, and target regulation. There is one `_automaton_flow!` method per state, so each
# state's behaviour is its own equation rather than a branch inside a single routine.
# ---------------------------------------------------------------------------
# Inactive branch: P = h·(Δθ + α⁰) within the rating, else trip. The over-current test is
# justified against the *connected-reference* flow `p_ref` (a determined quantity), not the
# branch's own — possibly disconnected — angle, so a trip cannot be fabricated.
# `conn_max` (a binary or nothing) forbids reconnection if a prior state tripped.
function _inactive_flow!(model, br, Δθ, plim, M, p_ref; conn_max = nothing)
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
    @constraint(model, p_ref <= plim + M * (1 - conn)); @constraint(model, p_ref >= -plim - M * (1 - conn))  # conn ⇒ no over-current
    @constraint(model, P <= M * conn); @constraint(model, P >= -M * conn)                            # ¬conn ⇒ P = 0
    @constraint(model, p_ref >= plim - M * (1 - dhi))                                                # trip-high justified by reference over-current
    @constraint(model, p_ref <= -plim + M * (1 - dlo))
    return P, conn
end

# Active branch: regulate toward ±P^tar within the angle range (the median of the two clamps),
# and trip on over-current.
function _active_flow!(model, br, Δθ, plim, ptar, M, p_ref; conn_max = nothing)
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
    @constraint(model, reg <= plim + M * (1 - conn)); @constraint(model, reg >= -plim - M * (1 - conn))  # conn ⇒ regulated flow within rating
    @constraint(model, p_ref <= plim + M * (1 - conn)); @constraint(model, p_ref >= -plim - M * (1 - conn))  # conn ⇒ no over-current
    @constraint(model, P <= M * conn); @constraint(model, P >= -M * conn)
    @constraint(model, p_ref >= plim - M * (1 - dhi)); @constraint(model, p_ref <= -plim + M * (1 - dlo))  # trip on reference over-current
    return P, conn
end

# Nominal: the device is inactive at α⁰; it may still trip on over-current.
function _automaton_flow!(model, br::Pst, θ, ::NominalState, sb::StateBuilder, fp)
    P, _ = _inactive_flow!(model, br, _dθ(br, θ), fp.p_lim, sb.M, _pref(sb, br))
    return P
end

# Base (N): as nominal, but a trip here is inherited by every later state.
function _automaton_flow!(model, br::Pst, θ, ::BaseState, sb::StateBuilder, fp)
    P, conn = _inactive_flow!(model, br, _dθ(br, θ), fp.p_lim, sb.M, _pref(sb, br))
    sb.memo[(:conn_N, br.id)] = conn
    return P
end

# Post-contingency (N-1): still inactive at α⁰, cannot reconnect if it tripped in N.
function _automaton_flow!(model, br::Pst, θ, st::ContingencyState, sb::StateBuilder, fp)
    P, conn = _inactive_flow!(model, br, _dθ(br, θ), fp.p_lim, sb.M, _pref(sb, br);
                              conn_max = sb.memo[(:conn_N, br.id)])
    sb.memo[(:conn_N1, br.id, st.outage)] = conn
    sb.memo[(:P_N1, br.id, st.outage)] = P
    return P
end

# Post-corrective (N-1/c): the device activates once |P^{N-1}| ≥ P^act and then regulates toward
# ±P^tar; otherwise it stays inactive at α⁰. Either way a trip inherited from N-1 keeps it open.
function _automaton_flow!(model, br::Pst, θ, st::CorrectiveState, sb::StateBuilder, fp)
    M = sb.M; Δθ = _dθ(br, θ); p_ref = _pref(sb, br)
    conn_N1 = sb.memo[(:conn_N1, br.id, st.outage)]
    P_N1 = sb.memo[(:P_N1, br.id, st.outage)]
    P_ia, _ = _inactive_flow!(model, br, Δθ, fp.p_lim, M, p_ref; conn_max = conn_N1)
    P_a, _  = _active_flow!(model, br, Δθ, fp.p_lim, fp.p_tar, M, p_ref; conn_max = conn_N1)
    act = @variable(model, binary = true); sgn = @variable(model, binary = true)
    @constraint(model, P_N1 <= fp.p_act + M * act); @constraint(model, P_N1 >= -fp.p_act - M * act)   # ¬act ⇒ |P_N1| ≤ P^act
    @constraint(model, P_N1 >= fp.p_act - M * (1 - act) - M * (1 - sgn))                              # act ⇒ |P_N1| ≥ P^act
    @constraint(model, P_N1 <= -fp.p_act + M * (1 - act) + M * sgn)
    P = @variable(model)
    @constraint(model, P <= P_a + M * (1 - act));  @constraint(model, P >= P_a - M * (1 - act))       # act ⇒ P = active flow
    @constraint(model, P <= P_ia + M * act);       @constraint(model, P >= P_ia - M * act)            # ¬act ⇒ P = inactive flow
    return P
end

function _overloads(P, monitored, st::State)
    out = Any[]
    for (id, limspec) in monitored
        haskey(P, id) || continue
        lim = _limit(limspec, st)
        push!(out, P[id] / lim - 1)
        push!(out, -P[id] / lim - 1)
    end
    return out
end

# PST over-current limit applies only where a disconnection mode is available (corrective states
# of switchable PSTs) — elsewhere the PST is at α⁰ and unrestricted (temporary rating assumed).
_plim_of(pst_limits) = (pst_id, open) -> (open === nothing ? Inf : get(pst_limits, pst_id, Inf))

# ---------------------------------------------------------------------------
# The multi-state system, instantiated once per program.
#
# Both programs below build the *same* four-state DC system. They differ only in where the
# corrective controls come from (free variables in the response problem, a fixed candidate in
# the relaxed medial) and in how each overload enters the objective — so those are the two
# callbacks, and the state loop itself is written once.
# ---------------------------------------------------------------------------
function _build_program!(model, gm, states, monitored, correctives, switchable, pst_limits,
                         pst_model, inj_unc, inj_nom, drop_slack, M, tag_prefix,
                         corr_angle, corr_open, on_overload)
    a0 = _pst_alpha0(gm)
    plim_of = _plim_of(pst_limits)
    memo = Dict{Any,Any}()
    for st in states
        cf = corrective_for(st)
        angle_of = function (pid)
            if cf !== nothing && pid in correctives
                c = corr_angle(pid, cf)
                c === nothing || return c
            end
            return get(a0, pid, 0.0)
        end
        open_of = pid -> (cf !== nothing && pid in switchable ? corr_open(pid, cf) : nothing)
        sb = StateBuilder(gm, st, angle_of, open_of, plim_of, pst_model,
                          has_uncertainty(st) ? inj_unc : inj_nom, drop_slack, M,
                          "$(tag_prefix)$(statename(st))", memo)
        for o in _overloads(_add_state!(model, sb), monitored, st)
            on_overload(o)
        end
    end
end

# ---------------------------------------------------------------------------
# Corrective-response problem (LLP)
# ---------------------------------------------------------------------------
function _corrective_response(gm, states, monitored, correctives, switchable, contingencies,
                              participation, pst_limits, pst_model, vstar, opt, silent, bigM, balance_M)
    model = Model(opt); silent && set_silent(model)
    inj_unc, inj_nom, drop_slack = _injection_model!(model, gm, participation, vstar, balance_M)
    ranges = Dict(b.id => (b.alpha_min, b.alpha_max) for b in gm.branches if b isa Pst)
    α = Dict{Tuple{String,String},VariableRef}()
    op = Dict{Tuple{String,String},VariableRef}()
    for c in contingencies, pid in correctives
        a = @variable(model, base_name = "α_$(pid)_$(c)")
        set_lower_bound(a, ranges[pid][1]); set_upper_bound(a, ranges[pid][2])
        α[(pid, c)] = a
        pid in switchable && (op[(pid, c)] = @variable(model, binary = true, base_name = "open_$(pid)_$(c)"))
    end
    @variable(model, η)
    # correctives are free variables here; every overload is an epigraph lower bound on η
    _build_program!(model, gm, states, monitored, correctives, switchable, pst_limits, pst_model,
                    inj_unc, inj_nom, drop_slack, bigM, "",
                    (pid, c) -> get(α, (pid, c), nothing),
                    (pid, c) -> get(op, (pid, c), nothing),
                    o -> @constraint(model, η >= o))
    @objective(model, Min, η)
    optimize!(model)
    ac = Dict((pid, c) => (alpha = value(α[(pid, c)]),
                           open = haskey(op, (pid, c)) ? value(op[(pid, c)]) > 0.5 : false)
              for c in contingencies, pid in correctives)
    return objective_value(model), ac
end

# ---------------------------------------------------------------------------
# Exchange parameterisation
#
# The *exchange* is the net injection deviation of a zone of buses — the power that zone imports
# beyond its forecast. Restricting the uncertainty to realisations whose exchange lies in a range
# is the parameterisation used to ask "how much transfer can this grid absorb?", as opposed to a
# per-bus box, which asks "how much can each injection move?".
# ---------------------------------------------------------------------------
"""
    zone_exchange(v, spec) -> AffExpr

The exchange expression `Σ_{n ∈ spec.buses} v[n]` over the uncertainty variables `v` (buses
outside `v` contribute nothing). `spec` is a `NamedTuple` `(; buses, lo, hi)`.
"""
zone_exchange(v, spec) =
    sum((v[n] for n in spec.buses if haskey(v, n)); init = AffExpr(0.0))

_exchange_constraint!(model, v, ::Nothing) = nothing
function _exchange_constraint!(model, v, spec)
    e = zone_exchange(v, spec)
    haskey(spec, :lo) && @constraint(model, e >= spec.lo)
    haskey(spec, :hi) && @constraint(model, e <= spec.hi)
    return e
end

# ---------------------------------------------------------------------------
# Relaxed medial problem (MLP)
# ---------------------------------------------------------------------------
function _relaxed_medial(gm, states, monitored, uncertain, correctives, switchable, contingencies,
                         participation, pst_limits, pst_model, candidates, bigM, opt, silent, balance_M,
                         exchange = nothing)
    model = Model(opt); silent && set_silent(model)
    v = Dict{String,Any}()
    for (n, (lo, hi)) in uncertain
        vn = @variable(model, base_name = "v_$(n)"); set_lower_bound(vn, lo); set_upper_bound(vn, hi)
        v[n] = vn
    end
    # Exchange parameterisation: the net injection deviation of a zone is the *exchange*, and the
    # uncertainty is restricted to realisations achieving an exchange in the given range. The
    # per-bus box then bounds how the exchange may be composed, not how large it is.
    _exchange_constraint!(model, v, exchange)
    inj_unc, inj_nom, drop_slack = _injection_model!(model, gm, participation, v, balance_M)
    @variable(model, η)
    # each candidate corrective response is a fixed menu entry; a binary picks the branch/state
    # that binds, so η is the worst overload the uncertainty can force against that response
    for (j, cand) in enumerate(candidates)
        sel = VariableRef[]
        _build_program!(model, gm, states, monitored, correctives, switchable, pst_limits, pst_model,
                        inj_unc, inj_nom, drop_slack, bigM, "c$(j)_",
                        (pid, c) -> (haskey(cand, (pid, c)) ? cand[(pid, c)].alpha : nothing),
                        (pid, c) -> (haskey(cand, (pid, c)) ? cand[(pid, c)].open : nothing),
                        function (o)
                            b = @variable(model, binary = true); push!(sel, b)
                            @constraint(model, η <= o + bigM * (1 - b))
                        end)
        @constraint(model, sum(sel) == 1)
    end
    @objective(model, Max, η)
    optimize!(model)
    return objective_value(model), Dict(n => value(v[n]) for n in keys(uncertain))
end

# ---------------------------------------------------------------------------
# Smallest uncorrectable exchange
#
# The security question "how much transfer can this grid absorb?" does not need a search over
# transfer levels. Ask instead for the *smallest* exchange at which correction fails: everything
# below it is correctable by construction, so that value **is** the frontier.
#
# The program minimises the exchange subject to every corrective response in a menu leaving a
# violation. That menu is grown the usual way: a candidate scenario is verified against the full
# corrective freedom, and if it turns out correctable the response that fixes it is added and the
# minimisation repeated. On exit the scenario defeats *all* corrective responses, so its exchange
# is the frontier — reached by cutting, not by bisection.
# ---------------------------------------------------------------------------
"""
    min_violating_exchange(network; zone, uncertain, monitored, e_cap, ...) -> (exchange, injection) | nothing

The smallest zone import at which no corrective response keeps every monitored branch within its
limits, searched within `[0, e_cap]`. Returns `nothing` when the grid is securable across the
whole range — i.e. when `e_cap` itself is achievable.

`restriction` is a required **security margin**, with the same meaning and the same direction as in
[`worst_case_oracle`](@ref): a branch counts as failing when it no longer keeps the margin, so a
larger restriction reports a **smaller** (conservative) frontier. All other keywords match the
oracle.

The value is **exact** on return, not tolerance-limited: the menu minimiser satisfies
`E_menu ≤ E_true`, and when it is verified to defeat *every* corrective response it also witnesses
`E_true ≤ e`, so the two coincide.
"""
function min_violating_exchange(network;
                                zone, uncertain::AbstractDict, monitored::AbstractDict, e_cap::Real,
                                correctives = String[], contingencies = String[],
                                participation::Union{Nothing,AbstractDict} = nothing,
                                hvdc = NamedTuple[], switchable = String[],
                                pst_limits::AbstractDict = Dict{String,Float64}(),
                                pst_model::AbstractDict = Dict{String,Any}(),
                                slack::Union{Nothing,String} = nothing,
                                optimizer = HiGHS.Optimizer, restriction = 0.0, tol = 1e-5,
                                max_iter = 30, bigM = 1e4, balance_bigM = 1e5, silent = true)
    gm = GridModel(network; slack = slack)
    for h in hvdc
        push!(gm.branches, Hvdc(h.id, h.bus1, h.bus2, h.p_zero, h.k, h.p_lim))
    end
    conts = collect(String, contingencies)
    correctives = collect(String, correctives)
    switch = Set(collect(String, switchable))
    states = _states(conts)
    zone = collect(String, zone)

    Cand = Dict{Tuple{String,String},NamedTuple{(:alpha, :open),Tuple{Float64,Bool}}}
    menu = Cand[Cand()]

    for _ in 1:max_iter
        model = Model(optimizer); silent && set_silent(model)
        v = Dict{String,Any}()
        for (n, (lo, hi)) in uncertain
            vn = @variable(model, base_name = "v_$(n)"); set_lower_bound(vn, lo); set_upper_bound(vn, hi)
            v[n] = vn
        end
        E = @variable(model, base_name = "E"); set_lower_bound(E, 0.0); set_upper_bound(E, e_cap)
        @constraint(model, zone_exchange(v, (buses = zone,)) == -E)   # import ⇒ negative deviation
        inj_unc, inj_nom, drop_slack = _injection_model!(model, gm, participation, v, balance_bigM)
        for (j, cand) in enumerate(menu)
            sel = VariableRef[]
            _build_program!(model, gm, states, monitored, correctives, switch, pst_limits, pst_model,
                            inj_unc, inj_nom, drop_slack, bigM, "m$(j)_",
                            (pid, c) -> (haskey(cand, (pid, c)) ? cand[(pid, c)].alpha : nothing),
                            (pid, c) -> (haskey(cand, (pid, c)) ? cand[(pid, c)].open : nothing),
                            function (o)
                                b = @variable(model, binary = true); push!(sel, b)
                                @constraint(model, o >= -restriction - bigM * (1 - b))
                            end)
            @constraint(model, sum(sel) == 1)      # this response must leave some branch violated
        end
        @objective(model, Min, E)
        optimize!(model)
        termination_status(model) == MOI.OPTIMAL || return nothing   # nothing violates within e_cap
        e = value(E)
        vstar = Dict(n => value(v[n]) for n in keys(uncertain))

        # Verify the candidate against the full corrective freedom, not just the menu.
        phi, ac = _corrective_response(gm, states, monitored, correctives, switch, conts,
                                       participation, pst_limits, pst_model, vstar,
                                       optimizer, silent, bigM, balance_bigM)
        phi > -restriction - tol && return (e, vstar)  # genuinely uncorrectable ⇒ the frontier
        push!(menu, ac)                                # correctable ⇒ enrich the menu and retry
    end
    return nothing
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
  equilibria are resolved to the physical one by a connected-reference trip test, so the automaton
  composes with the free `correctives` (the max/min bounds meet).
* `restriction` — tighten the security test by `ε_R ≥ 0`: the grid counts as secure only with a
  margin, `φ ≤ −ε_R`. A restricted answer is **conservative**, so a configuration it accepts is
  securable with room to spare — the restriction-of-the-right-hand-side idea, used to obtain
  guaranteed-achievable values rather than the exact frontier. `0` gives the exact test.
* `exchange` — `(; buses, lo, hi)` to use the **exchange parameterisation**: the uncertainty is
  restricted to realisations whose net injection deviation over `buses` (the zone's exchange) lies
  in `[lo, hi]`. `uncertain` then bounds how the exchange may be composed per bus, while `lo`/`hi`
  bound its size. Omit for a pure per-bus box.
"""
function worst_case_oracle(network;
                           uncertain::AbstractDict, monitored::AbstractDict,
                           correctives = String[], contingencies = String[],
                           participation::Union{Nothing,AbstractDict} = nothing,
                           hvdc = NamedTuple[], switchable = String[], pst_limits::AbstractDict = Dict{String,Float64}(),
                           pst_model::AbstractDict = Dict{String,Any}(),
                           exchange = nothing, restriction = 0.0,
                           slack::Union{Nothing,String} = nothing,
                           optimizer = HiGHS.Optimizer, tol = 1e-5, max_iter = 30,
                           bigM = 1e4, balance_bigM = 1e5, silent = true)
    gm = GridModel(network; slack = slack)
    for h in hvdc
        push!(gm.branches, Hvdc(h.id, h.bus1, h.bus2, h.p_zero, h.k, h.p_lim))
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
    # discretize, the PST is part of the grid model and has no discretionary control. Its trip is
    # pinned deterministically by the connected-reference over-current test (see
    # `_reference_flow!`), so the relaxed-medial (max over uncertainty) and the corrective-response
    # (physical evaluation) agree: a single pass suffices and the reported `φ` is the response value.
    if isempty(correctives) && isempty(switch)
        ub, vstar = _relaxed_medial(gm, states, monitored, uncertain, correctives, switch, conts,
                                    participation, pst_limits, pst_model, candidates, bigM, optimizer, silent, balance_bigM, exchange)
        lb, _ = _corrective_response(gm, states, monitored, correctives, switch, conts,
                                     participation, pst_limits, pst_model, vstar, optimizer, silent, bigM, balance_bigM)
        return WorstCaseSolution(lb, lb <= tol - restriction, vstar,
                                 Dict{String,Dict{String,Float64}}(), 1, lb, ub)
    end

    for k in 1:max_iter
        iterations = k
        ub, vstar = _relaxed_medial(gm, states, monitored, uncertain, correctives, switch, conts,
                                    participation, pst_limits, pst_model, candidates, bigM, optimizer, silent, balance_bigM, exchange)
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
    return WorstCaseSolution(phi, phi <= tol - restriction, vstar, corr_by_c, iterations, best_lb, ub)
end

end # module

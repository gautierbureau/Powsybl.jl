# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

"""
    PowsyblDcOpf

A native Julia DC optimal power flow (DC-OPF) on top of the Powsybl.jl APIs, built with
JuMP + HiGHS. It reproduces two classic formulations of the linear OPF with a phase-shifting
transformer (PST) as a continuous control:

* [`theta_formulation`](@ref) — the **bus-angle (B-θ) formulation**: bus voltage angles and
  branch flows are variables tied by `P_branch = h·(θ₁ − θ₂ (+ φ))`, with a nodal balance
  (KCL) at every bus. Uses only the network topology (reactances + nominal voltages).
* [`ptdf_formulation`](@ref) — the **PTDF formulation**: bus angles are eliminated; branch
  flows are `F = PTDF·(nodal injection) + PSDF·φ`, where the PTDF/PSDF sensitivity matrices
  come from a DC sensitivity analysis on the real engine.

Both minimise generation cost plus a PST-movement penalty subject to thermal limits, and both
are validated against a DC load flow via [`validate_with_dc_loadflow`](@ref).

The fixture network is [`build_pst_network`](@ref) (the `pst_focus` case): two parallel paths
S1→S2, one bypassing the PST (`L12a`) and one feeding it (`L1_2a` → `PST_T`), merging at B2b
and exiting to S3 via `L2b_3`.
"""
module PowsyblDcOpf

using Powsybl
using JuMP
import HiGHS
import DataFrames

const NET = Powsybl.Network
const LF  = Powsybl.LoadFlow
const SEN = Powsybl.SensitivityAnalysis
const LIB = Powsybl.LibPowsybl

# ---------------------------------------------------------------------------
# Constants (mirroring the Python reference: DCOPF/PST/common_pst.py)
# ---------------------------------------------------------------------------
const BASE_MVA  = 100.0
const KV        = 400.0
const Z_BASE    = KV^2 / BASE_MVA          # 1600 Ω on a 400 kV / 100 MVA base
const PHI_MAX   = deg2rad(30.0)            # PST angle bound (rad)
const THETA_MAX = pi / 3                   # bus-angle bound (rad)
const C_PST     = 5.0                      # PST-movement penalty ($/rad)

# Thermal limits and generator costs for the `pst_focus` fixture, matching the reference
# `theta_formulation.py` / `ptdf_formulation.py` (L12a congested at 110 MW).
const DEFAULT_LINE_MAX_P = Dict("L12a" => 110.0, "L1_2a" => 150.0, "L2b_3" => 200.0)
const DEFAULT_TFO_MAX_P  = Dict("PST_T" => 150.0)
const DEFAULT_COST       = Dict("G1" => 30.0, "G2" => 45.0)

"""
    DcOpfSolution

Result of a DC-OPF solve.

* `formulation` — `:theta` or `:ptdf`.
* `termination` — the JuMP termination status.
* `cost`        — objective value (generation cost + PST penalty).
* `generation`  — `id => set point (MW)` for every generator.
* `phi`         — `pst id => optimal phase-shift angle (rad)`.
* `flows`       — `branch id => active-power flow (MW)`, signed side-1 → side-2.
* `angles`      — `bus id => voltage angle (rad)` (empty for the PTDF formulation).
"""
struct DcOpfSolution
    formulation::Symbol
    termination::Any
    cost::Float64
    generation::Dict{String,Float64}
    phi::Dict{String,Float64}
    flows::Dict{String,Float64}
    angles::Dict{String,Float64}
end

generation(sol::DcOpfSolution, id) = sol.generation[id]
flow(sol::DcOpfSolution, id) = sol.flows[id]

# ---------------------------------------------------------------------------
# Fixture network — reproduces DCOPF/PST/common_pst.build_network (saved as pst1.xiidm)
# ---------------------------------------------------------------------------
"""
    build_pst_network() -> NetworkHandle

Build the `pst_focus` DC-OPF fixture: substations S1/S2/S3, four buses (B1, B2a, B2b, B3),
three lines (`L12a`, `L1_2a`, `L2b_3`), a phase-shifting transformer `PST_T` (21 taps,
neutral 10, 3°/step) between B2a and B2b, generators G1 (at B1) and G2 (at B3), and a 250 MW
load at B3. All reactances are ideal (r = g = b = 0) on a 400 kV / 100 MVA base.
"""
function build_pst_network()
    x_of(b) = BASE_MVA / b * Z_BASE   # susceptance (MW/rad) -> reactance (Ω)

    net = NET.create_empty("pst_focus")
    NET.create_substations(net; id = ["S1", "S2", "S3"], country = ["FR", "FR", "FR"])
    NET.create_voltage_levels(net;
        id = ["VL1", "VL2a", "VL2b", "VL3"],
        substation_id = ["S1", "S2", "S2", "S3"],
        topology_kind = ["BUS_BREAKER", "BUS_BREAKER", "BUS_BREAKER", "BUS_BREAKER"],
        nominal_v = [KV, KV, KV, KV])
    NET.create_buses(net;
        id = ["B1", "B2a", "B2b", "B3"],
        voltage_level_id = ["VL1", "VL2a", "VL2b", "VL3"])

    # L12a: B1 -> B2b, direct path that bypasses the PST (b = 500 MW/rad)
    NET.create_lines(net; id = ["L12a"],
        voltage_level1_id = ["VL1"], bus1_id = ["B1"],
        voltage_level2_id = ["VL2b"], bus2_id = ["B2b"],
        r = [0.0], x = [x_of(BASE_MVA / 0.2)],
        g1 = [0.0], b1 = [0.0], g2 = [0.0], b2 = [0.0])
    # L1_2a: B1 -> B2a, entry leg feeding the PST (b = 250 MW/rad)
    NET.create_lines(net; id = ["L1_2a"],
        voltage_level1_id = ["VL1"], bus1_id = ["B1"],
        voltage_level2_id = ["VL2a"], bus2_id = ["B2a"],
        r = [0.0], x = [x_of(BASE_MVA / 0.4)],
        g1 = [0.0], b1 = [0.0], g2 = [0.0], b2 = [0.0])
    # L2b_3: B2b -> B3, single exit line (b = 500 MW/rad)
    NET.create_lines(net; id = ["L2b_3"],
        voltage_level1_id = ["VL2b"], bus1_id = ["B2b"],
        voltage_level2_id = ["VL3"], bus2_id = ["B3"],
        r = [0.0], x = [x_of(BASE_MVA / 0.2)],
        g1 = [0.0], b1 = [0.0], g2 = [0.0], b2 = [0.0])

    # PST_T: B2a -> B2b, same substation S2 (b = 1000 MW/rad)
    NET.create_2_windings_transformers(net; id = ["PST_T"],
        voltage_level1_id = ["VL2a"], bus1_id = ["B2a"],
        voltage_level2_id = ["VL2b"], bus2_id = ["B2b"],
        rated_u1 = [KV], rated_u2 = [KV],
        r = [0.0], x = [x_of(BASE_MVA / 0.1)], g = [0.0], b = [0.0])

    n_steps = 21; neutral = 10; astep = 3.0   # -30° .. +30° in 3° steps
    alphas = [(i - neutral) * astep for i in 0:(n_steps - 1)]
    NET.create_phase_tap_changers(net;
        id = "PST_T", low_tap = 0, tap = neutral,
        regulation_mode = "CURRENT_LIMITER", regulating = false, target_deadband = 0.0,
        steps = (id = fill("PST_T", n_steps), alpha = alphas, rho = fill(1.0, n_steps),
                 r = zeros(n_steps), x = zeros(n_steps), g = zeros(n_steps), b = zeros(n_steps)))

    NET.create_generators(net;
        id = ["G1", "G2"], voltage_level_id = ["VL1", "VL3"], bus_id = ["B1", "B3"],
        energy_source = ["OTHER", "OTHER"], min_p = [0.0, 0.0], max_p = [300.0, 150.0],
        target_p = [200.0, 50.0], target_v = [KV, KV], target_q = [0.0, 0.0],
        voltage_regulator_on = [true, false])
    NET.create_loads(net; id = ["D3"], voltage_level_id = ["VL3"], bus_id = ["B3"],
        p0 = [250.0], q0 = [0.0])
    return net
end

# ---------------------------------------------------------------------------
# Shared data extraction
# ---------------------------------------------------------------------------
_rows(df) = 1:DataFrames.nrow(df)
_dict(df, k, v) = Dict(df[i, k] => df[i, v] for i in _rows(df))

struct _Branch
    id::String
    bus1::String
    bus2::String
    x::Float64
    v2::Float64        # side-2 nominal voltage (kV)
    is_pst::Bool
    max_p::Union{Nothing,Float64}
end

# Assemble the branch table (lines then transformers), tagging the PST branches and their
# per-branch thermal limits. Transformers use `x_at_current_tap` (the PST base reactance).
function _branches(lines, tfos, psts, nominal_v, line_max_p, tfo_max_p)
    pst_ids = Set(collect(psts.id))
    out = _Branch[]
    for i in _rows(lines)
        id = lines[i, :id]
        push!(out, _Branch(id, lines[i, :bus1_id], lines[i, :bus2_id], lines[i, :x],
                           nominal_v[lines[i, :voltage_level2_id]], false, get(line_max_p, id, nothing)))
    end
    for i in _rows(tfos)
        id = tfos[i, :id]
        push!(out, _Branch(id, tfos[i, :bus1_id], tfos[i, :bus2_id], tfos[i, :x_at_current_tap],
                           nominal_v[tfos[i, :voltage_level2_id]], id in pst_ids, get(tfo_max_p, id, nothing)))
    end
    return out
end

# Generators as (id, bus, min, max, cost); loads aggregated per bus.
function _generators(gens, cost)
    [(id = gens[i, :id], bus = gens[i, :bus_id], min = gens[i, :min_p], max = gens[i, :max_p],
      cost = cost[gens[i, :id]]) for i in _rows(gens)]
end

function _load_by_bus(loads)
    d = Dict{String,Float64}()
    for i in _rows(loads)
        d[loads[i, :bus_id]] = get(d, loads[i, :bus_id], 0.0) + loads[i, :p0]
    end
    return d
end

# ---------------------------------------------------------------------------
# θ (bus-angle) formulation
# ---------------------------------------------------------------------------
"""
    theta_formulation(network; line_max_p, tfo_max_p, cost, pst_cost, optimizer) -> DcOpfSolution

DC-OPF in the bus-angle formulation. Bus angles `θ`, branch flows `P`, and PST angles `φ` are
variables; each branch enforces `P = h·(θ₁ − θ₂ (+ φ))` with `h = V₂²/x`, each bus enforces
nodal balance, and thermal limits box the flows. Minimises `Σ cost·Pg + pst_cost·Σ|φ|`.
"""
function theta_formulation(network;
                           line_max_p = DEFAULT_LINE_MAX_P, tfo_max_p = DEFAULT_TFO_MAX_P,
                           cost = DEFAULT_COST, pst_cost = C_PST, optimizer = HiGHS.Optimizer)
    gens_df = NET.get_generators(network, true)
    loads   = NET.get_loads(network, true)
    buses   = NET.get_buses(network, true)
    lines   = NET.get_lines(network, true)
    tfos    = NET.get_2_windings_transformers(network, true)
    psts    = NET.get_phase_tap_changers(network, true)
    vls     = NET.get_voltage_levels(network, true)

    nominal_v = _dict(vls, :id, :nominal_v)
    bus_ids   = collect(buses.id)
    slack     = bus_ids[1]
    branches  = _branches(lines, tfos, psts, nominal_v, line_max_p, tfo_max_p)
    gens      = _generators(gens_df, cost)
    load_bus  = _load_by_bus(loads)
    pst_ids   = collect(psts.id)

    model = Model(optimizer)
    set_silent(model)

    @variable(model, Pg[g in [x.id for x in gens]])
    for g in gens
        set_lower_bound(Pg[g.id], g.min); set_upper_bound(Pg[g.id], g.max)
    end
    # Bus angles: the slack bus is fixed at 0.
    @variable(model, -THETA_MAX <= θ[b in bus_ids] <= THETA_MAX)
    fix(θ[slack], 0.0; force = true)
    @variable(model, P[br in [b.id for b in branches]])
    @variable(model, -PHI_MAX <= φ[p in pst_ids] <= PHI_MAX)
    @variable(model, 0 <= ψ[p in pst_ids] <= PHI_MAX)
    @constraint(model, [p in pst_ids], ψ[p] >= φ[p])
    @constraint(model, [p in pst_ids], ψ[p] >= -φ[p])

    # Branch flow definitions: P = h·(θ₁ − θ₂ (+ φ)),  h = V₂²/x = BASE_MVA/x · Z_BASE₂.
    for br in branches
        z_base = br.v2^2 / BASE_MVA
        h = BASE_MVA / br.x * z_base
        expr = @expression(model, P[br.id] - h * (θ[br.bus1] - θ[br.bus2]))
        if br.is_pst
            expr = @expression(model, expr - h * φ[br.id])
        end
        @constraint(model, expr == 0)
        if br.max_p !== nothing
            @constraint(model, -br.max_p <= P[br.id] <= br.max_p)
        end
    end

    # Nodal balance (KCL) at each bus: gen − load + inflow − outflow = 0.
    for b in bus_ids
        expr = AffExpr(0.0)
        for g in gens; g.bus == b && add_to_expression!(expr, Pg[g.id]); end
        haskey(load_bus, b) && add_to_expression!(expr, -load_bus[b])
        for br in branches
            br.bus2 == b && add_to_expression!(expr, P[br.id])
            br.bus1 == b && add_to_expression!(expr, -P[br.id])
        end
        @constraint(model, expr == 0)
    end

    @objective(model, Min,
        sum(g.cost * Pg[g.id] for g in gens) + pst_cost * sum(ψ[p] for p in pst_ids))
    optimize!(model)

    return DcOpfSolution(:theta, termination_status(model), objective_value(model),
        Dict(g.id => value(Pg[g.id]) for g in gens),
        Dict(p => value(φ[p]) for p in pst_ids),
        Dict(br.id => value(P[br.id]) for br in branches),
        Dict(b => value(θ[b]) for b in bus_ids))
end

# ---------------------------------------------------------------------------
# PTDF formulation
# ---------------------------------------------------------------------------
"""
    ptdf_formulation(network; line_max_p, tfo_max_p, cost, pst_cost, optimizer, dc) -> DcOpfSolution

DC-OPF in the PTDF formulation. Bus angles are eliminated: branch flows are reconstructed as
`F = PTDF·(nodal injection) + PSDF·φ`, where PTDF (branch flow vs bus injection) and PSDF
(branch flow vs PST phase) come from a DC sensitivity analysis on the engine. One injection
variable per injection bus is used (a generator is preferred over a load as the representative
element so all sensitivities share the generator-injection sign convention).
"""
function ptdf_formulation(network;
                          line_max_p = DEFAULT_LINE_MAX_P, tfo_max_p = DEFAULT_TFO_MAX_P,
                          cost = DEFAULT_COST, pst_cost = C_PST, optimizer = HiGHS.Optimizer,
                          dc = true)
    gens_df = NET.get_generators(network, true)
    loads   = NET.get_loads(network, true)
    lines   = NET.get_lines(network, true)
    tfos    = NET.get_2_windings_transformers(network, true)
    psts    = NET.get_phase_tap_changers(network, true)

    gens     = _generators(gens_df, cost)
    load_bus = _load_by_bus(loads)
    branch_ids = vcat(collect(lines.id), collect(tfos.id))
    pst_ids  = collect(psts.id)
    branch_limit = merge(Dict{String,Union{Nothing,Float64}}(), line_max_p, tfo_max_p)

    # One representative injection element per bus (generator preferred), aligned with the
    # sorted injection buses so PTDF rows map cleanly to bus net injections.
    rep = Dict{String,String}()
    for i in _rows(gens_df); b = gens_df[i, :bus_id]; haskey(rep, b) || (rep[b] = gens_df[i, :id]); end
    for i in _rows(loads);   b = loads[i, :bus_id];   haskey(rep, b) || (rep[b] = loads[i, :id]);   end
    inj_buses = sort(collect(keys(rep)))
    inj_vars  = [rep[b] for b in inj_buses]

    # DC sensitivities: PTDF (branch flow / bus injection) and PSDF (branch flow / PST phase).
    analysis = SEN.create()
    SEN.add_factor_matrix(analysis, branch_ids, inj_vars; matrix_id = "PTDF",
        sensitivity_function_type = SEN.BRANCH_ACTIVE_POWER_1,
        sensitivity_variable_type = SEN.INJECTION_ACTIVE_POWER)
    SEN.add_factor_matrix(analysis, branch_ids, pst_ids; matrix_id = "PSDF",
        sensitivity_function_type = SEN.BRANCH_ACTIVE_POWER_1,
        sensitivity_variable_type = SEN.TRANSFORMER_PHASE)
    params = LF.load_flow_parameters(); params.distributed_slack = false
    result = dc ? SEN.run_dc(analysis, network, params) : SEN.run_ac(analysis, network, params)
    ptdf = SEN.get_sensitivity_matrix(result, "PTDF")            # (n_inj × n_branch)
    psdf = SEN.get_sensitivity_matrix(result, "PSDF") .* (180 / pi)  # per-radian (n_pst × n_branch)

    model = Model(optimizer)
    set_silent(model)
    @variable(model, Pg[g in [x.id for x in gens]])
    for g in gens
        set_lower_bound(Pg[g.id], g.min); set_upper_bound(Pg[g.id], g.max)
    end
    @variable(model, -PHI_MAX <= φ[p in pst_ids] <= PHI_MAX)
    @variable(model, 0 <= ψ[p in pst_ids] <= PHI_MAX)
    @constraint(model, [p in pst_ids], ψ[p] >= φ[p])
    @constraint(model, [p in pst_ids], ψ[p] >= -φ[p])

    # System balance: total generation meets total load.
    @constraint(model, sum(Pg[g.id] for g in gens) == sum(values(load_bus)))

    # Net nodal injection expression per injection bus (gen variables − fixed load).
    netinj = Dict(b => AffExpr(0.0) for b in inj_buses)
    for g in gens; add_to_expression!(netinj[g.bus], Pg[g.id]); end
    for (b, pd) in load_bus; add_to_expression!(netinj[b], -pd); end

    # Branch flows F = PTDF·netinj + PSDF·φ, boxed by thermal limits.
    flow_expr = Dict{String,AffExpr}()
    for (j, br) in enumerate(branch_ids)
        F = AffExpr(0.0)
        for (i, b) in enumerate(inj_buses)
            add_to_expression!(F, ptdf[i, j], netinj[b])
        end
        for (k, p) in enumerate(pst_ids)
            add_to_expression!(F, psdf[k, j], φ[p])
        end
        flow_expr[br] = F
        lim = get(branch_limit, br, nothing)
        if lim !== nothing
            @constraint(model, -lim <= F <= lim)
        end
    end

    @objective(model, Min,
        sum(g.cost * Pg[g.id] for g in gens) + pst_cost * sum(ψ[p] for p in pst_ids))
    optimize!(model)

    return DcOpfSolution(:ptdf, termination_status(model), objective_value(model),
        Dict(g.id => value(Pg[g.id]) for g in gens),
        Dict(p => value(φ[p]) for p in pst_ids),
        Dict(br => value(flow_expr[br]) for br in branch_ids),
        Dict{String,Float64}())
end

# ---------------------------------------------------------------------------
# Validation against a DC load flow
# ---------------------------------------------------------------------------
"""
    phi_to_tap(phi_rad; neutral = 10, step_deg = 3.0, low = 0, high = 20) -> Int

Map a continuous PST angle (rad) to the nearest discrete tap position.
"""
phi_to_tap(phi_rad; neutral = 10, step_deg = 3.0, low = 0, high = 20) =
    clamp(neutral + round(Int, rad2deg(phi_rad) / step_deg), low, high)

"""
    validate_with_dc_loadflow(network, solution) -> Dict{String,Float64}

Deploy a solution's generator set points and PST tap (quantised from `φ`) onto the network,
run a DC load flow, and return the resulting per-branch flows (side-1 active power). The PST
tap is discrete, so flows match the continuous OPF exactly only when `φ` lands on a tap.
"""
function validate_with_dc_loadflow(network, solution::DcOpfSolution)
    for (g, p) in solution.generation
        NET.update_generators(network; id = g, target_p = p)
    end
    for (p, phi) in solution.phi
        NET.update_elements(network, LIB.PHASE_TAP_CHANGER; id = p, tap = phi_to_tap(phi))
    end
    params = LF.load_flow_parameters(); params.distributed_slack = false
    LF.run_dc(network, params)

    lines = NET.get_lines(network, true)
    tfos  = NET.get_2_windings_transformers(network, true)
    flows = Dict{String,Float64}()
    for i in _rows(lines); flows[lines[i, :id]] = lines[i, :p1]; end
    for i in _rows(tfos);  flows[tfos[i, :id]]  = tfos[i, :p1];  end
    return flows
end

end # module

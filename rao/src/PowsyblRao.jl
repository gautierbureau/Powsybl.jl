# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

"""
    PowsyblRao

A native Julia remedial-action optimizer built on the Powsybl.jl APIs and JuMP, mirroring
the inner "linear problem" of OpenRAO's SearchTreeRao: each flow CNEC — in its own state
(base case or post-contingency) — is linearized around the current operating point using
sensitivities, and the minimum margin over all CNECs is maximized over the available
preventive range actions.

Supported:
- **multiple range actions of mixed types**: PST range actions (discrete taps, via the
  phase-shift angle) and injection range actions (redispatching, via a keyed injection zone);
- **N-1**: post-contingency (outage / curative) flow CNECs, via per-contingency sensitivities;
- a **discrete-tap MILP** (PST taps) combined with continuous injection set points, or a fully
  continuous LP;
- an **SLP outer loop** re-linearizing at the chosen taps until they converge;
- an optional **PST-movement penalty**.
"""
module PowsyblRao
  using Powsybl
  using JuMP
  using HiGHS
  import DataFrames

  const MOI = JuMP.MOI
  const RAO = Powsybl.RAO
  const NET = Powsybl.Network
  const SEN = Powsybl.SensitivityAnalysis
  const LIB = Powsybl.LibPowsybl

  """
  Optimized value of one range action in a [`Solution`](@ref):
  - `id` / `kind` (`:pst` or `:injection`);
  - `set_point`: the optimized phase-shift angle (degrees) for a PST, or the redispatch set
    point (MW) for an injection range action;
  - `tap`: the optimized tap for a PST, `nothing` otherwise.
  """
  struct RangeActionSolution
    id::String
    kind::Symbol
    set_point::Float64
    tap::Union{Int, Nothing}
  end

  """
  Result of [`solve_preventive`](@ref):
  - `range_actions`: the optimized range actions (see [`RangeActionSolution`](@ref));
  - `min_margin` / `initial_min_margin`: optimized and pre-optimization minimum margins (MW);
  - `cnec_margins`: per-CNEC margin (MW) at the optimum; `binding_cnec`: the CNEC achieving
    the minimum;
  - `iterations`: SLP iterations; `termination`: JuMP status of the last solve.
  """
  struct Solution
    range_actions::Vector{RangeActionSolution}
    min_margin::Float64
    initial_min_margin::Float64
    cnec_margins::Dict{String, Float64}
    binding_cnec::String
    iterations::Int
    termination::Any
  end

  "Fetch the optimized range action with the given id."
  range_action(sol::Solution, id::AbstractString) = sol.range_actions[findfirst(r -> r.id == id, sol.range_actions)]

  _nearest_tap(angle_by_tap, angle, taps) = argmin(t -> abs(angle_by_tap[t] - angle), taps)

  function _min_margin(cnec_ids, flows, tmin, tmax)
    mm, binding = Inf, ""
    for (j, id) in enumerate(cnec_ids)
      m = Inf
      haskey(tmax, id) && (m = min(m, tmax[id] - flows[j]))
      haskey(tmin, id) && (m = min(m, flows[j] - tmin[id]))
      m < mm && ((mm, binding) = (m, id))
    end
    return mm, binding
  end

  # CNECs (with their states), thresholds and contingencies.
  function _cnec_data(crac)
    flow_cnecs = RAO.get_flow_cnecs(crac)
    DataFrames.nrow(flow_cnecs) > 0 || error("PowsyblRao: no flow CNECs in the CRAC")
    thresholds = RAO.get_thresholds(crac)
    tmin, tmax = Dict{String, Float64}(), Dict{String, Float64}()
    for row in DataFrames.eachrow(thresholds)
      String(row.unit) == "MEGAWATT" || error("PowsyblRao only supports MW thresholds, got $(row.unit)")
      tmin[String(row.id)] = row.min
      tmax[String(row.id)] = row.max
    end
    contingencies = Dict{String, Vector{String}}()
    for row in DataFrames.eachrow(RAO.get_contingency_elements(crac))
      push!(get!(contingencies, String(row.id), String[]), String(row.network_element_id))
    end
    return (; cnec_ids = String.(flow_cnecs.id), branches = String.(flow_cnecs.network_element_id),
             cnec_states = String.(flow_cnecs.contingency_id), tmin, tmax, contingencies)
  end

  # The preventive range actions (PST + injection) available in the CRAC.
  function _range_actions(crac, network)
    ranges = RAO.get_range_action_ranges(crac)
    ra_range(id) = ranges[String.(ranges.id) .== id, :]
    steps = NET.get_phase_tap_changer_steps(network, true)
    ptc = NET.get_phase_tap_changers(network, true)
    keys_df = RAO.get_network_element_ids_and_keys(crac)

    ras = Any[]
    for row in DataFrames.eachrow(RAO.get_pst_range_actions(crac))
      id, pst_id = String(row.id), String(row.network_element_id)
      rr = ra_range(id)
      DataFrames.nrow(rr) >= 1 || error("PowsyblRao: no range for PST range action $id")
      pst_steps = steps[String.(steps.id) .== pst_id, :]
      angle_by_tap = Dict{Int, Float64}(Int(r.position) => Float64(r.alpha) for r in DataFrames.eachrow(pst_steps))
      prow = ptc[String.(ptc.id) .== pst_id, :]
      DataFrames.nrow(prow) == 1 || error("PowsyblRao: phase tap changer $pst_id not found")
      tap_min = max(Int(round(minimum(rr.min))), Int(prow[1, :low_tap]))
      tap_max = min(Int(round(maximum(rr.max))), Int(prow[1, :high_tap]))
      valid_taps = [t for t in tap_min:tap_max if haskey(angle_by_tap, t)]
      push!(ras, (; id, kind = :pst, variable_id = pst_id, angle_by_tap, valid_taps,
                   current_tap = Int(prow[1, :tap])))
    end
    for row in DataFrames.eachrow(RAO.get_injection_range_actions(crac))
      id = String(row.id)
      rr = ra_range(id)
      DataFrames.nrow(rr) >= 1 || error("PowsyblRao: no range for injection range action $id")
      keys = Dict(String(r.network_element_id) => Float64(r.distribution_key)
                  for r in DataFrames.eachrow(keys_df) if String(r.id) == id)
      push!(ras, (; id, kind = :injection, variable_id = id, keys,
                   setpoint_min = Float64(minimum(rr.min)), setpoint_max = Float64(maximum(rr.max))))
    end
    isempty(ras) && error("PowsyblRao: the CRAC has no PST or injection range action")
    return ras
  end

  # Per-RA, per-CNEC flow sensitivities (each CNEC read in its own state) and the reference
  # flows. One factor matrix per range action; injection RAs use a keyed sensitivity zone.
  function _sensitivities(network, cnecs, ras; dc::Bool)
    analysis = SEN.create()
    for (contingency_id, elements) in cnecs.contingencies
      SEN.add_multiple_elements_contingency(analysis, elements, contingency_id)
    end
    zones = [SEN.create_zone(ra.id, ra.keys) for ra in ras if ra.kind == :injection]
    isempty(zones) || SEN.set_zones(analysis, zones)
    for ra in ras
      vtype = ra.kind == :pst ? SEN.TRANSFORMER_PHASE : SEN.AUTO_DETECT
      SEN.add_factor_matrix(analysis, cnecs.branches, [ra.variable_id];
                            matrix_id = ra.id, sensitivity_variable_type = vtype)
    end
    result = dc ? SEN.run_dc(analysis, network) : SEN.run_ac(analysis, network)

    states = unique(cnecs.cnec_states)
    fmat = Dict(s => SEN.get_reference_matrix(result, ras[1].id, s) for s in states)
    F = [fmat[cnecs.cnec_states[j]][1, j] for j in eachindex(cnecs.cnec_ids)]
    S = Dict{String, Vector{Float64}}()
    for ra in ras
      smat = Dict(s => SEN.get_sensitivity_matrix(result, ra.id, s) for s in states)
      S[ra.id] = [smat[cnecs.cnec_states[j]][1, j] for j in eachindex(cnecs.cnec_ids)]
    end
    return S, F
  end

  _apply_tap(network, pst_id, tap) = NET.update_elements(network, LIB.PHASE_TAP_CHANGER; id = pst_id, tap = tap)

  # One MILP/LP step: a discrete tap per PST and a continuous set point per injection RA,
  # maximizing the minimum margin. `lin` gives each RA's linearization set point.
  function _solve_step(cnecs, ras, S, F, lin, base; discrete, pst_penalty, optimizer)
    model = Model(optimizer)
    set_silent(model)
    @variable(model, min_margin)
    setpoint = Dict{String, Any}()
    zvars = Dict{String, Any}()
    penalty_terms = AffExpr[]
    for ra in ras
      if ra.kind == :pst
        z = @variable(model, [ra.valid_taps], Bin)
        @constraint(model, sum(z[t] for t in ra.valid_taps) == 1)
        setpoint[ra.id] = @expression(model, sum(ra.angle_by_tap[t] * z[t] for t in ra.valid_taps))
        zvars[ra.id] = z
        if pst_penalty > 0
          mov = @variable(model, lower_bound = 0.0)
          @constraint(model, mov >= setpoint[ra.id] - base[ra.id])
          @constraint(model, mov >= base[ra.id] - setpoint[ra.id])
          push!(penalty_terms, pst_penalty * mov)
        end
      else
        setpoint[ra.id] = @variable(model, lower_bound = ra.setpoint_min, upper_bound = ra.setpoint_max)
      end
    end
    for j in eachindex(cnecs.cnec_ids)
      flow = @expression(model, F[j] + sum(S[ra.id][j] * (setpoint[ra.id] - lin[ra.id]) for ra in ras))
      id = cnecs.cnec_ids[j]
      haskey(cnecs.tmax, id) && @constraint(model, min_margin <= cnecs.tmax[id] - flow)
      haskey(cnecs.tmin, id) && @constraint(model, min_margin <= flow - cnecs.tmin[id])
    end
    @objective(model, Max, min_margin - sum(penalty_terms; init = zero(AffExpr)))
    optimize!(model)

    taps = Dict{String, Union{Int, Nothing}}()
    points = Dict{String, Float64}()
    for ra in ras
      if ra.kind == :pst
        t = ra.valid_taps[argmax([value(zvars[ra.id][k]) for k in ra.valid_taps])]
        taps[ra.id] = t
        points[ra.id] = ra.angle_by_tap[t]
      else
        taps[ra.id] = nothing
        points[ra.id] = value(setpoint[ra.id])
      end
    end
    return taps, points, termination_status(model)
  end

  """
      solve_preventive(network, crac; optimizer = HiGHS.Optimizer, discrete = true,
                       max_iterations = 10, pst_penalty = 0.0, dc = true) -> Solution

  Optimize the preventive range actions of `crac` on `network` to maximize the minimum margin
  over all flow CNECs (each in its own state). Handles PST range actions (discrete taps) and
  injection range actions (redispatching) together.

  The network's PST taps are restored before returning (pure query). Reported margins come
  from the recomputed reference flows plus the linear injection contribution.
  """
  function solve_preventive(network::Powsybl.Network.NetworkHandle, crac::Powsybl.RAO.Crac;
                            optimizer = HiGHS.Optimizer, discrete::Bool = true,
                            max_iterations::Int = 10, pst_penalty::Real = 0.0, dc::Bool = true)
    cnecs = _cnec_data(crac)
    ras = _range_actions(crac, network)
    pst_ras = [ra for ra in ras if ra.kind == :pst]

    # Linearization / base set points. PSTs move over the SLP loop; injections linearize at 0.
    tap_of = Dict(ra.id => ra.current_tap for ra in pst_ras)
    base = Dict(ra.id => (ra.kind == :pst ? ra.angle_by_tap[ra.current_tap] : 0.0) for ra in ras)

    status = MOI.OPTIMIZE_NOT_CALLED
    points = Dict{String, Float64}()
    initial_flows = nothing
    iterations = 0
    for iter in 1:max_iterations
      iterations = iter
      for ra in pst_ras
        _apply_tap(network, ra.variable_id, tap_of[ra.id])
      end
      S, F = _sensitivities(network, cnecs, ras; dc = dc)
      iter == 1 && (initial_flows = copy(F))
      lin = Dict(ra.id => (ra.kind == :pst ? ra.angle_by_tap[tap_of[ra.id]] : 0.0) for ra in ras)
      taps, points, status = _solve_step(cnecs, ras, S, F, lin, base;
                                         discrete = discrete, pst_penalty = pst_penalty, optimizer = optimizer)
      converged = all(taps[ra.id] == tap_of[ra.id] for ra in pst_ras)
      for ra in pst_ras
        tap_of[ra.id] = taps[ra.id]
      end
      converged && break
    end

    # Final flows at the converged operating point: recomputed reference flows (with the PST
    # taps applied) plus the linear injection contribution.
    for ra in pst_ras
      _apply_tap(network, ra.variable_id, tap_of[ra.id])
    end
    S, F = _sensitivities(network, cnecs, ras; dc = dc)
    inj_ras = [ra for ra in ras if ra.kind == :injection]
    final_flows = [F[j] + sum(S[ra.id][j] * points[ra.id] for ra in inj_ras; init = 0.0) for j in eachindex(cnecs.cnec_ids)]
    for ra in pst_ras
      _apply_tap(network, ra.variable_id, ra.current_tap)   # restore: pure query
    end

    margins = Dict{String, Float64}()
    for (j, id) in enumerate(cnecs.cnec_ids)
      m = Inf
      haskey(cnecs.tmax, id) && (m = min(m, cnecs.tmax[id] - final_flows[j]))
      haskey(cnecs.tmin, id) && (m = min(m, final_flows[j] - cnecs.tmin[id]))
      margins[id] = m
    end
    min_margin, binding = _min_margin(cnecs.cnec_ids, final_flows, cnecs.tmin, cnecs.tmax)
    initial_min_margin, _ = _min_margin(cnecs.cnec_ids, initial_flows, cnecs.tmin, cnecs.tmax)

    solutions = [RangeActionSolution(ra.id, ra.kind, points[ra.id],
                                     ra.kind == :pst ? tap_of[ra.id] : nothing) for ra in ras]
    return Solution(solutions, min_margin, initial_min_margin, margins, binding, iterations, status)
  end

  """
      is_secure(solution) -> Bool

  Whether the optimized operating point is secure, i.e. every CNEC has a non-negative margin.
  """
  is_secure(solution::Solution) = solution.min_margin >= 0

  """
      apply!(network, crac, solution) -> network

  Deploy the optimized range actions of `solution` onto `network`: set each PST range action
  to its optimized tap. After this the network is at the optimized operating point (in
  contrast to [`solve_preventive`](@ref), which restores it).

  Only PST range actions are deployed; deploying injection/HVDC range actions (which shift
  set points rather than a discrete tap) is not yet supported.
  """
  function apply!(network::Powsybl.Network.NetworkHandle, crac::Powsybl.RAO.Crac, solution::Solution)
    psts = RAO.get_pst_range_actions(crac)
    pst_element = Dict(String(row.id) => String(row.network_element_id) for row in DataFrames.eachrow(psts))
    for ra in solution.range_actions
      ra.kind == :pst || error("PowsyblRao.apply!: deploying $(ra.kind) range actions is not yet supported")
      _apply_tap(network, pst_element[ra.id], ra.tap)
    end
    return network
  end
end

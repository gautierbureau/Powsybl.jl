# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

"""
    PowsyblRao

A native Julia remedial-action optimizer built on the Powsybl.jl APIs and JuMP.

It solves the **linear range-action problem** for a single preventive PST, mirroring the
inner "linear problem" of OpenRAO's SearchTreeRao: the flow of each flow CNEC — in its own
state (base case or post-contingency) — is linearized around the current operating point
using sensitivities, and the minimum margin over all CNECs is maximized over the PST tap.

Supported:
- **N-1**: post-contingency (outage / curative) flow CNECs, using per-contingency
  sensitivities and reference flows (the preventive PST affects every state);
- a **discrete-tap MILP** (the tap is chosen from actual tap positions) or continuous LP;
- an **SLP outer loop** that re-linearizes at the chosen tap and re-solves until it converges
  (matching OpenRAO's `max_mip_iterations`);
- an optional **RA-movement penalty**.
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
  Result of [`solve_preventive`](@ref).

  - `range_action_id` / `pst_id`: the optimized PST range action and its network element.
  - `optimized_angle` (degrees) / `optimized_tap`: the optimized phase-shift.
  - `min_margin` / `initial_min_margin`: optimized and pre-optimization minimum margins (MW),
    over all CNECs (each in its own state), from the actual recomputed flows.
  - `cnec_margins`: the per-CNEC margin (MW) at the optimum.
  - `binding_cnec`: the CNEC id achieving `min_margin` at the optimum.
  - `iterations`: number of SLP iterations run.
  - `termination`: the JuMP termination status of the last solve.
  """
  struct PreventiveResult
    range_action_id::String
    pst_id::String
    optimized_angle::Float64
    optimized_tap::Int
    min_margin::Float64
    initial_min_margin::Float64
    cnec_margins::Dict{String, Float64}
    binding_cnec::String
    iterations::Int
    termination::Any
  end

  _nearest_tap(angle_by_tap, angle, tap_min, tap_max) =
    argmin(t -> abs(angle_by_tap[t] - angle), [t for t in tap_min:tap_max if haskey(angle_by_tap, t)])

  # Minimum margin (MW) over all CNECs for a flow vector, and the binding CNEC id.
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

  # Extract the static problem data (CNECs + their states, thresholds, contingencies, PST,
  # tap<->angle) from the CRAC/network.
  function _extract(network, crac)
    flow_cnecs = RAO.get_flow_cnecs(crac)
    DataFrames.nrow(flow_cnecs) > 0 || error("PowsyblRao: no flow CNECs in the CRAC")
    cnec_ids = String.(flow_cnecs.id)
    branches = String.(flow_cnecs.network_element_id)
    cnec_states = String.(flow_cnecs.contingency_id)   # "" for preventive (base case)

    thresholds = RAO.get_thresholds(crac)
    tmin, tmax = Dict{String, Float64}(), Dict{String, Float64}()
    for row in DataFrames.eachrow(thresholds)
      String(row.unit) == "MEGAWATT" || error("PowsyblRao only supports MW thresholds, got $(row.unit)")
      tmin[String(row.id)] = row.min
      tmax[String(row.id)] = row.max
    end

    # Contingencies referenced by the post-contingency CNECs, and the elements they trip.
    contingencies = Dict{String, Vector{String}}()
    for row in DataFrames.eachrow(RAO.get_contingency_elements(crac))
      push!(get!(contingencies, String(row.id), String[]), String(row.network_element_id))
    end

    psts = RAO.get_pst_range_actions(crac)
    DataFrames.nrow(psts) == 1 ||
      error("PowsyblRao supports exactly one PST range action, got $(DataFrames.nrow(psts))")
    range_action_id = String(psts[1, :id])
    pst_id = String(psts[1, :network_element_id])

    ranges = RAO.get_range_action_ranges(crac)
    ra_ranges = ranges[String.(ranges.id) .== range_action_id, :]
    DataFrames.nrow(ra_ranges) >= 1 || error("PowsyblRao: no range for range action $range_action_id")
    tap_lo_crac = Int(round(minimum(ra_ranges.min)))
    tap_hi_crac = Int(round(maximum(ra_ranges.max)))

    steps = NET.get_phase_tap_changer_steps(network, true)
    pst_steps = steps[String.(steps.id) .== pst_id, :]
    DataFrames.nrow(pst_steps) > 0 || error("PowsyblRao: no phase tap changer steps for $pst_id")
    angle_by_tap = Dict{Int, Float64}(Int(r.position) => Float64(r.alpha) for r in DataFrames.eachrow(pst_steps))

    ptc = NET.get_phase_tap_changers(network, true)
    ptc_row = ptc[String.(ptc.id) .== pst_id, :]
    DataFrames.nrow(ptc_row) == 1 || error("PowsyblRao: phase tap changer $pst_id not found")
    current_tap = Int(ptc_row[1, :tap])
    tap_min = max(tap_lo_crac, Int(ptc_row[1, :low_tap]))
    tap_max = min(tap_hi_crac, Int(ptc_row[1, :high_tap]))
    valid_taps = [t for t in tap_min:tap_max if haskey(angle_by_tap, t)]
    tap_angles = [angle_by_tap[t] for t in valid_taps]

    return (; cnec_ids, branches, cnec_states, tmin, tmax, contingencies, range_action_id,
             pst_id, angle_by_tap, tap_min, tap_max, current_tap, valid_taps,
             angle_min = minimum(tap_angles), angle_max = maximum(tap_angles))
  end

  # Per-CNEC sensitivities of the flow to the PST phase angle and reference flows, each read
  # in the CNEC's own state (base case or post-contingency).
  function _state_sensitivities(network, data; dc::Bool)
    analysis = SEN.create()
    for (contingency_id, elements) in data.contingencies
      SEN.add_multiple_elements_contingency(analysis, elements, contingency_id)
    end
    SEN.add_factor_matrix(analysis, data.branches, [data.pst_id]; sensitivity_variable_type = SEN.TRANSFORMER_PHASE)
    result = dc ? SEN.run_dc(analysis, network) : SEN.run_ac(analysis, network)

    states = unique(data.cnec_states)
    smat = Dict(s => SEN.get_sensitivity_matrix(result, "default", s) for s in states)
    fmat = Dict(s => SEN.get_reference_matrix(result, "default", s) for s in states)
    S = [smat[data.cnec_states[j]][1, j] for j in eachindex(data.cnec_ids)]
    F = [fmat[data.cnec_states[j]][1, j] for j in eachindex(data.cnec_ids)]
    return S, F
  end

  _apply_tap(network, pst_id, tap) = NET.update_elements(network, LIB.PHASE_TAP_CHANGER; id = pst_id, tap = tap)

  # One optimization step: choose the tap (MILP) or angle (LP) that maximizes the minimum
  # margin (minus an optional movement penalty), linearizing each CNEC's flow around `angle_lin`.
  function _solve_step(data, S, F, angle_lin, angle_orig; discrete, pst_penalty, optimizer)
    model = Model(optimizer)
    set_silent(model)
    @variable(model, min_margin)
    if discrete
      @variable(model, z[data.valid_taps], Bin)
      @constraint(model, sum(z[t] for t in data.valid_taps) == 1)
      angle = @expression(model, sum(data.angle_by_tap[t] * z[t] for t in data.valid_taps))
    else
      @variable(model, data.angle_min <= a <= data.angle_max)
      angle = a
    end
    for j in eachindex(data.cnec_ids)
      flow = F[j] + S[j] * (angle - angle_lin)
      id = data.cnec_ids[j]
      haskey(data.tmax, id) && @constraint(model, min_margin <= data.tmax[id] - flow)
      haskey(data.tmin, id) && @constraint(model, min_margin <= flow - data.tmin[id])
    end
    if pst_penalty > 0
      @variable(model, movement >= 0)
      @constraint(model, movement >= angle - angle_orig)
      @constraint(model, movement >= angle_orig - angle)
      @objective(model, Max, min_margin - pst_penalty * movement)
    else
      @objective(model, Max, min_margin)
    end
    optimize!(model)
    chosen_tap = discrete ?
      data.valid_taps[argmax([value(z[t]) for t in data.valid_taps])] :
      _nearest_tap(data.angle_by_tap, value(angle), data.tap_min, data.tap_max)
    return chosen_tap, termination_status(model)
  end

  """
      solve_preventive(network, crac; optimizer = HiGHS.Optimizer, discrete = true,
                       max_iterations = 10, pst_penalty = 0.0, dc = true) -> PreventiveResult

  Optimize the preventive PST tap of `crac` on `network` to maximize the minimum margin over
  all flow CNECs, each evaluated in its own state (base case for preventive CNECs,
  post-contingency for outage/curative CNECs).

  - `discrete = true` chooses an actual tap position (MILP); `false` optimizes the continuous
    angle (LP) and rounds to the nearest tap.
  - `max_iterations` bounds the SLP outer loop that re-linearizes at the chosen tap.
  - `pst_penalty` (MW per degree) penalizes the PST movement from its initial position.
  - `dc` selects DC (default) or AC sensitivities / reference flows.

  The network's tap is restored before returning (pure query). Reported margins come from the
  actual recomputed flows at the relevant taps.

  Scope: one preventive PST range action, flow CNECs with MW thresholds.
  """
  function solve_preventive(network::Powsybl.Network.NetworkHandle, crac::Powsybl.RAO.Crac;
                            optimizer = HiGHS.Optimizer, discrete::Bool = true,
                            max_iterations::Int = 10, pst_penalty::Real = 0.0, dc::Bool = true)
    data = _extract(network, crac)
    original_tap = data.current_tap
    angle_orig = data.angle_by_tap[original_tap]

    tap = original_tap
    result_tap = original_tap
    status = MOI.OPTIMIZE_NOT_CALLED
    initial_flows = nothing
    iterations = 0
    for iter in 1:max_iterations
      iterations = iter
      _apply_tap(network, data.pst_id, tap)
      S, F = _state_sensitivities(network, data; dc = dc)
      iter == 1 && (initial_flows = copy(F))
      new_tap, status = _solve_step(data, S, F, data.angle_by_tap[tap], angle_orig;
                                    discrete = discrete, pst_penalty = pst_penalty, optimizer = optimizer)
      result_tap = new_tap
      new_tap == tap && break   # SLP fixed point
      tap = new_tap
    end

    # True margins at the converged tap, from the actual recomputed (per-state) flows.
    _apply_tap(network, data.pst_id, result_tap)
    _, final_flows = _state_sensitivities(network, data; dc = dc)
    margins = Dict{String, Float64}()
    for (j, id) in enumerate(data.cnec_ids)
      m = Inf
      haskey(data.tmax, id) && (m = min(m, data.tmax[id] - final_flows[j]))
      haskey(data.tmin, id) && (m = min(m, final_flows[j] - data.tmin[id]))
      margins[id] = m
    end

    _apply_tap(network, data.pst_id, original_tap)   # restore: pure query

    min_margin, binding = _min_margin(data.cnec_ids, final_flows, data.tmin, data.tmax)
    initial_min_margin, _ = _min_margin(data.cnec_ids, initial_flows, data.tmin, data.tmax)
    return PreventiveResult(data.range_action_id, data.pst_id, data.angle_by_tap[result_tap],
                            result_tap, min_margin, initial_min_margin, margins, binding,
                            iterations, status)
  end
end

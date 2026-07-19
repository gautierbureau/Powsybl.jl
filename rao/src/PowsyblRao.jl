# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

"""
    PowsyblRao

A native Julia remedial-action optimizer built on the Powsybl.jl APIs and JuMP.

It solves the **preventive linear range-action problem** for a single PST, mirroring the
inner "linear problem" of OpenRAO's SearchTreeRao: the flow of each preventive flow CNEC is
linearized around the current operating point using sensitivities, and the minimum margin is
maximized over the PST tap.

Two refinements over a single continuous solve are supported:
- a **discrete-tap MILP** (the tap is chosen from the actual tap positions), and
- a **sequential linear programming (SLP)** outer loop that re-linearizes at the chosen tap
  and re-solves until the tap converges (matching OpenRAO's `max_mip_iterations`; with an AC
  reference this refines the linear approximation, in DC it converges immediately).

An optional RA-movement penalty discourages moving the PST when it barely helps.
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
    evaluated from the actual (recomputed) flows at the corresponding taps.
  - `cnec_margins`: the per-CNEC margin (MW) at the optimum.
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
    iterations::Int
    termination::Any
  end

  # Nearest tap to a target angle within the allowed tap range.
  function _nearest_tap(angle_by_tap::Dict{Int, Float64}, angle::Real, tap_min::Int, tap_max::Int)
    best_tap, best_dist = tap_min, Inf
    for t in tap_min:tap_max
      haskey(angle_by_tap, t) || continue
      dist = abs(angle_by_tap[t] - angle)
      dist < best_dist && ((best_tap, best_dist) = (t, dist))
    end
    return best_tap
  end

  # Minimum margin (MW) over all CNECs for a flow vector, given per-CNEC thresholds.
  function _min_margin(cnec_ids, flows, tmin, tmax)
    mm = Inf
    for (j, id) in enumerate(cnec_ids)
      haskey(tmax, id) && (mm = min(mm, tmax[id] - flows[j]))
      haskey(tmin, id) && (mm = min(mm, flows[j] - tmin[id]))
    end
    return mm
  end

  # Extract the static problem data (CNECs, thresholds, PST, tap<->angle) from the CRAC/network.
  function _extract(network, crac)
    flow_cnecs = RAO.get_flow_cnecs(crac)
    preventive = flow_cnecs[flow_cnecs.instant .== "preventive", :]
    DataFrames.nrow(preventive) > 0 || error("PowsyblRao: no preventive flow CNECs in the CRAC")
    cnec_ids = String.(preventive.id)
    branches = String.(preventive.network_element_id)

    thresholds = RAO.get_thresholds(crac)
    tmin, tmax = Dict{String, Float64}(), Dict{String, Float64}()
    for row in DataFrames.eachrow(thresholds)
      String(row.unit) == "MEGAWATT" || error("PowsyblRao MVP only supports MW thresholds, got $(row.unit)")
      tmin[String(row.id)] = row.min
      tmax[String(row.id)] = row.max
    end

    psts = RAO.get_pst_range_actions(crac)
    DataFrames.nrow(psts) == 1 ||
      error("PowsyblRao MVP supports exactly one PST range action, got $(DataFrames.nrow(psts))")
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

    return (; cnec_ids, branches, tmin, tmax, range_action_id, pst_id,
             angle_by_tap, tap_min, tap_max, current_tap, valid_taps,
             angle_min = minimum(tap_angles), angle_max = maximum(tap_angles))
  end

  # DC (or AC) sensitivities of the CNEC flows to the PST phase angle, plus reference flows.
  function _sensitivity(network, branches, pst_id; dc::Bool)
    analysis = SEN.create()
    SEN.add_factor_matrix(analysis, branches, [pst_id]; sensitivity_variable_type = SEN.TRANSFORMER_PHASE)
    result = dc ? SEN.run_dc(analysis, network) : SEN.run_ac(analysis, network)
    return SEN.get_sensitivity_matrix(result), SEN.get_reference_matrix(result)
  end

  _apply_tap(network, pst_id, tap) = NET.update_elements(network, LIB.PHASE_TAP_CHANGER; id = pst_id, tap = tap)

  # One optimization step: choose the tap (MILP) or angle (LP) that maximizes the minimum
  # margin (minus an optional movement penalty), linearizing flows around `angle_lin`.
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
      flow = F[1, j] + S[1, j] * (angle - angle_lin)
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

  Optimize the preventive PST tap of `crac` on `network` to maximize the minimum margin of
  the preventive flow CNECs.

  - `discrete = true` chooses an actual tap position (MILP); `false` optimizes the continuous
    angle (LP) and rounds to the nearest tap.
  - `max_iterations` bounds the SLP outer loop that re-linearizes at the chosen tap and
    re-solves until the tap converges.
  - `pst_penalty` (MW per degree) penalizes the PST movement from its initial position.
  - `dc` selects DC (default) or AC sensitivities / reference flows.

  The network's tap is restored to its initial value before returning, so this is a pure
  query. Reported margins are evaluated from the actual recomputed flows at the relevant taps.

  MVP scope: exactly one PST range action, preventive flow CNECs, MW thresholds.
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
      S, F = _sensitivity(network, data.branches, data.pst_id; dc = dc)
      iter == 1 && (initial_flows = [F[1, j] for j in eachindex(data.cnec_ids)])
      new_tap, status = _solve_step(data, S, F, data.angle_by_tap[tap], angle_orig;
                                    discrete = discrete, pst_penalty = pst_penalty, optimizer = optimizer)
      result_tap = new_tap
      new_tap == tap && break   # SLP fixed point
      tap = new_tap
    end

    # True margins at the converged tap, from the actual recomputed flows.
    _apply_tap(network, data.pst_id, result_tap)
    _, Ff = _sensitivity(network, data.branches, data.pst_id; dc = dc)
    final_flows = [Ff[1, j] for j in eachindex(data.cnec_ids)]
    margins = Dict{String, Float64}()
    for (j, id) in enumerate(data.cnec_ids)
      m = Inf
      haskey(data.tmax, id) && (m = min(m, data.tmax[id] - final_flows[j]))
      haskey(data.tmin, id) && (m = min(m, final_flows[j] - data.tmin[id]))
      margins[id] = m
    end

    _apply_tap(network, data.pst_id, original_tap)   # restore: pure query

    return PreventiveResult(data.range_action_id, data.pst_id, data.angle_by_tap[result_tap],
                            result_tap, _min_margin(data.cnec_ids, final_flows, data.tmin, data.tmax),
                            _min_margin(data.cnec_ids, initial_flows, data.tmin, data.tmax),
                            margins, iterations, status)
  end
end

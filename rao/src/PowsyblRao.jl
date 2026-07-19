# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

"""
    PowsyblRao

A native Julia remedial-action optimizer built on the Powsybl.jl APIs and JuMP.

This first milestone solves the **preventive linear range-action problem** for a single PST:
it linearizes the flow of each preventive flow CNEC around the base case using DC
sensitivities, and maximizes the minimum margin over one PST phase-shift angle with a linear
program. It mirrors the inner "linear problem" of OpenRAO's SearchTreeRao.
"""
module PowsyblRao
  using Powsybl
  using JuMP
  using HiGHS
  import DataFrames

  const RAO = Powsybl.RAO
  const NET = Powsybl.Network
  const SEN = Powsybl.SensitivityAnalysis

  """
  Result of [`solve_preventive`](@ref).

  - `range_action_id` / `pst_id`: the optimized PST range action and its network element.
  - `optimized_angle`: the optimized phase-shift angle (degrees).
  - `optimized_tap`: the nearest tap position to `optimized_angle`.
  - `min_margin` / `initial_min_margin`: the optimized and pre-optimization minimum margins (MW).
  - `cnec_margins`: the per-CNEC margin (MW) at the optimum.
  - `termination`: the JuMP termination status.
  """
  struct PreventiveResult
    range_action_id::String
    pst_id::String
    optimized_angle::Float64
    optimized_tap::Int
    min_margin::Float64
    initial_min_margin::Float64
    cnec_margins::Dict{String, Float64}
    termination::Any
  end

  # Nearest tap to a target angle within [tap_min, tap_max].
  function _nearest_tap(angle_by_tap::Dict{Int, Float64}, angle::Real, tap_min::Int, tap_max::Int)
    best_tap = tap_min
    best_dist = Inf
    for t in tap_min:tap_max
      haskey(angle_by_tap, t) || continue
      dist = abs(angle_by_tap[t] - angle)
      if dist < best_dist
        best_dist = dist
        best_tap = t
      end
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

  """
      solve_preventive(network, crac; optimizer = HiGHS.Optimizer) -> PreventiveResult

  Optimize the preventive PST tap of `crac` on `network` to maximize the minimum margin of
  the preventive flow CNECs, using DC sensitivities and a JuMP linear program.

  MVP scope: exactly one PST range action and the preventive (base-case) flow CNECs, with
  thresholds expressed in MW. Contingencies, discrete-tap MILP, SLP iteration and other
  range-action / objective types are out of scope for this milestone.
  """
  function solve_preventive(network::Powsybl.Network.NetworkHandle, crac::Powsybl.RAO.Crac;
                            optimizer = HiGHS.Optimizer)
    # --- Preventive flow CNECs and their thresholds ---
    flow_cnecs = RAO.get_flow_cnecs(crac)
    preventive = flow_cnecs[flow_cnecs.instant .== "preventive", :]
    DataFrames.nrow(preventive) > 0 || error("PowsyblRao: no preventive flow CNECs in the CRAC")
    cnec_ids = String.(preventive.id)
    branches = String.(preventive.network_element_id)

    thresholds = RAO.get_thresholds(crac)
    tmin = Dict{String, Float64}()
    tmax = Dict{String, Float64}()
    for row in DataFrames.eachrow(thresholds)
      String(row.unit) == "MEGAWATT" || error("PowsyblRao MVP only supports MW thresholds, got $(row.unit)")
      tmin[String(row.id)] = row.min
      tmax[String(row.id)] = row.max
    end

    # --- The (single) PST range action and its tap range ---
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

    # --- Tap <-> angle mapping from the network ---
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

    angle0 = angle_by_tap[current_tap]
    tap_angles = [angle_by_tap[t] for t in tap_min:tap_max if haskey(angle_by_tap, t)]
    angle_min, angle_max = minimum(tap_angles), maximum(tap_angles)

    # --- DC sensitivities of CNEC flows to the PST phase angle ---
    analysis = SEN.create()
    SEN.add_factor_matrix(analysis, branches, [pst_id]; sensitivity_variable_type = SEN.TRANSFORMER_PHASE)
    sresult = SEN.run_dc(analysis, network)
    S = SEN.get_sensitivity_matrix(sresult)   # (1, n_cnec): d(flow)/d(angle)
    F = SEN.get_reference_matrix(sresult)     # (1, n_cnec): base-case flow

    # --- JuMP linear program: maximize the minimum margin ---
    model = Model(optimizer)
    set_silent(model)
    @variable(model, angle_min <= angle <= angle_max)
    @variable(model, min_margin)
    for j in eachindex(cnec_ids)
      flow = F[1, j] + S[1, j] * (angle - angle0)
      id = cnec_ids[j]
      haskey(tmax, id) && @constraint(model, min_margin <= tmax[id] - flow)
      haskey(tmin, id) && @constraint(model, min_margin <= flow - tmin[id])
    end
    @objective(model, Max, min_margin)
    optimize!(model)

    opt_angle = value(angle)
    opt_tap = _nearest_tap(angle_by_tap, opt_angle, tap_min, tap_max)

    opt_flows = [F[1, j] + S[1, j] * (opt_angle - angle0) for j in eachindex(cnec_ids)]
    init_flows = [F[1, j] for j in eachindex(cnec_ids)]
    margins = Dict{String, Float64}()
    for (j, id) in enumerate(cnec_ids)
      m = Inf
      haskey(tmax, id) && (m = min(m, tmax[id] - opt_flows[j]))
      haskey(tmin, id) && (m = min(m, opt_flows[j] - tmin[id]))
      margins[id] = m
    end

    return PreventiveResult(range_action_id, pst_id, opt_angle, opt_tap,
                            value(min_margin), _min_margin(cnec_ids, init_flows, tmin, tmax),
                            margins, termination_status(model))
  end
end

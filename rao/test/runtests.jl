# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

using PowsyblRao
using Powsybl
using Test

Powsybl.LibPowsybl.set_config_read(false)

const RAO = Powsybl.RAO

# The RAO fixtures live in the parent package's test data.
const DATA = joinpath(@__DIR__, "..", "..", "test", "data", "rao")

@testset "Preventive PST linear RAO vs OpenRAO" begin
  network = Powsybl.Network.load(joinpath(DATA, "rao_network.uct"))
  crac = RAO.load_crac(network, joinpath(DATA, "rao_crac.json"))

  result = PowsyblRao.solve_preventive(network, crac)

  # solve_preventive is a pure query: the network tap is restored (checked before OpenRAO's
  # run below, which does apply the optimized action to the network)
  ptc0 = Powsybl.Network.get_phase_tap_changers(network, true)
  @test ptc0[ptc0.id .== result.pst_id, :tap][1] == 0

  # The LP is solved to optimality
  @test string(result.termination) == "OPTIMAL"
  @test result.range_action_id == "PRA_PST_BE"
  @test result.pst_id == "BBE2AA1  BBE3AA1  1"

  # Optimizing improves (or preserves) the minimum margin over the base case
  @test result.min_margin >= result.initial_min_margin - 1e-6
  # Initial min margin is the FR1-FR2 CNEC at ±4000 MW: 4000 - 1333.33
  @test result.initial_min_margin ≈ 2666.67 atol = 0.5

  # Cross-check against OpenRAO's SearchTreeRao on the same fixture
  rao = RAO.create()
  glsk = RAO.load_glsk(joinpath(DATA, "rao_glsk.xml"))
  RAO.set_loopflow_glsk(rao, glsk)
  openrao = RAO.run(rao, network, crac; parameters_file = joinpath(DATA, "rao_parameters.json"))
  @test RAO.get_status(openrao) == RAO.DEFAULT

  # Same optimized tap as OpenRAO
  open_pst = RAO.get_pst_range_action_results(openrao)
  @test result.optimized_tap == open_pst[1, "optimized_tap"]

  # Same optimized minimum margin: OpenRAO's preventive functional cost is -min_margin
  cost = RAO.get_cost_results(openrao)
  preventive_cost = cost[cost.optimized_instant .== "preventive", "functional_cost"][1]
  @test result.min_margin ≈ -preventive_cost atol = 1.0

  # The SLP loop converges (DC model is exact, so a single iteration reaches the fixed point)
  @test result.iterations >= 1
end

@testset "Discrete MILP, continuous LP and penalty" begin
  network = Powsybl.Network.load(joinpath(DATA, "rao_network.uct"))
  crac = RAO.load_crac(network, joinpath(DATA, "rao_crac.json"))

  # Discrete MILP and continuous-then-rounded LP agree here (optimum sits on a tap)
  milp = PowsyblRao.solve_preventive(network, crac; discrete = true)
  lp = PowsyblRao.solve_preventive(network, crac; discrete = false)
  @test milp.optimized_tap == -16
  @test lp.optimized_tap == -16
  @test milp.min_margin ≈ lp.min_margin atol = 1e-6

  # A large movement penalty makes moving the PST not worth it: stay at the initial tap
  penalized = PowsyblRao.solve_preventive(network, crac; pst_penalty = 1.0e6)
  @test penalized.optimized_tap == 0
  @test penalized.min_margin ≈ penalized.initial_min_margin atol = 1e-6
end

@testset "N-1 post-contingency CNECs" begin
  network = Powsybl.Network.load(joinpath(DATA, "rao_network.uct"))
  crac = RAO.load_crac(network, joinpath(DATA, "N-1_case_crac_curative.json"))

  result = PowsyblRao.solve_preventive(network, crac)

  # This CRAC monitors 3 CNECs across states (preventive / outage / curative)
  @test length(result.cnec_margins) == 3

  # The CNECs are overloaded, so the minimum margin is negative; optimizing improves it
  @test result.initial_min_margin < 0
  @test result.min_margin > result.initial_min_margin

  # The binding CNEC is a post-contingency one — N-1 is what drives the decision here
  @test occursin("Contingency", result.binding_cnec)

  # Reported minimum margin is self-consistent with the per-CNEC margins
  @test result.min_margin ≈ minimum(values(result.cnec_margins)) atol = 1e-6

  # Same tap decision as OpenRAO (which runs AC + a search tree on this case)
  rao = RAO.create()
  openrao = RAO.run(rao, network, crac; parameters_file = joinpath(DATA, "rao_parameters_with_curative.json"))
  @test RAO.get_status(openrao) == RAO.DEFAULT
  open_pst = RAO.get_pst_range_action_results(openrao)
  @test result.optimized_tap == open_pst[1, "optimized_tap"]
end

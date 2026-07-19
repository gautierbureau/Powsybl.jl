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
end

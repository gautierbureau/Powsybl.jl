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
const DATA = joinpath(@__DIR__, "..", "..", "test", "data", "rao")

@testset "Preventive PST linear RAO vs OpenRAO" begin
  network = Powsybl.Network.load(joinpath(DATA, "rao_network.uct"))
  crac = RAO.load_crac(network, joinpath(DATA, "rao_crac.json"))

  result = PowsyblRao.solve_preventive(network, crac)
  pst = PowsyblRao.range_action(result, "PRA_PST_BE")

  # solve_preventive is a pure query: the network tap is restored (checked before OpenRAO's
  # run below, which does apply the optimized action to the network)
  ptc0 = Powsybl.Network.get_phase_tap_changers(network, true)
  @test ptc0[ptc0.id .== "BBE2AA1  BBE3AA1  1", :tap][1] == 0

  @test string(result.termination) == "OPTIMAL"
  @test pst.kind == :pst
  @test result.min_margin >= result.initial_min_margin - 1e-6
  @test result.initial_min_margin ≈ 2666.67 atol = 0.5

  # Cross-check against OpenRAO's SearchTreeRao on the same fixture
  rao = RAO.create()
  glsk = RAO.load_glsk(joinpath(DATA, "rao_glsk.xml"))
  RAO.set_loopflow_glsk(rao, glsk)
  openrao = RAO.run(rao, network, crac; parameters_file = joinpath(DATA, "rao_parameters.json"))
  @test RAO.get_status(openrao) == RAO.DEFAULT

  open_pst = RAO.get_pst_range_action_results(openrao)
  @test pst.tap == open_pst[1, "optimized_tap"]

  cost = RAO.get_cost_results(openrao)
  preventive_cost = cost[cost.optimized_instant .== "preventive", "functional_cost"][1]
  @test result.min_margin ≈ -preventive_cost atol = 1.0
  @test result.iterations >= 1
end

@testset "Discrete MILP, continuous LP and penalty" begin
  network = Powsybl.Network.load(joinpath(DATA, "rao_network.uct"))
  crac = RAO.load_crac(network, joinpath(DATA, "rao_crac.json"))

  milp = PowsyblRao.solve_preventive(network, crac; discrete = true)
  lp = PowsyblRao.solve_preventive(network, crac; discrete = false)
  @test PowsyblRao.range_action(milp, "PRA_PST_BE").tap == -16
  @test PowsyblRao.range_action(lp, "PRA_PST_BE").tap == -16
  @test milp.min_margin ≈ lp.min_margin atol = 1e-6

  penalized = PowsyblRao.solve_preventive(network, crac; pst_penalty = 1.0e6)
  @test PowsyblRao.range_action(penalized, "PRA_PST_BE").tap == 0
  @test penalized.min_margin ≈ penalized.initial_min_margin atol = 1e-6
end

@testset "N-1 post-contingency CNECs" begin
  network = Powsybl.Network.load(joinpath(DATA, "rao_network.uct"))
  crac = RAO.load_crac(network, joinpath(DATA, "N-1_case_crac_curative.json"))

  result = PowsyblRao.solve_preventive(network, crac)

  @test length(result.cnec_margins) == 3
  @test result.initial_min_margin < 0
  @test result.min_margin > result.initial_min_margin
  @test occursin("Contingency", result.binding_cnec)
  @test result.min_margin ≈ minimum(values(result.cnec_margins)) atol = 1e-6

  rao = RAO.create()
  openrao = RAO.run(rao, network, crac; parameters_file = joinpath(DATA, "rao_parameters_with_curative.json"))
  @test RAO.get_status(openrao) == RAO.DEFAULT
  open_pst = RAO.get_pst_range_action_results(openrao)
  @test PowsyblRao.range_action(result, "pst-range-action").tap == open_pst[1, "optimized_tap"]
end

@testset "Deploy optimized solution to the network" begin
  network = Powsybl.Network.load(joinpath(DATA, "rao_network.uct"))
  crac = RAO.load_crac(network, joinpath(DATA, "rao_crac.json"))

  result = PowsyblRao.solve_preventive(network, crac)
  @test PowsyblRao.is_secure(result)   # optimized margin is positive on this fixture

  # Deploy the plan; the network is now at the optimized tap
  PowsyblRao.apply!(network, crac, result)
  ptc = Powsybl.Network.get_phase_tap_changers(network, true)
  @test ptc[ptc.id .== "BBE2AA1  BBE3AA1  1", :tap][1] == PowsyblRao.range_action(result, "PRA_PST_BE").tap

  # The deployed network actually achieves the predicted minimum margin: re-solving now sees
  # the deployed tap as its initial state, whose margin must equal the earlier optimum.
  redo = PowsyblRao.solve_preventive(network, crac)
  @test redo.initial_min_margin ≈ result.min_margin atol = 1.0
end

@testset "Inter-temporal (Marmot-style) ramp coupling" begin
  LIB = Powsybl.LibPowsybl
  crac_path = joinpath(DATA, "rao_crac.json")

  base = Powsybl.Network.load(joinpath(DATA, "rao_network.uct"))
  crac = RAO.load_crac(base, crac_path)

  # A second timestamp: a strong France -> Germany generation shift, which moves the optimal
  # PST tap far from the base case.
  shifted = Powsybl.Network.load(joinpath(DATA, "rao_network.uct"))
  Powsybl.Network.update_elements(shifted, LIB.GENERATOR;
    id = ["FFR1AA1 _generator", "FFR2AA1 _generator", "FFR3AA1 _generator"], target_p = [0.0, 0.0, 0.0])
  Powsybl.Network.update_elements(shifted, LIB.GENERATOR;
    id = ["DDE1AA1 _generator", "DDE2AA1 _generator", "DDE3AA1 _generator"], target_p = [4500.0, 4000.0, 4500.0])
  networks = [base, shifted]

  # Independent per-timestamp optima — the two timestamps genuinely want different taps
  o1 = PowsyblRao.solve_preventive(base, crac)
  o2 = PowsyblRao.solve_preventive(shifted, RAO.load_crac(shifted, crac_path))
  tap1 = PowsyblRao.range_action(o1, "PRA_PST_BE").tap
  tap2 = PowsyblRao.range_action(o2, "PRA_PST_BE").tap
  @test tap1 != tap2

  pst(sol, t) = PowsyblRao.range_action(sol.range_actions[t], "PRA_PST_BE")

  # Loose ramp: the timestamps decouple, so the global optimum is the worse of the two
  # independent optima (whichever timestamp is binding reaches its own optimum).
  loose = PowsyblRao.solve_intertemporal(networks, crac; gradient = 20.0)
  @test string(loose.termination) == "OPTIMAL"
  @test loose.min_margin ≈ min(o1.min_margin, o2.min_margin) atol = 1.0

  # Rigid ramp (gradient 0): the tap is forced identical across timestamps, even though the
  # two timestamps independently want different taps. Coupling can only reduce (or tie) the
  # achievable global minimum margin.
  rigid = PowsyblRao.solve_intertemporal(networks, crac; gradient = 0.0)
  @test pst(rigid, 1).tap == pst(rigid, 2).tap
  @test rigid.min_margin <= loose.min_margin + 1e-6

  # A tight but non-zero ramp respects the gradient on the phase-shift angle and sits between
  # the rigid and loose regimes.
  tight = PowsyblRao.solve_intertemporal(networks, crac; gradient = 1.0)
  @test abs(pst(tight, 1).set_point - pst(tight, 2).set_point) <= 1.0 + 1e-6
  @test rigid.min_margin - 1e-6 <= tight.min_margin <= loose.min_margin + 1e-6
end

@testset "Injection (redispatching) range action vs OpenRAO" begin
  network = Powsybl.Network.load(joinpath(DATA, "2nodes.uct"))
  crac = RAO.load_crac(network, joinpath(DATA, "crac-simple-rd-mw.json"))

  result = PowsyblRao.solve_preventive(network, crac)
  rd = PowsyblRao.range_action(result, "redispatching")

  # The redispatch is a continuous injection set point (not a tap)
  @test rd.kind == :injection
  @test rd.tap === nothing

  # The monitored branch is overloaded and redispatching (BE gen up / FR load down) would
  # only push more power onto it, so the optimum is not to redispatch.
  @test rd.set_point ≈ 0.0 atol = 1e-3
  @test result.min_margin < 0   # the overload cannot be relieved by this range action

  # Same decision as OpenRAO
  rao = RAO.create()
  openrao = RAO.run(rao, network, crac; parameters_file = joinpath(DATA, "rao-parameters-min-margin-mw.json"))
  @test RAO.get_status(openrao) == RAO.DEFAULT
  rar = RAO.get_range_action_results(openrao)
  open_sp = rar[rar.remedial_action_id .== "redispatching", "optimized_set_point"][1]
  @test rd.set_point ≈ open_sp atol = 1e-3
end

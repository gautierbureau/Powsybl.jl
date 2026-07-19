# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

using Powsybl
using Test

# To avoid reading potential user specific configuration
Powsybl.LibPowsybl.set_config_read(false)

@testset "Test network data" begin
  network = Powsybl.Network.create_ieee9()

  @test network.id == "ieee9cdf"
  @test network.name == "ieee9cdf"
  @test network.source_format == "IEEE-CDF"
  @test network.forecast_distance == 0
  @test network.case_date ≈ 1.240704e9

  lines = Powsybl.Network.get_lines(network)
  @test names(lines) == ["id", "name", "r", "x", "g1", "b1", "g2", "b2", "p1", "q1", "i1", "p2", "q2",
   "i2", "voltage_level1_id", "voltage_level2_id", "bus1_id", "bus2_id", "connected1", "connected2"]

  @test lines[:, "id"] == ["L7-8-0", "L9-8-0", "L7-5-0", "L9-6-0", "L5-4-0", "L6-4-0"]
  @test lines[:, "bus1_id"] == ["VL2_1", "VL3_1", "VL2_1", "VL3_1", "VL5_0", "VL6_0"]
end

@testset "Test network save and load" begin
  network = Powsybl.Network.load("simple-eu.xiidm")
  @test network.name == "simple-eu"

  Powsybl.Network.save(network, "simple-eu.mat", "MATPOWER")
  network_matpower = Powsybl.Network.load("simple-eu.mat")
  @test network_matpower.name == "simple-eu"

  Powsybl.Network.save(network, "simple-eu.zip", "CGMES")
  network_cgmes = Powsybl.Network.load("simple-eu.zip")
  @test network_cgmes.name == "urn:uuid:simple-eu_N_EQUIPMENT_2024-09-25T12:47:58Z_1_1D__FM"
end

@testset "Test load flow parameters" begin
  parameters = Powsybl.LoadFlow.load_flow_parameters()
  @test parameters.voltage_init_mode == Powsybl.LoadFlow.UNIFORM_VALUES
  @test parameters.transformer_voltage_control_on == false
  @test parameters.use_reactive_limits == true
  @test parameters.phase_shifter_regulation_on == false
  @test parameters.twt_split_shunt_admittance == false
  @test parameters.shunt_compensator_voltage_control_on == false
  @test parameters.read_slack_bus == true
  @test parameters.write_slack_bus == true
  @test parameters.distributed_slack == true
  @test parameters.balance_type == Powsybl.LoadFlow.PROPORTIONAL_TO_GENERATION_P_MAX
  @test parameters.dc_use_transformer_ratio == true
  @test parameters.countries_to_balance == []
  @test parameters.component_mode == Powsybl.LoadFlow.MAIN_CONNECTED
  @test parameters.dc_power_factor == 1.0
  @test parameters.provider_parameters == Dict{String, String}()
end

@testset "Test AC load flow" begin
  network = Powsybl.Network.create_ieee9()
  parameters = Powsybl.LoadFlow.load_flow_parameters()
  result = Powsybl.LoadFlow.run_ac(network, parameters)

  component_res = result.component_results[1, :]
  @test component_res.connected_component_num == 0
  @test component_res.synchronous_component_num == 0
  @test component_res.status == Powsybl.LoadFlow.CONVERGED
  @test component_res.status_text == "Converged"
  @test component_res.iteration_count == 3
  @test component_res.reference_bus_id == "VL1_0"
  @test component_res.distributed_active_power == 0.0

  slackbus_res = result.slack_bus_results[1, :]
  @test slackbus_res.connected_component_num == 0
  @test slackbus_res.synchronous_component_num == 0
  @test slackbus_res.id == "VL1_0"
  @test isapprox(slackbus_res.active_power_mismatch, -4.324e-6; atol = 1e-3)
end

@testset "Test DC load flow" begin
  network = Powsybl.Network.create_ieee9()
  parameters = Powsybl.LoadFlow.load_flow_parameters()
  result = Powsybl.LoadFlow.run_dc(network, parameters)
  @test size(result.component_results, 1) == 1
end
@testset "Test RAO (remedial action optimisation)" begin
  RAO = Powsybl.RAO
  network = Powsybl.Network.load("data/rao/rao_network.uct")

  rao = RAO.create()
  crac = RAO.load_crac(network, "data/rao/rao_crac.json")
  glsk = RAO.load_glsk("data/rao/rao_glsk.xml")
  # This CRAC enables loop-flow computation, which needs a GLSK
  RAO.set_loopflow_glsk(rao, glsk)

  result = RAO.run(rao, network, crac; parameters_file = "data/rao/rao_parameters.json")

  # The optimisation succeeds
  @test RAO.get_status(result) == RAO.DEFAULT

  # A PST range action was optimised (this CRAC is a PST parade)
  pst = RAO.get_pst_range_action_results(result)
  @test "optimized_tap" in names(pst)
  @test size(pst, 1) >= 1

  # Cost results are reported per optimized instant, including the initial state
  cost = RAO.get_cost_results(result)
  @test names(cost) == ["optimized_instant", "functional_cost", "virtual_cost", "cost"]
  @test "initial" in cost[:, "optimized_instant"]

  # The other result accessors return tabular data without throwing
  @test size(RAO.get_flow_cnec_results(result), 2) >= 0
  @test size(RAO.get_range_action_results(result), 2) >= 0
  @test size(RAO.get_network_action_results(result), 2) >= 0

  # Virtual costs are reported per named contributor, one column of values per instant
  vc_names = RAO.get_virtual_cost_names(result)
  @test vc_names isa Vector{String}
  @test "loop-flow-cost" in vc_names
  loop_flow = RAO.get_virtual_cost_results(result, "loop-flow-cost")
  @test names(loop_flow) == ["optimized_instant", "loop-flow-cost"]
  @test "initial" in loop_flow[:, "optimized_instant"]
end

@testset "Test CRAC introspection" begin
  RAO = Powsybl.RAO
  network = Powsybl.Network.load("data/rao/rao_network.uct")
  crac = RAO.load_crac(network, "data/rao/rao_crac.json")

  # Contingencies and the elements they trip
  contingencies = RAO.get_contingencies(crac)
  @test "id" in names(contingencies)
  @test size(contingencies, 1) == 1
  @test "network_element_id" in names(RAO.get_contingency_elements(crac))

  # Instants (preventive / outage / auto / curative)
  instants = RAO.get_instants(crac)
  @test names(instants) == ["id", "kind", "order"]
  @test size(instants, 1) == 4

  # Flow CNECs are the substance of this CRAC
  flow_cnecs = RAO.get_flow_cnecs(crac)
  @test size(flow_cnecs, 1) == 7
  @test issubset(["id", "network_element_id", "instant", "contingency_id"], names(flow_cnecs))

  # This CRAC is a PST parade: exactly one PST range action, no network actions
  pst = RAO.get_pst_range_actions(crac)
  @test size(pst, 1) == 1
  @test "network_element_id" in names(pst)
  @test size(RAO.get_network_actions(crac), 1) == 0

  # The angle/voltage CNEC accessors return the right (empty) schema for this CRAC
  @test "importing_network_element_id" in names(RAO.get_angle_cnecs(crac))
  @test "network_element_id" in names(RAO.get_voltage_cnecs(crac))
end

@testset "Test CRAC introspection (thresholds, actions, rules, limits)" begin
  RAO = Powsybl.RAO
  network = Powsybl.Network.load("data/rao/rao_network.uct")
  crac = RAO.load_crac(network, "data/rao/rao_crac.json")

  # Thresholds back the flow CNECs (one per CNEC here), range action ranges back the PST
  thresholds = RAO.get_thresholds(crac)
  @test issubset(["id", "min", "max", "unit", "side"], names(thresholds))
  @test size(thresholds, 1) == 7
  ranges = RAO.get_range_action_ranges(crac)
  @test issubset(["id", "min", "max", "range_type"], names(ranges))
  @test size(ranges, 1) == 1

  # Elementary action accessors: this CRAC has no network actions, so all are empty
  # but expose their columnar schema.
  @test "action_type" in names(RAO.get_terminal_connection_actions(crac))
  @test "tap_position" in names(RAO.get_pst_tap_position_actions(crac))
  @test "active_power_value" in names(RAO.get_generator_actions(crac))
  @test "active_power_value" in names(RAO.get_load_actions(crac))
  @test "active_power_value" in names(RAO.get_boundary_line_actions(crac))
  @test "section_count" in names(RAO.get_shunt_compensator_position_actions(crac))
  @test "action_type" in names(RAO.get_switch_actions(crac))
  @test issubset(["open", "close"], names(RAO.get_switch_pairs(crac)))
  @test "operator" in names(RAO.get_counter_trade_range_actions(crac))
  @test "distribution_key" in names(RAO.get_network_element_ids_and_keys(crac))

  # Usage rules: the schema of each rule family is exposed regardless of presence.
  @test issubset(["id", "instant"], names(RAO.get_on_instant_usage_rules(crac)))
  @test "contingency_id" in names(RAO.get_on_contingency_state_usage_rules(crac))
  @test "cnec_id" in names(RAO.get_on_constraint_usage_rules(crac))
  @test "country" in names(RAO.get_on_flow_constraint_in_country_usage_rules(crac))

  # Usage limits: caps on remedial actions, globally and per TSO.
  @test issubset(["instant", "value"], names(RAO.get_max_remedial_actions_usage_limits(crac)))
  @test "tso" in names(RAO.get_max_topological_actions_per_tso_usage_limits(crac))
  @test "tso" in names(RAO.get_max_pst_actions_per_tso_usage_limits(crac))
  @test "tso" in names(RAO.get_max_remedial_actions_per_tso_usage_limits(crac))
  @test "tso" in names(RAO.get_max_elementary_actions_per_tso_usage_limits(crac))
end

@testset "Test sensitivity analysis provider names" begin
  @test !isempty(Powsybl.SensitivityAnalysis.get_provider_names())
end

@testset "Test sensitivity analysis" begin
  network = Powsybl.Network.create_ieee9()
  generators = Powsybl.Network.get_generators(network)[:, "id"]
  branches = ["L7-8-0", "L9-8-0", "L7-5-0"]

  analysis = Powsybl.SensitivityAnalysis.create()
  Powsybl.SensitivityAnalysis.set_branch_flow_factor_matrix(analysis, branches, generators)

  result = Powsybl.SensitivityAnalysis.run_dc(analysis, network)

  sensitivities = Powsybl.SensitivityAnalysis.get_sensitivity_matrix(result)
  @test sensitivities isa Matrix{Float64}
  @test length(sensitivities) == length(branches) * length(generators)

  references = Powsybl.SensitivityAnalysis.get_reference_matrix(result)
  @test length(references) == length(branches)
end

@testset "Test sensitivity analysis zones" begin
  SEN = Powsybl.SensitivityAnalysis
  network = Powsybl.Network.create_ieee9()
  generators = Powsybl.Network.get_generators(network)[:, "id"]
  branches = ["L7-8-0", "L9-8-0", "L7-5-0"]

  # Zones can be built from a vector (with explicit or defaulted keys) or a Dict
  z1 = SEN.create_zone("zone1", [generators[1], generators[2]], [1.0, 2.0])
  @test z1.id == "zone1"
  @test z1.shift_keys_by_injection == Dict(generators[1] => 1.0, generators[2] => 2.0)

  z_uniform = SEN.create_zone("z", [generators[1], generators[2]])
  @test all(==(1.0), values(z_uniform.shift_keys_by_injection))

  z2 = SEN.create_zone("zone2", Dict(generators[3] => 1.0))
  @test z2.shift_keys_by_injection == Dict(generators[3] => 1.0)

  @test_throws ArgumentError SEN.create_zone("bad", ["a", "b"], [1.0])

  # Registered zone ids are usable as variable ids in a factor matrix
  analysis = SEN.create()
  SEN.set_zones(analysis, [z1, z2])
  SEN.add_factor_matrix(analysis, branches, ["zone1", "zone2"])

  result = SEN.run_dc(analysis, network)
  sensitivities = SEN.get_sensitivity_matrix(result)
  @test sensitivities isa Matrix{Float64}
  # One row per zone (variable), one column per branch (function)
  @test size(sensitivities) == (2, length(branches))
  # A GLSK zone distributes the shift, so its sensitivities are finite numbers
  @test all(isfinite, sensitivities)
end

@testset "Test element creation and update" begin
  network = Powsybl.Network.create_empty()

  Powsybl.Network.create_substations(network; id = "S1", country = "FR")
  Powsybl.Network.create_voltage_levels(network; id = "VL1", substation_id = "S1",
                                        topology_kind = "BUS_BREAKER", nominal_v = 400.0)
  Powsybl.Network.create_buses(network; id = "B1", voltage_level_id = "VL1")
  Powsybl.Network.create_loads(network; id = "LOAD1", voltage_level_id = "VL1", bus_id = "B1",
                               p0 = 100.0, q0 = 10.0)
  Powsybl.Network.create_generators(network; id = "GEN1", voltage_level_id = "VL1", bus_id = "B1",
                                    target_p = 100.0, min_p = 0.0, max_p = 1000.0,
                                    target_v = 400.0, voltage_regulator_on = true)

  substations = Powsybl.Network.get_substations(network)
  @test "S1" in substations[:, "id"]

  loads = Powsybl.Network.get_loads(network)
  @test "LOAD1" in loads[:, "id"]
  load_row = findfirst(==("LOAD1"), loads[:, "id"])
  @test loads[load_row, "p0"] == 100.0

  generators = Powsybl.Network.get_generators(network)
  @test "GEN1" in generators[:, "id"]

  # Update an existing element
  Powsybl.Network.update_loads(network; id = "LOAD1", p0 = 200.0)
  loads = Powsybl.Network.get_loads(network)
  load_row = findfirst(==("LOAD1"), loads[:, "id"])
  @test loads[load_row, "p0"] == 200.0

  # Create several elements in a single call
  Powsybl.Network.create_buses(network; id = ["B2", "B3"], voltage_level_id = ["VL1", "VL1"])
  buses = Powsybl.Network.get_bus_breaker_view_buses(network)
  @test "B2" in buses[:, "id"]
  @test "B3" in buses[:, "id"]
end

@testset "Test extension creation, update and removal" begin
  @test "activePowerControl" in Powsybl.Network.get_extensions_names()
  @test size(Powsybl.Network.get_extensions_information(), 1) >= 1

  network = Powsybl.Network.create_eurostag_tutorial_example1()
  generator_id = Powsybl.Network.get_generators(network)[1, "id"]

  # Create an activePowerControl extension on the generator
  Powsybl.Network.create_extensions(network, "activePowerControl";
                                    id = generator_id, droop = 4.0, participate = true)
  extension = Powsybl.Network.get_extensions(network, "activePowerControl")
  @test generator_id in extension[:, "id"]
  row = findfirst(==(generator_id), extension[:, "id"])
  @test extension[row, "droop"] == 4.0
  @test extension[row, "participate"] == true          # exercises the boolean marshalling

  # Update it
  Powsybl.Network.update_extensions(network, "activePowerControl"; id = generator_id, droop = 8.0)
  extension = Powsybl.Network.get_extensions(network, "activePowerControl")
  row = findfirst(==(generator_id), extension[:, "id"])
  @test extension[row, "droop"] == 8.0

  # Remove it
  Powsybl.Network.remove_extensions(network, "activePowerControl", generator_id)
  extension = Powsybl.Network.get_extensions(network, "activePowerControl")
  @test !(generator_id in extension[:, "id"])
end

@testset "Test multi-dataframe creation (shunts and tap changers)" begin
  network = Powsybl.Network.create_empty()
  Powsybl.Network.create_substations(network; id = "S1", country = "FR")
  Powsybl.Network.create_voltage_levels(network; id = "VL1", substation_id = "S1",
                                        topology_kind = "BUS_BREAKER", nominal_v = 400.0)
  Powsybl.Network.create_buses(network; id = "B1", voltage_level_id = "VL1")

  # Linear shunt: dataframe 0 (shunt) + dataframe 1 (linear model), dataframe 2 left empty
  Powsybl.Network.create_shunt_compensators(network;
      id = "SHUNT_L", voltage_level_id = "VL1", bus_id = "B1", section_count = 1, model_type = "LINEAR",
      linear = (id = "SHUNT_L", g_per_section = 0.0, b_per_section = 1e-5, max_section_count = 1))
  @test "SHUNT_L" in Powsybl.Network.get_shunt_compensators(network)[:, "id"]

  # Non-linear shunt with two sections: dataframe 0 + empty dataframe 1 + dataframe 2
  Powsybl.Network.create_shunt_compensators(network;
      id = "SHUNT_NL", voltage_level_id = "VL1", bus_id = "B1", section_count = 1, model_type = "NON_LINEAR",
      non_linear = (id = ["SHUNT_NL", "SHUNT_NL"], g = [0.0, 0.0], b = [1e-5, 2e-5]))
  @test "SHUNT_NL" in Powsybl.Network.get_shunt_compensators(network)[:, "id"]
  sections = Powsybl.Network.get_non_linear_shunt_compensator_sections(network)
  @test count(==("SHUNT_NL"), sections[:, "id"]) == 2

  # Ratio tap changer with three steps on an existing transformer: dataframe 0 + steps
  eurostag = Powsybl.Network.create_eurostag_tutorial_example1()
  Powsybl.Network.create_ratio_tap_changers(eurostag;
      id = "NGEN_NHV1", tap = 1, low_tap = 0, target_v = 400.0, target_deadband = 0.0, regulating = false,
      steps = (id = ["NGEN_NHV1", "NGEN_NHV1", "NGEN_NHV1"],
               g = [0.0, 0.0, 0.0], b = [0.0, 0.0, 0.0], r = [0.0, 0.0, 0.0], x = [0.0, 0.0, 0.0],
               rho = [0.9, 1.0, 1.1]))
  @test "NGEN_NHV1" in Powsybl.Network.get_ratio_tap_changers(eurostag)[:, "id"]
  rtc_steps = Powsybl.Network.get_ratio_tap_changer_steps(eurostag)
  @test count(==("NGEN_NHV1"), rtc_steps[:, "id"]) == 3
end

@testset "Test network modifications" begin
  N = Powsybl.Network

  # Build a node-breaker voltage level and create its topology (two busbar sections)
  network = N.create_empty()
  N.create_substations(network; id = "S1", country = "FR")
  N.create_voltage_levels(network; id = "VL1", substation_id = "S1",
                          topology_kind = "NODE_BREAKER", nominal_v = 400.0)
  N.create_voltage_level_topology(network; id = "VL1",
                                  aligned_buses_or_busbar_count = 2, section_count = 1, switch_kinds = "")
  busbars = N.get_busbar_sections(network)[:, "id"]
  @test length(busbars) == 2

  # Couple the two busbar sections; a coupling device adds switches
  switches_before = size(N.get_switches(network), 1)
  N.create_coupling_device(network;
                           bus_or_busbar_section_id_1 = busbars[1],
                           bus_or_busbar_section_id_2 = busbars[2], switch_prefix_id = "cpl")
  @test size(N.get_switches(network), 1) > switches_before

  # Unused connectable order positions around a busbar section
  interval = N.get_unused_order_positions_after(network, busbars[1])
  @test interval === nothing || (interval isa Tuple{Int, Int} && interval[1] <= interval[2])

  # Tap an existing line with a new line (create line on line)
  eurostag = N.create_eurostag_tutorial_example1()
  target_bus = N.get_bus_breaker_view_buses(eurostag)[1, "id"]
  N.create_line_on_line(eurostag;
                        bbs_or_bus_id = target_bus, new_line_id = "NEW_LINE",
                        new_line_r = 1.0, new_line_x = 1.0,
                        new_line_b1 = 0.0, new_line_b2 = 0.0, new_line_g1 = 0.0, new_line_g2 = 0.0,
                        line_id = "NHV1_NHV2_1", line1_id = "L1_PART1", line2_id = "L1_PART2",
                        position_percent = 50.0)
  lines_after = N.get_lines(eurostag)[:, "id"]
  @test "NEW_LINE" in lines_after
  @test "L1_PART1" in lines_after && "L1_PART2" in lines_after
  @test !("NHV1_NHV2_1" in lines_after)   # the tapped line was split

  # Remove a feeder bay (a generator and its bay)
  eurostag2 = N.create_eurostag_tutorial_example1()
  @test "GEN" in N.get_generators(eurostag2)[:, "id"]
  N.remove_feeder_bays(eurostag2, "GEN")
  @test !("GEN" in N.get_generators(eurostag2)[:, "id"])
end

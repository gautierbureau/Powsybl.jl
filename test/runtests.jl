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

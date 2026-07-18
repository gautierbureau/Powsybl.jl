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

  # Default parameters expose editable, typed fields
  defaults = RAO.rao_parameters()
  @test defaults.objective_function_type == RAO.SECURE_FLOW
  @test defaults.unit == RAO.MEGAWATT
  @test defaults.solver == RAO.CBC
  @test defaults.load_flow_provider == "OpenLoadFlow"

  # Parameters round-trip through JSON, preserving edited fields
  edited = RAO.rao_parameters()
  edited.objective_function_type = RAO.MAX_MIN_MARGIN
  edited.max_mip_iterations = 5
  edited.pst_model = RAO.APPROXIMATED_INTEGERS
  json = RAO.parameters_to_json(edited)
  @test occursin("MAX_MIN_MARGIN", json)
  restored = RAO.parameters_from_json(json)
  @test restored.objective_function_type == RAO.MAX_MIN_MARGIN
  @test restored.max_mip_iterations == 5
  @test restored.pst_model == RAO.APPROXIMATED_INTEGERS

  # Load parameters into an editable struct and run the RAO with it
  parameters = RAO.load_parameters("data/rao/rao_parameters.json")
  @test parameters.objective_function_type == RAO.MAX_MIN_MARGIN
  result = RAO.run(rao, network, crac; parameters = parameters)

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
end

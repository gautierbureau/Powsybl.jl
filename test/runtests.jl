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

@testset "Test flow decomposition" begin
  FD = Powsybl.FlowDecomposition
  network = Powsybl.Network.load("simple-eu.xiidm")
  lines = Powsybl.Network.get_lines(network)
  branch = lines[1, "id"]
  other_branch = lines[2, "id"]

  # Default parameters expose editable, typed fields
  params = FD.Parameters()
  @test params.enable_losses_compensation == false
  @test params.rescale_mode == FD.NONE
  @test params.sensitivity_variable_batch_size == 15000

  # Monitoring all branches decomposes every branch on the pre-contingency (N) state
  ctx = FD.create()
  FD.add_all_branches_as_monitored_elements(ctx)
  df = FD.run(ctx, network)
  @test issubset(["xnec_id", "branch_id", "contingency_id", "country1", "country2",
                  "ac_reference_flow1", "dc_reference_flow", "commercial_flow",
                  "loop_flow_from_be", "loop_flow_from_fr"], names(df))
  @test size(df, 1) == 18
  @test all(df[:, "contingency_id"] .== "")   # all pre-contingency (XNE)

  # A single monitored branch on the N state yields exactly one XNE
  ctx1 = FD.create()
  FD.add_precontingency_monitored_elements(ctx1, branch)
  @test size(FD.run(ctx1, network), 1) == 1

  # A contingency plus a post-contingency monitored branch yields an XNEC tagged with it
  ctx2 = FD.create()
  FD.add_single_element_contingency(ctx2, other_branch; contingency_id = "cont1")
  FD.add_postcontingency_monitored_elements(ctx2, branch, "cont1")
  post = FD.run(ctx2, network)
  @test size(post, 1) == 1
  @test post[1, "contingency_id"] == "cont1"

  # Edited parameters flow through to the run. Losses compensation mutates the network
  # (adds fictitious loss loads), so use a freshly loaded network for it.
  edited = FD.Parameters()
  edited.rescale_mode = FD.ACER_METHODOLOGY
  edited.enable_losses_compensation = true
  fresh = Powsybl.Network.load("simple-eu.xiidm")
  ctx3 = FD.create()
  FD.add_all_branches_as_monitored_elements(ctx3)
  @test size(FD.run(ctx3, fresh; parameters = edited), 1) == 18
end
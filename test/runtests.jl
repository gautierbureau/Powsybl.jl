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
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

@testset "Test in-memory and probing I/O" begin
  network = Powsybl.Network.load("simple-eu.xiidm")

  # Export to a string and reload it from that string
  content = Powsybl.Network.save_to_string(network, "XIIDM")
  @test content isa String
  @test occursin("<?xml", content)

  reloaded = Powsybl.Network.load_from_string("simple-eu.xiidm", content)
  @test reloaded.name == network.name

  # Probe whether a file is a loadable network
  @test Powsybl.Network.is_network_loadable("simple-eu.xiidm") == true
  @test Powsybl.Network.is_network_loadable("runtests.jl") == false

  # Update an existing network in place from a file (CGMES implements updates)
  cgmes_file = tempname() * ".zip"
  Powsybl.Network.save(network, cgmes_file, "CGMES")
  cgmes = Powsybl.Network.load(cgmes_file)
  Powsybl.Network.update_network(cgmes, cgmes_file)
  @test cgmes.source_format == "CGMES"
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

@testset "Test version table" begin
  table = Powsybl.get_version_table()
  @test table isa String
  @test !isempty(table)
end

@testset "Test import/export format metadata" begin
  extensions = Powsybl.Network.get_network_import_supported_extensions()
  @test extensions isa Vector{String}
  @test !isempty(extensions)

  cgmes_import = Powsybl.Network.get_import_parameters("CGMES")
  @test size(cgmes_import, 2) >= 1

  xiidm_export = Powsybl.Network.get_export_parameters("XIIDM")
  @test size(xiidm_export, 2) >= 1
end

@testset "Test variant management" begin
  network = Powsybl.Network.create_ieee9()

  variants = Powsybl.Network.get_variants_ids(network)
  @test length(variants) == 1

  initial = Powsybl.Network.get_working_variant_id(network)
  @test initial in variants

  Powsybl.Network.clone_variant(network, initial, "my_variant")
  @test "my_variant" in Powsybl.Network.get_variants_ids(network)

  Powsybl.Network.set_working_variant(network, "my_variant")
  @test Powsybl.Network.get_working_variant_id(network) == "my_variant"

  Powsybl.Network.set_working_variant(network, initial)
  Powsybl.Network.remove_variant(network, "my_variant")
  @test !("my_variant" in Powsybl.Network.get_variants_ids(network))
end

@testset "Test network mutation" begin
  network = Powsybl.Network.create_ieee9()

  loads_before = Powsybl.Network.get_loads(network)
  n_before = size(loads_before, 1)
  @test n_before > 0

  a_load = loads_before[1, "id"]
  Powsybl.Network.remove_elements(network, a_load)
  @test size(Powsybl.Network.get_loads(network), 1) == n_before - 1

  generator_ids = Powsybl.Network.get_elements_ids(network, Powsybl.LibPowsybl.GENERATOR)
  @test generator_ids isa Vector{String}
  @test !isempty(generator_ids)
end

@testset "Test bus/breaker view" begin
  network = Powsybl.Network.create_ieee9()
  voltage_levels = Powsybl.Network.get_voltage_levels(network)
  vl_id = voltage_levels[1, "id"]

  buses = Powsybl.Network.get_bus_breaker_view_buses(network, vl_id)
  @test size(buses, 1) >= 1

  # These must return a DataFrame without throwing
  Powsybl.Network.get_bus_breaker_view_switches(network, vl_id)
  Powsybl.Network.get_bus_breaker_view_elements(network, vl_id)
end

@testset "Test node/breaker view and connectable status" begin
  network = Powsybl.Network.create_four_substations_node_breaker()
  voltage_levels = Powsybl.Network.get_voltage_levels(network)
  vl_id = voltage_levels[1, "id"]

  nodes = Powsybl.Network.get_node_breaker_view_nodes(network, vl_id)
  @test size(nodes, 1) >= 1

  # These must return a DataFrame without throwing
  Powsybl.Network.get_node_breaker_view_switches(network, vl_id)
  Powsybl.Network.get_node_breaker_view_internal_connections(network, vl_id)

  loads = Powsybl.Network.get_loads(network)
  if size(loads, 1) > 0
    load_id = loads[1, "id"]
    @test Powsybl.Network.update_connectable_status(network, load_id, false) isa Bool
    @test Powsybl.Network.update_connectable_status(network, load_id, true) isa Bool
  end
@testset "Test security analysis provider names" begin
  @test !isempty(Powsybl.SecurityAnalysis.get_provider_names())
end

@testset "Test security analysis" begin
  network = Powsybl.Network.create_ieee9()

  analysis = Powsybl.SecurityAnalysis.create()
  Powsybl.SecurityAnalysis.add_single_element_contingency(analysis, "L7-8-0")
  Powsybl.SecurityAnalysis.add_multiple_elements_contingency(analysis, ["L9-8-0", "L7-5-0"], "double")
  Powsybl.SecurityAnalysis.add_monitored_elements(analysis; branch_ids = ["L9-6-0"])

  parameters = Powsybl.LoadFlow.load_flow_parameters()
  result = Powsybl.SecurityAnalysis.run_ac(analysis, network, parameters)

  # Base case converges
  @test Powsybl.SecurityAnalysis.get_pre_contingency_result(result) == Powsybl.SecurityAnalysis.CONVERGED

  # One row per contingency, in insertion order
  post = Powsybl.SecurityAnalysis.get_post_contingency_results(result)
  @test Set(post[:, "contingency_id"]) == Set(["L7-8-0", "double"])
  @test post[1, "status"] isa Powsybl.SecurityAnalysis.ComputationStatus

  # Result accessors return tabular data without throwing
  violations = Powsybl.SecurityAnalysis.get_limit_violations(result)
  @test size(violations, 2) >= 0

  branch_results = Powsybl.SecurityAnalysis.get_branch_results(result)
  @test size(branch_results, 2) >= 0

  Powsybl.SecurityAnalysis.get_bus_results(result)
  Powsybl.SecurityAnalysis.get_three_windings_transformer_results(result)
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
@testset "Test single line diagram" begin
  network = Powsybl.Network.create_ieee9()
  vl_id = Powsybl.Network.get_voltage_levels(network)[1, "id"]

  svg = Powsybl.Diagram.get_single_line_diagram_svg(network, vl_id)
  @test svg isa String
  @test occursin("<svg", svg)

  @test !isempty(Powsybl.Diagram.get_single_line_diagram_component_library_names())

  svg_file = tempname() * ".svg"
  Powsybl.Diagram.write_single_line_diagram_svg(network, vl_id, svg_file)
  @test isfile(svg_file)
  @test filesize(svg_file) > 0
end

@testset "Test network area diagram" begin
  network = Powsybl.Network.create_ieee9()
  vl_id = Powsybl.Network.get_voltage_levels(network)[1, "id"]

  svg = Powsybl.Diagram.get_network_area_diagram_svg(network; voltage_level_ids = [vl_id], depth = 1)
  @test svg isa String
  @test occursin("<svg", svg)

  displayed = Powsybl.Diagram.get_network_area_diagram_displayed_voltage_levels(network, [vl_id], 1)
  @test displayed isa Vector{String}
  @test vl_id in displayed

  svg_file = tempname() * ".svg"
  Powsybl.Diagram.write_network_area_diagram_svg(network, svg_file)
  @test isfile(svg_file)
  @test filesize(svg_file) > 0
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
@testset "Test reporting" begin
  report = Powsybl.Report.create_report_node()

  # Load flow with a report node collects functional logs
  network = Powsybl.Network.create_ieee9()
  parameters = Powsybl.LoadFlow.load_flow_parameters()
  result = Powsybl.LoadFlow.run_ac(network, parameters; report = report)
  @test result.component_results[1, :].status == Powsybl.LoadFlow.CONVERGED

  text = Powsybl.Report.to_string(report)
  @test text isa String
  @test !isempty(text)

  json = Powsybl.Report.to_json(report)
  @test occursin("{", json)

  # Network import with a report node
  import_report = Powsybl.Report.create_report_node()
  imported = Powsybl.Network.load("simple-eu.xiidm"; report = import_report)
  @test imported.name == "simple-eu"
  @test !isempty(Powsybl.Report.to_string(import_report))
end

@testset "Test Java logging" begin
  Powsybl.Log.set_level(Powsybl.Log.INFO)
  Powsybl.Log.clear()
  @test isempty(Powsybl.Log.get_messages())

  network = Powsybl.Network.create_ieee9()
  Powsybl.LoadFlow.run_ac(network, Powsybl.LoadFlow.load_flow_parameters())
  info_messages = Powsybl.Log.get_messages()
  @test info_messages isa Vector{String}
  @test !isempty(info_messages)
  @test any(message -> occursin("OpenLoadFlow", message), info_messages)

  # A lower level yields more detail (DEBUG includes the Java stack traces)
  Powsybl.Log.set_level(Powsybl.Log.DEBUG)
  Powsybl.Log.clear()
  Powsybl.LoadFlow.run_ac(Powsybl.Network.create_ieee9(), Powsybl.LoadFlow.load_flow_parameters())
  @test length(Powsybl.Log.get_messages()) >= length(info_messages)

  Powsybl.Log.clear()
  @test isempty(Powsybl.Log.get_messages())
end
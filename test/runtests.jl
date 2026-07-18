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

@testset "Test per-unit settings" begin
  N = Powsybl.Network
  network = N.create_ieee9()

  # Defaults: physical units, 100 MVA base
  @test N.is_per_unit() == false
  @test N.get_nominal_apparent_power() == 100.0
  x_physical = N.get_lines(network)[1, "x"]

  try
    @test N.set_per_unit(true) === nothing
    @test N.set_nominal_apparent_power(100.0) === nothing
    @test N.is_per_unit() == true
    @test N.get_nominal_apparent_power() == 100.0

    # The same reactance is now reported in per-unit (base impedance = V^2 / S)
    x_per_unit = N.get_lines(network)[1, "x"]
    @test x_per_unit != x_physical
    @test x_per_unit < x_physical
  finally
    N.set_per_unit(false)
  end

  # Disabling per-unit restores the physical value
  @test N.is_per_unit() == false
  @test N.get_lines(network)[1, "x"] == x_physical
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
@testset "Test network composition" begin
  be = Powsybl.Network.create_micro_grid_be()
  nl = Powsybl.Network.create_micro_grid_nl()
  vl_be = size(Powsybl.Network.get_voltage_levels(be), 1)
  vl_nl = size(Powsybl.Network.get_voltage_levels(nl), 1)

  # Merge the two networks into one
  merged = Powsybl.Network.merge([be, nl])
  @test size(Powsybl.Network.get_voltage_levels(merged), 1) == vl_be + vl_nl

  # The merged network has both as sub-networks
  subs = Powsybl.Network.get_sub_networks(merged)
  @test size(subs, 1) == 2

  # Retrieve a sub-network and detach it into a standalone network
  sub = Powsybl.Network.get_sub_network(merged, subs[1, "id"])
  detached = Powsybl.Network.detach_sub_network(sub)
  @test size(Powsybl.Network.get_voltage_levels(detached), 1) in (vl_be, vl_nl)

  # Reduce a network in place, keeping only two voltage levels
  network = Powsybl.Network.create_ieee9()
  all_vls = Powsybl.Network.get_voltage_levels(network)[:, "id"]
  kept = all_vls[1:2]
  Powsybl.Network.reduce_by_ids(network, kept)
  @test Set(Powsybl.Network.get_voltage_levels(network)[:, "id"]) == Set(kept)
end

@testset "Test security analysis operator strategies" begin
  SA = Powsybl.SecurityAnalysis
  network = Powsybl.Network.create_eurostag_tutorial_example1()

  analysis = SA.create()
  SA.add_single_element_contingency(analysis, "NHV1_NHV2_1", "co1")

  # Register remedial actions of several kinds
  SA.add_load_active_power_action(analysis, "act_load_p", "LOAD", true, 10.0)
  SA.add_load_reactive_power_action(analysis, "act_load_q", "LOAD", true, 5.0)
  SA.add_generator_active_power_action(analysis, "act_gen", "GEN", false, 100.0)

  # Operator strategy applying the load action on the contingency
  SA.add_operator_strategy(analysis, "strat1", "co1", ["act_load_p"])
  SA.add_monitored_elements(analysis; branch_ids = ["NHV1_NHV2_2"])

  result = SA.run_ac(analysis, network)

  # One row per operator strategy, converged
  os = SA.get_operator_strategy_results(result)
  @test os[:, "operator_strategy_id"] == ["strat1"]
  @test os[1, "status"] == SA.CONVERGED

  # Post-strategy limit violations are tabular and tagged with the strategy id
  osv = SA.get_operator_strategy_limit_violations(result)
  @test names(osv) == ["operator_strategy_id", "subject_id", "subject_name", "limit_type",
                       "limit_name", "limit", "acceptable_duration", "limit_reduction", "value", "side"]
  @test all(id -> id == "strat1", osv[:, "operator_strategy_id"])
  @test "NHV1_NHV2_2" in osv[:, "subject_id"]
  @test eltype(osv[:, "side"]) == SA.Side

  # Enum-typed conditions and a violation filter are accepted end-to-end
  analysis2 = SA.create()
  SA.add_single_element_contingency(analysis2, "NHV1_NHV2_1", "co1")
  SA.add_generator_active_power_action(analysis2, "act_gen", "GEN", true, -50.0)
  SA.add_operator_strategy(analysis2, "strat2", "co1", ["act_gen"];
                           condition_type = SA.ANY_VIOLATION_CONDITION,
                           violation_subject_ids = ["NHV1_NHV2_2"],
                           violation_types = [SA.CURRENT, SA.HIGH_VOLTAGE])
  result2 = SA.run_ac(analysis2, network)
  @test SA.get_operator_strategy_results(result2)[:, "operator_strategy_id"] == ["strat2"]

  # Remaining action kinds marshal their arguments (including the Side enum) without
  # error. They target elements the sample network lacks, so this context is not run —
  # the engine only validates element ids at run time.
  actions = SA.create()
  @test SA.add_switch_action(actions, "a1", "a_switch", true) === nothing
  @test SA.add_shunt_compensator_position_action(actions, "a2", "a_shunt", 1) === nothing
  @test SA.add_phase_tap_changer_position_action(actions, "a3", "a_twt", 2; side = SA.SIDE_ONE) === nothing
  @test SA.add_ratio_tap_changer_position_action(actions, "a4", "a_twt", 1; is_relative = true) === nothing
  @test SA.add_terminals_connection_action(actions, "a5", "a_line"; side = SA.SIDE_TWO, opening = false) === nothing

  # The result can be exported to JSON
  json_path = tempname() * ".json"
  SA.export_to_json(result, json_path)
  @test isfile(json_path)
  @test filesize(json_path) > 0
  rm(json_path; force = true)
@testset "Test load flow parameters JSON round-trip" begin
  LF = Powsybl.LoadFlow
  parameters = LF.load_flow_parameters()
  parameters.distributed_slack = false
  parameters.dc_power_factor = 0.95
  parameters.voltage_init_mode = LF.DC_VALUES
  parameters.balance_type = LF.PROPORTIONAL_TO_LOAD
  parameters.countries_to_balance = ["FR", "BE"]
  parameters.provider_parameters = Dict("maxNewtonRaphsonIterations" => "20")

  json = LF.parameters_to_json(parameters)
  @test occursin("balanceType", json)
  # Provider-specific parameters are serialized into the JSON extensions section
  @test occursin("maxNewtonRaphsonIterations", json)

  # The common parameters round-trip exactly
  restored = LF.parameters_from_json(json)
  @test restored.distributed_slack == false
  @test restored.dc_power_factor == 0.95
  @test restored.voltage_init_mode == LF.DC_VALUES
  @test restored.balance_type == LF.PROPORTIONAL_TO_LOAD
  @test restored.countries_to_balance == ["FR", "BE"]

  # A default set of parameters is serializable and re-parses to the same defaults
  defaults = LF.load_flow_parameters()
  reparsed = LF.parameters_from_json(LF.parameters_to_json(defaults))
  @test reparsed.use_reactive_limits == defaults.use_reactive_limits
  @test reparsed.balance_type == defaults.balance_type
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
@testset "Test feeder bays and alias/internal-connection removal" begin
  N = Powsybl.Network

  # A helper node-breaker network with two voltage levels, each with one busbar section
  function node_breaker_network()
    network = N.create_empty()
    N.create_substations(network; id = "S1", country = "FR")
    N.create_voltage_levels(network; id = "VL1", substation_id = "S1",
                            topology_kind = "NODE_BREAKER", nominal_v = 400.0)
    N.create_voltage_levels(network; id = "VL2", substation_id = "S1",
                            topology_kind = "NODE_BREAKER", nominal_v = 400.0)
    N.create_voltage_level_topology(network; id = "VL1", aligned_buses_or_busbar_count = 1,
                                    section_count = 1, switch_kinds = "")
    N.create_voltage_level_topology(network; id = "VL2", aligned_buses_or_busbar_count = 1,
                                    section_count = 1, switch_kinds = "")
    return network, N.get_busbar_sections(network)[:, "id"]
  end

  # Injection feeder bays (create the element and its connection bay in one step)
  network, busbars = node_breaker_network()
  N.create_load_bay(network; id = "LOAD1", p0 = 100.0, q0 = 10.0,
                    bus_or_busbar_section_id = busbars[1], position_order = 10, direction = "BOTTOM")
  @test "LOAD1" in N.get_loads(network)[:, "id"]

  N.create_generator_bay(network; id = "GEN1", max_p = 1000.0, min_p = 0.0, target_p = 100.0,
                         target_v = 400.0, voltage_regulator_on = true,
                         bus_or_busbar_section_id = busbars[1], position_order = 20, direction = "TOP")
  @test "GEN1" in N.get_generators(network)[:, "id"]

  # Line feeder bay (connects two node-breaker voltage levels)
  network2, busbars2 = node_breaker_network()
  N.create_line_bays(network2; id = "NEW_LINE", r = 1.0, x = 10.0, b1 = 0.0, b2 = 0.0, g1 = 0.0, g2 = 0.0,
                     bus_or_busbar_section_id_1 = busbars2[1], bus_or_busbar_section_id_2 = busbars2[2],
                     position_order_1 = 10, position_order_2 = 10)
  @test "NEW_LINE" in N.get_lines(network2)[:, "id"]

  # Two windings transformer feeder bay
  network3, busbars3 = node_breaker_network()
  N.create_2_windings_transformer_bays(network3; id = "NEW_TWT",
                                       voltage_level1_id = "VL1", voltage_level2_id = "VL2",
                                       r = 1.0, x = 10.0, g = 0.0, b = 0.0, rated_u1 = 400.0, rated_u2 = 400.0,
                                       bus_or_busbar_section_id_1 = busbars3[1], bus_or_busbar_section_id_2 = busbars3[2],
                                       position_order_1 = 10, position_order_2 = 10)
  @test "NEW_TWT" in N.get_2_windings_transformers(network3)[:, "id"]

  # Alias removal round-trip: add an alias, remove it, then the id is free to reuse
  eurostag = N.create_eurostag_tutorial_example1()
  N.create_elements(eurostag, Powsybl.LibPowsybl.ALIAS; id = "GEN", alias = "MY_ALIAS", alias_type = "")
  N.remove_aliases(eurostag; id = "GEN", alias = "MY_ALIAS")
  # Re-adding the same alias only succeeds because the previous one was removed
  N.create_elements(eurostag, Powsybl.LibPowsybl.ALIAS; id = "GEN", alias = "MY_ALIAS", alias_type = "")
  @test "GEN" in N.get_generators(eurostag)[:, "id"]

  # Internal-connection removal reaches the engine: removing a nonexistent one is rejected
  empty_nb = N.create_empty()
  N.create_substations(empty_nb; id = "S1", country = "FR")
  N.create_voltage_levels(empty_nb; id = "VL1", substation_id = "S1",
                          topology_kind = "NODE_BREAKER", nominal_v = 400.0)
  @test_throws Exception N.remove_internal_connections(empty_nb; voltage_level_id = "VL1", node1 = 0, node2 = 1)
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

  # Voltage monitoring enriches the result; it runs cleanly even though this PST-parade
  # CRAC declares no voltage CNECs (so the voltage CNEC table is empty)
  voltage_monitored = RAO.run_voltage_monitoring(rao, network, crac, result)
  @test RAO.get_status(voltage_monitored) == RAO.DEFAULT
  voltage_cnecs = RAO.get_voltage_cnec_results(voltage_monitored)
  @test names(voltage_cnecs) == ["index", "cnec_id", "optimized_instant", "contingency",
                                 "side", "min_voltage", "max_voltage", "margin"]

  # Angle monitoring, driven with a monitoring GLSK
  angle_monitored = RAO.run_angle_monitoring(rao, network, crac, result; monitoring_glsk = glsk)
  @test RAO.get_status(angle_monitored) == RAO.DEFAULT
  angle_cnecs = RAO.get_angle_cnec_results(angle_monitored)
  @test names(angle_cnecs) == ["index", "cnec_id", "optimized_instant", "contingency", "angle", "margin"]
end

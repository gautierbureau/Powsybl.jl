# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

module RAO
  using ..LibPowsybl
  using ..Network
  using CxxWrap

  """
  Global status of a RAO (remedial action optimisation) run: `DEFAULT` (success),
  `FAILURE`, or `PARTIAL_FAILURE`.
  """
  @enum RaoComputationStatus begin
    DEFAULT = LibPowsybl.RAO_DEFAULT
    FAILURE = LibPowsybl.RAO_FAILURE
    PARTIAL_FAILURE = LibPowsybl.RAO_PARTIAL_FAILURE
  end

  """
  A RAO context, created with [`create`](@ref) and run against a network and a CRAC.
  """
  mutable struct RaoContext
    handle::LibPowsybl.JavaHandle
  end

  """
  A CRAC (Contingencies, Remedial Actions and additional Constraints) imported with
  [`load_crac`](@ref).
  """
  mutable struct Crac
    handle::LibPowsybl.JavaHandle
  end

  """
  A GLSK (Generation and Load Shift Keys) document imported with [`load_glsk`](@ref),
  used for loop-flow or monitoring computations.
  """
  mutable struct Glsk
    handle::LibPowsybl.JavaHandle
  end

  """
  The result of a RAO run. Query it through [`get_status`](@ref) and the result accessors.
  It keeps a reference to the CRAC it was computed against, so the accessors only need the
  result itself.
  """
  mutable struct RaoResult
    handle::LibPowsybl.JavaHandle
    crac::LibPowsybl.JavaHandle
  end

  """
      create() -> RaoContext

  Create an empty RAO context.
  """
  function create()
    return RaoContext(LibPowsybl.create_rao())
  end

  """
      load_crac(network, crac_file) -> Crac

  Import a CRAC from a JSON file, interpreted against `network`.
  """
  function load_crac(network::Network.NetworkHandle, crac_file::AbstractString)
    return Crac(LibPowsybl.load_crac_source(network.handle, String(read(crac_file))))
  end

  """
      load_glsk(glsk_file) -> Glsk

  Import a GLSK document (e.g. a CIM/UCTE GSK XML file).
  """
  function load_glsk(glsk_file::AbstractString)
    return Glsk(LibPowsybl.load_glsk_source(String(read(glsk_file))))
  end

  # ---------------------------------------------------------------------------
  # CRAC introspection: read the contents of a loaded CRAC as DataFrames.
  # ---------------------------------------------------------------------------

  """
      get_contingencies(crac::Crac) -> DataFrame

  Return the contingencies defined in the CRAC (one row per contingency).
  """
  get_contingencies(crac::Crac) = _df(LibPowsybl.get_crac_contingencies(crac.handle))

  """
      get_contingency_elements(crac::Crac) -> DataFrame

  Return the network elements tripped by each contingency (one row per element).
  """
  get_contingency_elements(crac::Crac) = _df(LibPowsybl.get_crac_contingency_elements(crac.handle))

  """
      get_instants(crac::Crac) -> DataFrame

  Return the instants defined in the CRAC (preventive, outage, curative, ...).
  """
  get_instants(crac::Crac) = _df(LibPowsybl.get_crac_instants(crac.handle))

  """
      get_flow_cnecs(crac::Crac) -> DataFrame

  Return the flow CNECs (critical network elements and contingencies) of the CRAC.
  """
  get_flow_cnecs(crac::Crac) = _df(LibPowsybl.get_crac_flow_cnecs(crac.handle))

  """
      get_angle_cnecs(crac::Crac) -> DataFrame

  Return the angle CNECs of the CRAC.
  """
  get_angle_cnecs(crac::Crac) = _df(LibPowsybl.get_crac_angle_cnecs(crac.handle))

  """
      get_voltage_cnecs(crac::Crac) -> DataFrame

  Return the voltage CNECs of the CRAC.
  """
  get_voltage_cnecs(crac::Crac) = _df(LibPowsybl.get_crac_voltage_cnecs(crac.handle))

  """
      get_pst_range_actions(crac::Crac) -> DataFrame

  Return the PST range actions available as remedial actions in the CRAC.
  """
  get_pst_range_actions(crac::Crac) = _df(LibPowsybl.get_crac_pst_range_actions(crac.handle))

  """
      get_hvdc_range_actions(crac::Crac) -> DataFrame

  Return the HVDC range actions of the CRAC.
  """
  get_hvdc_range_actions(crac::Crac) = _df(LibPowsybl.get_crac_hvdc_range_actions(crac.handle))

  """
      get_injection_range_actions(crac::Crac) -> DataFrame

  Return the injection range actions of the CRAC.
  """
  get_injection_range_actions(crac::Crac) = _df(LibPowsybl.get_crac_injection_range_actions(crac.handle))

  """
      get_network_actions(crac::Crac) -> DataFrame

  Return the network (topological) actions available in the CRAC.
  """
  get_network_actions(crac::Crac) = _df(LibPowsybl.get_crac_network_actions(crac.handle))

  """
      get_thresholds(crac::Crac) -> DataFrame

  Return the thresholds attached to the CNECs of the CRAC (one row per threshold).
  """
  get_thresholds(crac::Crac) = _df(LibPowsybl.get_crac_thresholds(crac.handle))

  """
      get_range_action_ranges(crac::Crac) -> DataFrame

  Return the ranges (min/max set point or tap) of the range actions of the CRAC.
  """
  get_range_action_ranges(crac::Crac) = _df(LibPowsybl.get_crac_range_action_ranges(crac.handle))

  """
      get_counter_trade_range_actions(crac::Crac) -> DataFrame

  Return the counter trade range actions of the CRAC.
  """
  get_counter_trade_range_actions(crac::Crac) = _df(LibPowsybl.get_crac_counter_trade_range_actions(crac.handle))

  """
      get_terminal_connection_actions(crac::Crac) -> DataFrame

  Return the terminal connection elementary actions of the network actions of the CRAC.
  """
  get_terminal_connection_actions(crac::Crac) = _df(LibPowsybl.get_crac_terminal_connection_actions(crac.handle))

  """
      get_pst_tap_position_actions(crac::Crac) -> DataFrame

  Return the PST tap position elementary actions of the network actions of the CRAC.
  """
  get_pst_tap_position_actions(crac::Crac) = _df(LibPowsybl.get_crac_pst_tap_position_actions(crac.handle))

  """
      get_generator_actions(crac::Crac) -> DataFrame

  Return the generator elementary actions of the network actions of the CRAC.
  """
  get_generator_actions(crac::Crac) = _df(LibPowsybl.get_crac_generator_actions(crac.handle))

  """
      get_load_actions(crac::Crac) -> DataFrame

  Return the load elementary actions of the network actions of the CRAC.
  """
  get_load_actions(crac::Crac) = _df(LibPowsybl.get_crac_load_actions(crac.handle))

  """
      get_boundary_line_actions(crac::Crac) -> DataFrame

  Return the boundary line elementary actions of the network actions of the CRAC.
  """
  get_boundary_line_actions(crac::Crac) = _df(LibPowsybl.get_crac_boundary_line_actions(crac.handle))

  """
      get_shunt_compensator_position_actions(crac::Crac) -> DataFrame

  Return the shunt compensator position elementary actions of the network actions of the CRAC.
  """
  get_shunt_compensator_position_actions(crac::Crac) = _df(LibPowsybl.get_crac_shunt_compensator_position_actions(crac.handle))

  """
      get_switch_actions(crac::Crac) -> DataFrame

  Return the switch elementary actions of the network actions of the CRAC.
  """
  get_switch_actions(crac::Crac) = _df(LibPowsybl.get_crac_switch_actions(crac.handle))

  """
      get_switch_pairs(crac::Crac) -> DataFrame

  Return the switch pair elementary actions of the network actions of the CRAC.
  """
  get_switch_pairs(crac::Crac) = _df(LibPowsybl.get_crac_switch_pairs(crac.handle))

  """
      get_network_element_ids_and_keys(crac::Crac) -> DataFrame

  Return the network elements referenced by the CRAC together with their keys.
  """
  get_network_element_ids_and_keys(crac::Crac) = _df(LibPowsybl.get_crac_network_element_ids_and_keys(crac.handle))

  """
      get_on_instant_usage_rules(crac::Crac) -> DataFrame

  Return the OnInstant usage rules of the remedial actions of the CRAC.
  """
  get_on_instant_usage_rules(crac::Crac) = _df(LibPowsybl.get_crac_on_instant_usage_rules(crac.handle))

  """
      get_on_contingency_state_usage_rules(crac::Crac) -> DataFrame

  Return the OnContingencyState usage rules of the remedial actions of the CRAC.
  """
  get_on_contingency_state_usage_rules(crac::Crac) = _df(LibPowsybl.get_crac_on_contingency_state_usage_rules(crac.handle))

  """
      get_on_constraint_usage_rules(crac::Crac) -> DataFrame

  Return the OnConstraint usage rules of the remedial actions of the CRAC.
  """
  get_on_constraint_usage_rules(crac::Crac) = _df(LibPowsybl.get_crac_on_constraint_usage_rules(crac.handle))

  """
      get_on_flow_constraint_in_country_usage_rules(crac::Crac) -> DataFrame

  Return the OnFlowConstraintInCountry usage rules of the remedial actions of the CRAC.
  """
  get_on_flow_constraint_in_country_usage_rules(crac::Crac) = _df(LibPowsybl.get_crac_on_flow_constraint_in_country_usage_rules(crac.handle))

  """
      get_max_remedial_actions_usage_limits(crac::Crac) -> DataFrame

  Return the global cap on the number of remedial actions per state of the CRAC.
  """
  get_max_remedial_actions_usage_limits(crac::Crac) = _df(LibPowsybl.get_crac_max_remedial_actions_usage_limits(crac.handle))

  """
      get_max_topological_actions_per_tso_usage_limits(crac::Crac) -> DataFrame

  Return the per-TSO cap on the number of topological actions of the CRAC.
  """
  get_max_topological_actions_per_tso_usage_limits(crac::Crac) = _df(LibPowsybl.get_crac_max_topological_actions_per_tso_usage_limits(crac.handle))

  """
      get_max_pst_actions_per_tso_usage_limits(crac::Crac) -> DataFrame

  Return the per-TSO cap on the number of PST actions of the CRAC.
  """
  get_max_pst_actions_per_tso_usage_limits(crac::Crac) = _df(LibPowsybl.get_crac_max_pst_actions_per_tso_usage_limits(crac.handle))

  """
      get_max_remedial_actions_per_tso_usage_limits(crac::Crac) -> DataFrame

  Return the per-TSO cap on the number of remedial actions of the CRAC.
  """
  get_max_remedial_actions_per_tso_usage_limits(crac::Crac) = _df(LibPowsybl.get_crac_max_remedial_actions_per_tso_usage_limits(crac.handle))

  """
      get_max_elementary_actions_per_tso_usage_limits(crac::Crac) -> DataFrame

  Return the per-TSO cap on the number of elementary actions of the CRAC.
  """
  get_max_elementary_actions_per_tso_usage_limits(crac::Crac) = _df(LibPowsybl.get_crac_max_elementary_actions_per_tso_usage_limits(crac.handle))

  """
      set_loopflow_glsk(rao, glsk)

  Register the GLSK used for loop-flow constraints of the RAO. Required when the CRAC or
  the parameters enable loop-flow computation.
  """
  function set_loopflow_glsk(rao::RaoContext, glsk::Glsk)
    LibPowsybl.set_rao_loopflow_glsk(rao.handle, glsk.handle)
    return nothing
  end

  """
      set_monitoring_glsk(rao, glsk)

  Register the GLSK used for monitoring computations of the RAO.
  """
  function set_monitoring_glsk(rao::RaoContext, glsk::Glsk)
    LibPowsybl.set_rao_monitoring_glsk(rao.handle, glsk.handle)
    return nothing
  end

  """
      run(rao, network, crac; parameters_file = nothing, provider = "SearchTreeRao") -> RaoResult

  Run the remedial action optimisation. With `parameters_file` (a JSON RAO parameters file)
  the given parameters are used, otherwise the provider defaults apply. `provider` selects
  the RAO implementation (e.g. `"SearchTreeRao"` or `"FastRao"`).
  """
  function run(rao::RaoContext, network::Network.NetworkHandle, crac::Crac;
               parameters_file::Union{AbstractString, Nothing} = nothing,
               provider::String = "SearchTreeRao")
    handle = parameters_file === nothing ?
      LibPowsybl.run_rao(network.handle, crac.handle, rao.handle, provider) :
      LibPowsybl.run_rao_with_parameters(network.handle, crac.handle, rao.handle,
                                         String(read(parameters_file)), provider)
    return RaoResult(handle, crac.handle)
  end

  """
      get_status(result::RaoResult) -> RaoComputationStatus

  Return the global status of the RAO run.
  """
  function get_status(result::RaoResult)
    return RaoComputationStatus(LibPowsybl.get_rao_result_status(result.handle))
  end

  _df(series_array) = Network.create_dataframe_from_series_array(series_array[])

  """
      get_flow_cnec_results(result::RaoResult) -> DataFrame

  Return the results on the flow CNECs (flow, margin, loop flow, ...) per optimized instant.
  """
  get_flow_cnec_results(result::RaoResult) =
    _df(LibPowsybl.get_rao_flow_cnec_results(result.crac, result.handle))

  """
      get_angle_cnec_results(result::RaoResult) -> DataFrame

  Return the results on the angle CNECs.
  """
  get_angle_cnec_results(result::RaoResult) =
    _df(LibPowsybl.get_rao_angle_cnec_results(result.crac, result.handle))

  """
      get_voltage_cnec_results(result::RaoResult) -> DataFrame

  Return the results on the voltage CNECs.
  """
  get_voltage_cnec_results(result::RaoResult) =
    _df(LibPowsybl.get_rao_voltage_cnec_results(result.crac, result.handle))

  """
      get_remedial_action_results(result::RaoResult) -> DataFrame

  Return the activated remedial actions per instant and contingency.
  """
  get_remedial_action_results(result::RaoResult) =
    _df(LibPowsybl.get_rao_remedial_action_results(result.crac, result.handle))

  """
      get_network_action_results(result::RaoResult) -> DataFrame

  Return the activated network (topological) actions.
  """
  get_network_action_results(result::RaoResult) =
    _df(LibPowsybl.get_rao_network_action_results(result.crac, result.handle))

  """
      get_pst_range_action_results(result::RaoResult) -> DataFrame

  Return the optimized PST range actions (their optimized tap per instant).
  """
  get_pst_range_action_results(result::RaoResult) =
    _df(LibPowsybl.get_rao_pst_range_action_results(result.crac, result.handle))

  """
      get_range_action_results(result::RaoResult) -> DataFrame

  Return the optimized range actions (their optimized set point per instant).
  """
  get_range_action_results(result::RaoResult) =
    _df(LibPowsybl.get_rao_range_action_results(result.crac, result.handle))

  """
      get_cost_results(result::RaoResult) -> DataFrame

  Return the functional and virtual cost per optimized instant.
  """
  get_cost_results(result::RaoResult) =
    _df(LibPowsybl.get_rao_cost_results(result.crac, result.handle))

  """
      get_virtual_cost_names(result::RaoResult) -> Vector{String}

  Return the names of the virtual costs tracked by the RAO result (e.g. `"loop-flow-cost"`,
  `"min-margin-violation-evaluator"`). Use these to index [`get_virtual_cost_results`](@ref).
  """
  get_virtual_cost_names(result::RaoResult) =
    String[String(name) for name in LibPowsybl.get_rao_virtual_cost_names(result.handle)]

  """
      get_virtual_cost_results(result::RaoResult, name::AbstractString) -> DataFrame

  Return the per-CNEC contributions to the named virtual cost. `name` must be one of
  [`get_virtual_cost_names`](@ref).
  """
  get_virtual_cost_results(result::RaoResult, name::AbstractString) =
    _df(LibPowsybl.get_rao_virtual_cost_results(result.crac, result.handle, String(name)))
end

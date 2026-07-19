# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

module RAO
  using ..LibPowsybl
  using ..Network
  using ..LoadFlow
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
  Objective the RAO optimises: `SECURE_FLOW`, `MAX_MIN_MARGIN`, `MAX_MIN_RELATIVE_MARGIN`
  or `MIN_COST`.
  """
  @enum ObjectiveFunctionType begin
    SECURE_FLOW = LibPowsybl.RAO_OBJ_SECURE_FLOW
    MAX_MIN_MARGIN = LibPowsybl.RAO_OBJ_MAX_MIN_MARGIN
    MAX_MIN_RELATIVE_MARGIN = LibPowsybl.RAO_OBJ_MAX_MIN_RELATIVE_MARGIN
    MIN_COST = LibPowsybl.RAO_OBJ_MIN_COST
  end

  """
  Unit the objective function is expressed in.
  """
  @enum Unit begin
    AMPERE = LibPowsybl.RAO_UNIT_AMPERE
    DEGREE = LibPowsybl.RAO_UNIT_DEGREE
    MEGAWATT = LibPowsybl.RAO_UNIT_MEGAWATT
    KILOVOLT = LibPowsybl.RAO_UNIT_KILOVOLT
    PERCENT_IMAX = LibPowsybl.RAO_UNIT_PERCENT_IMAX
    TAP = LibPowsybl.RAO_UNIT_TAP
    SECTION_COUNT = LibPowsybl.RAO_UNIT_SECTION_COUNT
  end

  """
  MILP solver used for range action optimisation.
  """
  @enum Solver begin
    CBC = LibPowsybl.RAO_SOLVER_CBC
    SCIP = LibPowsybl.RAO_SOLVER_SCIP
    XPRESS = LibPowsybl.RAO_SOLVER_XPRESS
  end

  """
  How PSTs are modelled in the MILP: `CONTINUOUS` or `APPROXIMATED_INTEGERS`.
  """
  @enum PstModel begin
    CONTINUOUS = LibPowsybl.RAO_PST_CONTINUOUS
    APPROXIMATED_INTEGERS = LibPowsybl.RAO_PST_APPROXIMATED_INTEGERS
  end

  """
  Range action range shrinking policy.
  """
  @enum RaRangeShrinking begin
    RA_RANGE_SHRINKING_DISABLED = LibPowsybl.RAO_RA_SHRINK_DISABLED
    RA_RANGE_SHRINKING_ENABLED = LibPowsybl.RAO_RA_SHRINK_ENABLED
    RA_RANGE_SHRINKING_ENABLED_IN_FIRST_PRAO_AND_CRAO = LibPowsybl.RAO_RA_SHRINK_ENABLED_IN_FIRST_PRAO_AND_CRAO
  end

  """
  Condition under which a second preventive RAO is run.
  """
  @enum ExecutionCondition begin
    EXECUTION_CONDITION_DISABLED = LibPowsybl.RAO_EXEC_DISABLED
    POSSIBLE_CURATIVE_IMPROVEMENT = LibPowsybl.RAO_EXEC_POSSIBLE_CURATIVE_IMPROVEMENT
    COST_INCREASE = LibPowsybl.RAO_EXEC_COST_INCREASE
  end

  """
  Editable RAO parameters. Build defaults with [`rao_parameters`](@ref), edit the fields,
  and pass to [`run`](@ref). The complex predefined range-action combinations and the
  nested sensitivity analysis parameters are kept at their defaults.
  """
  mutable struct RaoParameters
    objective_function_type::ObjectiveFunctionType
    unit::Unit
    enforce_curative_security::Bool
    curative_min_obj_improvement::Float64
    solver::Solver
    relative_mip_gap::Float64
    solver_specific_parameters::String
    pst_ra_min_impact_threshold::Float64
    hvdc_ra_min_impact_threshold::Float64
    injection_ra_min_impact_threshold::Float64
    max_mip_iterations::Int
    pst_sensitivity_threshold::Float64
    hvdc_sensitivity_threshold::Float64
    injection_ra_sensitivity_threshold::Float64
    pst_model::PstModel
    ra_range_shrinking::RaRangeShrinking
    max_preventive_search_tree_depth::Int
    max_curative_search_tree_depth::Int
    relative_min_impact_threshold::Float64
    absolute_min_impact_threshold::Float64
    skip_actions_far_from_most_limiting_element::Bool
    max_number_of_boundaries_for_skipping_actions::Int
    available_cpus::Int
    execution_condition::ExecutionCondition
    hint_from_first_preventive_rao::Bool
    do_not_optimize_curative_cnecs_for_tsos_without_cras::Bool
    load_flow_provider::String
    sensitivity_provider::String
    sensitivity_failure_overcost::Float64
    provider_parameters::Dict{String, String}
  end

  function _c_to_rao_parameters(c)
    keys_vec = LibPowsybl.provider_parameters_keys(c)
    values_vec = LibPowsybl.provider_parameters_values(c)
    return RaoParameters(
      ObjectiveFunctionType(LibPowsybl.objective_function_type(c)),
      Unit(LibPowsybl.unit(c)),
      LibPowsybl.enforce_curative_security(c),
      LibPowsybl.curative_min_obj_improvement(c),
      Solver(LibPowsybl.solver(c)),
      LibPowsybl.relative_mip_gap(c),
      String(LibPowsybl.solver_specific_parameters(c)),
      LibPowsybl.pst_ra_min_impact_threshold(c),
      LibPowsybl.hvdc_ra_min_impact_threshold(c),
      LibPowsybl.injection_ra_min_impact_threshold(c),
      Int(LibPowsybl.max_mip_iterations(c)),
      LibPowsybl.pst_sensitivity_threshold(c),
      LibPowsybl.hvdc_sensitivity_threshold(c),
      LibPowsybl.injection_ra_sensitivity_threshold(c),
      PstModel(LibPowsybl.pst_model(c)),
      RaRangeShrinking(LibPowsybl.ra_range_shrinking(c)),
      Int(LibPowsybl.max_preventive_search_tree_depth(c)),
      Int(LibPowsybl.max_curative_search_tree_depth(c)),
      LibPowsybl.relative_min_impact_threshold(c),
      LibPowsybl.absolute_min_impact_threshold(c),
      LibPowsybl.skip_actions_far_from_most_limiting_element(c),
      Int(LibPowsybl.max_number_of_boundaries_for_skipping_actions(c)),
      Int(LibPowsybl.available_cpus(c)),
      ExecutionCondition(LibPowsybl.execution_condition(c)),
      LibPowsybl.hint_from_first_preventive_rao(c),
      LibPowsybl.do_not_optimize_curative_cnecs_for_tsos_without_cras(c),
      String(LibPowsybl.load_flow_provider(c)),
      String(LibPowsybl.sensitivity_provider(c)),
      LibPowsybl.sensitivity_failure_overcost(c),
      Dict{String, String}(String(k) => String(v) for (k, v) in zip(keys_vec, values_vec)))
  end

  function _rao_parameters_to_c_struct(p::RaoParameters)
    c = LibPowsybl.RaoParameters()
    LibPowsybl.objective_function_type(c, LibPowsybl.RaoObjectiveFunctionType(p.objective_function_type))
    LibPowsybl.unit(c, LibPowsybl.RaoUnit(p.unit))
    LibPowsybl.enforce_curative_security(c, p.enforce_curative_security)
    LibPowsybl.curative_min_obj_improvement(c, p.curative_min_obj_improvement)
    LibPowsybl.solver(c, LibPowsybl.RaoSolver(p.solver))
    LibPowsybl.relative_mip_gap(c, p.relative_mip_gap)
    LibPowsybl.solver_specific_parameters(c, p.solver_specific_parameters)
    LibPowsybl.pst_ra_min_impact_threshold(c, p.pst_ra_min_impact_threshold)
    LibPowsybl.hvdc_ra_min_impact_threshold(c, p.hvdc_ra_min_impact_threshold)
    LibPowsybl.injection_ra_min_impact_threshold(c, p.injection_ra_min_impact_threshold)
    LibPowsybl.max_mip_iterations(c, Cint(p.max_mip_iterations))
    LibPowsybl.pst_sensitivity_threshold(c, p.pst_sensitivity_threshold)
    LibPowsybl.hvdc_sensitivity_threshold(c, p.hvdc_sensitivity_threshold)
    LibPowsybl.injection_ra_sensitivity_threshold(c, p.injection_ra_sensitivity_threshold)
    LibPowsybl.pst_model(c, LibPowsybl.RaoPstModel(p.pst_model))
    LibPowsybl.ra_range_shrinking(c, LibPowsybl.RaRangeShrinking(p.ra_range_shrinking))
    LibPowsybl.max_preventive_search_tree_depth(c, Cint(p.max_preventive_search_tree_depth))
    LibPowsybl.max_curative_search_tree_depth(c, Cint(p.max_curative_search_tree_depth))
    LibPowsybl.relative_min_impact_threshold(c, p.relative_min_impact_threshold)
    LibPowsybl.absolute_min_impact_threshold(c, p.absolute_min_impact_threshold)
    LibPowsybl.skip_actions_far_from_most_limiting_element(c, p.skip_actions_far_from_most_limiting_element)
    LibPowsybl.max_number_of_boundaries_for_skipping_actions(c, Cint(p.max_number_of_boundaries_for_skipping_actions))
    LibPowsybl.available_cpus(c, Cint(p.available_cpus))
    LibPowsybl.execution_condition(c, LibPowsybl.RaoExecutionCondition(p.execution_condition))
    LibPowsybl.hint_from_first_preventive_rao(c, p.hint_from_first_preventive_rao)
    LibPowsybl.do_not_optimize_curative_cnecs_for_tsos_without_cras(c, p.do_not_optimize_curative_cnecs_for_tsos_without_cras)
    LibPowsybl.load_flow_provider(c, p.load_flow_provider)
    LibPowsybl.sensitivity_provider(c, p.sensitivity_provider)
    LibPowsybl.sensitivity_failure_overcost(c, p.sensitivity_failure_overcost)
    LibPowsybl.provider_parameters_keys(c, StdVector{StdString}(collect(keys(p.provider_parameters))))
    LibPowsybl.provider_parameters_values(c, StdVector{StdString}(collect(values(p.provider_parameters))))
    return c
  end

  """
      rao_parameters() -> RaoParameters

  Return a fresh set of default RAO parameters, ready to be edited and passed to
  [`run`](@ref).
  """
  function rao_parameters()
    return _c_to_rao_parameters(LibPowsybl.RaoParameters())
  end

  """
      parameters_to_json(parameters::RaoParameters) -> String

  Serialize RAO parameters to a PowSyBl JSON string.
  """
  function parameters_to_json(parameters::RaoParameters)
    return String(LibPowsybl.rao_parameters_to_json(_rao_parameters_to_c_struct(parameters)))
  end

  """
      parameters_from_json(json::AbstractString) -> RaoParameters

  Deserialize RAO parameters from a PowSyBl JSON string into an editable struct.
  """
  function parameters_from_json(json::AbstractString)
    return _c_to_rao_parameters(LibPowsybl.rao_parameters_from_json(String(json)))
  end

  """
      load_parameters(parameters_file) -> RaoParameters

  Load RAO parameters from a JSON file into an editable struct.
  """
  function load_parameters(parameters_file::AbstractString)
    return parameters_from_json(String(read(parameters_file)))
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
      run(rao, network, crac; parameters = nothing, parameters_file = nothing,
          provider = "SearchTreeRao") -> RaoResult

  Run the remedial action optimisation. Provide either a [`RaoParameters`](@ref) struct
  (`parameters`) or a JSON RAO parameters file (`parameters_file`); with neither, the
  provider defaults apply. `provider` selects the RAO implementation (e.g. `"SearchTreeRao"`
  or `"FastRao"`).
  """
  function run(rao::RaoContext, network::Network.NetworkHandle, crac::Crac;
               parameters::Union{RaoParameters, Nothing} = nothing,
               parameters_file::Union{AbstractString, Nothing} = nothing,
               provider::String = "SearchTreeRao")
    parameters !== nothing && parameters_file !== nothing &&
      throw(ArgumentError("pass either `parameters` or `parameters_file`, not both"))
    handle = if parameters !== nothing
      LibPowsybl.run_rao_with_parameters_object(network.handle, crac.handle, rao.handle,
                                                _rao_parameters_to_c_struct(parameters), provider)
    elseif parameters_file !== nothing
      LibPowsybl.run_rao_with_parameters(network.handle, crac.handle, rao.handle,
                                         String(read(parameters_file)), provider)
    else
      LibPowsybl.run_rao(network.handle, crac.handle, rao.handle, provider)
    end
    return RaoResult(handle, crac.handle)
  end

  function _run_monitoring(run_fn, rao::RaoContext, network::Network.NetworkHandle, crac::Crac, result::RaoResult,
                           parameters::LoadFlow.LoadFlowParameters, provider::String, monitoring_glsk::Union{Glsk, Nothing})
    monitoring_glsk !== nothing && set_monitoring_glsk(rao, monitoring_glsk)
    c_parameters = LoadFlow.load_flow_parameters_to_c_struct(parameters)
    handle = run_fn(network.handle, result.handle, crac.handle, rao.handle, c_parameters, provider)
    return RaoResult(handle, crac.handle)
  end

  """
      run_voltage_monitoring(rao, network, crac, result; parameters = LoadFlow.load_flow_parameters(),
                             provider = "", monitoring_glsk = nothing) -> RaoResult

  Run voltage monitoring on a RAO `result`: a load flow re-evaluates the voltage CNECs and
  the (possibly voltage-constrained) remedial actions, returning an enriched result whose
  [`get_voltage_cnec_results`](@ref) reflects the monitoring. Pass a `monitoring_glsk` when
  the monitoring needs one.
  """
  function run_voltage_monitoring(rao::RaoContext, network::Network.NetworkHandle, crac::Crac, result::RaoResult;
                                  parameters::LoadFlow.LoadFlowParameters = LoadFlow.load_flow_parameters(),
                                  provider::String = "", monitoring_glsk::Union{Glsk, Nothing} = nothing)
    return _run_monitoring(LibPowsybl.run_voltage_monitoring, rao, network, crac, result, parameters, provider, monitoring_glsk)
  end

  """
      run_angle_monitoring(rao, network, crac, result; parameters = LoadFlow.load_flow_parameters(),
                           provider = "", monitoring_glsk = nothing) -> RaoResult

  Run angle monitoring on a RAO `result`, returning an enriched result whose
  [`get_angle_cnec_results`](@ref) reflects the monitoring. See [`run_voltage_monitoring`](@ref).
  """
  function run_angle_monitoring(rao::RaoContext, network::Network.NetworkHandle, crac::Crac, result::RaoResult;
                                parameters::LoadFlow.LoadFlowParameters = LoadFlow.load_flow_parameters(),
                                provider::String = "", monitoring_glsk::Union{Glsk, Nothing} = nothing)
    return _run_monitoring(LibPowsybl.run_angle_monitoring, rao, network, crac, result, parameters, provider, monitoring_glsk)
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

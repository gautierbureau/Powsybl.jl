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
  The OpenRAO search-tree ("SearchTreeRao") parameters. In pypowsybl these live in an
  optional extension: present only when a provider that uses them is configured (e.g. after
  loading a parameters JSON that carries the extension), and absent on a plain default
  `RaoParameters`. They are exposed here as an optional [`RaoParameters`](@ref) field so the
  Julia API mirrors that model.
  """
  mutable struct RaoSearchTreeParameters
    curative_min_obj_improvement::Float64
    solver::Solver
    relative_mip_gap::Float64
    solver_specific_parameters::String
    max_mip_iterations::Int
    pst_sensitivity_threshold::Float64
    hvdc_sensitivity_threshold::Float64
    injection_ra_sensitivity_threshold::Float64
    pst_model::PstModel
    ra_range_shrinking::RaRangeShrinking
    max_preventive_search_tree_depth::Int
    max_curative_search_tree_depth::Int
    predefined_combinations::Vector{Vector{String}}
    skip_actions_far_from_most_limiting_element::Bool
    max_number_of_boundaries_for_skipping_actions::Int
    available_cpus::Int
    execution_condition::ExecutionCondition
    hint_from_first_preventive_rao::Bool
    load_flow_provider::String
    sensitivity_provider::String
    sensitivity_failure_overcost::Float64
  end

  """
  Editable RAO parameters. Build defaults with [`rao_parameters`](@ref), edit the fields,
  and pass to [`run`](@ref). The OpenRAO search-tree parameters are an optional extension
  ([`RaoSearchTreeParameters`](@ref)): `nothing` on defaults, populated when loaded from a
  JSON that carries the extension.
  """
  mutable struct RaoParameters
    objective_function_type::ObjectiveFunctionType
    enforce_curative_security::Bool
    pst_ra_min_impact_threshold::Float64
    hvdc_ra_min_impact_threshold::Float64
    injection_ra_min_impact_threshold::Float64
    relative_min_impact_threshold::Float64
    absolute_min_impact_threshold::Float64
    do_not_optimize_curative_cnecs_for_tsos_without_cras::Bool
    provider_parameters::Dict{String, String}
    # Optional OpenRAO search-tree extension: `nothing` when absent, populated when present.
    search_tree_parameters::Union{Nothing, RaoSearchTreeParameters}
  end

  function _search_tree_from_c(c)
    return RaoSearchTreeParameters(
      LibPowsybl.curative_min_obj_improvement(c),
      Solver(LibPowsybl.solver(c)),
      LibPowsybl.relative_mip_gap(c),
      String(LibPowsybl.solver_specific_parameters(c)),
      Int(LibPowsybl.max_mip_iterations(c)),
      LibPowsybl.pst_sensitivity_threshold(c),
      LibPowsybl.hvdc_sensitivity_threshold(c),
      LibPowsybl.injection_ra_sensitivity_threshold(c),
      PstModel(LibPowsybl.pst_model(c)),
      RaRangeShrinking(LibPowsybl.ra_range_shrinking(c)),
      Int(LibPowsybl.max_preventive_search_tree_depth(c)),
      Int(LibPowsybl.max_curative_search_tree_depth(c)),
      Vector{String}[collect(String, split(String(group), '\t')) for group in LibPowsybl.predefined_combinations(c)],
      LibPowsybl.skip_actions_far_from_most_limiting_element(c),
      Int(LibPowsybl.max_number_of_boundaries_for_skipping_actions(c)),
      Int(LibPowsybl.available_cpus(c)),
      ExecutionCondition(LibPowsybl.execution_condition(c)),
      LibPowsybl.hint_from_first_preventive_rao(c),
      String(LibPowsybl.load_flow_provider(c)),
      String(LibPowsybl.sensitivity_provider(c)),
      LibPowsybl.sensitivity_failure_overcost(c))
  end

  function _c_to_rao_parameters(c)
    keys_vec = LibPowsybl.provider_parameters_keys(c)
    values_vec = LibPowsybl.provider_parameters_values(c)
    # The search-tree fields are only meaningful (and only initialised on the C side) when
    # the OpenRAO search-tree extension is present; otherwise expose them as `nothing`.
    search_tree = LibPowsybl.search_tree_parameters_ext(c) ? _search_tree_from_c(c) : nothing
    return RaoParameters(
      ObjectiveFunctionType(LibPowsybl.objective_function_type(c)),
      LibPowsybl.enforce_curative_security(c),
      LibPowsybl.pst_ra_min_impact_threshold(c),
      LibPowsybl.hvdc_ra_min_impact_threshold(c),
      LibPowsybl.injection_ra_min_impact_threshold(c),
      LibPowsybl.relative_min_impact_threshold(c),
      LibPowsybl.absolute_min_impact_threshold(c),
      LibPowsybl.do_not_optimize_curative_cnecs_for_tsos_without_cras(c),
      Dict{String, String}(String(k) => String(v) for (k, v) in zip(keys_vec, values_vec)),
      search_tree)
  end

  # A minimal RAO parameters JSON carrying an (empty) OpenRAO search-tree extension. Loading
  # it yields a C struct whose search-tree section — including the nested sensitivity
  # parameters — is fully initialised with OpenRAO defaults, which a bare createRaoParameters()
  # is not. We seed the write path from it whenever the parameters carry the extension, so
  # serializing / running with edited parameters does not read uninitialised memory.
  const _DEFAULT_SEARCH_TREE_JSON = "{\"version\":\"3.4\",\"extensions\":{\"open-rao-search-tree-parameters\":{}}}"

  function _rao_parameters_to_c_struct(p::RaoParameters)
    c = p.search_tree_parameters === nothing ? LibPowsybl.RaoParameters() :
        LibPowsybl.rao_parameters_from_json(_DEFAULT_SEARCH_TREE_JSON)
    LibPowsybl.objective_function_type(c, LibPowsybl.RaoObjectiveFunctionType(p.objective_function_type))
    LibPowsybl.enforce_curative_security(c, p.enforce_curative_security)
    LibPowsybl.pst_ra_min_impact_threshold(c, p.pst_ra_min_impact_threshold)
    LibPowsybl.hvdc_ra_min_impact_threshold(c, p.hvdc_ra_min_impact_threshold)
    LibPowsybl.injection_ra_min_impact_threshold(c, p.injection_ra_min_impact_threshold)
    LibPowsybl.relative_min_impact_threshold(c, p.relative_min_impact_threshold)
    LibPowsybl.absolute_min_impact_threshold(c, p.absolute_min_impact_threshold)
    LibPowsybl.do_not_optimize_curative_cnecs_for_tsos_without_cras(c, p.do_not_optimize_curative_cnecs_for_tsos_without_cras)
    LibPowsybl.provider_parameters_keys(c, StdVector{StdString}(collect(keys(p.provider_parameters))))
    LibPowsybl.provider_parameters_values(c, StdVector{StdString}(collect(values(p.provider_parameters))))
    st = p.search_tree_parameters
    LibPowsybl.search_tree_parameters_ext(c, st !== nothing)
    if st !== nothing
      LibPowsybl.curative_min_obj_improvement(c, st.curative_min_obj_improvement)
      LibPowsybl.solver(c, LibPowsybl.RaoSolver(st.solver))
      LibPowsybl.relative_mip_gap(c, st.relative_mip_gap)
      LibPowsybl.solver_specific_parameters(c, st.solver_specific_parameters)
      LibPowsybl.max_mip_iterations(c, Cint(st.max_mip_iterations))
      LibPowsybl.pst_sensitivity_threshold(c, st.pst_sensitivity_threshold)
      LibPowsybl.hvdc_sensitivity_threshold(c, st.hvdc_sensitivity_threshold)
      LibPowsybl.injection_ra_sensitivity_threshold(c, st.injection_ra_sensitivity_threshold)
      LibPowsybl.pst_model(c, LibPowsybl.RaoPstModel(st.pst_model))
      LibPowsybl.ra_range_shrinking(c, LibPowsybl.RaRangeShrinking(st.ra_range_shrinking))
      LibPowsybl.max_preventive_search_tree_depth(c, Cint(st.max_preventive_search_tree_depth))
      LibPowsybl.max_curative_search_tree_depth(c, Cint(st.max_curative_search_tree_depth))
      LibPowsybl.predefined_combinations(c, StdVector{StdString}([join(combo, '\t') for combo in st.predefined_combinations]))
      LibPowsybl.skip_actions_far_from_most_limiting_element(c, st.skip_actions_far_from_most_limiting_element)
      LibPowsybl.max_number_of_boundaries_for_skipping_actions(c, Cint(st.max_number_of_boundaries_for_skipping_actions))
      LibPowsybl.available_cpus(c, Cint(st.available_cpus))
      LibPowsybl.execution_condition(c, LibPowsybl.RaoExecutionCondition(st.execution_condition))
      LibPowsybl.hint_from_first_preventive_rao(c, st.hint_from_first_preventive_rao)
      LibPowsybl.load_flow_provider(c, st.load_flow_provider)
      LibPowsybl.sensitivity_provider(c, st.sensitivity_provider)
      LibPowsybl.sensitivity_failure_overcost(c, st.sensitivity_failure_overcost)
    end
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
end

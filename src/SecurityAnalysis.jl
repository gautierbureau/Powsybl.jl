# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

module SecurityAnalysis
  using ..LibPowsybl
  using ..Network
  using ..LoadFlow
  using DataFrames
  using CxxWrap

  """
  Computation status of a pre- or post-contingency state of a security analysis.
  """
  @enum ComputationStatus begin
    CONVERGED = LibPowsybl.POST_CONTINGENCY_CONVERGED
    MAX_ITERATION_REACHED = LibPowsybl.POST_CONTINGENCY_MAX_ITERATION_REACHED
    SOLVER_FAILED = LibPowsybl.POST_CONTINGENCY_SOLVER_FAILED
    FAILED = LibPowsybl.POST_CONTINGENCY_FAILED
    NO_IMPACT = LibPowsybl.POST_CONTINGENCY_NO_IMPACT
  end

  """
  Defines for which contingencies a monitored element is observed:
  `ALL` (base case and every contingency), `NONE`, `SPECIFIC` (the listed
  contingencies), or `ONLY_CONTINGENCIES`.
  """
  @enum ContingencyContextType begin
    ALL = LibPowsybl.CONTINGENCY_CONTEXT_ALL
    NONE = LibPowsybl.CONTINGENCY_CONTEXT_NONE
    SPECIFIC = LibPowsybl.CONTINGENCY_CONTEXT_SPECIFIC
    ONLY_CONTINGENCIES = LibPowsybl.CONTINGENCY_CONTEXT_ONLY_CONTINGENCIES
  end

  """
  A security analysis context: it collects the contingencies and monitored elements
  to analyse before being run against a network.
  """
  mutable struct SecurityAnalysisContext
    handle::LibPowsybl.JavaHandle
  end

  """
  The result of a security analysis run. Query it through `get_limit_violations`,
  `get_pre_contingency_result`, `get_post_contingency_results` and the monitored
  element result accessors.
  """
  mutable struct Result
    handle::LibPowsybl.JavaHandle
  end

  """
      create() -> SecurityAnalysisContext

  Create an empty security analysis context.
  """
  function create()
    return SecurityAnalysisContext(LibPowsybl.create_security_analysis())
  end

  """
      add_single_element_contingency(analysis, element_id[, contingency_id])

  Add a contingency tripping a single element. When omitted, the contingency id
  defaults to the element id.
  """
  function add_single_element_contingency(analysis::SecurityAnalysisContext, element_id::String, contingency_id::String = element_id)
    LibPowsybl.add_contingency(analysis.handle, contingency_id, StdVector{StdString}([element_id]))
    return nothing
  end

  """
      add_multiple_elements_contingency(analysis, elements_ids, contingency_id)

  Add a contingency tripping several elements simultaneously (an N-k contingency).
  """
  function add_multiple_elements_contingency(analysis::SecurityAnalysisContext, elements_ids::Vector{String}, contingency_id::String)
    LibPowsybl.add_contingency(analysis.handle, contingency_id, StdVector{StdString}(elements_ids))
    return nothing
  end

  """
      add_single_element_contingencies(analysis, elements_ids)

  Convenience helper adding one single-element contingency per element id.
  """
  function add_single_element_contingencies(analysis::SecurityAnalysisContext, elements_ids::Vector{String})
    for element_id in elements_ids
      add_single_element_contingency(analysis, element_id)
    end
    return nothing
  end

  """
      add_monitored_elements(analysis; contingency_context_type = ALL, branch_ids,
                             voltage_level_ids, three_windings_transformer_ids,
                             contingency_ids)

  Register elements whose detailed results (flows, voltages) should be collected during
  the analysis. `contingency_context_type` selects the states in which they are
  monitored; `contingency_ids` restricts a `SPECIFIC` context to the given contingencies.
  """
  function add_monitored_elements(analysis::SecurityAnalysisContext;
                                  contingency_context_type::ContingencyContextType = ALL,
                                  branch_ids::Vector{String} = String[],
                                  voltage_level_ids::Vector{String} = String[],
                                  three_windings_transformer_ids::Vector{String} = String[],
                                  contingency_ids::Vector{String} = String[])
    LibPowsybl.add_monitored_elements(analysis.handle,
                                      LibPowsybl.ContingencyContextType(contingency_context_type),
                                      StdVector{StdString}(branch_ids),
                                      StdVector{StdString}(voltage_level_ids),
                                      StdVector{StdString}(three_windings_transformer_ids),
                                      StdVector{StdString}(contingency_ids))
    return nothing
  end

  function _run(analysis::SecurityAnalysisContext, network::Network.NetworkHandle,
                parameters::LoadFlow.LoadFlowParameters, provider::String, dc::Bool, report)
    c_parameters = LoadFlow.load_flow_parameters_to_c_struct(parameters)
    handle = report === nothing ?
      LibPowsybl.run_security_analysis(analysis.handle, network.handle, c_parameters, provider, dc) :
      LibPowsybl.run_security_analysis_report(analysis.handle, network.handle, c_parameters, provider, dc, report.handle)
    return Result(handle)
  end

  """
      run_ac(analysis, network[, parameters[, provider]]; report = nothing) -> Result

  Run the security analysis in AC. Security-analysis-specific limit thresholds keep their
  default values; `parameters` are the load flow parameters used for the base case and
  every contingency. Pass a `Powsybl.Report.ReportNode` as `report` to collect the
  functional logs.
  """
  function run_ac(analysis::SecurityAnalysisContext, network::Network.NetworkHandle,
                  parameters::LoadFlow.LoadFlowParameters = LoadFlow.load_flow_parameters(), provider::String = "";
                  report = nothing)
    return _run(analysis, network, parameters, provider, false, report)
  end

  """
      run_dc(analysis, network[, parameters[, provider]]; report = nothing) -> Result

  Run the security analysis in DC. See [`run_ac`](@ref).
  """
  function run_dc(analysis::SecurityAnalysisContext, network::Network.NetworkHandle,
                  parameters::LoadFlow.LoadFlowParameters = LoadFlow.load_flow_parameters(), provider::String = "";
                  report = nothing)
    return _run(analysis, network, parameters, provider, true, report)
  end

  """
      get_limit_violations(result::Result) -> DataFrame

  Return, as a DataFrame, all the limit violations detected in the base case and in each
  contingency (indexed by `contingency_id`, empty for the pre-contingency state).
  """
  function get_limit_violations(result::Result)
    series_array = LibPowsybl.get_security_analysis_limit_violations(result.handle)
    return Network.create_dataframe_from_series_array(series_array[])
  end

  """
      get_branch_results(result::Result) -> DataFrame

  Return the results on the monitored branches.
  """
  function get_branch_results(result::Result)
    series_array = LibPowsybl.get_security_analysis_branch_results(result.handle)
    return Network.create_dataframe_from_series_array(series_array[])
  end

  """
      get_bus_results(result::Result) -> DataFrame

  Return the results on the monitored buses.
  """
  function get_bus_results(result::Result)
    series_array = LibPowsybl.get_security_analysis_bus_results(result.handle)
    return Network.create_dataframe_from_series_array(series_array[])
  end

  """
      get_three_windings_transformer_results(result::Result) -> DataFrame

  Return the results on the monitored three windings transformers.
  """
  function get_three_windings_transformer_results(result::Result)
    series_array = LibPowsybl.get_security_analysis_three_windings_transformer_results(result.handle)
    return Network.create_dataframe_from_series_array(series_array[])
  end

  """
      get_pre_contingency_result(result::Result) -> ComputationStatus

  Return the computation status of the pre-contingency (base case) state.
  """
  function get_pre_contingency_result(result::Result)
    pre = LibPowsybl.get_pre_contingency_result(result.handle)
    return ComputationStatus(LibPowsybl.status(pre[]))
  end

  """
      get_post_contingency_results(result::Result) -> DataFrame

  Return a DataFrame with the computation status of each contingency
  (columns `contingency_id`, `status`).
  """
  function get_post_contingency_results(result::Result)
    c_results = LibPowsybl.get_post_contingency_results(result.handle)
    df = DataFrame()
    df[!, "contingency_id"] = [String(LibPowsybl.contingency_id(post_result)) for post_result in c_results]
    df[!, "status"] = [ComputationStatus(LibPowsybl.status(post_result)) for post_result in c_results]
    return df
  end

  """
      get_provider_names() -> Vector{String}

  Return the names of the available security analysis providers.
  """
  function get_provider_names()
    return [String(name) for name in LibPowsybl.get_security_analysis_provider_names()]
  end
end

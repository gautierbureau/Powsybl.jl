# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

module SensitivityAnalysis
  using ..LibPowsybl
  using ..Network
  using ..LoadFlow
  using CxxWrap

  """
  The kind of monitored quantity a sensitivity factor is computed on (the "function").
  """
  @enum SensitivityFunctionType begin
    BRANCH_ACTIVE_POWER_1 = 0
    BRANCH_CURRENT_1 = 1
    BRANCH_REACTIVE_POWER_1 = 2
    BRANCH_ACTIVE_POWER_2 = 3
    BRANCH_CURRENT_2 = 4
    BRANCH_REACTIVE_POWER_2 = 5
    BRANCH_ACTIVE_POWER_3 = 6
    BRANCH_CURRENT_3 = 7
    BRANCH_REACTIVE_POWER_3 = 8
    BUS_REACTIVE_POWER = 9
    BUS_VOLTAGE = 10
  end

  """
  The kind of variable a sensitivity factor is computed against. `AUTO_DETECT` lets
  PowSyBl infer the variable type from the element id.
  """
  @enum SensitivityVariableType begin
    AUTO_DETECT = 0
    INJECTION_ACTIVE_POWER = 1
    INJECTION_REACTIVE_POWER = 2
    TRANSFORMER_PHASE = 3
    BUS_TARGET_VOLTAGE = 4
    HVDC_LINE_ACTIVE_POWER = 5
    TRANSFORMER_PHASE_1 = 6
    TRANSFORMER_PHASE_2 = 7
    TRANSFORMER_PHASE_3 = 8
  end

  """
  Selects for which contingencies a factor matrix is evaluated.
  """
  @enum ContingencyContextType begin
    ALL = 0
    NONE = 1
    SPECIFIC = 2
    ONLY_CONTINGENCIES = 3
  end

  """
  A sensitivity analysis context: it collects factor matrices (and optionally
  contingencies) to evaluate before being run against a network.
  """
  mutable struct SensitivityAnalysisContext
    handle::LibPowsybl.JavaHandle
  end

  """
  The result of a sensitivity analysis run. Query it through `get_sensitivity_matrix`
  and `get_reference_matrix`.
  """
  mutable struct Result
    handle::LibPowsybl.JavaHandle
  end

  """
      create() -> SensitivityAnalysisContext

  Create an empty sensitivity analysis context.
  """
  function create()
    return SensitivityAnalysisContext(LibPowsybl.create_sensitivity_analysis())
  end

  """
      add_single_element_contingency(analysis, element_id[, contingency_id])

  Add a contingency tripping a single element (used to compute post-contingency
  sensitivities). Defaults the contingency id to the element id.
  """
  function add_single_element_contingency(analysis::SensitivityAnalysisContext, element_id::String, contingency_id::String = element_id)
    LibPowsybl.add_sensitivity_contingency(analysis.handle, contingency_id, StdVector{StdString}([element_id]))
    return nothing
  end

  """
      add_multiple_elements_contingency(analysis, elements_ids, contingency_id)

  Add a contingency tripping several elements simultaneously.
  """
  function add_multiple_elements_contingency(analysis::SensitivityAnalysisContext, elements_ids::Vector{String}, contingency_id::String)
    LibPowsybl.add_sensitivity_contingency(analysis.handle, contingency_id, StdVector{StdString}(elements_ids))
    return nothing
  end

  """
      add_factor_matrix(analysis, function_ids, variable_ids; matrix_id, contingencies_ids,
                        contingency_context_type, sensitivity_function_type,
                        sensitivity_variable_type)

  Register a factor matrix: sensitivities of each monitored quantity in `function_ids`
  (e.g. branch ids) with respect to each variable in `variable_ids` (e.g. injections).
  The matrix is retrieved after the run via its `matrix_id` (default `"default"`).
  """
  function add_factor_matrix(analysis::SensitivityAnalysisContext, function_ids::Vector{String}, variable_ids::Vector{String};
                             matrix_id::String = "default",
                             contingencies_ids::Vector{String} = String[],
                             contingency_context_type::ContingencyContextType = ALL,
                             sensitivity_function_type::SensitivityFunctionType = BRANCH_ACTIVE_POWER_1,
                             sensitivity_variable_type::SensitivityVariableType = AUTO_DETECT)
    LibPowsybl.add_factor_matrix(analysis.handle, matrix_id,
                                 StdVector{StdString}(function_ids),
                                 StdVector{StdString}(variable_ids),
                                 StdVector{StdString}(contingencies_ids),
                                 Int32(contingency_context_type),
                                 Int32(sensitivity_function_type),
                                 Int32(sensitivity_variable_type))
    return nothing
  end

  """
      set_branch_flow_factor_matrix(analysis, branch_ids, variable_ids; matrix_id = "default")

  Convenience helper registering a branch active power (side 1) factor matrix — the most
  common case, producing PTDF-like sensitivities.
  """
  function set_branch_flow_factor_matrix(analysis::SensitivityAnalysisContext, branch_ids::Vector{String}, variable_ids::Vector{String};
                                         matrix_id::String = "default")
    return add_factor_matrix(analysis, branch_ids, variable_ids;
                             matrix_id = matrix_id,
                             sensitivity_function_type = BRANCH_ACTIVE_POWER_1,
                             sensitivity_variable_type = AUTO_DETECT)
  end

  function _run(analysis::SensitivityAnalysisContext, network::Network.NetworkHandle, dc::Bool,
                parameters::LoadFlow.LoadFlowParameters, provider::String, report)
    c_parameters = LoadFlow.load_flow_parameters_to_c_struct(parameters)
    handle = report === nothing ?
      LibPowsybl.run_sensitivity_analysis(analysis.handle, network.handle, dc, c_parameters, provider) :
      LibPowsybl.run_sensitivity_analysis_report(analysis.handle, network.handle, dc, c_parameters, provider, report.handle)
    return Result(handle)
  end

  """
      run_ac(analysis, network[, parameters[, provider]]; report = nothing) -> Result

  Run the sensitivity analysis in AC. Pass a `Powsybl.Report.ReportNode` as `report` to
  collect the functional logs.
  """
  function run_ac(analysis::SensitivityAnalysisContext, network::Network.NetworkHandle,
                  parameters::LoadFlow.LoadFlowParameters = LoadFlow.load_flow_parameters(), provider::String = "";
                  report = nothing)
    return _run(analysis, network, false, parameters, provider, report)
  end

  """
      run_dc(analysis, network[, parameters[, provider]]; report = nothing) -> Result

  Run the sensitivity analysis in DC (the usual mode for PTDF computations). See
  [`run_ac`](@ref).
  """
  function run_dc(analysis::SensitivityAnalysisContext, network::Network.NetworkHandle,
                  parameters::LoadFlow.LoadFlowParameters = LoadFlow.load_flow_parameters(), provider::String = "";
                  report = nothing)
    return _run(analysis, network, true, parameters, provider, report)
  end

  function _matrix_to_julia(m)
    row_count = LibPowsybl.row_count(m)
    column_count = LibPowsybl.column_count(m)
    # The C matrix is row-major; reshape column-major then transpose to recover it.
    values = collect(Float64, LibPowsybl.matrix_values(m))
    return permutedims(reshape(values, column_count, row_count))
  end

  """
      get_sensitivity_matrix(result[, matrix_id[, contingency_id]]) -> Matrix{Float64}

  Return the sensitivity values of a factor matrix (default `matrix_id = "default"`) for
  a given contingency (empty id for the pre-contingency / base case).
  """
  function get_sensitivity_matrix(result::Result, matrix_id::String = "default", contingency_id::String = "")
    m = LibPowsybl.get_sensitivity_matrix(result.handle, matrix_id, contingency_id)
    return _matrix_to_julia(m[])
  end

  """
      get_reference_matrix(result[, matrix_id[, contingency_id]]) -> Matrix{Float64}

  Return the reference (function) values of a factor matrix — e.g. the base-case branch
  flows the sensitivities are computed around.
  """
  function get_reference_matrix(result::Result, matrix_id::String = "default", contingency_id::String = "")
    m = LibPowsybl.get_reference_matrix(result.handle, matrix_id, contingency_id)
    return _matrix_to_julia(m[])
  end

  """
      get_provider_names() -> Vector{String}

  Return the names of the available sensitivity analysis providers.
  """
  function get_provider_names()
    return [String(name) for name in LibPowsybl.get_sensitivity_analysis_provider_names()]
  end
end

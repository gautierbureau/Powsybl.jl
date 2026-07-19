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
end

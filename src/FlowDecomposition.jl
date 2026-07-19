# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

module FlowDecomposition
  using ..LibPowsybl
  using ..Network
  using ..LoadFlow
  using CxxWrap

  """
  How the decomposed flows are rescaled onto the reference AC flow: `NONE`,
  `ACER_METHODOLOGY`, `PROPORTIONAL` or `MAX_CURRENT_OVERLOAD`.
  """
  @enum RescaleMode begin
    NONE = LibPowsybl.RESCALE_NONE
    ACER_METHODOLOGY = LibPowsybl.RESCALE_ACER_METHODOLOGY
    PROPORTIONAL = LibPowsybl.RESCALE_PROPORTIONAL
    MAX_CURRENT_OVERLOAD = LibPowsybl.RESCALE_MAX_CURRENT_OVERLOAD
  end

  """
  A flow decomposition context, created with [`create`](@ref). Add the contingencies and
  monitored elements (XNECs) to decompose, then call [`run`](@ref).
  """
  mutable struct FlowDecompositionContext
    handle::LibPowsybl.JavaHandle
  end

  """
  Editable flow decomposition parameters. Build defaults with `Parameters()`, edit the
  fields, and pass to [`run`](@ref).
  """
  mutable struct Parameters
    enable_losses_compensation::Bool
    losses_compensation_epsilon::Float32
    sensitivity_epsilon::Float32
    rescale_mode::RescaleMode
    dc_fallback_enabled_after_ac_divergence::Bool
    sensitivity_variable_batch_size::Int
  end

  function _c_to_parameters(c)
    return Parameters(
      LibPowsybl.enable_losses_compensation(c),
      LibPowsybl.losses_compensation_epsilon(c),
      LibPowsybl.sensitivity_epsilon(c),
      RescaleMode(LibPowsybl.rescale_mode(c)),
      LibPowsybl.dc_fallback_enabled_after_ac_divergence(c),
      Int(LibPowsybl.sensitivity_variable_batch_size(c)))
  end

  function _parameters_to_c(p::Parameters)
    c = LibPowsybl.FlowDecompositionParameters()
    LibPowsybl.enable_losses_compensation(c, p.enable_losses_compensation)
    LibPowsybl.losses_compensation_epsilon(c, Cfloat(p.losses_compensation_epsilon))
    LibPowsybl.sensitivity_epsilon(c, Cfloat(p.sensitivity_epsilon))
    LibPowsybl.rescale_mode(c, LibPowsybl.RescaleMode(p.rescale_mode))
    LibPowsybl.dc_fallback_enabled_after_ac_divergence(c, p.dc_fallback_enabled_after_ac_divergence)
    LibPowsybl.sensitivity_variable_batch_size(c, Cint(p.sensitivity_variable_batch_size))
    return c
  end

  """
      Parameters() -> Parameters

  Return a fresh set of default flow decomposition parameters, ready to be edited.
  """
  Parameters() = _c_to_parameters(LibPowsybl.FlowDecompositionParameters())

  """
      create() -> FlowDecompositionContext

  Create an empty flow decomposition context.
  """
  create() = FlowDecompositionContext(LibPowsybl.create_flow_decomposition())

  _strings(ids::AbstractString) = StdVector{StdString}([String(ids)])
  _strings(ids::AbstractVector{<:AbstractString}) = StdVector{StdString}(String.(ids))

  """
      add_single_element_contingency(context, element_id; contingency_id = element_id)

  Add a contingency tripping the single network element `element_id`.
  """
  function add_single_element_contingency(context::FlowDecompositionContext, element_id::AbstractString;
                                          contingency_id::AbstractString = element_id)
    LibPowsybl.add_contingency_for_flow_decomposition(context.handle, String(contingency_id), _strings(element_id))
    return context
  end

  """
      add_multiple_elements_contingency(context, elements_ids; contingency_id)

  Add a contingency `contingency_id` tripping all of `elements_ids` at once.
  """
  function add_multiple_elements_contingency(context::FlowDecompositionContext,
                                             elements_ids::AbstractVector{<:AbstractString};
                                             contingency_id::AbstractString)
    LibPowsybl.add_contingency_for_flow_decomposition(context.handle, String(contingency_id), _strings(elements_ids))
    return context
  end

  """
      add_precontingency_monitored_elements(context, branch_ids)

  Monitor `branch_ids` on the pre-contingency (N) state — creates an XNE per branch.
  """
  function add_precontingency_monitored_elements(context::FlowDecompositionContext,
                                                 branch_ids::Union{AbstractString, AbstractVector{<:AbstractString}})
    LibPowsybl.add_precontingency_monitored_elements_for_flow_decomposition(context.handle, _strings(branch_ids))
    return context
  end

  """
      add_postcontingency_monitored_elements(context, branch_ids, contingency_ids)

  Monitor `branch_ids` on each post-contingency state in `contingency_ids` — creates an
  XNEC per valid (branch, contingency) pair. Create the contingencies first.
  """
  function add_postcontingency_monitored_elements(context::FlowDecompositionContext,
                                                  branch_ids::Union{AbstractString, AbstractVector{<:AbstractString}},
                                                  contingency_ids::Union{AbstractString, AbstractVector{<:AbstractString}})
    LibPowsybl.add_postcontingency_monitored_elements_for_flow_decomposition(context.handle, _strings(branch_ids), _strings(contingency_ids))
    return context
  end

  """
      add_monitored_elements(context, branch_ids; contingency_ids = String[])

  Monitor `branch_ids` on the pre-contingency state and, when `contingency_ids` is given,
  on each of those post-contingency states as well.
  """
  function add_monitored_elements(context::FlowDecompositionContext,
                                  branch_ids::Union{AbstractString, AbstractVector{<:AbstractString}};
                                  contingency_ids::Union{AbstractString, AbstractVector{<:AbstractString}} = String[])
    if !isempty(contingency_ids)
      add_postcontingency_monitored_elements(context, branch_ids, contingency_ids)
    end
    add_precontingency_monitored_elements(context, branch_ids)
    return context
  end

  """
      add_5perc_ptdf_as_monitored_elements(context)

  Monitor the branches whose zone-to-zone PTDF exceeds 5% (or that are interconnections).
  """
  function add_5perc_ptdf_as_monitored_elements(context::FlowDecompositionContext)
    LibPowsybl.add_additional_xnec_provider_for_flow_decomposition(context.handle, LibPowsybl.XNEC_GT_5_PERC_ZONE_TO_ZONE_PTDF)
    return context
  end

  """
      add_interconnections_as_monitored_elements(context)

  Monitor all interconnection branches.
  """
  function add_interconnections_as_monitored_elements(context::FlowDecompositionContext)
    LibPowsybl.add_additional_xnec_provider_for_flow_decomposition(context.handle, LibPowsybl.XNEC_INTERCONNECTIONS)
    return context
  end

  """
      add_all_branches_as_monitored_elements(context)

  Monitor every branch of the network on the pre-contingency state.
  """
  function add_all_branches_as_monitored_elements(context::FlowDecompositionContext)
    LibPowsybl.add_additional_xnec_provider_for_flow_decomposition(context.handle, LibPowsybl.XNEC_ALL_BRANCHES)
    return context
  end

  """
      run(context, network; parameters = Parameters(), load_flow_parameters = LoadFlow.load_flow_parameters()) -> DataFrame

  Run the flow decomposition and return the decomposed flows (allocated, loop, PST, ... per
  monitored element) as a DataFrame.

  Note: with `parameters.enable_losses_compensation = true` the run mutates `network` by
  adding fictitious loss loads, so reload the network before running again with losses
  compensation enabled.
  """
  function run(context::FlowDecompositionContext, network::Network.NetworkHandle;
               parameters::Parameters = Parameters(),
               load_flow_parameters::LoadFlow.LoadFlowParameters = LoadFlow.load_flow_parameters())
    series = LibPowsybl.run_flow_decomposition(context.handle, network.handle,
               _parameters_to_c(parameters),
               LoadFlow.load_flow_parameters_to_c_struct(load_flow_parameters))
    return Network.create_dataframe_from_series_array(series[])
  end
end

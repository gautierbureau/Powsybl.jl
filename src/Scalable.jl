# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

module Scalable
  using ..LibPowsybl
  using ..Network
  using CxxWrap

  """
  How an asked scaling variation is interpreted: `DELTA_P` (a change) or `TARGET_P`
  (an absolute target).
  """
  @enum ScalingType begin
    DELTA_P = LibPowsybl.DELTA_P
    TARGET_P = LibPowsybl.TARGET_P
  end

  """
  What is respected when the asked volume cannot be fully distributed:
  `RESPECT_OF_VOLUME_ASKED`, `RESPECT_OF_DISTRIBUTION` or `ONESHOT`.
  """
  @enum Priority begin
    RESPECT_OF_VOLUME_ASKED = LibPowsybl.RESPECT_OF_VOLUME_ASKED
    RESPECT_OF_DISTRIBUTION = LibPowsybl.RESPECT_OF_DISTRIBUTION
    ONESHOT = LibPowsybl.ONESHOT
  end

  """
  Sign convention: a positive scaling either increases generation
  (`GENERATOR_SCALING_CONVENTION`) or increases load (`LOAD_SCALING_CONVENTION`).
  """
  @enum ScalingConvention begin
    GENERATOR_SCALING_CONVENTION = LibPowsybl.GENERATOR_SCALING_CONVENTION
    LOAD_SCALING_CONVENTION = LibPowsybl.LOAD_SCALING_CONVENTION
  end

  """
  How a proportional scalable distributes a variation across its injections.
  """
  @enum DistributionMode begin
    PROPORTIONAL_TO_TARGETP = LibPowsybl.PROPORTIONAL_TO_TARGETP
    PROPORTIONAL_TO_PMAX = LibPowsybl.PROPORTIONAL_TO_PMAX
    PROPORTIONAL_TO_DIFF_PMAX_TARGETP = LibPowsybl.PROPORTIONAL_TO_DIFF_PMAX_TARGETP
    PROPORTIONAL_TO_DIFF_TARGETP_PMIN = LibPowsybl.PROPORTIONAL_TO_DIFF_TARGETP_PMIN
    PROPORTIONAL_TO_P0 = LibPowsybl.PROPORTIONAL_TO_P0
    UNIFORM_DISTRIBUTION = LibPowsybl.UNIFORM_DISTRIBUTION
  end

  # JavaScalableType tags (mirrors the Java Scalable hierarchy).
  const _ELEMENT = 0
  const _STACK = 1
  const _PROPORTIONAL = 2
  const _UP_DOWN = 3

  """
  A scalable: a rule for distributing an active-power variation across one or more
  injections. Build one with [`injection`](@ref), [`stack`](@ref), [`proportional`](@ref)
  or [`up_down`](@ref), then apply it with [`scale`](@ref).
  """
  mutable struct ScalableModel
    handle::LibPowsybl.JavaHandle
  end

  function _handles(children)
    v = LibPowsybl.JavaHandleVector()
    for c in children
      LibPowsybl.push_handle(v, c.handle)
    end
    return v
  end

  _create(type, id, min_value, max_value, children, percentages) =
    ScalableModel(LibPowsybl.create_scalable(type, String(id), Float64(min_value), Float64(max_value),
                                             _handles(children), StdVector{Float64}(Float64.(percentages))))

  """
      injection(injection_id; min_value = -Inf, max_value = Inf) -> ScalableModel

  A scalable acting on a single injection (generator or load).
  """
  injection(injection_id::AbstractString; min_value::Real = -Inf, max_value::Real = Inf) =
    _create(_ELEMENT, injection_id, min_value, max_value, ScalableModel[], Float64[])

  """
      stack(children...; min_value = -Inf, max_value = Inf) -> ScalableModel

  A scalable that fills each child in turn (up to its own bounds) before moving to the next.
  """
  stack(children::ScalableModel...; min_value::Real = -Inf, max_value::Real = Inf) =
    _create(_STACK, "", min_value, max_value, collect(children), Float64[])

  """
      proportional(children, percentages; min_value = -Inf, max_value = Inf) -> ScalableModel

  A scalable that splits the variation across its children by the given percentages
  (which should sum to 100).
  """
  proportional(children::AbstractVector{ScalableModel}, percentages::AbstractVector{<:Real};
               min_value::Real = -Inf, max_value::Real = Inf) =
    _create(_PROPORTIONAL, "", min_value, max_value, children, percentages)

  """
      up_down(up, down; min_value = -Inf, max_value = Inf) -> ScalableModel

  A scalable using `up` for positive variations and `down` for negative ones.
  """
  up_down(up::ScalableModel, down::ScalableModel; min_value::Real = -Inf, max_value::Real = Inf) =
    _create(_UP_DOWN, "", min_value, max_value, [up, down], Float64[])

  """
  Parameters controlling how a [`scale`](@ref) is applied. Build defaults with
  `ScalingParameters()` and edit the fields.
  """
  mutable struct ScalingParameters
    scaling_convention::ScalingConvention
    constant_power_factor::Bool
    reconnect::Bool
    allows_generator_out_of_active_power_limits::Bool
    priority::Priority
    scaling_type::ScalingType
    ignored_injection_ids::Vector{String}
  end

  function _c_to_parameters(c)
    return ScalingParameters(
      ScalingConvention(LibPowsybl.scaling_convention(c)),
      LibPowsybl.constant_power_factor(c),
      LibPowsybl.reconnect(c),
      LibPowsybl.allows_generator_out_of_active_power_limits(c),
      Priority(LibPowsybl.priority(c)),
      ScalingType(LibPowsybl.scaling_type(c)),
      String[String(s) for s in LibPowsybl.ignored_injection_ids(c)])
  end

  function _parameters_to_c(p::ScalingParameters)
    c = LibPowsybl.ScalingParameters()
    LibPowsybl.scaling_convention(c, LibPowsybl.ScalingConvention(p.scaling_convention))
    LibPowsybl.constant_power_factor(c, p.constant_power_factor)
    LibPowsybl.reconnect(c, p.reconnect)
    LibPowsybl.allows_generator_out_of_active_power_limits(c, p.allows_generator_out_of_active_power_limits)
    LibPowsybl.priority(c, LibPowsybl.ScalingPriority(p.priority))
    LibPowsybl.scaling_type(c, LibPowsybl.ScalingType(p.scaling_type))
    LibPowsybl.ignored_injection_ids(c, StdVector{StdString}(String.(p.ignored_injection_ids)))
    return c
  end

  """
      ScalingParameters() -> ScalingParameters

  Return a fresh set of default scaling parameters, ready to be edited.
  """
  ScalingParameters() = _c_to_parameters(LibPowsybl.ScalingParameters())

  """
      scale(scalable, network, asked; parameters = ScalingParameters()) -> Float64

  Apply the active-power variation `asked` to `network` through `scalable`, returning the
  amount actually applied (which may be smaller when injection limits are reached).
  """
  function scale(scalable::ScalableModel, network::Network.NetworkHandle, asked::Real;
                 parameters::ScalingParameters = ScalingParameters())
    return LibPowsybl.scale(network.handle, scalable.handle, _parameters_to_c(parameters), Float64(asked))
  end

  """
      compute_proportional_percentages(injection_ids, network, mode) -> Vector{Float64}

  Compute the proportional distribution keys (percentages summing to 100) for a set of
  injections under the given [`DistributionMode`](@ref), from the current network state.
  """
  function compute_proportional_percentages(injection_ids::AbstractVector{<:AbstractString},
                                            network::Network.NetworkHandle, mode::DistributionMode)
    return Float64[Float64(f) for f in
      LibPowsybl.compute_proportional_scalable_percentages(StdVector{StdString}(String.(injection_ids)),
                                                           LibPowsybl.DistributionMode(mode), network.handle)]
  end
end

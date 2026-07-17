# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

module Diagram
  using ..LibPowsybl
  using ..Network
  using CxxWrap

  # ---------------------------------------------------------------------------
  # Single line diagram (SLD)
  # ---------------------------------------------------------------------------

  """
      get_single_line_diagram_svg(network, container_id) -> String

  Return the single line diagram of a voltage level or substation (identified by
  `container_id`) as an SVG string.
  """
  function get_single_line_diagram_svg(network::Network.NetworkHandle, container_id::String)
    return String(LibPowsybl.get_single_line_diagram_svg(network.handle, container_id))
  end

  """
      write_single_line_diagram_svg(network, container_id, svg_file; metadata_file = "")

  Write the single line diagram of a voltage level or substation to `svg_file`.
  When `metadata_file` is non-empty, the diagram metadata is written there too.
  """
  function write_single_line_diagram_svg(network::Network.NetworkHandle, container_id::String, svg_file::String;
                                         metadata_file::String = "")
    LibPowsybl.write_single_line_diagram_svg(network.handle, container_id, svg_file, metadata_file)
    return nothing
  end

  """
      get_single_line_diagram_component_library_names() -> Vector{String}

  Return the names of the available single line diagram component libraries.
  """
  function get_single_line_diagram_component_library_names()
    return [String(name) for name in LibPowsybl.get_single_line_diagram_component_library_names()]
  end

  # ---------------------------------------------------------------------------
  # Network area diagram (NAD)
  # ---------------------------------------------------------------------------

  """
      get_network_area_diagram_svg(network; voltage_level_ids = String[], depth = 0,
                                   high_nominal_voltage_bound = -1.0,
                                   low_nominal_voltage_bound = -1.0) -> String

  Return the network area diagram as an SVG string. With an empty `voltage_level_ids`
  the whole network is drawn; otherwise the diagram is centered on the given voltage
  levels and expanded by `depth` hops. The nominal voltage bounds (`-1.0` meaning no
  bound) filter the displayed voltage levels.
  """
  function get_network_area_diagram_svg(network::Network.NetworkHandle;
                                        voltage_level_ids::Vector{String} = String[],
                                        depth::Integer = 0,
                                        high_nominal_voltage_bound::Float64 = -1.0,
                                        low_nominal_voltage_bound::Float64 = -1.0)
    return String(LibPowsybl.get_network_area_diagram_svg(network.handle,
                                                          StdVector{StdString}(voltage_level_ids),
                                                          Int32(depth),
                                                          high_nominal_voltage_bound,
                                                          low_nominal_voltage_bound))
  end

  """
      write_network_area_diagram_svg(network, svg_file; voltage_level_ids = String[],
                                     depth = 0, high_nominal_voltage_bound = -1.0,
                                     low_nominal_voltage_bound = -1.0, metadata_file = "")

  Write the network area diagram to `svg_file`. See [`get_network_area_diagram_svg`](@ref)
  for the meaning of the arguments.
  """
  function write_network_area_diagram_svg(network::Network.NetworkHandle, svg_file::String;
                                          voltage_level_ids::Vector{String} = String[],
                                          depth::Integer = 0,
                                          high_nominal_voltage_bound::Float64 = -1.0,
                                          low_nominal_voltage_bound::Float64 = -1.0,
                                          metadata_file::String = "")
    LibPowsybl.write_network_area_diagram_svg(network.handle, svg_file, metadata_file,
                                              StdVector{StdString}(voltage_level_ids),
                                              Int32(depth),
                                              high_nominal_voltage_bound,
                                              low_nominal_voltage_bound)
    return nothing
  end

  """
      get_network_area_diagram_displayed_voltage_levels(network, voltage_level_ids, depth = 0) -> Vector{String}

  Return the ids of the voltage levels that would be displayed in a network area diagram
  centered on `voltage_level_ids` and expanded by `depth` hops.
  """
  function get_network_area_diagram_displayed_voltage_levels(network::Network.NetworkHandle,
                                                             voltage_level_ids::Vector{String}, depth::Integer = 0)
    return [String(vl_id) for vl_id in LibPowsybl.get_network_area_diagram_displayed_voltage_levels(network.handle,
                                                                                                    StdVector{StdString}(voltage_level_ids),
                                                                                                    Int32(depth))]
  end
end

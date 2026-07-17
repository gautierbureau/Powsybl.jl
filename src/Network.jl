# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

module Network
  using ..LibPowsybl
  using CxxWrap
  using DataFrames

  nominal_apparent_power::Float64 = 100.0
  per_unit::Bool = false

  mutable struct NetworkHandle
    handle::LibPowsybl.JavaHandle
    id::String
    name::String
    source_format::String
    forecast_distance::Int32
    case_date::Float64
  end

  function get_network_metadata(network::NetworkHandle)
      return LibPowsybl.get_network_metadata(network.handle)
  end

  function get_network_import_formats()
      return [String(format) for format in LibPowsybl.get_network_import_formats()]
  end

  function get_network_export_formats()
      return [String(format) for format in LibPowsybl.get_network_export_formats()]
  end

  function get_network_available_post_processors()
      return [String(processor) for processor in LibPowsybl.get_network_available_post_processors()]
  end

  function get_extensions_names()
      return [String(extension_name) for extension_name in LibPowsybl.get_extensions_names()]
  end

  function get_elements(network::NetworkHandle, type::LibPowsybl.ElementType, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    filter_attributes = LibPowsybl.DEFAULT_ATTRIBUTES
    if all_attributes
      filter_attributes = LibPowsybl.ALL_ATTRIBUTES
    elseif !isempty(attributes)
      filter_attributes = LibPowsybl.SELECTION_ATTRIBUTES
    end

    if all_attributes && !isempty(attributes)
      throw("parameters \"all_attributes\" and \"attributes\" are mutually exclusive")
    end
    series_array = LibPowsybl.create_network_elements_series_array(network.handle, type, StdVector{StdString}(attributes), filter_attributes, per_unit, nominal_apparent_power)
    return create_dataframe_from_series_array(series_array[])
  end

  function get_buses(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.BUS, all_attributes, attributes)
  end

  function get_bus_breaker_view_buses(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.BUS_FROM_BUS_BREAKER_VIEW, all_attributes, attributes)
  end

  function get_generators(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.GENERATOR, all_attributes, attributes)
  end

  function get_batteries(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.BATTERY, all_attributes, attributes)
  end

  function get_lines(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.LINE, all_attributes, attributes)
  end

  function get_2_windings_transformers(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.TWO_WINDINGS_TRANSFORMER, all_attributes, attributes)
  end

  function get_3_windings_transformers(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.THREE_WINDINGS_TRANSFORMER, all_attributes, attributes)
  end

  function get_shunt_compensators(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.SHUNT_COMPENSATOR, all_attributes, attributes)
  end

  function get_non_linear_shunt_compensator_sections(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.NON_LINEAR_SHUNT_COMPENSATOR_SECTION, all_attributes, attributes)
  end

  function get_linear_shunt_compensator_sections(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.LINEAR_SHUNT_COMPENSATOR_SECTION, all_attributes, attributes)
  end

  function get_boundary_lines(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.BOUNDARY_LINE, all_attributes, attributes)
  end

  # Deprecated since pypowsybl 1.15.0 renamed the DANGLING_LINE element type to BOUNDARY_LINE.
  # Kept as an alias for backward compatibility; use get_boundary_lines instead.
  function get_dangling_lines(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    Base.depwarn("get_dangling_lines is deprecated, use get_boundary_lines instead.", :get_dangling_lines)
    return get_boundary_lines(network, all_attributes, attributes)
  end

  function get_tie_lines(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.TIE_LINE, all_attributes, attributes)
  end

  function get_lcc_converter_stations(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.LCC_CONVERTER_STATION, all_attributes, attributes)
  end

  function get_vsc_converter_stations(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.VSC_CONVERTER_STATION, all_attributes, attributes)
  end

  function get_static_var_compensators(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.STATIC_VAR_COMPENSATOR, all_attributes, attributes)
  end

  function get_voltage_levels(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.VOLTAGE_LEVEL, all_attributes, attributes)
  end

  function get_busbar_sections(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.BUSBAR_SECTION, all_attributes, attributes)
  end

  function get_substations(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.SUBSTATION, all_attributes, attributes)
  end

  function get_hvdc_lines(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.HVDC_LINE, all_attributes, attributes)
  end

  function get_switches(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.SWITCH, all_attributes, attributes)
  end

  function get_ratio_tap_changer_steps(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.RATIO_TAP_CHANGER_STEP, all_attributes, attributes)
  end

  function get_phase_tap_changer_steps(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.PHASE_TAP_CHANGER_STEP, all_attributes, attributes)
  end

  function get_ratio_tap_changers(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.RATIO_TAP_CHANGER, all_attributes, attributes)
  end

  function get_phase_tap_changers(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.PHASE_TAP_CHANGER, all_attributes, attributes)
  end

  function get_reactive_capability_curve_points(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.REACTIVE_CAPABILITY_CURVE_POINT, all_attributes, attributes)
  end

  function get_aliases(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.ALIAS, all_attributes, attributes)
  end

  function get_identifiables(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.IDENTIFIABLE, all_attributes, attributes)
  end

  function get_injections(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.INJECTION, all_attributes, attributes)
  end

  function get_branches(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.BRANCH, all_attributes, attributes)
  end

  function get_terminals(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.TERMINAL, all_attributes, attributes)
  end

  function get_loads(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.LOAD, all_attributes, attributes)
  end

  function get_operational_limits(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.OPERATIONAL_LIMITS, all_attributes, attributes)
  end

  function get_extensions(network::NetworkHandle, extension_name::String, table_name::String = "")
    series_array = LibPowsybl.create_network_elements_extension_series_array(network.handle, extension_name, table_name)
    return create_dataframe_from_series_array(series_array[])
  end

  function create_dataframe_from_series_array(array::LibPowsybl.SeriesArray)
    myArray = LibPowsybl.as_array(array)
    df = DataFrame()
    for serie in myArray
      type = LibPowsybl.type(serie)
      name = LibPowsybl.name(serie)
      if type == 0
        # To avoid getting CxxWrap StdString type in the dataframe
        data = [String(cxx_str_elem) for cxx_str_elem in LibPowsybl.as_string_array(serie)]
      elseif type == 1
        data = LibPowsybl.as_double_array(serie)
      elseif type == 2
        data = LibPowsybl.as_int_array(serie)
      elseif type == 3
        # To avoid getting CxxWrap CxxBool type in the dataframe
        data = [Bool(cxx_bool_elem) for cxx_bool_elem in LibPowsybl.as_bool_array(serie)]
      else
        continue
      end
      df[!, name]=data
    end
    return df
  end

  function load(network_file::String, parameters::Dict{String, String} = Dict{String, String}(), postProcessors::Vector{String} = Vector{String}())::NetworkHandle
      handle = LibPowsybl.load(network_file, LibPowsybl.dict_to_string_string_map(parameters), StdVector{StdString}(postProcessors))
    return NetworkHandle(handle,
        LibPowsybl.id(handle),
        LibPowsybl.name(handle),
        LibPowsybl.source_format(handle),
        LibPowsybl.forecast_distance(handle),
        LibPowsybl.case_date(handle))
  end

  function save(network::NetworkHandle, network_file::String, format::String, parameters::Dict{String, String} = Dict{String, String}())
      LibPowsybl.save_network(network.handle, network_file, format, LibPowsybl.dict_to_string_string_map(parameters))
  end

  # Series type codes returned by the metadata (match the reader in
  # create_dataframe_from_series_array): 0 = string, 1 = double, 2 = int, 3 = bool.
  function _infer_series_type(column)
    element_type = eltype(column)
    if element_type <: AbstractString
      return 0
    elseif element_type <: Bool
      return 3
    elseif element_type <: Integer
      return 2
    elseif element_type <: Real
      return 1
    else
      return 0
    end
  end

  function _fill_builder!(builder, kwargs, meta_names, meta_types, meta_indices)
    type_by_name = Dict{String, Int}()
    index_names = Set{String}()
    for (name, type_code, is_index) in zip(meta_names, meta_types, meta_indices)
      column_name = String(name)
      type_by_name[column_name] = Int(type_code)
      if Int(is_index) != 0
        push!(index_names, column_name)
      end
    end

    # Number of rows = longest provided vector column (scalars are broadcast).
    row_count = 1
    for (_, value) in kwargs
      if value isa AbstractVector
        row_count = max(row_count, length(value))
      end
    end

    for (key, value) in kwargs
      column_name = String(key)
      column = value isa AbstractVector ? collect(value) : fill(value, row_count)
      if length(column) == 1 && row_count > 1
        column = fill(column[1], row_count)
      elseif length(column) != row_count
        throw(ArgumentError("column \"$column_name\" has $(length(column)) values but $row_count were expected"))
      end

      type_code = get(type_by_name, column_name, _infer_series_type(column))
      is_index = column_name in index_names

      if type_code == 0
        LibPowsybl.add_string_series(builder, column_name, is_index, StdVector{StdString}(String.(column)))
      elseif type_code == 1
        LibPowsybl.add_double_series(builder, column_name, is_index, StdVector{Float64}(Float64.(column)))
      elseif type_code == 2
        LibPowsybl.add_int_series(builder, column_name, is_index, StdVector{Cint}(Cint.(column)))
      elseif type_code == 3
        LibPowsybl.add_bool_series(builder, column_name, is_index, StdVector{Cint}(Cint.(Bool.(column))))
      end
    end
    return builder
  end

  """
      create_elements(network, element_type; kwargs...)

  Create network elements of the given `element_type` (a `LibPowsybl.ElementType`).
  Each keyword argument is a column of the creation dataframe; values may be scalars or
  vectors. This is the generic entry point behind the `create_*` helpers below.
  """
  function create_elements(network::NetworkHandle, element_type::LibPowsybl.ElementType; kwargs...)
    builder = LibPowsybl.ElementDataframe()
    _fill_builder!(builder, kwargs,
                   LibPowsybl.get_element_creation_metadata_names(element_type),
                   LibPowsybl.get_element_creation_metadata_types(element_type),
                   LibPowsybl.get_element_creation_metadata_indices(element_type))
    LibPowsybl.create_element(network.handle, builder, element_type)
    return nothing
  end

  """
      update_elements(network, element_type; kwargs...)

  Update existing network elements of the given `element_type`. The `id` column selects
  the elements; the other keyword columns are the values to set.
  """
  function update_elements(network::NetworkHandle, element_type::LibPowsybl.ElementType; kwargs...)
    builder = LibPowsybl.ElementDataframe()
    _fill_builder!(builder, kwargs,
                   LibPowsybl.get_element_metadata_names(element_type),
                   LibPowsybl.get_element_metadata_types(element_type),
                   LibPowsybl.get_element_metadata_indices(element_type))
    LibPowsybl.update_element(network.handle, builder, element_type, per_unit, nominal_apparent_power)
    return nothing
  end

  # Convenience creators, one per single-dataframe element type, mirroring pypowsybl.
  create_substations(network::NetworkHandle; kwargs...) = create_elements(network, LibPowsybl.SUBSTATION; kwargs...)
  create_voltage_levels(network::NetworkHandle; kwargs...) = create_elements(network, LibPowsybl.VOLTAGE_LEVEL; kwargs...)
  create_buses(network::NetworkHandle; kwargs...) = create_elements(network, LibPowsybl.BUS; kwargs...)
  create_busbar_sections(network::NetworkHandle; kwargs...) = create_elements(network, LibPowsybl.BUSBAR_SECTION; kwargs...)
  create_loads(network::NetworkHandle; kwargs...) = create_elements(network, LibPowsybl.LOAD; kwargs...)
  create_generators(network::NetworkHandle; kwargs...) = create_elements(network, LibPowsybl.GENERATOR; kwargs...)
  create_batteries(network::NetworkHandle; kwargs...) = create_elements(network, LibPowsybl.BATTERY; kwargs...)
  create_dangling_lines(network::NetworkHandle; kwargs...) = create_elements(network, LibPowsybl.DANGLING_LINE; kwargs...)
  create_lines(network::NetworkHandle; kwargs...) = create_elements(network, LibPowsybl.LINE; kwargs...)
  create_2_windings_transformers(network::NetworkHandle; kwargs...) = create_elements(network, LibPowsybl.TWO_WINDINGS_TRANSFORMER; kwargs...)
  create_switches(network::NetworkHandle; kwargs...) = create_elements(network, LibPowsybl.SWITCH; kwargs...)
  create_static_var_compensators(network::NetworkHandle; kwargs...) = create_elements(network, LibPowsybl.STATIC_VAR_COMPENSATOR; kwargs...)
  create_lcc_converter_stations(network::NetworkHandle; kwargs...) = create_elements(network, LibPowsybl.LCC_CONVERTER_STATION; kwargs...)
  create_vsc_converter_stations(network::NetworkHandle; kwargs...) = create_elements(network, LibPowsybl.VSC_CONVERTER_STATION; kwargs...)
  create_hvdc_lines(network::NetworkHandle; kwargs...) = create_elements(network, LibPowsybl.HVDC_LINE; kwargs...)

  # Convenience updaters.
  update_substations(network::NetworkHandle; kwargs...) = update_elements(network, LibPowsybl.SUBSTATION; kwargs...)
  update_voltage_levels(network::NetworkHandle; kwargs...) = update_elements(network, LibPowsybl.VOLTAGE_LEVEL; kwargs...)
  update_buses(network::NetworkHandle; kwargs...) = update_elements(network, LibPowsybl.BUS; kwargs...)
  update_loads(network::NetworkHandle; kwargs...) = update_elements(network, LibPowsybl.LOAD; kwargs...)
  update_generators(network::NetworkHandle; kwargs...) = update_elements(network, LibPowsybl.GENERATOR; kwargs...)
  update_batteries(network::NetworkHandle; kwargs...) = update_elements(network, LibPowsybl.BATTERY; kwargs...)
  update_dangling_lines(network::NetworkHandle; kwargs...) = update_elements(network, LibPowsybl.DANGLING_LINE; kwargs...)
  update_lines(network::NetworkHandle; kwargs...) = update_elements(network, LibPowsybl.LINE; kwargs...)
  update_2_windings_transformers(network::NetworkHandle; kwargs...) = update_elements(network, LibPowsybl.TWO_WINDINGS_TRANSFORMER; kwargs...)
  update_switches(network::NetworkHandle; kwargs...) = update_elements(network, LibPowsybl.SWITCH; kwargs...)
  update_shunt_compensators(network::NetworkHandle; kwargs...) = update_elements(network, LibPowsybl.SHUNT_COMPENSATOR; kwargs...)
  update_static_var_compensators(network::NetworkHandle; kwargs...) = update_elements(network, LibPowsybl.STATIC_VAR_COMPENSATOR; kwargs...)
  update_vsc_converter_stations(network::NetworkHandle; kwargs...) = update_elements(network, LibPowsybl.VSC_CONVERTER_STATION; kwargs...)
  update_lcc_converter_stations(network::NetworkHandle; kwargs...) = update_elements(network, LibPowsybl.LCC_CONVERTER_STATION; kwargs...)
  update_hvdc_lines(network::NetworkHandle; kwargs...) = update_elements(network, LibPowsybl.HVDC_LINE; kwargs...)

  # ---------------------------------------------------------------------------
  # Extension creation, update and removal
  #
  # Same keyword-argument style as element creation: one column per keyword,
  # scalar or vector, coerced to the type declared by the extension's dataframe
  # schema. The index column is typically the id of the element the extension
  # is attached to.
  # ---------------------------------------------------------------------------

  """
      get_extensions_information() -> DataFrame

  Return a DataFrame describing all the extensions supported by the underlying PowSyBl
  installation (name, attributes, ...).
  """
  function get_extensions_information()
    series_array = LibPowsybl.get_extensions_information()
    return create_dataframe_from_series_array(series_array[])
  end

  """
      create_extensions(network, extension_name; kwargs...)

  Create extensions of type `extension_name` (e.g. `"activePowerControl"`). Each keyword
  argument is a column of the extension's creation dataframe; the index column is usually
  `id` (the element the extension is attached to). See [`get_extensions_names`](@ref) for
  the available extension types.
  """
  function create_extensions(network::NetworkHandle, extension_name::String; kwargs...)
    builder = LibPowsybl.ElementDataframe()
    _fill_builder!(builder, kwargs,
                   LibPowsybl.get_extension_creation_metadata_names(extension_name),
                   LibPowsybl.get_extension_creation_metadata_types(extension_name),
                   LibPowsybl.get_extension_creation_metadata_indices(extension_name))
    LibPowsybl.create_extensions(network.handle, builder, extension_name)
    return nothing
  end

  """
      update_extensions(network, extension_name; table_name = "", kwargs...)

  Update existing extensions of type `extension_name`. Some extensions expose several
  tables (e.g. a main table and a secondary one); `table_name` selects which one to
  update (empty for the default table).
  """
  function update_extensions(network::NetworkHandle, extension_name::String; table_name::String = "", kwargs...)
    builder = LibPowsybl.ElementDataframe()
    _fill_builder!(builder, kwargs,
                   LibPowsybl.get_extension_metadata_names(extension_name, table_name),
                   LibPowsybl.get_extension_metadata_types(extension_name, table_name),
                   LibPowsybl.get_extension_metadata_indices(extension_name, table_name))
    LibPowsybl.update_extension(network.handle, builder, extension_name, table_name)
    return nothing
  end

  """
      remove_extensions(network, extension_name, ids)
      remove_extensions(network, extension_name, id)

  Remove the extensions of type `extension_name` from the elements with the given ids.
  """
  function remove_extensions(network::NetworkHandle, extension_name::String, ids::Vector{String})
    LibPowsybl.remove_extensions(network.handle, extension_name, StdVector{StdString}(ids))
    return nothing
  end

  function remove_extensions(network::NetworkHandle, extension_name::String, id::String)
    return remove_extensions(network, extension_name, [id])
  end

  include("NetworkCreationUtils.jl")
end

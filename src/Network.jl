# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

module Network
  using ..LibPowsybl
  using ..Report
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

  """
      set_per_unit(value::Bool)

  Enable or disable per-unit values for element data reads. When enabled, the `get_*`
  element accessors return quantities in per-unit (relative to the nominal voltage and
  [`get_nominal_apparent_power`](@ref)) instead of physical units.

  This is a module-wide setting affecting every subsequent element read on any network,
  until changed; it is disabled by default.
  """
  function set_per_unit(value::Bool)
    global per_unit = value
    return nothing
  end

  """
      is_per_unit() -> Bool

  Whether element data reads currently return per-unit values (see [`set_per_unit`](@ref)).
  """
  is_per_unit() = per_unit

  """
      set_nominal_apparent_power(value::Real)

  Set the nominal apparent power in MVA used as the base for per-unit values. Module-wide,
  `100.0` by default. Only relevant when [`set_per_unit`](@ref) is enabled.
  """
  function set_nominal_apparent_power(value::Real)
    global nominal_apparent_power = Float64(value)
    return nothing
  end

  """
      get_nominal_apparent_power() -> Float64

  The nominal apparent power in MVA used as the base for per-unit values
  (see [`set_nominal_apparent_power`](@ref)).
  """
  get_nominal_apparent_power() = nominal_apparent_power

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

  function get_dangling_lines(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.DANGLING_LINE, all_attributes, attributes)
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
    # pypowsybl 1.16.0 replaced OPERATIONAL_LIMITS with SELECTED_LOADING_LIMITS (the active
    # limit sets, matching the default behaviour of the deprecated get_operational_limits).
    return get_elements(network, LibPowsybl.SELECTED_LOADING_LIMITS, all_attributes, attributes)
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

  function load(network_file::String, parameters::Dict{String, String} = Dict{String, String}(),
                postProcessors::Vector{String} = Vector{String}();
                report::Union{Nothing, Report.ReportNode} = nothing)::NetworkHandle
      c_parameters = LibPowsybl.dict_to_string_string_map(parameters)
      c_post_processors = StdVector{StdString}(postProcessors)
      handle = report === nothing ?
        LibPowsybl.load(network_file, c_parameters, c_post_processors) :
        LibPowsybl.load_report(network_file, c_parameters, c_post_processors, report.handle)
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

  # ---------------------------------------------------------------------------
  # Import / export format metadata
  # ---------------------------------------------------------------------------

  """
      get_network_import_supported_extensions() -> Vector{String}

  Return the list of file extensions (e.g. `"xiidm"`, `"uct"`, `"raw"`) that can be
  used to import a network.
  """
  function get_network_import_supported_extensions()
    return [String(extension) for extension in LibPowsybl.get_network_import_supported_extensions()]
  end

  """
      get_import_parameters(format::String) -> DataFrame

  Return, as a DataFrame, the parameters supported by a given import `format`
  (for instance `"CGMES"`, `"PSS/E"`, `"UCTE"`). Each row describes a parameter with
  its name, description, type, default value and possible values.
  """
  function get_import_parameters(format::String)
    series_array = LibPowsybl.create_importer_parameters_series_array(format)
    return create_dataframe_from_series_array(series_array[])
  end

  """
      get_export_parameters(format::String) -> DataFrame

  Return, as a DataFrame, the parameters supported by a given export `format`.
  See also [`get_import_parameters`](@ref).
  """
  function get_export_parameters(format::String)
    series_array = LibPowsybl.create_exporter_parameters_series_array(format)
    return create_dataframe_from_series_array(series_array[])
  end

  # ---------------------------------------------------------------------------
  # Variant management
  # ---------------------------------------------------------------------------

  """
      get_variants_ids(network::NetworkHandle) -> Vector{String}

  Return the list of variant ids defined on the network. A network always has at
  least the initial variant.
  """
  function get_variants_ids(network::NetworkHandle)
    return [String(variant_id) for variant_id in LibPowsybl.get_variants_ids(network.handle)]
  end

  """
      get_working_variant_id(network::NetworkHandle) -> String

  Return the id of the currently active (working) variant of the network.
  """
  function get_working_variant_id(network::NetworkHandle)
    return String(LibPowsybl.get_working_variant_id(network.handle))
  end

  """
      clone_variant(network::NetworkHandle, src::String, variant::String; may_overwrite::Bool = true)

  Create a new variant `variant` by cloning the `src` variant. Cloning a variant lets
  you run several independent studies (e.g. contingencies) on the same network without
  altering the base case.
  """
  function clone_variant(network::NetworkHandle, src::String, variant::String; may_overwrite::Bool = true)
    LibPowsybl.clone_variant(network.handle, src, variant, may_overwrite)
    return nothing
  end

  # ---------------------------------------------------------------------------
  # Element creation and update
  #
  # The API mirrors pypowsybl: pass one keyword argument per column, each value
  # being a scalar (a single element) or a vector (several elements). Columns are
  # coerced to the type declared in the element's dataframe schema, so numeric
  # literals do not need to be spelled with an explicit type.
  # ---------------------------------------------------------------------------

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
    ordered_names = String[]
    index_names = Set{String}()
    for (name, type_code, is_index) in zip(meta_names, meta_types, meta_indices)
      column_name = String(name)
      type_by_name[column_name] = Int(type_code)
      push!(ordered_names, column_name)
      if Int(is_index) != 0
        push!(index_names, column_name)
      end
    end

    # Secondary creation dataframes (e.g. shunt sections, tap-changer steps) do not flag
    # an index column in their metadata, yet the Java side keys their rows on the first
    # column (the id). Mirror pypowsybl, which sends that column as the dataframe index.
    if isempty(index_names) && !isempty(ordered_names)
      push!(index_names, ordered_names[1])
    end

    provided = collect(kwargs)

    # An empty dataframe (e.g. the non-linear sections of a linear shunt) must still carry
    # its index column with zero rows, as pypowsybl does; a truly empty dataframe crashes
    # or is rejected by the Java side.
    if isempty(provided)
      for name in index_names
        _add_series!(builder, name, true, get(type_by_name, name, 0), Int[])
      end
      return builder
    end

    # Number of rows = longest provided vector column (scalars are broadcast).
    row_count = 1
    for (_, value) in provided
      if value isa AbstractVector
        row_count = max(row_count, length(value))
      end
    end

    for (key, value) in provided
      column_name = String(key)
      column = value isa AbstractVector ? collect(value) : fill(value, row_count)
      if length(column) == 1 && row_count > 1
        column = fill(column[1], row_count)
      elseif length(column) != row_count
        throw(ArgumentError("column \"$column_name\" has $(length(column)) values but $row_count were expected"))
      end

      type_code = get(type_by_name, column_name, _infer_series_type(column))
      _add_series!(builder, column_name, column_name in index_names, type_code, column)
    end
    return builder
  end

  function _add_series!(builder, name, is_index, type_code, column)
    if type_code == 0
      LibPowsybl.add_string_series(builder, name, is_index, StdVector{StdString}(String.(column)))
    elseif type_code == 1
      LibPowsybl.add_double_series(builder, name, is_index, StdVector{Float64}(Float64.(column)))
    elseif type_code == 2
      LibPowsybl.add_int_series(builder, name, is_index, StdVector{Cint}(Cint.(column)))
    elseif type_code == 3
      LibPowsybl.add_bool_series(builder, name, is_index, StdVector{Cint}(Cint.(Bool.(column))))
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
      set_working_variant(network::NetworkHandle, variant::String)

  Set the working variant of the network. All subsequent reads and computations operate
  on this variant.
  """
  function set_working_variant(network::NetworkHandle, variant::String)
    LibPowsybl.set_working_variant(network.handle, variant)
    return nothing
  end

  """
      remove_variant(network::NetworkHandle, variant::String)

  Remove a variant from the network.
  """
  function remove_variant(network::NetworkHandle, variant::String)
    LibPowsybl.remove_variant(network.handle, variant)
    return nothing
  end

  # ---------------------------------------------------------------------------
  # Network mutation
  # ---------------------------------------------------------------------------

  """
      remove_elements(network::NetworkHandle, element_ids::Vector{String})
      remove_elements(network::NetworkHandle, element_id::String)

  Remove one or several elements from the network given their ids.
  """
  function remove_elements(network::NetworkHandle, element_ids::Vector{String})
    LibPowsybl.remove_network_elements(network.handle, StdVector{StdString}(element_ids))
    return nothing
  end

  function remove_elements(network::NetworkHandle, element_id::String)
    return remove_elements(network, [element_id])
  end

  """
      update_switch_position(network::NetworkHandle, id::String, open::Bool) -> Bool

  Open (`open = true`) or close (`open = false`) the switch identified by `id`.
  Return `true` if the switch position was actually changed.
  """
  function update_switch_position(network::NetworkHandle, id::String, open::Bool)
    return LibPowsybl.update_switch_position(network.handle, id, open)
  end

  """
      update_connectable_status(network::NetworkHandle, id::String, connected::Bool) -> Bool

  Connect (`connected = true`) or disconnect (`connected = false`) the connectable
  identified by `id` (a load, generator, line, ...). Return `true` if the status was
  actually changed.
  """
  function update_connectable_status(network::NetworkHandle, id::String, connected::Bool)
    return LibPowsybl.update_connectable_status(network.handle, id, connected)
  end

  """
      get_elements_ids(network, type; nominal_voltages, countries,
                       main_connected_component, main_synchronous_component,
                       not_connected_to_same_bus_at_both_sides) -> Vector{String}

  Return the ids of the elements of a given `type` (a `LibPowsybl.ElementType`), with
  optional filtering by nominal voltage, country and connected/synchronous component.
  """
  function get_elements_ids(network::NetworkHandle, type::LibPowsybl.ElementType;
                            nominal_voltages::Vector{Float64} = Float64[],
                            countries::Vector{String} = String[],
                            main_connected_component::Bool = true,
                            main_synchronous_component::Bool = true,
                            not_connected_to_same_bus_at_both_sides::Bool = false)
    ids = LibPowsybl.get_network_elements_ids(network.handle, type,
                                              StdVector{Float64}(nominal_voltages),
                                              StdVector{StdString}(countries),
                                              main_connected_component,
                                              main_synchronous_component,
                                              not_connected_to_same_bus_at_both_sides)
    return [String(element_id) for element_id in ids]
  end

  # ---------------------------------------------------------------------------
  # Node/breaker and bus/breaker topology views
  # ---------------------------------------------------------------------------

  """
      get_node_breaker_view_nodes(network::NetworkHandle, voltage_level_id::String) -> DataFrame

  Return the nodes of the node/breaker topology view of a voltage level.
  """
  function get_node_breaker_view_nodes(network::NetworkHandle, voltage_level_id::String)
    series_array = LibPowsybl.get_node_breaker_view_nodes(network.handle, voltage_level_id)
    return create_dataframe_from_series_array(series_array[])
  end

  """
      get_node_breaker_view_switches(network::NetworkHandle, voltage_level_id::String) -> DataFrame

  Return the switches of the node/breaker topology view of a voltage level.
  """
  function get_node_breaker_view_switches(network::NetworkHandle, voltage_level_id::String)
    series_array = LibPowsybl.get_node_breaker_view_switches(network.handle, voltage_level_id)
    return create_dataframe_from_series_array(series_array[])
  end

  """
      get_node_breaker_view_internal_connections(network::NetworkHandle, voltage_level_id::String) -> DataFrame

  Return the internal connections of the node/breaker topology view of a voltage level.
  """
  function get_node_breaker_view_internal_connections(network::NetworkHandle, voltage_level_id::String)
    series_array = LibPowsybl.get_node_breaker_view_internal_connections(network.handle, voltage_level_id)
    return create_dataframe_from_series_array(series_array[])
  end

  """
      get_bus_breaker_view_buses(network::NetworkHandle, voltage_level_id::String) -> DataFrame

  Return the buses of the bus/breaker topology view of a voltage level.
  """
  function get_bus_breaker_view_buses(network::NetworkHandle, voltage_level_id::String)
    series_array = LibPowsybl.get_bus_breaker_view_buses(network.handle, voltage_level_id)
    return create_dataframe_from_series_array(series_array[])
  end

  """
      get_bus_breaker_view_switches(network::NetworkHandle, voltage_level_id::String) -> DataFrame

  Return the switches of the bus/breaker topology view of a voltage level.
  """
  function get_bus_breaker_view_switches(network::NetworkHandle, voltage_level_id::String)
    series_array = LibPowsybl.get_bus_breaker_view_switches(network.handle, voltage_level_id)
    return create_dataframe_from_series_array(series_array[])
  end

  """
      get_bus_breaker_view_elements(network::NetworkHandle, voltage_level_id::String) -> DataFrame

  Return the elements connected in the bus/breaker topology view of a voltage level.
  """
  function get_bus_breaker_view_elements(network::NetworkHandle, voltage_level_id::String)
    series_array = LibPowsybl.get_bus_breaker_view_elements(network.handle, voltage_level_id)
    return create_dataframe_from_series_array(series_array[])
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

  """
      create_elements(network, element_type, column_sets::AbstractVector)

  Create elements that need several dataframes (shunt compensators with their
  linear/non-linear sections, tap changers with their steps). `column_sets` holds one
  column set (a NamedTuple, `Dict`, or the pairs of a keyword list) per dataframe, in the
  order given by the creation schema. Trailing dataframes may be omitted and any dataframe
  may be left empty (`(;)`).
  """
  function create_elements(network::NetworkHandle, element_type::LibPowsybl.ElementType, column_sets::AbstractVector)
    builder = LibPowsybl.ElementDataframe()
    dataframe_count = LibPowsybl.get_element_creation_dataframes_count(element_type)
    for i in 0:(dataframe_count - 1)
      columns = (i + 1) <= length(column_sets) ? column_sets[i + 1] : (;)
      _fill_builder!(builder, pairs(columns),
                     LibPowsybl.get_element_creation_metadata_names_at(element_type, i),
                     LibPowsybl.get_element_creation_metadata_types_at(element_type, i),
                     LibPowsybl.get_element_creation_metadata_indices_at(element_type, i))
      LibPowsybl.finish_dataframe(builder)
    end
    LibPowsybl.create_element(network.handle, builder, element_type)
    return nothing
  end

  """
      create_shunt_compensators(network; linear = nothing, non_linear = nothing, kwargs...)

  Create shunt compensators. The keyword arguments describe the shunt compensators
  themselves; the sections are given either as a `linear` model
  (`g_per_section`, `b_per_section`, `max_section_count`) or as a `non_linear` set of
  sections (`g`, `b`, one row per section). Both `linear` and `non_linear` are column
  sets (NamedTuples) whose `id` links back to the shunt.
  """
  function create_shunt_compensators(network::NetworkHandle; linear = nothing, non_linear = nothing, kwargs...)
    return create_elements(network, LibPowsybl.SHUNT_COMPENSATOR,
                           Any[kwargs,
                               linear === nothing ? (;) : linear,
                               non_linear === nothing ? (;) : non_linear])
  end

  """
      create_ratio_tap_changers(network; steps, kwargs...)

  Create ratio tap changers. The keyword arguments describe the tap changers (their `id`
  is the transformer they are added to); `steps` is a column set with one row per step
  (`r`, `x`, `g`, `b`, `rho`).
  """
  function create_ratio_tap_changers(network::NetworkHandle; steps, kwargs...)
    return create_elements(network, LibPowsybl.RATIO_TAP_CHANGER, Any[kwargs, steps])
  end

  """
      create_phase_tap_changers(network; steps, kwargs...)

  Create phase tap changers. Like [`create_ratio_tap_changers`](@ref), but the `steps`
  additionally carry an `alpha` (phase shift) column.
  """
  function create_phase_tap_changers(network::NetworkHandle; steps, kwargs...)
    return create_elements(network, LibPowsybl.PHASE_TAP_CHANGER, Any[kwargs, steps])
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

  # ---------------------------------------------------------------------------
  # In-memory and probing I/O
  # ---------------------------------------------------------------------------

  """
      load_from_string(file_name, file_content[, parameters[, post_processors]]) -> NetworkHandle

  Load a network from an in-memory string. `file_name` is only used for its extension,
  which selects the format (e.g. `"network.xiidm"`, `"case.uct"`); `file_content` is the
  actual data.
  """
  function load_from_string(file_name::String, file_content::String,
                            parameters::Dict{String, String} = Dict{String, String}(),
                            post_processors::Vector{String} = Vector{String}())::NetworkHandle
      handle = LibPowsybl.load_from_string(file_name, file_content,
                                           LibPowsybl.dict_to_string_string_map(parameters),
                                           StdVector{StdString}(post_processors))
    return NetworkHandle(handle,
        LibPowsybl.id(handle),
        LibPowsybl.name(handle),
        LibPowsybl.source_format(handle),
        LibPowsybl.forecast_distance(handle),
        LibPowsybl.case_date(handle))
  end

  # ---------------------------------------------------------------------------
  # Network composition (merge / sub-networks / reduce)
  # ---------------------------------------------------------------------------

  # Build a NetworkHandle (with its metadata) from a raw Java handle.
  function _network_handle(handle::LibPowsybl.JavaHandle)
    return NetworkHandle(handle,
        LibPowsybl.id(handle),
        LibPowsybl.name(handle),
        LibPowsybl.source_format(handle),
        LibPowsybl.forecast_distance(handle),
        LibPowsybl.case_date(handle))
  end

  """
      save_to_string(network, format[, parameters]) -> String

  Export a network to a string in the given `format`, instead of to a file.
  """
  function save_to_string(network::NetworkHandle, format::String,
                          parameters::Dict{String, String} = Dict{String, String}())::String
      return String(LibPowsybl.save_to_string(network.handle, format, LibPowsybl.dict_to_string_string_map(parameters)))
  end

  """
      update_network(network, network_file[, parameters[, post_processors]])

  Update an existing network in place with the data read from `network_file` (for
  instance to refresh state variables from a solved case).
  """
  function update_network(network::NetworkHandle, network_file::String,
                          parameters::Dict{String, String} = Dict{String, String}(),
                          post_processors::Vector{String} = Vector{String}())
      LibPowsybl.update_network(network.handle, network_file,
                                LibPowsybl.dict_to_string_string_map(parameters),
                                StdVector{StdString}(post_processors))
      return nothing
  end

  """
      is_network_loadable(network_file) -> Bool

  Return `true` if `network_file` can be imported as a network (its format is recognised).
  """
  function is_network_loadable(network_file::String)
      return LibPowsybl.is_network_loadable(network_file)
  end

  """
      merge(networks::AbstractVector{NetworkHandle}) -> NetworkHandle
      merge(network::NetworkHandle, others::NetworkHandle...) -> NetworkHandle

  Merge networks into a single one, the first being the base into which the others are
  merged (each becomes a sub-network). Returns the merged network. Networks are merged
  left to right.
  """
  function merge(networks::AbstractVector{<:NetworkHandle})
    isempty(networks) && throw(ArgumentError("merge requires at least one network"))
    handle = networks[1].handle
    for i in 2:length(networks)
      handle = LibPowsybl.merge_networks(handle, networks[i].handle)
    end
    return _network_handle(handle)
  end

  merge(network::NetworkHandle, others::NetworkHandle...) = merge(NetworkHandle[network, others...])

  """
      get_sub_networks(network[, all_attributes[, attributes]]) -> DataFrame

  Return the sub-networks of a (merged) network as a DataFrame.
  """
  function get_sub_networks(network::NetworkHandle, all_attributes::Bool = false, attributes::Vector{String} = Vector{String}())
    return get_elements(network, LibPowsybl.SUB_NETWORK, all_attributes, attributes)
  end

  """
      get_sub_network(network, sub_network_id::String) -> NetworkHandle

  Return the sub-network of `network` with the given id.
  """
  function get_sub_network(network::NetworkHandle, sub_network_id::String)
    return _network_handle(LibPowsybl.get_sub_network(network.handle, sub_network_id))
  end

  """
      detach_sub_network(sub_network::NetworkHandle) -> NetworkHandle

  Detach a sub-network from its parent into a standalone network.
  """
  function detach_sub_network(sub_network::NetworkHandle)
    return _network_handle(LibPowsybl.detach_sub_network(sub_network.handle))
  end

  """
      reduce(network; v_min, v_max, ids, vl_depths, with_dangling_lines)

  Reduce a network in place, keeping the voltage levels selected by the criteria. This is
  the general entry point; see [`reduce_by_voltage_range`](@ref), [`reduce_by_ids`](@ref)
  and [`reduce_by_ids_and_depths`](@ref) for the common cases. `vl_depths` is a vector of
  `(voltage_level_id, depth)` pairs.
  """
  function reduce(network::NetworkHandle;
                  v_min::Float64 = 0.0, v_max::Float64 = floatmax(Float64),
                  ids::Vector{String} = String[],
                  vl_depths::AbstractVector = Tuple{String, Int}[],
                  with_dangling_lines::Bool = false)
    vls = String[String(first(p)) for p in vl_depths]
    depths = Cint[Cint(last(p)) for p in vl_depths]
    LibPowsybl.reduce_network(network.handle, v_min, v_max,
                              StdVector{StdString}(ids), StdVector{StdString}(vls), StdVector{Cint}(depths),
                              with_dangling_lines)
    return nothing
  end

  """
      reduce_by_voltage_range(network, v_min, v_max; with_dangling_lines = false)

  Reduce a network in place, keeping only the voltage levels whose nominal voltage is in
  `[v_min, v_max]`.
  """
  function reduce_by_voltage_range(network::NetworkHandle, v_min::Float64, v_max::Float64; with_dangling_lines::Bool = false)
    return reduce(network; v_min = v_min, v_max = v_max, with_dangling_lines = with_dangling_lines)
  end

  """
      reduce_by_ids(network, ids; with_dangling_lines = false)

  Reduce a network in place, keeping only the voltage levels whose id is in `ids`.
  """
  function reduce_by_ids(network::NetworkHandle, ids::Vector{String}; with_dangling_lines::Bool = false)
    return reduce(network; ids = ids, with_dangling_lines = with_dangling_lines)
  end

  """
      reduce_by_ids_and_depths(network, vl_depths; with_dangling_lines = false)

  Reduce a network in place, keeping the given voltage levels and their neighbours up to
  the given depth. `vl_depths` is a vector of `(voltage_level_id, depth)` pairs.
  """
  function reduce_by_ids_and_depths(network::NetworkHandle, vl_depths::AbstractVector; with_dangling_lines::Bool = false)
    return reduce(network; vl_depths = vl_depths, with_dangling_lines = with_dangling_lines)
  end

  # ===========================================================================
  # Network modifications (topology builders)
  # ===========================================================================

  """
  The kind of topology modification applied by [`create_network_modification`](@ref).
  The ordinals match PowSyBl's `network_modification_type`.
  """
  @enum NetworkModificationType begin
    VOLTAGE_LEVEL_TOPOLOGY_CREATION = 0
    CREATE_COUPLING_DEVICE = 1
    CREATE_FEEDER_BAY = 2
    CREATE_LINE_FEEDER = 3
    CREATE_TWO_WINDINGS_TRANSFORMER_FEEDER = 4
    CREATE_LINE_ON_LINE = 5
    REVERT_CREATE_LINE_ON_LINE = 6
    CONNECT_VOLTAGE_LEVEL_ON_LINE = 7
    REVERT_CONNECT_VOLTAGE_LEVEL_ON_LINE = 8
    REPLACE_TEE_POINT_BY_VOLTAGE_LEVEL_ON_LINE = 9
  end

  """
  The kind of element removed by [`remove_elements_modification`](@ref).
  """
  @enum RemoveModificationType begin
    REMOVE_FEEDER = 0
    REMOVE_VOLTAGE_LEVEL = 1
    REMOVE_HVDC_LINE = 2
  end

  """
      create_network_modification(network, modification_type; throw_exception = true, kwargs...)

  Apply a topology modification of the given [`NetworkModificationType`](@ref). Each keyword
  argument is a column of the modification's dataframe (scalar or vector); the columns are
  coerced to the schema PowSyBl expects. This is the generic entry point behind the
  `create_*` / `connect_*` / `replace_*` helpers below.
  """
  function create_network_modification(network::NetworkHandle, modification_type::NetworkModificationType;
                                       throw_exception::Bool = true, kwargs...)
    code = Int(modification_type)
    builder = LibPowsybl.ElementDataframe()
    _fill_builder!(builder, kwargs,
                   LibPowsybl.get_modification_metadata_names(code),
                   LibPowsybl.get_modification_metadata_types(code),
                   LibPowsybl.get_modification_metadata_indices(code))
    LibPowsybl.create_network_modification(network.handle, builder, code, throw_exception)
    return nothing
  end

  """
      create_voltage_level_topology(network; throw_exception = true, kwargs...)

  Create the internal topology (busbar sections and coupling switches) of a voltage level.
  Columns: `id`, `low_bus_or_busbar_index`, `aligned_buses_or_busbar_count`,
  `low_section_index`, `section_count`, `bus_or_busbar_section_prefix_id`,
  `switch_prefix_id`, `switch_kinds`.
  """
  function create_voltage_level_topology(network::NetworkHandle; throw_exception::Bool = true, kwargs...)
    return create_network_modification(network, VOLTAGE_LEVEL_TOPOLOGY_CREATION; throw_exception, kwargs...)
  end

  """
      create_coupling_device(network; throw_exception = true, kwargs...)

  Create a coupling device (a closed switch chain) between two busbar sections or buses.
  Columns: `bus_or_busbar_section_id_1`, `bus_or_busbar_section_id_2`, `switch_prefix_id`.
  """
  function create_coupling_device(network::NetworkHandle; throw_exception::Bool = true, kwargs...)
    return create_network_modification(network, CREATE_COUPLING_DEVICE; throw_exception, kwargs...)
  end

  """
      create_line_on_line(network; throw_exception = true, kwargs...)

  Tap an existing line, splitting it in two and connecting a new line to a bus/busbar.
  Columns include `line_id` (the line to split), `bbs_or_bus_id`, `new_line_id`,
  `new_line_r`/`_x`/`_b1`/`_b2`/`_g1`/`_g2`, `line1_id`, `line2_id`, `position_percent`.
  """
  function create_line_on_line(network::NetworkHandle; throw_exception::Bool = true, kwargs...)
    return create_network_modification(network, CREATE_LINE_ON_LINE; throw_exception, kwargs...)
  end

  """
      revert_create_line_on_line(network; throw_exception = true, kwargs...)

  Revert a [`create_line_on_line`](@ref), merging the two line segments back into one.
  Columns: `line_to_be_merged1_id`, `line_to_be_merged2_id`, `line_to_be_deleted`,
  `merged_line_id`, `merged_line_name`.
  """
  function revert_create_line_on_line(network::NetworkHandle; throw_exception::Bool = true, kwargs...)
    return create_network_modification(network, REVERT_CREATE_LINE_ON_LINE; throw_exception, kwargs...)
  end

  """
      connect_voltage_level_on_line(network; throw_exception = true, kwargs...)

  Connect an existing voltage level onto a line by splitting it at `position_percent`.
  Columns: `bbs_or_bus_id`, `line_id`, `position_percent`, `line1_id`, `line1_name`,
  `line2_id`, `line2_name`.
  """
  function connect_voltage_level_on_line(network::NetworkHandle; throw_exception::Bool = true, kwargs...)
    return create_network_modification(network, CONNECT_VOLTAGE_LEVEL_ON_LINE; throw_exception, kwargs...)
  end

  """
      revert_connect_voltage_level_on_line(network; throw_exception = true, kwargs...)

  Revert a [`connect_voltage_level_on_line`](@ref). Columns: `line1_id`, `line2_id`,
  `line_id`, `line_name`.
  """
  function revert_connect_voltage_level_on_line(network::NetworkHandle; throw_exception::Bool = true, kwargs...)
    return create_network_modification(network, REVERT_CONNECT_VOLTAGE_LEVEL_ON_LINE; throw_exception, kwargs...)
  end

  """
      replace_tee_point_by_voltage_level_on_line(network; throw_exception = true, kwargs...)

  Replace a tee point (three lines meeting) by connecting a voltage level on the line.
  Columns: `tee_point_line1`, `tee_point_line2`, `tee_point_line_to_remove`,
  `bbs_or_bus_id`, `new_line1_id`, `new_line2_id`, `new_line1_name`, `new_line2_name`.
  """
  function replace_tee_point_by_voltage_level_on_line(network::NetworkHandle; throw_exception::Bool = true, kwargs...)
    return create_network_modification(network, REPLACE_TEE_POINT_BY_VOLTAGE_LEVEL_ON_LINE; throw_exception, kwargs...)
  end

  function _as_id_vector(ids)
    return ids isa AbstractString ? [String(ids)] : String.(collect(ids))
  end

  """
      remove_elements_modification(network, connectable_ids, removal_type; throw_exception = true)

  Remove elements with a topology-aware modification. `removal_type` is a
  [`RemoveModificationType`](@ref); `connectable_ids` is an id or a vector of ids. Prefer
  the [`remove_feeder_bays`](@ref) / [`remove_voltage_levels`](@ref) / [`remove_hvdc_lines`](@ref)
  helpers.
  """
  function remove_elements_modification(network::NetworkHandle, connectable_ids,
                                        removal_type::RemoveModificationType; throw_exception::Bool = true)
    LibPowsybl.remove_elements_modification(network.handle, StdVector{StdString}(_as_id_vector(connectable_ids)),
                                            Int(removal_type), throw_exception)
    return nothing
  end

  """
      remove_feeder_bays(network, connectable_ids; throw_exception = true)

  Remove the given feeders (injections or branches) together with their bay switches.
  """
  function remove_feeder_bays(network::NetworkHandle, connectable_ids; throw_exception::Bool = true)
    return remove_elements_modification(network, connectable_ids, REMOVE_FEEDER; throw_exception)
  end

  """
      remove_voltage_levels(network, voltage_level_ids; throw_exception = true)

  Remove the given voltage levels and everything they contain.
  """
  function remove_voltage_levels(network::NetworkHandle, voltage_level_ids; throw_exception::Bool = true)
    return remove_elements_modification(network, voltage_level_ids, REMOVE_VOLTAGE_LEVEL; throw_exception)
  end

  """
      remove_hvdc_lines(network, hvdc_line_ids; throw_exception = true)

  Remove the given HVDC lines and their converter stations.
  """
  function remove_hvdc_lines(network::NetworkHandle, hvdc_line_ids; throw_exception::Bool = true)
    return remove_elements_modification(network, hvdc_line_ids, REMOVE_HVDC_LINE; throw_exception)
  end

  function _unused_order_positions(network::NetworkHandle, busbar_section_id::String, before_or_after::String)
    positions = collect(Int, LibPowsybl.get_unused_connectable_order_positions(network.handle, busbar_section_id, before_or_after))
    return isempty(positions) ? nothing : (positions[1], positions[end])
  end

  """
      get_unused_order_positions_before(network, busbar_section_id) -> Union{Tuple{Int,Int}, Nothing}

  Return the `(min, max)` interval of connectable order positions still free *before* the
  given busbar section, or `nothing` if none are available.
  """
  function get_unused_order_positions_before(network::NetworkHandle, busbar_section_id::String)
    return _unused_order_positions(network, busbar_section_id, "BEFORE")
  end

  """
      get_unused_order_positions_after(network, busbar_section_id) -> Union{Tuple{Int,Int}, Nothing}

  Return the `(min, max)` interval of connectable order positions still free *after* the
  given busbar section, or `nothing` if none are available.
  """
  function get_unused_order_positions_after(network::NetworkHandle, busbar_section_id::String)
    return _unused_order_positions(network, busbar_section_id, "AFTER")
  end

  # ---------------------------------------------------------------------------
  # Feeder bays: create an element and connect it into a node-breaker voltage
  # level in one step (creating the connection bay: switches, order position...).
  # ---------------------------------------------------------------------------

  # Build the modification dataframe from the element-type-specific schema. For the
  # injection feeder bay (CREATE_FEEDER_BAY) the element type is carried in a
  # `feeder_type` column, exactly as pypowsybl does.
  function _create_feeder_bay(network::NetworkHandle, modification_type::NetworkModificationType,
                              element_type::LibPowsybl.ElementType, feeder_type_name;
                              throw_exception::Bool, kwargs...)
    code = Int(modification_type)
    provided = collect(kwargs)
    if feeder_type_name !== nothing
      push!(provided, :feeder_type => feeder_type_name)
    end
    builder = LibPowsybl.ElementDataframe()
    _fill_builder!(builder, provided,
                   LibPowsybl.get_modification_element_metadata_names_at(code, element_type, 0),
                   LibPowsybl.get_modification_element_metadata_types_at(code, element_type, 0),
                   LibPowsybl.get_modification_element_metadata_indices_at(code, element_type, 0))
    LibPowsybl.create_network_modification(network.handle, builder, code, throw_exception)
    return nothing
  end

  for (fname, etype, tname) in [
        (:create_load_bay, :LOAD, "LOAD"),
        (:create_generator_bay, :GENERATOR, "GENERATOR"),
        (:create_battery_bay, :BATTERY, "BATTERY"),
        (:create_dangling_line_bay, :DANGLING_LINE, "DANGLING_LINE"),
        (:create_shunt_compensator_bay, :SHUNT_COMPENSATOR, "SHUNT_COMPENSATOR"),
        (:create_static_var_compensator_bay, :STATIC_VAR_COMPENSATOR, "STATIC_VAR_COMPENSATOR"),
        (:create_lcc_converter_station_bay, :LCC_CONVERTER_STATION, "LCC_CONVERTER_STATION"),
        (:create_vsc_converter_station_bay, :VSC_CONVERTER_STATION, "VSC_CONVERTER_STATION"),
      ]
    @eval begin
      """
          $($(String(fname)))(network; throw_exception = true, kwargs...)

      Create a $($tname) and connect it into a node-breaker voltage level, building its
      connection bay. Keyword columns are the element's creation columns plus the bay
      columns `bus_or_busbar_section_id`, `position_order` and `direction` (`"TOP"` or
      `"BOTTOM"`).
      """
      function $(fname)(network::NetworkHandle; throw_exception::Bool = true, kwargs...)
        return _create_feeder_bay(network, CREATE_FEEDER_BAY, LibPowsybl.$(etype), $tname;
                                  throw_exception = throw_exception, kwargs...)
      end
    end
  end

  """
      create_line_bays(network; throw_exception = true, kwargs...)

  Create a line and connect both of its ends into node-breaker voltage levels, building a
  bay on each side. Columns include the line's `id`, `r`, `x`, `b1`, `b2`, `g1`, `g2` and
  the per-side bay columns `bus_or_busbar_section_id_1`/`_2`, `position_order_1`/`_2`,
  `direction_1`/`_2`.
  """
  function create_line_bays(network::NetworkHandle; throw_exception::Bool = true, kwargs...)
    return _create_feeder_bay(network, CREATE_LINE_FEEDER, LibPowsybl.LINE, nothing;
                              throw_exception = throw_exception, kwargs...)
  end

  """
      create_2_windings_transformer_bays(network; throw_exception = true, kwargs...)

  Create a two windings transformer and connect both ends into node-breaker voltage levels.
  Columns include `id`, `voltage_level1_id`, `voltage_level2_id`, `r`, `x`, `g`, `b`,
  `rated_u1`, `rated_u2` and the per-side bay columns.
  """
  function create_2_windings_transformer_bays(network::NetworkHandle; throw_exception::Bool = true, kwargs...)
    return _create_feeder_bay(network, CREATE_TWO_WINDINGS_TRANSFORMER_FEEDER, LibPowsybl.TWO_WINDINGS_TRANSFORMER, nothing;
                              throw_exception = throw_exception, kwargs...)
  end

  # ---------------------------------------------------------------------------
  # Alias and internal-connection removal
  # ---------------------------------------------------------------------------

  """
      remove_aliases(network; id, alias)

  Remove element aliases. `id` selects the elements and `alias` the alias to drop from each
  (scalars or matching vectors).
  """
  function remove_aliases(network::NetworkHandle; kwargs...)
    builder = LibPowsybl.ElementDataframe()
    _fill_builder!(builder, kwargs, ["id", "alias"], [0, 0], [1, 0])
    LibPowsybl.remove_aliases(network.handle, builder)
    return nothing
  end

  """
      remove_internal_connections(network; voltage_level_id, node1, node2)

  Remove node-breaker internal connections (direct node-to-node links) identified by their
  voltage level and the two node numbers they connect (scalars or matching vectors).
  """
  function remove_internal_connections(network::NetworkHandle; kwargs...)
    builder = LibPowsybl.ElementDataframe()
    _fill_builder!(builder, kwargs, ["voltage_level_id", "node1", "node2"], [0, 2, 2], [1, 0, 0])
    LibPowsybl.remove_internal_connections(network.handle, builder)
    return nothing
  end

  include("NetworkCreationUtils.jl")
end
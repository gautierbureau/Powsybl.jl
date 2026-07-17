/**
 * Copyright (c) 2025, RTE (http://www.rte-france.com)
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 * SPDX-License-Identifier: MPL-2.0
 */
#include <string>
#include <functional>
#include <memory>
#include <iostream>
#include <thread>
#include <list>
#include <vector>

#include "jlcxx/jlcxx.hpp"
#include "powsybl-cpp.h"

// Accumulates typed columns and exposes them as a C `dataframe` for element
// creation/update. Owns all the column storage so the pointers held by the C
// series stay valid for the duration of the (synchronous) Java call.
class ElementDataframe {
public:
    void add_string_series(const std::string& name, bool index, const std::vector<std::string>& values) {
        names_.push_back(name);
        stringData_.push_back(values);
        std::vector<std::string>& stored = stringData_.back();
        stringPtrs_.emplace_back();
        std::vector<char*>& ptrs = stringPtrs_.back();
        ptrs.reserve(stored.size());
        for (std::string& s : stored) { ptrs.push_back(const_cast<char*>(s.c_str())); }
        appendSeries(index, 0, ptrs.data(), (int) ptrs.size());
    }
    void add_double_series(const std::string& name, bool index, const std::vector<double>& values) {
        names_.push_back(name);
        doubleData_.push_back(values);
        appendSeries(index, 1, doubleData_.back().data(), (int) doubleData_.back().size());
    }
    void add_int_series(const std::string& name, bool index, const std::vector<int>& values) {
        names_.push_back(name);
        intData_.push_back(values);
        appendSeries(index, 2, intData_.back().data(), (int) intData_.back().size());
    }
    void add_bool_series(const std::string& name, bool index, const std::vector<int>& values) {
        // Boolean series are marshalled as 4-byte ints (0/1), exactly like int
        // series: the Java side reads type 2 and 3 from an int* buffer.
        names_.push_back(name);
        intData_.push_back(values);
        appendSeries(index, 3, intData_.back().data(), (int) intData_.back().size());
    }
    // Close the current dataframe and start a new one. Used to build the several
    // dataframes some element types need at creation (e.g. a shunt compensator plus
    // its linear/non-linear sections, or a tap changer plus its steps).
    void finish_dataframe() {
        frames_.push_back(current_);
        current_.clear();
    }
    // Single dataframe (the columns added since the last finish_dataframe). Used for
    // updates and single-dataframe extension creation.
    dataframe build_dataframe() {
        return makeDataframe(current_);
    }
    // All the dataframes to create an element: the finished frames, or the current one
    // when finish_dataframe was never called (the single-dataframe case).
    std::vector<dataframe> build_dataframes() {
        std::vector<dataframe> result;
        if (!frames_.empty()) {
            for (std::vector<series>& frame : frames_) {
                result.push_back(makeDataframe(frame));
            }
        } else {
            result.push_back(makeDataframe(current_));
        }
        return result;
    }
private:
    // An empty dataframe must still carry a valid (non-null) series pointer, matching
    // pypowsybl which always allocates the series array even for zero columns; a null
    // pointer crashes the Java dataframe reader.
    dataframe makeDataframe(std::vector<series>& frame) {
        dataframe df;
        df.series = frame.empty() ? &emptySeries_ : frame.data();
        df.series_count = (int) frame.size();
        return df;
    }
    void appendSeries(bool index, int type, void* ptr, int length) {
        series s;
        s.name = const_cast<char*>(names_.back().c_str());
        s.index = index ? 1 : 0;
        s.type = type;
        s.data.ptr = ptr;
        s.data.length = length;
        s.mask = nullptr;
        current_.push_back(s);
    }
    std::list<std::string> names_;
    std::list<std::vector<std::string>> stringData_;
    std::list<std::vector<char*>> stringPtrs_;
    std::list<std::vector<double>> doubleData_;
    std::list<std::vector<int>> intData_;
    std::vector<series> current_;
    std::list<std::vector<series>> frames_;
    series emptySeries_{};
};

// Necessary to compile to map struct with no constructor ?
template <> struct jlcxx::IsMirroredType<series> : std::false_type {};
template <> struct jlcxx::IsMirroredType<network_metadata> : std::false_type {};
template <> struct jlcxx::IsMirroredType<loadflow_component_result> : std::false_type {};
template <> struct jlcxx::IsMirroredType<slack_bus_result> : std::false_type {};
template <> struct jlcxx::IsMirroredType<pre_contingency_result> : std::false_type {};
template <> struct jlcxx::IsMirroredType<post_contingency_result> : std::false_type {};
template <> struct jlcxx::IsMirroredType<matrix> : std::false_type {};

using StringStringMap = std::map<std::string, std::string>;

void logFromJava(int level, long timestamp, char* loggerName, char* message) {
  //TODO Redirect log properly to julia logger
}

// Template lambda returning an attribute of a class instance
template <typename R, typename P>
std::function<R(P)> attribute_getter(const R P::*pm) {
    return [pm](const P &c) -> const R & { return c.*pm; };
}

// Template lambda setting an attribute of a class instance
template <typename R, typename P>
std::function<void(P&, R)> attribute_setter(R P::*pm) {
    return [pm](P &c, R v) { c.*pm = v; };
}

// Template method generating getter and setter for a given class attribute
template <typename P, typename R>
jlcxx::TypeWrapper<P>& map_attribute_accessor(jlcxx::TypeWrapper<P>& wrapper, std::string const& attribute_name, R P::*pm) {
    wrapper.method(attribute_name, attribute_setter(pm));
    wrapper.method(attribute_name, attribute_getter(pm));
    return wrapper;
}

template <typename T>
jlcxx::Array<T> powsybl_array_to_julia(const pypowsybl::Array<T>* parray) {
  return powsybl_array_to_julia(parray->begin(), parray->length());
}

template <typename T>
jlcxx::Array<T> powsybl_array_to_julia(const array* parray) {
  return powsybl_array_to_julia((T*)parray->ptr, parray->length);
}

template <typename T>
jlcxx::Array<T> powsybl_array_to_julia(const T* ptr, int length) {
  jlcxx::Array<T> jlArray{ };
  for(int i=0; i < length; ++i) {
    jlArray.push_back(ptr[i]);
  }
  return jlArray;
}

// Wrap previous method in a convenient function
// Jlcxx wrapper is accessible when we want to provide custom method / lambda
// Simple attribute can be mapped using map_attribute (inspired by pydbind11)
template <typename T>
class CustomMapper {
public:
    CustomMapper(jlcxx::Module& module, std::string type_name) :
     type_wrapper(module.add_type<T>(type_name)) {}

    jlcxx::TypeWrapper<T> jlcxx_wrapper() {
      return type_wrapper;
    }

    template <typename R>
    CustomMapper<T>& method_readwrite(std::string const& attribute_name, R T::*pm) {
        map_attribute_accessor(type_wrapper, attribute_name, pm);
        return *this;
    }
    jlcxx::TypeWrapper<T> type_wrapper;
};

JLCXX_MODULE define_module_powsybl(jlcxx::Module& mod)
{
  mod.add_type<pypowsybl::JavaHandle>("JavaHandle");

  // No automatic mapping of std::map type
  // Only map the basic we use on julia side...
  mod.add_type<StringStringMap>("StringStringMap")
        .method("put_element", [] (StringStringMap& map, const std::string& key, const std::string& value) {
          map[key] = value;
       });

  mod.add_bits<element_type>("ElementType", jlcxx::julia_type("CppEnum"));
  mod.set_const("BUS", element_type::BUS);
  mod.set_const("BUS_FROM_BUS_BREAKER_VIEW", element_type::BUS_FROM_BUS_BREAKER_VIEW);
  mod.set_const("LINE", element_type::LINE);
  mod.set_const("TWO_WINDINGS_TRANSFORMER", element_type::TWO_WINDINGS_TRANSFORMER);
  mod.set_const("THREE_WINDINGS_TRANSFORMER", element_type::THREE_WINDINGS_TRANSFORMER);
  mod.set_const("GENERATOR", element_type::GENERATOR);
  mod.set_const("LOAD", element_type::LOAD);
  mod.set_const("BATTERY", element_type::BATTERY);
  mod.set_const("SHUNT_COMPENSATOR", element_type::SHUNT_COMPENSATOR);
  mod.set_const("NON_LINEAR_SHUNT_COMPENSATOR_SECTION", element_type::NON_LINEAR_SHUNT_COMPENSATOR_SECTION);
  mod.set_const("LINEAR_SHUNT_COMPENSATOR_SECTION", element_type::LINEAR_SHUNT_COMPENSATOR_SECTION);
  // pypowsybl 1.15.0 renamed the DANGLING_LINE element type to BOUNDARY_LINE; keep the
  // Julia-facing name stable so Network.get_dangling_lines is unchanged.
  mod.set_const("DANGLING_LINE", element_type::BOUNDARY_LINE);
  mod.set_const("TIE_LINE", element_type::TIE_LINE);
  mod.set_const("LCC_CONVERTER_STATION", element_type::LCC_CONVERTER_STATION);
  mod.set_const("VSC_CONVERTER_STATION", element_type::VSC_CONVERTER_STATION);
  mod.set_const("STATIC_VAR_COMPENSATOR", element_type::STATIC_VAR_COMPENSATOR);
  mod.set_const("SWITCH", element_type::SWITCH);
  mod.set_const("VOLTAGE_LEVEL", element_type::VOLTAGE_LEVEL);
  mod.set_const("SUBSTATION", element_type::SUBSTATION);
  mod.set_const("BUSBAR_SECTION", element_type::BUSBAR_SECTION);
  mod.set_const("HVDC_LINE", element_type::HVDC_LINE);
  mod.set_const("RATIO_TAP_CHANGER_STEP", element_type::RATIO_TAP_CHANGER_STEP);
  mod.set_const("PHASE_TAP_CHANGER_STEP", element_type::PHASE_TAP_CHANGER_STEP);
  mod.set_const("RATIO_TAP_CHANGER", element_type::RATIO_TAP_CHANGER);
  mod.set_const("PHASE_TAP_CHANGER", element_type::PHASE_TAP_CHANGER);
  mod.set_const("REACTIVE_CAPABILITY_CURVE_POINT", element_type::REACTIVE_CAPABILITY_CURVE_POINT);
  mod.set_const("OPERATIONAL_LIMITS", element_type::OPERATIONAL_LIMITS);
  mod.set_const("MINMAX_REACTIVE_LIMITS", element_type::MINMAX_REACTIVE_LIMITS);
  mod.set_const("ALIAS", element_type::ALIAS);
  mod.set_const("IDENTIFIABLE", element_type::IDENTIFIABLE);
  mod.set_const("INJECTION", element_type::INJECTION);
  mod.set_const("BRANCH", element_type::BRANCH);
  mod.set_const("TERMINAL", element_type::TERMINAL);
  mod.set_const("SUB_NETWORK", element_type::SUB_NETWORK);

  mod.add_bits<filter_attributes_type>("FilterAttributes", jlcxx::julia_type("CppEnum"));
  mod.set_const("ALL_ATTRIBUTES", filter_attributes_type::ALL_ATTRIBUTES);
  mod.set_const("DEFAULT_ATTRIBUTES", filter_attributes_type::DEFAULT_ATTRIBUTES);
  mod.set_const("SELECTION_ATTRIBUTES", filter_attributes_type::SELECTION_ATTRIBUTES);

  auto preJavaCall = [](pypowsybl::GraalVmGuard* guard, exception_handler* exc){ };
  auto postJavaCall = [](){ };
  pypowsybl::init(preJavaCall, postJavaCall);
  auto fptr = &::logFromJava;
  pypowsybl::setupLoggerCallback(reinterpret_cast<void *&>(fptr));

  mod.method("get_version_table", &pypowsybl::getVersionTable, "Get an ASCII table with all PowSybBl modules version");
  mod.method("set_java_library_path", &pypowsybl::setJavaLibraryPath, "Set java.library.path JVM property");

  mod.method("close_powsybl", &pypowsybl::closePypowsybl, "Closes powsybl module");

  mod.method("set_config_read_internal", &pypowsybl::setConfigRead, "Set config read mode");

  mod.method("load", [] (std::string const& s, StringStringMap& parameters, std::vector<std::string>& postProcessors) {
    pypowsybl::JavaHandle network = pypowsybl::loadNetwork(s, parameters, postProcessors, nullptr, false);
    return network;
  }, "Load a network from a file");

  mod.method("create_network", [] (std::string const& name, std::string const& id) {
    return pypowsybl::createNetwork(name, id, false);
  }, "create an example network");

  mod.method("get_network_available_post_processors", &pypowsybl::getNetworkImportPostProcessors, "Get available post processors");
  mod.method("get_network_import_formats", &pypowsybl::getNetworkImportFormats, "Get available import format");
  mod.method("get_network_export_formats", &pypowsybl::getNetworkExportFormats, "Get available export format");

  mod.method("save_network", [] (pypowsybl::JavaHandle handle, std::string const& file, std::string const& format, StringStringMap const& parameters) {
      pypowsybl::saveNetwork(handle, file, format, parameters, nullptr);
    }, "Save network to a file in a given format");

  mod.add_type<series>("SeriesType")
        .method("name", [](series& s) { return std::string(s.name); })
        .method("index", [](series& s) { return (bool) s.index; })
        .method("type", [](series& s) { return s.type; })
        .method("as_double_array", [](series& s) {
            return jlcxx::ArrayRef<double,1>(static_cast<double*>(s.data.ptr), s.data.length);
         })
        .method("as_int_array", [](series& s) {
                  return jlcxx::ArrayRef<int,1>(static_cast<int*>(s.data.ptr), s.data.length);
        })
        .method("as_string_array", [](series& s) {
                  return pypowsybl::toVector<std::string>((array *) & s.data);
        })
        .method("as_bool_array", [](series& s) {
                  return jlcxx::ArrayRef<bool,1>(static_cast<bool*>(s.data.ptr), s.data.length);
        });

  mod.add_type<network_metadata>("NetworkMetadata")
        .method("id", [](pypowsybl::JavaHandle handle) {
           return std::string(pypowsybl::getNetworkMetadata(handle)->id);
        })
        .method("name", [](pypowsybl::JavaHandle handle) {
           return std::string(pypowsybl::getNetworkMetadata(handle)->name);
        })
        .method("source_format", [](pypowsybl::JavaHandle handle) {
           return std::string(pypowsybl::getNetworkMetadata(handle)->source_format);
        })
        .method("forecast_distance", [](pypowsybl::JavaHandle handle) {
           return pypowsybl::getNetworkMetadata(handle)->forecast_distance;
         })
        .method("case_date", [](pypowsybl::JavaHandle handle) {
           return pypowsybl::getNetworkMetadata(handle)->case_date;
        });

  mod.add_type<pypowsybl::SeriesArray>("SeriesArray")
      .method("as_array", [](pypowsybl::SeriesArray& seriesArray) {
          return powsybl_array_to_julia(&seriesArray);
      });

  mod.method("create_network_elements_series_array", [] (pypowsybl::JavaHandle handle, element_type type, std::vector<std::string> const& attributes, filter_attributes_type filter_attributes, bool nominal_apparent_power, double per_unit) {
      return pypowsybl::createNetworkElementsSeriesArray(handle, type, filter_attributes, attributes, nullptr, nominal_apparent_power, per_unit);
      }, "Create a network elements series array for a given element type");

  mod.method("create_network_elements_extension_series_array", [] (pypowsybl::JavaHandle handle, std::string const& extension_name, std::string const& table_name) {
        return pypowsybl::createNetworkElementsExtensionSeriesArray(handle, extension_name, table_name);
        }, "Create a network elements extensions series array for a given extension name");

  mod.method("get_extensions_names", [] () {
          return pypowsybl::getExtensionsNames();
          }, "Get all the extensions names available");

  // VoltageInitMode
  mod.add_bits<pypowsybl::VoltageInitMode>("VoltageInitMode", jlcxx::julia_type("CppEnum"));
  mod.set_const("UNIFORM_VALUES", pypowsybl::VoltageInitMode::UNIFORM_VALUES);
  mod.set_const("PREVIOUS_VALUES", pypowsybl::VoltageInitMode::PREVIOUS_VALUES);
  mod.set_const("DC_VALUES", pypowsybl::VoltageInitMode::DC_VALUES);

  // ConnectedComponentMode
  mod.add_bits<pypowsybl::ComponentMode>("ComponentMode", jlcxx::julia_type("CppEnum"));
  mod.set_const("MAIN_CONNECTED", pypowsybl::ComponentMode::MAIN_CONNECTED);
  mod.set_const("ALL_CONNECTED", pypowsybl::ComponentMode::ALL_CONNECTED);
  mod.set_const("MAIN_SYNCHRONOUS", pypowsybl::ComponentMode::MAIN_SYNCHRONOUS);

  // BalanceType
  mod.add_bits<pypowsybl::BalanceType>("BalanceType", jlcxx::julia_type("CppEnum"));
  mod.set_const("PROPORTIONAL_TO_GENERATION_P", pypowsybl::BalanceType::PROPORTIONAL_TO_GENERATION_P);
  mod.set_const("PROPORTIONAL_TO_GENERATION_P_MAX", pypowsybl::BalanceType::PROPORTIONAL_TO_GENERATION_P_MAX);
  mod.set_const("PROPORTIONAL_TO_GENERATION_REMAINING_MARGIN", pypowsybl::BalanceType::PROPORTIONAL_TO_GENERATION_REMAINING_MARGIN);
  mod.set_const("PROPORTIONAL_TO_GENERATION_PARTICIPATION_FACTOR", pypowsybl::BalanceType::PROPORTIONAL_TO_GENERATION_PARTICIPATION_FACTOR);
  mod.set_const("PROPORTIONAL_TO_LOAD", pypowsybl::BalanceType::PROPORTIONAL_TO_LOAD);
  mod.set_const("PROPORTIONAL_TO_CONFORM_LOAD", pypowsybl::BalanceType::PROPORTIONAL_TO_CONFORM_LOAD);

  // LoadFlowComponentStatus
  mod.add_bits<pypowsybl::LoadFlowComponentStatus>("LoadFlowComponentStatus", jlcxx::julia_type("CppEnum"));
  mod.set_const("CONVERGED", pypowsybl::LoadFlowComponentStatus::CONVERGED);
  mod.set_const("FAILED", pypowsybl::LoadFlowComponentStatus::FAILED);
  mod.set_const("MAX_ITERATION_REACHED", pypowsybl::LoadFlowComponentStatus::MAX_ITERATION_REACHED);
  mod.set_const("NO_CALCULATION", pypowsybl::LoadFlowComponentStatus::NO_CALCULATION);

  mod.add_type<slack_bus_result>("SlackBusResult")
          .method("id", [](const slack_bus_result& r) {
             return std::string(r.id);
          })
          .method("active_power_mismatch", [](const slack_bus_result& r) {
             return r.active_power_mismatch;
          });

  mod.add_type<loadflow_component_result>("LoadFlowComponentResult")
          .method("connected_component_num", [](const loadflow_component_result& r) {
             return r.connected_component_num;
          })
          .method("synchronous_component_num", [](const loadflow_component_result& r) {
             return r.synchronous_component_num;
          })
          .method("status", [](const loadflow_component_result& r) {
             return static_cast<pypowsybl::LoadFlowComponentStatus>(r.status);
          })
          .method("status_text", [](const loadflow_component_result& r) {
             return std::string(r.status_text);
          })
          .method("iteration_count", [](const loadflow_component_result& r) {
             return r.iteration_count;
          })
          .method("reference_bus_id", [](const loadflow_component_result& r) {
             return std::string(r.reference_bus_id);
          })
          .method("distributed_active_power", [](const loadflow_component_result& r) {
             return r.distributed_active_power;
          })
          .method("slack_bus_results", [](const loadflow_component_result& r) {
             return powsybl_array_to_julia<slack_bus_result>(&(r.slack_bus_results));
          });

  // Since pypowsybl 1.15.0, jlcxx auto-registers a default constructor for
  // LoadFlowParameters, so we must not also register one here (it would be a double
  // registration). Provider defaults are obtained through default_loadflow_parameters().
  CustomMapper<pypowsybl::LoadFlowParameters> lfParametersMapper(mod, "LoadFlowParameters");
  lfParametersMapper
    .method_readwrite("voltage_init_mode", &pypowsybl::LoadFlowParameters::voltage_init_mode)
    .method_readwrite("transformer_voltage_control_on", &pypowsybl::LoadFlowParameters::transformer_voltage_control_on)
    .method_readwrite("use_reactive_limits", &pypowsybl::LoadFlowParameters::use_reactive_limits)
    .method_readwrite("phase_shifter_regulation_on", &pypowsybl::LoadFlowParameters::phase_shifter_regulation_on)
    .method_readwrite("twt_split_shunt_admittance", &pypowsybl::LoadFlowParameters::twt_split_shunt_admittance)
    .method_readwrite("shunt_compensator_voltage_control_on", &pypowsybl::LoadFlowParameters::shunt_compensator_voltage_control_on)
    .method_readwrite("read_slack_bus", &pypowsybl::LoadFlowParameters::read_slack_bus)
    .method_readwrite("write_slack_bus", &pypowsybl::LoadFlowParameters::write_slack_bus)
    .method_readwrite("distributed_slack", &pypowsybl::LoadFlowParameters::distributed_slack)
    .method_readwrite("balance_type", &pypowsybl::LoadFlowParameters::balance_type)
    .method_readwrite("dc_use_transformer_ratio", &pypowsybl::LoadFlowParameters::dc_use_transformer_ratio)
    .method_readwrite("countries_to_balance", &pypowsybl::LoadFlowParameters::countries_to_balance)
    .method_readwrite("component_mode", &pypowsybl::LoadFlowParameters::component_mode)
    .method_readwrite("dc_power_factor", &pypowsybl::LoadFlowParameters::dc_power_factor)
    .method_readwrite("provider_parameters_keys", &pypowsybl::LoadFlowParameters::provider_parameters_keys)
    .method_readwrite("provider_parameters_values", &pypowsybl::LoadFlowParameters::provider_parameters_values);

  mod.method("default_loadflow_parameters", [] () {
                std::shared_ptr<pypowsybl::LoadFlowParameters> parameters(pypowsybl::createLoadFlowParameters());
                return *parameters;
    }, "Get a LoadFlowParameters filled with the provider defaults");

  mod.method("run_load_flow", [] (const pypowsybl::JavaHandle& network, const pypowsybl::LoadFlowParameters& parameters, bool dc, const std::string& provider) {
                // Since pypowsybl 1.15.0 the DC flag is carried on the parameters (runLoadFlow
                // no longer takes a separate dc argument); copy locally to set it.
                pypowsybl::LoadFlowParameters dcParameters = parameters;
                dcParameters.dc = dc;
                pypowsybl::LoadFlowComponentResultArray* results = pypowsybl::runLoadFlow(network, dcParameters, provider, nullptr);
                return powsybl_array_to_julia(results);
      }, "Run and AC load flow");

  mod.method("create_loadflow_provider_parameters_series_array", [] (const std::string& provider) {
            return pypowsybl::createLoadFlowProviderParametersSeriesArray(provider);
    }, "Create a parameters series array for a given loadflow provider");

  // ---------------------------------------------------------------------------
  // Import / export format metadata
  // ---------------------------------------------------------------------------
  mod.method("get_network_import_supported_extensions", &pypowsybl::getNetworkImportSupportedExtensions,
             "Get the file extensions supported for network import");

  mod.method("create_importer_parameters_series_array", [] (const std::string& format) {
            return pypowsybl::createImporterParametersSeriesArray(format);
    }, "Create a parameters series array for a given import format");

  mod.method("create_exporter_parameters_series_array", [] (const std::string& format) {
            return pypowsybl::createExporterParametersSeriesArray(format);
    }, "Create a parameters series array for a given export format");

  // ---------------------------------------------------------------------------
  // Variant management
  // ---------------------------------------------------------------------------
  mod.method("get_variants_ids", [] (pypowsybl::JavaHandle network) {
            return pypowsybl::getVariantsIds(network);
    }, "Get the list of variant ids of a network");

  mod.method("get_working_variant_id", [] (pypowsybl::JavaHandle network) {
            return pypowsybl::getWorkingVariantId(network);
    }, "Get the id of the working variant of a network");

  mod.method("clone_variant", [] (pypowsybl::JavaHandle network, std::string src, std::string variant, bool mayOverwrite) {
            pypowsybl::cloneVariant(network, src, variant, mayOverwrite);
    }, "Clone a network variant into a new one");

  mod.method("set_working_variant", [] (pypowsybl::JavaHandle network, std::string variant) {
            pypowsybl::setWorkingVariant(network, variant);
    }, "Set the working variant of a network");

  mod.method("remove_variant", [] (pypowsybl::JavaHandle network, std::string variant) {
            pypowsybl::removeVariant(network, variant);
    }, "Remove a variant from a network");

  // ---------------------------------------------------------------------------
  // Network mutation
  // ---------------------------------------------------------------------------
  mod.method("remove_network_elements", [] (pypowsybl::JavaHandle network, std::vector<std::string> const& elementIds) {
            pypowsybl::removeNetworkElements(network, elementIds);
    }, "Remove elements from a network given their ids");

  mod.method("update_switch_position", [] (pypowsybl::JavaHandle network, std::string const& id, bool open) {
            return pypowsybl::updateSwitchPosition(network, id, open);
    }, "Open or close a switch, returns true if the state was changed");

  mod.method("update_connectable_status", [] (pypowsybl::JavaHandle network, std::string const& id, bool connected) {
            return pypowsybl::updateConnectableStatus(network, id, connected);
    }, "Connect or disconnect a connectable, returns true if the state was changed");

  mod.method("get_network_elements_ids", [] (pypowsybl::JavaHandle network, element_type type,
                                             std::vector<double> const& nominalVoltages,
                                             std::vector<std::string> const& countries,
                                             bool mainCc, bool mainSc, bool notConnectedToSameBusAtBothSides) {
            return pypowsybl::getNetworkElementsIds(network, type, nominalVoltages, countries, mainCc, mainSc, notConnectedToSameBusAtBothSides);
    }, "Get the ids of the elements of a given type, with optional filtering");

  // ---------------------------------------------------------------------------
  // Node/breaker and bus/breaker topology views
  // ---------------------------------------------------------------------------
  mod.method("get_node_breaker_view_nodes", [] (pypowsybl::JavaHandle network, std::string voltageLevel) {
            return pypowsybl::getNodeBreakerViewNodes(network, voltageLevel);
    }, "Get the node/breaker view nodes of a voltage level");

  mod.method("get_node_breaker_view_switches", [] (pypowsybl::JavaHandle network, std::string voltageLevel) {
            return pypowsybl::getNodeBreakerViewSwitches(network, voltageLevel);
    }, "Get the node/breaker view switches of a voltage level");

  mod.method("get_node_breaker_view_internal_connections", [] (pypowsybl::JavaHandle network, std::string voltageLevel) {
            return pypowsybl::getNodeBreakerViewInternalConnections(network, voltageLevel);
    }, "Get the node/breaker view internal connections of a voltage level");

  mod.method("get_bus_breaker_view_buses", [] (pypowsybl::JavaHandle network, std::string voltageLevel) {
            return pypowsybl::getBusBreakerViewBuses(network, voltageLevel);
    }, "Get the bus/breaker view buses of a voltage level");

  mod.method("get_bus_breaker_view_switches", [] (pypowsybl::JavaHandle network, std::string voltageLevel) {
            return pypowsybl::getBusBreakerViewSwitches(network, voltageLevel);
    }, "Get the bus/breaker view switches of a voltage level");

  mod.method("get_bus_breaker_view_elements", [] (pypowsybl::JavaHandle network, std::string voltageLevel) {
            return pypowsybl::getBusBreakerViewElements(network, voltageLevel);
    }, "Get the bus/breaker view elements of a voltage level");
  // ===========================================================================
  // Security analysis
  // ===========================================================================

  // ContingencyContextType
  mod.add_bits<contingency_context_type>("ContingencyContextType", jlcxx::julia_type("CppEnum"));
  mod.set_const("CONTINGENCY_CONTEXT_ALL", contingency_context_type::ALL);
  mod.set_const("CONTINGENCY_CONTEXT_NONE", contingency_context_type::NONE);
  mod.set_const("CONTINGENCY_CONTEXT_SPECIFIC", contingency_context_type::SPECIFIC);
  mod.set_const("CONTINGENCY_CONTEXT_ONLY_CONTINGENCIES", contingency_context_type::ONLY_CONTINGENCIES);

  // PostContingencyComputationStatus (used for both pre- and post-contingency results)
  mod.add_bits<pypowsybl::PostContingencyComputationStatus>("PostContingencyComputationStatus", jlcxx::julia_type("CppEnum"));
  mod.set_const("POST_CONTINGENCY_CONVERGED", pypowsybl::PostContingencyComputationStatus::CONVERGED);
  mod.set_const("POST_CONTINGENCY_MAX_ITERATION_REACHED", pypowsybl::PostContingencyComputationStatus::MAX_ITERATION_REACHED);
  mod.set_const("POST_CONTINGENCY_SOLVER_FAILED", pypowsybl::PostContingencyComputationStatus::SOLVER_FAILED);
  mod.set_const("POST_CONTINGENCY_FAILED", pypowsybl::PostContingencyComputationStatus::FAILED);
  mod.set_const("POST_CONTINGENCY_NO_IMPACT", pypowsybl::PostContingencyComputationStatus::NO_IMPACT);

  mod.add_type<pre_contingency_result>("PreContingencyResult")
          .method("status", [](const pre_contingency_result& r) {
             return static_cast<pypowsybl::PostContingencyComputationStatus>(r.status);
          });

  mod.add_type<post_contingency_result>("PostContingencyResult")
          .method("contingency_id", [](const post_contingency_result& r) {
             return std::string(r.contingency_id);
          })
          .method("status", [](const post_contingency_result& r) {
             return static_cast<pypowsybl::PostContingencyComputationStatus>(r.status);
          });

  mod.method("create_security_analysis", [] () {
            return pypowsybl::createSecurityAnalysis();
    }, "Create a security analysis context");

  mod.method("add_contingency", [] (pypowsybl::JavaHandle analysisContext, std::string const& contingencyId,
                                    std::vector<std::string> const& elementsIds) {
            pypowsybl::addContingency(analysisContext, contingencyId, elementsIds);
    }, "Add a contingency (list of element ids to trip) to a security analysis context");

  mod.method("add_monitored_elements", [] (pypowsybl::JavaHandle analysisContext, contingency_context_type contingencyContextType,
                                           std::vector<std::string> const& branchIds,
                                           std::vector<std::string> const& voltageLevelIds,
                                           std::vector<std::string> const& threeWindingsTransformerIds,
                                           std::vector<std::string> const& contingencyIds) {
            pypowsybl::addMonitoredElements(analysisContext, contingencyContextType, branchIds, voltageLevelIds,
                                            threeWindingsTransformerIds, contingencyIds);
    }, "Add monitored elements to a security analysis context");

  // Runs a security analysis using default security-analysis thresholds and the provided
  // load flow parameters. Returns a handle to the security analysis result.
  mod.method("run_security_analysis", [] (pypowsybl::JavaHandle analysisContext, pypowsybl::JavaHandle network,
                                          const pypowsybl::LoadFlowParameters& loadflowParameters,
                                          std::string const& provider, bool dc) {
            std::shared_ptr<pypowsybl::SecurityAnalysisParameters> parameters(pypowsybl::createSecurityAnalysisParameters());
            parameters->loadflow_parameters = loadflowParameters;
            return pypowsybl::runSecurityAnalysis(analysisContext, network, *parameters, provider, dc, nullptr);
    }, "Run a security analysis");

  mod.method("run_security_analysis_report", [] (pypowsybl::JavaHandle analysisContext, pypowsybl::JavaHandle network,
                                                 const pypowsybl::LoadFlowParameters& loadflowParameters,
                                                 std::string const& provider, bool dc, pypowsybl::JavaHandle reportNode) {
            std::shared_ptr<pypowsybl::SecurityAnalysisParameters> parameters(pypowsybl::createSecurityAnalysisParameters());
            parameters->loadflow_parameters = loadflowParameters;
            return pypowsybl::runSecurityAnalysis(analysisContext, network, *parameters, provider, dc, &reportNode);
    }, "Run a security analysis, collecting logs into a report node");

  mod.method("get_pre_contingency_result", [] (pypowsybl::JavaHandle result) {
            return pypowsybl::getPreContingencyResult(result);
    }, "Get the pre-contingency result of a security analysis");

  mod.method("get_post_contingency_results", [] (pypowsybl::JavaHandle result) {
            return powsybl_array_to_julia<post_contingency_result>(pypowsybl::getPostContingencyResults(result));
    }, "Get the post-contingency results of a security analysis");

  mod.method("get_security_analysis_limit_violations", [] (pypowsybl::JavaHandle result) {
            return pypowsybl::getLimitViolations(result);
    }, "Get all the limit violations of a security analysis result");

  mod.method("get_security_analysis_branch_results", [] (pypowsybl::JavaHandle result) {
            return pypowsybl::getBranchResults(result);
    }, "Get the monitored branch results of a security analysis result");

  mod.method("get_security_analysis_bus_results", [] (pypowsybl::JavaHandle result) {
            return pypowsybl::getBusResults(result);
    }, "Get the monitored bus results of a security analysis result");

  mod.method("get_security_analysis_three_windings_transformer_results", [] (pypowsybl::JavaHandle result) {
            return pypowsybl::getThreeWindingsTransformerResults(result);
    }, "Get the monitored three windings transformer results of a security analysis result");

  mod.method("get_security_analysis_provider_names", [] () {
            return pypowsybl::getSecurityAnalysisProviderNames();
    }, "Get the names of the available security analysis providers");
  // ===========================================================================
  // Sensitivity analysis
  // ===========================================================================

  // A dense matrix (row-major) returned by the sensitivity result getters.
  mod.add_type<matrix>("PowsyblMatrix")
          .method("row_count", [](const matrix& m) { return m.row_count; })
          .method("column_count", [](const matrix& m) { return m.column_count; })
          .method("matrix_values", [](matrix& m) {
             return jlcxx::ArrayRef<double,1>(m.values, m.row_count * m.column_count);
          });

  mod.method("create_sensitivity_analysis", [] () {
            return pypowsybl::createSensitivityAnalysis();
    }, "Create a sensitivity analysis context");

  mod.method("add_sensitivity_contingency", [] (pypowsybl::JavaHandle analysisContext, std::string const& contingencyId,
                                                std::vector<std::string> const& elementsIds) {
            pypowsybl::addContingency(analysisContext, contingencyId, elementsIds);
    }, "Add a contingency to a sensitivity analysis context");

  // Contingency context / function / variable types are passed as ints and cast to the
  // corresponding C enums, so this binding stays independent of other analysis modules.
  mod.method("add_factor_matrix", [] (pypowsybl::JavaHandle analysisContext, std::string matrixId,
                                      std::vector<std::string> const& branchesIds,
                                      std::vector<std::string> const& variablesIds,
                                      std::vector<std::string> const& contingenciesIds,
                                      int contingencyContextType, int sensitivityFunctionType, int sensitivityVariableType) {
            pypowsybl::addFactorMatrix(analysisContext, matrixId, branchesIds, variablesIds, contingenciesIds,
                                       static_cast<contingency_context_type>(contingencyContextType),
                                       static_cast<sensitivity_function_type>(sensitivityFunctionType),
                                       static_cast<sensitivity_variable_type>(sensitivityVariableType));
    }, "Add a factor matrix to a sensitivity analysis context");

  mod.method("run_sensitivity_analysis", [] (pypowsybl::JavaHandle analysisContext, pypowsybl::JavaHandle network,
                                             bool dc, const pypowsybl::LoadFlowParameters& loadflowParameters,
                                             std::string const& provider) {
            // pypowsybl 1.15.0 dropped the dc argument of runSensitivityAnalysis; the mode
            // now travels in the load flow parameters (as it does for runLoadFlow).
            std::shared_ptr<pypowsybl::SensitivityAnalysisParameters> parameters(pypowsybl::createSensitivityAnalysisParameters());
            parameters->loadflow_parameters = loadflowParameters;
            parameters->loadflow_parameters.dc = dc;
            return pypowsybl::runSensitivityAnalysis(analysisContext, network, *parameters, provider, nullptr);
    }, "Run a sensitivity analysis");

  mod.method("run_sensitivity_analysis_report", [] (pypowsybl::JavaHandle analysisContext, pypowsybl::JavaHandle network,
                                                    bool dc, const pypowsybl::LoadFlowParameters& loadflowParameters,
                                                    std::string const& provider, pypowsybl::JavaHandle reportNode) {
            std::shared_ptr<pypowsybl::SensitivityAnalysisParameters> parameters(pypowsybl::createSensitivityAnalysisParameters());
            parameters->loadflow_parameters = loadflowParameters;
            parameters->loadflow_parameters.dc = dc;
            return pypowsybl::runSensitivityAnalysis(analysisContext, network, *parameters, provider, &reportNode);
    }, "Run a sensitivity analysis, collecting logs into a report node");

  mod.method("get_sensitivity_matrix", [] (pypowsybl::JavaHandle result, std::string const& matrixId, std::string const& contingencyId) {
            return pypowsybl::getSensitivityMatrix(result, matrixId, contingencyId);
    }, "Get the sensitivity values matrix of a factor matrix for a given contingency");

  mod.method("get_reference_matrix", [] (pypowsybl::JavaHandle result, std::string const& matrixId, std::string const& contingencyId) {
            return pypowsybl::getReferenceMatrix(result, matrixId, contingencyId);
    }, "Get the reference (function) values matrix of a factor matrix for a given contingency");

  mod.method("get_sensitivity_analysis_provider_names", [] () {
            return pypowsybl::getSensitivityAnalysisProviderNames();
    }, "Get the names of the available sensitivity analysis providers");
  // ===========================================================================
  // Single line diagram (SLD) and network area diagram (NAD)
  // ===========================================================================
  // Default diagram parameters are built inside each wrapper and the optional
  // per-element override dataframes are left null, so no parameter/dataframe type
  // needs to be marshalled from Julia.

  mod.method("get_single_line_diagram_svg", [] (pypowsybl::JavaHandle network, std::string const& containerId) {
            return pypowsybl::getSingleLineDiagramSvg(network, containerId);
    }, "Get the single line diagram of a voltage level or substation as an SVG string");

  mod.method("write_single_line_diagram_svg", [] (pypowsybl::JavaHandle network, std::string const& containerId,
                                                  std::string const& svgFile, std::string const& metadataFile) {
            std::shared_ptr<pypowsybl::SldParameters> parameters(pypowsybl::createSldParameters());
            pypowsybl::writeSingleLineDiagramSvg(network, containerId, svgFile, metadataFile, *parameters, nullptr, nullptr, nullptr);
    }, "Write the single line diagram of a voltage level or substation to an SVG file");

  mod.method("get_single_line_diagram_component_library_names", [] () {
            return pypowsybl::getSingleLineDiagramComponentLibraryNames();
    }, "Get the names of the available single line diagram component libraries");

  mod.method("get_network_area_diagram_svg", [] (pypowsybl::JavaHandle network, std::vector<std::string> const& voltageLevelIds,
                                                 int depth, double highNominalVoltageBound, double lowNominalVoltageBound) {
            std::shared_ptr<pypowsybl::NadParameters> parameters(pypowsybl::createNadParameters());
            return pypowsybl::getNetworkAreaDiagramSvg(network, voltageLevelIds, depth, highNominalVoltageBound, lowNominalVoltageBound, *parameters);
    }, "Get the network area diagram as an SVG string");

  mod.method("write_network_area_diagram_svg", [] (pypowsybl::JavaHandle network, std::string const& svgFile, std::string const& metadataFile,
                                                   std::vector<std::string> const& voltageLevelIds, int depth,
                                                   double highNominalVoltageBound, double lowNominalVoltageBound) {
            std::shared_ptr<pypowsybl::NadParameters> parameters(pypowsybl::createNadParameters());
            pypowsybl::writeNetworkAreaDiagramSvg(network, svgFile, metadataFile, voltageLevelIds, depth,
                                                  highNominalVoltageBound, lowNominalVoltageBound, *parameters,
                                                  nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr);
    }, "Write the network area diagram to an SVG file");

  mod.method("get_network_area_diagram_displayed_voltage_levels", [] (pypowsybl::JavaHandle network,
                                                                      std::vector<std::string> const& voltageLevelIds, int depth) {
            return pypowsybl::getNetworkAreaDiagramDisplayedVoltageLevels(network, voltageLevelIds, depth);
    }, "Get the voltage levels displayed in a network area diagram for the given filter");
  // ===========================================================================
  // Element creation / update from a dataframe builder
  // ===========================================================================

  mod.add_type<ElementDataframe>("ElementDataframe")
        .constructor<>()
        .method("add_string_series", [] (ElementDataframe& b, std::string const& name, bool index, std::vector<std::string> const& values) {
            b.add_string_series(name, index, values);
        })
        .method("add_double_series", [] (ElementDataframe& b, std::string const& name, bool index, std::vector<double> const& values) {
            b.add_double_series(name, index, values);
        })
        .method("add_int_series", [] (ElementDataframe& b, std::string const& name, bool index, std::vector<int> const& values) {
            b.add_int_series(name, index, values);
        })
        .method("add_bool_series", [] (ElementDataframe& b, std::string const& name, bool index, std::vector<int> const& values) {
            b.add_bool_series(name, index, values);
        })
        .method("finish_dataframe", [] (ElementDataframe& b) {
            b.finish_dataframe();
        });

  mod.method("create_element", [] (pypowsybl::JavaHandle network, ElementDataframe& builder, element_type type) {
            std::vector<dataframe> dfs = builder.build_dataframes();
            dataframe_array dataframes;
            dataframes.dataframes = dfs.data();
            dataframes.dataframes_count = (int) dfs.size();
            pypowsybl::createElement(network, &dataframes, type);
    }, "Create network elements of a given type from a dataframe builder");

  mod.method("update_element", [] (pypowsybl::JavaHandle network, ElementDataframe& builder, element_type type,
                                   bool perUnit, double nominalApparentPower) {
            dataframe df = builder.build_dataframe();
            pypowsybl::updateNetworkElementsWithSeries(network, &df, type, perUnit, nominalApparentPower);
    }, "Update network elements of a given type from a dataframe builder");

  // Dataframe schema metadata (parallel arrays: names, types, index flags).
  // Types follow the series type codes: 0 = string, 1 = double, 2 = int, 3 = boolean.
  mod.method("get_element_metadata_names", [] (element_type type) {
            std::vector<std::string> result;
            for (const auto& m : pypowsybl::getNetworkDataframeMetadata(type)) { result.push_back(m.name()); }
            return result;
    }, "Get the series names of the update/read dataframe of an element type");

  mod.method("get_element_metadata_types", [] (element_type type) {
            std::vector<int> result;
            for (const auto& m : pypowsybl::getNetworkDataframeMetadata(type)) { result.push_back(m.type()); }
            return result;
    }, "Get the series types of the update/read dataframe of an element type");

  mod.method("get_element_metadata_indices", [] (element_type type) {
            std::vector<int> result;
            for (const auto& m : pypowsybl::getNetworkDataframeMetadata(type)) { result.push_back(m.isIndex() ? 1 : 0); }
            return result;
    }, "Get the index flags of the update/read dataframe of an element type");

  mod.method("get_element_creation_metadata_names", [] (element_type type) {
            std::vector<std::string> result;
            auto metadata = pypowsybl::getNetworkElementCreationDataframesMetadata(type);
            if (!metadata.empty()) { for (const auto& m : metadata[0]) { result.push_back(m.name()); } }
            return result;
    }, "Get the series names of the creation dataframe of an element type");

  mod.method("get_element_creation_metadata_types", [] (element_type type) {
            std::vector<int> result;
            auto metadata = pypowsybl::getNetworkElementCreationDataframesMetadata(type);
            if (!metadata.empty()) { for (const auto& m : metadata[0]) { result.push_back(m.type()); } }
            return result;
    }, "Get the series types of the creation dataframe of an element type");

  mod.method("get_element_creation_metadata_indices", [] (element_type type) {
            std::vector<int> result;
            auto metadata = pypowsybl::getNetworkElementCreationDataframesMetadata(type);
            if (!metadata.empty()) { for (const auto& m : metadata[0]) { result.push_back(m.isIndex() ? 1 : 0); } }
            return result;
    }, "Get the index flags of the creation dataframe of an element type");

  // Per-dataframe creation metadata, for element types that need several dataframes
  // (shunt compensators with their sections, tap changers with their steps, ...).
  mod.method("get_element_creation_dataframes_count", [] (element_type type) {
            return (int) pypowsybl::getNetworkElementCreationDataframesMetadata(type).size();
    }, "Get the number of dataframes needed to create an element type");

  mod.method("get_element_creation_metadata_names_at", [] (element_type type, int dataframeIndex) {
            std::vector<std::string> result;
            auto metadata = pypowsybl::getNetworkElementCreationDataframesMetadata(type);
            if (dataframeIndex >= 0 && dataframeIndex < (int) metadata.size()) {
                for (const auto& m : metadata[dataframeIndex]) { result.push_back(m.name()); }
            }
            return result;
    }, "Get the series names of the i-th creation dataframe of an element type");

  mod.method("get_element_creation_metadata_types_at", [] (element_type type, int dataframeIndex) {
            std::vector<int> result;
            auto metadata = pypowsybl::getNetworkElementCreationDataframesMetadata(type);
            if (dataframeIndex >= 0 && dataframeIndex < (int) metadata.size()) {
                for (const auto& m : metadata[dataframeIndex]) { result.push_back(m.type()); }
            }
            return result;
    }, "Get the series types of the i-th creation dataframe of an element type");

  mod.method("get_element_creation_metadata_indices_at", [] (element_type type, int dataframeIndex) {
            std::vector<int> result;
            auto metadata = pypowsybl::getNetworkElementCreationDataframesMetadata(type);
            if (dataframeIndex >= 0 && dataframeIndex < (int) metadata.size()) {
                for (const auto& m : metadata[dataframeIndex]) { result.push_back(m.isIndex() ? 1 : 0); }
            }
            return result;
    }, "Get the index flags of the i-th creation dataframe of an element type");

  // ===========================================================================
  // Extension creation / update / removal (reuses the ElementDataframe builder)
  // ===========================================================================

  mod.method("create_extensions", [] (pypowsybl::JavaHandle network, ElementDataframe& builder, std::string name) {
            dataframe df = builder.build_dataframe();
            dataframe_array dataframes;
            dataframes.dataframes = &df;
            dataframes.dataframes_count = 1;
            pypowsybl::createExtensions(network, &dataframes, name);
    }, "Create extensions of a given name from a dataframe builder");

  mod.method("update_extension", [] (pypowsybl::JavaHandle network, ElementDataframe& builder, std::string name, std::string tableName) {
            dataframe df = builder.build_dataframe();
            pypowsybl::updateNetworkElementsExtensionsWithSeries(network, name, tableName, &df);
    }, "Update extensions of a given name from a dataframe builder");

  mod.method("remove_extensions", [] (pypowsybl::JavaHandle network, std::string name, std::vector<std::string> const& ids) {
            pypowsybl::removeExtensions(network, name, ids);
    }, "Remove the extensions of a given name from the elements with the given ids");

  mod.method("get_extensions_information", [] () {
            return pypowsybl::getExtensionsInformation();
    }, "Get a dataframe describing all the available extensions");

  mod.method("get_extension_creation_metadata_names", [] (std::string name) {
            std::vector<std::string> result;
            auto metadata = pypowsybl::getNetworkExtensionsCreationDataframesMetadata(name);
            if (!metadata.empty()) { for (const auto& m : metadata[0]) { result.push_back(m.name()); } }
            return result;
    }, "Get the series names of the creation dataframe of an extension");

  mod.method("get_extension_creation_metadata_types", [] (std::string name) {
            std::vector<int> result;
            auto metadata = pypowsybl::getNetworkExtensionsCreationDataframesMetadata(name);
            if (!metadata.empty()) { for (const auto& m : metadata[0]) { result.push_back(m.type()); } }
            return result;
    }, "Get the series types of the creation dataframe of an extension");

  mod.method("get_extension_creation_metadata_indices", [] (std::string name) {
            std::vector<int> result;
            auto metadata = pypowsybl::getNetworkExtensionsCreationDataframesMetadata(name);
            if (!metadata.empty()) { for (const auto& m : metadata[0]) { result.push_back(m.isIndex() ? 1 : 0); } }
            return result;
    }, "Get the index flags of the creation dataframe of an extension");

  mod.method("get_extension_metadata_names", [] (std::string name, std::string tableName) {
            std::vector<std::string> result;
            for (const auto& m : pypowsybl::getNetworkExtensionsDataframeMetadata(name, tableName)) { result.push_back(m.name()); }
            return result;
    }, "Get the series names of the update dataframe of an extension");

  mod.method("get_extension_metadata_types", [] (std::string name, std::string tableName) {
            std::vector<int> result;
            for (const auto& m : pypowsybl::getNetworkExtensionsDataframeMetadata(name, tableName)) { result.push_back(m.type()); }
            return result;
    }, "Get the series types of the update dataframe of an extension");

  mod.method("get_extension_metadata_indices", [] (std::string name, std::string tableName) {
            std::vector<int> result;
            for (const auto& m : pypowsybl::getNetworkExtensionsDataframeMetadata(name, tableName)) { result.push_back(m.isIndex() ? 1 : 0); }
            return result;
    }, "Get the index flags of the update dataframe of an extension");
  // ===========================================================================
  // Reporting (ReportNode)
  // ===========================================================================

  mod.method("create_report_node", [] (std::string const& taskKey, std::string const& defaultName) {
            return pypowsybl::createReportNode(taskKey, defaultName);
    }, "Create a report node collecting functional logs");

  mod.method("print_report", [] (pypowsybl::JavaHandle reportNode) {
            return pypowsybl::printReport(reportNode);
    }, "Render a report node as a text tree");

  mod.method("json_report", [] (pypowsybl::JavaHandle reportNode) {
            return pypowsybl::jsonReport(reportNode);
    }, "Render a report node as JSON");

  // Report-aware variants: they thread a report node through the underlying call so it
  // collects the functional logs produced during execution.
  mod.method("load_report", [] (std::string const& file, StringStringMap& parameters,
                                std::vector<std::string>& postProcessors, pypowsybl::JavaHandle reportNode) {
            return pypowsybl::loadNetwork(file, parameters, postProcessors, &reportNode, false);
    }, "Load a network from a file, collecting logs into a report node");

  mod.method("run_load_flow_report", [] (const pypowsybl::JavaHandle& network, const pypowsybl::LoadFlowParameters& parameters,
                                         bool dc, const std::string& provider, pypowsybl::JavaHandle reportNode) {
            pypowsybl::LoadFlowComponentResultArray* results = pypowsybl::runLoadFlow(network, dc, parameters, provider, &reportNode);
            return powsybl_array_to_julia(results);
    }, "Run a load flow, collecting logs into a report node");
}

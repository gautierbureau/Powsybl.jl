# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

module Report
  using ..LibPowsybl

  """
  A report node collects the functional logs (a tree of typed messages) produced by
  PowSyBl operations such as a network import or a load flow. Pass it to the operations
  that accept a `report` argument, then render it with [`to_string`](@ref) or
  [`to_json`](@ref).
  """
  mutable struct ReportNode
    handle::LibPowsybl.JavaHandle
  end

  """
      create_report_node(task_key = "powsybl", default_name = "Powsybl report") -> ReportNode

  Create an empty report node. `task_key` is a key identifying the root task and
  `default_name` its human-readable name.
  """
  function create_report_node(task_key::String = "powsybl", default_name::String = "Powsybl report")
    # pypowsybl 1.16.0 dropped createReportNode's default name; keep the argument for API
    # stability but no longer forward it.
    return ReportNode(LibPowsybl.create_report_node(task_key))
  end

  """
      to_string(report::ReportNode) -> String

  Render the report as an indented text tree.
  """
  to_string(report::ReportNode) = String(LibPowsybl.print_report(report.handle))

  """
      to_json(report::ReportNode) -> String

  Render the report as JSON.
  """
  to_json(report::ReportNode) = String(LibPowsybl.json_report(report.handle))

  Base.show(io::IO, report::ReportNode) = print(io, to_string(report))
end

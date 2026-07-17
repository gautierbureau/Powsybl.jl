# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

module Log
  using ..LibPowsybl

  # PowSyBl (Java) log levels, on the same integer scale pypowsybl uses. Setting a lower
  # level makes PowSyBl emit more detail; DEBUG/TRACE include the Java stack traces.
  const TRACE = 0
  const DEBUG = 10
  const INFO = 20
  const WARN = 30
  const ERROR = 40

  """
      set_level(level::Integer = INFO)

  Set the PowSyBl (Java) log level. Use one of `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`.
  Messages at or above this level are collected and can be read with [`get_messages`](@ref);
  lower levels (`DEBUG`, `TRACE`) include the Java stack traces.
  """
  set_level(level::Integer = INFO) = (LibPowsybl.set_log_level(Int32(level)); nothing)

  """
      get_messages() -> Vector{String}

  Return the Java log messages collected since the last [`clear`](@ref), each formatted
  as `"[LEVEL] logger - message"`.
  """
  get_messages() = [String(message) for message in LibPowsybl.get_java_log_messages()]

  """
      clear()

  Discard the collected Java log messages.
  """
  clear() = (LibPowsybl.clear_java_log(); nothing)
end

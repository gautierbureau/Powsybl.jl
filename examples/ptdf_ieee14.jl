# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

# ---------------------------------------------------------------------------
# Computing PTDFs on the IEEE 14-bus network with Powsybl.jl
# ---------------------------------------------------------------------------
#
# A PTDF (Power Transfer Distribution Factor) tells you how the active power
# flow on a branch changes when 1 MW of injection is added at a node (and
# withdrawn at the slack). It is exactly a *DC* sensitivity of a branch active
# power to an injection active power, so the sensitivity analysis module
# produces the PTDF matrix directly.
#
# Run with:
#     julia --project examples/ptdf_ieee14.jl
#
# (the native binaries are provided by `Powsybl_jll`; see LOCAL_INSTALL.md if
# you are running this branch from a pre-built artifact).

using Powsybl
using Printf

const Net = Powsybl.Network
const SEN = Powsybl.SensitivityAnalysis

# 1. Build the IEEE 14-bus test network shipped with PowSyBl.
network = Net.create_ieee14()
println("Loaded network: ", network.id, " (", network.source_format, ")")

# 2. Pick the monitored branches (the "functions") and the injection variables.
#    - functions : the lines whose flow we monitor -> matrix columns
#    - variables : the generators we shift power at  -> matrix rows
branch_ids    = Vector{String}(Net.get_lines(network)[:, "id"])
generator_ids = Vector{String}(Net.get_generators(network)[:, "id"])

@printf("Monitoring %d branches against %d generator injections\n",
        length(branch_ids), length(generator_ids))

# 3. Declare a branch-active-power factor matrix. `set_branch_flow_factor_matrix`
#    is the convenience helper for the common PTDF case: it registers a
#    BRANCH_ACTIVE_POWER_1 function against AUTO_DETECT (injection) variables.
analysis = SEN.create()
SEN.set_branch_flow_factor_matrix(analysis, branch_ids, generator_ids)

# 4. Run in DC — PTDFs are, by definition, DC sensitivities.
result = SEN.run_dc(analysis, network)

# 5. Read back the matrices.
#    - ptdf[i, j]      = sensitivity of branch j flow to generator i injection
#    - reference[j]    = the base-case DC flow on branch j (MW)
ptdf      = SEN.get_sensitivity_matrix(result)   # size (n_generators, n_branches)
reference = SEN.get_reference_matrix(result)     # size (1, n_branches)

# 6. Pretty-print the PTDF matrix (branches as rows, generators as columns).
println("\nPTDF matrix (rows = branches, columns = generators):\n")

header = @sprintf("%-14s %12s", "branch", "flow[MW]")
for g in generator_ids
    header *= @sprintf(" %10s", length(g) > 10 ? g[1:10] : g)
end
println(header)
println("-"^length(header))

for (j, branch) in enumerate(branch_ids)
    row = @sprintf("%-14s %12.2f", branch, reference[1, j])
    for i in eachindex(generator_ids)
        row *= @sprintf(" %10.4f", ptdf[i, j])
    end
    println(row)
end

# 7. Sanity check: a single injection PTDF over the whole network sums (with the
#    slack) to the identity of power conservation. Here we just show the size.
@printf("\nPTDF matrix size: %d branches x %d generators\n",
        size(ptdf, 2), size(ptdf, 1))

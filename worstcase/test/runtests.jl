# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

using PowsyblWorstCase
using Powsybl
using Test

const W = PowsyblWorstCase
const NET = Powsybl.Network
Powsybl.LibPowsybl.set_config_read(false)

# pst_focus fixture: two parallel B1→B2b paths, one direct (L12a), one via the PST
# (L1_2a → PST_T), merging at B2b and exiting to B3 via L2b_3. G1 at B1, G2 + 250 MW load at B3.
function build_pst_network()
    KV = 400.0; BASE = 100.0; ZB = KV^2 / BASE
    x_of(b) = BASE / b * ZB
    net = NET.create_empty("pst_focus")
    NET.create_substations(net; id = ["S1", "S2", "S3"], country = ["FR", "FR", "FR"])
    NET.create_voltage_levels(net; id = ["VL1", "VL2a", "VL2b", "VL3"],
        substation_id = ["S1", "S2", "S2", "S3"],
        topology_kind = fill("BUS_BREAKER", 4), nominal_v = fill(KV, 4))
    NET.create_buses(net; id = ["B1", "B2a", "B2b", "B3"],
        voltage_level_id = ["VL1", "VL2a", "VL2b", "VL3"])
    NET.create_lines(net; id = ["L12a"], voltage_level1_id = ["VL1"], bus1_id = ["B1"],
        voltage_level2_id = ["VL2b"], bus2_id = ["B2b"], r = [0.0], x = [x_of(BASE / 0.2)],
        g1 = [0.0], b1 = [0.0], g2 = [0.0], b2 = [0.0])
    NET.create_lines(net; id = ["L1_2a"], voltage_level1_id = ["VL1"], bus1_id = ["B1"],
        voltage_level2_id = ["VL2a"], bus2_id = ["B2a"], r = [0.0], x = [x_of(BASE / 0.4)],
        g1 = [0.0], b1 = [0.0], g2 = [0.0], b2 = [0.0])
    NET.create_lines(net; id = ["L2b_3"], voltage_level1_id = ["VL2b"], bus1_id = ["B2b"],
        voltage_level2_id = ["VL3"], bus2_id = ["B3"], r = [0.0], x = [x_of(BASE / 0.2)],
        g1 = [0.0], b1 = [0.0], g2 = [0.0], b2 = [0.0])
    NET.create_2_windings_transformers(net; id = ["PST_T"],
        voltage_level1_id = ["VL2a"], bus1_id = ["B2a"], voltage_level2_id = ["VL2b"], bus2_id = ["B2b"],
        rated_u1 = [KV], rated_u2 = [KV], r = [0.0], x = [x_of(BASE / 0.1)], g = [0.0], b = [0.0])
    n = 21; neutral = 10
    NET.create_phase_tap_changers(net; id = "PST_T", low_tap = 0, tap = neutral,
        regulation_mode = "CURRENT_LIMITER", regulating = false, target_deadband = 0.0,
        steps = (id = fill("PST_T", n), alpha = [(i - neutral) * 3.0 for i in 0:(n-1)],
                 rho = fill(1.0, n), r = zeros(n), x = zeros(n), g = zeros(n), b = zeros(n)))
    NET.create_generators(net; id = ["G1", "G2"], voltage_level_id = ["VL1", "VL3"],
        bus_id = ["B1", "B3"], energy_source = ["OTHER", "OTHER"], min_p = [0.0, 0.0],
        max_p = [1000.0, 150.0], target_p = [200.0, 50.0], target_v = [KV, KV],
        target_q = [0.0, 0.0], voltage_regulator_on = [true, false])
    NET.create_loads(net; id = ["D3"], voltage_level_id = ["VL3"], bus_id = ["B3"], p0 = [250.0], q0 = [0.0])
    return net
end

# Extra load at B3 (bus VL3_0): injection deviation in [-100, 0] MW.
const UNCERTAIN = Dict("VL3_0" => (-100.0, 0.0))

@testset "GridModel extraction" begin
    gm = W.GridModel(build_pst_network())
    @test gm.slack == "VL1_0"                    # G1's bus
    @test gm.injection["VL1_0"] ≈ 200.0          # G1 target
    @test gm.injection["VL3_0"] ≈ -200.0         # G2 (50) − load (250)
    ids = Dict(b.id => b for b in gm.branches)
    @test ids["L12a"].h ≈ 500.0                  # V²/x = 400²/320
    @test ids["PST_T"].h ≈ 1000.0
    @test ids["PST_T"].is_pst
    @test rad2deg(ids["PST_T"].alpha_max) ≈ 30.0 atol = 1e-6
    @test rad2deg(ids["PST_T"].alpha_min) ≈ -30.0 atol = 1e-6
end

@testset "Insecure: PST cannot fully relieve the worst case" begin
    net = build_pst_network()
    sol = W.worst_case_oracle(net; uncertain = UNCERTAIN, monitored = Dict("L12a" => 110.0),
                              correctives = ["PST_T"])
    @test !W.is_secure(sol)
    @test sol.phi > 0
    @test sol.phi ≈ 0.268 atol = 5e-3            # 26.8% residual overload after best correction
    @test sol.worst_injection["VL3_0"] ≈ -100.0 atol = 1e-3   # worst = maximal extra load (a vertex)
    @test rad2deg(sol.corrective["PST_T"]) ≈ 30.0 atol = 1e-2 # PST driven to its bound
    @test sol.upper_bound - sol.lower_bound <= 1e-4           # the min-max bracket closed
end

@testset "Secure: a looser limit is coverable by correction" begin
    net = build_pst_network()
    sol = W.worst_case_oracle(net; uncertain = UNCERTAIN, monitored = Dict("L12a" => 150.0),
                              correctives = ["PST_T"])
    @test W.is_secure(sol)
    @test sol.phi < 0
end

@testset "Corrective control strictly reduces the worst-case overload" begin
    net = build_pst_network()
    with_pst = W.worst_case_oracle(net; uncertain = UNCERTAIN, monitored = Dict("L12a" => 110.0),
                                   correctives = ["PST_T"])
    no_ctrl = W.worst_case_oracle(net; uncertain = UNCERTAIN, monitored = Dict("L12a" => 110.0),
                                  correctives = String[])
    @test no_ctrl.phi ≈ 0.948 atol = 5e-3        # 94.8% overload with the reactance split, no PST
    @test with_pst.phi < no_ctrl.phi - 0.5       # the PST removes ~68 percentage points
end

@testset "N-1: contingency severs the PST path" begin
    # Outage L1_2a isolates B2a (dead-end via PST_T only), so the PST can carry no flow and all
    # power routes through L12a — a strictly worse, uncorrectable state.
    net = build_pst_network()
    sol = W.worst_case_oracle(net; uncertain = UNCERTAIN, monitored = Dict("L12a" => 110.0),
                              correctives = ["PST_T"], contingencies = ["L1_2a"])
    @test !W.is_secure(sol)
    @test sol.phi ≈ 300.0 / 110.0 - 1 atol = 1e-2   # full 300 MW on L12a in the N-1 state
end

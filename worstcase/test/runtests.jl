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

# pst_focus + a parallel direct line L_B (B1 → B3): two corridors from B1 to B3, one via the PST
# (L1_2a → PST_T → B2b → L2b_3), one direct (L_B). Outaging L_B forces all power through the PST
# corridor, overloading L12a — a contingency the *post-corrective* PST can relieve.
function build_ext()
    KV = 400.0; BASE = 100.0; ZB = KV^2 / BASE
    x_of(b) = BASE / b * ZB
    net = NET.create_empty("pst_focus_ext")
    NET.create_substations(net; id = ["S1", "S2", "S3"], country = ["FR", "FR", "FR"])
    NET.create_voltage_levels(net; id = ["VL1", "VL2a", "VL2b", "VL3"],
        substation_id = ["S1", "S2", "S2", "S3"], topology_kind = fill("BUS_BREAKER", 4),
        nominal_v = fill(KV, 4))
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
    NET.create_lines(net; id = ["L_B"], voltage_level1_id = ["VL1"], bus1_id = ["B1"],
        voltage_level2_id = ["VL3"], bus2_id = ["B3"], r = [0.0], x = [x_of(300.0)],
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

const NO_UNC = Dict("VL3_0" => (0.0, 0.0))   # isolate the contingency mechanics
# Base ≈ 70.4 MW on L12a; the N-1 (L_B out) state routes the full 200 MW through the corridor,
# giving L12a ≈ 142.86 MW (a 0.2987 pu overload against a 110 MW limit).
const N1_OVERLOAD = 200.0 * 500 / 700 / 110 - 1     # ≈ 0.2987

@testset "GridModel extraction (α⁰ from current tap)" begin
    gm = W.GridModel(build_ext())
    ids = Dict(b.id => b for b in gm.branches)
    @test Set(keys(ids)) == Set(["L12a", "L1_2a", "L2b_3", "L_B", "PST_T"])
    @test ids["PST_T"].is_pst
    @test ids["PST_T"].alpha0 ≈ 0.0 atol = 1e-9         # neutral tap ⇒ preventive angle 0
    @test rad2deg(ids["PST_T"].alpha_max) ≈ 30.0 atol = 1e-6
    @test ids["L_B"].h ≈ 300.0
end

@testset "N-1 temporary rating + post-corrective recourse ⇒ secure" begin
    # base 110, N-1 temporary rating 150 (absorbs the 142.9 briefly), post-corrective 110.
    lim = (base = 110.0, contingency = 150.0, corrective = 110.0)
    sol = W.worst_case_oracle(build_ext(); uncertain = NO_UNC, monitored = Dict("L12a" => lim),
                              correctives = ["PST_T"], contingencies = ["L_B"])
    @test W.is_secure(sol)
    @test sol.phi < 0
    # the corrective PST is driven to its bound in the post-corrective state of L_B
    @test rad2deg(sol.corrective["L_B"]["PST_T"]) ≈ 30.0 atol = 1e-2
end

@testset "Without correction the post-corrective state is insecure" begin
    lim = (base = 110.0, contingency = 150.0, corrective = 110.0)
    sol = W.worst_case_oracle(build_ext(); uncertain = NO_UNC, monitored = Dict("L12a" => lim),
                              correctives = String[], contingencies = ["L_B"])
    @test !W.is_secure(sol)
    @test sol.phi ≈ N1_OVERLOAD atol = 1e-3            # post-corrective at α⁰ still overloads
end

@testset "Correctives do not act in the pre-corrective N-1 state" begin
    # A single (permanent) limit in every state: the N-1 pre-corrective overload (142.9 > 110)
    # binds and cannot be corrected, so even with the PST the grid is insecure.
    sol = W.worst_case_oracle(build_ext(); uncertain = NO_UNC, monitored = Dict("L12a" => 110.0),
                              correctives = ["PST_T"], contingencies = ["L_B"])
    @test !W.is_secure(sol)
    @test sol.phi ≈ N1_OVERLOAD atol = 1e-3
end

@testset "Correctives do not rescue the base state" begin
    # Base limit tightened below the base flow (≈70.4 MW): the base state overloads, and since
    # correctives act only post-contingency, no PST action can fix it.
    lim = (base = 55.0, contingency = 150.0, corrective = 110.0)
    sol = W.worst_case_oracle(build_ext(); uncertain = NO_UNC, monitored = Dict("L12a" => lim),
                              correctives = ["PST_T"], contingencies = ["L_B"])
    @test !W.is_secure(sol)
    @test sol.phi ≈ 200.0 * 500 / 700 * (291.67 / 591.67) / 55 - 1 atol = 5e-3   # base ≈ 70.4/55 − 1
end

@testset "Base-only robust check (no contingency, no corrective action)" begin
    # With no contingency there is no post-corrective state, so the PST cannot act; extra load
    # that overloads L12a in the base state is therefore uncorrectable.
    unc = Dict("VL3_0" => (-150.0, 0.0))
    tight = W.worst_case_oracle(build_ext(); uncertain = unc, monitored = Dict("L12a" => 90.0),
                                correctives = ["PST_T"])
    @test !W.is_secure(tight)
    @test tight.worst_injection["VL3_0"] ≈ -150.0 atol = 1e-2   # worst = max extra load (a vertex)
    loose = W.worst_case_oracle(build_ext(); uncertain = unc, monitored = Dict("L12a" => 300.0),
                                correctives = ["PST_T"])
    @test W.is_secure(loose)
end

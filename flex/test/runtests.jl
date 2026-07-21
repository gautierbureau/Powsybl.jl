# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

using PowsyblFlexibility
using Powsybl
using Test

const NET = Powsybl.Network
Powsybl.LibPowsybl.set_config_read(false)

# A single corridor B1 → B2: generator G1 (slack, 100 MW, headroom to `g1max`) at B1 feeds a
# 100 MW load at B2 across line L12. A local generator G2 (idle, large headroom) sits at B2.
# Injection uncertainty at B2 (bus id VL2_0) grows the load; the whole change flows over L12.
# Analytic facts (base flow = 100 MW):
#   • worst L12 flow at region scaling δ (single slack) = 100 + δ  ⇒ δ* = P^lim − 100
#   • copper-plate bound (only G1 responds)             = g1max − 100
#   • with G1+G2 sharing the pickup, worst flow = 100 + δ/2       ⇒ δ* = 2 (P^lim − 100)
function build_corridor(; g1max = 300.0)
    KV = 400.0; BASE = 100.0; ZB = KV^2 / BASE
    net = NET.create_empty("corridor")
    NET.create_substations(net; id = ["S1", "S2"], country = ["FR", "FR"])
    NET.create_voltage_levels(net; id = ["VL1", "VL2"], substation_id = ["S1", "S2"],
        topology_kind = fill("BUS_BREAKER", 2), nominal_v = fill(KV, 2))
    NET.create_buses(net; id = ["B1", "B2"], voltage_level_id = ["VL1", "VL2"])
    NET.create_lines(net; id = ["L12"], voltage_level1_id = ["VL1"], bus1_id = ["B1"],
        voltage_level2_id = ["VL2"], bus2_id = ["B2"], r = [0.0], x = [BASE / 0.5 * ZB],
        g1 = [0.0], b1 = [0.0], g2 = [0.0], b2 = [0.0])
    NET.create_generators(net; id = ["G1", "G2"], voltage_level_id = ["VL1", "VL2"],
        bus_id = ["B1", "B2"], energy_source = ["OTHER", "OTHER"], min_p = [0.0, 0.0],
        max_p = [g1max, 1000.0], target_p = [100.0, 0.0], target_v = [KV, KV],
        target_q = [0.0, 0.0], voltage_regulator_on = [true, false])
    NET.create_loads(net; id = ["D2"], voltage_level_id = ["VL2"], bus_id = ["B2"], p0 = [100.0], q0 = [0.0])
    return net
end

const BASE0 = Dict("VL2_0" => (0.0, 0.0))            # forecast box: no deviation, pure δ-scaling
const LOAD_ONLY = Dict("VL2_0" => (1.0, 0.0))        # grow only the load (lower) side by δ

@testset "Copper-plate bound (network-free adequacy)" begin
    # Load-only growth ⇒ the worst deficit Σy = −δ exhausts G1's up-headroom (g1max − 100) at
    # δ = g1max − 100. Only G1 (the slack-bus generator) responds under a single slack.
    dcp, phi0 = copperplate_bound(build_corridor(; g1max = 300.0), BASE0; weights = LOAD_ONLY)
    @test dcp ≈ 200.0 atol = 1e-6
    @test phi0 < 0                              # the forecast box is balanceable
    # Sharing across G1+G2 (1000 MW headroom) lifts the adequacy bound far out.
    dcp2, _ = copperplate_bound(build_corridor(), BASE0; weights = LOAD_ONLY,
                                participation = Dict("G1" => 1.0, "G2" => 1.0))
    @test dcp2 ≈ 1200.0 atol = 1e-6
end

@testset "flexibility_max: network limit binds (bisection)" begin
    # P^lim = 150 ⇒ δ* = 50 (worst flow 100 + δ). Copper-plate (200) is a loose upper bound.
    r = flexibility_max(build_corridor(; g1max = 300.0); base = BASE0, weights = LOAD_ONLY,
                        monitored = Dict("L12" => 150.0), tol = 0.05)
    @test r.secure_at_base
    @test r.delta ≈ 50.0 atol = 0.2
    @test r.delta_cp ≈ 200.0 atol = 1e-6
    @test r.delta ≤ r.delta_cp                 # copper-plate is a valid upper bound
    @test r.worst_injection["VL2_0"] ≈ -50.0 atol = 0.5   # binding worst case = max extra load
end

@testset "flexibility_max: copper-plate adequacy binds" begin
    # Tighten G1 to 115 MW: generation runs out (δ_cp = 15) before the 150 MW line would (δ = 50),
    # so the flexibility is capped by adequacy — δ* = δ_cp.
    r = flexibility_max(build_corridor(; g1max = 115.0); base = BASE0, weights = LOAD_ONLY,
                        monitored = Dict("L12" => 150.0), tol = 0.05)
    @test r.delta_cp ≈ 15.0 atol = 1e-6
    @test r.delta ≈ 15.0 atol = 0.2
end

@testset "flexibility_max: a participating local generator enlarges flexibility" begin
    slack = flexibility_max(build_corridor(); base = BASE0, weights = LOAD_ONLY,
                            monitored = Dict("L12" => 150.0), tol = 0.05)
    part  = flexibility_max(build_corridor(); base = BASE0, weights = LOAD_ONLY,
                            monitored = Dict("L12" => 150.0),
                            participation = Dict("G1" => 1.0, "G2" => 1.0), tol = 0.05)
    @test slack.delta ≈ 50.0 atol = 0.3
    @test part.delta ≈ 100.0 atol = 0.5        # G2 shares the load ⇒ flow 100 + δ/2 ⇒ δ* doubles
    @test part.delta > slack.delta + 40.0
end

@testset "flexibility_max: insecure at the forecast box ⇒ zero flexibility" begin
    # P^lim = 90 < base flow 100: the forecast itself overloads, so there is no flexibility.
    r = flexibility_max(build_corridor(); base = BASE0, weights = LOAD_ONLY,
                        monitored = Dict("L12" => 90.0), tol = 0.05)
    @test !r.secure_at_base
    @test r.delta == 0.0
end

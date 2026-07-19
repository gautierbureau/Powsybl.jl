# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

using PowsyblDcOpf
using Powsybl
using Test

Powsybl.LibPowsybl.set_config_read(false)

const D = PowsyblDcOpf
const NET = Powsybl.Network

# Relaxed limits that leave L12a uncongested (PST stays near neutral).
const UNCONGESTED = Dict("L12a" => 250.0, "L1_2a" => 150.0, "L2b_3" => 200.0)

@testset "Fixture network (pst_focus)" begin
    net = D.build_pst_network()
    @test Set(NET.get_generators(net).id) == Set(["G1", "G2"])
    @test Set(NET.get_loads(net).id) == Set(["D3"])
    @test size(NET.get_buses(net), 1) == 4
    lines = NET.get_lines(net, true)
    @test Set(lines.id) == Set(["L12a", "L1_2a", "L2b_3"])
    # ideal reactances on a 400 kV / 100 MVA base: x = V²/b
    xz = Dict(lines[i, :id] => lines[i, :x] for i in 1:size(lines, 1))
    @test xz["L12a"] ≈ 320.0
    @test xz["L1_2a"] ≈ 640.0
    @test xz["L2b_3"] ≈ 320.0
    tfos = NET.get_2_windings_transformers(net, true)
    @test tfos[1, :id] == "PST_T"
    @test tfos[1, :x] ≈ 160.0
    psts = NET.get_phase_tap_changers(net, true)
    @test psts[1, :low_tap] == 0 && psts[1, :high_tap] == 20 && psts[1, :tap] == 10
end

@testset "θ and PTDF formulations agree (congested)" begin
    net = D.build_pst_network()
    th = D.theta_formulation(net)
    pt = D.ptdf_formulation(net)

    @test string(th.termination) == "OPTIMAL"
    @test string(pt.termination) == "OPTIMAL"

    # Cheap G1 is capped by the L2b_3 exit limit (200 MW) forcing G2 ≥ 50.
    @test th.generation["G1"] ≈ 200.0 atol = 1e-3
    @test th.generation["G2"] ≈ 50.0 atol = 1e-3

    # Two binding constraints: the exit line and the (congested) direct path.
    @test th.flows["L2b_3"] ≈ 200.0 atol = 1e-3
    @test th.flows["L12a"] ≈ 110.0 atol = 1e-3
    @test th.flows["PST_T"] ≈ 90.0 atol = 1e-3
    @test th.flows["L1_2a"] ≈ 90.0 atol = 1e-3

    # The PST shifts flow onto its path (positive angle) to relieve L12a.
    @test th.phi["PST_T"] > 0
    @test rad2deg(th.phi["PST_T"]) ≈ 13.178 atol = 1e-2

    # Generation cost 30·200 + 45·50 + PST wear 5·φ.
    @test th.cost ≈ 8251.15 atol = 0.05

    # The two formulations must coincide branch-by-branch and on cost / dispatch / angle.
    for br in keys(th.flows)
        @test th.flows[br] ≈ pt.flows[br] atol = 1e-4
    end
    @test th.cost ≈ pt.cost atol = 1e-4
    @test th.generation["G1"] ≈ pt.generation["G1"] atol = 1e-4
    @test th.generation["G2"] ≈ pt.generation["G2"] atol = 1e-4
    @test th.phi["PST_T"] ≈ pt.phi["PST_T"] atol = 1e-6

    # θ formulation invariants: slack angle is zero; the PTDF one carries no angles.
    @test th.angles["VL1_0"] ≈ 0.0 atol = 1e-9
    @test isempty(pt.angles)
end

@testset "DC load flow validation — uncongested (φ = 0, exact)" begin
    # With L12a uncongested the PST stays at neutral (tap 10), so the discrete deployment
    # reproduces the continuous optimum exactly.
    net = D.build_pst_network()
    th = D.theta_formulation(net; line_max_p = UNCONGESTED)
    pt = D.ptdf_formulation(net; line_max_p = UNCONGESTED)

    @test rad2deg(th.phi["PST_T"]) ≈ 0.0 atol = 1e-6
    @test th.flows["L12a"] ≈ 142.857 atol = 1e-2   # 200 · 800/1120 (reactance split)
    @test th.flows["L1_2a"] ≈ 57.143 atol = 1e-2
    for br in keys(th.flows)
        @test th.flows[br] ≈ pt.flows[br] atol = 1e-4
    end

    lf = D.validate_with_dc_loadflow(net, th)
    @test D.phi_to_tap(th.phi["PST_T"]) == 10
    for br in keys(lf)
        @test lf[br] ≈ th.flows[br] atol = 1e-2
    end
end

@testset "DC load flow validation — congested (tap-quantised)" begin
    net = D.build_pst_network()
    th = D.theta_formulation(net)
    lf = D.validate_with_dc_loadflow(net, th)

    # φ = 13.18° rounds to tap 14 (12°); flows track the OPF within one tap step, and the
    # exit line — set purely by the balance, not the PST — matches exactly.
    @test D.phi_to_tap(th.phi["PST_T"]) == 14
    @test lf["L2b_3"] ≈ th.flows["L2b_3"] atol = 1e-3
    for br in keys(lf)
        @test lf[br] ≈ th.flows[br] atol = 4.0
    end
end

@testset "PST relieves congestion" begin
    net = D.build_pst_network()
    tight = D.theta_formulation(net)                      # L12a ≤ 110 → PST active
    loose = D.theta_formulation(net; line_max_p = UNCONGESTED)  # L12a ≤ 250 → PST idle

    @test rad2deg(loose.phi["PST_T"]) ≈ 0.0 atol = 1e-6
    @test tight.phi["PST_T"] > loose.phi["PST_T"]
    @test tight.flows["L12a"] < loose.flows["L12a"]   # PST pushed flow off the direct path
    @test tight.cost >= loose.cost                    # congestion is never cheaper
end

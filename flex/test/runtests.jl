# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

using PowsyblFlexibility
using PowsyblWorstCase
using Powsybl
using Test

const W = PowsyblWorstCase

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

@testset "Copper-plate exchange interval" begin
    # Only G1 (100 MW at the slack bus) responds: up-headroom g1max−100, down-headroom 100.
    # An import by the zone needs up-regulation, an export needs down-regulation.
    lo, hi = copperplate_exchange_interval(build_corridor(; g1max = 300.0), ["VL2_0"])
    @test hi ≈ 200.0 atol = 1e-6
    @test lo ≈ -100.0 atol = 1e-6
end

@testset "max_exchange: the transfer the corridor can absorb" begin
    # Base flow 100 MW on L12; an import of E at B2 adds E to it, so with P^lim = 150 the largest
    # manageable exchange is 50 MW — strictly inside the 200 MW copper-plate bound.
    box = Dict("VL2_0" => (-1000.0, 0.0))        # per-bus box loose: the exchange bound binds
    r = max_exchange(build_corridor(; g1max = 300.0); zone = ["VL2_0"], box = box,
                     monitored = Dict("L12" => 150.0), method = :bisection, tol = 0.05)
    @test r.secure_at_zero
    @test r.emax ≈ 50.0 atol = 0.2
    @test r.interval == (-100.0, 200.0)
    @test r.emax < r.interval[2]                 # copper plate is a valid outer bound

    # Generation adequacy can bind before the network does: cap G1 at 115 MW and the copper-plate
    # bound (15 MW) is below the 50 MW the line would allow, so it decides.
    r2 = max_exchange(build_corridor(; g1max = 115.0); zone = ["VL2_0"], box = box,
                      monitored = Dict("L12" => 150.0), method = :bisection, tol = 0.05)
    @test r2.interval[2] ≈ 15.0 atol = 1e-6
    @test r2.emax ≈ 15.0 atol = 0.2
end

@testset "max_exchange: a participating local generator raises the transfer" begin
    box = Dict("VL2_0" => (-1000.0, 0.0))
    slack = max_exchange(build_corridor(); zone = ["VL2_0"], box = box,
                         monitored = Dict("L12" => 150.0), method = :bisection, tol = 0.05)
    part  = max_exchange(build_corridor(); zone = ["VL2_0"], box = box,
                         monitored = Dict("L12" => 150.0), method = :bisection,
                         participation = Dict("G1" => 1.0, "G2" => 1.0), emax_cap = 400.0, tol = 0.05)
    @test slack.emax ≈ 50.0 atol = 0.3
    @test part.emax ≈ 100.0 atol = 0.5           # G2 covers half the import locally
end

@testset "max_exchange: a restriction gives a conservative (achievable) transfer" begin
    # Requiring a margin instead of bare security can only shrink the answer, and the restricted
    # value is guaranteed achievable — it still passes the *exact* test.
    box = Dict("VL2_0" => (-1000.0, 0.0))
    mon = Dict("L12" => 150.0)
    exact = max_exchange(build_corridor(; g1max = 300.0); zone = ["VL2_0"], box = box,
                         monitored = mon, method = :bisection, tol = 0.02)
    restr = max_exchange(build_corridor(; g1max = 300.0); zone = ["VL2_0"], box = box,
                         monitored = mon, method = :bisection, tol = 0.02, restriction = 0.1)
    @test restr.emax < exact.emax                 # a margin costs transfer
    @test restr.emax > 0.0
    # the conservative answer really is securable: re-check it with the exact test
    check = W.worst_case_oracle(build_corridor(; g1max = 300.0); uncertain = box, monitored = mon,
                exchange = (buses = ["VL2_0"], lo = -restr.emax, hi = 0.0))
    @test W.is_secure(check)
    # limit ratio 150 MW ⇒ a 10% margin means the flow may reach only 135 MW ⇒ 35 MW of transfer
    @test restr.emax ≈ 35.0 atol = 0.5
end

@testset "flexibility_max: insecure at the forecast box ⇒ zero flexibility" begin
    # P^lim = 90 < base flow 100: the forecast itself overloads, so there is no flexibility.
    r = flexibility_max(build_corridor(); base = BASE0, weights = LOAD_ONLY,
                        monitored = Dict("L12" => 90.0), tol = 0.05)
    @test !r.secure_at_base
    @test r.delta == 0.0
end

@testset "max_exchange: cuts and bisection agree (cuts in one solve)" begin
    # The cutting method makes the exchange the objective, so it lands on the frontier directly;
    # bisection probes levels. They must agree, and the cut answer is exact rather than tol-limited.
    box = Dict("VL2_0" => (-1000.0, 0.0))
    mon = Dict("L12" => 150.0)
    cuts = max_exchange(build_corridor(; g1max = 300.0); zone = ["VL2_0"], box = box, monitored = mon)
    bis  = max_exchange(build_corridor(; g1max = 300.0); zone = ["VL2_0"], box = box, monitored = mon,
                        method = :bisection, tol = 0.01)
    @test cuts.emax ≈ 50.0 atol = 1e-3          # exact, not tolerance-limited
    @test cuts.emax ≈ bis.emax atol = 0.05      # and it agrees with the independent search
    @test cuts.iterations == 1                  # one solve, no level probing
    @test cuts.worst_injection["VL2_0"] ≈ -50.0 atol = 0.1

    # Adequacy-bound case: the copper plate caps the range and nothing violates inside it.
    r = max_exchange(build_corridor(; g1max = 115.0); zone = ["VL2_0"], box = box, monitored = mon)
    @test r.emax ≈ 15.0 atol = 1e-3
end

@testset "exchange_bracket: two-sided bounding of the maximum exchange" begin
    # Running the menu programme at +ε and at −ε encloses the frontier: the first reports a
    # transfer that is certainly securable, the second one that certainly is not, and shrinking ε
    # brings them together on the exact answer (50 MW here).
    box = Dict("VL2_0" => (-1000.0, 0.0))
    mon = Dict("L12" => 150.0)
    b = exchange_bracket(build_corridor(; g1max = 300.0); zone = ["VL2_0"], box = box,
                         monitored = mon, init_restriction = 0.1, reduction = 0.25, tol = 0.5)
    @test b.lower <= 50.0 <= b.upper
    @test b.upper - b.lower <= 0.5
    @test b.rounds < 8                            # closed before exhausting the schedule
    @test b.interval == (-100.0, 200.0)

    # Both bounds are valid from the first round, so a bracket stopped early is still usable —
    # and the lower one is a transfer the exact oracle confirms.
    early = exchange_bracket(build_corridor(; g1max = 300.0); zone = ["VL2_0"], box = box,
                             monitored = mon, init_restriction = 0.1, reduction = 0.25,
                             tol = 0.5, max_rounds = 1)
    @test early.rounds == 1
    @test early.lower < b.lower                   # looser, but still on the right side
    @test early.upper > b.upper
    @test early.lower <= 50.0 <= early.upper
    @test W.is_secure(W.worst_case_oracle(build_corridor(; g1max = 300.0); uncertain = box,
                monitored = mon, exchange = (buses = ["VL2_0"], lo = -early.lower, hi = 0.0)))

    @test_throws ArgumentError exchange_bracket(build_corridor(); zone = ["VL2_0"], box = box,
                                                monitored = mon, init_restriction = 0.0)
    @test_throws ArgumentError exchange_bracket(build_corridor(); zone = ["VL2_0"], box = box,
                                                monitored = mon, reduction = 1.0)
end

@testset "certifying_scenario: confirm a reported range, or produce the counter-example" begin
    # The corridor holds 50 MW of import against a 150 MW rating on L12. Searching that whole
    # range for the worst violation is what turns the reported figure into a checkable claim.
    box = Dict("VL2_0" => (-1000.0, 0.0))
    mon = Dict("L12" => 150.0)
    net() = build_corridor(; g1max = 300.0)

    ok = certifying_scenario(net(); zone = ["VL2_0"], box = box, monitored = mon, emax = 50.0)
    @test ok.clear                                # nothing in [0, 50] violates
    @test ok.phi <= 0.0
    @test ok.tested[2] < 50.0                     # stepped just inside the reported bound

    # Overstate the answer and the certificate fails, handing back the scenario that breaks it.
    bad = certifying_scenario(net(); zone = ["VL2_0"], box = box, monitored = mon, emax = 80.0)
    @test !bad.clear
    @test bad.phi ≈ 180.0 / 150.0 - 1 atol = 5e-3          # 100 + 80 MW over a 150 MW rating
    @test bad.exchange ≈ 80.0 atol = 0.1                   # the binding transfer is the top of the range
    @test bad.injection["VL2_0"] ≈ -80.0 atol = 0.1
    @test bad.binding.branch == "L12"
    @test bad.binding.direction == :forward

    # An extension deliberately looks past the boundary, so it finds a failure by construction —
    # useful as an illustration, not as a test of the interval.
    ext = certifying_scenario(net(); zone = ["VL2_0"], box = box, monitored = mon,
                              emax = 50.0, extension = 60.0)
    @test ext.tested[2] ≈ 80.0 atol = 1e-3
    @test !ext.clear
    @test ext.phi ≈ bad.phi atol = 5e-3

    # The frontier and the certificate have to agree: whatever max_exchange reports must certify.
    e = max_exchange(net(); zone = ["VL2_0"], box = box, monitored = mon).emax
    @test certifying_scenario(net(); zone = ["VL2_0"], box = box, monitored = mon, emax = e).clear

    @test_throws ArgumentError certifying_scenario(net(); zone = ["VL2_0"], box = box,
                                                   monitored = mon, emax = 50.0, extension = -1.0)
end

@testset "Monitored screening reaches the search unchanged" begin
    # `screen = true` is forwarded to the oracle like any other keyword, so every entry point here
    # inherits it. Dropping branches that cannot fail must not move any reported answer.
    box = Dict("VL2_0" => (-1000.0, 0.0))
    mon = Dict{String,Any}("L12" => 150.0)     # the corridor's only branch, and it can bind
    net() = build_corridor(; g1max = 300.0)

    @test max_exchange(net(); zone = ["VL2_0"], box = box, monitored = mon, screen = true).emax ≈
          max_exchange(net(); zone = ["VL2_0"], box = box, monitored = mon).emax atol = 1e-6
    @test certifying_scenario(net(); zone = ["VL2_0"], box = box, monitored = mon,
                              emax = 50.0, screen = true).clear
    b = exchange_bracket(net(); zone = ["VL2_0"], box = box, monitored = mon, tol = 0.5,
                         screen = true)
    @test b.lower <= 50.0 <= b.upper
end

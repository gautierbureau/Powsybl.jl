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
function build_ext(; with_LB = true)
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
    with_LB && NET.create_lines(net; id = ["L_B"], voltage_level1_id = ["VL1"], bus1_id = ["B1"],
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
    @test ids["PST_T"] isa W.Pst
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

@testset "Secondary frequency response (participation factors)" begin
    # Extra load up to 200 MW at B3, monitor L12a ≤ 110. Under a single slack (all pickup at B1)
    # the whole imbalance flows down the corridor and overloads L12a; with a participation-factor
    # response the local generator G2 shares the pickup, halving the corridor flow.
    unc = Dict("VL3_0" => (-200.0, 0.0))
    mon = Dict("L12a" => 110.0)
    slack = W.worst_case_oracle(build_ext(); uncertain = unc, monitored = mon)
    part  = W.worst_case_oracle(build_ext(); uncertain = unc, monitored = mon,
                                participation = Dict("G1" => 1.0, "G2" => 1.0))
    g1only = W.worst_case_oracle(build_ext(); uncertain = unc, monitored = mon,
                                 participation = Dict("G1" => 1.0))

    @test !W.is_secure(slack)
    @test slack.phi ≈ 0.2804 atol = 5e-3
    @test W.is_secure(part)                    # local sharing keeps L12a within its limit
    @test part.phi ≈ -0.0397 atol = 5e-3
    @test part.phi < slack.phi - 0.2           # the response strictly reduces the worst-case flow
    @test g1only.phi ≈ slack.phi atol = 5e-3   # only G1 responds ⇒ equivalent to a single slack
end

@testset "Participation saturates at generator limits (mid clamp)" begin
    # G2 has 100 MW of headroom (50 → 150 MW). Beyond ~200 MW of extra load it saturates, the
    # response reverts toward the single slack, and a 250 MW excess is insecure again.
    unc = Dict("VL3_0" => (-250.0, 0.0))
    part = W.worst_case_oracle(build_ext(); uncertain = unc, monitored = Dict("L12a" => 110.0),
                               participation = Dict("G1" => 1.0, "G2" => 1.0))
    slack = W.worst_case_oracle(build_ext(); uncertain = unc, monitored = Dict("L12a" => 110.0))
    @test !W.is_secure(part)                   # G2 capped ⇒ can no longer keep it secure
    @test part.phi < slack.phi                 # but still helps partially vs. the single slack
end

@testset "HVDC AC-emulation clamp (3-mode disjunction)" begin
    # An HVDC B1→B3 in AC-emulation shares the corridor flow (K = 300 MW/rad). With 100 MW of
    # extra load and L12a ≤ 110, a generous limit keeps the grid secure; as the hard limit P^lim
    # tightens the HVDC saturates and helps less; at P^lim = 0 it is equivalent to no HVDC.
    unc = Dict("VL3_0" => (-100.0, 0.0)); mon = Dict("L12a" => 110.0)
    hv(pl) = [(id = "H1", bus1 = "VL1_0", bus2 = "VL3_0", k = 300.0, p_zero = 0.0, p_lim = pl)]
    open   = W.worst_case_oracle(build_ext(with_LB = false); uncertain = unc, monitored = mon, hvdc = hv(1000.0))
    capped = W.worst_case_oracle(build_ext(with_LB = false); uncertain = unc, monitored = mon, hvdc = hv(50.0))
    off    = W.worst_case_oracle(build_ext(with_LB = false); uncertain = unc, monitored = mon, hvdc = hv(0.0))
    none   = W.worst_case_oracle(build_ext(with_LB = false); uncertain = unc, monitored = mon)

    @test W.is_secure(open)                       # unclamped HVDC carries its share ⇒ secure
    @test !W.is_secure(capped)                    # clamp binds ⇒ can no longer keep L12a in limit
    @test capped.phi > open.phi + 0.5
    @test off.phi ≈ none.phi atol = 1e-6          # a zero-limit HVDC ≡ no HVDC
end

@testset "PST over-current (disconnection disjunction)" begin
    # Contingency L_B; the corrective PST relieves L12a in the post-corrective state only if its
    # own rating allows it. A 150 MW rating is enough (regulates to +30°); a 50 MW rating caps
    # the PST so it cannot keep L12a within its 110 MW permanent limit.
    unc = Dict("VL3_0" => (0.0, 0.0))
    lim = (base = 110.0, contingency = 150.0, corrective = 110.0)
    ample = W.worst_case_oracle(build_ext(); uncertain = unc, monitored = Dict("L12a" => lim),
                                correctives = ["PST_T"], switchable = ["PST_T"],
                                pst_limits = Dict("PST_T" => 150.0), contingencies = ["L_B"])
    tight = W.worst_case_oracle(build_ext(); uncertain = unc, monitored = Dict("L12a" => lim),
                                correctives = ["PST_T"], switchable = ["PST_T"],
                                pst_limits = Dict("PST_T" => 50.0), contingencies = ["L_B"])
    @test W.is_secure(ample)
    @test !W.is_secure(tight)
    # PST capped at 50 MW ⇒ post-corrective L12a = 200 − 50 = 150 MW against a 110 MW limit
    @test tight.phi ≈ 150.0 / 110.0 - 1 atol = 5e-3
end

@testset "Full PST automaton (activation, target regulation, over-current propagation)" begin
    # After the L_B outage the PST corridor carries ≈ 57.14 MW (= 200 · 320/1120). The full
    # automaton (pst_model) then decides, per contingency: stay inactive at α⁰, activate and
    # regulate toward ±P^tar once |P^{N-1}| ≥ P^act, or trip on over-current and propagate the
    # trip forward. The trip is pinned by the connected-reference over-current test, so the
    # physical (maximally-connected) equilibrium is selected — no spurious disconnection.
    nat = 200.0 * 320 / 1120            # ≈ 57.14 MW PST corridor flow after L_B out
    orc(mon, pm) = W.worst_case_oracle(build_ext(); uncertain = NO_UNC, monitored = mon,
                                       contingencies = ["L_B"], pst_model = pm)

    # (1) activation + target regulation: |57| ≥ P^act = 50 ⇒ regulate toward P^tar = 30.
    monP = Dict("PST_T" => (base = 1e4, contingency = 1e4, corrective = 40.0))
    reg = orc(monP, Dict("PST_T" => (p_lim = 300.0, p_act = 50.0, p_tar = 30.0)))
    @test W.is_secure(reg)
    @test reg.phi ≈ 30.0 / 40.0 - 1 atol = 5e-3          # regulated to +30 MW ⇒ within the 40 MW monitor

    # (2) below the activation threshold (P^act = 100 > 57): the PST stays inactive at α⁰.
    off = orc(monP, Dict("PST_T" => (p_lim = 300.0, p_act = 100.0, p_tar = 30.0)))
    @test !W.is_secure(off)
    @test off.phi ≈ nat / 40.0 - 1 atol = 5e-3           # uncorrected 57 MW overloads the 40 MW monitor

    # (3) over-current trip + forward propagation: P^lim = 40 < 57 ⇒ the PST trips in N-1 and
    # stays open post-corrective, so all 200 MW routes through L12a (monitor ≤ 150 in N-1/c).
    monL = Dict("L12a" => (base = 1e4, contingency = 1e4, corrective = 150.0))
    trip = orc(monL, Dict("PST_T" => (p_lim = 40.0, p_act = 50.0, p_tar = 30.0)))
    @test !W.is_secure(trip)
    @test trip.phi ≈ 200.0 / 150.0 - 1 atol = 5e-3       # PST tripped ⇒ L12a = 200 MW

    # (4) no over-current (P^lim = 300 ≫ 57) and never activated: the PST stays connected at α⁰
    # and the corridor split leaves L12a ≈ 142.86 MW, within the 150 MW monitor. This is the
    # case the reference-flow trip test protects: a spurious "trip" (which would zero the
    # corridor and satisfy the monitor) is impossible because |P_ref| = 57 < 300.
    stay = orc(monL, Dict("PST_T" => (p_lim = 300.0, p_act = 1000.0, p_tar = 200.0)))
    @test W.is_secure(stay)
    @test stay.phi ≈ (200.0 * 500 / 700) / 150.0 - 1 atol = 5e-3   # L12a ≈ 142.86 MW, PST stays
end

# Two B1→B3 corridors, each through a PST: corridor A via PST_T (full automaton) and corridor F
# via PST_F (a *free* corrective the operator controls). Outaging L_B loads both corridors.
function build_two_pst()
    KV = 400.0; BASE = 100.0; ZB = KV^2 / BASE
    x_of(b) = BASE / b * ZB
    net = NET.create_empty("two_pst")
    NET.create_substations(net; id = ["S1", "S2", "S3", "S4"], country = fill("FR", 4))
    NET.create_voltage_levels(net; id = ["VL1", "VL2a", "VL2b", "VL3", "VL4a", "VL4b"],
        substation_id = ["S1", "S2", "S2", "S3", "S4", "S4"], topology_kind = fill("BUS_BREAKER", 6),
        nominal_v = fill(KV, 6))
    NET.create_buses(net; id = ["B1", "B2a", "B2b", "B3", "B4a", "B4b"],
        voltage_level_id = ["VL1", "VL2a", "VL2b", "VL3", "VL4a", "VL4b"])
    for (id, v1, b1, v2, b2, xx) in [
            ("L12a", "VL1", "B1", "VL2b", "B2b", x_of(BASE / 0.2)),
            ("L1_2a", "VL1", "B1", "VL2a", "B2a", x_of(BASE / 0.4)),
            ("L2b_3", "VL2b", "B2b", "VL3", "B3", x_of(BASE / 0.2)),
            ("L1_4a", "VL1", "B1", "VL4a", "B4a", x_of(BASE / 0.4)),
            ("L4b_3", "VL4b", "B4b", "VL3", "B3", x_of(BASE / 0.2)),
            ("L_B", "VL1", "B1", "VL3", "B3", x_of(300.0))]
        NET.create_lines(net; id = [id], voltage_level1_id = [v1], bus1_id = [b1],
            voltage_level2_id = [v2], bus2_id = [b2], r = [0.0], x = [xx],
            g1 = [0.0], b1 = [0.0], g2 = [0.0], b2 = [0.0])
    end
    NET.create_2_windings_transformers(net; id = ["PST_T", "PST_F"],
        voltage_level1_id = ["VL2a", "VL4a"], bus1_id = ["B2a", "B4a"],
        voltage_level2_id = ["VL2b", "VL4b"], bus2_id = ["B2b", "B4b"],
        rated_u1 = fill(KV, 2), rated_u2 = fill(KV, 2), r = fill(0.0, 2),
        x = fill(x_of(BASE / 0.1), 2), g = fill(0.0, 2), b = fill(0.0, 2))
    n = 21; neutral = 10
    for pid in ["PST_T", "PST_F"]
        NET.create_phase_tap_changers(net; id = pid, low_tap = 0, tap = neutral,
            regulation_mode = "CURRENT_LIMITER", regulating = false, target_deadband = 0.0,
            steps = (id = fill(pid, n), alpha = [(i - neutral) * 3.0 for i in 0:(n-1)],
                     rho = fill(1.0, n), r = zeros(n), x = zeros(n), g = zeros(n), b = zeros(n)))
    end
    NET.create_generators(net; id = ["G1", "G2"], voltage_level_id = ["VL1", "VL3"],
        bus_id = ["B1", "B3"], energy_source = ["OTHER", "OTHER"], min_p = [0.0, 0.0],
        max_p = [1000.0, 150.0], target_p = [200.0, 50.0], target_v = [KV, KV],
        target_q = [0.0, 0.0], voltage_regulator_on = [true, false])
    NET.create_loads(net; id = ["D3"], voltage_level_id = ["VL3"], bus_id = ["B3"], p0 = [250.0], q0 = [0.0])
    return net
end

@testset "Full PST automaton composes with a free corrective (tight convergence)" begin
    # PST_T is the full automaton; PST_F is a free corrective the medial discretizes. The trip
    # of PST_T is pinned by its connected-reference over-current test — a *determined* function of
    # the injection — so the relaxed-medial (max) can no longer fabricate a spurious PST_T
    # disconnection to inflate its bound. The Falk–Hoffman bounds therefore meet.
    mon = Dict("L12a" => (base = 1e4, contingency = 1e4, corrective = 130.0))
    sol = W.worst_case_oracle(build_two_pst(); uncertain = Dict("VL3_0" => (-100.0, 0.0)),
        monitored = mon, correctives = ["PST_F"], contingencies = ["L_B"],
        pst_model = Dict("PST_T" => (p_lim = 300.0, p_act = 1000.0, p_tar = 200.0)))
    @test W.is_secure(sol)
    @test sol.upper_bound - sol.lower_bound ≤ 1e-4    # bounds meet: certificate is tight
    @test sol.iterations < 10                          # converges quickly (vs. running to max_iter)
    @test sol.phi ≈ -0.1694 atol = 5e-3
end

@testset "Exchange parameterisation (zone transfer instead of a per-bus box)" begin
    # Zone = {B3}. Its net injection deviation *is* the exchange, so bounding the exchange bounds
    # the transfer down the corridor regardless of how the per-bus box is drawn: with a generous
    # per-bus box, an exchange capped at −60 MW (60 MW of extra import) keeps L12a within 110 MW,
    # while capping it at −150 MW does not.
    # Base flow on L12a is ≈ 70.4 MW and grows by ≈ 0.352 MW per MW of extra import at B3, so a
    # 60 MW transfer gives ≈ 91.5 MW (secure vs. 110) and a 150 MW one ≈ 123.2 MW (insecure).
    box = Dict("VL3_0" => (-300.0, 0.0))          # per-bus box: deliberately loose
    zone = ["VL3_0"]
    L12a(x) = 200.0 * 500 / 700 * (291.67 / 591.67) * (200 + x) / 200
    orc(lo) = W.worst_case_oracle(build_ext(); uncertain = box, monitored = Dict("L12a" => 110.0),
                                  exchange = (buses = zone, lo = lo, hi = 0.0))
    tight = orc(-60.0)
    loose = orc(-150.0)
    @test W.is_secure(tight)
    @test tight.phi ≈ L12a(60) / 110 - 1 atol = 5e-3
    @test !W.is_secure(loose)
    @test loose.phi ≈ L12a(150) / 110 - 1 atol = 5e-3
    # the binding realisation sits at the exchange bound, not at the (looser) per-bus bound
    @test loose.worst_injection["VL3_0"] ≈ -150.0 atol = 1e-2

    # Without the exchange restriction the whole per-bus box is available, and it is worse.
    nolim = W.worst_case_oracle(build_ext(); uncertain = box, monitored = Dict("L12a" => 110.0))
    @test !W.is_secure(nolim)
    @test nolim.phi ≈ L12a(300) / 110 - 1 atol = 5e-3
    @test nolim.phi > loose.phi                   # a wider transfer ⇒ a worse overload
end

@testset "Restricted security test (conservative margin)" begin
    # Base flow ≈ 70.4 MW against a 110 MW limit ⇒ φ ≈ −0.36: secure with 36% of margin. A
    # restriction below that margin still accepts; one above it rejects, even though φ is unchanged.
    sol0 = W.worst_case_oracle(build_ext(); uncertain = NO_UNC, monitored = Dict("L12a" => 110.0))
    margin = -sol0.phi
    @test margin ≈ 1 - 200.0 * 500 / 700 * (291.67 / 591.67) / 110 atol = 5e-3
    @test W.is_secure(sol0)

    ok = W.worst_case_oracle(build_ext(); uncertain = NO_UNC, monitored = Dict("L12a" => 110.0),
                             restriction = margin / 2)
    tight = W.worst_case_oracle(build_ext(); uncertain = NO_UNC, monitored = Dict("L12a" => 110.0),
                                restriction = margin * 2)
    @test W.is_secure(ok)
    @test !W.is_secure(tight)
    @test ok.phi ≈ sol0.phi atol = 1e-9        # the restriction moves the test, not the value
    @test tight.phi ≈ sol0.phi atol = 1e-9
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

@testset "Smallest uncorrectable exchange (cuts, not bisection)" begin
    # Corridor with L_B: base L12a ≈ 70.4 MW, growing ≈ 0.352 MW per MW imported at B3. Against a
    # 110 MW limit the frontier is at (110 − 70.4)/0.352 ≈ 112.4 MW of import, and the program
    # returns it directly — no search over transfer levels.
    box = Dict("VL3_0" => (-400.0, 0.0))
    base = 200.0 * 500 / 700 * (291.67 / 591.67)
    slope = base / 200
    frontier = (110.0 - base) / slope
    r = W.min_violating_exchange(build_ext(); zone = ["VL3_0"], uncertain = box,
                                 monitored = Dict("L12a" => 110.0), e_cap = 400.0)
    @test r !== nothing
    e, v = r
    @test e ≈ frontier atol = 0.5
    @test v["VL3_0"] ≈ -frontier atol = 0.5       # the binding scenario is the import itself

    # Just below the frontier nothing violates, so the whole range is achievable.
    @test W.min_violating_exchange(build_ext(); zone = ["VL3_0"], uncertain = box,
              monitored = Dict("L12a" => 110.0), e_cap = frontier - 1.0) === nothing

    # Cross-check against the security oracle: secure just below, insecure just above.
    below = W.worst_case_oracle(build_ext(); uncertain = box, monitored = Dict("L12a" => 110.0),
                exchange = (buses = ["VL3_0"], lo = -(frontier - 1.0), hi = 0.0))
    above = W.worst_case_oracle(build_ext(); uncertain = box, monitored = Dict("L12a" => 110.0),
                exchange = (buses = ["VL3_0"], lo = -(frontier + 1.0), hi = 0.0))
    @test W.is_secure(below)
    @test !W.is_secure(above)
end

@testset "Restriction has one meaning across both formulations" begin
    # `restriction` is a security margin everywhere: tightening it must move the reported frontier
    # *down* whichever way it is computed. (It previously moved the cut formulation the wrong way.)
    box = Dict("VL3_0" => (-400.0, 0.0))
    mon = Dict("L12a" => 110.0)
    frontier(r) = W.min_violating_exchange(build_ext(); zone = ["VL3_0"], uncertain = box,
                                           monitored = mon, e_cap = 400.0, restriction = r)[1]
    e0, e1 = frontier(0.0), frontier(0.1)
    @test e1 < e0                              # a margin costs transfer, as in the oracle
    # and the conservative frontier really is secure by the oracle's own restricted test
    sol = W.worst_case_oracle(build_ext(); uncertain = box, monitored = mon, restriction = 0.1,
                              exchange = (buses = ["VL3_0"], lo = -(e1 - 0.5), hi = 0.0))
    @test W.is_secure(sol)
end

@testset "Exchange direction and zero point" begin
    # `direction` picks the sense of the transfer and `offset` moves the reference the exchange is
    # measured from — needed whenever the forecast exchange is not itself zero.
    box = Dict("VL3_0" => (-400.0, 400.0))
    mon = Dict("L12a" => 110.0)
    f(dir, off) = W.min_violating_exchange(build_ext(); zone = ["VL3_0"], uncertain = box,
                      monitored = mon, e_cap = 2000.0, direction = dir, offset = off)
    imp = f(-1.0, 0.0)
    @test imp !== nothing
    # shifting the zero point moves the measured exchange one-for-one, same physical frontier
    imp50 = f(-1.0, 50.0)
    @test imp50 !== nothing
    @test imp50[1] ≈ imp[1] + 50.0 atol = 0.5
    @test imp50[2]["VL3_0"] ≈ imp[2]["VL3_0"] atol = 0.5   # same binding injection
    # the opposite sense is a different frontier (the corridor reverses)
    exp_ = f(+1.0, 0.0)
    @test exp_ === nothing || !isapprox(exp_[1], imp[1]; atol = 1.0)
end

# ---------------------------------------------------------------------------
# Reference six-bus benchmark
#
# A published instance with a closed-form maximum exchange. Per-unit on a 100 MVA base, expressed
# here in MW so that h = V²/x equals 100/x_pu. The foreign region is {1,4,5}; its forecast
# exchange is -731 MW, so the exchange is measured from that offset in either direction.
# ---------------------------------------------------------------------------
const REF_KV = 400.0
ref_x(x_pu) = REF_KV^2 * x_pu / 100

function build_ref6(; bb_pu = 20.0)
    net = NET.create_empty("ref6")
    NET.create_substations(net; id = ["S$i" for i in 1:6], country = fill("FR", 6))
    NET.create_voltage_levels(net; id = ["VL$i" for i in 1:6], substation_id = ["S$i" for i in 1:6],
        topology_kind = fill("BUS_BREAKER", 6), nominal_v = fill(REF_KV, 6))
    NET.create_buses(net; id = ["B$i" for i in 1:6], voltage_level_id = ["VL$i" for i in 1:6])
    for (id, f, t, xp) in [("SIMP1", 2, 1, 0.20215535), ("SIMP2", 3, 4, 0.07687),
                           ("SIMP3", 1, 4, 0.51732935), ("SIMP4", 3, 2, 0.51732935),
                           ("SIMP5", 6, 3, 0.15374),    ("SIMP6", 4, 5, 0.15374)]
        NET.create_lines(net; id = [id], voltage_level1_id = ["VL$f"], bus1_id = ["B$f"],
            voltage_level2_id = ["VL$t"], bus2_id = ["B$t"], r = [0.0], x = [ref_x(xp)],
            g1 = [0.0], b1 = [0.0], g2 = [0.0], b2 = [0.0])
    end
    gid  = ["LOADG1", "GENC1", "GENC2", "GENC3", "LOADG2", "LOADG3", "GENU1", "GENU2"]
    gbus = [1, 2, 2, 3, 4, 4, 1, 4]
    NET.create_generators(net; id = gid, voltage_level_id = ["VL$b" for b in gbus],
        bus_id = ["B$b" for b in gbus], energy_source = fill("OTHER", 8),
        min_p = [0.0, 100.0, 100.0, 100.0, 0.0, 0.0, -100bb_pu, -100bb_pu],
        max_p = [1000.0, 1500.0, 1500.0, 1500.0, 1000.0, 1000.0, 100bb_pu, 100bb_pu],
        target_p = [577.0, 577.0, 577.0, 577.0, 346.0, 346.0, 0.0, 0.0],
        target_v = fill(REF_KV, 8), target_q = fill(0.0, 8), voltage_regulator_on = fill(false, 8))
    NET.create_loads(net; id = ["LOADC1", "LOADC2", "LOADC4"],
        voltage_level_id = ["VL1", "VL2", "VL5"], bus_id = ["B1", "B2", "B5"],
        p0 = [1000.0, 1000.0, 1000.0], q0 = [0.0, 0.0, 0.0])
    return net
end

const REF_ZONE   = ["VL1_0", "VL4_0", "VL5_0"]
const REF_OFFSET = 731.0                       # minus the forecast foreign exchange (-731 MW)
const REF_BOX    = Dict("VL1_0" => (-100.0, 1100.0), "VL4_0" => (-100.0, 100.0))
const REF_MON    = Dict("SIMP1" => (base = 600.0, contingency = 1000.0, corrective = 600.0),
                        "SIMP2" => (base = 600.0, contingency = 1000.0, corrective = 600.0))
const REF_PART   = Dict("GENC1" => 1/3, "GENC2" => 1/3, "GENC3" => 1/3)
const REF_HVDC   = [(id = "HVDC1", bus1 = "VL5_0", bus2 = "VL6_0",
                     k = 100 / 0.04848135, p_zero = 0.0, p_lim = 500.0)]
ref_ugens(bb) = [(id = "GENU1", bus = "VL1_0", controllable = (-100bb, 100bb)),
                 (id = "GENU2", bus = "VL4_0", controllable = (-100bb, 100bb))]

@testset "Reference six-bus benchmark: the network" begin
    gm = W.GridModel(build_ref6(); slack = "VL1_0")
    h = Dict(b.id => b.h for b in gm.branches)
    for (id, xp) in [("SIMP1", 0.20215535), ("SIMP2", 0.07687), ("SIMP3", 0.51732935),
                     ("SIMP4", 0.51732935), ("SIMP5", 0.15374), ("SIMP6", 0.15374)]
        @test h[id] ≈ 100 / xp rtol = 1e-9         # admittance in MW/rad
    end
    inj = W._nominal_injection(gm)
    for (n, p) in ["VL1_0" => -423.0, "VL2_0" => 154.0, "VL3_0" => 577.0,
                   "VL4_0" => 692.0, "VL5_0" => -1000.0, "VL6_0" => 0.0]
        @test inj[n] ≈ p atol = 1e-6
    end
    @test sum(values(inj)) ≈ 0.0 atol = 1e-9       # the forecast balances
end

@testset "Reference six-bus benchmark: maximum exchange" begin
    # Published values, in MW, for each balancing bound and transfer sense.
    for (bb, dir, expected) in [(20.0, +1.0, 354.473), (20.0, -1.0, 991.046),
                                ( 7.0, +1.0, 398.954), ( 7.0, -1.0, 1174.987)]
        r = W.min_violating_exchange(build_ref6(; bb_pu = bb); zone = REF_ZONE, uncertain = REF_BOX,
                uncertain_generators = ref_ugens(bb), monitored = REF_MON, e_cap = 3000.0,
                participation = REF_PART, hvdc = REF_HVDC, slack = "VL1_0",
                direction = dir, offset = REF_OFFSET)   # no hand-tuned big-M
        @test r !== nothing
        @test r[1] ≈ expected atol = 0.01          # inside the reference's own 1e-4 pu tolerance
    end
end

@testset "Per-branch big-M bounds from the physics" begin
    # The bounds must be valid — never below a flow the model can actually reach — and materially
    # tighter than a single hand-picked constant.
    gm = W.GridModel(build_ext(); slack = "VL1_0")
    box = Dict("VL3_0" => (-200.0, 0.0))
    M = W.branch_bigM(gm, ["L_B"]; uncertain = box,
                      participation = Dict("G1" => 1.0, "G2" => 1.0))
    @test Set(keys(M)) == Set(br.id for br in gm.branches)
    @test all(v -> v > 0 && isfinite(v), values(M))

    # Validity: the worst case the oracle actually finds must sit inside the bound. With L_B out
    # the corridor carries ≈ 142.9 MW at forecast and more under the uncertainty; every branch
    # bound must exceed the flows the model reaches, and the monitored limit it is compared to.
    @test M["L12a"] > 200.0
    @test M["PST_T"] > 0.0

    # Tightness: far below the 1e4 default that was previously applied to every branch.
    @test maximum(values(M)) < 1e4

    # Answers must not depend on the bound: the automatic and a generous manual setting agree.
    lim = (base = 110.0, contingency = 150.0, corrective = 110.0)
    auto = W.worst_case_oracle(build_ext(); uncertain = NO_UNC, monitored = Dict("L12a" => lim),
                               correctives = ["PST_T"], contingencies = ["L_B"])
    manual = W.worst_case_oracle(build_ext(); uncertain = NO_UNC, monitored = Dict("L12a" => lim),
                                 correctives = ["PST_T"], contingencies = ["L_B"],
                                 auto_bigM = false, bigM = 1e4)
    @test auto.phi ≈ manual.phi atol = 1e-6
    @test W.is_secure(auto) == W.is_secure(manual)
end

@testset "Asymmetric per-direction limits" begin
    # A branch may be rated differently each way. Base flow on L12a is positive and reaches
    # ≈ 140.8 MW under the uncertainty, so only the forward rating can bind here.
    unc = Dict("VL3_0" => (-200.0, 0.0))
    sym  = W.worst_case_oracle(build_ext(); uncertain = unc, monitored = Dict("L12a" => 110.0))
    pair = W.worst_case_oracle(build_ext(); uncertain = unc,
                               monitored = Dict("L12a" => (-110.0, 110.0)))
    @test pair.phi ≈ sym.phi atol = 1e-9        # (-r, r) is exactly the symmetric rating

    # Relaxing only the reverse rating changes nothing: the forward one still binds.
    fwd = W.worst_case_oracle(build_ext(); uncertain = unc,
                              monitored = Dict("L12a" => (-1e4, 110.0)))
    @test fwd.phi ≈ sym.phi atol = 1e-9
    @test !W.is_secure(fwd)

    # Relaxing the forward rating instead leaves the flow unconstrained in the direction it runs.
    rev = W.worst_case_oracle(build_ext(); uncertain = unc,
                              monitored = Dict("L12a" => (-110.0, 1e4)))
    @test W.is_secure(rev)
    @test rev.phi < sym.phi - 1.0

    # Per-state ratings may be pairs too.
    perstate = W.worst_case_oracle(build_ext(); uncertain = NO_UNC, contingencies = ["L_B"],
        monitored = Dict("L12a" => (base = (-110.0, 110.0), contingency = (-1e4, 1e4),
                                    corrective = (-110.0, 110.0))))
    @test !W.is_secure(perstate)
    @test perstate.phi ≈ N1_OVERLOAD atol = 1e-3   # only the post-corrective rating binds

    @test_throws ArgumentError W.worst_case_oracle(build_ext(); uncertain = NO_UNC,
        monitored = Dict("L12a" => (110.0, 220.0)))     # both positive is not a direction pair
end

@testset "Emergency reserve and merit order" begin
    # G1 (200 MW, up to 1000) is the ordinary responding unit; G2 (50 MW, up to 150) is held as
    # reserve. Reserve must stay put while G1 still has headroom, and engage only once it doesn't.
    mon = Dict("L12a" => 110.0)
    both = Dict("G1" => 1.0, "G2" => 1.0)

    # 700 MW of extra load is within G1's 800 MW of headroom, so the reserve stays at its set
    # point and the answer must equal the case where G2 does not participate at all.
    unc700 = Dict("VL3_0" => (-700.0, 0.0))
    reserve = W.worst_case_oracle(build_ext(); uncertain = unc700, monitored = mon,
                                  participation = both, emergency = ["G2"])
    g1only  = W.worst_case_oracle(build_ext(); uncertain = unc700, monitored = mon,
                                  participation = Dict("G1" => 1.0))
    shared  = W.worst_case_oracle(build_ext(); uncertain = unc700, monitored = mon,
                                  participation = both)
    @test reserve.phi ≈ g1only.phi atol = 5e-3      # held back: as if it did not respond
    @test reserve.phi > shared.phi + 0.05           # …and strictly worse than sharing

    # 850 MW exceeds G1's headroom, so the reserve must engage for the case to balance at all.
    unc850 = Dict("VL3_0" => (-850.0, 0.0))
    engaged = W.worst_case_oracle(build_ext(); uncertain = unc850, monitored = mon,
                                  participation = both, emergency = ["G2"])
    shared850 = W.worst_case_oracle(build_ext(); uncertain = unc850, monitored = mon,
                                    participation = both)
    @test isfinite(engaged.phi)
    @test engaged.phi > reserve.phi                 # a larger deficit is worse
    @test !isapprox(engaged.phi, shared850.phi; atol = 1e-3)   # reserve last ≠ sharing throughout

    # A 700 MW deficit overloads the corridor however it is covered; sharing merely softens it.
    @test shared.phi > 0
    @test g1only.phi > shared.phi
end

@testset "Discrete tap positions for a corrective PST" begin
    # Shifting the PST relieves L12a but loads the PST corridor itself, so the best corrective is
    # an interior compromise rather than a bound — which is where discreteness actually bites.
    mon = Dict("L12a"  => (base = 1e4, contingency = 1e4, corrective = 110.0),
               "PST_T" => (base = 1e4, contingency = 1e4, corrective = 80.0))
    kw = (uncertain = NO_UNC, monitored = mon, correctives = ["PST_T"], contingencies = ["L_B"])
    cont = W.worst_case_oracle(build_ext(); kw...)
    disc = W.worst_case_oracle(build_ext(); kw..., discrete = ["PST_T"])

    taps = first(b for b in W.GridModel(build_ext()).branches if b isa W.Pst).taps
    @test length(taps) == 21
    @test rad2deg(taps[1]) ≈ -30.0 atol = 1e-9      # every 3° from −30 to +30
    αc = cont.corrective["L_B"]["PST_T"]
    αd = disc.corrective["L_B"]["PST_T"]

    @test minimum(abs(αd - t) for t in taps) ≈ 0.0 atol = 1e-6   # lands on a real tap
    @test minimum(abs(αc - t) for t in taps) > 1e-3              # the continuous one does not
    @test rad2deg(αc) ≈ 10.856 atol = 5e-3
    @test rad2deg(αd) ≈ 12.0 atol = 1e-3            # chosen, not rounded: 9° would be worse
    @test disc.phi >= cont.phi - 1e-9               # discretising can only cost
    @test disc.phi > cont.phi + 1e-3                # and here it does

    # Where the continuous optimum already sits on a tap, the two agree exactly.
    mon2 = Dict("L12a" => (base = 1e4, contingency = 1e4, corrective = 110.0))
    kw2 = (uncertain = NO_UNC, monitored = mon2, correctives = ["PST_T"], contingencies = ["L_B"])
    c2 = W.worst_case_oracle(build_ext(); kw2...)
    d2 = W.worst_case_oracle(build_ext(); kw2..., discrete = ["PST_T"])
    @test rad2deg(c2.corrective["L_B"]["PST_T"]) ≈ 30.0 atol = 1e-2
    @test d2.phi ≈ c2.phi atol = 1e-6
end

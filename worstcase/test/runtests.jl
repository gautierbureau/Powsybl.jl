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

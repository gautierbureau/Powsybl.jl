# Copyright (c) 2025, RTE (http://www.rte-france.com)
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# SPDX-License-Identifier: MPL-2.0

using SemiInfinite
using Test
import Ipopt

@testset "1-D linear SIP (worst case at a vertex)" begin
    # min x   s.t.  x ≥ y  ∀ y ∈ [0, 0.5]   →   x* = 0.5
    # g(x, y) = y - x ≤ 0
    p = SIPProblem(nx = 1, ny = 1, x_lower = -10.0, x_upper = 10.0,
                   y_lower = 0.0, y_upper = 0.5,
                   objective = x -> x[1], constraints = (x, y) -> y[1] - x[1])
    res = solve_bnf(p)

    @test res.status == :optimal
    @test res.x[1] ≈ 0.5 atol = 1e-6
    @test res.objective ≈ 0.5 atol = 1e-6
    @test res.max_violation <= 1e-6
    # the binding worst case y* = 0.5 was discovered
    @test any(y -> isapprox(y[1], 0.5, atol = 1e-6), res.discretization)
end

@testset "2-D linear SIP (two vertex worst cases)" begin
    # min x1 + x2   s.t.  y·x1 + (1-y)·x2 ≥ 1  ∀ y ∈ [0, 1]   →   x* = (1, 1)
    # g(x, y) = 1 - y·x1 - (1-y)·x2 ≤ 0  (bilinear, but linear in each subproblem)
    p = SIPProblem(nx = 2, ny = 1, x_lower = [0.0, 0.0], x_upper = [10.0, 10.0],
                   y_lower = 0.0, y_upper = 1.0,
                   objective = x -> x[1] + x[2],
                   constraints = (x, y) -> 1 - y[1] * x[1] - (1 - y[1]) * x[2])
    res = solve_bnf(p)

    @test res.status == :optimal
    @test res.x ≈ [1.0, 1.0] atol = 1e-5
    @test res.objective ≈ 2.0 atol = 1e-5
    # both extreme parameter values had to be enforced
    @test any(y -> isapprox(y[1], 0.0, atol = 1e-5), res.discretization)
    @test any(y -> isapprox(y[1], 1.0, atol = 1e-5), res.discretization)
end

@testset "Nonlinear separation, interior worst case (injected NLP solver)" begin
    # max x  (min -x)   s.t.  x·y·(1-y) ≤ 0.25  ∀ y ∈ [0, 1],  x ∈ [0, 2]
    # The separation max_y x·y·(1-y) is concave with an *interior* maximiser y* = 1/2,
    # so it needs a nonlinear optimizer (HiGHS cannot); inject Ipopt only for the LLP.
    # Binding: x·(1/4) ≤ 0.25 → x* = 1.
    p = SIPProblem(nx = 1, ny = 1, x_lower = 0.0, x_upper = 2.0,
                   y_lower = 0.0, y_upper = 1.0,
                   objective = x -> -x[1],
                   constraints = (x, y) -> x[1] * y[1] * (1 - y[1]) - 0.25)
    res = solve_bnf(p, SIPOptions(llp_optimizer = Ipopt.Optimizer))

    @test res.status == :optimal
    @test res.x[1] ≈ 1.0 atol = 1e-4
    @test res.objective ≈ -1.0 atol = 1e-4
    # the interior worst case y* = 1/2 was found by the separation solver
    @test any(y -> isapprox(y[1], 0.5, atol = 1e-3), res.discretization)
end

@testset "Detects infeasibility" begin
    # x ≤ 0 (upper bound) but x ≥ y ≥ 1  →  infeasible
    p = SIPProblem(nx = 1, ny = 1, x_lower = -10.0, x_upper = 0.0,
                   y_lower = 1.0, y_upper = 2.0,
                   objective = x -> x[1], constraints = (x, y) -> y[1] - x[1])
    res = solve_bnf(p)
    @test res.status == :infeasible
end

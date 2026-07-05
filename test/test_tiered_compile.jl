using Test
using Joovy

@testset "TieredCompile" begin
    table = ComparisonTable("TieredCompile: Tiered Compilation & Auto-Promotion")

    clear_timeline!()

    # --- Test 1: Tier 0 compiles and runs ---
    tc0 = joovy_compile_tiered("tc_t0(x) = x + 1"; tier=0, name=:tc_t0)
    @test tc0(5) == 6
    @test get_tier(tc0) == 0
    add_row!(table, "Tier 0: compile + call", 6, tc0(5), 0.0, 0.0)

    # --- Test 2: Tier 1 compiles and runs ---
    tc1 = joovy_compile_tiered("tc_t1(x) = x * 2"; tier=1, name=:tc_t1)
    @test tc1(5) == 10
    @test get_tier(tc1) == 1
    add_row!(table, "Tier 1: compile + call", 10, tc1(5), 0.0, 0.0)

    # --- Test 3: Tier 2 compiles and runs ---
    tc2 = joovy_compile_tiered("tc_t2(x) = x ^ 2"; tier=2, name=:tc_t2)
    @test tc2(5) == 25
    @test get_tier(tc2) == 2
    add_row!(table, "Tier 2: compile + call", 25, tc2(5), 0.0, 0.0)

    # --- Test 4: Manual promotion ---
    tc_promo = joovy_compile_tiered("tc_promo(x) = x + 100"; tier=0, name=:tc_promo)
    @test get_tier(tc_promo) == 0
    promote!(tc_promo; tier=2)
    @test get_tier(tc_promo) == 2
    @test tc_promo(5) == 105
    add_row!(table, "Manual promote 0->2", 105, tc_promo(5), 0.0, 0.0)

    # --- Test 5: Auto-promotion via call count ---
    tc_auto = joovy_compile_tiered("tc_auto(x) = x - 1"; tier=1, name=:tc_auto,
                                    promote_threshold=5)
    for i in 1:10
        tc_auto(i)
    end
    sleep(1.0)
    @test get_tier(tc_auto) == 2
    add_row!(table, "Auto-promote after 5 calls", 2, get_tier(tc_auto), 0.0, 0.0)

    # --- Test 6: TieredCallable is AbstractJoovyCallable ---
    @test tc0 isa AbstractJoovyCallable
    add_row!(table, "Is AbstractJoovyCallable", true, tc0 isa AbstractJoovyCallable, 0.0, 0.0)

    # --- Test 7: Multi-argument function ---
    tc_multi = joovy_compile_tiered("tc_multi(a, b, c) = a + b * c"; tier=1, name=:tc_multi)
    @test tc_multi(1, 2, 3) == 7
    add_row!(table, "Multi-arg tier 1", 7, tc_multi(1, 2, 3), 0.0, 0.0)

    # --- Test 8: Correctness across tiers ---
    code = "tc_correct(x) = sin(x) * cos(x) + log(1 + abs(x))"
    t0c = joovy_compile_tiered(code; tier=0, name=:tc_correct0)
    t1c = joovy_compile_tiered(code; tier=1, name=:tc_correct1)
    t2c = joovy_compile_tiered(code; tier=2, name=:tc_correct2)
    x = 2.5
    @test isapprox(t0c(x), t2c(x); atol=1e-10)
    @test isapprox(t1c(x), t2c(x); atol=1e-10)
    add_row!(table, "Correctness across tiers", round(t2c(x), digits=8),
             round(t0c(x), digits=8), 0.0, 0.0)

    # --- Test 9: set_promote_threshold! ---
    tc_thresh = joovy_compile_tiered("tc_thresh(x) = x"; tier=0, name=:tc_thresh,
                                      promote_threshold=100)
    set_promote_threshold!(tc_thresh, 3)
    for i in 1:5
        tc_thresh(i)
    end
    sleep(1.0)
    @test get_tier(tc_thresh) >= 1
    add_row!(table, "set_promote_threshold!", true, get_tier(tc_thresh) >= 1, 0.0, 0.0)

    # --- Test 10: tier_stats ---
    ts = tier_stats()
    @test !isempty(ts.counts)
    add_row!(table, "Tier stats tracked", true, !isempty(ts.counts), 0.0, 0.0)

    print_table(table)
    @test table_all_passed(table)
end

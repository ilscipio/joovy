using Test
using Joovy

@testset "CompileTimeline" begin
    table = ComparisonTable("CompileTimeline: Compilation Event Tracking")

    clear_timeline!()

    # --- Test 1: Events are recorded ---
    joovy_compile_tiered("tl_fn1(x) = x + 1"; tier=0, name=:tl_fn1)
    joovy_compile_tiered("tl_fn2(x) = x * 2"; tier=1, name=:tl_fn2)
    joovy_compile_tiered("tl_fn3(x) = x ^ 2"; tier=2, name=:tl_fn3)

    tl = compile_timeline()
    @test length(tl) >= 3
    add_row!(table, "Events recorded", true, length(tl) >= 3, 0.0, 0.0)

    # --- Test 2: Filter by tier ---
    tier0_events = compile_timeline(tier=0)
    @test all(e -> e.tier == 0, tier0_events)
    @test !isempty(tier0_events)
    add_row!(table, "Filter by tier 0", true, !isempty(tier0_events), 0.0, 0.0)

    # --- Test 3: Filter by source ---
    tiered_events = compile_timeline(source=:tiered_compile)
    @test all(e -> e.source == :tiered_compile, tiered_events)
    add_row!(table, "Filter by source", true, !isempty(tiered_events), 0.0, 0.0)

    # --- Test 4: Stats summary ---
    stats = compile_stats_summary()
    @test stats.total_compile_time_ns > 0
    @test !isempty(stats.count_by_tier)
    add_row!(table, "Stats: total time > 0", true, stats.total_compile_time_ns > 0, 0.0, 0.0)

    # --- Test 5: Report generates string ---
    report = compile_report()
    @test length(report) > 0
    @test occursin("tl_fn", report)
    add_row!(table, "Report contains fn names", true, occursin("tl_fn", report), 0.0, 0.0)

    # --- Test 6: Compile tree ---
    tree = compile_tree(:tl_fn1)
    @test tree.name === :tl_fn1
    add_row!(table, "Compile tree for tl_fn1", :tl_fn1, tree.name, 0.0, 0.0)

    # --- Test 7: Clear timeline ---
    clear_timeline!()
    @test length(compile_timeline()) == 0
    add_row!(table, "Clear empties timeline", 0, length(compile_timeline()), 0.0, 0.0)

    print_table(table)
    @test table_all_passed(table)
end

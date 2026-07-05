using Test
using Joovy

@testset "LazyModule" begin
    table = ComparisonTable("LazyModule: Parse-Once, Compile-On-Use")

    clear_timeline!()

    test_dir = @__DIR__
    tmpfile = joinpath(test_dir, "scripts", "_lazy_test.jl")

    # --- Setup: write a multi-function file ---
    write(tmpfile, """
    helper(x) = x * 2

    function compute(x)
        helper(x) + 10
    end

    standalone(x) = x^3

    function chain(x)
        compute(x) + standalone(x)
    end
    """)

    # --- Test 1: joovy_use parses but does not compile ---
    lm = joovy_use(tmpfile; tier=1)
    pending = lazy_pending(lm)
    compiled = lazy_compiled(lm)
    @test length(pending) == 4
    @test length(compiled) == 0
    add_row!(table, "Parse only, 0 compiled", 0, length(compiled), 0.0, 0.0)

    # --- Test 2: standalone compiles only itself ---
    result = lm.standalone(3)
    @test result == 27
    @test length(lazy_compiled(lm)) == 1
    add_row!(table, "standalone(3) = 27", 27, result, 0.0, 0.0)

    # --- Test 3: compute compiles helper transitively ---
    result = lm.compute(5)
    @test result == 20  # helper(5)=10, 10+10=20
    comp = lazy_compiled(lm)
    @test :helper in comp
    @test :compute in comp
    add_row!(table, "compute(5) + transitive dep", 20, result, 0.0, 0.0)

    # --- Test 4: Full chain ---
    result = lm.chain(2)
    expected = (2*2 + 10) + 2^3  # compute(2)=14, standalone(2)=8, total=22
    @test result == expected
    @test length(lazy_compiled(lm)) == 4
    add_row!(table, "chain(2) full dep tree", expected, result, 0.0, 0.0)

    # --- Test 5: Reload with changes ---
    write(tmpfile, """
    helper(x) = x * 3

    function compute(x)
        helper(x) + 10
    end

    standalone(x) = x^3

    function chain(x)
        compute(x) + standalone(x)
    end
    """)
    sleep(0.1)

    changes = joovy_reload!(lm)
    @test :helper in changes.changed
    result = lm.compute(5)
    @test result == 25  # helper(5)=15, 15+10=25
    add_row!(table, "Reload: compute(5)", 25, result, 0.0, 0.0)

    # --- Test 6: Standalone not invalidated ---
    @test :standalone in lazy_compiled(lm)
    add_row!(table, "Unchanged fn stays compiled", true, :standalone in lazy_compiled(lm), 0.0, 0.0)

    # --- Test 7: lazy_status ---
    status = lazy_status(lm)
    @test status.total_definitions == 4
    @test status.compiled_count >= 1
    add_row!(table, "Status: 4 definitions", 4, status.total_definitions, 0.0, 0.0)

    # --- Test 8: Promote a specific function ---
    joovy_promote_lazy!(lm, :standalone; tier=2)
    status2 = lazy_status(lm)
    @test status2.tiers[:standalone] == 2
    add_row!(table, "Promote standalone->tier2", 2, status2.tiers[:standalone], 0.0, 0.0)

    # --- Test 9: Compile timeline has lazy_module events ---
    tl = compile_timeline(source=:lazy_module)
    @test !isempty(tl)
    add_row!(table, "Timeline has lazy events", true, !isempty(tl), 0.0, 0.0)

    # Cleanup
    rm(tmpfile; force=true)

    print_table(table)
    @test table_all_passed(table)
end

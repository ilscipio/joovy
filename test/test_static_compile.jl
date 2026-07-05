using Test
using Joovy

@testset "StaticCompile" begin
    table = ComparisonTable("StaticCompile: Lock, Typed, & CallSite Optimizations")

    # ===================================================================
    # SECTION 1: Static Lock (joovy_lock!)
    # ===================================================================

    # --- Test 1: Lock a compiled function and call it directly ---
    joovy_compile("sc_add(x, y) = x + y")
    locked_add = joovy_lock!(:sc_add)

    t0 = time_ns()
    native_r = 3 + 4
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    joovy_r = locked_add(3, 4)
    ft = Float64(time_ns() - t0)

    @test native_r == joovy_r
    add_row!(table, "Lock: direct call", native_r, joovy_r, nt, ft)

    # --- Test 2: Locked function works repeatedly ---
    @test locked_add(10, 20) == 30
    @test locked_add(0, 0) == 0
    @test locked_add(-5, 5) == 0
    add_row!(table, "Lock: repeated calls", 30, locked_add(10, 20), 0.0, 0.0)

    # --- Test 3: is_locked check ---
    @test joovy_is_locked(:sc_add)
    @test !joovy_is_locked(:nonexistent_fn)
    add_row!(table, "Lock: is_locked", true, joovy_is_locked(:sc_add), 0.0, 0.0)

    # --- Test 4: Swap blocked while locked ---
    registry = HotSwapRegistry()
    hotswap_register!(:sc_add, "sc_add(x, y) = x + y"; registry=registry)

    swap_blocked = try
        hotswap_swap!(:sc_add, "sc_add(x, y) = x * y"; registry=registry)
        false
    catch e
        occursin("locked", string(e))
    end
    @test swap_blocked
    add_row!(table, "Lock: swap blocked", true, swap_blocked, 0.0, 0.0)

    # --- Test 5: Unlock and swap succeeds ---
    joovy_unlock!(:sc_add)
    @test !joovy_is_locked(:sc_add)
    hotswap_swap!(:sc_add, "sc_add(x, y) = x * y"; registry=registry)
    @test hotswap_call(:sc_add, 3, 4; registry=registry) == 12
    add_row!(table, "Lock: unlock+swap", 12, hotswap_call(:sc_add, 3, 4; registry=registry), 0.0, 0.0)

    # --- Test 6: Old locked reference still works (stale but valid) ---
    @test locked_add(3, 4) == 7
    add_row!(table, "Lock: stale ref valid", 7, locked_add(3, 4), 0.0, 0.0)

    # ===================================================================
    # SECTION 2: Typed Compilation
    # ===================================================================

    # --- Test 7: TypedJoovyCallable with Int return ---
    typed_add = joovy_compile_typed("sc_typed_add(x, y) = x + y"; returns=Int)

    t0 = time_ns()
    native_r = 5 + 7
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    joovy_r = typed_add(5, 7)
    ft = Float64(time_ns() - t0)

    @test joovy_r == native_r
    @test joovy_r isa Int
    add_row!(table, "Typed: Int return", native_r, joovy_r, nt, ft)

    # --- Test 8: Float64 return type ---
    typed_div = joovy_compile_typed("sc_typed_div(x, y) = x / y"; returns=Float64)
    r = typed_div(10, 3)
    @test r isa Float64
    @test isapprox(r, 10/3; atol=1e-12)
    add_row!(table, "Typed: Float64 return", round(10/3, digits=4), round(r, digits=4), 0.0, 0.0)

    # --- Test 9: String return type ---
    typed_str = joovy_compile_typed("sc_typed_str(x) = string(x)"; returns=String)
    @test typed_str(42) == "42"
    @test typed_str(42) isa String
    add_row!(table, "Typed: String return", "42", typed_str(42), 0.0, 0.0)

    # --- Test 10: FullyTypedJoovyCallable with signature ---
    full_typed = joovy_compile_typed("sc_full_typed(x, y) = x + y";
                                     returns=Int, signature=Tuple{Int, Int})
    @test full_typed(3, 4) == 7
    @test full_typed(100, 200) == 300
    add_row!(table, "FullTyped: sig+ret", 7, full_typed(3, 4), 0.0, 0.0)

    # --- Test 11: No returns kwarg falls back to JoovyCallable ---
    fallback = joovy_compile_typed("sc_fallback(x) = x^2")
    @test fallback(5) == 25
    @test fallback isa JoovyCallable
    add_row!(table, "Typed: fallback", 25, fallback(5), 0.0, 0.0)

    # ===================================================================
    # SECTION 3: Call-Site Caching (JoovyCallSite)
    # ===================================================================

    # --- Test 12: Create call site and invoke ---
    registry2 = HotSwapRegistry()
    hotswap_register!(:sc_cs_fn, "sc_cs_fn(x) = x * 2"; registry=registry2)
    cs = joovy_callsite(:sc_cs_fn; registry=registry2)

    t0 = time_ns()
    native_r = 5 * 2
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    joovy_r = cs(5)
    ft = Float64(time_ns() - t0)

    @test native_r == joovy_r
    add_row!(table, "CallSite: initial", native_r, joovy_r, nt, ft)

    # --- Test 13: Call site picks up swap ---
    hotswap_swap!(:sc_cs_fn, "sc_cs_fn(x) = x * 3 + 1"; registry=registry2)
    @test cs(5) == 16
    add_row!(table, "CallSite: after swap", 16, cs(5), 0.0, 0.0)

    # --- Test 14: Multiple swaps tracked ---
    hotswap_swap!(:sc_cs_fn, "sc_cs_fn(x) = x ^ 2"; registry=registry2)
    @test cs(4) == 16
    hotswap_swap!(:sc_cs_fn, "sc_cs_fn(x) = x + 100"; registry=registry2)
    @test cs(4) == 104
    add_row!(table, "CallSite: multi-swap", 104, cs(4), 0.0, 0.0)

    # --- Test 15: Error on non-existent call site ---
    cs_error = try
        joovy_callsite(:nonexistent_cs_fn; registry=registry2)
        false
    catch e
        occursin("No hot-swappable", string(e))
    end
    @test cs_error
    add_row!(table, "CallSite: error check", true, cs_error, 0.0, 0.0)

    # ===================================================================
    # SECTION 4: Memory Management
    # ===================================================================

    # --- Test 16: Memory stats returns valid data ---
    stats = joovy_memory_stats()
    @test stats.cache_entries > 0
    @test stats.compile_counter > 0
    add_row!(table, "Memory: stats", true, stats.cache_entries > 0, 0.0, 0.0)

    # --- Test 17: History trimming ---
    registry3 = HotSwapRegistry()
    hotswap_register!(:sc_trim_fn, "sc_trim_fn(x) = x"; registry=registry3)
    for i in 2:10
        hotswap_swap!(:sc_trim_fn, "sc_trim_fn(x) = x + $i"; registry=registry3)
    end
    hist_before = length(hotswap_history(:sc_trim_fn; registry=registry3))
    @test hist_before == 10
    hotswap_trim_history!(:sc_trim_fn; keep_last=3, registry=registry3)
    hist_after = length(hotswap_history(:sc_trim_fn; registry=registry3))
    @test hist_after == 3
    add_row!(table, "Memory: trim history", 3, hist_after, 0.0, 0.0)

    # --- Test 18: Session lock/unlock ---
    session = JoovySession()
    session_compile(session, "sc_session_fn(x) = x * 10"; name=:sc_session_fn)
    locked_fn = session_lock!(session, :sc_session_fn)
    @test locked_fn(5) == 50
    session_unlock!(session, :sc_session_fn)
    @test !joovy_is_locked(:sc_session_fn)
    add_row!(table, "Session: lock/unlock", 50, locked_fn(5), 0.0, 0.0)

    print_table(table)
    @test table_all_passed(table)
end

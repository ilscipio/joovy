using Test
using Joovy

@testset "ExprCache" begin
    table = ComparisonTable("ExprCache: Content-Addressed Caching")

    cache = JoovyCache()

    # --- Test 1: normalize strips line numbers ---
    expr1 = :(function f(x)
        x + 1
    end)
    expr2 = :(function f(x)
                x + 1
            end)
    h1 = expr_hash(expr1)
    h2 = expr_hash(expr2)

    @test h1 == h2

    t0 = time_ns()
    native_match = true  # same logic should match
    native_t = Float64(time_ns() - t0)

    t0 = time_ns()
    joovy_match = (h1 == h2)
    joovy_t = Float64(time_ns() - t0)

    add_row!(table, "Normalize: same logic", native_match, joovy_match, native_t, joovy_t)

    # --- Test 2: different exprs produce different hashes ---
    expr_a = :(x -> x + 1)
    expr_b = :(x -> x + 2)
    ha = expr_hash(expr_a)
    hb = expr_hash(expr_b)

    t0 = time_ns()
    native_diff = (string(expr_a) != string(expr_b))
    native_t = Float64(time_ns() - t0)

    t0 = time_ns()
    joovy_diff = (ha != hb)
    joovy_t = Float64(time_ns() - t0)

    @test ha != hb
    add_row!(table, "Different exprs != hash", native_diff, joovy_diff, native_t, joovy_t)

    # --- Test 3: cache put and get ---
    test_fn = x -> x * 2
    t0 = time_ns()
    native_store = test_fn(21)
    native_t = Float64(time_ns() - t0)

    cache_put!(cache, :(x -> x * 2), test_fn)

    t0 = time_ns()
    retrieved = cache_get(cache, :(x -> x * 2))
    joovy_result = retrieved(21)
    joovy_t = Float64(time_ns() - t0)

    @test joovy_result == 42
    add_row!(table, "Put/Get roundtrip", native_store, joovy_result, native_t, joovy_t)

    # --- Test 4: cache miss returns nothing ---
    t0 = time_ns()
    native_miss = nothing
    native_t = Float64(time_ns() - t0)

    t0 = time_ns()
    miss = cache_get(cache, :(x -> x * 999))
    joovy_t = Float64(time_ns() - t0)

    @test miss === nothing
    add_row!(table, "Cache miss → nothing", string(native_miss), string(miss), native_t, joovy_t)

    # --- Test 5: named registration ---
    cache_put!(cache, :(x -> x + 10), x -> x + 10)
    cache_register!(cache, :adder, :(x -> x + 10))

    t0 = time_ns()
    native_named = 15
    native_t = Float64(time_ns() - t0)

    t0 = time_ns()
    named_fn = cache_lookup(cache, :adder)
    joovy_named = named_fn(5)
    joovy_t = Float64(time_ns() - t0)

    @test joovy_named == 15
    add_row!(table, "Named lookup :adder(5)", native_named, joovy_named, native_t, joovy_t)

    # --- Test 6: cache stats ---
    stats = cache_stats(cache)
    @test stats.total_entries >= 2
    @test stats.content_hits >= 1

    t0 = time_ns()
    native_entries = 2
    native_t = Float64(time_ns() - t0)

    t0 = time_ns()
    joovy_entries = stats.total_entries
    joovy_t = Float64(time_ns() - t0)

    add_row!(table, "Cache entries count", native_entries, joovy_entries, native_t, joovy_t)

    # --- Test 7: cache clear ---
    cache_clear!(cache)
    stats_after = cache_stats(cache)

    t0 = time_ns()
    native_cleared = 0
    native_t = Float64(time_ns() - t0)

    t0 = time_ns()
    joovy_cleared = stats_after.total_entries
    joovy_t = Float64(time_ns() - t0)

    @test joovy_cleared == 0
    add_row!(table, "Clear empties cache", native_cleared, joovy_cleared, native_t, joovy_t)

    print_table(table)
    @test table_all_passed(table)
end

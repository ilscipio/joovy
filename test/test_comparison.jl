using Test
using Joovy

@testset "Full Comparison Suite" begin
    table = ComparisonTable("FULL SUITE: Compiled Julia vs Joovy.jl — Correctness & Performance")

    config = TuneConfig(warmup_runs=3, bench_runs=10)

    # ═══════════════════════════════════════════════
    # CATEGORY 1: Pure Arithmetic
    # ═══════════════════════════════════════════════

    # Fibonacci
    native_fib(n) = n <= 1 ? n : native_fib(n-1) + native_fib(n-2)

    joovy_fib = joovy_compile("""
        function joovy_fib(n)
            n <= 1 ? n : joovy_fib(n-1) + joovy_fib(n-2)
        end
    """)

    for n in [10, 15, 20]
        comp = joovy_autotune_compare(
            () -> native_fib(n),
            () -> joovy_fib(n);
            config=config
        )
        @test comp.native.result == comp.joovy.result
        add_row!(table, "Fibonacci($n)",
                 comp.native.result, comp.joovy.result,
                 comp.native.median_time_ns, comp.joovy.median_time_ns)
    end

    # Factorial
    native_fact(n) = n <= 1 ? 1 : n * native_fact(n-1)

    joovy_fact = joovy_compile("""
        function joovy_fact(n)
            n <= 1 ? 1 : n * joovy_fact(n-1)
        end
    """)

    for n in [5, 10, 15]
        comp = joovy_autotune_compare(
            () -> native_fact(n),
            () -> joovy_fact(n);
            config=config
        )
        @test comp.native.result == comp.joovy.result
        add_row!(table, "Factorial($n)",
                 comp.native.result, comp.joovy.result,
                 comp.native.median_time_ns, comp.joovy.median_time_ns)
    end

    # ═══════════════════════════════════════════════
    # CATEGORY 2: Array/Vector Operations
    # ═══════════════════════════════════════════════

    native_norm(v) = sqrt(sum(x^2 for x in v))

    joovy_norm = joovy_compile("""
        joovy_norm(v) = sqrt(sum(x^2 for x in v))
    """)

    for sz in [10, 100, 1000]
        v = rand(sz)
        comp = joovy_autotune_compare(
            () -> native_norm(v),
            () -> joovy_norm(v);
            config=config
        )
        @test isapprox(comp.native.result, comp.joovy.result; atol=1e-8)
        add_row!(table, "Vector norm [$sz]",
                 round(comp.native.result, digits=4),
                 round(comp.joovy.result, digits=4),
                 comp.native.median_time_ns, comp.joovy.median_time_ns)
    end

    # Matrix trace
    native_trace(M) = sum(M[i,i] for i in 1:size(M,1))

    joovy_trace = joovy_compile("""
        joovy_trace(M) = sum(M[i,i] for i in 1:size(M,1))
    """)

    for sz in [10, 50, 100]
        M = rand(sz, sz)
        comp = joovy_autotune_compare(
            () -> native_trace(M),
            () -> joovy_trace(M);
            config=config
        )
        @test isapprox(comp.native.result, comp.joovy.result; atol=1e-8)
        add_row!(table, "Matrix trace [$(sz)×$(sz)]",
                 round(comp.native.result, digits=4),
                 round(comp.joovy.result, digits=4),
                 comp.native.median_time_ns, comp.joovy.median_time_ns)
    end

    # ═══════════════════════════════════════════════
    # CATEGORY 3: String Operations
    # ═══════════════════════════════════════════════

    native_rev(s) = reverse(s)

    joovy_rev = joovy_compile("""
        joovy_rev(s) = reverse(s)
    """)

    for s in ["hello", "abcdefghij", "a"^100]
        comp = joovy_autotune_compare(
            () -> native_rev(s),
            () -> joovy_rev(s);
            config=config
        )
        @test comp.native.result == comp.joovy.result
        add_row!(table, "Reverse len=$(length(s))",
                 comp.native.result[1:min(15, end)],
                 comp.joovy.result[1:min(15, end)],
                 comp.native.median_time_ns, comp.joovy.median_time_ns)
    end

    # ═══════════════════════════════════════════════
    # CATEGORY 4: Mathematical Functions
    # ═══════════════════════════════════════════════

    native_taylor_sin(x) = sum((-1)^k * x^(2k+1) / factorial(2k+1) for k in 0:9)

    joovy_taylor = joovy_compile("""
        joovy_taylor_sin(x) = sum((-1)^k * x^(2k+1) / factorial(2k+1) for k in 0:9)
    """)

    for x in [0.0, 0.5, 1.0, 3.14159/2]
        comp = joovy_autotune_compare(
            () -> native_taylor_sin(x),
            () -> joovy_taylor(x);
            config=config
        )
        @test isapprox(comp.native.result, comp.joovy.result; atol=1e-10)
        add_row!(table, "Taylor sin($(round(x,digits=2)))",
                 round(comp.native.result, digits=8),
                 round(comp.joovy.result, digits=8),
                 comp.native.median_time_ns, comp.joovy.median_time_ns)
    end

    # ═══════════════════════════════════════════════
    # CATEGORY 5: Hot-Swap Inline Updates
    # ═══════════════════════════════════════════════

    registry = HotSwapRegistry()
    test_dir = @__DIR__
    tmpfile = joinpath(test_dir, "scripts", "_comparison_swap.jl")

    implementations = [
        ("x + 1",    x -> x + 1),
        ("x * 2",    x -> x * 2),
        ("x ^ 2",    x -> x ^ 2),
        ("x * x + x", x -> x * x + x),
    ]

    # Write initial version
    write(tmpfile, "comparison_swap_fn(x) = $(implementations[1][1])\n")
    hotswap_load_file!(:cmp_swap, tmpfile; registry=registry)

    input_val = 7

    for (i, (code, native_fn)) in enumerate(implementations)
        if i > 1
            write(tmpfile, "comparison_swap_fn(x) = $code\n")
            sleep(0.05)
            hotswap_reload!(:cmp_swap; registry=registry)
        end

        t0 = time_ns()
        native_r = native_fn(input_val)
        nt = Float64(time_ns() - t0)

        t0 = time_ns()
        joovy_r = hotswap_call(:cmp_swap, input_val; registry=registry)
        ft = Float64(time_ns() - t0)

        @test native_r == joovy_r
        add_row!(table, "Swap v$(i): $code", native_r, joovy_r, nt, ft)
    end

    rm(tmpfile; force=true)

    # ═══════════════════════════════════════════════
    # CATEGORY 6: JoovyObject Per-Instance Override
    # ═══════════════════════════════════════════════

    struct TestPoint
        x::Float64
        y::Float64
    end

    obj1 = JoovyObject(TestPoint(3.0, 4.0))
    obj2 = JoovyObject(TestPoint(3.0, 4.0))

    joovy_override!(obj1, :magnitude, p -> sqrt(p.x^2 + p.y^2))
    joovy_override!(obj2, :magnitude, p -> abs(p.x) + abs(p.y))  # Manhattan

    t0 = time_ns()
    native_euclidean = sqrt(3.0^2 + 4.0^2)
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    joovy_euclidean = joovy_call(obj1, :magnitude)
    ft = Float64(time_ns() - t0)

    @test isapprox(native_euclidean, joovy_euclidean; atol=1e-12)
    add_row!(table, "Obj1 Euclidean mag", native_euclidean, joovy_euclidean, nt, ft)

    t0 = time_ns()
    native_manhattan = abs(3.0) + abs(4.0)
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    joovy_manhattan = joovy_call(obj2, :magnitude)
    ft = Float64(time_ns() - t0)

    @test isapprox(native_manhattan, joovy_manhattan; atol=1e-12)
    add_row!(table, "Obj2 Manhattan mag", native_manhattan, joovy_manhattan, nt, ft)

    # Override obj1 in-place
    joovy_override!(obj1, :magnitude, p -> max(abs(p.x), abs(p.y)))  # Chebyshev

    t0 = time_ns()
    native_chebyshev = max(abs(3.0), abs(4.0))
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    joovy_chebyshev = joovy_call(obj1, :magnitude)
    ft = Float64(time_ns() - t0)

    @test isapprox(native_chebyshev, joovy_chebyshev; atol=1e-12)
    add_row!(table, "Obj1 swapped→Cheby", native_chebyshev, joovy_chebyshev, nt, ft)

    print_table(table)
    @test table_all_passed(table)
end

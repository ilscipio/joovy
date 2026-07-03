using Test
using Joovy

@testset "DynCompiler" begin
    table = ComparisonTable("DynCompiler: Compiled Julia vs Joovy Dynamic Compilation")

    # --- Test 1: Simple arithmetic function ---
    native_add(x, y) = x + y

    joovy_add = joovy_compile("add_joovy(x, y) = x + y")

    for (name, a, b) in [("Add integers", 3, 4), ("Add floats", 1.5, 2.5), ("Add negative", -10, 3)]
        t0 = time_ns()
        nr = native_add(a, b)
        nt = Float64(time_ns() - t0)

        t0 = time_ns()
        fr = joovy_add(a, b)
        ft = Float64(time_ns() - t0)

        @test nr == fr
        add_row!(table, name, nr, fr, nt, ft)
    end

    # --- Test 2: Mathematical function ---
    native_sigmoid(x) = 1.0 / (1.0 + exp(-x))

    joovy_sigmoid = joovy_compile("""
        sigmoid_joovy(x) = 1.0 / (1.0 + exp(-x))
    """)

    for (name, x) in [("Sigmoid(0)", 0.0), ("Sigmoid(1)", 1.0), ("Sigmoid(-5)", -5.0)]
        t0 = time_ns()
        nr = native_sigmoid(x)
        nt = Float64(time_ns() - t0)

        t0 = time_ns()
        fr = joovy_sigmoid(x)
        ft = Float64(time_ns() - t0)

        @test isapprox(nr, fr; atol=1e-12)
        add_row!(table, name, nr, fr, nt, ft)
    end

    # --- Test 3: Array operations ---
    native_dot(a, b) = sum(a .* b)

    joovy_dot = joovy_compile("""
        dot_joovy(a, b) = sum(a .* b)
    """)

    a = [1.0, 2.0, 3.0, 4.0, 5.0]
    b = [5.0, 4.0, 3.0, 2.0, 1.0]

    t0 = time_ns()
    nr = native_dot(a, b)
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    fr = joovy_dot(a, b)
    ft = Float64(time_ns() - t0)

    @test isapprox(nr, fr; atol=1e-10)
    add_row!(table, "Dot product [5]", nr, fr, nt, ft)

    # --- Test 4: Expression-based compilation ---
    expr = :(square_joovy(x) = x * x)
    joovy_square = joovy_compile(expr)

    native_square(x) = x * x

    for (name, x) in [("Square(7)", 7), ("Square(0.5)", 0.5), ("Square(-3)", -3)]
        t0 = time_ns()
        nr = native_square(x)
        nt = Float64(time_ns() - t0)

        t0 = time_ns()
        fr = joovy_square(x)
        ft = Float64(time_ns() - t0)

        @test nr == fr
        add_row!(table, name, nr, fr, nt, ft)
    end

    # --- Test 5: Multi-function compilation ---
    joovy_multi = joovy_compile("""
        function multi_joovy(x, y)
            a = x^2
            b = y^2
            return sqrt(a + b)
        end
    """)

    native_multi(x, y) = sqrt(x^2 + y^2)

    t0 = time_ns()
    nr = native_multi(3.0, 4.0)
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    fr = joovy_multi(3.0, 4.0)
    ft = Float64(time_ns() - t0)

    @test isapprox(nr, fr; atol=1e-12)
    add_row!(table, "Hypotenuse(3,4)", nr, fr, nt, ft)

    # --- Test 6: File compilation ---
    test_dir = @__DIR__
    script_path = joinpath(test_dir, "scripts", "v1_processor.jl")
    joovy_file = joovy_compile_file(script_path)

    native_v1(x) = x * 2 + 1

    for (name, x) in [("File v1(5)", 5), ("File v1(0)", 0), ("File v1(-3)", -3)]
        t0 = time_ns()
        nr = native_v1(x)
        nt = Float64(time_ns() - t0)

        t0 = time_ns()
        fr = joovy_file(x)
        ft = Float64(time_ns() - t0)

        @test nr == fr
        add_row!(table, name, nr, fr, nt, ft)
    end

    # --- Test 7: Cache hit performance ---
    joovy_cached = joovy_compile("add_joovy(x, y) = x + y")

    t0 = time_ns()
    nr = native_add(100, 200)
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    fr = joovy_cached(100, 200)
    ft = Float64(time_ns() - t0)

    @test nr == fr
    add_row!(table, "Cached recompile", nr, fr, nt, ft)

    # --- Test 8: Large array computation ---
    big_a = rand(1000)
    big_b = rand(1000)

    joovy_big_dot = joovy_compile("big_dot_joovy(a, b) = sum(a .* b)")

    t0 = time_ns()
    nr = native_dot(big_a, big_b)
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    fr = joovy_big_dot(big_a, big_b)
    ft = Float64(time_ns() - t0)

    @test isapprox(nr, fr; atol=1e-8)
    add_row!(table, "Dot product [1000]", round(nr, digits=4), round(fr, digits=4), nt, ft)

    print_table(table)
    @test table_all_passed(table)
end

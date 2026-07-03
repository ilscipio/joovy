using Test
using Joovy

@testset "ScriptEngine" begin
    table = ComparisonTable("ScriptEngine: Sandboxed Execution & Bindings")

    engine = JoovyEngine(sandbox=false)

    # --- Test 1: Simple eval ---
    result = joovy_run(engine, "1 + 2 + 3")

    t0 = time_ns()
    native_r = 1 + 2 + 3
    nt = Float64(time_ns() - t0)

    @test result.success
    @test result.value == native_r
    add_row!(table, "Simple eval 1+2+3", native_r, result.value, nt, Float64(result.elapsed_ns))

    # --- Test 2: Function definition + call ---
    result = joovy_run(engine, """
        function engine_calc(a, b)
            return a * b + a
        end
        engine_calc(3, 4)
    """)

    native_calc(a, b) = a * b + a

    t0 = time_ns()
    native_r = native_calc(3, 4)
    nt = Float64(time_ns() - t0)

    @test result.success
    @test result.value == native_r
    add_row!(table, "Func def + call", native_r, result.value, nt, Float64(result.elapsed_ns))

    # --- Test 3: Bindings ---
    bindings = Dict{Symbol,Any}(:data_input => [1.0, 2.0, 3.0, 4.0, 5.0])
    result = joovy_run(engine, "sum(data_input) / length(data_input)"; bindings=bindings)

    t0 = time_ns()
    native_r = sum([1.0, 2.0, 3.0, 4.0, 5.0]) / 5
    nt = Float64(time_ns() - t0)

    @test result.success
    @test isapprox(result.value, native_r; atol=1e-12)
    add_row!(table, "Bindings: mean([1:5])", native_r, result.value, nt, Float64(result.elapsed_ns))

    # --- Test 4: Multiple bindings ---
    bindings2 = Dict{Symbol,Any}(:x_val => 10, :y_val => 20, :z_val => 30)
    result = joovy_run(engine, "x_val + y_val * z_val"; bindings=bindings2)

    t0 = time_ns()
    native_r = 10 + 20 * 30
    nt = Float64(time_ns() - t0)

    @test result.success
    @test result.value == native_r
    add_row!(table, "Multi-binding expr", native_r, result.value, nt, Float64(result.elapsed_ns))

    # --- Test 5: Error handling ---
    result = joovy_run(engine, "1 / 0")
    # In Julia, integer division by zero throws, but float gives Inf
    # Let's test actual error:
    err_result = joovy_run(engine, "error(\"test error\")")

    @test !err_result.success
    @test err_result.error !== nothing
    add_row!(table, "Error caught", "ErrorException", string(typeof(err_result.error)), 0.0, 0.0)

    # --- Test 6: File execution ---
    test_dir = @__DIR__
    script_path = joinpath(test_dir, "scripts", "v1_processor.jl")

    # Write a self-contained script that returns a value
    tmpscript = joinpath(test_dir, "scripts", "_engine_test.jl")
    write(tmpscript, """
        function engine_test_fn(x)
            return x * 5 + 3
        end
        engine_test_fn(10)
    """)

    result = joovy_run_file(engine, tmpscript)

    t0 = time_ns()
    native_r = 10 * 5 + 3
    nt = Float64(time_ns() - t0)

    @test result.success
    @test result.value == native_r
    add_row!(table, "File execution", native_r, result.value, nt, Float64(result.elapsed_ns))

    # --- Test 7: Stateful script updates ---
    write(tmpscript, """
        stateful_fn(x) = x + 1000
        stateful_fn(5)
    """)
    r1 = joovy_run_file(engine, tmpscript)

    write(tmpscript, """
        stateful_fn(x) = x - 1000
        stateful_fn(5)
    """)
    r2 = joovy_run_file(engine, tmpscript)

    t0 = time_ns()
    native_r1 = 5 + 1000
    native_r2 = 5 - 1000
    nt = Float64(time_ns() - t0)

    @test r1.success && r1.value == native_r1
    @test r2.success && r2.value == native_r2
    add_row!(table, "File update v1→v2 (v1)", native_r1, r1.value, nt, 0.0)
    add_row!(table, "File update v1→v2 (v2)", native_r2, r2.value, 0.0, 0.0)

    # --- Test 8: Array processing via engine ---
    bindings3 = Dict{Symbol,Any}(:arr => collect(1:100))
    result = joovy_run(engine, """
        map(x -> x^2, arr) |> sum
    """; bindings=bindings3)

    t0 = time_ns()
    native_r = sum(x^2 for x in 1:100)
    nt = Float64(time_ns() - t0)

    @test result.success
    @test result.value == native_r
    add_row!(table, "Array map+sum [100]", native_r, result.value, nt, Float64(result.elapsed_ns))

    # Cleanup
    rm(tmpscript; force=true)

    print_table(table)
    @test table_all_passed(table)
end

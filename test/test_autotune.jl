using Test
using Joovy

@testset "AutoTune" begin
    table = ComparisonTable("AutoTune: Runtime Kernel Optimization & Variant Selection")

    # --- Test 1: Basic benchmark ---
    native_fn(x) = sum(x .^ 2)
    data = rand(100)

    t0 = time_ns()
    native_r = native_fn(data)
    nt = Float64(time_ns() - t0)

    joovy_fn = joovy_compile("sum_sq_joovy(x) = sum(x .^ 2)")
    t0 = time_ns()
    joovy_r = joovy_fn(data)
    ft = Float64(time_ns() - t0)

    @test isapprox(native_r, joovy_r; atol=1e-8)
    add_row!(table, "Sum of squares [100]", round(native_r, digits=4), round(joovy_r, digits=4), nt, ft)

    # --- Test 2: Benchmark variant helper ---
    config = TuneConfig(warmup_runs=2, bench_runs=5)
    vr = benchmark_variant(native_fn, data; config=config)

    @test vr.result !== nothing
    @test vr.median_time_ns >= 0
    add_row!(table, "Benchmark ran", true, vr.result !== nothing, 0.0, 0.0)

    # --- Test 3: Compare native vs joovy benchmarks ---
    comparison = joovy_autotune_compare(native_fn, joovy_fn, data; config=config)

    @test isapprox(comparison.native.result, comparison.joovy.result; atol=1e-8)
    add_row!(table, "Benchmark results match",
             round(comparison.native.result, digits=4),
             round(comparison.joovy.result, digits=4),
             comparison.native.median_time_ns,
             comparison.joovy.median_time_ns)

    # --- Test 4: Variant generation with unique names ---
    base_code = "vfn(x) = sum(x .^ POWER)"
    param_space = Dict{Symbol,Any}(:POWER => [2, 3, 4])
    variants = generate_variants(base_code, param_space)

    @test length(variants) == 3

    data_small = [2.0, 3.0]

    native_p2 = sum(data_small .^ 2)
    native_p3 = sum(data_small .^ 3)
    native_p4 = sum(data_small .^ 4)

    r2 = variants[1].fn(data_small)
    r3 = variants[2].fn(data_small)
    r4 = variants[3].fn(data_small)

    @test isapprox(r2, native_p2; atol=1e-10)
    @test isapprox(r3, native_p3; atol=1e-10)
    @test isapprox(r4, native_p4; atol=1e-10)

    add_row!(table, "Variant POWER=2", native_p2, r2, 0.0, 0.0)
    add_row!(table, "Variant POWER=3", native_p3, r3, 0.0, 0.0)
    add_row!(table, "Variant POWER=4", native_p4, r4, 0.0, 0.0)

    # --- Test 5: Full autotune finds best ---
    tune_result = joovy_autotune(
        base_code, param_space, data;
        config=TuneConfig(mode=:measure, warmup_runs=2, bench_runs=5)
    )

    @test tune_result.best_variant.median_time_ns >= 0
    @test length(tune_result.all_variants) == 3

    best_power = tune_result.best_variant.params[:POWER]
    expected_best = sum(data .^ best_power)
    @test isapprox(tune_result.best_variant.result, expected_best; atol=1e-6)

    add_row!(table, "Best variant correct",
             round(expected_best, digits=4),
             round(tune_result.best_variant.result, digits=4),
             tune_result.all_variants[end].median_time_ns,
             tune_result.best_variant.median_time_ns)

    # --- Test 6: Multi-parameter autotune ---
    multi_code = "mfn(x) = sum(x[1:WINDOW] .^ POWER)"
    multi_params = Dict{Symbol,Any}(:WINDOW => [10, 50], :POWER => [2, 3])

    multi_data = rand(100)
    multi_result = joovy_autotune(
        multi_code, multi_params, multi_data;
        config=TuneConfig(mode=:exhaustive, warmup_runs=2, bench_runs=5)
    )

    @test length(multi_result.all_variants) == 4  # 2 × 2
    add_row!(table, "Multi-param variants", 4, length(multi_result.all_variants), 0.0, 0.0)

    best_mp = multi_result.best_variant.params
    expected = sum(multi_data[1:best_mp[:WINDOW]] .^ best_mp[:POWER])

    @test isapprox(multi_result.best_variant.result, expected; atol=1e-6)
    add_row!(table, "Multi-param correct",
             round(expected, digits=4),
             round(multi_result.best_variant.result, digits=4),
             0.0, 0.0)

    # --- Test 7: Wisdom cache ---
    wisdom_clear!()
    tune_with_wisdom = joovy_autotune(
        base_code, param_space, data;
        config=TuneConfig(mode=:measure, warmup_runs=2, bench_runs=3),
        wisdom_key="test_sum_sq"
    )

    cached = joovy_autotune(
        base_code, param_space, data;
        config=TuneConfig(mode=:estimate, warmup_runs=1, bench_runs=1),
        wisdom_key="test_sum_sq"
    )

    @test cached isa Joovy.AutoTune.VariantResult
    add_row!(table, "Wisdom cache hit", true, cached isa Joovy.AutoTune.VariantResult, 0.0, 0.0)

    print_table(table)
    @test table_all_passed(table)
end

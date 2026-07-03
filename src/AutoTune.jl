module AutoTune

using ..ExprCache
using ..DynCompiler
using Statistics
using Serialization

export TuneResult, TuneConfig, joovy_autotune, joovy_autotune_compare,
       Wisdom, wisdom_save, wisdom_load, wisdom_clear!,
       generate_variants, benchmark_variant

struct TuneConfig
    mode::Symbol           # :estimate, :measure, :exhaustive
    warmup_runs::Int
    bench_runs::Int
    min_time_ns::UInt64
end

TuneConfig(; mode=:measure, warmup_runs=3, bench_runs=10, min_time_ns=UInt64(1_000_000)) =
    TuneConfig(mode, warmup_runs, bench_runs, min_time_ns)

struct VariantResult
    variant_id::Int
    params::Dict{Symbol, Any}
    median_time_ns::Float64
    min_time_ns::Float64
    max_time_ns::Float64
    std_time_ns::Float64
    result::Any
end

struct TuneResult
    best_variant::VariantResult
    all_variants::Vector{VariantResult}
    speedup_vs_first::Float64
    total_tune_time_ns::UInt64
end

mutable struct Wisdom
    entries::Dict{String, VariantResult}
    lock::ReentrantLock

    Wisdom() = new(Dict{String,VariantResult}(), ReentrantLock())
end

const GLOBAL_WISDOM = Wisdom()

function benchmark_variant(fn, args...; config::TuneConfig=TuneConfig())
    for _ in 1:config.warmup_runs
        fn(args...)
    end

    times = Vector{UInt64}(undef, config.bench_runs)
    result = nothing
    for i in 1:config.bench_runs
        t0 = time_ns()
        result = fn(args...)
        times[i] = time_ns() - t0
    end

    ftimes = Float64.(times)
    VariantResult(
        0,
        Dict{Symbol,Any}(),
        median(ftimes),
        minimum(ftimes),
        maximum(ftimes),
        config.bench_runs > 1 ? std(ftimes) : 0.0,
        result
    )
end

function generate_variants(base_code::String, param_space::AbstractDict{Symbol};
                           mod::Module=Main)
    param_names = collect(keys(param_space))
    param_values = collect(values(param_space))

    combos = _cartesian_product(param_values)
    variants = []

    for (i, combo) in enumerate(combos)
        params = Dict{Symbol,Any}(param_names[j] => combo[j] for j in eachindex(param_names))

        code = base_code
        for (name, val) in params
            code = replace(code, string(name) => string(val))
        end

        unique_name = Symbol("_joovy_variant_$(i)_$(abs(hash(code)) % 100000)")
        code = _rename_function(code, unique_name)

        compiled = joovy_compile(code; name=unique_name, mod=mod)
        push!(variants, (id=i, params=params, fn=compiled))
    end

    return variants
end

function _rename_function(code::String, new_name::Symbol)
    ns = string(new_name)
    c = replace(code, r"function\s+(\w+)\s*\(" => SubstitutionString("function $(ns)("))
    if c == code
        c = replace(code, r"^(\w+)\s*\(" => SubstitutionString("$(ns)("))
    end
    return c
end

function joovy_autotune(base_code::String, param_space::AbstractDict{Symbol},
                        test_args...;
                        config::TuneConfig=TuneConfig(),
                        mod::Module=Main,
                        wisdom_key::Union{String,Nothing}=nothing)
    if wisdom_key !== nothing
        cached = lock(GLOBAL_WISDOM.lock) do
            get(GLOBAL_WISDOM.entries, wisdom_key, nothing)
        end
        if cached !== nothing && config.mode === :estimate
            return cached
        end
    end

    t0 = time_ns()
    variants = generate_variants(base_code, param_space; mod=mod)
    results = VariantResult[]

    for (i, v) in enumerate(variants)
        if config.mode === :estimate && i > 3
            break
        end

        vr = benchmark_variant(v.fn, test_args...; config=config)
        push!(results, VariantResult(
            v.id, v.params,
            vr.median_time_ns, vr.min_time_ns, vr.max_time_ns, vr.std_time_ns,
            vr.result
        ))
    end

    sort!(results, by=r -> r.median_time_ns)

    best = results[1]
    first_time = results[end].median_time_ns
    speedup = first_time > 0 ? first_time / best.median_time_ns : 1.0

    total_time = time_ns() - t0

    if wisdom_key !== nothing
        lock(GLOBAL_WISDOM.lock) do
            GLOBAL_WISDOM.entries[wisdom_key] = best
        end
    end

    return TuneResult(best, results, speedup, total_time)
end

function joovy_autotune_compare(native_fn, joovy_fn, test_args...;
                                config::TuneConfig=TuneConfig())
    native_result = benchmark_variant(native_fn, test_args...; config=config)
    joovy_result = benchmark_variant(joovy_fn, test_args...; config=config)

    return (native=native_result, joovy=joovy_result)
end

function wisdom_save(path::String)
    lock(GLOBAL_WISDOM.lock) do
        open(path, "w") do io
            serialize(io, GLOBAL_WISDOM.entries)
        end
    end
end

function wisdom_load(path::String)
    if !isfile(path)
        return
    end
    lock(GLOBAL_WISDOM.lock) do
        entries = open(path, "r") do io
            deserialize(io)
        end
        merge!(GLOBAL_WISDOM.entries, entries)
    end
end

function wisdom_clear!()
    lock(GLOBAL_WISDOM.lock) do
        empty!(GLOBAL_WISDOM.entries)
    end
end

function _cartesian_product(arrays)
    if isempty(arrays)
        return [()]
    end
    result = Tuple[]
    _cart_helper!(result, arrays, 1, ())
    return result
end

function _cart_helper!(result, arrays, idx, current)
    if idx > length(arrays)
        push!(result, current)
        return
    end
    for val in arrays[idx]
        _cart_helper!(result, arrays, idx + 1, (current..., val))
    end
end

end # module

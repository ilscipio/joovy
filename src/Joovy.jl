module Joovy

_mean(x) = isempty(x) ? 0.0 : sum(x) / length(x)

include("ExprCache.jl")
include("WorldAgeBridge.jl")
include("DynCompiler.jl")
include("HotSwap.jl")
include("StaticCompile.jl")
include("CompileTimeline.jl")
include("TieredCompile.jl")
include("MemoryManager.jl")
include("LazyModule.jl")
include("PackageTier.jl")
include("ColdLoad.jl")
include("Instrument.jl")
include("Config.jl")
include("JoovyObject.jl")
include("ScriptEngine.jl")
include("AutoTune.jl")
include("Debug.jl")
include("IpcBridge.jl")
include("Integration.jl")
include("Warmup.jl")

using .ExprCache
using .WorldAgeBridge
using .DynCompiler
using .HotSwap
using .StaticCompile
using .CompileTimeline
using .TieredCompile
using .MemoryManager
using .LazyModules
using .Instrument
using .ColdLoad
using .PackageTier
using .JoovyObjects
using .ScriptEngine
using .AutoTune
using .Debug
using .IpcBridge
using .Integration
using .Warmup
using .Config

# ExprCache
export JoovyCache, cache_put!, cache_get, cache_has, cache_register!,
       cache_lookup, cache_clear!, cache_stats, normalize_expr, expr_hash

# WorldAgeBridge
export joovy_eval, joovy_function, invoke_joovy

# DynCompiler
export joovy_compile, joovy_compile_file, joovy_recompile!,
       compilation_stats, GLOBAL_CACHE, AbstractJoovyCallable, JoovyCallable,
       GLOBAL_SOURCE_MAP, SourceMapping, source_map_lookup, source_map_reverse,
       compile_expr_raw, extract_function_names

# HotSwap
export HotSwapRegistry, SwapEntry, hotswap_register!, hotswap_swap!,
       hotswap_call, hotswap_load_file!, hotswap_reload!, hotswap_version,
       hotswap_history, GLOBAL_REGISTRY

# StaticCompile
export TypedJoovyCallable, FullyTypedJoovyCallable,
       JoovyCallSite, joovy_lock!, joovy_unlock!, joovy_is_locked,
       joovy_callsite, joovy_compile_typed

# CompileTimeline
export CompileEvent, record_compile!, compile_timeline, compile_tree,
       compile_stats_summary, compile_report, clear_timeline!

# TieredCompile
export TieredCallable, joovy_compile_tiered, promote!, get_tier,
       set_promote_threshold!, tier_stats, set_module_tier!,
       make_tiered_callable, set_nospecialize!, nospecialize_enabled

# MemoryManager
export cache_trim!, hotswap_trim_history!, source_map_gc!, joovy_memory_stats,
       timeline_trim!

# LazyModule
export LazyModule, joovy_use, joovy_reload!, joovy_watch_lazy!, joovy_promote_lazy!,
       lazy_status, lazy_compiled, lazy_pending

# Instrument
export CounterEntry, joovy_exec, instrument_expr, counters_report,
       start_counter_stream!, reset_counters!

# ColdLoad
export prepare_cold_load!, finish_cold_load!, cold_load_active

# PackageTier
export joovy_use_package, joovy_promote_package!, joovy_dev_mode!, joovy_dev_mode_eager!,
       joovy_dev_mode_status, joovy_package_tiers, joovy_promote_loaded!

# JoovyObject
export JoovyObject, joovy_override!, joovy_remove_override!, joovy_call,
       joovy_has_override, joovy_list_overrides, joovy_reset!

# ScriptEngine
export JoovyEngine, joovy_run, joovy_run_file, joovy_watch!, joovy_unwatch!,
       EngineResult

# AutoTune
export TuneResult, TuneConfig, joovy_autotune, joovy_autotune_compare,
       Wisdom, wisdom_save, wisdom_load, wisdom_clear!,
       generate_variants, benchmark_variant

# Debug
export joovy_hot_reload, joovy_debug_info, is_joovy_frame, clean_frame_name,
       joovy_filter_stacktrace, joovy_breakpoint_map

# IpcBridge
export joovy_register_ipc_handlers!, joovy_ipc_available

# Integration
export JoovySession, session_compile, session_swap!, session_status,
       session_eval, session_reset!, session_hot_reload, session_connect_ide!,
       session_lock!, session_unlock!, session_callsite,
       session_compile_tiered, session_use, session_compile_timeline

# Warmup
export joovy_warm, warmup_generate, warmup_build, warm_daemon_loop

# Config
export joovy_apply_preferences!, joovy_config_status,
       joovy_config_pkg_tier, joovy_config_fn_tier

# Apply any [Joovy] LocalPreferences.toml tier config on `using Joovy`, so plain-Julia
# users (no IDE) get declarative tiering with zero extra calls. No-op when there is no
# config. Skipped during precompile, in remote/native profiling mode, or when opted out.
function __init__()
    ccall(:jl_generating_output, Cint, ()) == 1 && return
    get(ENV, "JULIA_IDE_JOOVY_REMOTE", "") == "1" && return
    get(ENV, "JOOVY_NO_AUTO_CONFIG", "") == "1" && return
    try
        joovy_apply_preferences!()
    catch e
        @warn "Joovy: failed to apply LocalPreferences.toml config" exception=(e, catch_backtrace())
    end
end

# Test/demo comparison table utilities
export ComparisonTable, add_row!, print_table, table_all_passed

mutable struct ComparisonRow
    test_name::String
    native_result::String
    joovy_result::String
    match::Bool
    native_time_ns::Float64
    joovy_time_ns::Float64
    speedup::Float64
end

mutable struct ComparisonTable
    title::String
    rows::Vector{ComparisonRow}

    ComparisonTable(title::String) = new(title, ComparisonRow[])
end

function add_row!(table::ComparisonTable, test_name::String,
                  native_result, joovy_result,
                  native_time_ns::Real, joovy_time_ns::Real)
    match = _results_match(native_result, joovy_result)
    speedup = native_time_ns > 0 ? native_time_ns / joovy_time_ns : 0.0

    push!(table.rows, ComparisonRow(
        test_name,
        _format_result(native_result),
        _format_result(joovy_result),
        match,
        Float64(native_time_ns),
        Float64(joovy_time_ns),
        speedup
    ))
end

function _results_match(a, b)
    if a isa AbstractFloat && b isa AbstractFloat
        return isapprox(a, b; atol=1e-10, rtol=1e-8)
    elseif a isa AbstractArray && b isa AbstractArray
        return length(a) == length(b) && all(isapprox.(a, b; atol=1e-10, rtol=1e-8))
    else
        return a == b
    end
end

function _format_result(x)
    s = string(x)
    length(s) > 40 ? first(s, 37) * "..." : s
end

function _format_time(ns::Float64)
    if ns < 1_000
        return "$(round(ns, digits=1)) ns"
    elseif ns < 1_000_000
        return "$(round(ns/1_000, digits=1)) us"
    elseif ns < 1_000_000_000
        return "$(round(ns/1_000_000, digits=2)) ms"
    else
        return "$(round(ns/1_000_000_000, digits=3)) s"
    end
end

function print_table(table::ComparisonTable)
    println()
    println("=" ^ 110)
    println("  $(table.title)")
    println("=" ^ 110)

    header = rpad("Test", 30) *
             rpad("Native Result", 18) *
             rpad("Joovy Result", 18) *
             rpad("Match", 8) *
             rpad("Native Time", 14) *
             rpad("Joovy Time", 14) *
             "Ratio"
    println(header)
    println("-" ^ 110)

    for row in table.rows
        match_str = row.match ? "  OK" : " FAIL"
        ratio_str = row.speedup > 0 ? "$(round(row.speedup, digits=2))x" : "N/A"

        line = rpad(row.test_name, 30) *
               rpad(row.native_result, 18) *
               rpad(row.joovy_result, 18) *
               rpad(match_str, 8) *
               rpad(_format_time(row.native_time_ns), 14) *
               rpad(_format_time(row.joovy_time_ns), 14) *
               ratio_str
        println(line)
    end

    println("-" ^ 110)
    passed = count(r -> r.match, table.rows)
    total = length(table.rows)
    ratios = [r.speedup for r in table.rows if r.speedup > 0]
    avg_ratio = !isempty(ratios) ? round(_mean(ratios), digits=2) : 0.0
    println("  $passed/$total passed | Avg speed ratio: $(avg_ratio)x (>1 = native faster)")
    println("=" ^ 110)
    println()
end

function table_all_passed(table::ComparisonTable)
    all(r -> r.match, table.rows)
end

if ccall(:jl_generating_output, Cint, ()) == 1
    let _m = @__MODULE__
        _fn = joovy_compile("_pc_f(x, y) = x + y"; name=:_pc_f, mod=_m)
        Base.invokelatest(_fn, 1, 2)
        joovy_recompile!(:_pc_f, "_pc_f(x, y) = x * y"; mod=_m)
        source_map_lookup(:_pc_f)
        source_map_reverse(:_pc_f_joovy_1)
        joovy_compile_typed("_pc_t(x) = x^2"; returns=Int, mod=_m)
        joovy_memory_stats()

        cache_clear!(GLOBAL_CACHE)
        lock(DynCompiler._source_map_lock) do
            empty!(GLOBAL_SOURCE_MAP)
        end
        DynCompiler._compile_counter[] = 0
    end
end

end # module

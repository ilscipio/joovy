# bench/bench_compile_watch.jl
#
# Benchmark for CompileWatch (src/CompileWatch.jl, src/SourcePos.jl): does the
# dynamic capture layer cost noticeable compile throughput while it's
# installed, and does applying the closure-arg-respecialization rule's own
# suggested fix (`@nospecialize`) actually reduce compile time the way the
# rule's rationale claims?
#
# Two independent FRESH-`julia`-child scenarios, each run as its own
# `bench_julia_cmd` subprocess (same "real cold session, not the harness's
# own warmed-up process" rationale as every other bench_*.jl in this repo):
#
# (a) OVERHEAD gate: a fixed compile-heavy workload (M distinct trivial
#     top-level function defs+calls, each trial using fresh names so no
#     trial benefits from a prior trial's method cache) run PRIME_ITERS
#     times (unmeasured, discarded) then K_TRIALS times (measured, GC
#     disabled around each measured call -- same rationale as
#     bench_source_cache.jl), in an "on" child (dynamic capture installed via
#     `compile_watch_start!(dynamic=true)` before the workload) and an "off"
#     child (CompileWatch never touched). Reports overhead_pct = (on.min -
#     off.min) / off.min * 100, gated <= GATE_OVERHEAD_PCT_MAX.
#
# (b) VALUE gate: a single, deliberately EXPENSIVE-TO-COMPILE outer function
#     taking an unannotated closure argument `f` and calling `f(x)` in its
#     body (the exact closure-arg-respecialization pattern), applied to
#     N_CLOSURES DISTINCT closure literals at N_CLOSURES separate call sites
#     (a real distinct-closure-per-call-site respecialization -- capturing
#     the SAME closure literal in a loop does NOT reproduce this: Julia gives
#     identical-source closures with identical-typed captures the SAME
#     concrete type, verified directly while building this fixture). Measured
#     via `Base.cumulative_compile_time_ns()` (the design's own dynamic-layer
#     table entry for coarse process-wide compile time) around the whole
#     block, once for the unannotated ("nofix") version and once for the
#     `@nospecialize f`-annotated ("fixed") version of the SAME body. Reports
#     factor = nofix_ns / fixed_ns, gated >= GATE_VALUE_FACTOR_MIN.
#
# Markers only on stdout (this script is itself run as a child by
# bench/run_benchmarks.jl); diagnostics go to stderr.
#
# Usage:
#   julia bench/bench_compile_watch.jl

include(joinpath(@__DIR__, "common.jl"))

const JOOVY_ROOT = dirname(@__DIR__)

# --- Hard gate thresholds (tunable; exit 1 if violated) ----------------------
#
# GATE_OVERHEAD_PCT_MAX starts at the design brief's literal 5% placeholder.
# GATE_VALUE_FACTOR_MIN starts at the design brief's literal 1.5x placeholder
# -- verified achievable directly while building this fixture (observed
# ~7.5x locally with N_CLOSURES=60 against the SAME heavy-body pattern used
# below), so 1.5x is kept as a comfortable, non-vacuous floor rather than
# raised to match that one observation.
const GATE_OVERHEAD_PCT_MAX = 5.0
const GATE_VALUE_FACTOR_MIN = 1.5

const PRIME_ITERS = 3
const K_TRIALS = 7
const M_FUNCS = 60          # (a): functions defined+called per trial
const N_CLOSURES = 60       # (b): distinct closures / call sites per scenario

const _CHILD_PREFIX = "__CW_BENCH_CHILD__ "

# ===================================================================
# (a) overhead: workload + child driver
# ===================================================================

# `seed` guarantees every (child, trial) pair defines FRESH, never-before-seen
# top-level names, so no trial benefits from an earlier trial's already-warm
# method table -- each measured trial pays a genuinely fresh compile cost.
function _overhead_workload_lines(m::Int, seed::AbstractString)
    lines = String[]
    for i in 1:m
        push!(lines, "cw_bench_wl_$(seed)_$(i)(x) = x + $(i)")
        push!(lines, "cw_bench_wl_$(seed)_$(i)($(i))")
    end
    return lines
end

function _write_overhead_driver(driver_path::String; watch_on::Bool)
    lines = String[]
    push!(lines, "push!(LOAD_PATH, $(repr(JOOVY_ROOT)))")
    push!(lines, "using Joovy")
    if watch_on
        push!(lines, "compile_watch_start!(static=false, dynamic=true)")
    end
    push!(lines, "")

    # Unmeasured priming (JIT-warms the harness's own eval/parse machinery).
    for i in 1:PRIME_ITERS
        for l in _overhead_workload_lines(M_FUNCS, "prime$(i)")
            push!(lines, l)
        end
    end
    push!(lines, "GC.gc()")
    push!(lines, "")

    push!(lines, "trial_ns = Float64[]")
    for t in 1:K_TRIALS
        push!(lines, "GC.enable(false)")
        push!(lines, "t0 = time_ns()")
        for l in _overhead_workload_lines(M_FUNCS, "t$(t)")
            push!(lines, l)
        end
        push!(lines, "push!(trial_ns, time_ns() - t0)")
        push!(lines, "GC.enable(true)")
    end
    push!(lines, "")
    push!(lines, "for v in trial_ns")
    push!(lines, "    println($(repr(_CHILD_PREFIX * "trial_ns=")), v)")
    push!(lines, "end")
    if watch_on
        push!(lines, "println($(repr(_CHILD_PREFIX * "dynamic_active=")), Float64(compile_watch_status().dynamic_active))")
    end

    write(driver_path, join(lines, "\n") * "\n")
    return nothing
end

# ===================================================================
# (b) value: heavy-body fixture + child driver
# ===================================================================

# A deliberately non-trivial outer body (loops + Dict + trig), so N-fold
# RE-SPECIALIZATION of the OUTER function (one copy of this whole body per
# distinct closure type, when `f` is unannotated) is the dominant cost, not
# the (basically constant, same in both variants) cost of compiling each tiny
# closure itself. Verified directly while building this fixture: with a
# trivial one-line outer body the nofix/fixed compile-time GAP nearly
# disappears (factor ~0.9x) because per-closure compile cost then dominates
# equally in both variants -- this heavier body is what makes the
# closure-arg-respecialization FIX's actual benefit measurable at all.
function _heavy_fn_source(name::String; nospecialize::Bool)
    nospec_line = nospecialize ? "    Base.@nospecialize f\n" : ""
    return """
    function $(name)(f, x)
    $(nospec_line)    a = 0.0
        for i in 1:8
            a += sin(x * i) + cos(x / (i + 1)) - sqrt(abs(x) + i)
            a *= 1.0001
            if a > 1e10
                a = 0.0
            end
        end
        b = Dict{String,Float64}()
        for i in 1:5
            b["k\$(i)"] = a + i
        end
        s = 0.0
        for (k, v) in b
            s += v * length(k)
        end
        return f(x) + a + s
    end
    """
end

function _write_value_driver(driver_path::String; nospecialize::Bool)
    fname = nospecialize ? "cw_bench_heavy_fixed" : "cw_bench_heavy_nofix"
    lines = String[]
    push!(lines, "push!(LOAD_PATH, $(repr(JOOVY_ROOT)))")
    push!(lines, "using Joovy")
    push!(lines, "")
    push!(lines, _heavy_fn_source(fname; nospecialize=nospecialize))
    push!(lines, "")
    push!(lines, "Base.cumulative_compile_timing(true)")
    push!(lines, "t0 = Base.cumulative_compile_time_ns()")
    for i in 1:N_CLOSURES
        # Each call site below is its OWN closure literal (a distinct AST
        # node), so each is its OWN concrete anonymous-function type --
        # exactly the pattern closure-arg-respecialization flags.
        push!(lines, "$(fname)(x -> x + $(i), $(i) * 1.0)")
    end
    push!(lines, "t1 = Base.cumulative_compile_time_ns()")
    push!(lines, "Base.cumulative_compile_timing(false)")
    push!(lines, "compile_ns = Float64((t1[1] - t0[1]) + (t1[2] - t0[2]))")
    push!(lines, "specializations = length(collect(Base.specializations(first(methods($(fname))))))")
    push!(lines, "println($(repr(_CHILD_PREFIX * "compile_ns=")), compile_ns)")
    push!(lines, "println($(repr(_CHILD_PREFIX * "specializations=")), specializations)")

    write(driver_path, join(lines, "\n") * "\n")
    return nothing
end

# ===================================================================
# Marker scraping
# ===================================================================

function _scrape_all(output::AbstractString, key::AbstractString)::Vector{Float64}
    vals = Float64[]
    re = Regex(key * "=(\\S+)")
    for line in split(output, '\n')
        startswith(line, _CHILD_PREFIX) || continue
        m = match(re, line)
        m === nothing && continue
        push!(vals, parse(Float64, m.captures[1]))
    end
    return vals
end

function _scrape_one(output::AbstractString, key::AbstractString)::Union{Float64,Nothing}
    vals = _scrape_all(output, key)
    isempty(vals) && return nothing
    return vals[end]
end

# ===================================================================
# Scenario runners
# ===================================================================

function run_overhead(; watch_on::Bool)
    dir = mktempdir(; prefix="joovy_bench_cw_overhead_")
    write(joinpath(dir, "Project.toml"),
          "name = \"CWBenchProj\"\nuuid = \"22222222-3333-4444-5555-666666666666\"\n")
    driver_path = joinpath(dir, "_driver.jl")
    _write_overhead_driver(driver_path; watch_on=watch_on)

    cmd = bench_julia_cmd(driver_path; project=dir)
    out, ok, elapsed = run_bench_child(cmd)
    ok || error("bench_compile_watch: overhead child (watch_on=$watch_on) failed after $(round(elapsed, digits=1))s:\n$out")

    trial_ns = _scrape_all(out, "trial_ns")
    isempty(trial_ns) && error("bench_compile_watch: overhead child (watch_on=$watch_on) missing trial_ns markers:\n$out")
    dynamic_active = watch_on ? _scrape_one(out, "dynamic_active") : nothing

    return (min_ns = minimum(trial_ns), median_ns = _median(trial_ns), dynamic_active = dynamic_active)
end

function run_value(; nospecialize::Bool)
    dir = mktempdir(; prefix="joovy_bench_cw_value_")
    write(joinpath(dir, "Project.toml"),
          "name = \"CWBenchProj\"\nuuid = \"22222222-3333-4444-5555-666666666666\"\n")
    driver_path = joinpath(dir, "_driver.jl")
    _write_value_driver(driver_path; nospecialize=nospecialize)

    cmd = bench_julia_cmd(driver_path; project=dir)
    out, ok, elapsed = run_bench_child(cmd)
    ok || error("bench_compile_watch: value child (nospecialize=$nospecialize) failed after $(round(elapsed, digits=1))s:\n$out")

    compile_ns = _scrape_one(out, "compile_ns")
    specializations = _scrape_one(out, "specializations")
    (compile_ns === nothing || specializations === nothing) &&
        error("bench_compile_watch: value child (nospecialize=$nospecialize) missing marker(s):\n$out")

    return (compile_ns = compile_ns, specializations = Int(specializations))
end

# ===================================================================
# main
# ===================================================================

function main()
    println("Joovy CompileWatch benchmark -- M_FUNCS=$M_FUNCS K_TRIALS=$K_TRIALS N_CLOSURES=$N_CLOSURES")
    println("=" ^ 70)

    println("  RUN   (a) overhead: watch=off")
    off = run_overhead(watch_on=false)
    println("  RUN   (a) overhead: watch=on")
    on = run_overhead(watch_on=true)

    println("  RUN   (b) value: nofix (unannotated closure arg)")
    nofix = run_value(nospecialize=false)
    println("  RUN   (b) value: fixed (@nospecialize closure arg)")
    fixed = run_value(nospecialize=true)

    overhead_pct = off.min_ns > 0 ? (on.min_ns - off.min_ns) / off.min_ns * 100 : NaN
    value_factor = fixed.compile_ns > 0 ? nofix.compile_ns / fixed.compile_ns : Inf

    println("=" ^ 70)
    println("  (a) overhead: off_min_ns=$(off.min_ns) on_min_ns=$(on.min_ns) overhead_pct=$(round(overhead_pct, digits=2))%")
    println("      off_median_ns=$(off.median_ns) on_median_ns=$(on.median_ns) dynamic_active(on)=$(on.dynamic_active)")
    println("  (b) value: nofix_compile_ns=$(nofix.compile_ns) fixed_compile_ns=$(fixed.compile_ns) factor=$(round(value_factor, digits=2))x")
    println("      nofix_specializations=$(nofix.specializations) fixed_specializations=$(fixed.specializations)")

    bench_line(stdout, "compile_watch", "overhead_off_min_ns", round(off.min_ns, digits=1), "ns")
    bench_line(stdout, "compile_watch", "overhead_on_min_ns", round(on.min_ns, digits=1), "ns")
    bench_line(stdout, "compile_watch", "overhead_off_median_ns", round(off.median_ns, digits=1), "ns")
    bench_line(stdout, "compile_watch", "overhead_on_median_ns", round(on.median_ns, digits=1), "ns")
    bench_line(stdout, "compile_watch", "overhead_pct", round(overhead_pct, digits=2), "pct")
    bench_line(stdout, "compile_watch", "dynamic_active", on.dynamic_active, "bool")
    bench_line(stdout, "compile_watch", "value_nofix_compile_ns", round(nofix.compile_ns, digits=1), "ns")
    bench_line(stdout, "compile_watch", "value_fixed_compile_ns", round(fixed.compile_ns, digits=1), "ns")
    bench_line(stdout, "compile_watch", "value_improvement_factor", round(value_factor, digits=2), "x")
    bench_line(stdout, "compile_watch", "value_nofix_specializations", nofix.specializations, "count")
    bench_line(stdout, "compile_watch", "value_fixed_specializations", fixed.specializations, "count")

    passed = true

    if !(overhead_pct <= GATE_OVERHEAD_PCT_MAX)
        println(stderr, "GATE FAIL: overhead_pct=$(round(overhead_pct, digits=2))% not <= $(GATE_OVERHEAD_PCT_MAX)%")
        passed = false
    end

    if on.dynamic_active != 1.0
        println(stderr, "GATE FAIL: dynamic capture was not active in the 'on' child (dynamic_active=$(on.dynamic_active)) -- overhead number is not measuring what it claims to")
        passed = false
    end

    if !(value_factor >= GATE_VALUE_FACTOR_MIN)
        println(stderr, "GATE FAIL: value_improvement_factor=$(round(value_factor, digits=2))x not >= $(GATE_VALUE_FACTOR_MIN)x")
        passed = false
    end

    # Sanity: the fix must actually collapse specializations for this to be a
    # meaningful demonstration of the rule's own rationale, not a fluke.
    if !(nofix.specializations > fixed.specializations)
        println(stderr, "GATE FAIL: nofix_specializations=$(nofix.specializations) not > fixed_specializations=$(fixed.specializations)")
        passed = false
    end

    if !passed
        println(stderr, "bench_compile_watch: one or more hard gates FAILED")
        exit(1)
    end

    println("All gates passed.")
    return nothing
end

main()

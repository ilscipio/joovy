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
#     off.min) / off.min * 100 (reporting-only); the gated overhead number
#     is the in-process record_overhead_ns_per_call probe, see (a2).
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

# Loaded directly in THIS (parent) process too -- unlike (a)/(b) below, (c)'s
# static-rule gate calls `compile_watch_check` in-process (no child needed for
# a pure AST check), so the parent needs Joovy on its own LOAD_PATH. This is
# independent of, and does not affect, the isolated child subprocesses (a)/(b)/(c)
# spawn for their own measurements.
push!(LOAD_PATH, JOOVY_ROOT)
using Joovy

# --- Hard gate thresholds (tunable; exit 1 if violated) ----------------------
#
# The child-process wall-clock overhead comparison (overhead_pct) is
# REPORTING-ONLY, not a gate: across identical runs with no code change it
# swung -16.8%..+11.5% (two compile-heavy children diverge by hundreds of ms
# from JIT/GC/scheduler variance alone), so no honest threshold exists at the
# magnitude of the real signal. The gated overhead number is instead the
# in-process per-call delta of the :full record path vs an identical plain
# function (GATE_RECORD_OVERHEAD_NS_MAX): measured ~200 ns/call; the 2000 ns
# bound is a 10x margin that catches a real regression (e.g. the GC_Diff
# arithmetic getting inlined into callers again) without machine-noise flakes.
# GATE_VALUE_FACTOR_MIN starts at the design brief's literal 1.5x placeholder
# -- verified achievable directly while building this fixture (observed
# ~7.5x locally with N_CLOSURES=60 against the SAME heavy-body pattern used
# below), so 1.5x is kept as a comfortable, non-vacuous floor rather than
# raised to match that one observation.
# GATE_ALLOC_REDUCTION_FACTOR_MIN: the study's own pattern (a vectorized chain
# of separate broadcast statements, each allocating a full intermediate
# array, vs a loop rewrite allocating only the final output) -- allocation
# BYTE COUNTS are deterministic (no wall-clock noise), so this gate is exact,
# not statistical.
const GATE_RECORD_OVERHEAD_NS_MAX = 2000.0
const GATE_VALUE_FACTOR_MIN = 1.5
const GATE_ALLOC_REDUCTION_FACTOR_MIN = 10.0

const PRIME_ITERS = 3
const K_TRIALS = 7
const M_FUNCS = 60          # (a): functions defined+called per trial
const N_CLOSURES = 60       # (b): distinct closures / call sites per scenario
const IMG_N = 256           # (c): image side length (~256x256, per the study's fixture)

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
# (c) alloc: deterministic chain-vs-loop image fixture (also exercises the
# NEW long-broadcast-fusion-chain static rule -- see run_alloc_check below)
# ===================================================================
#
# "Chain": builds a ~256x256 image via a vectorized broadcast chain -- the
# study's "non-fused vectorized chains allocate an intermediate per step"
# pattern. Each of the 9 channel lines (r, g, b, a, noise, base, shift, tint,
# glow) is its OWN separate broadcast statement, so each allocates its own
# full IMG_N x IMG_N array before the next line even starts (fusion cannot
# cross a statement boundary); the final compositing line then ALSO chains
# 17 dotted operations in ONE statement (well over the default
# long-broadcast-fusion-chain threshold of 8), so this single fixture
# demonstrates both the allocation finding and the inference-cost finding
# from the same study.
#
# "Loop": the same math, computed per-pixel with plain scalar arithmetic into
# ONE pre-allocated output array -- zero intermediate IMG_N x IMG_N arrays.
const _CHAIN_IMAGE_SRC = """
function cw_bench_chain_image(n::Int)
    rows  = Float64.(1:n)
    cols  = Float64.(1:n)'
    X     = rows .* ones(1, n)
    Y     = ones(n, 1) .* cols
    r     = sin.(X .* 0.01)
    g     = cos.(Y .* 0.02)
    b     = sin.((X .+ Y) .* 0.005)
    a     = cos.((X .- Y) .* 0.007)
    noise = sin.(X .* 0.03) .* cos.(Y .* 0.03)
    base  = cos.(X .* 0.011)
    shift = sin.(Y .* 0.013)
    tint  = cos.((X .* Y) .* 0.0001)
    glow  = sin.(X .+ Y)
    out = clamp.(r .+ g .* 0.5 .- b .* 0.3 .+ a .* 0.2 .- noise .* 0.1 .+ base .* 0.05 .- shift .* 0.02 .+ tint .* 0.01 .- glow .* 0.005, 0.0, 1.0)
    return out
end
"""

const _LOOP_IMAGE_SRC = """
function cw_bench_loop_image(n::Int)
    out = Matrix{Float64}(undef, n, n)
    @inbounds for j in 1:n
        y = Float64(j)
        for i in 1:n
            x = Float64(i)
            r = sin(x * 0.01)
            g = cos(y * 0.02)
            b = sin((x + y) * 0.005)
            a = cos((x - y) * 0.007)
            noise = sin(x * 0.03) * cos(y * 0.03)
            base = cos(x * 0.011)
            shift = sin(y * 0.013)
            tint = cos((x * y) * 0.0001)
            glow = sin(x + y)
            v = r + g * 0.5 - b * 0.3 + a * 0.2 - noise * 0.1 + base * 0.05 - shift * 0.02 + tint * 0.01 - glow * 0.005
            out[i, j] = clamp(v, 0.0, 1.0)
        end
    end
    return out
end
"""

function _write_alloc_driver(driver_path::String)
    lines = String[]
    push!(lines, _CHAIN_IMAGE_SRC)
    push!(lines, _LOOP_IMAGE_SRC)
    push!(lines, "")
    # Unmeasured priming call (pays first-call compilation cost outside the
    # measured @allocated window) at a small n so it stays cheap.
    push!(lines, "cw_bench_chain_image(4)")
    push!(lines, "cw_bench_loop_image(4)")
    push!(lines, "GC.gc()")
    push!(lines, "")
    push!(lines, "chain_bytes = @allocated cw_bench_chain_image($IMG_N)")
    push!(lines, "loop_bytes  = @allocated cw_bench_loop_image($IMG_N)")
    push!(lines, "println($(repr(_CHILD_PREFIX * "alloc_bytes_chain=")), Float64(chain_bytes))")
    push!(lines, "println($(repr(_CHILD_PREFIX * "alloc_bytes_loop=")), Float64(loop_bytes))")

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

function run_alloc()
    dir = mktempdir(; prefix="joovy_bench_cw_alloc_")
    write(joinpath(dir, "Project.toml"),
          "name = \"CWBenchProj\"\nuuid = \"22222222-3333-4444-5555-666666666666\"\n")
    driver_path = joinpath(dir, "_driver.jl")
    _write_alloc_driver(driver_path)

    cmd = bench_julia_cmd(driver_path; project=dir)
    out, ok, elapsed = run_bench_child(cmd)
    ok || error("bench_compile_watch: alloc child failed after $(round(elapsed, digits=1))s:\n$out")

    chain_bytes = _scrape_one(out, "alloc_bytes_chain")
    loop_bytes = _scrape_one(out, "alloc_bytes_loop")
    (chain_bytes === nothing || loop_bytes === nothing) &&
        error("bench_compile_watch: alloc child missing marker(s):\n$out")

    return (chain_bytes = chain_bytes, loop_bytes = loop_bytes)
end

# In-process (parent) static-rule check: does `compile_watch_check` flag the
# (c) chain fixture's source with the NEW long-broadcast-fusion-chain rule?
# Pure AST analysis, no child subprocess needed.
function run_alloc_check()
    diags = compile_watch_check(_CHAIN_IMAGE_SRC)
    return any(d -> d.rule_id === Symbol("long-broadcast-fusion-chain"), diags)
end

# In-process per-call overhead of the :full record path (the GATED overhead
# number -- see the threshold comment block). Interleaved batches cancel
# process drift; the @noinline probes keep the loops honest (nothing elides).
const _probe_entry = Joovy.Instrument.CounterEntry(:cw_overhead_probe, :full, 2)
@noinline _probe_plain(x) = x + 1.0
@noinline function _probe_full(x)
    t0 = Base.time_ns()
    gc0 = Base.gc_num()
    try
        x + 1.0
    finally
        Joovy.Instrument.record(_probe_entry, t0, gc0)
    end
end

function run_record_overhead(; batches::Int=9, iters::Int=200_000)
    _probe_plain(1.0); _probe_full(1.0)   # compile both before timing
    deltas = Float64[]
    for _ in 1:batches
        s1 = 0.0
        t1 = Base.time_ns()
        for i in 1:iters
            s1 += _probe_plain(1.0 * i)
        end
        t1 = Base.time_ns() - t1
        s2 = 0.0
        t2 = Base.time_ns()
        for i in 1:iters
            s2 += _probe_full(1.0 * i)
        end
        t2 = Base.time_ns() - t2
        s1 == s2 || error("bench_compile_watch: record-overhead probes disagree ($s1 vs $s2)")
        push!(deltas, (t2 - t1) / iters)
    end
    sort!(deltas)
    return deltas[cld(length(deltas), 2)]
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

    println("  RUN   (c) alloc: chain vs loop image fixture (n=$IMG_N)")
    alloc = run_alloc()
    println("  RUN   (c) alloc: static-rule check on the chain fixture")
    chain_flagged = run_alloc_check()

    overhead_pct = off.min_ns > 0 ? (on.min_ns - off.min_ns) / off.min_ns * 100 : NaN
    value_factor = fixed.compile_ns > 0 ? nofix.compile_ns / fixed.compile_ns : Inf
    alloc_reduction_factor = alloc.loop_bytes > 0 ? alloc.chain_bytes / alloc.loop_bytes : Inf

    println("=" ^ 70)
    println("  (a) overhead: off_min_ns=$(off.min_ns) on_min_ns=$(on.min_ns) overhead_pct=$(round(overhead_pct, digits=2))%")
    println("      off_median_ns=$(off.median_ns) on_median_ns=$(on.median_ns) dynamic_active(on)=$(on.dynamic_active)")
    println("  (b) value: nofix_compile_ns=$(nofix.compile_ns) fixed_compile_ns=$(fixed.compile_ns) factor=$(round(value_factor, digits=2))x")
    println("      nofix_specializations=$(nofix.specializations) fixed_specializations=$(fixed.specializations)")
    println("  (c) alloc: chain_bytes=$(alloc.chain_bytes) loop_bytes=$(alloc.loop_bytes) reduction_factor=$(round(alloc_reduction_factor, digits=2))x")
    println("      chain fixture flagged by long-broadcast-fusion-chain: $chain_flagged")

    bench_line(stdout, "compile_watch", "overhead_off_min_ns", round(off.min_ns, digits=1), "ns")
    bench_line(stdout, "compile_watch", "overhead_on_min_ns", round(on.min_ns, digits=1), "ns")
    bench_line(stdout, "compile_watch", "overhead_off_median_ns", round(off.median_ns, digits=1), "ns")
    bench_line(stdout, "compile_watch", "overhead_on_median_ns", round(on.median_ns, digits=1), "ns")
    bench_line(stdout, "compile_watch", "overhead_pct", round(overhead_pct, digits=2), "pct")
    println("  RUN   (a2) in-process record-path overhead")
    record_overhead_ns = run_record_overhead()
    println("  (a2) record path: $(round(record_overhead_ns, digits=1)) ns/call over an identical plain call")
    bench_line(stdout, "compile_watch", "record_overhead_ns_per_call", round(record_overhead_ns, digits=1), "ns")
    bench_line(stdout, "compile_watch", "dynamic_active", on.dynamic_active, "bool")
    bench_line(stdout, "compile_watch", "value_nofix_compile_ns", round(nofix.compile_ns, digits=1), "ns")
    bench_line(stdout, "compile_watch", "value_fixed_compile_ns", round(fixed.compile_ns, digits=1), "ns")
    bench_line(stdout, "compile_watch", "value_improvement_factor", round(value_factor, digits=2), "x")
    bench_line(stdout, "compile_watch", "value_nofix_specializations", nofix.specializations, "count")
    bench_line(stdout, "compile_watch", "value_fixed_specializations", fixed.specializations, "count")
    bench_line(stdout, "compile_watch", "alloc_bytes_chain", round(alloc.chain_bytes, digits=1), "bytes")
    bench_line(stdout, "compile_watch", "alloc_bytes_loop", round(alloc.loop_bytes, digits=1), "bytes")
    bench_line(stdout, "compile_watch", "alloc_reduction_factor", round(alloc_reduction_factor, digits=2), "x")

    passed = true

    # overhead_pct (child wall-clock A/B) is deliberately NOT gated -- see the
    # threshold comment block. The gated overhead number is the in-process
    # per-call record-path delta:
    if !(record_overhead_ns <= GATE_RECORD_OVERHEAD_NS_MAX)
        println(stderr, "GATE FAIL: record_overhead_ns_per_call=$(round(record_overhead_ns, digits=1)) not <= $(GATE_RECORD_OVERHEAD_NS_MAX)")
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

    if !(alloc_reduction_factor >= GATE_ALLOC_REDUCTION_FACTOR_MIN)
        println(stderr, "GATE FAIL: alloc_reduction_factor=$(round(alloc_reduction_factor, digits=2))x not >= $(GATE_ALLOC_REDUCTION_FACTOR_MIN)x")
        passed = false
    end

    if !chain_flagged
        println(stderr, "GATE FAIL: compile_watch_check did not flag the (c) chain fixture with long-broadcast-fusion-chain")
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

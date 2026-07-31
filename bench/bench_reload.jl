# bench/bench_reload.jl
#
# Benchmark for incremental hot-reload (src/Debug.jl `joovy_hot_reload`,
# src/HotSwap.jl `hotswap_reload_file!`): re-evaluating ONLY the definitions
# that changed on a file save, instead of re-evaluating every definition in
# the file on every save (which triggers Julia backedge invalidation of every
# caller, even callers of definitions that did not change).
#
# Two FRESH `julia` child sessions each:
#   1. write a synthetic M=50-definition file where def i calls def (i-1) and
#      def (i-2) (a Fibonacci-style dependency chain), and load it via
#      `joovy_hot_reload`.
#   2. call all 50 functions once (warm-up) so Julia actually specializes them
#      and establishes real backedges -- otherwise redefining a method has
#      nothing to invalidate and the two modes look artificially similar.
#   3. repeatedly (K_TRIALS times) edit def #EDIT_INDEX to a new value and
#      reload with `incremental=true` (child A) resp. `incremental=false`
#      (child B, i.e. today's "re-evaluate everything" behavior), timing each
#      reload; this is to get a stable median instead of a single noisy
#      sample.
#   4. report the median reload_ns, reeval_count (`fallback_definitions`,
#      i.e. how many top-level defs got re-run per reload), and recall_ns
#      (time to invoke all 50 functions once more after the last reload).
#
# This script is itself run as a child by bench/run_benchmarks.jl -- per
# run_bench_child's contract, ONLY `__JOOVY_BENCH__` marker lines go to
# stdout; diagnostics (e.g. gate failures) go to stderr.
#
# Usage:
#   julia bench/bench_reload.jl

include(joinpath(@__DIR__, "common.jl"))

const JOOVY_ROOT = dirname(@__DIR__)

# --- Hard gate thresholds (exit 1 if violated) -----------------------------
const M = 50                        # synthetic definition count
const EDIT_INDEX = 25               # 1-based index of the def edited between loads
const PRIME_ITERS = 5               # unmeasured edit+reload cycles before timing starts
const K_TRIALS = 25                 # reload measurements per child (MINIMUM is reported/gated)
const GATE_REEVAL_INCREMENTAL = 1   # reeval_count with incremental=true MUST equal this
const GATE_REEVAL_FULL = M          # reeval_count with incremental=false MUST equal this
const GATE_SPEEDUP_FACTOR = 5       # min reload_ns(incremental) MUST be < min reload_ns(full) / this

# reload_ns is reported/gated as the MINIMUM across K_TRIALS repeated
# edit+reload cycles, not the mean/median: OS scheduling jitter, GC pauses,
# and antivirus/filesystem interference can only ADD latency to a given
# sample, never subtract it, so the minimum across enough samples is the
# standard robust estimator of "true" achievable cost (same rationale
# BenchmarkTools.jl uses for its default `minimum` timing).

const _CHILD_PREFIX = "__RELOAD_CHILD__ "

# ===================================================================
# Synthetic workload: M defs, def i calls def (i-1) and def (i-2).
# ===================================================================

function generate_defs(m::Int; edit_index::Union{Int,Nothing}=nothing, edit_offset::Int=1000)
    lines = String[]
    for i in 1:m
        body = if i == 1
            "x + 1"
        elseif i == 2
            "x + 2"
        else
            "bench_reload_def_$(i-1)(x) + bench_reload_def_$(i-2)(x)"
        end
        if edit_index !== nothing && i == edit_index
            body = "$body + $edit_offset"
        end
        push!(lines, "bench_reload_def_$(i)(x) = $body")
    end
    return join(lines, "\n") * "\n"
end

# ===================================================================
# Child driver: load once, warm up, then K_TRIALS x (edit + measured
# reload), then one final recall pass.
# ===================================================================

function write_child_driver(driver_path::String, bench_path::String,
                             original_defs::String, prime_variants::Vector{String},
                             edited_variants::Vector{String},
                             incremental::Bool, m::Int)
    lines = String[]
    push!(lines, "using Joovy")
    push!(lines, "")
    push!(lines, "write($(repr(bench_path)), $(repr(original_defs)))")
    push!(lines, "joovy_hot_reload($(repr(bench_path)))")
    push!(lines, "")
    # Warm-up: call every function once so Julia actually specializes/compiles
    # them and establishes real backedges between callers and callees -- this
    # is what makes redefining a def (even to the SAME body) expensive: Julia
    # must invalidate every already-compiled caller. Without this warm-up,
    # nothing has been compiled yet, so redefinition has nothing to invalidate
    # and both modes look artificially similar.
    push!(lines, "for i in 1:$(m)")
    push!(lines, "    fn = getfield(Main, Symbol(string(\"bench_reload_def_\", i)))")
    push!(lines, "    Base.invokelatest(fn, 1)")
    push!(lines, "end")
    push!(lines, "")
    # Unmeasured priming cycles: get past first-call JIT compilation of the
    # reload code path itself before the timed trials start.
    prime_literal = "[" * join(map(repr, prime_variants), ", ") * "]"
    push!(lines, "for primed in $(prime_literal)")
    push!(lines, "    write($(repr(bench_path)), primed)")
    push!(lines, "    joovy_hot_reload($(repr(bench_path)); incremental=$(incremental))")
    push!(lines, "end")
    push!(lines, "GC.gc()")
    push!(lines, "")
    variants_literal = "[" * join(map(repr, edited_variants), ", ") * "]"
    push!(lines, "edited_variants = $(variants_literal)")
    push!(lines, "for edited in edited_variants")
    push!(lines, "    write($(repr(bench_path)), edited)")
    # GC disabled only around the measured call itself, so a GC pause landing
    # in this specific window can't inflate this specific sample -- collection
    # still happens normally between trials.
    push!(lines, "    GC.enable(false)")
    push!(lines, "    t0 = time_ns()")
    push!(lines, "    result = joovy_hot_reload($(repr(bench_path)); incremental=$(incremental))")
    push!(lines, "    dt = time_ns() - t0")
    push!(lines, "    GC.enable(true)")
    push!(lines, "    println($(repr(_CHILD_PREFIX * "reload_ns=")), dt)")
    push!(lines, "    println($(repr(_CHILD_PREFIX * "reeval_count=")), result.fallback_definitions)")
    push!(lines, "end")
    push!(lines, "")
    push!(lines, "t1 = time_ns()")
    push!(lines, "total = 0")
    push!(lines, "for i in 1:$(m)")
    push!(lines, "    fn = getfield(Main, Symbol(string(\"bench_reload_def_\", i)))")
    push!(lines, "    global total += Base.invokelatest(fn, 1)")
    push!(lines, "end")
    push!(lines, "recall_ns = time_ns() - t1")
    push!(lines, "println($(repr(_CHILD_PREFIX * "recall_ns=")), recall_ns)")
    push!(lines, "println($(repr(_CHILD_PREFIX * "total=")), total)")
    write(driver_path, join(lines, "\n") * "\n")
    return nothing
end

# Collect ALL values printed for `key` (one child prints it K_TRIALS times).
function scrape_child_all(output::AbstractString, key::AbstractString)::Vector{Float64}
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

function run_one(incremental::Bool, original_defs::String,
                  prime_variants::Vector{String}, edited_variants::Vector{String})
    dir = mktempdir(; prefix="joovy_bench_reload_")
    bench_path = joinpath(dir, "bench_defs.jl")
    driver_path = joinpath(dir, "_driver.jl")
    write_child_driver(driver_path, bench_path, original_defs, prime_variants,
                        edited_variants, incremental, M)

    cmd = bench_julia_cmd(driver_path; project=JOOVY_ROOT)
    out, ok, elapsed = run_bench_child(cmd)
    ok || error("bench_reload: child (incremental=$incremental) failed after $(round(elapsed, digits=1))s:\n$out")

    reload_ns_all = scrape_child_all(out, "reload_ns")
    reeval_all = scrape_child_all(out, "reeval_count")
    recall_ns_all = scrape_child_all(out, "recall_ns")
    if isempty(reload_ns_all) || isempty(reeval_all) || isempty(recall_ns_all)
        error("bench_reload: child (incremental=$incremental) missing marker(s):\n$out")
    end

    return (
        reload_ns = minimum(reload_ns_all),
        reload_ns_median = _median(reload_ns_all),
        reeval_count = Int(round(_median(reeval_all))),
        recall_ns = _median(recall_ns_all),
    )
end

# ===================================================================
# main
# ===================================================================

function main()
    original_defs = generate_defs(M)
    prime_variants = [generate_defs(M; edit_index=EDIT_INDEX, edit_offset=k) for k in 1:PRIME_ITERS]
    edited_variants = [generate_defs(M; edit_index=EDIT_INDEX, edit_offset=1000 + k) for k in 1:K_TRIALS]

    println("Joovy incremental-reload benchmark -- M=$M edit_index=$EDIT_INDEX trials=$K_TRIALS (+$PRIME_ITERS unmeasured priming)")
    println("=" ^ 70)

    println("  RUN   incremental=true")
    incr = run_one(true, original_defs, prime_variants, edited_variants)
    println("  RUN   incremental=false")
    full = run_one(false, original_defs, prime_variants, edited_variants)

    speedup_ratio = incr.reload_ns > 0 ? full.reload_ns / incr.reload_ns : Inf
    recall_ratio = incr.recall_ns > 0 ? full.recall_ns / incr.recall_ns : Inf

    bench_line(stdout, "reload", "reload_ns_incremental", round(incr.reload_ns, digits=1), "ns")
    bench_line(stdout, "reload", "reload_ns_full", round(full.reload_ns, digits=1), "ns")
    bench_line(stdout, "reload", "reload_ns_incremental_median", round(incr.reload_ns_median, digits=1), "ns")
    bench_line(stdout, "reload", "reload_ns_full_median", round(full.reload_ns_median, digits=1), "ns")
    bench_line(stdout, "reload", "reeval_count_incremental", incr.reeval_count, "count")
    bench_line(stdout, "reload", "reeval_count_full", full.reeval_count, "count")
    bench_line(stdout, "reload", "recall_ns_incremental", round(incr.recall_ns, digits=1), "ns")
    bench_line(stdout, "reload", "recall_ns_full", round(full.recall_ns, digits=1), "ns")
    bench_line(stdout, "reload", "reload_speedup_ratio", round(speedup_ratio, digits=2), "x")
    bench_line(stdout, "reload", "recall_speedup_ratio", round(recall_ratio, digits=2), "x")

    println("=" ^ 70)
    println("  reload_ns (min of $K_TRIALS):   incremental=$(incr.reload_ns)  full=$(full.reload_ns)  speedup=$(round(speedup_ratio, digits=2))x")
    println("  reload_ns (median of $K_TRIALS):   incremental=$(incr.reload_ns_median)  full=$(full.reload_ns_median)")
    println("  reeval_count:                      incremental=$(incr.reeval_count)  full=$(full.reeval_count)")
    println("  recall_ns:                         incremental=$(incr.recall_ns)  full=$(full.recall_ns)  ratio=$(round(recall_ratio, digits=2))x (informational only)")

    passed = true

    if incr.reeval_count != GATE_REEVAL_INCREMENTAL
        println(stderr, "GATE FAIL: reeval_count(incremental) expected $GATE_REEVAL_INCREMENTAL, got $(incr.reeval_count)")
        passed = false
    end
    if full.reeval_count != GATE_REEVAL_FULL
        println(stderr, "GATE FAIL: reeval_count(full) expected $GATE_REEVAL_FULL, got $(full.reeval_count)")
        passed = false
    end
    if !(incr.reload_ns < full.reload_ns / GATE_SPEEDUP_FACTOR)
        println(stderr, "GATE FAIL: reload_ns(incremental)=$(incr.reload_ns) not < reload_ns(full)/$GATE_SPEEDUP_FACTOR=$(full.reload_ns / GATE_SPEEDUP_FACTOR)")
        passed = false
    end

    if !passed
        println(stderr, "bench_reload: one or more hard gates FAILED")
        exit(1)
    end

    println("All gates passed.")
    return nothing
end

main()

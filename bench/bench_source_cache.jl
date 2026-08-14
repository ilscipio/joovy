# bench/bench_source_cache.jl
#
# Benchmark for SourceProvider (src/SourceProvider.jl): the path-keyed cache
# that lets the IDE push editor-buffer content ahead of a reload, instead of
# `joovy/reload` re-reading the file from disk.
#
# Two FRESH `julia` child sessions each:
#   1. write a single-definition file to disk and load it via
#      `joovy_hot_reload` (this establishes a real backedge from the warm-up
#      call below, so later redefinitions have something to invalidate --
#      same rationale as bench_reload.jl).
#   2. run PRIME_ITERS unmeasured edit+reload cycles to get past first-call
#      JIT compilation of the reload/SourceProvider code paths themselves.
#   3. run K_TRIALS MEASURED edit+reload cycles:
#        - "cache" child:  push the edited body via `source_push!` (content
#          differs from what's on disk -- the on-disk file is NEVER
#          rewritten after step 1), then call `joovy_hot_reload`. Every read
#          inside that reload must be served from the SourceProvider cache.
#        - "disk" child:   write the edited body straight to disk (the
#          SourceProvider cache is NEVER touched), then call
#          `joovy_hot_reload`. This is exactly today's pre-SourceProvider
#          code path (empty cache = byte-identical behavior).
#   4. report min/median reload_ns for both, plus `source_stats().disk_reads`
#      deltas summed across all K_TRIALS.
#
# Gates (hard -- exit(1) on failure):
#   - correctness: the "cache" child's final compiled function reflects the
#     LAST PUSHED body, not the (never-rewritten, and therefore different)
#     on-disk body -- i.e. SourceProvider content, not disk content, is what
#     actually got compiled.
#   - no-regression: min(reload_ns, cache) <= min(reload_ns, disk).
#
# This script is itself run as a child by bench/run_benchmarks.jl -- per
# run_bench_child's contract, ONLY `__JOOVY_BENCH__` marker lines go to
# stdout; diagnostics (e.g. gate failures) go to stderr.
#
# Usage:
#   julia bench/bench_source_cache.jl

include(joinpath(@__DIR__, "common.jl"))

const JOOVY_ROOT = dirname(@__DIR__)

# --- Hard gate thresholds / trial counts -----------------------------------
const PRIME_ITERS = 5    # unmeasured edit+reload cycles before timing starts
const K_TRIALS = 25      # reload measurements per child (MINIMUM is gated)

# reload_ns is gated as the MINIMUM across K_TRIALS repeated edit+reload
# cycles, not the mean/median: OS scheduling jitter, GC pauses, and
# antivirus/filesystem interference can only ADD latency to a given sample,
# never subtract it, so the minimum across enough samples is the standard
# robust estimator of "true" achievable cost (same rationale
# BenchmarkTools.jl uses for its default `minimum` timing, and the same
# convention bench_reload.jl uses).

const _CHILD_PREFIX = "__SOURCE_CACHE_CHILD__ "

# ===================================================================
# Synthetic workload: one definition, body varies by an additive offset.
# ===================================================================

gen_def(offset::Int) = "bench_source_cache_fn(x) = x + $offset\n"

const ORIGINAL_OFFSET = 1
const PRIME_OFFSET_BASE = 100
const EDIT_OFFSET_BASE = 1000

# ===================================================================
# Child driver
# ===================================================================

function write_child_driver(driver_path::String, bench_path::String, mode::String)
    mode in ("cache", "disk") || error("mode must be \"cache\" or \"disk\"")

    lines = String[]
    push!(lines, "using Joovy")
    push!(lines, "")
    push!(lines, "write($(repr(bench_path)), $(repr(gen_def(ORIGINAL_OFFSET))))")
    push!(lines, "joovy_hot_reload($(repr(bench_path)))")
    # Warm-up: call the function once so Julia actually specializes/compiles
    # it and establishes a real backedge -- this is what makes redefining a
    # def (even to the same body) expensive, and matters equally to both
    # modes since only the SOURCE-READING half of reload differs between them.
    push!(lines, "Base.invokelatest(getfield(Main, :bench_source_cache_fn), 1)")
    push!(lines, "")

    # Unmeasured priming cycles.
    push!(lines, "version = 1")
    for i in 1:PRIME_ITERS
        body = gen_def(PRIME_OFFSET_BASE + i)
        push!(lines, "version += 1")
        if mode == "cache"
            push!(lines, "source_push!($(repr(bench_path)), $(repr(body)), version)")
        else
            push!(lines, "write($(repr(bench_path)), $(repr(body)))")
        end
        push!(lines, "joovy_hot_reload($(repr(bench_path)))")
    end
    push!(lines, "GC.gc()")
    push!(lines, "")

    # Measured trials.
    push!(lines, "reload_ns_all = Float64[]")
    push!(lines, "disk_reads_total = 0")
    for i in 1:K_TRIALS
        body = gen_def(EDIT_OFFSET_BASE + i)
        push!(lines, "version += 1")
        if mode == "cache"
            push!(lines, "source_push!($(repr(bench_path)), $(repr(body)), version)")
        else
            push!(lines, "write($(repr(bench_path)), $(repr(body)))")
        end
        # GC disabled only around the measured call itself, so a GC pause
        # landing in this specific window can't inflate this specific sample.
        push!(lines, "before_stats = source_stats()")
        push!(lines, "GC.enable(false)")
        push!(lines, "t0 = time_ns()")
        push!(lines, "joovy_hot_reload($(repr(bench_path)))")
        push!(lines, "dt = time_ns() - t0")
        push!(lines, "GC.enable(true)")
        push!(lines, "after_stats = source_stats()")
        push!(lines, "push!(reload_ns_all, dt)")
        push!(lines, "global disk_reads_total += after_stats.disk_reads - before_stats.disk_reads")
    end
    push!(lines, "")
    push!(lines, "for v in reload_ns_all")
    push!(lines, "    println($(repr(_CHILD_PREFIX * "reload_ns=")), v)")
    push!(lines, "end")
    push!(lines, "println($(repr(_CHILD_PREFIX * "disk_reads_total=")), disk_reads_total)")
    push!(lines, "final_value = Base.invokelatest(getfield(Main, :bench_source_cache_fn), 1)")
    push!(lines, "println($(repr(_CHILD_PREFIX * "final_value=")), final_value)")

    write(driver_path, join(lines, "\n") * "\n")
    return nothing
end

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

function scrape_child_one(output::AbstractString, key::AbstractString)::Union{Float64,Nothing}
    vals = scrape_child_all(output, key)
    isempty(vals) && return nothing
    return vals[end]
end

function run_one(mode::String)
    dir = mktempdir(; prefix="joovy_bench_source_cache_")
    bench_path = joinpath(dir, "bench_defs.jl")
    driver_path = joinpath(dir, "_driver.jl")
    write_child_driver(driver_path, bench_path, mode)

    cmd = bench_julia_cmd(driver_path; project=JOOVY_ROOT)
    out, ok, elapsed = run_bench_child(cmd)
    ok || error("bench_source_cache: child (mode=$mode) failed after $(round(elapsed, digits=1))s:\n$out")

    reload_ns_all = scrape_child_all(out, "reload_ns")
    disk_reads_total = scrape_child_one(out, "disk_reads_total")
    final_value = scrape_child_one(out, "final_value")
    if isempty(reload_ns_all) || disk_reads_total === nothing || final_value === nothing
        error("bench_source_cache: child (mode=$mode) missing marker(s):\n$out")
    end

    return (
        reload_ns = minimum(reload_ns_all),
        reload_ns_median = _median(reload_ns_all),
        disk_reads_total = Int(round(disk_reads_total)),
        final_value = final_value,
    )
end

# ===================================================================
# main
# ===================================================================

function main()
    println("Joovy SourceProvider cache benchmark -- trials=$K_TRIALS (+$PRIME_ITERS unmeasured priming)")
    println("=" ^ 70)

    println("  RUN   mode=cache")
    cache = run_one("cache")
    println("  RUN   mode=disk")
    disk = run_one("disk")

    speedup_ratio = cache.reload_ns > 0 ? disk.reload_ns / cache.reload_ns : Inf
    ns_delta = disk.reload_ns - cache.reload_ns
    disk_reads_eliminated = disk.disk_reads_total - cache.disk_reads_total

    bench_line(stdout, "source_cache", "reload_ns_cache_min", round(cache.reload_ns, digits=1), "ns")
    bench_line(stdout, "source_cache", "reload_ns_disk_min", round(disk.reload_ns, digits=1), "ns")
    bench_line(stdout, "source_cache", "reload_ns_cache_median", round(cache.reload_ns_median, digits=1), "ns")
    bench_line(stdout, "source_cache", "reload_ns_disk_median", round(disk.reload_ns_median, digits=1), "ns")
    bench_line(stdout, "source_cache", "reload_ns_delta", round(ns_delta, digits=1), "ns")
    bench_line(stdout, "source_cache", "reload_speedup_ratio", round(speedup_ratio, digits=2), "x")
    bench_line(stdout, "source_cache", "disk_reads_cache_total", cache.disk_reads_total, "count")
    bench_line(stdout, "source_cache", "disk_reads_disk_total", disk.disk_reads_total, "count")
    bench_line(stdout, "source_cache", "disk_reads_eliminated", disk_reads_eliminated, "count")

    println("=" ^ 70)
    println("  reload_ns (min of $K_TRIALS):    cache=$(cache.reload_ns)  disk=$(disk.reload_ns)  speedup=$(round(speedup_ratio, digits=2))x  delta=$(round(ns_delta, digits=1))ns")
    println("  reload_ns (median of $K_TRIALS):  cache=$(cache.reload_ns_median)  disk=$(disk.reload_ns_median)")
    println("  disk_reads (sum of $K_TRIALS):    cache=$(cache.disk_reads_total)  disk=$(disk.disk_reads_total)  eliminated=$(disk_reads_eliminated)")
    println("  final_value:                      cache=$(cache.final_value)  disk=$(disk.final_value)")

    passed = true

    # Correctness gate: the on-disk file in "cache" mode is NEVER rewritten
    # past its ORIGINAL body (offset=$ORIGINAL_OFFSET), so if the reload had
    # actually read from disk, final_value would equal 1 + $ORIGINAL_OFFSET.
    # The pushed content (offset=$(EDIT_OFFSET_BASE + K_TRIALS)) must be what
    # actually got compiled instead.
    expected_cache_value = 1 + (EDIT_OFFSET_BASE + K_TRIALS)
    disk_only_value = 1 + ORIGINAL_OFFSET
    if cache.final_value != expected_cache_value
        println(stderr, "GATE FAIL: correctness -- cache-mode final_value=$(cache.final_value), expected $expected_cache_value (pushed content)")
        passed = false
    end
    if cache.final_value == disk_only_value
        println(stderr, "GATE FAIL: correctness -- cache-mode final_value matches the UNCHANGED on-disk content ($disk_only_value); reload did not use the pushed content")
        passed = false
    end

    # No-regression gate.
    if !(cache.reload_ns <= disk.reload_ns)
        println(stderr, "GATE FAIL: reload_ns(cache)=$(cache.reload_ns) not <= reload_ns(disk)=$(disk.reload_ns)")
        passed = false
    end

    if !passed
        println(stderr, "bench_source_cache: one or more hard gates FAILED")
        exit(1)
    end

    println("All gates passed.")
    return nothing
end

main()

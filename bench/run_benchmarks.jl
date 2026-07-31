# bench/run_benchmarks.jl
#
# Orchestrates the Joovy benchmark suite: runs each bench_*.jl script (listed
# in BENCH_SCRIPTS) as an INDEPENDENT SUBPROCESS, saves its raw stdout, and
# folds its __JOOVY_BENCH__ marker lines into one combined markdown table.
#
# A missing bench script is warned about and skipped -- this lets the
# harness run standalone before every bench_*.jl script exists (some are
# written by other, parallel work packages).
#
# Usage:
#   julia bench/run_benchmarks.jl [--label <name>] [other flags...]
#
# `--label` (default: current timestamp, yyyymmdd-HHMMSS) names the output
# files. Every OTHER flag/arg is forwarded verbatim to each child script
# (e.g. `--sessions 20`, `--heavy`).

using Dates

include(joinpath(@__DIR__, "common.jl"))

const BENCH_SCRIPTS = ["bench_warmup.jl", "bench_reload.jl", "bench_speculative.jl"]
const RESULTS_DIR = joinpath(@__DIR__, "results")

default_label() = Dates.format(now(), "yyyymmdd-HHMMSS")

# Split ARGS into (label, forward): `--label <value>` is consumed here,
# everything else is forwarded verbatim to each child script.
function split_args(args::Vector{String})
    label = getopt(args, "--label", default_label())
    forward = String[]
    i = 1
    while i <= length(args)
        if args[i] == "--label"
            i += 2
            continue
        end
        push!(forward, args[i])
        i += 1
    end
    return label, forward
end

function main()
    label, forward = split_args(copy(ARGS))
    mkpath(RESULTS_DIR)

    println("Joovy benchmark run -- label: $label")
    isempty(forward) || println("Forwarding to each child: $(join(forward, " "))")
    println("=" ^ 70)

    rows = Tuple{String,String,String,String}[]  # (bench, metric, value, unit)
    any_failed = false

    for script in BENCH_SCRIPTS
        script_path = joinpath(@__DIR__, script)
        if !isfile(script_path)
            println("  SKIP  $script (not found -- not written yet)")
            @warn "bench script not found, skipping" script = script_path
            continue
        end

        println("  RUN   $script")
        cmd = bench_julia_cmd(script_path; args=forward)
        out, ok, elapsed = run_bench_child(cmd)

        log_path = joinpath(RESULTS_DIR, "$(label)_$(script).log")
        write(log_path, out)

        markers = parse_bench_markers(out)

        if !ok || isempty(markers)
            any_failed = true
            reason = !ok ? "nonzero exit" : "no markers"
            println("  FAIL  $script ($reason, $(round(elapsed, digits=1))s) -> $log_path")
            push!(rows, (script, "FAILED", reason, ""))
            continue
        end

        println("  OK    $script ($(round(elapsed, digits=1))s) -> $log_path")
        for m in markers
            bench = get(m, "name", script)
            metric = get(m, "metric", "?")
            value = get(m, "value", "?")
            unit = get(m, "unit", "")
            push!(rows, (bench, metric, value, unit))
        end
    end

    md_path = joinpath(RESULTS_DIR, "$label.md")
    open(md_path, "w") do io
        println(io, "# Joovy benchmark results -- $label")
        println(io)
        println(io, "| bench | metric | value | unit |")
        println(io, "|---|---|---|---|")
        for (bench, metric, value, unit) in rows
            println(io, "| $bench | $metric | $value | $unit |")
        end
    end

    println("=" ^ 70)
    println("Results: $md_path")
    any_failed && println("One or more bench scripts FAILED -- see per-script logs above.")
    return nothing
end

main()

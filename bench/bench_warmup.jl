# bench/bench_warmup.jl
#
# Cross-session Time-To-First-X (TTFX) benchmark for the EXISTING warmup
# pipeline in src/Warmup.jl (`warmup_generate` + `warmup_build` -- read their
# docstrings there for the full contract and the `__JOOVY_WARMUP_PKG__`
# markers they print). Measures a cold "using X; <call>" workload against the
# SAME workload after Joovy has generated + built a `JoovyWarmup` package
# from `--trace-compile` output, and reports the improvement.
#
# Uses the REAL ambient depot (no JULIA_DEPOT_PATH override) -- this measures
# against the user's actual environment, the way an IDE would encounter it.
# Each invocation gets a FRESH temp trace_dir (via mktempdir()).
#
# Phases:
#   P0 (unmeasured, must fully complete before P1): ensure the fixture
#       project (bench/.fixture_dataframes[/heavy], gitignored) is
#       instantiated + precompiled. Skipped entirely once cached.
#   P1: `--sessions` (default 3) cold child sessions of the RAW workload,
#       each with `--trace-compile=<trace_dir>/trace-<i>.jl`.
#       baseline_ms = median of the inner `@elapsed` (ms).
#   P2: once, `using Joovy; warmup_generate(...); warmup_build(...)` against
#       ALL accumulated traces. Scrapes `statements=`/`elapsed=` from
#       Warmup's own `__JOOVY_WARMUP_PKG__` markers and re-emits them as
#       __JOOVY_BENCH__ build_cost_ms / statement_count.
#   P3: 3 (fixed) cold child sessions of `using JoovyWarmup` then the SAME
#       workload (identical source text to P1). warm_ms = median.
#
# IMPORTANT correctness detail: on Julia 1.12, --trace-compile output may
# carry `#= <n> ms =#` timing-comment prefixes; Warmup.jl's own sanitizer
# handles that. This script never pre-processes trace files itself -- it
# only counts raw lines (trace_line_count) and hands the directory to
# `warmup_generate` untouched.
#
# Usage:
#   julia bench/bench_warmup.jl [--label <name>] [--sessions N] [--heavy]

include(joinpath(@__DIR__, "common.jl"))

const JOOVY_ROOT = dirname(@__DIR__)

# ===================================================================
# Fixture project (P0)
# ===================================================================

fixture_dir_for(heavy::Bool) =
    heavy ? joinpath(@__DIR__, ".fixture_dataframes", "heavy") : joinpath(@__DIR__, ".fixture_dataframes")

# Ensure the fixture project at `fixture_dir` has `dep` instantiated and
# precompiled. Unmeasured setup cost -- skipped entirely once a Manifest.toml
# is already present (cached fixture across repeated bench runs).
function ensure_fixture!(fixture_dir::String, dep::String)
    mkpath(fixture_dir)
    manifest = joinpath(fixture_dir, "Manifest.toml")
    if isfile(manifest)
        println("  [P0] fixture already instantiated ($dep) -- skipping (cached)")
        return nothing
    end

    println("  [P0] instantiating fixture project ($dep) -- unmeasured, one-time...")
    project_toml = joinpath(fixture_dir, "Project.toml")
    isfile(project_toml) || write(project_toml, "")

    setup_script = joinpath(fixture_dir, "_setup.jl")
    write(setup_script, """
    import Pkg
    Pkg.activate($(repr(fixture_dir)); io=devnull)
    Pkg.add($(repr(dep)); io=devnull)
    Pkg.instantiate(io=devnull)
    Pkg.precompile(io=devnull)
    println("SETUP_OK")
    """)
    cmd = bench_julia_cmd(setup_script)
    out, ok, elapsed = run_bench_child(cmd)
    (ok && occursin("SETUP_OK", out)) || error("bench_warmup: fixture setup failed:\n$out")
    println("  [P0] done ($(round(elapsed, digits=1))s)")
    return nothing
end

# ===================================================================
# Workload (identical source text used in P1 and P3)
# ===================================================================

function workload_code(heavy::Bool)
    return heavy ?
           """
               using Plots
               p = plot(1:10, rand(10))
               savefig(p, joinpath(mktempdir(), "bench_plot.png"))
           """ :
           """
               using DataFrames
               describe(DataFrame(a=1:10))
           """
end

function write_driver(path::String, code::String; prelude::String="")
    write(path, """
    $prelude
    t = @elapsed begin
    $code
    end
    println("__BENCH_ELAPSED__ ", t)
    """)
end

const _ELAPSED_PREFIX = "__BENCH_ELAPSED__ "

function scrape_elapsed_ms(output::AbstractString)::Union{Nothing,Float64}
    for line in split(output, '\n')
        startswith(line, _ELAPSED_PREFIX) || continue
        return parse(Float64, strip(line[length(_ELAPSED_PREFIX)+1:end])) * 1000
    end
    return nothing
end

# Scrape the value of `key=` from the first line starting with `line_prefix`.
function scrape_marker(output::AbstractString, line_prefix::AbstractString, key::AbstractString)
    re = Regex(key * "=(\\S+)")
    for line in split(output, '\n')
        startswith(line, line_prefix) || continue
        m = match(re, line)
        m === nothing || return m.captures[1]
    end
    return nothing
end

# ===================================================================
# Cold session runner (shared by P1 and P3)
# ===================================================================

# Run `n` cold `julia --project=<project> <driver>` sessions. When
# `trace_dir` is not `nothing`, each session additionally gets
# `--trace-compile=<trace_dir>/trace-<i>.jl` (a julia-level flag that must
# precede the script, hence built by hand rather than via bench_julia_cmd).
# Returns (inner_ms, process_ms) -- the scraped in-child @elapsed times, and
# the external wall-clock time of the whole child process, both in ms.
function run_cold_sessions(n::Int, project::String, driver::String,
                            trace_dir::Union{Nothing,String})
    inner_ms = Float64[]
    process_ms = Float64[]
    julia = Base.julia_cmd()
    for i in 1:n
        cmd = trace_dir === nothing ?
            `$julia --startup-file=no --project=$project $driver` :
            `$julia --startup-file=no --project=$project --trace-compile=$(joinpath(trace_dir, "trace-$i.jl")) $driver`
        out, ok, elapsed = run_bench_child(cmd)
        ok || error("bench_warmup: cold session $i failed:\n$out")
        v = scrape_elapsed_ms(out)
        v === nothing && error("bench_warmup: cold session $i printed no $_ELAPSED_PREFIX marker:\n$out")
        push!(inner_ms, v)
        push!(process_ms, elapsed * 1000)
    end
    return inner_ms, process_ms
end

function count_trace_lines(trace_dir::String)::Int
    total = 0
    for f in readdir(trace_dir)
        (startswith(f, "trace-") && endswith(f, ".jl")) || continue
        total += length(readlines(joinpath(trace_dir, f)))
    end
    return total
end

# ===================================================================
# main
# ===================================================================

function main()
    args = copy(ARGS)
    sessions = parse(Int, getopt(args, "--sessions", "3"))
    heavy = hasflag(args, "--heavy")
    mode = heavy ? "heavy" : "normal"
    dep = heavy ? "Plots" : "DataFrames"

    fixture_dir = fixture_dir_for(heavy)
    ensure_fixture!(fixture_dir, dep)

    trace_dir = mktempdir(; prefix="joovy_bench_")
    println("Joovy warmup benchmark -- mode=$mode sessions=$sessions trace_dir=$trace_dir")
    println("=" ^ 70)

    code = workload_code(heavy)

    # --- P1: N cold baseline sessions, each tracing its own compiles ----
    p1_driver = joinpath(trace_dir, "_p1_driver.jl")
    write_driver(p1_driver, code)
    println("  [P1] running $sessions cold baseline session(s)...")
    baseline_inner, baseline_process = run_cold_sessions(sessions, fixture_dir, p1_driver, trace_dir)
    baseline_ms = _median(baseline_inner)
    baseline_process_ms = _median(baseline_process)
    println("  [P1] baseline_ms=$(round(baseline_ms, digits=1))")

    trace_line_count = count_trace_lines(trace_dir)

    # --- P2: once, generate + build the JoovyWarmup package ------------
    println("  [P2] generating + building JoovyWarmup package...")
    build_script = joinpath(trace_dir, "_p2_build.jl")
    write(build_script, """
    using Joovy
    pkg_dir = warmup_generate($(repr(fixture_dir)), $(repr(trace_dir)))
    pkg_dir === nothing && error("warmup_generate returned nothing")
    ok = warmup_build($(repr(fixture_dir)), pkg_dir)
    ok || error("warmup_build failed")
    """)
    build_cmd = bench_julia_cmd(build_script; project=JOOVY_ROOT)
    build_out, build_ok, build_process_elapsed = run_bench_child(build_cmd)
    build_ok || error("bench_warmup: P2 build failed:\n$build_out")

    statement_count_str = scrape_marker(build_out, "__JOOVY_WARMUP_PKG__ status=generated", "statements")
    build_elapsed_str = scrape_marker(build_out, "__JOOVY_WARMUP_PKG__ status=built", "elapsed")
    statement_count_str === nothing && error("bench_warmup: no statements= marker in P2 output:\n$build_out")
    build_elapsed_str === nothing && error("bench_warmup: no built elapsed= marker in P2 output:\n$build_out")
    statement_count = parse(Int, statement_count_str)
    build_cost_ms = parse(Float64, build_elapsed_str) * 1000
    println("  [P2] statements=$statement_count build_cost_ms=$(round(build_cost_ms, digits=1))")

    # --- P3: 3 (fixed) cold sessions against the built JoovyWarmup pkg --
    build_env = joinpath(trace_dir, "_build_env")
    p3_driver = joinpath(trace_dir, "_p3_driver.jl")
    write_driver(p3_driver, code; prelude="using JoovyWarmup")
    println("  [P3] running 3 cold warm session(s)...")
    warm_inner, warm_process = run_cold_sessions(3, build_env, p3_driver, nothing)
    warm_ms = _median(warm_inner)
    warm_process_ms = _median(warm_process)
    println("  [P3] warm_ms=$(round(warm_ms, digits=1))")

    improvement_pct = baseline_ms > 0 ? (baseline_ms - warm_ms) / baseline_ms * 100 : 0.0

    println("=" ^ 70)
    bench_line(stdout, "warmup", "baseline_ms", round(baseline_ms, digits=2), "ms"; mode=mode)
    bench_line(stdout, "warmup", "warm_ms", round(warm_ms, digits=2), "ms"; mode=mode)
    bench_line(stdout, "warmup", "improvement_pct", round(improvement_pct, digits=2), "pct"; mode=mode)
    bench_line(stdout, "warmup", "build_cost_ms", round(build_cost_ms, digits=2), "ms"; mode=mode)
    bench_line(stdout, "warmup", "statement_count", statement_count, "count"; mode=mode)
    bench_line(stdout, "warmup", "trace_line_count", trace_line_count, "count"; mode=mode)
    bench_line(stdout, "warmup", "baseline_process_ms", round(baseline_process_ms, digits=2), "ms"; mode=mode)
    bench_line(stdout, "warmup", "warm_process_ms", round(warm_process_ms, digits=2), "ms"; mode=mode)
    bench_line(stdout, "warmup", "build_process_ms", round(build_process_elapsed * 1000, digits=2), "ms"; mode=mode)
    return nothing
end

main()

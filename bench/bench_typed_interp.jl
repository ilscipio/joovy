# bench/bench_typed_interp.jl
#
# Benchmark for the experimental typed-IR interpreter (src/TypedInterp.jl): is
# "tier 0.5 -- inference cost without LLVM cost" actually faster than tier 0,
# and what does it cost on the first call?
#
# 3 fixtures x 3 modes, one FRESH `julia` child per cell (9 children), so no
# cell sees another cell's warmed caches:
#
#   collection -- iterate a Vector{Float64}, branch per element, call `abs`
#                 and `sqrt`. The workload the design predicts TypedInterp
#                 wins: tier 0 pays dynamic dispatch per surface operation,
#                 while the typed IR has already collapsed them to `:invoke`s.
#   dispatch   -- a 3-deep chain of tiny user functions per iteration. Under
#                 TypedInterp every callee ESCAPES TO NATIVE through
#                 `jl_invoke`; under tier 0 the callees stay interpreted too.
#   loop       -- a pure scalar recurrence with no collection and no user
#                 callees. The accepted NON-WIN: there is nothing for the
#                 typed IR to collapse, so this fixture only guards against a
#                 regression, it is not expected to beat tier 0.
#
#   tier0  -- fixture defined in a `compile=min optimize=0 max_methods=1`
#             module and called normally (Julia's own AST interpreter).
#   interp -- fixture defined in an ordinary module, never called natively,
#             wrapped in a `TypedInterpCallable` and interpreted from typed IR.
#   native -- fixture defined in an ordinary module and called directly.
#
# METHODOLOGY -- every timed call happens at TOP LEVEL, around a
# `Base.invokelatest`. Inside a compiled function LLVM common-subexpression-
# eliminates the two `time_ns()` calls that `@elapsed` expands to and reports
# 0.0; that silently faked two runs while this design was being validated.
# `Base.invokelatest` is opaque to the optimizer, so nothing can be hoisted
# across it. Reported per-cell timing is the MINIMUM of TRIALS repetitions
# (minimum, not mean: it is the measurement least polluted by GC and by other
# processes on the machine).
#
# Only the harness writes `__JOOVY_BENCH__` markers, and only to stdout.
# Children speak a private `RESULT key=value` protocol; diagnostics and gate
# failures go to stderr.
#
# Usage:
#   julia bench/bench_typed_interp.jl [--trials N] [--strict]
#   julia bench/bench_typed_interp.jl --child <fixture> <mode>   (internal)
#
# `--strict` makes the PERFORMANCE gates fatal as well. By default only the
# CORRECTNESS gates (identical results across modes, zero fallbacks, zero
# interpreter errors) exit 1, because the perf ratios move with machine load
# and the definitive ratio run is meant to happen on a quiet machine -- a
# timing wobble on a busy CI box must not be reported as a broken interpreter.
# The thresholds themselves are the design's, unchanged, and every one of them
# is emitted as a `gate_*` marker whether it passes or fails.

include(joinpath(@__DIR__, "common.jl"))

const JOOVY_ROOT = dirname(@__DIR__)

# --- Workload sizes ---------------------------------------------------------
const N_ELEMS = 2000        # collection: vector length
const N_ITERS = 2000        # dispatch / loop: iteration count
const TRIALS_DEFAULT = 15   # timed repetitions per cell (minimum is reported)

# --- Hard gate thresholds (design section 6; NOT tuned to the measurements) --
const GATE_COLLECTION_MAX_RATIO = 0.85   # interp <= 0.85 x tier0
const GATE_DISPATCH_MAX_RATIO   = 0.25   # interp <= 0.25 x tier0
const GATE_LOOP_MAX_RATIO       = 1.60   # interp <= 1.60 x tier0 (regression guard)

const FIXTURES = ["collection", "dispatch", "loop"]
const MODES = ["tier0", "interp", "native"]

# Fixture bodies as SOURCE, because `tier0` has to evaluate them inside a
# module carrying `@compiler_options compile=min`, which is a property of the
# module the method is defined in, not of the call site.
const FIXTURE_SRC = Dict(
    "collection" => """
        function fx(v::Vector{Float64})
            s = 0.0
            n = 0
            for x in v
                y = abs(x)
                if y > 0.5
                    s += sqrt(y)
                    n += 1
                else
                    s -= y * y
                end
            end
            return s + n
        end
    """,
    "dispatch" => """
        step_a(x::Float64) = x * 1.5 + 1.0
        step_b(x::Float64) = x / 3.0 - 0.25
        step_c(x::Float64) = x * x * 0.001
        function fx(n::Int)
            s = 0.0
            for i in 1:n
                s += step_c(step_b(step_a(Float64(i))))
            end
            return s
        end
    """,
    "loop" => """
        function fx(n::Int)
            s = 0.0
            x = 1.0
            for i in 1:n
                x = x * 1.0000001 + 0.5
                s += x
            end
            return s
        end
    """,
)

fixture_arg(fixture) = fixture == "collection" ?
    Float64[i / 7 - 1.0 for i in 1:N_ELEMS] : N_ITERS

# Joovy is loaded ONLY in a child: the harness itself is launched by
# run_benchmarks.jl without `--project`, so it must not depend on Joovy being
# resolvable, while every child is spawned with `project = JOOVY_ROOT`.
if "--child" in ARGS
    @eval using Joovy
end

# Throwaway signature used to prime Julia's inference pipeline. Defined at TOP
# LEVEL so its world age is older than the priming call, which lets the
# interpreter's `jl_invoke` reach it without an `invokelatest` round trip.
_bench_prime(a::Int, b::Int) = a < b ? a * 2 + b : b - a

# ===================================================================
# Child: one (fixture, mode) cell in a fresh process
# ===================================================================

function run_child(fixture::String, mode::String, trials::Int)
    src = FIXTURE_SRC[fixture]
    arg = fixture_arg(fixture)

    fixmod = Module(Symbol("FixMod_", fixture, "_", mode))
    if mode == "tier0"
        Core.eval(fixmod, :(Base.Experimental.@compiler_options compile=min optimize=0 max_methods=1))
    end
    Core.eval(fixmod, Meta.parse("begin\n$src\nend"))
    raw = Core.eval(fixmod, :fx)

    prime_ms = 0.0
    callable = raw
    if mode == "interp"
        # Prime Julia's inference pipeline on a throwaway signature. The FIRST
        # `code_typed` through a custom NativeInterpreter in a process costs
        # ~130-210 ms of one-time warmup that cannot be cached into a package
        # image (probe O5b); it belongs to the session, not to this fixture, so
        # it is measured and reported separately rather than folded into the
        # fixture's first call. `first_call_ms` below reports the UNPRIMED cost
        # (prime + first call), which is what the very first user call pays.
        joovy_typed_interp!(true)
        local p0 = time_ns()
        TypedInterpCallable(_bench_prime)(3, 4)
        prime_ms = (time_ns() - p0) / 1e6
        callable = TypedInterpCallable(raw)
    end

    # --- first call, timed at top level ---
    t0 = time_ns()
    first_value = Base.invokelatest(callable, arg)
    t1 = time_ns()
    first_call_ms = (t1 - t0) / 1e6

    # --- steady state ---
    times = Float64[]
    vals = Any[]
    for _ in 1:trials
        s0 = time_ns()
        v = Base.invokelatest(callable, arg)
        s1 = time_ns()
        push!(times, (s1 - s0) / 1e6)
        push!(vals, v)
    end

    all(==(first_value), vals) ||
        println(stderr, "bench_typed_interp: child $fixture/$mode produced unstable results")

    println("RESULT fixture=$fixture")
    println("RESULT mode=$mode")
    println("RESULT value=$(first_value)")
    println("RESULT min_ms=$(minimum(times))")
    println("RESULT median_ms=$(_median(times))")
    # `first_call_primed_ms` is this fixture's own first call; `first_call_ms` adds the
    # session-wide pipeline warmup, so it is comparable with the tier0/native children,
    # which pay all of their cold cost inside their own first call.
    println("RESULT first_call_primed_ms=$(first_call_ms)")
    println("RESULT prime_ms=$(prime_ms)")
    println("RESULT first_call_ms=$(first_call_ms + prime_ms)")

    if mode == "interp"
        st = typed_interp_stats()
        println("RESULT hits=$(st.hits)")
        println("RESULT misses=$(st.misses)")
        println("RESULT fallbacks=$(st.fallbacks)")
        println("RESULT reinfers=$(st.reinfers)")
        println("RESULT errors=$(st.errors)")
        println("RESULT entries=$(st.entries)")
    else
        for k in ("hits", "misses", "fallbacks", "reinfers", "errors", "entries")
            println("RESULT $k=0")
        end
    end
    return nothing
end

function parse_child(out::AbstractString)
    d = Dict{String,String}()
    for line in split(out, '\n')
        startswith(line, "RESULT ") || continue
        tok = strip(line[8:end])
        i = findfirst('=', tok)
        i === nothing && continue
        d[tok[1:i-1]] = tok[i+1:end]
    end
    return d
end

# ===================================================================
# Harness
# ===================================================================

function main(args::Vector{String})
    trials = parse(Int, getopt(args, "--trials", string(TRIALS_DEFAULT)))
    strict = hasflag(args, "--strict")

    cells = Dict{Tuple{String,String},Dict{String,String}}()
    failed_cells = String[]

    for fixture in FIXTURES, mode in MODES
        cmd = bench_julia_cmd(@__FILE__; project = JOOVY_ROOT,
                              args = ["--child", fixture, mode, "--trials", string(trials)])
        out, ok, elapsed = run_bench_child(cmd)
        d = parse_child(out)
        if !ok || isempty(d)
            push!(failed_cells, "$fixture/$mode")
            println(stderr, "bench_typed_interp: child $fixture/$mode FAILED " *
                            "(ok=$ok, $(round(elapsed, digits=1))s)")
            println(stderr, out)
            continue
        end
        cells[(fixture, mode)] = d
        println(stderr, "  $fixture/$mode  min=$(d["min_ms"]) ms  " *
                        "first=$(d["first_call_ms"]) ms  ($(round(elapsed, digits=1))s)")
    end

    if !isempty(failed_cells)
        println(stderr, "bench_typed_interp: missing cells: $(join(failed_cells, ", "))")
        exit(1)
    end

    getf(fixture, mode, key) = parse(Float64, cells[(fixture, mode)][key])
    geti(fixture, mode, key) = parse(Int, cells[(fixture, mode)][key])

    # --- results must agree across all three modes ---
    results_match = true
    for fixture in FIXTURES
        vals = [parse(Float64, cells[(fixture, m)]["value"]) for m in MODES]
        agree = all(v -> isapprox(v, vals[1]; atol = 1e-10, rtol = 1e-12), vals)
        agree || println(stderr, "GATE FAIL: $fixture results differ across modes: $vals")
        results_match &= agree
    end

    total_fallbacks = sum(geti(f, "interp", "fallbacks") for f in FIXTURES)
    total_errors = sum(geti(f, "interp", "errors") for f in FIXTURES)
    total_hits = sum(geti(f, "interp", "hits") for f in FIXTURES)
    fallback_rate = total_hits + total_fallbacks == 0 ? 1.0 :
                    total_fallbacks / (total_hits + total_fallbacks)

    # --- markers: the 3x3 table, then latencies, then counters ---
    for fixture in FIXTURES, mode in MODES
        bench_line(stdout, "typed_interp", "$(fixture)_$(mode)_min_ms",
                   round(getf(fixture, mode, "min_ms"); digits = 4), "ms")
    end
    for fixture in FIXTURES
        ratio_t0 = getf(fixture, "interp", "min_ms") / getf(fixture, "tier0", "min_ms")
        ratio_nat = getf(fixture, "interp", "min_ms") / getf(fixture, "native", "min_ms")
        bench_line(stdout, "typed_interp", "$(fixture)_ratio_interp_over_tier0",
                   round(ratio_t0; digits = 3), "x")
        bench_line(stdout, "typed_interp", "$(fixture)_ratio_interp_over_native",
                   round(ratio_nat; digits = 3), "x")
    end
    for fixture in FIXTURES, mode in MODES
        bench_line(stdout, "typed_interp", "$(fixture)_$(mode)_first_call_ms",
                   round(getf(fixture, mode, "first_call_ms"); digits = 3), "ms")
    end
    for fixture in FIXTURES
        bench_line(stdout, "typed_interp", "$(fixture)_interp_prime_ms",
                   round(getf(fixture, "interp", "prime_ms"); digits = 3), "ms")
        bench_line(stdout, "typed_interp", "$(fixture)_interp_first_call_primed_ms",
                   round(getf(fixture, "interp", "first_call_primed_ms"); digits = 3), "ms")
    end
    bench_line(stdout, "typed_interp", "results_match", results_match, "bool")
    bench_line(stdout, "typed_interp", "interp_hits", total_hits, "count")
    bench_line(stdout, "typed_interp", "interp_fallbacks", total_fallbacks, "count")
    bench_line(stdout, "typed_interp", "interp_errors", total_errors, "count")
    bench_line(stdout, "typed_interp", "fallback_rate", round(fallback_rate; digits = 4), "ratio")
    bench_line(stdout, "typed_interp", "interp_reinfers",
               sum(geti(f, "interp", "reinfers") for f in FIXTURES), "count")

    # --- gates ---
    perf_gates = Tuple{String,Bool,String}[]
    for (fixture, limit) in (("collection", GATE_COLLECTION_MAX_RATIO),
                             ("dispatch", GATE_DISPATCH_MAX_RATIO),
                             ("loop", GATE_LOOP_MAX_RATIO))
        r = getf(fixture, "interp", "min_ms") / getf(fixture, "tier0", "min_ms")
        push!(perf_gates, ("$(fixture)_ratio_vs_tier0", r <= limit,
                           "$(round(r, digits=3)) <= $limit"))
    end
    for fixture in FIXTURES
        fi = getf(fixture, "interp", "first_call_ms")
        fn = getf(fixture, "native", "first_call_ms")
        push!(perf_gates, ("$(fixture)_first_call_vs_native", fi <= fn,
                           "$(round(fi, digits=3)) <= $(round(fn, digits=3))"))
    end

    correctness_gates = Tuple{String,Bool,String}[
        ("results_match", results_match, string(results_match)),
        ("fallback_rate_zero", total_fallbacks == 0, "fallbacks=$total_fallbacks"),
        ("interp_errors_zero", total_errors == 0, "errors=$total_errors"),
    ]

    for (name, pass, detail) in vcat(correctness_gates, perf_gates)
        bench_line(stdout, "typed_interp", "gate_$name", pass ? "pass" : "fail", "gate")
        pass || println(stderr, "GATE FAIL: $name ($detail)")
    end

    println()
    println("fixture      tier0_ms    interp_ms   native_ms   interp/tier0")
    println("-" ^ 62)
    for fixture in FIXTURES
        println(rpad(fixture, 13),
                rpad(round(getf(fixture, "tier0", "min_ms"); digits = 3), 12),
                rpad(round(getf(fixture, "interp", "min_ms"); digits = 3), 12),
                rpad(round(getf(fixture, "native", "min_ms"); digits = 3), 12),
                round(getf(fixture, "interp", "min_ms") / getf(fixture, "tier0", "min_ms");
                      digits = 3), "x")
    end
    println()

    correctness_ok = all(g -> g[2], correctness_gates)
    perf_ok = all(g -> g[2], perf_gates)

    if !correctness_ok
        println(stderr, "bench_typed_interp: a CORRECTNESS gate FAILED")
        exit(1)
    end
    if !perf_ok
        println(stderr, "bench_typed_interp: one or more PERFORMANCE gates failed " *
                        "(advisory without --strict; rerun on a quiet machine)")
        strict && exit(1)
    end
    perf_ok && println("All gates passed.")
    return nothing
end

let args = copy(ARGS)
    if hasflag(args, "--child")
        i = findfirst(==("--child"), args)
        trials = parse(Int, getopt(args, "--trials", string(TRIALS_DEFAULT)))
        run_child(String(args[i+1]), String(args[i+2]), trials)
    else
        main(args)
    end
end

# bench/common.jl
#
# Shared child-process + marker-parsing helpers for the Joovy benchmark
# harness. Modeled on examples/verify_preferences.jl's `run_child` (lines
# 22-44): every benchmark scenario runs in a FRESH `julia` subprocess, so
# results reflect a real cold (or warm) session rather than the harness's
# own already-warmed-up process.
#
# Stdlib only. Julia 1.9 compatible (no Statistics dep -- see `_median`).

# ===================================================================
# Child-process spawning
# ===================================================================

"""
    bench_julia_cmd(script; project=nothing, args=String[], env=Dict{String,String}()) -> Cmd

Build a `Cmd` that runs `script` in a fresh `julia --startup-file=no` child:

    <julia> --startup-file=no [--project=<project>] <script> <args...>

`env` entries are layered onto the child's environment via `addenv` (adds to
/overrides the parent's env; does not replace it).

Note: flags that must precede the script on the command line (e.g.
`--trace-compile=<file>`) are NOT expressible through this helper -- build
the `Cmd` by hand for those cases and pass it straight to
[`run_bench_child`](@ref), which accepts any `Cmd`.
"""
function bench_julia_cmd(script::AbstractString;
                          project::Union{Nothing,AbstractString}=nothing,
                          args::Vector{String}=String[],
                          env::Dict{String,String}=Dict{String,String}())
    base = Base.julia_cmd()
    cmd = project === nothing ?
        `$base --startup-file=no $script $args` :
        `$base --startup-file=no --project=$project $script $args`
    isempty(env) && return cmd
    return addenv(cmd, env)
end

"""
    run_bench_child(cmd::Cmd) -> (out::String, ok::Bool, elapsed::Float64)

Run `cmd` to completion: stdout is captured into a `String`, stderr is left
to pass through to the harness's own stderr (so child errors/warnings are
visible live rather than swallowed), and the whole run is timed with
`time()`. `ok` is `true` iff the child exited with status 0; a `Cmd` spawn
failure (e.g. executable not found) also yields `ok=false` rather than
throwing.
"""
function run_bench_child(cmd::Cmd)
    buf = IOBuffer()
    t0 = time()
    ok = try
        success(pipeline(cmd; stdout=buf, stderr=Base.stderr))
    catch
        false
    end
    elapsed = time() - t0
    out = String(take!(buf))
    return (out, ok, elapsed)
end

# ===================================================================
# __JOOVY_BENCH__ marker wire format
# ===================================================================

const _BENCH_MARKER_PREFIX = "__JOOVY_BENCH__ "

"""
    bench_line(io, name, metric, value, unit; kwargs...)

Print a single `__JOOVY_BENCH__` marker line:

    __JOOVY_BENCH__ name=<name> metric=<metric> value=<value> unit=<unit> [k=v ...]

This is the ONLY place in the benchmark harness that prints this marker --
every bench script should call this rather than hand-rolling the format, so
the wire format lives in exactly one place.
"""
function bench_line(io::IO, name, metric, value, unit; kwargs...)
    parts = ["__JOOVY_BENCH__", "name=$name", "metric=$metric", "value=$value", "unit=$unit"]
    for (k, v) in kwargs
        push!(parts, "$k=$v")
    end
    println(io, join(parts, " "))
end

"""
    parse_bench_markers(output::AbstractString) -> Vector{Dict{String,String}}

Scan `output` line by line for lines with the `__JOOVY_BENCH__ ` prefix
(exactly one trailing space), and parse the remainder as whitespace-separated
`key=value` tokens into a `Dict{String,String}`. Lines without the prefix,
and tokens without an `=`, are ignored. One `Dict` per matching line.
"""
function parse_bench_markers(output::AbstractString)::Vector{Dict{String,String}}
    markers = Dict{String,String}[]
    for line in split(output, '\n')
        startswith(line, _BENCH_MARKER_PREFIX) || continue
        rest = line[length(_BENCH_MARKER_PREFIX)+1:end]
        d = Dict{String,String}()
        for tok in split(rest)
            i = findfirst('=', tok)
            i === nothing && continue
            d[tok[1:i-1]] = tok[i+1:end]
        end
        push!(markers, d)
    end
    return markers
end

# ===================================================================
# Small numeric / CLI helpers
# ===================================================================

"""
    _median(xs) -> Float64

Hand-rolled median (no Statistics dependency): sorts a copy of `xs` and
returns the middle value, or the mean of the two middle values for an
even-length input.
"""
function _median(xs)
    isempty(xs) && throw(ArgumentError("_median: empty input"))
    s = sort(collect(xs))
    n = length(s)
    mid = (n + 1) ÷ 2
    return isodd(n) ? Float64(s[mid]) : (Float64(s[mid]) + Float64(s[mid+1])) / 2
end

"""
    getopt(args, flag, default) -> String

Look for `flag` (e.g. `"--label"`) in `args` and return the value in the
element right after it. Returns `default` if the flag is absent, or if it is
the last element (no following value).
"""
function getopt(args::Vector{String}, flag::AbstractString, default)
    i = findfirst(==(flag), args)
    (i === nothing || i == length(args)) && return default
    return args[i+1]
end

"""
    hasflag(args, flag) -> Bool

Return whether `flag` appears anywhere in `args`.
"""
hasflag(args::Vector{String}, flag::AbstractString) = flag in args

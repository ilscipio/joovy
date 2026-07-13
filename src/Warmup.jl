module Warmup

# Background depot-cache warming, and generation + build of a per-project
# "JoovyWarmup" package from `--trace-compile` output.
#
# An IDE spawns a DEDICATED subprocess per call to these functions and parses
# the printed `__JOOVY_*__` markers from stdout. Because each call owns the
# whole process, mutating global state (ENV, `Pkg.activate`, the active
# project) is safe here -- it never leaks into the user's REPL or another
# concurrent call.

import Pkg
import SHA

export joovy_warm, warmup_generate, warmup_build

# Fixed UUID for the generated JoovyWarmup package. Keeping it constant lets
# the IDE recognize/reuse a previously generated+built package across runs.
const _WARMUP_PKG_UUID = "7b1a2c3d-0000-4000-8000-1234567890ab"

const _RECOMPILE_COMMENT_RE = r"\)\s*#\s*recompile\s*$"
const _MODULE_REF_RE = r"[A-Za-z_][A-Za-z0-9_!]*(?=\.)"

# ===================================================================
# joovy_warm: background depot-cache warming
# ===================================================================

"""
    joovy_warm(packages; project=nothing, ntasks=.., cancel_file=nothing, io=stdout) -> Bool

Precompile `packages` (by name) one at a time into the active (or given)
project's depot cache, printing progress markers to `io` as it goes:

    __JOOVY_WARM__ pkg=<name> status=done|fail|skip [elapsed=<s>] [reason=<reason>]
    __JOOVY_WARM_ERR__ <compact error message>          # only on status=fail
    __JOOVY_WARM_DONE__ total=<n> warmed=<n> failed=<n>

Returns `true` iff no package failed (skips do not count as failures).
"""
function joovy_warm(packages::Vector{String};
                     project::Union{Nothing,String}=nothing,
                     ntasks::Integer=max(1, Sys.CPU_THREADS ÷ 2),
                     cancel_file::Union{Nothing,String}=nothing,
                     io::IO=stdout)
    if VERSION < v"1.10"
        println(io, "__JOOVY_WARM__ status=skip reason=julia_version")
        return false
    end

    ENV["JULIA_NUM_PRECOMPILE_TASKS"] = string(ntasks)

    project !== nothing && Pkg.activate(project; io=devnull)

    available = Set{String}(info.name for info in values(Pkg.dependencies()))

    warmed = 0
    failed = 0

    for (i, pkg) in enumerate(packages)
        if cancel_file !== nothing && isfile(cancel_file)
            for skipped in packages[i:end]
                println(io, "__JOOVY_WARM__ pkg=$skipped status=skip reason=cancelled")
            end
            break
        end

        if !(pkg in available)
            println(io, "__JOOVY_WARM__ pkg=$pkg status=skip reason=not_in_env")
            continue
        end

        t0 = time()
        try
            _pkg_precompile([pkg]; io=devnull)
            elapsed = round(time() - t0, digits=1)
            println(io, "__JOOVY_WARM__ pkg=$pkg status=done elapsed=$elapsed")
            warmed += 1
        catch e
            println(io, "__JOOVY_WARM_ERR__ $(_compact_error(e))")
            println(io, "__JOOVY_WARM__ pkg=$pkg status=fail")
            failed += 1
        end
    end

    println(io, "__JOOVY_WARM_DONE__ total=$(length(packages)) warmed=$warmed failed=$failed")
    return failed == 0
end

# ===================================================================
# warmup_generate: build a JoovyWarmup package source from trace-compile output
# ===================================================================

"""
    warmup_generate(project, trace_dir; name="JoovyWarmup") -> Union{Nothing,String}

Read every `trace-*.jl` file in `trace_dir` (as produced by
`julia --trace-compile=<file>`), sanitize the `precompile(...)` statements,
and write a standalone package (`Project.toml` + `src/<name>.jl`) under
`joinpath(trace_dir, name)` whose precompilation replays those statements.

Prints one of:

    __JOOVY_WARMUP_PKG__ status=skip reason=julia_version|no_statements
    __JOOVY_WARMUP_PKG__ status=generated statements=<n> deps=<n>

Returns the generated package directory on success, `nothing` otherwise.
"""
function warmup_generate(project::String, trace_dir::String; name::String="JoovyWarmup")
    if VERSION < v"1.10"
        println("__JOOVY_WARMUP_PKG__ status=skip reason=julia_version")
        return nothing
    end

    trace_files = sort(filter(f -> startswith(f, "trace-") && endswith(f, ".jl"),
                               readdir(trace_dir)))

    raw_lines = String[]
    for f in trace_files
        append!(raw_lines, readlines(joinpath(trace_dir, f)))
    end

    statements = _sanitize_trace_lines(raw_lines)

    if isempty(statements)
        println("__JOOVY_WARMUP_PKG__ status=skip reason=no_statements")
        return nothing
    end

    Pkg.activate(project; io=devnull)
    dep_uuids = Dict{String,Base.UUID}(info.name => uuid for (uuid, info) in Pkg.dependencies())

    referenced = Set{String}()
    for stmt in statements
        union!(referenced, _statement_modules(stmt))
    end
    referenced_deps = sort!(collect(intersect(referenced, keys(dep_uuids))))

    pkg_dir = joinpath(trace_dir, name)
    src_dir = joinpath(pkg_dir, "src")
    mkpath(src_dir)

    _write_warmup_project_toml(joinpath(pkg_dir, "Project.toml"), name, referenced_deps, dep_uuids)
    _write_warmup_src(joinpath(src_dir, "$name.jl"), name, referenced_deps, statements)

    println("__JOOVY_WARMUP_PKG__ status=generated statements=$(length(statements)) deps=$(length(referenced_deps))")
    return pkg_dir
end

# --- pure helpers (unit-testable) -----------------------------------------

"""
    _sanitize_trace_lines(lines) -> Vector{String}

Filter raw trace-compile lines down to `precompile(...)` statements: strip
trailing `) # recompile` comments (which would otherwise comment out the
`; catch; end` wrapper and break the generated module), drop any statement
that references `Main.` (not resolvable outside the user's session), and
dedup while preserving first-seen order.
"""
function _sanitize_trace_lines(lines::Vector{String})::Vector{String}
    seen = Set{String}()
    result = String[]
    for raw in lines
        line = strip(raw)
        startswith(line, "precompile(") || continue
        line = String(strip(replace(line, _RECOMPILE_COMMENT_RE => ")")))
        occursin("Main.", line) && continue
        line in seen && continue
        push!(seen, line)
        push!(result, line)
    end
    return result
end

"""
    _statement_modules(stmt) -> Set{String}

Extract candidate top-level module names referenced by a precompile
statement: any identifier immediately followed by `.` (e.g. `JSON` from
`JSON.Parser.parse` or `typeof(JSON.json)`). Over-inclusive by design --
callers intersect the result with the project's actual dependency names,
which naturally drops non-dependencies (submodule segments, `Base`,
`Core`, `Main`, `Tuple`, `Type`, `Vararg`, ...).
"""
function _statement_modules(stmt::String)::Set{String}
    return Set{String}(m.match for m in eachmatch(_MODULE_REF_RE, stmt))
end

function _write_warmup_project_toml(path::String, name::String, deps::Vector{String},
                                     dep_uuids::Dict{String,Base.UUID})
    open(path, "w") do io
        println(io, "name = \"$name\"")
        println(io, "uuid = \"$_WARMUP_PKG_UUID\"")
        println(io, "version = \"0.1.0\"")
        if !isempty(deps)
            println(io)
            println(io, "[deps]")
            for d in deps
                println(io, "$d = \"$(dep_uuids[d])\"")
            end
        end
    end
end

function _write_warmup_src(path::String, name::String, deps::Vector{String}, statements::Vector{String})
    open(path, "w") do io
        println(io, "module $name")
        println(io)
        for d in deps
            println(io, "using $d")
        end
        println(io)
        println(io, "if ccall(:jl_generating_output, Cint, ()) == 1")
        for stmt in statements
            println(io, "    try; $stmt; catch; end")
        end
        println(io, "end")
        println(io)
        println(io, "end # module")
    end
end

# ===================================================================
# warmup_build: develop + precompile the generated package into a build env
# ===================================================================

"""
    _active_manifest_path(project::String) -> Union{Nothing,String}

Return the absolute path to the manifest Julia would *actually* load for
`project` -- i.e. honoring per-minor-version manifests
(`Manifest-v<major>.<minor>.toml` / `JuliaManifest-v<major>.<minor>.toml`
take precedence over the unversioned `Manifest.toml`/`JuliaManifest.toml`,
exactly as `Base.require` resolves them). Returns `nothing` if `project` has
no `Project.toml` or no manifest at all.

Delegates to the internal `Base.project_file_manifest_path`, the same
function `Base`'s own loading machinery uses; falls back to a manual
equivalent if that internal is ever renamed/removed.
"""
function _active_manifest_path(project::String)::Union{Nothing,String}
    project_toml = joinpath(project, "Project.toml")
    isfile(project_toml) || return nothing
    if isdefined(Base, :project_file_manifest_path)
        try
            return Base.project_file_manifest_path(project_toml)
        catch
            # Internal API shifted under us -- fall through to the manual
            # resolution below rather than error out.
        end
    end
    for name in ("JuliaManifest-v$(VERSION.major).$(VERSION.minor).toml",
                 "Manifest-v$(VERSION.major).$(VERSION.minor).toml",
                 "JuliaManifest.toml",
                 "Manifest.toml")
        candidate = joinpath(project, name)
        isfile(candidate) && return candidate
    end
    return nothing
end

"""
    warmup_build(project, warmup_pkg_dir) -> Bool

Build the package generated by [`warmup_generate`](@ref) against a dedicated
environment (`_build_env`, a sibling of `warmup_pkg_dir`) that mirrors
`project`'s exact dependency resolution: `project`'s `Project.toml` and its
*active* manifest (see [`_active_manifest_path`](@ref) -- this honors
versioned manifests like `Manifest-v1.12.toml`, not just the unversioned
`Manifest.toml`) are copied in as `Project.toml`/`Manifest.toml`, then the
warmup package is `Pkg.develop`ed with `preserve=PRESERVE_ALL` (so develop
cannot re-resolve/upgrade the copied manifest's versions) and
`Pkg.precompile`d into it.

Prints one of:

    __JOOVY_WARMUP_PKG__ status=skip reason=julia_version|no_manifest
    __JOOVY_WARMUP_PKG__ status=fail
    __JOOVY_WARMUP_ERR__ <compact error message>        # only on status=fail
    __JOOVY_WARMUP_PKG__ status=built elapsed=<s>

On success, writes `_build_env/.manifest_hash` as two lines: the lowercase
hex sha256 of the active manifest's bytes, then the manifest's basename
(e.g. `Manifest-v1.12.toml`) -- so the IDE can cheaply detect whether the
build is stale relative to the project's current (possibly versioned)
manifest.
"""
function warmup_build(project::String, warmup_pkg_dir::String)
    if VERSION < v"1.10"
        println("__JOOVY_WARMUP_PKG__ status=skip reason=julia_version")
        return false
    end

    project_toml = joinpath(project, "Project.toml")
    manifest_path = _active_manifest_path(project)
    if !isfile(project_toml) || manifest_path === nothing
        println("__JOOVY_WARMUP_PKG__ status=skip reason=no_manifest")
        return false
    end

    build_env = joinpath(dirname(warmup_pkg_dir), "_build_env")
    mkpath(build_env)
    cp(project_toml, joinpath(build_env, "Project.toml"); force=true)
    cp(manifest_path, joinpath(build_env, "Manifest.toml"); force=true)

    t0 = time()
    try
        Pkg.activate(build_env; io=devnull)
        Pkg.develop(path=warmup_pkg_dir; preserve=Pkg.PRESERVE_ALL, io=devnull)
        _pkg_precompile("JoovyWarmup"; io=devnull)
    catch e
        println("__JOOVY_WARMUP_PKG__ status=fail")
        println("__JOOVY_WARMUP_ERR__ $(_compact_error(e))")
        return false
    end

    hash = bytes2hex(SHA.sha256(read(manifest_path)))
    write(joinpath(build_env, ".manifest_hash"), hash * "\n" * basename(manifest_path))

    elapsed = round(time() - t0, digits=1)
    println("__JOOVY_WARMUP_PKG__ status=built elapsed=$elapsed")
    return true
end

# ===================================================================
# Shared helpers
# ===================================================================

# `io` support in `Pkg.precompile` has shifted across 1.10-1.12; fall back to
# the io-less call if the keyword is rejected outright (a MethodError raised
# before any actual precompilation runs), while letting real precompile
# failures propagate to the caller's try/catch.
function _pkg_precompile(target; io::IO=devnull)
    try
        Pkg.precompile(target; io=io)
    catch e
        e isa MethodError || rethrow()
        Pkg.precompile(target)
    end
end

_compact_error(e) = replace(sprint(showerror, e), '\n' => ' ')

end # module

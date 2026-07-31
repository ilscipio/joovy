module Warmup

# Background depot-cache warming, and generation + build of a per-project
# "JoovyWarmup" package from `--trace-compile` output.
#
# An IDE spawns a DEDICATED subprocess per call to these functions and parses
# the printed `__JOOVY_*__` markers from stdout. Because each call owns the
# whole process, mutating global state (ENV, `Pkg.activate`, the active
# project) is safe here -- it never leaks into the user's REPL or another
# concurrent call.

export joovy_warm, warmup_generate, warmup_build, warm_daemon_loop,
       warmup_compact!, warmup_should_rebuild

# Pkg and SHA are loaded LAZILY at first use (they are declared in
# Project.toml [deps], both stdlibs). A top-level `import Pkg` here would make
# Pkg a load-time dependency of Joovy and add ~0.6s to EVERY `using Joovy`
# session start, even though only the dedicated warmup subprocesses ever call
# these functions.
const _PKG_ID = Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg")
const _SHA_ID = Base.PkgId(Base.UUID("ea8e919c-243c-51af-8825-aaa63cd721ce"), "SHA")
_pkg() = Base.require(_PKG_ID)
_sha() = Base.require(_SHA_ID)

# Fixed UUID for the generated JoovyWarmup package. Keeping it constant lets
# the IDE recognize/reuse a previously generated+built package across runs.
const _WARMUP_PKG_UUID = "7b1a2c3d-0000-4000-8000-1234567890ab"

const _RECOMPILE_COMMENT_RE = r"\)\s*#\s*recompile\s*$"
const _MODULE_REF_RE = r"[A-Za-z_][A-Za-z0-9_!]*(?=\.)"
# `--trace-compile-timing` (Julia 1.12+) prefixes each line with a block
# comment like `#=   12.3 ms =#`; non-greedy so nested `=#` (if any) isn't
# over-consumed.
const _TIMING_PREFIX_RE = r"^#=.*?=#\s*"

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
    # Pkg is loaded lazily (see _pkg); invokelatest crosses the world-age
    # boundary so the impl can call methods newer than Joovy's own compile.
    Pkg = _pkg()
    return Base.invokelatest(_joovy_warm_impl, Pkg, packages;
                             project=project, ntasks=ntasks,
                             cancel_file=cancel_file, io=io)
end

function _joovy_warm_impl(Pkg::Module, packages::Vector{String};
                          project::Union{Nothing,String},
                          ntasks::Integer,
                          cancel_file::Union{Nothing,String},
                          io::IO)
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
            _pkg_precompile(Pkg, [pkg]; io=devnull)
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

    trace_files = _list_trace_files(trace_dir)

    raw_lines = String[]
    for f in trace_files
        append!(raw_lines, readlines(joinpath(trace_dir, f)))
    end

    statements = _sanitize_trace_lines(raw_lines)

    if isempty(statements)
        println("__JOOVY_WARMUP_PKG__ status=skip reason=no_statements")
        return nothing
    end

    # Lazy Pkg + invokelatest: see joovy_warm for the world-age rationale.
    dep_uuids = Base.invokelatest(_project_dep_uuids, _pkg(), project)

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
    _list_trace_files(trace_dir) -> Vector{String}

Return the sorted basenames of every `trace-*.jl` file directly under
`trace_dir` (as produced by `julia --trace-compile=<file>`), matching
`startswith("trace-") && endswith(".jl")` on `readdir(trace_dir)`. Callers
`joinpath` these with `trace_dir` as needed -- this mirrors the original
inline filter `warmup_generate` used before it was extracted here.

Note this glob also matches `trace-compacted.jl` (the file
[`warmup_compact!`](@ref) writes), which is intentional: compacted output
feeds straight back into the next `warmup_generate` rebuild with no special
casing needed there.
"""
function _list_trace_files(trace_dir::String)::Vector{String}
    return sort(filter(f -> startswith(f, "trace-") && endswith(f, ".jl"),
                        readdir(trace_dir)))
end

"""
    _sanitize_trace_lines(lines) -> Vector{String}

Filter raw trace-compile lines down to `precompile(...)` statements: first
strip a leading `#= ... =#` timing-comment block (as emitted by
`--trace-compile-timing` on Julia 1.12+, e.g. `#=   12.3 ms =# precompile(...)`)
plus surrounding whitespace, then strip trailing `) # recompile` comments
(which would otherwise comment out the `; catch; end` wrapper and break the
generated module), drop any statement that references `Main.` (not
resolvable outside the user's session), and dedup while preserving
first-seen order.
"""
function _sanitize_trace_lines(lines::Vector{String})::Vector{String}
    seen = Set{String}()
    result = String[]
    for raw in lines
        line = strip(raw)
        line = String(strip(replace(line, _TIMING_PREFIX_RE => ""; count=1)))
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
# warmup_compact!: bound trace-dir growth across sessions
# ===================================================================

"""
    warmup_compact!(trace_dir::String; stale_after::Real=60, io::IO=stdout) -> NamedTuple

A real project accumulates one `trace-*.jl` file per session forever, and
[`warmup_generate`](@ref) re-reads every one of them on each rebuild. This
merges every non-fresh `trace-*.jl` file under `trace_dir` (as listed by
[`_list_trace_files`](@ref), excluding `trace-compacted.jl` itself and any
file whose `mtime` is within `stale_after` seconds of `time()` -- likely an
open session's still-being-written trace) into a single deduplicated,
sorted `trace-compacted.jl`, then deletes the merged originals so the file
count (and re-read cost) stops growing without bound.

The existing `trace-compacted.jl`, if any, is read and re-sanitized too and
unioned into the merge, so repeated calls only ever grow the deduplicated
statement set -- compacting twice in a row, or re-merging a file whose
deletion failed, is safe and idempotent. `trace-compacted.jl` is written
atomically: a temp file in `trace_dir`, then `mv(...; force=true)`.

`warmup_generate`'s trace-file glob (`startswith("trace-") &&
endswith(".jl")`, see [`_list_trace_files`](@ref)) already matches
`trace-compacted.jl`, so the compacted output feeds straight into the next
rebuild -- no changes needed there.

Prints one of:

    __JOOVY_WARMUP_COMPACT__ status=skip reason=julia_version
    __JOOVY_WARMUP_COMPACT__ status=skip reason=nothing_to_compact
    __JOOVY_WARMUP_COMPACT__ status=compacted merged=<n> statements=<n> skipped=<n>

`merged` counts original files successfully deleted; `skipped` counts files
excluded as too-fresh plus originals whose deletion failed (e.g. Windows
keeping a live session's file open) -- those simply merge again, harmlessly,
on the next call.

Returns `(status::Symbol, reason::Union{Symbol,Missing}, merged::Int,
statements::Int, skipped::Int)`.
"""
function warmup_compact!(trace_dir::String; stale_after::Real=60, io::IO=stdout)
    if VERSION < v"1.10"
        println(io, "__JOOVY_WARMUP_COMPACT__ status=skip reason=julia_version")
        return (status=:skip, reason=:julia_version, merged=0, statements=0, skipped=0)
    end

    compacted_name = "trace-compacted.jl"
    compacted_path = joinpath(trace_dir, compacted_name)

    now = time()
    candidates = String[]
    recent_skipped = 0
    for f in _list_trace_files(trace_dir)
        f == compacted_name && continue
        path = joinpath(trace_dir, f)
        mt = try
            mtime(path)
        catch
            continue # file vanished between readdir and stat; nothing to merge
        end
        if now - mt < stale_after
            recent_skipped += 1
            continue # likely an open session's live trace; leave it alone
        end
        push!(candidates, f)
    end

    if isempty(candidates)
        println(io, "__JOOVY_WARMUP_COMPACT__ status=skip reason=nothing_to_compact")
        return (status=:skip, reason=:nothing_to_compact, merged=0, statements=0, skipped=recent_skipped)
    end

    raw_lines = String[]
    for f in candidates
        append!(raw_lines, readlines(joinpath(trace_dir, f)))
    end
    new_statements = _sanitize_trace_lines(raw_lines)

    existing_statements = isfile(compacted_path) ?
        _sanitize_trace_lines(readlines(compacted_path)) : String[]

    merged = sort!(union(existing_statements, new_statements))

    tmp_path = joinpath(trace_dir, ".$(compacted_name).$(getpid()).tmp")
    open(tmp_path, "w") do tmp_io
        for stmt in merged
            println(tmp_io, stmt)
        end
    end
    mv(tmp_path, compacted_path; force=true)

    deleted = 0
    failed = 0
    for f in candidates
        try
            rm(joinpath(trace_dir, f))
            deleted += 1
        catch
            failed += 1 # e.g. Windows: file still open by a live session
        end
    end

    skipped = failed + recent_skipped
    println(io, "__JOOVY_WARMUP_COMPACT__ status=compacted merged=$deleted statements=$(length(merged)) skipped=$skipped")
    return (status=:compacted, reason=missing, merged=deleted, statements=length(merged), skipped=skipped)
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

    # Lazy Pkg/SHA + invokelatest: see joovy_warm for the world-age rationale.
    return Base.invokelatest(_warmup_build_impl, _pkg(), _sha(), project, warmup_pkg_dir)
end

function _warmup_build_impl(Pkg::Module, SHA::Module, project::String, warmup_pkg_dir::String)
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
        _pkg_precompile(Pkg, "JoovyWarmup"; io=devnull)
    catch e
        println("__JOOVY_WARMUP_PKG__ status=fail")
        println("__JOOVY_WARMUP_ERR__ $(_compact_error(e))")
        return false
    end

    hash = bytes2hex(SHA.sha256(read(manifest_path)))
    write(joinpath(build_env, ".manifest_hash"), hash * "\n" * basename(manifest_path))

    trace_dir = dirname(warmup_pkg_dir)
    write(joinpath(build_env, ".trace_state"), string(_trace_bytes_total(trace_dir)))

    elapsed = round(time() - t0, digits=1)
    println("__JOOVY_WARMUP_PKG__ status=built elapsed=$elapsed")
    return true
end

# ===================================================================
# warmup_should_rebuild: cheap advisory rebuild hint for the IDE
# ===================================================================

"""
    warmup_should_rebuild(project, trace_dir; byte_threshold=1_000_000) -> NamedTuple

Advisory-only, cheap check for whether the IDE should re-run
[`warmup_generate`](@ref)/[`warmup_build`](@ref) rather than reuse the
existing built package. Compares two independent signals against the state
recorded by the last successful [`warmup_build`](@ref) (both files live
under `<trace_dir>/_build_env`, alongside `.manifest_hash`):

  - The project's *current* active manifest (see
    [`_active_manifest_path`](@ref)) hashed the same way
    [`_warmup_build_impl`](@ref) hashes it, compared against the stored
    `.manifest_hash`.
  - The current total byte size of every `trace-*.jl` file (see
    [`_list_trace_files`](@ref)) compared against the size recorded at the
    last build time in `.trace_state`.

This never builds or mutates anything -- it only reads state and reports a
recommendation.

Prints:

    __JOOVY_WARMUP_SHOULD_REBUILD__ should_rebuild=<bool> reason=<reason>

`reason` is one of:

  - `:julia_version`    -- Julia < 1.10, the advisory is unavailable.
  - `:never_built`      -- no recorded `.manifest_hash` yet.
  - `:manifest_changed` -- the project's active manifest no longer matches
                           the hash recorded at the last build.
  - `:trace_growth`     -- the manifest still matches, but trace files have
                           grown by at least `byte_threshold` bytes since
                           the last build.
  - `:up_to_date`        -- neither of the above triggered.

Returns `(should_rebuild::Bool, reason::Symbol,
manifest_changed::Union{Bool,Missing}, bytes_delta::Union{Int,Missing})`.
`manifest_changed`/`bytes_delta` are `missing` when they could not be
computed (e.g. no prior build, or no `.trace_state` recorded yet -- in which
case the recommendation relies on the manifest comparison alone).
"""
function warmup_should_rebuild(project::String, trace_dir::String;
                                byte_threshold::Integer=1_000_000)
    if VERSION < v"1.10"
        println("__JOOVY_WARMUP_SHOULD_REBUILD__ should_rebuild=false reason=julia_version")
        return (should_rebuild=false, reason=:julia_version,
                manifest_changed=missing, bytes_delta=missing)
    end

    build_env = joinpath(trace_dir, "_build_env")
    hash_file = joinpath(build_env, ".manifest_hash")

    if !isfile(hash_file)
        println("__JOOVY_WARMUP_SHOULD_REBUILD__ should_rebuild=true reason=never_built")
        return (should_rebuild=true, reason=:never_built,
                manifest_changed=missing, bytes_delta=missing)
    end

    # Lazy SHA + invokelatest: see joovy_warm for the world-age rationale.
    manifest_changed = Base.invokelatest(_manifest_changed, _sha(), project, hash_file)
    bytes_delta = _trace_bytes_delta(trace_dir, build_env)

    should_rebuild = manifest_changed === true ||
                     (bytes_delta !== missing && bytes_delta >= byte_threshold)

    reason = if manifest_changed === true
        :manifest_changed
    elseif bytes_delta !== missing && bytes_delta >= byte_threshold
        :trace_growth
    else
        :up_to_date
    end

    println("__JOOVY_WARMUP_SHOULD_REBUILD__ should_rebuild=$should_rebuild reason=$reason")
    return (should_rebuild=should_rebuild, reason=reason,
            manifest_changed=manifest_changed, bytes_delta=bytes_delta)
end

# `hash_file` holds two lines: hex sha256 of the manifest's bytes, then its
# basename (see `_warmup_build_impl`). Only the hash is compared here.
function _manifest_changed(SHA::Module, project::String, hash_file::String)::Union{Bool,Missing}
    manifest_path = _active_manifest_path(project)
    manifest_path === nothing && return missing
    stored_lines = readlines(hash_file)
    isempty(stored_lines) && return missing
    stored_hash = lowercase(strip(stored_lines[1]))
    current_hash = lowercase(bytes2hex(SHA.sha256(read(manifest_path))))
    return current_hash != stored_hash
end

function _trace_bytes_total(trace_dir::String)::Int
    total = 0
    for f in _list_trace_files(trace_dir)
        try
            total += filesize(joinpath(trace_dir, f))
        catch
            # file vanished between readdir and stat; just don't count it.
        end
    end
    return total
end

function _trace_bytes_delta(trace_dir::String, build_env::String)::Union{Int,Missing}
    state_file = joinpath(build_env, ".trace_state")
    isfile(state_file) || return missing
    stored = tryparse(Int, strip(read(state_file, String)))
    stored === nothing && return missing
    return _trace_bytes_total(trace_dir) - stored
end

# ===================================================================
# warm_daemon_loop: persistent worker, avoids per-request Julia startup
# ===================================================================

"""
    warm_daemon_loop(; input::IO=stdin, io::IO=stdout)

Run a persistent command loop so an IDE doesn't pay Julia's ~2-4s startup
cost on every warm/build request. The daemon is expected to be launched as a
dedicated subprocess with `--project=<env>` pointing at the project whose
depot cache should be warmed; `WARM` never activates a different project (it
runs against the daemon's own already-active project), and `BUILD` always
restores the daemon's original active project afterward.

Loads Pkg and SHA once, prints

    __JOOVY_DAEMON__ status=ready

then reads TAB-separated commands (one per line, tabs never appear in paths
or names) from `input` until EOF or an `EXIT` command:

    WARM\\t<pkg1,pkg2,...>\\t<cancel_file_path_or_->
    BUILD\\t<project_dir>\\t<trace_dir>
    COMPACT\\t<trace_dir>
    EXIT

`WARM` reuses [`_joovy_warm_impl`](@ref) (with `project=nothing`, since the
daemon's active project already IS the target project), printing the usual
`__JOOVY_WARM__` / `__JOOVY_WARM_DONE__` markers. `BUILD` reuses
[`warmup_generate`](@ref) then, if it returns a package dir,
[`_warmup_build_impl`](@ref) -- both mutate the active project via
`Pkg.activate`, so the project active before the command is captured and
restored in a `finally`. `COMPACT` reuses [`warmup_compact!`](@ref) directly
against the given `trace_dir`, printing the usual `__JOOVY_WARMUP_COMPACT__`
marker; unlike `WARM`/`BUILD` it does no `Pkg.activate` (pure file I/O), so
there is no active-project save/restore to do.

After EVERY command (success, failure, or unknown) prints and flushes:

    __JOOVY_DAEMON__ status=idle

On error, a command additionally prints (before the idle marker):

    __JOOVY_DAEMON_ERR__ <compact error message>

A command failure never kills the loop -- only `EXIT` (which prints
`__JOOVY_DAEMON__ status=exit` then returns) or the input stream reaching EOF
ends it. On Julia < 1.10 prints `__JOOVY_DAEMON__ status=skip
reason=julia_version` and returns immediately without entering the loop.
"""
function warm_daemon_loop(; input::IO=stdin, io::IO=stdout)
    if VERSION < v"1.10"
        println(io, "__JOOVY_DAEMON__ status=skip reason=julia_version")
        return nothing
    end

    # Lazy Pkg/SHA + invokelatest for anything that touches them: see
    # joovy_warm for the world-age rationale. Loaded once, up front, so every
    # subsequent command dispatch skips Base.require's lookup cost.
    Pkg = _pkg()
    SHA = _sha()

    println(io, "__JOOVY_DAEMON__ status=ready")
    flush(io)

    while !eof(input)
        line = readline(input)
        isempty(strip(line)) && continue

        parts = split(line, '\t')
        cmd = parts[1]

        if cmd == "EXIT"
            println(io, "__JOOVY_DAEMON__ status=exit")
            flush(io)
            break
        end

        try
            if cmd == "WARM"
                length(parts) >= 3 || error("WARM requires <packages>\\t<cancel_file>")
                pkgs = filter(!isempty, String.(split(parts[2], ',')))
                cancel_file = parts[3] == "-" ? nothing : String(parts[3])
                Base.invokelatest(_joovy_warm_impl, Pkg, pkgs;
                                  project=nothing,
                                  ntasks=max(1, Sys.CPU_THREADS ÷ 2),
                                  cancel_file=cancel_file, io=io)
            elseif cmd == "BUILD"
                length(parts) >= 3 || error("BUILD requires <project_dir>\\t<trace_dir>")
                project_dir = String(parts[2])
                trace_dir = String(parts[3])
                saved = Base.active_project()
                try
                    pkg_dir = warmup_generate(project_dir, trace_dir)
                    if pkg_dir !== nothing
                        Base.invokelatest(_warmup_build_impl, Pkg, SHA, project_dir, pkg_dir)
                    end
                finally
                    saved === nothing || Base.invokelatest(Pkg.activate, dirname(saved); io=devnull)
                end
            elseif cmd == "COMPACT"
                length(parts) >= 2 || error("COMPACT requires <trace_dir>")
                trace_dir = String(parts[2])
                warmup_compact!(trace_dir; io=io)
            else
                println(io, "__JOOVY_DAEMON_ERR__ unknown command: $cmd")
            end
        catch e
            println(io, "__JOOVY_DAEMON_ERR__ $(_compact_error(e))")
        end

        println(io, "__JOOVY_DAEMON__ status=idle")
        flush(io)
    end

    return nothing
end

# ===================================================================
# Shared helpers
# ===================================================================

# `io` support in `Pkg.precompile` has shifted across 1.10-1.12; fall back to
# the io-less call if the keyword is rejected outright (a MethodError raised
# before any actual precompilation runs), while letting real precompile
# failures propagate to the caller's try/catch.
function _pkg_precompile(Pkg::Module, target; io::IO=devnull)
    try
        Pkg.precompile(target; io=io)
    catch e
        e isa MethodError || rethrow()
        Pkg.precompile(target)
    end
end

function _project_dep_uuids(Pkg::Module, project::String)
    Pkg.activate(project; io=devnull)
    return Dict{String,Base.UUID}(info.name => uuid for (uuid, info) in Pkg.dependencies())
end

_compact_error(e) = replace(sprint(showerror, e), '\n' => ' ')

end # module

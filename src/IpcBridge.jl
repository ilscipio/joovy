module IpcBridge

using ..DynCompiler
using ..HotSwap
using ..ExprCache
using ..Debug
using ..LazyModules
using ..CompileTimeline
using ..PackageTier
using ..Instrument
using ..Config
using ..SpecQueue
using ..SourceProvider
using ..CompileWatch

export joovy_register_ipc_handlers!, joovy_ipc_available

const _ipc_registered = Ref{Bool}(false)

const _lazy_modules = Dict{String, LazyModule}()
const _lazy_modules_lock = ReentrantLock()

function joovy_ipc_available()
    isdefined(Main, :FlexibleIPC) &&
    isdefined(Main.FlexibleIPC, :register_handler)
end

function joovy_register_ipc_handlers!()
    joovy_ipc_available() || return false
    _ipc_registered[] && return true

    ipc = Main.FlexibleIPC

    for (route, handler) in _ipc_handler_table()
        ipc.register_handler("joovy/$route", function(params)
            return Base.invokelatest(handler, params)
        end)
    end

    _ipc_registered[] = true
    _notify("joovy/ready", Dict("version" => _joovy_version()))
    return true
end

_joovy_version() = try string(Base.pkgversion(@__MODULE__)) catch; "unknown" end

function _notify(method::String, params::Dict)
    if joovy_ipc_available() && isdefined(Main.FlexibleIPC, :send_notification)
        try
            Main.FlexibleIPC.send_notification(method, params)
        catch
        end
    end
end

# ===================================================================
# Parameter validation helpers
#
# `get(params, key, default)` only substitutes the default when `key` is
# ABSENT -- a present JSON `null` (Julia `nothing`) or a wrong-typed value
# still comes through as-is, and `isempty(nothing)` / `isempty(42)` throw a
# MethodError before any try/catch in the handler body gets a chance to run.
# These helpers make "absent or null" and "present but wrong type" two
# distinct, non-throwing outcomes: the former defaults, the latter is a
# clear validation error.
# ===================================================================

_err(msg::AbstractString) = Dict("status" => "error", "error" => String(msg))

function _req_string(params, key)
    v = get(params, key, nothing)
    (v isa AbstractString && !isempty(v)) ? String(v) : nothing
end

# present-but-wrong-type optionals are ERRORS (clear failure beats silent default);
# absent or null -> default.
function _opt_string(params, key)          # -> (value_or_nothing, valid::Bool)
    haskey(params, key) || return (nothing, true)
    v = params[key]; v === nothing && return (nothing, true)
    v isa AbstractString ? (String(v), true) : (nothing, false)
end
function _opt_int(params, key, default)    # -> Int or nothing (=invalid)
    haskey(params, key) || return default
    v = params[key]; v === nothing && return default
    v isa Bool && return nothing
    v isa Integer && return Int(v)
    v isa AbstractFloat && isinteger(v) && return Int(v)
    return nothing
end
function _opt_bool(params, key, default)
    haskey(params, key) || return default
    v = params[key]; v === nothing && return default
    v isa Bool ? v : nothing
end

# Same "absent-or-null -> default, wrong type -> nothing (=invalid)" shape as
# `_opt_int`/`_opt_bool`, for a real-valued (Float64) parameter. `default` is
# always a usable, non-nothing threshold value here, so `nothing` unambiguously
# signals "invalid type", exactly like the existing int/bool helpers.
function _opt_float(params, key, default)
    haskey(params, key) || return default
    v = params[key]; v === nothing && return default
    v isa Bool && return nothing
    v isa Real && return Float64(v)
    return nothing
end

# Optional integer whose "no value supplied" default IS `nothing` (source version
# numbers have no natural non-nothing default), so `_opt_int`'s collapsed
# "invalid-or-absent -> nothing" return can't be used to tell the two apart.
# Same absent/null-vs-wrong-type split as `_opt_string`, tupled the same way.
function _opt_int_or_nothing(params, key)   # -> (Union{Int,Nothing}, valid::Bool)
    haskey(params, key) || return (nothing, true)
    v = params[key]; v === nothing && return (nothing, true)
    v isa Bool && return (nothing, false)
    v isa Integer && return (Int(v), true)
    v isa AbstractFloat && isinteger(v) && return (Int(v), true)
    return (nothing, false)
end

function _handle_compile(params)
    code = _req_string(params, "code")
    code === nothing && return _err("Missing or invalid 'code' parameter")
    name_str, name_valid = _opt_string(params, "name")
    name_valid || return _err("Invalid 'name' parameter: must be a string")
    name = name_str !== nothing ? Symbol(name_str) : nothing

    t0 = time_ns()
    try
        result = joovy_compile(code; name=name)
        elapsed = time_ns() - t0
        resp = Dict("status" => "ok", "time_ns" => elapsed,
                     "cached" => false)
        if name !== nothing
            resp["name"] = string(name)
            mapping = source_map_lookup(name)
            if mapping !== nothing
                resp["compiled_name"] = string(mapping.compiled_names[1])
            end
        end
        _notify("joovy/compile_status", resp)
        return resp
    catch e
        elapsed = time_ns() - t0
        err = merge(_err(sprint(showerror, e)), Dict("time_ns" => elapsed))
        _notify("joovy/error", err)
        return err
    end
end

function _handle_swap(params)
    name_str = _req_string(params, "name")
    name_str === nothing && return _err("Missing or invalid 'name' parameter")
    code = _req_string(params, "code")
    code === nothing && return _err("Missing or invalid 'code' parameter")
    name = Symbol(name_str)

    t0 = time_ns()
    try
        old_version = hotswap_version(name)
        hotswap_swap!(name, code)
        new_version = hotswap_version(name)
        elapsed = time_ns() - t0
        resp = Dict("status" => "ok", "name" => name_str,
                     "old_version" => old_version, "new_version" => new_version,
                     "time_ns" => elapsed)
        _notify("joovy/swap_status", resp)
        return resp
    catch e
        elapsed = time_ns() - t0
        err = merge(_err(sprint(showerror, e)), Dict("name" => name_str, "time_ns" => elapsed))
        _notify("joovy/error", err)
        return err
    end
end

function _handle_reload(params)
    file = _req_string(params, "file")
    file === nothing && return _err("Missing or invalid 'file' parameter")
    incremental = _opt_bool(params, "incremental", true)
    incremental === nothing && return _err("Invalid 'incremental' parameter: must be a boolean")
    content, content_valid = _opt_string(params, "content")
    content_valid || return _err("Invalid 'content' parameter: must be a string")
    version, version_valid = _opt_int_or_nothing(params, "version")
    version_valid || return _err("Invalid 'version' parameter: must be an integer")

    abs_path = abspath(file)
    if content !== nothing
        source_push!(abs_path, content, version)
    end
    t0 = time_ns()
    try
        lm = lock(_lazy_modules_lock) do
            get(_lazy_modules, abs_path, nothing)
        end

        if lm !== nothing
            result = joovy_reload!(lm)
            elapsed = time_ns() - t0
            resp = Dict(
                "status" => "ok",
                "file" => file,
                "mode" => "lazy_incremental",
                "changed" => [string(n) for n in result.changed],
                "removed" => [string(n) for n in result.removed],
                "added" => [string(n) for n in result.added],
                "time_ns" => elapsed
            )
            _notify("joovy/swap_status", resp)
            return resp
        else
            result = joovy_hot_reload(file; incremental=incremental)
            elapsed = time_ns() - t0
            resp = Dict(
                "status" => result.status,
                "file" => file,
                "mode" => "full_reload",
                "reloaded" => [string(n) for n in result.reloaded],
                "unchanged" => [string(n) for n in result.unchanged],
                "fallback_definitions" => result.fallback_definitions,
                "defs_changed" => length(result.fallback_changed) + length(result.reloaded),
                "defs_added" => length(result.fallback_added),
                "defs_removed" => length(result.fallback_removed),
                "defs_unchanged" => length(result.fallback_unchanged) + length(result.unchanged),
                "time_ns" => elapsed
            )
            if result.error !== nothing
                resp["error"] = result.error
            end
            _notify("joovy/swap_status", resp)
            return resp
        end
    catch e
        elapsed = time_ns() - t0
        err = merge(_err(sprint(showerror, e)), Dict("file" => file, "time_ns" => elapsed))
        _notify("joovy/error", err)
        return err
    end
end

function _handle_status(params)
    stats = compilation_stats()

    entries = lock(GLOBAL_REGISTRY.lock) do
        Dict(string(k) => Dict(
            "version" => v.version,
            "has_file" => v.file_path !== nothing,
            "file_path" => v.file_path !== nothing ? v.file_path : ""
        ) for (k, v) in GLOBAL_REGISTRY.entries)
    end

    source_maps = lock(DynCompiler._source_map_lock) do
        Dict(string(k) => Dict(
            "original_names" => [string(n) for n in v.original_names],
            "compiled_names" => [string(n) for n in v.compiled_names],
            "source_file" => v.source_file !== nothing ? v.source_file : "",
            "compile_id" => v.compile_id
        ) for (k, v) in GLOBAL_SOURCE_MAP)
    end

    return Dict(
        "cache_hits" => stats.content_hits,
        "cache_misses" => stats.content_misses,
        "cache_entries" => stats.total_entries,
        "registered_functions" => entries,
        "source_maps" => source_maps,
        "ipc_connected" => true
    )
end

function _handle_source_map(params)
    name_str = _req_string(params, "name")
    name_str === nothing && return _err("Missing or invalid 'name' parameter")
    name = Symbol(name_str)

    try
        mapping = source_map_lookup(name)
        if mapping === nothing
            return Dict("found" => false, "name" => name_str)
        end

        return Dict(
            "found" => true,
            "name" => name_str,
            "original_names" => [string(n) for n in mapping.original_names],
            "compiled_names" => [string(n) for n in mapping.compiled_names],
            "source_file" => mapping.source_file !== nothing ? mapping.source_file : "",
            "compile_id" => mapping.compile_id
        )
    catch e
        return _err(sprint(showerror, e))
    end
end

function _handle_breakpoint_map(params)
    file = _req_string(params, "file")
    file === nothing && return _err("Missing or invalid 'file' parameter")
    line = _opt_int(params, "line", nothing)
    (line === nothing || line < 1) &&
        return _err("Missing or invalid 'line' parameter: must be an integer >= 1")

    try
        result = joovy_breakpoint_map(file, line)
        if result === nothing
            return Dict("found" => false, "file" => file, "line" => line)
        end

        return Dict(
            "found" => true,
            "file" => file,
            "line" => line,
            "original_name" => string(result.original_name),
            "compiled_name" => string(result.compiled_name),
            "compile_id" => result.compile_id
        )
    catch e
        return _err(sprint(showerror, e))
    end
end

function _handle_debug_info(params)
    name_str = _req_string(params, "name")
    name_str === nothing && return _err("Missing or invalid 'name' parameter")
    name = Symbol(name_str)

    try
        info = joovy_debug_info(name)
        if info === nothing
            return Dict("found" => false, "name" => name_str)
        end

        return Dict(
            "found" => true,
            "name" => name_str,
            "original_names" => [string(n) for n in info.original_names],
            "compiled_names" => [string(n) for n in info.compiled_names],
            "source_file" => info.source_file !== nothing ? info.source_file : "",
            "compile_id" => info.compile_id
        )
    catch e
        return _err(sprint(showerror, e))
    end
end

function _handle_use(params)
    path = _req_string(params, "path")
    path === nothing && return _err("Missing or invalid 'path' parameter")
    tier = _opt_int(params, "tier", 1)
    tier === nothing && return _err("Invalid 'tier' parameter: must be an integer")
    content, content_valid = _opt_string(params, "content")
    content_valid || return _err("Invalid 'content' parameter: must be a string")
    version, version_valid = _opt_int_or_nothing(params, "version")
    version_valid || return _err("Invalid 'version' parameter: must be an integer")

    if content !== nothing
        source_push!(abspath(path), content, version)
    end

    t0 = time_ns()
    try
        lm = joovy_use(path; tier=tier)
        lock(_lazy_modules_lock) do
            _lazy_modules[abspath(path)] = lm
        end
        elapsed = time_ns() - t0
        status = lazy_status(lm)
        return Dict(
            "status" => "ok",
            "path" => abspath(path),
            "total_definitions" => status.total_definitions,
            "compiled_count" => status.compiled_count,
            "pending_count" => length(status.pending),
            "time_ns" => elapsed
        )
    catch e
        elapsed = time_ns() - t0
        return merge(_err(sprint(showerror, e)), Dict("path" => path, "time_ns" => elapsed))
    end
end

function _handle_lazy_status(params)
    modules = Dict[]
    lock(_lazy_modules_lock) do
        for (path, lm) in _lazy_modules
            try
                s = lazy_status(lm)
                push!(modules, Dict(
                    "path" => s.path,
                    "total" => s.total_definitions,
                    "compiled" => s.compiled_count,
                    "pending" => length(s.pending),
                    "tiers" => Dict(string(k) => v for (k, v) in s.tiers),
                    "call_counts" => Dict(string(k) => v for (k, v) in s.call_counts)
                ))
            catch
            end
        end
    end
    return Dict("modules" => modules)
end

function _handle_timeline(params)
    report = compile_report()
    return Dict("report" => report)
end

function _handle_dev_mode(params)
    active = _opt_bool(params, "active", true)
    active === nothing && return _err("Invalid 'active' parameter: must be a boolean")
    tier = _opt_int(params, "tier", 1)
    tier === nothing && return _err("Invalid 'tier' parameter: must be an integer")

    t0 = time_ns()
    try
        result = joovy_dev_mode!(; tier=tier, active=active)
        elapsed = time_ns() - t0
        status = joovy_dev_mode_status()
        resp = Dict(
            "status" => "ok",
            "active" => status.active,
            "tier" => status.tier,
            "packages" => Dict(string(k) => v for (k, v) in status.packages),
            "time_ns" => elapsed
        )
        _notify("joovy/dev_mode_status", resp)
        return resp
    catch e
        elapsed = time_ns() - t0
        return merge(_err(sprint(showerror, e)), Dict("time_ns" => elapsed))
    end
end

function _handle_package_tier(params)
    pkg_str = _req_string(params, "package")
    pkg_str === nothing && return _err("Missing or invalid 'package' parameter")
    tier = _opt_int(params, "tier", 1)
    tier === nothing && return _err("Invalid 'tier' parameter: must be an integer")
    pkg = Symbol(pkg_str)

    t0 = time_ns()
    try
        result = joovy_use_package(pkg; tier=tier)
        elapsed = time_ns() - t0
        return Dict(
            "status" => "ok",
            "package" => pkg_str,
            "tier" => tier,
            "modules_configured" => result.modules_configured,
            "time_ns" => elapsed
        )
    catch e
        elapsed = time_ns() - t0
        return merge(_err(sprint(showerror, e)), Dict("package" => pkg_str, "time_ns" => elapsed))
    end
end

function _handle_promote_all(params)
    tier = _opt_int(params, "tier", 2)
    tier === nothing && return _err("Invalid 'tier' parameter: must be an integer")

    t0 = time_ns()
    try
        tiers = joovy_package_tiers()
        for (pkg, _) in tiers
            joovy_promote_package!(pkg; tier=tier)
        end
        elapsed = time_ns() - t0
        return Dict(
            "status" => "ok",
            "tier" => tier,
            "packages_promoted" => length(tiers),
            "time_ns" => elapsed
        )
    catch e
        elapsed = time_ns() - t0
        return merge(_err(sprint(showerror, e)), Dict("time_ns" => elapsed))
    end
end

function _handle_counters(params)
    return counters_report()
end

# Re-read LocalPreferences.toml [Joovy] and re-apply tiers without restarting the REPL.
function _handle_apply_preferences(params)
    t0 = time_ns()
    try
        result = joovy_apply_preferences!()
        elapsed = time_ns() - t0
        return Dict(
            "status"    => "ok",
            "has_config" => result.has_config,
            "default"   => result.default === nothing ? nothing : result.default,
            "packages"  => result.packages,
            "functions" => result.functions,
            "time_ns"   => elapsed,
        )
    catch e
        elapsed = time_ns() - t0
        return merge(_err(sprint(showerror, e)), Dict("time_ns" => elapsed))
    end
end

# Explicit IDE "promote" intent: enqueue a lazy module's function (and its transitive
# dependency subtree) -- or every definition in the module -- for speculative background
# compilation at `tier`. Force-enables speculation, since an explicit IPC call from the
# IDE is unambiguous user/tooling intent regardless of the current opt-in flag.
function _handle_promote(params)
    path = _req_string(params, "path")
    path === nothing && return _err("Missing or invalid 'path' parameter")
    tier = _opt_int(params, "tier", 2)
    tier === nothing && return _err("Invalid 'tier' parameter: must be an integer")
    fn_str, fn_valid = _opt_string(params, "function")
    fn_valid || return _err("Invalid 'function' parameter: must be a string")

    t0 = time_ns()
    try
        SpecQueue.joovy_speculate!(true)

        abs_path = abspath(path)
        lm = lock(_lazy_modules_lock) do
            get(_lazy_modules, abs_path, nothing)
        end
        if lm === nothing
            return _err("Unknown lazy module (call joovy/use first): $path")
        end

        n = if fn_str !== nothing
            name = Symbol(fn_str)
            if !haskey(lm.definitions, name)
                return _err("Unknown function `$fn_str` in $path")
            end
            SpecQueue.spec_enqueue_subtree!(lm, name; tier=tier, class=3)
        else
            SpecQueue.spec_enqueue_all!(lm; tier=tier, class=3)
        end

        elapsed = time_ns() - t0
        resp = Dict(
            "status" => "ok",
            "path" => abs_path,
            "enqueued" => n,
            "queue_depth" => SpecQueue.spec_stats().queue_depth,
            "time_ns" => elapsed
        )
        _notify("joovy/promote_status", resp)
        return resp
    catch e
        elapsed = time_ns() - t0
        err = merge(_err(sprint(showerror, e)), Dict("path" => path, "time_ns" => elapsed))
        _notify("joovy/error", err)
        return err
    end
end

# Push an editor-buffer's content into SourceProvider's cache ahead of any read
# (reload/use, or a plain future disk read) -- lets the IDE hand over an unsaved
# buffer so the compiler sees it without a round trip through disk.
function _handle_source_push(params)
    path = _req_string(params, "path")
    path === nothing && return _err("Missing or invalid 'path' parameter")
    content = _req_string(params, "content")
    content === nothing && return _err("Missing or invalid 'content' parameter")
    version, version_valid = _opt_int_or_nothing(params, "version")
    version_valid || return _err("Invalid 'version' parameter: must be an integer")

    t0 = time_ns()
    try
        abs_path = abspath(path)
        source_push!(abs_path, content, version)
        CompileWatch.compile_watch_notify_push!(abs_path)
        elapsed = time_ns() - t0
        return Dict(
            "status" => "ok",
            "path" => abs_path,
            "version" => version,
            "time_ns" => elapsed
        )
    catch e
        elapsed = time_ns() - t0
        return merge(_err(sprint(showerror, e)), Dict("path" => path, "time_ns" => elapsed))
    end
end

# Drop a cached SourceProvider entry, e.g. when the IDE closes an unsaved buffer
# and later reads should fall back to disk (or a provider) again.
function _handle_source_invalidate(params)
    path = _req_string(params, "path")
    path === nothing && return _err("Missing or invalid 'path' parameter")

    t0 = time_ns()
    try
        abs_path = abspath(path)
        source_invalidate!(abs_path)
        elapsed = time_ns() - t0
        return Dict("status" => "ok", "path" => abs_path, "time_ns" => elapsed)
    catch e
        elapsed = time_ns() - t0
        return merge(_err(sprint(showerror, e)), Dict("path" => path, "time_ns" => elapsed))
    end
end

# Start (or reconfigure) a CompileWatch diagnostics session: static rules over
# `paths` (if given) and/or the dynamic compile-time capture layer. Pushes a
# `joovy/diagnostics` full-snapshot notification once the session is up so the
# IDE doesn't have to wait for the first throttle tick.
function _handle_diag_start(params)
    paths_raw = get(params, "paths", nothing)
    paths = String[]
    if paths_raw !== nothing
        paths_raw isa AbstractVector ||
            return _err("Invalid 'paths' parameter: must be an array of strings")
        for p in paths_raw
            p isa AbstractString ||
                return _err("Invalid 'paths' parameter: must be an array of strings")
            push!(paths, String(p))
        end
    end
    static = _opt_bool(params, "static", true)
    static === nothing && return _err("Invalid 'static' parameter: must be a boolean")
    dynamic = _opt_bool(params, "dynamic", true)
    dynamic === nothing && return _err("Invalid 'dynamic' parameter: must be a boolean")
    spec_over = _opt_int(params, "specializations_over", 32)
    spec_over === nothing && return _err("Invalid 'specializations_over' parameter: must be an integer")
    infer_ms_over = _opt_float(params, "inference_self_ms_over", 50.0)
    infer_ms_over === nothing && return _err("Invalid 'inference_self_ms_over' parameter: must be a number")
    reinfer_over = _opt_int(params, "reinfer_count_over", 3)
    reinfer_over === nothing && return _err("Invalid 'reinfer_count_over' parameter: must be an integer")
    compile_ms_over = _opt_float(params, "compile_ms_over", 100.0)
    compile_ms_over === nothing && return _err("Invalid 'compile_ms_over' parameter: must be a number")
    disabled_raw = get(params, "disabled_rules", nothing)
    disabled = nothing
    if disabled_raw !== nothing
        disabled_raw isa AbstractVector ||
            return _err("Invalid 'disabled_rules' parameter: must be an array of strings")
        for r in disabled_raw
            r isa AbstractString ||
                return _err("Invalid 'disabled_rules' parameter: must be an array of strings")
        end
        disabled = String.(disabled_raw)
    end

    t0 = time_ns()
    try
        compile_watch_set_thresholds!(specializations_over=spec_over,
            inference_self_ms_over=infer_ms_over, reinfer_count_over=reinfer_over,
            compile_ms_over=compile_ms_over)
        # Present = replace (the IDE sends its full setting); absent = unchanged.
        disabled === nothing || CompileWatch.set_disabled_rules!(disabled)
        result = compile_watch_start!(static=static, dynamic=dynamic, paths=paths)
        elapsed = time_ns() - t0
        resp = Dict(
            "status" => "ok",
            "static" => static,
            "dynamic_requested" => dynamic,
            "dynamic_active" => result.dynamic_active,
            "static_diagnostic_count" => result.static_diagnostic_count,
            "time_ns" => elapsed,
        )
        _notify("joovy/diagnostics", compile_watch_wire_snapshot())
        return resp
    catch e
        elapsed = time_ns() - t0
        return merge(_err(sprint(showerror, e)), Dict("time_ns" => elapsed))
    end
end

function _handle_diag_stop(params)
    t0 = time_ns()
    try
        compile_watch_stop!()
        elapsed = time_ns() - t0
        return Dict("status" => "ok", "time_ns" => elapsed)
    catch e
        elapsed = time_ns() - t0
        return merge(_err(sprint(showerror, e)), Dict("time_ns" => elapsed))
    end
end

function _handle_diag_report(params)
    try
        return compile_watch_wire_snapshot()
    catch e
        return _err(sprint(showerror, e))
    end
end

function _ipc_handler_table()
    [
        ("compile", _handle_compile),
        ("counters", _handle_counters),
        ("swap", _handle_swap),
        ("reload", _handle_reload),
        ("status", _handle_status),
        ("source_map", _handle_source_map),
        ("breakpoint_map", _handle_breakpoint_map),
        ("debug_info", _handle_debug_info),
        ("use", _handle_use),
        ("lazy_status", _handle_lazy_status),
        ("timeline", _handle_timeline),
        ("dev_mode", _handle_dev_mode),
        ("package_tier", _handle_package_tier),
        ("promote_all", _handle_promote_all),
        ("apply_preferences", _handle_apply_preferences),
        ("promote", _handle_promote),
        ("source_push", _handle_source_push),
        ("source_invalidate", _handle_source_invalidate),
        ("diag_start", _handle_diag_start),
        ("diag_stop", _handle_diag_stop),
        ("diag_report", _handle_diag_report),
    ]
end

end # module

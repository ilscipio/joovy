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

    abs_path = abspath(file)
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
    ]
end

end # module

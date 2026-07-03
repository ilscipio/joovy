module IpcBridge

using ..DynCompiler
using ..HotSwap
using ..ExprCache
using ..Debug

export joovy_register_ipc_handlers!, joovy_ipc_available

const _ipc_registered = Ref{Bool}(false)

function joovy_ipc_available()
    isdefined(Main, :FlexibleIPC) &&
    isdefined(Main.FlexibleIPC, :register_handler)
end

function joovy_register_ipc_handlers!()
    joovy_ipc_available() || return false
    _ipc_registered[] && return true

    ipc = Main.FlexibleIPC

    ipc.register_handler("joovy/compile", function(params)
        return Base.invokelatest(_handle_compile, params)
    end)

    ipc.register_handler("joovy/swap", function(params)
        return Base.invokelatest(_handle_swap, params)
    end)

    ipc.register_handler("joovy/reload", function(params)
        return Base.invokelatest(_handle_reload, params)
    end)

    ipc.register_handler("joovy/status", function(params)
        return Base.invokelatest(_handle_status, params)
    end)

    ipc.register_handler("joovy/source_map", function(params)
        return Base.invokelatest(_handle_source_map, params)
    end)

    ipc.register_handler("joovy/breakpoint_map", function(params)
        return Base.invokelatest(_handle_breakpoint_map, params)
    end)

    ipc.register_handler("joovy/debug_info", function(params)
        return Base.invokelatest(_handle_debug_info, params)
    end)

    _ipc_registered[] = true
    _notify("joovy/ready", Dict("version" => "0.1.0"))
    return true
end

function _notify(method::String, params::Dict)
    if joovy_ipc_available() && isdefined(Main.FlexibleIPC, :send_notification)
        try
            Main.FlexibleIPC.send_notification(method, params)
        catch
        end
    end
end

function _handle_compile(params)
    code = get(params, "code", "")
    isempty(code) && return Dict("error" => "Missing code parameter")
    name_str = get(params, "name", nothing)
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
        err = Dict("status" => "error", "error" => sprint(showerror, e),
                    "time_ns" => elapsed)
        _notify("joovy/error", err)
        return err
    end
end

function _handle_swap(params)
    name_str = get(params, "name", "")
    isempty(name_str) && return Dict("error" => "Missing name parameter")
    code = get(params, "code", "")
    isempty(code) && return Dict("error" => "Missing code parameter")
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
        err = Dict("status" => "error", "error" => sprint(showerror, e),
                    "name" => name_str, "time_ns" => elapsed)
        _notify("joovy/error", err)
        return err
    end
end

function _handle_reload(params)
    file = get(params, "file", "")
    isempty(file) && return Dict("error" => "Missing file parameter")

    t0 = time_ns()
    try
        result = joovy_hot_reload(file)
        elapsed = time_ns() - t0
        resp = Dict(
            "status" => result.status,
            "file" => file,
            "reloaded" => [string(n) for n in result.reloaded],
            "unchanged" => [string(n) for n in result.unchanged],
            "fallback_definitions" => result.fallback_definitions,
            "time_ns" => elapsed
        )
        if result.error !== nothing
            resp["error"] = result.error
        end
        _notify("joovy/swap_status", resp)
        return resp
    catch e
        elapsed = time_ns() - t0
        err = Dict("status" => "error", "error" => sprint(showerror, e),
                    "file" => file, "time_ns" => elapsed)
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
    name_str = get(params, "name", "")
    isempty(name_str) && return Dict("error" => "Missing name parameter")
    name = Symbol(name_str)

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
end

function _handle_breakpoint_map(params)
    file = get(params, "file", "")
    isempty(file) && return Dict("error" => "Missing file parameter")
    line = get(params, "line", 0)
    line == 0 && return Dict("error" => "Missing line parameter")

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
end

function _handle_debug_info(params)
    name_str = get(params, "name", "")
    isempty(name_str) && return Dict("error" => "Missing name parameter")
    name = Symbol(name_str)

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
end

end # module

module Integration

using ..DynCompiler
using ..HotSwap
using ..StaticCompile
using ..CompileTimeline
using ..TieredCompile
using ..MemoryManager
using ..LazyModules
using ..PackageTier
using ..ExprCache
using ..AutoTune
using ..Debug
using ..IpcBridge

export JoovySession, session_compile, session_swap!, session_status,
       session_eval, session_reset!, session_hot_reload, session_connect_ide!,
       session_lock!, session_unlock!, session_callsite,
       session_compile_tiered, session_use, session_compile_timeline

mutable struct JoovySession
    registry::HotSwapRegistry
    compile_log::Vector{NamedTuple{(:name, :time_ns, :cached), Tuple{Symbol, UInt64, Bool}}}
    ide_connected::Bool
    lock::ReentrantLock

    JoovySession() = new(HotSwapRegistry(), [], false, ReentrantLock())
end

function session_compile(session::JoovySession, code::String;
                         name::Union{Symbol,Nothing}=nothing, mod::Module=Main)
    t0 = time_ns()
    cached = cache_get(GLOBAL_CACHE, code) !== nothing
    result = joovy_compile(code; name=name, mod=mod)
    elapsed = time_ns() - t0

    if name !== nothing
        lock(session.lock) do
            push!(session.compile_log, (name=name, time_ns=elapsed, cached=cached))
        end
    end

    return result
end

function session_swap!(session::JoovySession, name::Symbol, code::String;
                       mod::Module=Main)
    hotswap_swap!(name, code; registry=session.registry, mod=mod)
end

function session_eval(session::JoovySession, code::String; mod::Module=Main)
    t0 = time_ns()
    try
        expr = Meta.parse("begin\n$code\nend")
        result = Core.eval(mod, expr)
        elapsed = time_ns() - t0
        return (value=result, success=true, error=nothing, elapsed_ns=elapsed)
    catch e
        elapsed = time_ns() - t0
        return (value=nothing, success=false, error=e, elapsed_ns=elapsed)
    end
end

function session_hot_reload(session::JoovySession, file::String; mod::Module=Main)
    joovy_hot_reload(file; registry=session.registry, mod=mod)
end

function session_connect_ide!(session::JoovySession)
    if joovy_ipc_available()
        joovy_register_ipc_handlers!()
        session.ide_connected = true
        return true
    end
    return false
end

function session_status(session::JoovySession)
    stats = compilation_stats()
    registry = session.registry

    entries = lock(registry.lock) do
        Dict(k => (version=v.version, has_file=v.file_path !== nothing)
             for (k, v) in registry.entries)
    end

    log = lock(session.lock) do
        copy(session.compile_log)
    end

    source_maps = lock(DynCompiler._source_map_lock) do
        Dict(k => (original=v.original_names, compiled=v.compiled_names,
                    file=v.source_file, id=v.compile_id)
             for (k, v) in GLOBAL_SOURCE_MAP)
    end

    return (
        cache_hits=stats.content_hits,
        cache_misses=stats.content_misses,
        cache_entries=stats.total_entries,
        registered_functions=entries,
        source_maps=source_maps,
        compile_log=log,
        ide_connected=session.ide_connected
    )
end

function session_reset!(session::JoovySession)
    lock(session.lock) do
        empty!(session.compile_log)
    end
    lock(session.registry.lock) do
        empty!(session.registry.entries)
    end
    lock(DynCompiler._source_map_lock) do
        empty!(GLOBAL_SOURCE_MAP)
    end
end

function session_lock!(session::JoovySession, name::Symbol; mod::Module=Main)
    joovy_lock!(name; mod=mod)
end

function session_unlock!(session::JoovySession, name::Symbol)
    joovy_unlock!(name)
end

function session_callsite(session::JoovySession, name::Symbol)
    joovy_callsite(name; registry=session.registry)
end

function session_compile_tiered(session::JoovySession, code::String;
                                name::Union{Symbol,Nothing}=nothing,
                                tier::Int=1, mod::Module=Main)
    t0 = time_ns()
    result = joovy_compile_tiered(code; tier=tier, name=name, mod=mod)
    elapsed = time_ns() - t0

    if name !== nothing
        lock(session.lock) do
            push!(session.compile_log, (name=name, time_ns=elapsed, cached=false))
        end
    end
    return result
end

function session_use(session::JoovySession, path::String;
                     tier::Int=1, mod::Module=Main)
    joovy_use(path; mod=mod, tier=tier)
end

function session_compile_timeline(session::JoovySession)
    compile_timeline()
end

end # module

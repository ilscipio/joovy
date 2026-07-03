module Integration

using ..DynCompiler
using ..HotSwap
using ..ExprCache
using ..AutoTune

export JoovySession, session_compile, session_swap!, session_status,
       session_eval, session_reset!

mutable struct JoovySession
    registry::HotSwapRegistry
    compile_log::Vector{NamedTuple{(:name, :time_ns, :cached), Tuple{Symbol, UInt64, Bool}}}
    lock::ReentrantLock

    JoovySession() = new(HotSwapRegistry(), [], ReentrantLock())
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

    return (
        cache_hits=stats.content_hits,
        cache_misses=stats.content_misses,
        cache_entries=stats.total_entries,
        registered_functions=entries,
        compile_log=log
    )
end

function session_reset!(session::JoovySession)
    lock(session.lock) do
        empty!(session.compile_log)
    end
    lock(session.registry.lock) do
        empty!(session.registry.entries)
    end
end

end # module

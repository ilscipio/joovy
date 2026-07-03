module ScriptEngine

using ..DynCompiler

export JoovyEngine, joovy_run, joovy_run_file, joovy_watch!, joovy_unwatch!,
       EngineResult

struct EngineConfig
    sandbox::Bool
    allowed_modules::Vector{Symbol}
end

mutable struct JoovyEngine
    config::EngineConfig
    sandbox_mod::Module
    watched_files::Dict{String, Float64}
    active_watchers::Dict{String, Bool}
    lock::ReentrantLock

    function JoovyEngine(;
        sandbox::Bool=true,
        allowed_modules::Vector{Symbol}=[:Base, :Core]
    )
        cfg = EngineConfig(sandbox, allowed_modules)
        mod = Module(:JoovySandbox)

        if sandbox
            for m in allowed_modules
                try
                    Core.eval(mod, :(using $m))
                catch
                end
            end
        end

        new(cfg, mod, Dict{String,Float64}(), Dict{String,Bool}(), ReentrantLock())
    end
end

struct EngineResult
    value::Any
    success::Bool
    error::Union{Exception, Nothing}
    elapsed_ns::UInt64
end

function joovy_run(engine::JoovyEngine, code::String;
                   bindings::Dict{Symbol,Any}=Dict{Symbol,Any}())
    mod = engine.config.sandbox ? engine.sandbox_mod : Main

    for (k, v) in bindings
        Core.eval(mod, :($k = $v))
    end

    t0 = time_ns()
    try
        expr = Meta.parse("begin\n$code\nend")
        result = Core.eval(mod, expr)
        elapsed = time_ns() - t0
        return EngineResult(result, true, nothing, elapsed)
    catch e
        elapsed = time_ns() - t0
        return EngineResult(nothing, false, e, elapsed)
    end
end

function joovy_run_file(engine::JoovyEngine, path::String;
                        bindings::Dict{Symbol,Any}=Dict{Symbol,Any}())
    if !isfile(path)
        return EngineResult(nothing, false, ErrorException("File not found: $path"), UInt64(0))
    end
    code = read(path, String)
    return joovy_run(engine, code; bindings=bindings)
end

function joovy_watch!(engine::JoovyEngine, path::String, callback::Function)
    if !isfile(path)
        error("File not found: $path")
    end

    mtime_val = mtime(path)

    lock(engine.lock) do
        engine.watched_files[path] = mtime_val
        engine.active_watchers[path] = true
    end

    @async begin
        while true
            sleep(0.5)

            active = lock(engine.lock) do
                get(engine.active_watchers, path, false)
            end
            if !active || !isfile(path)
                break
            end

            current_mtime = mtime(path)
            old_mtime = lock(engine.lock) do
                get(engine.watched_files, path, 0.0)
            end

            if current_mtime > old_mtime
                lock(engine.lock) do
                    engine.watched_files[path] = current_mtime
                end
                try
                    code = read(path, String)
                    result = joovy_run(engine, code)
                    callback(result)
                catch e
                    callback(EngineResult(nothing, false, e, UInt64(0)))
                end
            end
        end
    end

    return nothing
end

function joovy_unwatch!(engine::JoovyEngine, path::String)
    lock(engine.lock) do
        engine.active_watchers[path] = false
        delete!(engine.watched_files, path)
    end
end

end # module

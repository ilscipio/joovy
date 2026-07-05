module HotSwap

using ..ExprCache
using ..DynCompiler

export HotSwapRegistry, SwapEntry, hotswap_register!, hotswap_swap!,
       hotswap_call, hotswap_load_file!, hotswap_reload!, hotswap_version,
       hotswap_history, GLOBAL_REGISTRY

const _swap_guard_hooks = Function[]
const _swap_guard_hooks_lock = ReentrantLock()

function _check_swap_guards(name::Symbol)
    lock(_swap_guard_hooks_lock) do
        for hook in _swap_guard_hooks
            hook(name)
        end
    end
end

mutable struct SwapEntry
    name::Symbol
    current_fn::Any
    version::Int
    source::String
    file_path::Union{String, Nothing}
    history::Vector{Pair{Int, String}}
    lock::ReentrantLock
end

mutable struct HotSwapRegistry
    entries::Dict{Symbol, SwapEntry}
    lock::ReentrantLock

    HotSwapRegistry() = new(Dict{Symbol, SwapEntry}(), ReentrantLock())
end

const GLOBAL_REGISTRY = HotSwapRegistry()

function hotswap_register!(name::Symbol, code::String;
                           registry::HotSwapRegistry=GLOBAL_REGISTRY,
                           mod::Module=Main)
    compiled = joovy_compile(code; name=name, mod=mod)

    entry = SwapEntry(
        name, compiled, 1, code, nothing,
        [1 => code],
        ReentrantLock()
    )

    lock(registry.lock) do
        registry.entries[name] = entry
    end

    return compiled
end

function hotswap_register!(name::Symbol, expr::Expr;
                           registry::HotSwapRegistry=GLOBAL_REGISTRY,
                           mod::Module=Main)
    hotswap_register!(name, string(expr); registry=registry, mod=mod)
end

function hotswap_swap!(name::Symbol, new_code::String;
                       registry::HotSwapRegistry=GLOBAL_REGISTRY,
                       mod::Module=Main)
    _check_swap_guards(name)

    entry = lock(registry.lock) do
        get(registry.entries, name, nothing)
    end

    if entry === nothing
        error("No hot-swappable function registered as :$name")
    end

    new_compiled = joovy_recompile!(name, new_code; mod=mod)

    lock(entry.lock) do
        entry.version += 1
        entry.current_fn = new_compiled
        entry.source = new_code
        push!(entry.history, entry.version => new_code)
    end

    return new_compiled
end

function hotswap_swap!(name::Symbol, expr::Expr;
                       registry::HotSwapRegistry=GLOBAL_REGISTRY,
                       mod::Module=Main)
    hotswap_swap!(name, string(expr); registry=registry, mod=mod)
end

function hotswap_call(name::Symbol, args...;
                      registry::HotSwapRegistry=GLOBAL_REGISTRY,
                      kwargs...)
    entry = lock(registry.lock) do
        get(registry.entries, name, nothing)
    end

    if entry === nothing
        error("No hot-swappable function registered as :$name")
    end

    fn = lock(entry.lock) do
        entry.current_fn
    end

    return fn(args...; kwargs...)
end

function hotswap_load_file!(name::Symbol, path::String;
                            registry::HotSwapRegistry=GLOBAL_REGISTRY,
                            mod::Module=Main)
    if !isfile(path)
        error("File not found: $path")
    end

    code = read(path, String)
    compiled = joovy_compile(code; name=name, mod=mod)

    entry = SwapEntry(
        name, compiled, 1, code, path,
        [1 => code],
        ReentrantLock()
    )

    lock(registry.lock) do
        registry.entries[name] = entry
    end

    return compiled
end

function hotswap_reload!(name::Symbol;
                         registry::HotSwapRegistry=GLOBAL_REGISTRY,
                         mod::Module=Main)
    entry = lock(registry.lock) do
        get(registry.entries, name, nothing)
    end

    if entry === nothing
        error("No hot-swappable function registered as :$name")
    end

    path = lock(entry.lock) do
        entry.file_path
    end

    if path === nothing
        error("Function :$name was not loaded from a file")
    end

    if !isfile(path)
        error("File not found: $path")
    end

    new_code = read(path, String)

    old_code = lock(entry.lock) do
        entry.source
    end

    if new_code == old_code
        return lock(entry.lock) do
            entry.current_fn
        end
    end

    new_compiled = joovy_recompile!(name, new_code; mod=mod)

    lock(entry.lock) do
        entry.version += 1
        entry.current_fn = new_compiled
        entry.source = new_code
        push!(entry.history, entry.version => new_code)
    end

    return new_compiled
end

function hotswap_version(name::Symbol;
                         registry::HotSwapRegistry=GLOBAL_REGISTRY)
    entry = lock(registry.lock) do
        get(registry.entries, name, nothing)
    end
    if entry === nothing
        return 0
    end
    return lock(entry.lock) do
        entry.version
    end
end

function hotswap_history(name::Symbol;
                         registry::HotSwapRegistry=GLOBAL_REGISTRY)
    entry = lock(registry.lock) do
        get(registry.entries, name, nothing)
    end
    if entry === nothing
        return Pair{Int,String}[]
    end
    return lock(entry.lock) do
        copy(entry.history)
    end
end

end # module

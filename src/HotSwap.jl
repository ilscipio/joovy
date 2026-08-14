module HotSwap

using ..ExprCache
using ..DynCompiler

export HotSwapRegistry, SwapEntry, hotswap_register!, hotswap_swap!,
       hotswap_call, hotswap_load_file!, hotswap_reload!, hotswap_reload_file!,
       hotswap_version, hotswap_history, GLOBAL_REGISTRY

const _swap_guard_hooks = Function[]
const _swap_guard_hooks_lock = ReentrantLock()

# Set by the TypedInterp submodule (include-order forbids importing it here) to a
# zero-argument function. Fired after a swap installs a new body, so no interpreter keeps
# executing typed IR that was inferred from the retired definition.
const _cache_flush_hook = Ref{Any}(nothing)

function _fire_cache_flush()
    hook = _cache_flush_hook[]
    hook === nothing && return nothing
    try
        hook()
    catch
    end
    return nothing
end

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

    _fire_cache_flush()
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

# Reload ALL SwapEntries backed by `file` with a SINGLE parse + SINGLE compile of the
# whole file, instead of recompiling the file once per entry (as looping `hotswap_reload!`
# over each entry would do). Each entry's own compiled symbol is looked up by matching the
# entry's registry `name` against the shared SourceMapping produced by that one compile, so
# every entry gets ITS OWN function rather than all entries silently aliasing the file's
# first function.
#
# Convention: an entry's registry name must match the name of the definition it tracks
# inside the file (this is how the IDE registers per-definition entries). If a changed
# entry's name cannot be resolved in the fresh compile's SourceMapping, that is a usage
# error and raises.
function hotswap_reload_file!(file::String;
                              registry::HotSwapRegistry=GLOBAL_REGISTRY,
                              mod::Module=Main)
    file = abspath(file)
    if !isfile(file)
        error("File not found: $file")
    end

    new_source = read(file, String)

    matching = Tuple{Symbol,SwapEntry}[]
    lock(registry.lock) do
        for (name, entry) in registry.entries
            entry_path = entry.file_path
            entry_path === nothing && continue
            if abspath(entry_path) == file
                push!(matching, (name, entry))
            end
        end
    end

    reloaded = Symbol[]
    unchanged = Symbol[]
    changed_entries = Tuple{Symbol,SwapEntry}[]

    for (name, entry) in matching
        old_source = lock(entry.lock) do
            entry.source
        end
        if new_source != old_source
            push!(reloaded, name)
            push!(changed_entries, (name, entry))
        else
            push!(unchanged, name)
        end
    end

    if !isempty(changed_entries)
        expr = Meta.parse("begin\n" * new_source * "\nend")
        compile_expr_raw(mod, expr, file)

        for (name, entry) in changed_entries
            mapping = source_map_lookup(name)
            mapping === nothing &&
                error("hotswap_reload_file!: no compiled definition named :$name found in $file")

            idx = findfirst(==(name), mapping.original_names)
            idx === nothing &&
                error("hotswap_reload_file!: no compiled definition named :$name found in $file")

            renamed = mapping.compiled_names[idx]
            fn = JoovyCallable(Base.invokelatest(getfield, mod, renamed))

            lock(entry.lock) do
                entry.version += 1
                entry.current_fn = fn
                entry.source = new_source
                push!(entry.history, entry.version => new_source)
            end
        end
        # This path installs new bodies through `compile_expr_raw`, which never reaches
        # `joovy_recompile!`, so it has to flush the typed-IR cache itself.
        _fire_cache_flush()
    end

    return (reloaded=reloaded, unchanged=unchanged)
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

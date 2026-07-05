module StaticCompile

using ..DynCompiler
using ..HotSwap

export TypedJoovyCallable, FullyTypedJoovyCallable,
       JoovyCallSite, joovy_lock!, joovy_unlock!, joovy_is_locked,
       joovy_callsite, joovy_compile_typed

# ===================================================================
# Static Lock - equivalent of Groovy's @CompileStatic
# ===================================================================

const _locked_functions = Set{Symbol}()
const _locked_lock = ReentrantLock()

function joovy_lock!(name::Symbol; mod::Module=Main)
    mapping = source_map_lookup(name)
    if mapping === nothing
        error("No compiled function found for :$name in source map")
    end

    idx = findfirst(==(name), mapping.original_names)
    if idx === nothing
        idx = findfirst(==(name), mapping.compiled_names)
        if idx === nothing
            error("Cannot resolve compiled name for :$name")
        end
        compiled_name = name
    else
        compiled_name = mapping.compiled_names[idx]
    end

    fn = Base.invokelatest(getfield, mod, compiled_name)

    lock(_locked_lock) do
        push!(_locked_functions, name)
    end

    return fn
end

function joovy_unlock!(name::Symbol)
    lock(_locked_lock) do
        delete!(_locked_functions, name)
    end
    return nothing
end

function joovy_is_locked(name::Symbol)
    lock(_locked_lock) do
        name in _locked_functions
    end
end

function _locked_guard(name::Symbol)
    if joovy_is_locked(name)
        error("Cannot swap locked function :$name. Call joovy_unlock!(:$name) first.")
    end
end

function __init__()
    lock(HotSwap._swap_guard_hooks_lock) do
        push!(HotSwap._swap_guard_hooks, _locked_guard)
    end
end

# ===================================================================
# Typed Compilation - equivalent of Groovy's optional typing
# ===================================================================

struct TypedJoovyCallable{R} <: AbstractJoovyCallable
    fn::Any
end

@inline function (tc::TypedJoovyCallable{R})(args...; kwargs...) where R
    Base.invokelatest(tc.fn, args...; kwargs...)::R
end

struct FullyTypedJoovyCallable{R, Args<:Tuple} <: AbstractJoovyCallable
    fn::Any
end

@inline function (tc::FullyTypedJoovyCallable{R, Args})(args...; kwargs...) where {R, Args}
    Base.invokelatest(tc.fn, args...; kwargs...)::R
end

function joovy_compile_typed(code::String;
                             name::Union{Symbol,Nothing}=nothing,
                             mod::Module=Main,
                             returns::Union{Type,Nothing}=nothing,
                             signature::Union{Type{<:Tuple},Nothing}=nothing)
    compiled = joovy_compile(code; name=name, mod=mod)

    if returns === nothing
        return compiled
    end

    raw_fn = compiled isa JoovyCallable ? compiled.fn : compiled

    if signature !== nothing
        return FullyTypedJoovyCallable{returns, signature}(raw_fn)
    else
        return TypedJoovyCallable{returns}(raw_fn)
    end
end

function joovy_compile_typed(expr::Expr;
                             name::Union{Symbol,Nothing}=nothing,
                             mod::Module=Main,
                             returns::Union{Type,Nothing}=nothing,
                             signature::Union{Type{<:Tuple},Nothing}=nothing)
    compiled = joovy_compile(expr; name=name, mod=mod)

    if returns === nothing
        return compiled
    end

    raw_fn = compiled isa JoovyCallable ? compiled.fn : compiled

    if signature !== nothing
        return FullyTypedJoovyCallable{returns, signature}(raw_fn)
    else
        return TypedJoovyCallable{returns}(raw_fn)
    end
end

# ===================================================================
# Call-Site Caching - equivalent of Groovy's CallSite / invokedynamic
# ===================================================================

mutable struct JoovyCallSite
    entry::SwapEntry
    cached_fn::Any
    cached_version::Int
end

function joovy_callsite(name::Symbol; registry::HotSwapRegistry=GLOBAL_REGISTRY)
    entry = lock(registry.lock) do
        get(registry.entries, name, nothing)
    end

    if entry === nothing
        error("No hot-swappable function registered as :$name")
    end

    fn, ver = lock(entry.lock) do
        entry.current_fn, entry.version
    end

    return JoovyCallSite(entry, fn, ver)
end

@inline function (cs::JoovyCallSite)(args...; kwargs...)
    current_version = cs.entry.version
    if current_version != cs.cached_version
        fn = lock(cs.entry.lock) do
            cs.entry.current_fn
        end
        cs.cached_fn = fn
        cs.cached_version = current_version
    end

    fn = cs.cached_fn
    if fn isa AbstractJoovyCallable
        return fn(args...; kwargs...)
    else
        return Base.invokelatest(fn, args...; kwargs...)
    end
end

end # module

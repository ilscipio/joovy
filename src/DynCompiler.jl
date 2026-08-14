module DynCompiler

using ..ExprCache
using ..WorldAgeBridge

export joovy_compile, joovy_compile_file, joovy_recompile!,
       compilation_stats, GLOBAL_CACHE, AbstractJoovyCallable, JoovyCallable,
       GLOBAL_SOURCE_MAP, SourceMapping, source_map_lookup, source_map_reverse,
       compile_expr_raw, extract_function_names

const GLOBAL_CACHE = JoovyCache()

const _compile_counter = Ref{Int}(0)

# Set by the TypedInterp submodule (include-order forbids importing it here) to a
# zero-argument function. Fired after every recompilation, because redefining a function
# invalidates any typed IR cached against the old definition.
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

abstract type AbstractJoovyCallable end

struct JoovyCallable <: AbstractJoovyCallable
    fn::Any
end

@inline function (jc::JoovyCallable)(args...; kwargs...)
    Base.invokelatest(jc.fn, args...; kwargs...)
end

struct SourceMapping
    original_names::Vector{Symbol}
    compiled_names::Vector{Symbol}
    source_file::Union{String, Nothing}
    source_code::Union{String, Nothing}
    compile_id::Int
end

const GLOBAL_SOURCE_MAP = Dict{Symbol, SourceMapping}()
const _source_map_lock = ReentrantLock()

function source_map_lookup(original_name::Symbol)
    lock(_source_map_lock) do
        get(GLOBAL_SOURCE_MAP, original_name, nothing)
    end
end

function source_map_reverse(compiled_name::Symbol)
    s = string(compiled_name)
    m = match(r"^(.+)_joovy_\d+$", s)
    m === nothing && return nothing
    return Symbol(m.captures[1])
end

function joovy_compile(code::String; name::Union{Symbol,Nothing}=nothing, mod::Module=Main)
    existing = cache_get(GLOBAL_CACHE, code)
    if existing !== nothing && name === nothing
        return existing
    end

    t0 = time_ns()
    expr = Meta.parse("begin\n$code\nend")
    compiled_fn = _compile_expr(mod, expr, nothing)
    elapsed = time_ns() - t0

    h = cache_put!(GLOBAL_CACHE, code, compiled_fn)

    if name !== nothing
        cache_register!(GLOBAL_CACHE, name, code)
    end

    return compiled_fn
end

function joovy_compile(expr::Expr; name::Union{Symbol,Nothing}=nothing, mod::Module=Main)
    existing = cache_get(GLOBAL_CACHE, expr)
    if existing !== nothing && name === nothing
        return existing
    end

    t0 = time_ns()
    compiled_fn = _compile_expr(mod, expr, nothing)
    elapsed = time_ns() - t0

    h = cache_put!(GLOBAL_CACHE, expr, compiled_fn)

    if name !== nothing
        cache_register!(GLOBAL_CACHE, name, expr)
    end

    return compiled_fn
end

function joovy_compile_file(path::String; name::Union{Symbol,Nothing}=nothing, mod::Module=Main)
    if !isfile(path)
        error("File not found: $path")
    end
    code = read(path, String)
    fname = name === nothing ? Symbol(splitext(basename(path))[1]) : name
    return joovy_compile(code; name=fname, mod=mod)
end

function joovy_recompile!(name::Symbol, code::String; mod::Module=Main)
    t0 = time_ns()
    expr = Meta.parse("begin\n$code\nend")
    compiled_fn = _compile_expr(mod, expr, nothing)
    elapsed = time_ns() - t0

    h = cache_put!(GLOBAL_CACHE, code, compiled_fn)
    cache_register!(GLOBAL_CACHE, name, code)

    _fire_cache_flush()
    return compiled_fn
end

function joovy_recompile!(name::Symbol, expr::Expr; mod::Module=Main)
    t0 = time_ns()
    compiled_fn = _compile_expr(mod, expr, nothing)
    elapsed = time_ns() - t0

    h = cache_put!(GLOBAL_CACHE, expr, compiled_fn)
    cache_register!(GLOBAL_CACHE, name, expr)

    _fire_cache_flush()
    return compiled_fn
end

function _wrap_fn(mod::Module, name::Symbol)
    fn = Base.invokelatest(getfield, mod, name)
    JoovyCallable(fn)
end

function _wrap_result(result)
    result isa Function ? JoovyCallable(result) : result
end

function _compile_expr(mod::Module, expr::Expr, source_file::Union{String, Nothing})
    fnames = _extract_all_function_names(expr)

    if !isempty(fnames)
        _compile_counter[] += 1
        suffix = _compile_counter[]
        mapping = Dict{Symbol,Symbol}(n => Symbol(n, :_joovy_, suffix) for n in fnames)
        expr = _replace_names(expr, mapping)
        renamed = Symbol[mapping[f] for f in fnames]
        Core.eval(mod, expr)

        sm = SourceMapping(fnames, renamed, source_file, nothing, suffix)
        lock(_source_map_lock) do
            for (orig, comp) in zip(fnames, renamed)
                GLOBAL_SOURCE_MAP[orig] = sm
                GLOBAL_SOURCE_MAP[comp] = sm
            end
        end

        primary = renamed[1]
        return _wrap_fn(mod, primary)
    end

    result = Core.eval(mod, expr)
    return _wrap_result(result)
end

function _replace_names(expr::Expr, mapping::Dict{Symbol,Symbol})
    new_args = Any[
        arg isa Symbol && haskey(mapping, arg) ? mapping[arg] :
        arg isa Expr ? _replace_names(arg, mapping) : arg
        for arg in expr.args
    ]
    Expr(expr.head, new_args...)
end

_replace_names(x, ::Dict{Symbol,Symbol}) = x

function _extract_all_function_names(expr::Expr)
    names = Symbol[]
    _walk_for_functions!(expr, names)
    return names
end

function _walk_for_functions!(expr::Expr, names::Vector{Symbol})
    if (expr.head === :function || expr.head === :(=)) && length(expr.args) >= 1
        lhs = expr.args[1]
        if lhs isa Expr && lhs.head === :call && length(lhs.args) >= 1 && lhs.args[1] isa Symbol
            push!(names, lhs.args[1]::Symbol)
        end
    end
    for arg in expr.args
        if arg isa Expr
            _walk_for_functions!(arg, names)
        end
    end
end

function compilation_stats()
    return cache_stats(GLOBAL_CACHE)
end

compile_expr_raw(mod::Module, expr::Expr, source_file::Union{String, Nothing}) =
    _compile_expr(mod, expr, source_file)

extract_function_names(expr::Expr) = _extract_all_function_names(expr)

end # module

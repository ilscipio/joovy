module DynCompiler

using ..ExprCache
using ..WorldAgeBridge

export joovy_compile, joovy_compile_file, joovy_recompile!, CompiledUnit,
       compilation_stats, GLOBAL_CACHE, JoovyCallable

const GLOBAL_CACHE = JoovyCache()

const _compile_counter = Ref{Int}(0)

struct JoovyCallable
    fn::Any
end

@inline function (jc::JoovyCallable)(args...; kwargs...)
    Base.invokelatest(jc.fn, args...; kwargs...)
end

mutable struct CompiledUnit
    name::Union{Symbol, Nothing}
    source::String
    expr::Expr
    compiled_fn::Any
    mod::Module
    compile_time_ns::UInt64
    call_count::Int
    hash::String
end

function joovy_compile(code::String; name::Union{Symbol,Nothing}=nothing, mod::Module=Main)
    existing = cache_get(GLOBAL_CACHE, code)
    if existing !== nothing && name === nothing
        return existing
    end

    t0 = time_ns()
    expr = Meta.parse("begin\n$code\nend")
    compiled_fn = _compile_expr(mod, expr)
    elapsed = time_ns() - t0

    h = cache_put!(GLOBAL_CACHE, code, compiled_fn)

    unit = CompiledUnit(name, code, expr, compiled_fn, mod, elapsed, 0, h)

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
    compiled_fn = _compile_expr(mod, expr)
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
    compiled_fn = _compile_expr(mod, expr)
    elapsed = time_ns() - t0

    h = cache_put!(GLOBAL_CACHE, code, compiled_fn)
    cache_register!(GLOBAL_CACHE, name, code)

    return compiled_fn
end

function joovy_recompile!(name::Symbol, expr::Expr; mod::Module=Main)
    t0 = time_ns()
    compiled_fn = _compile_expr(mod, expr)
    elapsed = time_ns() - t0

    h = cache_put!(GLOBAL_CACHE, expr, compiled_fn)
    cache_register!(GLOBAL_CACHE, name, expr)

    return compiled_fn
end

function _wrap_fn(mod::Module, name::Symbol)
    fn = Base.invokelatest(getfield, mod, name)
    JoovyCallable(fn)
end

function _wrap_result(result)
    result isa Function ? JoovyCallable(result) : result
end

function _compile_expr(mod::Module, expr::Expr)
    fnames = _extract_all_function_names(expr)

    if !isempty(fnames)
        _compile_counter[] += 1
        suffix = _compile_counter[]
        expr = _rename_functions(expr, fnames, suffix)
        renamed = [Symbol("$(f)_joovy_$(suffix)") for f in fnames]
        Core.eval(mod, expr)
        primary = renamed[1]
        return _wrap_fn(mod, primary)
    end

    result = Core.eval(mod, expr)
    return _wrap_result(result)
end

function _rename_functions(expr::Expr, original_names::Vector{Symbol}, suffix::Int)
    mapping = Dict(n => Symbol("$(n)_joovy_$(suffix)") for n in original_names)
    _replace_names(expr, mapping)
end

function _replace_names(expr::Expr, mapping::Dict{Symbol,Symbol})
    new_args = []
    for arg in expr.args
        if arg isa Symbol && haskey(mapping, arg)
            push!(new_args, mapping[arg])
        elseif arg isa Expr
            push!(new_args, _replace_names(arg, mapping))
        else
            push!(new_args, arg)
        end
    end
    Expr(expr.head, new_args...)
end

_replace_names(x, ::Dict{Symbol,Symbol}) = x

function _extract_all_function_names(expr::Expr)
    names = Symbol[]
    _walk_for_functions!(expr, names)
    return names
end

function _walk_for_functions!(expr::Expr, names::Vector{Symbol})
    if expr.head in (:function, :(=))
        fname = _try_extract_fname(expr)
        if fname !== nothing
            push!(names, fname)
        end
    end
    for arg in expr.args
        if arg isa Expr
            _walk_for_functions!(arg, names)
        end
    end
end

function _try_extract_fname(expr::Expr)
    if expr.head === :function || expr.head === :(=)
        lhs = expr.args[1]
        if lhs isa Expr && lhs.head === :call
            name = lhs.args[1]
            return name isa Symbol ? name : nothing
        end
    end
    return nothing
end

function compilation_stats()
    return cache_stats(GLOBAL_CACHE)
end

end # module

module TieredCompile

using ..DynCompiler
using ..CompileTimeline

export TieredCallable, joovy_compile_tiered, promote!, get_tier,
       set_promote_threshold!, tier_stats, set_module_tier!,
       make_tiered_callable

const _tier_compile_lock = ReentrantLock()
const _show_stats = Ref(get(ENV, "JULIA_IDE_JOOVY_STATS", "") == "1")

mutable struct TieredCallable <: AbstractJoovyCallable
    fn::Any
    tier::Int
    call_count::Int
    source_code::String
    name::Symbol
    promote_threshold::Int
    mod::Module
    promoting::Bool
    lock::ReentrantLock
end

@inline function (tc::TieredCallable)(args...; kwargs...)
    tc.call_count += 1
    if tc.tier < 2 && tc.call_count >= tc.promote_threshold && !tc.promoting
        tc.promoting = true
        @async _background_promote!(tc)
    end
    Base.invokelatest(tc.fn, args...; kwargs...)
end

get_tier(tc::TieredCallable) = tc.tier

function set_promote_threshold!(tc::TieredCallable, n::Int)
    tc.promote_threshold = n
    return nothing
end

# ===================================================================
# AST transforms for @nospecialize injection
# ===================================================================

function _add_nospecialize(expr::Expr)
    if expr.head === :function || (expr.head === :(=) && _is_funcdef(expr))
        return _nospec_funcdef(expr)
    end
    new_args = Any[arg isa Expr ? _add_nospecialize(arg) : arg for arg in expr.args]
    return Expr(expr.head, new_args...)
end

_add_nospecialize(x) = x

function _is_funcdef(expr::Expr)
    length(expr.args) >= 1 || return false
    lhs = expr.args[1]
    lhs isa Expr || return false
    lhs.head === :call && return true
    lhs.head === :where && length(lhs.args) >= 1 &&
        lhs.args[1] isa Expr && lhs.args[1].head === :call && return true
    return false
end

function _nospec_funcdef(expr::Expr)
    new_args = copy(expr.args)
    lhs = new_args[1]
    if lhs isa Expr && lhs.head === :where
        inner = lhs.args[1]
        if inner isa Expr && inner.head === :call
            new_inner = _nospec_call_args(inner)
            new_lhs = Expr(lhs.head, new_inner, lhs.args[2:end]...)
            new_args[1] = new_lhs
        end
    elseif lhs isa Expr && lhs.head === :call
        new_args[1] = _nospec_call_args(lhs)
    end
    for i in 2:length(new_args)
        if new_args[i] isa Expr
            new_args[i] = _add_nospecialize(new_args[i])
        end
    end
    return Expr(expr.head, new_args...)
end

function _nospec_call_args(call_expr::Expr)
    new_args = Any[call_expr.args[1]]
    for i in 2:length(call_expr.args)
        arg = call_expr.args[i]
        if arg isa Expr && arg.head === :parameters
            push!(new_args, arg)
        else
            push!(new_args, _wrap_nospecialize(arg))
        end
    end
    return Expr(:call, new_args...)
end

function _wrap_nospecialize(arg)
    if arg isa Expr && arg.head === :kw
        return Expr(:kw, _wrap_nospecialize(arg.args[1]), arg.args[2:end]...)
    end
    return Expr(:macrocall, Symbol("@nospecialize"), LineNumberNode(0), arg)
end

# ===================================================================
# Tier-specific compilation
# ===================================================================

function set_module_tier!(mod::Module, tier::Int)
    if tier == 0
        Core.eval(mod, :(Base.Experimental.@compiler_options compile=min optimize=0))
    elseif tier == 1
        Core.eval(mod, :(Base.Experimental.@optlevel 0))
    else
        Core.eval(mod, :(Base.Experimental.@optlevel 2))
    end
end

function _with_tier(f, mod::Module, tier::Int)
    if tier == 2
        return f()
    end
    lock(_tier_compile_lock) do
        try
            set_module_tier!(mod, tier)
            return f()
        finally
            set_module_tier!(mod, 2)
        end
    end
end

function _compile_at_tier(mod::Module, expr::Expr, tier::Int)
    _with_tier(mod, tier) do
        transformed = tier < 2 ? _add_nospecialize(expr) : expr
        compile_expr_raw(mod, transformed, nothing)
    end
end

function _background_promote!(tc::TieredCallable)
    try
        promote!(tc)
    catch e
        lock(tc.lock) do
            tc.promoting = false
        end
        @warn "Tier promotion failed for $(tc.name)" exception=(e, catch_backtrace())
    end
end

# ===================================================================
# No-rename compilation for LazyModule
# ===================================================================

function compile_in_module!(mod::Module, expr::Expr, name::Symbol, tier::Int)
    _with_tier(mod, tier) do
        transformed = tier < 2 ? _add_nospecialize(expr) : expr
        Core.eval(mod, transformed)
    end
    return Base.invokelatest(getfield, mod, name)
end

function make_tiered_callable(fn, tier::Int, code::String, name::Symbol,
                              mod::Module; promote_threshold::Int=10)
    TieredCallable(fn, tier, 0, code, name, promote_threshold, mod, false, ReentrantLock())
end

# ===================================================================
# Public API
# ===================================================================

function joovy_compile_tiered(code::String; tier::Int=1,
                              name::Union{Symbol,Nothing}=nothing,
                              mod::Module=Main,
                              promote_threshold::Int=10)
    expr = Meta.parse("begin\n$code\nend")
    fnames = extract_function_names(expr)
    actual_name = name !== nothing ? name : (!isempty(fnames) ? first(fnames) : :anonymous)

    t0 = time_ns()
    compiled = _compile_at_tier(mod, expr, tier)
    elapsed = time_ns() - t0

    raw_fn = compiled isa JoovyCallable ? compiled.fn : compiled

    record_compile!(CompileEvent(
        actual_name, tier, UInt64(elapsed), :explicit,
        Symbol[], UInt64(time_ns()), :tiered_compile
    ))

    return make_tiered_callable(raw_fn, tier, code, actual_name, mod;
                                promote_threshold=promote_threshold)
end

function promote!(tc::TieredCallable; tier::Union{Int,Nothing}=nothing)
    target = tier !== nothing ? tier : tc.tier + 1
    target > 2 && return tc
    target <= tc.tier && return tc

    expr = Meta.parse("begin\n$(tc.source_code)\nend")

    t0 = time_ns()
    compiled = _compile_at_tier(tc.mod, expr, target)
    elapsed = time_ns() - t0

    raw_fn = compiled isa JoovyCallable ? compiled.fn : compiled

    record_compile!(CompileEvent(
        tc.name, target, UInt64(elapsed), :promote,
        Symbol[], UInt64(time_ns()), :tiered_compile
    ))

    lock(tc.lock) do
        tc.fn = raw_fn
        tc.tier = target
        tc.call_count = 0
        tc.promoting = false
    end

    if _show_stats[]
        time_str = elapsed < 1_000_000 ? "$(round(elapsed / 1_000; digits=1))μs" : "$(round(elapsed / 1_000_000; digits=2))ms"
        @info "joovy promote: $(tc.name) tier=$(target) $(time_str) calls=$(tc.call_count)"
    end

    return tc
end

function tier_stats()
    timeline = compile_timeline(source=:tiered_compile)
    tier_counts = Dict{Int,Int}()
    tier_times = Dict{Int,UInt64}()
    promotions = 0
    for event in timeline
        tier_counts[event.tier] = get(tier_counts, event.tier, 0) + 1
        tier_times[event.tier] = get(tier_times, event.tier, UInt64(0)) + event.compile_time_ns
        if event.trigger === :promote
            promotions += 1
        end
    end
    return (counts=tier_counts, times=tier_times, promotions=promotions)
end

end # module

module Instrument

# Transparent, zero-annotation execution of plain Julia through Joovy.
#
# `joovy_exec(code)` walks the top-level statements of a code block IN ORDER
# (preserving execution semantics), and for each *simple, cleanly-named* top-level
# function definition it:
#   - keeps it a NORMAL generic function (evaluated without renaming, so multiple
#     dispatch / adding methods / methods() / @which / operator overloads all behave
#     exactly like plain Julia),
#   - compiles it at a low optimization tier for a fast first response,
#   - injects a cheap counter prologue into the body (signature untouched), and
#   - auto-promotes it to native (optlevel 2) once it is hot.
#
# Anything that is not a simple named function def (using/import/const/struct/macro,
# operator/qualified overloads like `Base.:+`, anonymous/do blocks, bare expressions)
# is evaluated VERBATIM into the target module.
#
# Two instrumentation levels:
#   :count  — increment a call counter only (local; drives promotion, ~1 add per call)
#   :full   — call counter + accumulated/median timing (added only when code is
#             dispatched to a machine; streamed back to the IDE in the background)

import ..TieredCompile
import ..LazyModules
import ..PackageTier
import ..ColdLoad
using ..CompileTimeline

export CounterEntry, joovy_exec, instrument_expr, counters_report,
       start_counter_stream!, reset_counters!, alloc_snapshot

const _MAX_SAMPLES = 256
const _PROMOTE_THRESHOLD = Ref{Int}(10)

# Per-function counter. One instance per function NAME; the same instance is both
# stored in `_COUNTERS` (for reporting) and spliced directly into the instrumented
# body as a literal, so the hot path is a plain field increment with no dict lookup.
mutable struct CounterEntry
    name::Symbol
    call_count::Int
    total_ns::UInt64
    samples::Vector{UInt64}   # fixed-capacity ring buffer for median timing
    sample_pos::Int
    sample_n::Int
    tier::Int
    level::Symbol
    promoting::Bool
    total_alloc_bytes::UInt64    # :full only -- sum of per-call Base.gc_num() deltas
    file::Union{Nothing,String}  # absolute path of the def's source, if known
    def_line::Int                # 1-based line of the def's body, 0 if unknown
end

CounterEntry(name::Symbol, level::Symbol, tier::Int) =
    CounterEntry(name, 0, UInt64(0), Vector{UInt64}(undef, _MAX_SAMPLES), 0, 0, tier, level, false,
                 UInt64(0), nothing, 0)

const _COUNTERS = Dict{Symbol, CounterEntry}()
const _COUNTERS_LOCK = ReentrantLock()
const _SOURCE = Dict{Symbol, Vector{Expr}}()   # original (un-instrumented) defs, for promotion
const _EXEC_MOD = Ref{Module}(Main)
const _STREAM_STARTED = Ref{Bool}(false)
const _DIRTY = Ref{Bool}(false)

# Set by the Config submodule to a function `(mod::Symbol, fn::Symbol) -> Union{Int,Nothing}`
# giving a per-function tier override from LocalPreferences.toml (best-effort: applies to
# functions Joovy compiles here). nothing = no override.
const _config_fn_tier_lookup = Ref{Any}(nothing)

# ===================================================================
# Hot-path counter hooks (referenced from instrumented function bodies)
# ===================================================================

@inline function tick(e::CounterEntry)
    e.call_count += 1
    _DIRTY[] = true
    if e.tier < 2 && !e.promoting && e.call_count >= _PROMOTE_THRESHOLD[]
        e.promoting = true
        @async _promote!(e)
    end
    return nothing
end

@inline function record(e::CounterEntry, t0::UInt64)
    dt = time_ns() - t0
    e.total_ns += dt
    p = e.sample_pos % _MAX_SAMPLES + 1
    @inbounds e.samples[p] = dt
    e.sample_pos = p
    e.sample_n < _MAX_SAMPLES && (e.sample_n += 1)
    tick(e)
    return nothing
end

# Same-shape overload used by :full instrumentation, additionally given the
# `Base.gc_num()` snapshot taken right before the wrapped body ran. The
# allocated-bytes delta is computed exactly the way `Base.@allocated` computes
# it pre-1.12 (and the way `@time`/`@timed` still compute it on 1.12): a
# `Base.GC_Diff` of the gc counters before/after, `.allocd` field. This is a
# PROCESS-WIDE counter, not a per-task one, so a call that overlaps another
# task's allocations on the same thread has its delta polluted by that other
# task's bytes too -- an inherent limitation of this mechanism (documented at
# the CompileWatch `allocation-heavy-method` rule that consumes this data),
# not something a cheaper capture point can fix without switching to Julia
# 1.12's newer per-task `Base.gc_bytes` counter (a bigger, riskier change than
# this task calls for).
# @noinline is load-bearing: inlining this body (GC_Diff = ~15 field
# subtractions) into every :full-instrumented def made each hot-reload
# re-eval re-infer and re-codegen it, slowing incremental reload ~4x.
@noinline function record(e::CounterEntry, t0::UInt64, gc0::Base.GC_Num)
    dt = time_ns() - t0
    e.total_ns += dt
    p = e.sample_pos % _MAX_SAMPLES + 1
    @inbounds e.samples[p] = dt
    e.sample_pos = p
    e.sample_n < _MAX_SAMPLES && (e.sample_n += 1)
    gdiff = Base.GC_Diff(Base.gc_num(), gc0)
    bytes = gdiff.allocd
    bytes > 0 && (e.total_alloc_bytes += UInt64(bytes))
    tick(e)
    return nothing
end

# ===================================================================
# AST body-transform (structure mirrors TieredCompile._add_nospecialize)
# Only the function BODY is rewritten; the signature is never touched, so
# dispatch is preserved exactly.
# ===================================================================

function instrument_expr(expr::Expr, e::CounterEntry, level::Symbol)
    if LazyModules._is_function_def(expr)
        return _instrument_funcdef(expr, e, level)
    end
    new_args = Any[arg isa Expr ? instrument_expr(arg, e, level) : arg for arg in expr.args]
    return Expr(expr.head, new_args...)
end

instrument_expr(x, ::CounterEntry, ::Symbol) = x

function _instrument_funcdef(expr::Expr, e::CounterEntry, level::Symbol)
    length(expr.args) >= 2 || return expr   # `function f end` — nothing to wrap
    new_args = copy(expr.args)
    old_body = new_args[2]
    new_args[2] = _wrap_body(old_body, e, level)
    return Expr(expr.head, new_args...)
end

function _wrap_body(old_body, e::CounterEntry, level::Symbol)
    tick_call = Expr(:call, GlobalRef(@__MODULE__, :tick), e)
    if level === :count
        return Expr(:block, tick_call, old_body)
    else
        tsym = gensym(:joovy_t0)
        gcsym = gensym(:joovy_gc0)
        t0_assign = Expr(:(=), tsym, Expr(:call, GlobalRef(Base, :time_ns)))
        gc0_assign = Expr(:(=), gcsym, Expr(:call, GlobalRef(Base, :gc_num)))
        rec_call = Expr(:call, GlobalRef(@__MODULE__, :record), e, tsym, gcsym)
        # value of `try A finally B end` is the value of A → return value preserved
        try_expr = Expr(:try, old_body, false, false, Expr(:block, rec_call))
        return Expr(:block, t0_assign, gc0_assign, try_expr)
    end
end

# ===================================================================
# Demand-driven package tiering — only packages the user actually
# loads (via using/import in their code) get tiered.
# ===================================================================

function _extract_package_names(stmt::Expr)
    names = Symbol[]
    for arg in stmt.args
        arg isa Expr || continue
        if arg.head === :(:) && length(arg.args) >= 1
            src = arg.args[1]
            if src isa Expr && src.head === :(.) && length(src.args) >= 1 && src.args[1] isa Symbol
                push!(names, src.args[1])
            end
        elseif arg.head === :(.) && length(arg.args) >= 1 && arg.args[1] isa Symbol
            push!(names, arg.args[1])
        end
    end
    return names
end

function _tier_package!(name::Symbol, mod::Module, tier::Int)
    name in PackageTier._SKIP_PACKAGES && return
    isdefined(mod, name) || return
    try
        val = getfield(mod, name)
        val isa Module || return
        PackageTier.joovy_use_package(name; tier=tier)
    catch
    end
    return
end

# ===================================================================
# Public entry point — transparent tiered execution of a code block
# ===================================================================

function _promote_all_packages!()
    try
        PackageTier.joovy_promote_loaded!(; tier=2)
    catch
    end
end

function joovy_exec(code::AbstractString; mod::Module=Main, tier::Int=1,
                    instrument::Symbol=:count, stream::Bool=false,
                    path::Union{String,Nothing}=nothing,
                    promote_after::Bool=true)
    _EXEC_MOD[] = mod
    # Parse with the real filename so @__FILE__/@__LINE__ and error stacktraces point at
    # the user's source (matching Base.include_string), and keep the toplevel line nodes.
    fname = path === nothing ? "none" : String(path)
    ast = Meta.parseall(String(code); filename=fname)
    stmts = (ast isa Expr && ast.head in (:block, :toplevel)) ? ast.args : Any[ast]

    # Build ONE :toplevel sequence, preserving original statement order. Evaluating
    # it as a single toplevel unit (rather than statement-by-statement Core.eval)
    # advances world age between statements exactly like include_string does, so the
    # common "define f then call f" cell pattern does not trip Julia 1.12 binding
    # world-age warnings. Simple named function defs are instrumented in place;
    # everything else is left verbatim.
    #
    # For tier < 2 we lower the module optlevel ONLY around each definition (fast
    # compile of the defs) and restore it to 2 immediately after, so the user's own
    # driver code (loops, main, calls) still compiles at native optlevel. This keeps
    # transparent tiering from silently deoptimizing the code around the defs.
    lower = tier < 2
    top = Expr(:toplevel)
    defnames = Symbol[]
    cur_line = 1   # cursor over toplevel LineNumberNode siblings, for CounterEntry.def_line
    for stmt in stmts
        if stmt isa LineNumberNode
            cur_line = stmt.line
            push!(top.args, stmt)
            continue
        end
        # Cold-load optimization: pre-tier all loaded modules BEFORE the using
        # statement, install a synchronous callback that tiers each dependency
        # as it loads, then restore Base/Core after.
        if lower && stmt isa Expr && stmt.head in (:using, :import)
            push!(top.args, :($(GlobalRef(ColdLoad, :prepare_cold_load!))($tier)))
            push!(top.args, stmt)
            for pname in _extract_package_names(stmt)
                push!(top.args, :($(GlobalRef(@__MODULE__, :_tier_package!))($(QuoteNode(pname)), $mod, $tier)))
            end
            push!(top.args, :($(GlobalRef(ColdLoad, :finish_cold_load!))()))
            continue
        end
        name = (stmt isa Expr && LazyModules._is_function_def(stmt)) ?
               LazyModules._extract_def_name(stmt) : nothing
        if name !== nothing && instrument !== :none
            # Per-function tier override from [Joovy] config wins over the session tier
            # for this def (best-effort — only user code Joovy compiles here).
            this_tier = tier
            lk = _config_fn_tier_lookup[]
            if lk !== nothing
                t = try lk(nameof(mod), name) catch; nothing end
                t isa Int && (this_tier = t)
            end
            this_lower = this_tier < 2
            entry = _register_def!(name, stmt, this_tier, instrument;
                                   file=path === nothing ? nothing : abspath(String(path)),
                                   line=cur_line)
            if this_lower
                push!(top.args, Meta.parse("Base.Experimental.@optlevel 0"))
            end
            push!(top.args, instrument_expr(stmt, entry, instrument))
            if this_lower
                push!(top.args, Meta.parse("Base.Experimental.@optlevel 2"))
            end
            push!(defnames, name)
        else
            push!(top.args, stmt)
        end
    end

    # Definitions compile synchronously up front (no yield points between the optlevel
    # toggles), so we do NOT hold the tier lock across the whole eval. That lets
    # background promotion run at the user code's yield points (I/O, sleep) instead of
    # being blocked until the entire run finishes.
    t0 = time_ns()
    result = Core.eval(mod, top)
    elapsed = time_ns() - t0

    if !isempty(defnames)
        per = UInt64(elapsed ÷ length(defnames))
        ts = UInt64(time_ns())
        for name in defnames
            record_compile!(CompileEvent(name, tier, per, :first_call, Symbol[], ts, :joovy_exec))
        end
        _DIRTY[] = true
    end

    if stream
        start_counter_stream!()
        _send_counters()   # flush once so short/batch runs report before exit
    end

    if promote_after && lower
        @async _promote_all_packages!()
    end

    return result
end

function _register_def!(name::Symbol, stmt::Expr, tier::Int, level::Symbol;
                        file::Union{Nothing,String}=nothing, line::Int=0)
    lock(_COUNTERS_LOCK) do
        e = get(_COUNTERS, name, nothing)
        if e === nothing
            e = CounterEntry(name, level, tier)
            _COUNTERS[name] = e
        else
            e.level = level
            e.tier = tier
            e.promoting = false
        end
        e.file = file
        e.def_line = line
        srcs = get!(() -> Expr[], _SOURCE, name)
        push!(srcs, stmt)
        return e
    end
end

# Promote a hot function to native: re-eval the ORIGINAL (un-instrumented) source at
# optlevel 2. Still a normal generic function — just recompiled hot, with the counter
# prologue dropped so the promoted code runs at full native speed.
function _promote!(e::CounterEntry)
    try
        srcs = lock(_COUNTERS_LOCK) do
            copy(get(_SOURCE, e.name, Expr[]))
        end
        isempty(srcs) && return
        mod = _EXEC_MOD[]
        t0 = time_ns()
        # Hold the shared tier lock and force optlevel 2 so a concurrent joovy_exec
        # (which may have lowered the module to optlevel 0) cannot make this
        # "promotion" compile at a low tier.
        lock(TieredCompile._tier_compile_lock) do
            TieredCompile.set_module_tier!(mod, 2)
            for s in srcs
                Core.eval(mod, s)
            end
        end
        elapsed = time_ns() - t0
        record_compile!(CompileEvent(e.name, 2, UInt64(elapsed), :promote,
                                     Symbol[], UInt64(time_ns()), :joovy_exec))
        e.tier = 2
        e.promoting = false
        _DIRTY[] = true
    catch err
        e.promoting = false
        @warn "joovy promote failed for $(e.name)" exception=(err, catch_backtrace())
    end
end

# ===================================================================
# Reporting + background streaming
# ===================================================================

function _median_sample(e::CounterEntry)
    n = e.sample_n
    n == 0 && return 0.0
    s = sort(e.samples[1:n])
    return isodd(n) ? Float64(s[(n + 1) ÷ 2]) :
                      (Float64(s[n ÷ 2]) + Float64(s[n ÷ 2 + 1])) / 2
end

function counters_report()
    fns = Dict{String,Any}[]
    lock(_COUNTERS_LOCK) do
        for (name, e) in _COUNTERS
            push!(fns, Dict{String,Any}(
                "name"      => string(name),
                "tier"      => e.tier,
                "calls"     => e.call_count,
                "total_ns"  => e.total_ns,
                "median_ns" => _median_sample(e),
            ))
        end
    end
    return Dict{String,Any}("functions" => fns)
end

"""
    alloc_snapshot() -> Vector{NamedTuple}

Per-function allocation snapshot consumed by CompileWatch's dynamic layer
(the `allocation-heavy-method` rule): one `(name, file, line, calls,
total_alloc_bytes)` entry per `:full`-instrumented function that has recorded
at least one call. `file`/`line` come from the def's own source location
(set in `_register_def!`), `nothing`/`0` if unknown (e.g. `joovy_exec` was
called with no `path`) -- CompileWatch skips entries with no file, mirroring
how the compile-time dynamic rules skip methods `_method_loc` can't resolve.

`total_alloc_bytes` is a sum of per-call `Base.gc_num()` deltas (see
`record`'s `:full` overload) -- a PROCESS-WIDE counter, so calls from
concurrently-running tasks inflate each other's totals. `bytes_per_call`
derived from this is therefore an approximation, not an exact per-call
figure, under concurrency.
"""
function alloc_snapshot()
    T = @NamedTuple{name::Symbol, file::Union{Nothing,String}, line::Int, calls::Int, total_alloc_bytes::UInt64}
    out = T[]
    lock(_COUNTERS_LOCK) do
        for (name, e) in _COUNTERS
            e.level === :full || continue
            e.call_count > 0 || continue
            push!(out, (name = name, file = e.file, line = e.def_line,
                        calls = e.call_count, total_alloc_bytes = e.total_alloc_bytes))
        end
    end
    return out
end

function _send_counters()
    if isdefined(Main, :FlexibleIPC) && isdefined(Main.FlexibleIPC, :send_notification)
        try
            Base.invokelatest(Main.FlexibleIPC.send_notification, "joovy/counters", counters_report())
        catch
        end
    end
    return nothing
end

# Idempotent background streamer: change-gated + throttled, so it never touches the
# hot call path and only sends when something actually changed.
function start_counter_stream!(; interval::Real=0.5)
    _STREAM_STARTED[] && return nothing
    _STREAM_STARTED[] = true
    @async begin
        while true
            try
                sleep(interval)
                if _DIRTY[]
                    _DIRTY[] = false
                    _send_counters()
                end
            catch
                # keep the streamer alive across transient IPC errors
            end
        end
    end
    return nothing
end

function reset_counters!()
    lock(_COUNTERS_LOCK) do
        empty!(_COUNTERS)
        empty!(_SOURCE)
    end
    _DIRTY[] = true
    return nothing
end

end # module

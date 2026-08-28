# src/CompileWatch.jl
#
# Detects Julia code patterns that hurt compile times and reports structured
# (file, line) diagnostics over IPC to the IDE.
#
# Two independent detection layers:
#
#   STATIC  -- 9 AST-level pattern rules (section 2 of the design), run once
#              per requested file (`compile_watch_start!(paths=...)`) or
#              ad-hoc over raw source/a path (`compile_watch_check`). Zero
#              runtime dependency; reused across `compile_watch_check` calls
#              with no session state.
#
#   DYNAMIC -- process-wide compile-time observation. On Julia 1.12+ this
#              installs `jl_set_newly_inferred` with a growable
#              `Vector{Core.CodeInstance}`, drained on the same 0.5s throttle
#              cadence as `Instrument.start_counter_stream!`; per
#              `Core.CodeInstance` it accumulates self-inference time,
#              compile time, and re-inference counts per `Method`. On
#              pre-1.12 Julia (`@static`-guarded dead code here -- never
#              loaded on 1.12) it falls back to walking the
#              `Core.Compiler.Timings` tree, UNVERIFIED (untestable on this
#              repo's Julia 1.12.3). A capability probe at
#              `compile_watch_start!` downgrades to static-only, with a
#              warning, if the selected path captures nothing -- CompileWatch
#              never silently claims dynamic coverage it doesn't have.

module CompileWatch

using ..SourceProvider
using ..SourcePos
using ..LazyModules
using ..Config
import ..Instrument

export CWDiagnostic, compile_watch_start!, compile_watch_stop!, compile_watch_report,
       compile_watch_check, compile_watch_set_thresholds!, compile_watch_wire_snapshot,
       compile_watch_status

# ===================================================================
# Diagnostic struct + wire shape (design section 4)
#
# The wire shape MUST match the IDE's already-written contract exactly: a
# full snapshot per push, 1-based lines, absolute file paths, kebab-case
# rule_id strings. The IDE replaces its whole diagnostic cache on every
# notification, so `compile_watch_wire_snapshot()` is always a COMPLETE
# snapshot, never a delta; entries missing file/line are dropped IDE-side, so
# we simply never emit those (see `_method_loc`).
# ===================================================================

struct CWDiagnostic
    rule_id::Symbol
    severity::Symbol            # :hint | :warning
    file::String
    line::Int
    method_name::Symbol
    message::String
    suggestion::String
    source::Symbol               # :static | :dynamic
    metric::Union{Nothing,Dict{String,Any}}
    fix::Union{Nothing,Dict{String,String}}   # optional machine-actionable fix hint
end

# Outer constructor at the OLD (pre-`fix`) arity: every call site written
# before `fix` existed keeps working unchanged, with `fix` defaulting to
# `nothing` (no hint) -- only the three rules named in the task brief pass
# `fix` explicitly via the full 10-arg inner constructor.
CWDiagnostic(rule_id::Symbol, severity::Symbol, file::String, line::Int, method_name::Symbol,
             message::String, suggestion::String, source::Symbol,
             metric::Union{Nothing,Dict{String,Any}}) =
    CWDiagnostic(rule_id, severity, file, line, method_name, message, suggestion, source, metric, nothing)

function _wire(d::CWDiagnostic)
    w = Dict{String,Any}(
        "rule_id"    => string(d.rule_id),
        "severity"   => string(d.severity),
        "file"       => d.file,
        "line"       => d.line,
        "method"     => string(d.method_name),
        "message"    => d.message,
        "suggestion" => d.suggestion,
        "source"     => string(d.source),
        "metric"     => d.metric,
    )
    d.fix === nothing || (w["fix"] = d.fix)
    return w
end

"""
    compile_watch_wire_snapshot() -> Dict{String,Any}

The full wire payload for the `joovy/diagnostics` notification and the
`joovy/diag_report` IPC route: `{"diagnostics": [...]}`. Single source of
truth for the wire shape -- both the throttled push and the on-demand report
route call this.
"""
function compile_watch_wire_snapshot()
    diags = compile_watch_report()
    # `scope` tells the IDE which slice of its cache this snapshot replaces:
    # a static-only session (the headless analyzer) must not clobber the
    # dynamic diagnostics a REPL session streams, and vice versa.
    scope = _static_enabled[] && !_dynamic_requested[] ? "static" :
            _dynamic_requested[] && !_static_enabled[] ? "dynamic" : "all"
    return Dict{String,Any}(
        "diagnostics" => Any[_wire(d) for d in diags],
        "scope" => scope)
end

# ===================================================================
# Session state
# ===================================================================

const _session_lock = ReentrantLock()
const _static_enabled = Ref{Bool}(false)
const _dynamic_requested = Ref{Bool}(false)
const _dynamic_capable = Ref{Bool}(false)
const _dynamic_active = Ref{Bool}(false)
const _running = Ref{Bool}(false)

const _static_diagnostics = Dict{String,Vector{CWDiagnostic}}()   # path -> diags
const _dynamic_diagnostics = Dict{Method,CWDiagnostic}()          # method -> latest diag
const _alloc_diagnostics = Dict{Symbol,CWDiagnostic}()            # fn name -> latest allocation-heavy-method diag

const _dirty = Ref{Bool}(false)
const _stream_started = Ref{Bool}(false)

# Rules the user switched off (IDE setting, delivered via diag_start's
# `disabled_rules` param). Filtered in `compile_watch_report`, so the editor
# marks, the status panel, and the stream all honor it from one place.
const _disabled_rules = Ref{Set{Symbol}}(Set{Symbol}())

"""
    set_disabled_rules!(ids) -> Int

Replace the disabled-rule set. Accepts any iterable of strings or symbols.
Returns the resulting set size. Unknown ids are kept (harmless) so the IDE
can send a superset across Joovy versions.
"""
function set_disabled_rules!(ids)
    _disabled_rules[] = Set{Symbol}(Symbol(x) for x in ids)
    _dirty[] = true
    return length(_disabled_rules[])
end

# 1.12 capture buffer (installed once for the whole session; drained by
# copy+empty! rather than reinstalling, since jl_set_newly_inferred keeps
# pushing into whatever Vector object is currently installed).
const _cw_buf = Ref{Union{Nothing,Vector{Core.CodeInstance}}}(nothing)

mutable struct _MethodAgg
    total_infer_self_s::Float64
    total_compile_s::Float64
    mi_ci_counts::Dict{Any,Int}   # MethodInstance -> distinct CodeInstances seen
end
_MethodAgg() = _MethodAgg(0.0, 0.0, Dict{Any,Int}())

const _method_agg = Dict{Method,_MethodAgg}()
const _touched_methods = Set{Method}()

# ===================================================================
# Thresholds (config-overridable -- see compile_watch_set_thresholds! and the
# diag_start IPC route's specializations_over/inference_self_ms_over/
# reinfer_count_over params)
# ===================================================================

mutable struct _Thresholds
    specializations_over::Int
    inference_self_ms_over::Float64
    reinfer_count_over::Int
    broadcast_fusion_chain_over::Int   # static: long-broadcast-fusion-chain
    alloc_bytes_per_call_over::Int     # dynamic: allocation-heavy-method
    compile_ms_over::Float64           # dynamic: dynamic-compile-time-over
end
const _thresholds = Ref(_Thresholds(32, 50.0, 3, 8, 1_000_000, 100.0))

"""
    compile_watch_set_thresholds!(; specializations_over=nothing,
                                    inference_self_ms_over=nothing,
                                    reinfer_count_over=nothing,
                                    broadcast_fusion_chain_over=nothing,
                                    alloc_bytes_per_call_over=nothing,
                                    compile_ms_over=nothing)

Override one or more thresholds (defaults: 32 specializations, 50ms
self-inference time, 3 re-inferences, 8 fused broadcast ops per statement,
1_000_000 allocated bytes/call, 100ms total compile time). Only provided keys
change; `nothing` (the default for each) leaves that threshold as-is. Returns
the resulting threshold set.
"""
function compile_watch_set_thresholds!(; specializations_over::Union{Integer,Nothing}=nothing,
                                        inference_self_ms_over::Union{Real,Nothing}=nothing,
                                        reinfer_count_over::Union{Integer,Nothing}=nothing,
                                        broadcast_fusion_chain_over::Union{Integer,Nothing}=nothing,
                                        alloc_bytes_per_call_over::Union{Integer,Nothing}=nothing,
                                        compile_ms_over::Union{Real,Nothing}=nothing)
    t = _thresholds[]
    specializations_over === nothing || (t.specializations_over = Int(specializations_over))
    inference_self_ms_over === nothing || (t.inference_self_ms_over = Float64(inference_self_ms_over))
    reinfer_count_over === nothing || (t.reinfer_count_over = Int(reinfer_count_over))
    broadcast_fusion_chain_over === nothing || (t.broadcast_fusion_chain_over = Int(broadcast_fusion_chain_over))
    alloc_bytes_per_call_over === nothing || (t.alloc_bytes_per_call_over = Int(alloc_bytes_per_call_over))
    compile_ms_over === nothing || (t.compile_ms_over = Float64(compile_ms_over))
    return (specializations_over = t.specializations_over,
            inference_self_ms_over = t.inference_self_ms_over,
            reinfer_count_over = t.reinfer_count_over,
            broadcast_fusion_chain_over = t.broadcast_fusion_chain_over,
            alloc_bytes_per_call_over = t.alloc_bytes_per_call_over,
            compile_ms_over = t.compile_ms_over)
end

# ===================================================================
# Static rules (design section 2): AST-only pattern detectors.
#
# All 9 rules operate on a `_FuncDef` (one named function definition, found by
# reusing LazyModules' def helpers -- `_is_function_def` / `_extract_def_name`
# -- exactly like the rest of the repo splits definitions out of parsed
# source) plus, for untyped-global-in-fn, a same-file top-level name
# classification pass.
# ===================================================================

struct _FuncDef
    name::Symbol
    sig::Any
    body::Any
    line::Int
end

# Unwrap `@inline function f() ... end` (and any other macro decorating a
# def, possibly stacked) down to the underlying function-def Expr, so a
# decorated top-level function is both (a) analyzed by the 9 static rules
# itself, and (b) recognized as a resolvable same-file name when OTHER
# functions call it (see `_scan_toplevel!`) -- `LazyModules._is_function_def`
# only matches the def shape directly, not a `:macrocall` wrapping one.
function _unwrap_macro_funcdef(stmt)
    s = stmt
    while s isa Expr && s.head === :macrocall && !isempty(s.args)
        inner = s.args[end]
        (inner isa Expr && LazyModules._is_function_def(inner)) || break
        s = inner
    end
    return s
end

function _iter_function_defs(ast)::Vector{_FuncDef}
    defs = _FuncDef[]
    seen = Set{UInt64}()   # dedup: a decorated def is reached both via its
                           # :macrocall wrapper AND, separately, as the same
                           # inner Expr object visited directly by the walk.
    SourcePos.each_positioned(ast) do node, line
        node isa Expr || return nothing
        node = _unwrap_macro_funcdef(node)
        LazyModules._is_function_def(node) || return nothing
        length(node.args) >= 2 || return nothing
        oid = objectid(node)
        oid in seen && return nothing
        push!(seen, oid)
        name = _def_name(node)
        name === nothing && return nothing
        push!(defs, _FuncDef(name, node.args[1], node.args[2], line))
        return nothing
    end
    return defs
end

# --- signature helpers -----------------------------------------------------

# Unwrap `where` clauses AND a return-type annotation (`function f(x)::T ...`
# parses with the whole call wrapped in an outer `:(::)`, order `where { :: {
# call } }` when both are present) down to the underlying `:call` signature.
# `LazyModules._is_function_def`/`_extract_def_name` don't handle the
# return-type-annotated form (used throughout this very file), so this and
# `_def_name` below fill that gap locally rather than touching the shared
# helper.
function _call_sig(sig)
    s = sig
    while true
        if s isa Expr && s.head === :where && length(s.args) >= 1
            s = s.args[1]
        elseif s isa Expr && s.head === :(::) && length(s.args) >= 1 &&
               s.args[1] isa Expr && s.args[1].head in (:call, :where)
            s = s.args[1]
        else
            break
        end
    end
    return (s isa Expr && s.head === :call) ? s : nothing
end

function _def_name(node::Expr)
    LazyModules._is_function_def(node) || return nothing
    length(node.args) >= 1 || return nothing
    nm = LazyModules._extract_def_name(node)
    nm !== nothing && return nm
    call = _call_sig(node.args[1])
    (call !== nothing && length(call.args) >= 1 && call.args[1] isa Symbol) ? call.args[1] : nothing
end

# Positional args, normalized: a defaulted positional (`Expr(:kw, name, default)`,
# which Julia's parser puts in the POSITIONAL slot, not :parameters) is unwrapped
# to its underlying name[::T] shape so every rule sees a uniform representation.
function _positional_args(sig)::Vector{Any}
    call = _call_sig(sig)
    call === nothing && return Any[]
    out = Any[]
    for a in call.args[2:end]
        a isa Expr && a.head === :parameters && continue
        if a isa Expr && a.head === :kw && length(a.args) >= 1
            push!(out, a.args[1])
        else
            push!(out, a)
        end
    end
    return out
end

# The `Expr(:parameters, ...)` block's entries (keyword params), if any.
function _keyword_params(sig)::Vector{Any}
    call = _call_sig(sig)
    call === nothing && return Any[]
    for a in call.args
        a isa Expr && a.head === :parameters && return a.args
    end
    return Any[]
end

function _arg_name(a)
    a isa Symbol && return a
    if a isa Expr
        if a.head === :(::) && length(a.args) >= 1
            inner = a.args[1]
            return inner isa Symbol ? inner : nothing
        elseif a.head === :(...) && length(a.args) >= 1
            return _arg_name(a.args[1])
        elseif a.head === :macrocall && a.args[1] === Symbol("@nospecialize") && length(a.args) >= 3
            # Inline `@nospecialize(x)`/`@nospecialize(x::T)` written directly
            # in a parameter list, as opposed to a body-leading statement.
            return _arg_name(a.args[end])
        end
    end
    return nothing
end

function _arg_type(a)
    if a isa Expr && a.head === :macrocall && a.args[1] === Symbol("@nospecialize") && length(a.args) >= 3
        a = a.args[end]
    end
    a isa Expr && a.head === :(::) && length(a.args) == 2 && return a.args[2]
    return nothing
end

# --- rule 1: closure-arg-respecialization -----------------------------------

const _RULE_CLOSURE_ARG = Symbol("closure-arg-respecialization")

function _rule_closure_arg(fd::_FuncDef, path::String)::Vector{CWDiagnostic}
    out = CWDiagnostic[]
    candidates = Symbol[]
    for a in _positional_args(fd.sig)
        a isa Expr && a.head === :(...) && continue     # varargs -> its own rule
        # Already fixed via inline `@nospecialize(cb)` in the signature itself
        # (as opposed to a body-leading `@nospecialize cb` statement, handled
        # below) -- not a candidate.
        a isa Expr && a.head === :macrocall && a.args[1] === Symbol("@nospecialize") && continue
        name = _arg_name(a)
        name === nothing && continue
        t = _arg_type(a)
        (t === nothing || t === :Function) || continue  # unannotated OR ::Function
        push!(candidates, name)
    end
    isempty(candidates) && return out

    nospecialized = Set{Symbol}()
    SourcePos.each_positioned(fd.body) do node, line
        node isa Expr && node.head === :macrocall && length(node.args) >= 3 || return nothing
        node.args[1] === Symbol("@nospecialize") || return nothing
        for a in node.args[3:end]
            s = (a isa Expr && a.head === :(::)) ? a.args[1] : a
            s isa Symbol && push!(nospecialized, s)
        end
        return nothing
    end

    seen = Set{Symbol}()
    SourcePos.each_positioned(fd.body) do node, line
        node isa Expr && node.head === :call && length(node.args) >= 1 || return nothing
        callee = node.args[1]
        callee isa Symbol || return nothing
        (callee in candidates) && !(callee in nospecialized) && !(callee in seen) || return nothing
        push!(seen, callee)
        push!(out, CWDiagnostic(
            _RULE_CLOSURE_ARG, :warning, path, line, fd.name,
            "Argument `$(callee)` of `$(fd.name)` is invoked as a closure call -- each distinct closure passed in gets its own specialization.",
            "Add `@nospecialize $(callee)` or hoist a named const function instead of a closure literal.",
            :static, nothing,
            Dict("kind" => "nospecialize-arg", "symbol" => String(callee))))
        return nothing
    end
    return out
end

# --- rule 2: vararg-unbounded-splat -----------------------------------------

const _RULE_VARARG = Symbol("vararg-unbounded-splat")

function _vararg_diag(fd::_FuncDef, path::String)
    CWDiagnostic(_RULE_VARARG, :warning, path, fd.line, fd.name,
        "`$(fd.name)` accepts an unbounded splat/Vararg argument -- Julia compiles one specialization per distinct arity/type tuple.",
        "Bind it as `Vararg{T,N}`, or accept a `Tuple`/`Vector` instead.",
        :static, nothing)
end

function _rule_vararg(fd::_FuncDef, path::String)::Vector{CWDiagnostic}
    out = CWDiagnostic[]
    for a in _positional_args(fd.sig)
        if a isa Expr && a.head === :(...)
            push!(out, _vararg_diag(fd, path))
        elseif a isa Expr && a.head === :(::) && length(a.args) == 2
            t = a.args[2]
            if t isa Expr && t.head === :curly && !isempty(t.args) && t.args[1] === :Vararg &&
               length(t.args) < 3   # Vararg{T} (no N) -- unbounded; Vararg{T,N} is fine
                push!(out, _vararg_diag(fd, path))
            end
        end
    end
    return out
end

# --- rule 3: large-tuple-signature ------------------------------------------

const _RULE_LARGE_TUPLE = Symbol("large-tuple-signature")
const _LARGE_TUPLE_ARITY = 8

function _tuple_diag(fd::_FuncDef, path::String, n)
    CWDiagnostic(_RULE_LARGE_TUPLE, :warning, path, fd.line, fd.name,
        "`$(fd.name)` takes a $(n)-element tuple type -- each concrete Tuple specializes separately and inference cost grows with width.",
        "Use a `Vector`/struct instead, or bound the tuple length.",
        :static, nothing)
end

function _rule_large_tuple(fd::_FuncDef, path::String)::Vector{CWDiagnostic}
    out = CWDiagnostic[]
    for a in _positional_args(fd.sig)
        t = _arg_type(a)
        (t isa Expr && t.head === :curly && !isempty(t.args)) || continue
        head = t.args[1]
        if head === :NTuple && length(t.args) >= 2 && t.args[2] isa Integer && t.args[2] > _LARGE_TUPLE_ARITY
            push!(out, _tuple_diag(fd, path, t.args[2]))
        elseif head === :Tuple
            arity = length(t.args) - 1
            arity > _LARGE_TUPLE_ARITY && push!(out, _tuple_diag(fd, path, arity))
        end
    end
    return out
end

# --- rule 4: untyped-global-in-fn -------------------------------------------

const _RULE_UNTYPED_GLOBAL = Symbol("untyped-global-in-fn")

function _type_head_name(expr)
    expr isa Symbol && return expr
    expr isa Expr || return nothing
    (expr.head === :curly || expr.head === :(<:)) && return _type_head_name(expr.args[1])
    return nothing
end

function _assign_target_name(lhs)
    lhs isa Symbol && return lhs
    (lhs isa Expr && lhs.head === :(::) && length(lhs.args) >= 1) && return _assign_target_name(lhs.args[1])
    return nothing
end

# Names a `using`/`import` statement brings into scope: `using ..Foo` (and
# `using A, B`) bind the LAST path component of each item (`Foo`/`A`/`B`);
# `using X: a, b` (and `import X: a, b`) bind only the explicitly listed
# names, NOT `X` itself. Relative-import dots (`.`, `..`) are plain Symbols
# in the path and never the LAST component, so no special-casing is needed.
function _using_import_names!(stmt::Expr, names::Set{Symbol})
    for item in stmt.args
        item isa Expr || continue
        if item.head === :(.)
            !isempty(item.args) && item.args[end] isa Symbol && push!(names, item.args[end])
        elseif item.head === :(:)
            for sub in item.args[2:end]
                sub isa Expr && sub.head === :(.) && !isempty(sub.args) &&
                    sub.args[end] isa Symbol && push!(names, sub.args[end])
            end
        end
    end
    return nothing
end

# Classify every TOP-LEVEL name in the same parsed source into "const-like"
# (function/struct/abstract/primitive/module def, `const` decl -- assumed
# resolvable/stable whether or not the module has been loaded yet) or
# "non-const global" (a bare top-level `name = value`). Names never seen at
# top level fall through to a runtime isdefined/isconst check against `mod`.
#
# Descends into `module ... end` bodies (and nested modules) -- almost every
# real Julia package file (this repo's own src/*.jl included) is a single
# top-level `module X ... end`, whose OWN body is where every def actually
# lives; without descending, a whole-file check would find zero top-level
# names and flag every sibling function/const reference as unresolved.
function _toplevel_names(ast)
    const_like = Set{Symbol}()
    non_const = Set{Symbol}()
    non_const_lines = Dict{Symbol,Int}()
    _scan_toplevel!(ast, const_like, non_const, non_const_lines, Ref(0))
    return const_like, non_const, non_const_lines
end

# `cursor` tracks the current source line via the `LineNumberNode`s
# interleaved among `stmts` (same threaded-cursor convention as
# `_collect_fusion_statements!`), so a non-const global's OWN top-level
# assignment line can be recorded in `non_const_lines` for the
# `untyped-global-in-fn` fix hint's `def_line` -- first occurrence per name
# wins, matching `_rule_int_float_acc`'s `inits` convention.
function _scan_toplevel!(ast, const_like::Set{Symbol}, non_const::Set{Symbol},
                          non_const_lines::Dict{Symbol,Int}, cursor::Ref{Int})
    stmts = (ast isa Expr && ast.head in (:block, :toplevel)) ? ast.args : Any[ast]
    for stmt0 in stmts
        if stmt0 isa LineNumberNode
            cursor[] = stmt0.line
            continue
        end
        stmt0 isa Expr || continue
        # `@static if ... else ... end` (version-gated code, e.g. this very
        # file's 1.9-1.11 vs 1.12 dynamic-layer split): treat BOTH branches as
        # transparent/top-level for name resolution, since static analysis
        # can't evaluate the condition and either branch may be the one kept.
        if stmt0.head === :macrocall && length(stmt0.args) >= 3 &&
           stmt0.args[1] === Symbol("@static") && stmt0.args[end] isa Expr &&
           stmt0.args[end].head === :if
            ifexpr = stmt0.args[end]
            _scan_toplevel!(ifexpr.args[2], const_like, non_const, non_const_lines, cursor)
            length(ifexpr.args) >= 3 && _scan_toplevel!(ifexpr.args[3], const_like, non_const, non_const_lines, cursor)
            continue
        end
        stmt = _unwrap_macro_funcdef(stmt0)
        if stmt.head === :module && length(stmt.args) >= 3
            stmt.args[2] isa Symbol && push!(const_like, stmt.args[2])
            _scan_toplevel!(stmt.args[3], const_like, non_const, non_const_lines, cursor)
        elseif LazyModules._is_function_def(stmt)
            nm = _def_name(stmt)
            nm !== nothing && push!(const_like, nm)
        elseif stmt.head === :struct && length(stmt.args) >= 2
            nm = _type_head_name(stmt.args[2])
            nm !== nothing && push!(const_like, nm)
        elseif stmt.head in (:abstract, :primitive) && length(stmt.args) >= 1
            nm = _type_head_name(stmt.args[1])
            nm !== nothing && push!(const_like, nm)
        elseif stmt.head === :const && length(stmt.args) >= 1
            inner = stmt.args[1]
            nm = inner isa Expr && inner.head === :(=) ? _assign_target_name(inner.args[1]) : nothing
            nm !== nothing && push!(const_like, nm)
        elseif stmt.head in (:using, :import)
            _using_import_names!(stmt, const_like)
        elseif stmt.head === :(=) && length(stmt.args) >= 1
            nm = _assign_target_name(stmt.args[1])
            if nm !== nothing && !(nm in const_like)
                push!(non_const, nm)
                haskey(non_const_lines, nm) || (non_const_lines[nm] = cursor[])
            end
        end
    end
    return nothing
end

function _bind_names!(lhs, locals::Set{Symbol})
    if lhs isa Symbol
        push!(locals, lhs)
    elseif lhs isa Expr && lhs.head === :(::) && length(lhs.args) >= 1
        _bind_names!(lhs.args[1], locals)
    elseif lhs isa Expr && lhs.head === :tuple
        for e in lhs.args
            _bind_names!(e, locals)
        end
    end
    # :ref (indexing) / :. (field) assignment targets are NOT new locals.
    return nothing
end

# Bind every name introduced by a parameter LIST (as found on the RHS of a
# `:call` signature, or in a `->`/do-block param tuple): positional (bare,
# typed, splatted), defaulted (`:kw` -- Julia's parser puts a defaulted
# POSITIONAL arg in `:kw` form too, not just true keywords), and a nested
# `:parameters` block for keyword arguments. Uniform across every place a
# parameter list can appear, so kwargs/splat args are never missed as locals.
function _bind_param_list!(items, locals::Set{Symbol})
    for it in items
        if it isa Expr && it.head === :parameters
            _bind_param_list!(it.args, locals)
        elseif it isa Expr && it.head === :kw && length(it.args) >= 1
            n = _arg_name(it.args[1])
            n !== nothing && push!(locals, n)
        else
            n = _arg_name(it)
            n !== nothing && push!(locals, n)
        end
    end
    return nothing
end

function _where_var_name(tv)
    tv isa Symbol && return tv
    if tv isa Expr && tv.head in (:(<:), :(>:), :comparison) && length(tv.args) >= 1
        return _where_var_name(tv.args[1])
    end
    return nothing
end

# Bind a function-def signature's OWN parameters (and any `where T` type
# variables) as locals. Handles both the named/`:call` form and the
# anonymous long form `function(params) ... end`, whose signature is a bare
# `Expr(:tuple, ...)` rather than a `:call` -- `_call_sig` only recognizes
# `:call`, so without this a long-form anonymous callback's own params would
# be missed and flagged as free reads in its body.
function _bind_funcdef_params!(sig, locals::Set{Symbol})
    s = sig
    while true
        if s isa Expr && s.head === :where && length(s.args) >= 1
            for tv in s.args[2:end]
                n = _where_var_name(tv)
                n !== nothing && push!(locals, n)
            end
            s = s.args[1]
        elseif s isa Expr && s.head === :(::) && length(s.args) >= 1 &&
               s.args[1] isa Expr && s.args[1].head in (:call, :where)
            s = s.args[1]   # return-type annotation -- not a new local, just unwrap
        else
            break
        end
    end
    if s isa Expr && s.head === :call
        _bind_param_list!(s.args[2:end], locals)
    elseif s isa Expr && s.head === :tuple
        _bind_param_list!(s.args, locals)
    elseif s isa Symbol
        push!(locals, s)
    end
    return nothing
end

function _bind_for_vars!(iterspec, locals::Set{Symbol})
    if iterspec isa Expr && iterspec.head === :block
        for it in iterspec.args
            it isa Expr && it.head === :(=) && _bind_names!(it.args[1], locals)
        end
    elseif iterspec isa Expr && iterspec.head === :(=)
        _bind_names!(iterspec.args[1], locals)
    end
    return nothing
end

# Best-effort, deliberately over-approximating local-binding collector: every
# name bound ANYWHERE in the body (assignments, for/generator/comprehension
# vars, let bindings, nested closures'/do-blocks' own params, catch vars) is
# treated as local for the WHOLE body, even though a precise implementation
# would scope some of these more tightly. Over-approximating locals only
# SUPPRESSES potential diagnostics, never fabricates one, which is the safe
# direction for a lint that must stay usable on the repo's own idiomatic code.
function _collect_locals!(node, locals::Set{Symbol})
    node isa Expr || return nothing
    if node.head === :(=) && length(node.args) >= 1
        _bind_names!(node.args[1], locals)
    elseif node.head === :for && length(node.args) >= 1
        _bind_for_vars!(node.args[1], locals)
    elseif node.head === :generator && length(node.args) >= 2
        for it in node.args[2:end]
            it isa Expr && it.head === :(=) && _bind_names!(it.args[1], locals)
        end
    elseif node.head === :let && length(node.args) >= 1
        bindings = node.args[1]
        if bindings isa Expr && bindings.head === :block
            for b in bindings.args
                b isa Expr && b.head === :(=) ? _bind_names!(b.args[1], locals) :
                    (b isa Symbol && push!(locals, b))
            end
        elseif bindings isa Expr && bindings.head === :(=)
            _bind_names!(bindings.args[1], locals)
        elseif bindings isa Symbol
            push!(locals, bindings)
        end
    elseif LazyModules._is_function_def(node) && length(node.args) >= 1
        _bind_funcdef_params!(node.args[1], locals)
    elseif node.head === :(->) && length(node.args) >= 1
        params = node.args[1]
        if params isa Expr && params.head === :tuple
            _bind_param_list!(params.args, locals)
        else
            n = _arg_name(params)
            n !== nothing && push!(locals, n)
        end
    elseif node.head === :try && length(node.args) >= 2 && node.args[2] isa Symbol
        # Expr(:try, tryblock, catchvar, catchblock, ...) -- the catch variable
        # sits directly in the :try node's OWN args, there is no :catch head.
        push!(locals, node.args[2])
    end
    for arg in node.args
        _collect_locals!(arg, locals)
    end
    return nothing
end

function _collect_locals(fd::_FuncDef)::Set{Symbol}
    locals = Set{Symbol}()
    _bind_funcdef_params!(fd.sig, locals)
    _collect_locals!(fd.body, locals)
    return locals
end

# `mod` first, then Base/Core directly: a name from a submodule Base doesn't
# re-export at the top level (e.g. `Base.StackTraces.StackFrame`) can still
# be a completely ordinary, resolvable reference even when it is not visible
# through `mod`'s own namespace (which for the default `mod=Main` only sees
# what Base/Core export, plus whatever the analyzed session has `using`'d).
function _resolved_const(sym::Symbol, mod::Module)::Bool
    for m in (mod, Base, Core)
        try
            isdefined(m, sym) && isconst(m, sym) && return true
        catch
        end
    end
    return false
end

# Parser-reserved pseudo-symbols that can appear as bare `Symbol` leaves in
# raw (unlowered) AST but are never real bindings: `end` inside indexing
# (`a[end]` parses to `Expr(:ref, :a, :end)` -- only lowered to `lastindex`
# later), `new` inside an inner constructor body, `_` the throwaway/wildcard
# placeholder, and `ccall`, a compiler builtin form, not a normal binding.
const _PSEUDO_SYMBOLS = Set{Symbol}([:end, :new, :_, :ccall])

# Free-variable read scan, structurally aware of two shapes a flat node
# visitor can't distinguish from a real read:
#   - a call-site keyword's LABEL (`Expr(:kw, name, value)`, reached via a
#     `:parameters` block, or the same shape in a nested def's own signature)
#     is not a variable reference -- only its value is.
#   - a `:quote` node (`:(...)`/`quote...end`, e.g. building an Expr to
#     `Core.eval`) holds CODE AS DATA describing a DIFFERENT program's
#     namespace, not live reads of the current function's scope -- skipped
#     entirely, not just its label positions.
function _each_read(f, node, cursor::Ref{Int})
    if node isa LineNumberNode
        cursor[] = node.line
        return nothing
    elseif node isa Expr
        if node.head === :kw && length(node.args) >= 2
            _each_read(f, node.args[2], cursor)
            return nothing
        elseif node.head === :quote
            return nothing
        end
        f(node, cursor[])
        for arg in node.args
            _each_read(f, arg, cursor)
        end
        return nothing
    else
        f(node, cursor[])
        return nothing
    end
end

function _rule_untyped_global(fd::_FuncDef, path::String, const_like::Set{Symbol},
                              non_const::Set{Symbol}, non_const_lines::Dict{Symbol,Int},
                              mod::Module)::Vector{CWDiagnostic}
    out = CWDiagnostic[]
    locals = _collect_locals(fd)
    flagged = Set{Symbol}()

    _each_read(fd.body, Ref(fd.line)) do node, line
        node isa Symbol || return nothing
        sym = node
        (sym in locals || sym in flagged || sym in _PSEUDO_SYMBOLS) && return nothing

        if sym in non_const
            push!(flagged, sym)
            def_line = get(non_const_lines, sym, line)
            push!(out, CWDiagnostic(
                _RULE_UNTYPED_GLOBAL, :warning, path, line, fd.name,
                "`$(fd.name)` reads module-level global `$(sym)`, which is not declared `const` -- every reassignment invalidates and re-infers every reader.",
                "Declare `const $(sym) = ...`, pass it as an argument, or wrap it in a `Ref{T}`.",
                :static, nothing,
                Dict("kind" => "make-const", "symbol" => String(sym), "def_line" => string(def_line))))
        elseif !(sym in const_like) && !_resolved_const(sym, mod)
            push!(flagged, sym)
            # Weaker confidence (:hint, not :warning): we could not resolve this
            # name at all, so it may simply be a not-yet-loaded const, an
            # imported name, or a typo -- not necessarily a real global.
            push!(out, CWDiagnostic(
                _RULE_UNTYPED_GLOBAL, :hint, path, line, fd.name,
                "`$(fd.name)` reads `$(sym)`, which could not be resolved to a constant binding in `$(nameof(mod))` or this file's own top-level definitions.",
                "If `$(sym)` is a mutable global, declare it `const`, pass it as an argument, or wrap it in a `Ref{T}`.",
                :static, nothing))
        end
        return nothing
    end
    return out
end

# --- rule 5: keyword-heavy-signature ----------------------------------------

const _RULE_KWARGS = Symbol("keyword-heavy-signature")
const _KW_HEAVY_COUNT = 6

function _rule_kwargs(fd::_FuncDef, path::String)::Vector{CWDiagnostic}
    n = length(_keyword_params(fd.sig))
    n > _KW_HEAVY_COUNT || return CWDiagnostic[]
    return CWDiagnostic[CWDiagnostic(_RULE_KWARGS, :warning, path, fd.line, fd.name,
        "`$(fd.name)` takes $(n) keyword parameters -- each distinct kwarg-type combination specializes the kwsorter and kwbody separately.",
        "Group related options into a struct or `NamedTuple`.",
        :static, nothing)]
end

# --- rule 6: val-type-proliferation -----------------------------------------

const _RULE_VAL = Symbol("val-type-proliferation")

_is_literal(x) = x isa Number || x isa AbstractString || x isa Bool || x isa QuoteNode || x isa Char

function _rule_val(fd::_FuncDef, path::String)::Vector{CWDiagnostic}
    out = CWDiagnostic[]
    seen_lines = Set{Int}()
    SourcePos.each_positioned(fd.body) do node, line
        node isa Expr && node.head === :call && length(node.args) == 2 || return nothing
        node.args[1] === :Val || return nothing
        _is_literal(node.args[2]) && return nothing
        line in seen_lines && return nothing
        push!(seen_lines, line)
        push!(out, CWDiagnostic(_RULE_VAL, :warning, path, line, fd.name,
            "`Val(...)` constructed from a non-literal value in `$(fd.name)` -- each distinct runtime value produces its own `Val{X}` type and specialization.",
            "Dispatch with a runtime `if`/`Dict` instead unless the value domain is small (<= ~8).",
            :static, nothing))
        return nothing
    end
    return out
end

# --- rule 7: deep-nested-parametric-signature -------------------------------

const _RULE_NESTED = Symbol("deep-nested-parametric-signature")
const _NEST_DEPTH = 4

function _curly_depth(t)::Int
    (t isa Expr && t.head === :curly) || return 0
    d = 0
    for sub in t.args[2:end]
        d = max(d, _curly_depth(sub))
    end
    return d + 1
end

function _rule_nested(fd::_FuncDef, path::String)::Vector{CWDiagnostic}
    for a in _positional_args(fd.sig)
        t = _arg_type(a)
        t === nothing && continue
        depth = _curly_depth(t)
        if depth >= _NEST_DEPTH
            return CWDiagnostic[CWDiagnostic(_RULE_NESTED, :warning, path, fd.line, fd.name,
                "`$(fd.name)` has a signature type nested $(depth) levels deep -- subtype/method-match lattice cost scales with nesting at every call site.",
                "Flatten via a wrapper struct or a looser supertype bound.",
                :static, nothing)]
        end
    end
    return CWDiagnostic[]
end

# --- rule 8: long-broadcast-fusion-chain ------------------------------------
#
# From the performance study: a single statement chaining many `.`-fused
# broadcast operations together builds one deeply nested `Broadcasted{...}`
# parametric type -- inference/codegen cost grows with chain depth even
# though (unlike a NON-fused chain of separate statements) the runtime
# allocates only the final output. Three fused-op shapes count towards one
# statement's total:
#   - a dotted-operator call:  `Expr(:call, sym, ...)` where `sym` is a
#     Symbol whose name starts with '.' (`.+`, `.*`, `.^`, `.<=`, ...)
#   - `f.(args)` broadcast-call sugar: `Expr(:., f, Expr(:tuple, args...))`
#     -- excludes plain field access `Expr(:., x, QuoteNode(:prop))`, which
#     has the SAME head but a QuoteNode second arg instead of a tuple.
#   - every `:call` node textually inside an `@.` (`@__dot__`) macrocall --
#     `@.` rewrites EVERY call/operator in its body to its dotted form, so
#     none of them carry an explicit leading '.' in the raw (unlowered) AST.

const _RULE_BROADCAST_CHAIN = Symbol("long-broadcast-fusion-chain")

function _is_dotted_op_call(node)::Bool
    (node isa Expr && node.head === :call && length(node.args) >= 1) || return false
    callee = node.args[1]
    callee isa Symbol || return false
    s = String(callee)
    return !isempty(s) && s[1] == '.'
end

# `f.(args)` form -- same head as field access (`x.prop`), distinguished only
# by the second arg's shape: a QuoteNode (field name) for field access vs an
# `Expr(:tuple, ...)` (call arguments) for the broadcast-call form.
function _is_dot_call_form(node)::Bool
    (node isa Expr && node.head === :(.) && length(node.args) == 2) || return false
    return !(node.args[2] isa QuoteNode)
end

function _is_dot_macro(node)::Bool
    (node isa Expr && node.head === :macrocall && length(node.args) >= 1) || return false
    return node.args[1] === Symbol("@__dot__")
end

# Counts every fused-op node in `node`'s subtree, scoped to ONE statement:
# stops descending at a nested `:block` (a control-flow body's statements are
# each counted separately as their OWN statement -- see
# `_collect_fusion_statements!`) but otherwise recurses through everything,
# including non-fusing call boundaries (`f(a .+ b)` still counts the `.+`),
# since the rule counts "fused ops appearing in this statement", not a
# strict single-Broadcasted-tree membership analysis.
function _count_fused_in_scope(node, in_dot::Bool)::Int
    node isa Expr || return 0
    node.head === :block && return 0
    if _is_dot_macro(node)
        total = 0
        for a in node.args[3:end]
            total += _count_fused_in_scope(a, true)
        end
        return total
    end
    is_fused = in_dot ? (node.head === :call) : (_is_dotted_op_call(node) || _is_dot_call_form(node))
    total = is_fused ? 1 : 0
    for a in node.args
        total += _count_fused_in_scope(a, in_dot)
    end
    return total
end

# Collects "statement root" nodes: every direct entry of every `:block`
# reachable in `node` (the outer function body block, and any nested block
# from an if/for/while/try/let/do body), paired with its line. A `:block`
# itself is transparent -- its entries are the statements, not the block
# node -- so counting each entry's fused ops via `_count_fused_in_scope`
# (which stops at the NEXT nested `:block`) never double-counts a nested
# statement as part of its parent's total.
function _collect_fusion_statements!(node, cursor::Ref{Int}, out::Vector{Tuple{Any,Int}})
    if node isa LineNumberNode
        cursor[] = node.line
        return nothing
    end
    node isa Expr || return nothing
    if node.head === :block
        for a in node.args
            if a isa LineNumberNode
                cursor[] = a.line
            elseif a isa Expr
                push!(out, (a, cursor[]))
                _collect_fusion_statements!(a, cursor, out)   # find blocks nested inside this statement
            end
        end
        return nothing
    end
    for a in node.args
        _collect_fusion_statements!(a, cursor, out)
    end
    return nothing
end

function _rule_broadcast_chain(fd::_FuncDef, path::String)::Vector{CWDiagnostic}
    out = CWDiagnostic[]
    stmts = Tuple{Any,Int}[]
    _collect_fusion_statements!(fd.body, Ref(fd.line), stmts)
    thresh = _thresholds[].broadcast_fusion_chain_over
    for (node, line) in stmts
        cnt = _count_fused_in_scope(node, false)
        cnt > thresh || continue
        push!(out, CWDiagnostic(_RULE_BROADCAST_CHAIN, :hint, path, line, fd.name,
            "A statement in `$(fd.name)` fuses $(cnt) dotted broadcast operations together (over $(thresh)) -- deeply nested Broadcasted type; inference and codegen cost grow with chain depth.",
            "Split the chain or use an explicit loop (a loop also avoids the intermediate allocations that splitting reintroduces).",
            :static, nothing))
    end
    return out
end

# --- rule 9: int-init-float-accumulator -------------------------------------
#
# From the performance study: `k3 = 0` (an Int-literal init) later promoted
# to float caused 9.44M allocations -- the accumulator's inferred type widens
# from `Int` to `Union{Int,Float64}`/`Float64` partway through the function,
# boxing every subsequent use. Deliberately narrow (only 3 easily-checked,
# AST-visible promotion shapes -- see the task brief) to keep this at zero
# false positives on ordinary code: a plain `x = 0; x += 1` (int accumulator
# that STAYS int) must never fire.
const _RULE_INT_FLOAT_ACC = Symbol("int-init-float-accumulator")

const _COMPOUND_ASSIGN_HEADS = Set{Symbol}([
    :+=, :-=, :*=, :/=, :÷=, :\=, :^=, :%=, ://=,
    :|=, :&=, :⊻=, :<<=, :>>=, :>>>=,
])

function _contains_float_lit(node)::Bool
    node isa AbstractFloat && return true
    node isa Expr || return false
    for a in node.args
        _contains_float_lit(a) && return true
    end
    return false
end

function _contains_division(node)::Bool
    node isa Expr || return false
    if node.head === :call && length(node.args) >= 1 && node.args[1] === :/
        return true
    end
    for a in node.args
        _contains_division(a) && return true
    end
    return false
end

function _rule_int_float_acc(fd::_FuncDef, path::String)::Vector{CWDiagnostic}
    out = CWDiagnostic[]

    # Pass 1: candidate int-inits -- `x = <Integer literal>` (Bool excluded;
    # `Bool <: Integer` but `flag = false` is not an accumulator init). First
    # occurrence per name wins, matching this rule's flat-body over-approximation
    # (same convention as `_collect_locals`/`_rule_untyped_global`).
    inits = Dict{Symbol,Int}()
    SourcePos.each_positioned(fd.body) do node, line
        (node isa Expr && node.head === :(=) && length(node.args) == 2) || return nothing
        lhs = node.args[1]
        lhs isa Symbol || return nothing
        rhs = node.args[2]
        (rhs isa Integer && !(rhs isa Bool)) || return nothing
        haskey(inits, lhs) || (inits[lhs] = line)
        return nothing
    end
    isempty(inits) && return out

    # Pass 2: a later assignment/compound-assignment to the SAME name that
    # promotes it to float, via one of the three narrow shapes.
    flagged = Set{Symbol}()
    SourcePos.each_positioned(fd.body) do node, line
        node isa Expr || return nothing
        head = node.head
        is_compound = head in _COMPOUND_ASSIGN_HEADS
        is_plain = head === :(=)
        (is_compound || is_plain) && length(node.args) == 2 || return nothing
        lhs = node.args[1]
        lhs isa Symbol || return nothing
        haskey(inits, lhs) || return nothing
        lhs in flagged && return nothing
        line > inits[lhs] || return nothing   # must be strictly after the init

        rhs = node.args[2]
        fires = (is_compound && _contains_float_lit(rhs)) ||             # (a)
                head === :(/=) || _contains_division(rhs) ||             # (b)
                (is_plain && rhs isa AbstractFloat)                      # (c)
        fires || return nothing

        push!(flagged, lhs)
        push!(out, CWDiagnostic(_RULE_INT_FLOAT_ACC, :hint, path, inits[lhs], fd.name,
            "`$(lhs)` in `$(fd.name)` is initialized from an integer literal but later promoted to float -- inference widens and the accumulator boxes.",
            "Initialize with 0.0 or zero(T); verify with @code_warntype.",
            :static, nothing,
            Dict("kind" => "float-init", "symbol" => String(lhs))))
        return nothing
    end
    return out
end

# --- orchestrator ------------------------------------------------------------

function _run_static_rules(ast, path::String, mod::Module)::Vector{CWDiagnostic}
    const_like, non_const, non_const_lines = _toplevel_names(ast)
    out = CWDiagnostic[]
    for fd in _iter_function_defs(ast)
        append!(out, _rule_closure_arg(fd, path))
        append!(out, _rule_vararg(fd, path))
        append!(out, _rule_large_tuple(fd, path))
        append!(out, _rule_untyped_global(fd, path, const_like, non_const, non_const_lines, mod))
        append!(out, _rule_kwargs(fd, path))
        append!(out, _rule_val(fd, path))
        append!(out, _rule_nested(fd, path))
        append!(out, _rule_broadcast_chain(fd, path))
        append!(out, _rule_int_float_acc(fd, path))
    end
    return out
end

"""
    compile_watch_check(path_or_code::AbstractString; mod::Module=Main) -> Vector{CWDiagnostic}

Static-only, one-shot check: `path_or_code` is treated as a file path if it
names an existing file (read via `SourceProvider.source_read`, so a pushed
editor buffer is honoured), otherwise as raw Julia source. Runs all 9 static
rules and returns the diagnostics directly -- no session state, safe to call
repeatedly with no `compile_watch_start!`/`compile_watch_stop!` bracket.
"""
function compile_watch_check(path_or_code::AbstractString; mod::Module=Main)::Vector{CWDiagnostic}
    if isfile(path_or_code)
        path = abspath(String(path_or_code))
        src = SourceProvider.source_read(path)
    else
        path = "<compile_watch_check>"
        src = String(path_or_code)
    end
    ast = SourcePos.parse_with_lines(src, path)
    return _run_static_rules(ast, path, mod)
end

# Called by IpcBridge on every `joovy/source_push` while a session runs.
# The IDE debounces keystrokes and pushes the buffer; this re-scans that
# file's static rules against the pushed text and marks the stream dirty,
# so editor marks refresh as the user types. No-op when no session runs.
function compile_watch_notify_push!(path::String)
    (_running[] && _static_enabled[]) || return nothing
    _scan_path!(abspath(path))
    _dirty[] = true
    return nothing
end

function _scan_path!(path::String)
    abs_path = abspath(path)
    src = try
        SourceProvider.source_exists(abs_path) ? SourceProvider.source_read(abs_path) : nothing
    catch
        nothing
    end
    if src === nothing
        lock(_session_lock) do
            delete!(_static_diagnostics, abs_path)
        end
        return nothing
    end
    ast = try
        SourcePos.parse_with_lines(src, abs_path)
    catch
        nothing
    end
    ast === nothing && return nothing
    diags = _run_static_rules(ast, abs_path, Main)
    lock(_session_lock) do
        _static_diagnostics[abs_path] = diags
    end
    return nothing
end

# ===================================================================
# Dynamic layer (design section 1)
# ===================================================================

function _skip_module(m::Module)::Bool
    r = Base.moduleroot(m)
    r === Base && return true
    r === Core && return true
    r === Base.moduleroot(@__MODULE__) && return true   # skip Joovy's own internals
    return false
end

function _decode_time(x::UInt16)::Float64
    v = reinterpret(Float16, x)
    isfinite(v) ? Float64(v) : 0.0
end

function _method_loc(method::Method)
    f = method.file
    (f === :none || String(f) == "") && return (nothing, 0)
    path = try
        abspath(String(f))
    catch
        String(f)
    end
    return (path, Int(method.line))
end

# --- 1.12 path: jl_set_newly_inferred (verified live) -----------------------

function _install_dynamic_1_12!()::Bool
    buf = Core.CodeInstance[]
    try
        ccall(:jl_set_newly_inferred, Cvoid, (Any,), buf)
    catch
        return false
    end
    _cw_buf[] = buf
    ok = _probe_capture_1_12!()
    ok || _uninstall_dynamic_1_12!()
    return ok
end

function _uninstall_dynamic_1_12!()
    try
        ccall(:jl_set_newly_inferred, Cvoid, (Any,), nothing)
    catch
    end
    _cw_buf[] = nothing
    return nothing
end

# Probe with a FRESH gensym'd method every call (not a fixed function): once a
# given (function, argtypes) pair has been inferred, re-running it hits the
# method cache and captures NOTHING new, which would falsely report the
# capability as dead on a second compile_watch_start! in the same process.
function _probe_capture_1_12!()::Bool
    buf = _cw_buf[]
    buf === nothing && return false
    empty!(buf)
    fname = gensym(:_cw_probe)
    try
        Core.eval(@__MODULE__, :($(fname)(x) = x + 1))
        # Wrap the `getfield` binding lookup itself, not just the call it
        # resolves to -- on 1.12 a bare `getfield(@__MODULE__, fname)` right
        # after `Core.eval` can trip the stricter world-age check on its own,
        # even under an outer `Base.invokelatest` around the CALL.
        Base.invokelatest(() -> getfield(@__MODULE__, fname)(1))
    catch
        return false
    end
    ok = !isempty(buf)
    empty!(buf)   # discard the probe's own sample -- not a real user method
    return ok
end

function _drain_1_12!()::Vector{Core.CodeInstance}
    buf = _cw_buf[]
    buf === nothing && return Core.CodeInstance[]
    items = copy(buf)
    empty!(buf)
    return items
end

function _process_1_12!(items::Vector{Core.CodeInstance})
    for ci in items
        mi = ci.def
        mi isa Core.MethodInstance || continue
        method = mi.def
        method isa Method || continue
        _skip_module(method.module) && continue
        agg = get!(_MethodAgg, _method_agg, method)
        agg.total_infer_self_s += _decode_time(ci.time_infer_self)
        agg.total_compile_s += _decode_time(ci.time_compile)
        agg.mi_ci_counts[mi] = get(agg.mi_ci_counts, mi, 0) + 1
        push!(_touched_methods, method)
    end
    return nothing
end

# --- 1.9-1.11 path: Core.Compiler.Timings tree (UNVERIFIED -- dead on 1.12) -

@static if VERSION < v"1.12-"

function _install_dynamic_legacy!()::Bool
    try
        Core.Compiler.Timings.reset_timings()
        Core.Compiler.__set_measure_typeinf(true)
    catch
        return false
    end
    return _probe_capture_legacy!()
end

function _uninstall_dynamic_legacy!()
    try
        Core.Compiler.__set_measure_typeinf(false)
    catch
    end
    return nothing
end

function _probe_capture_legacy!()::Bool
    try
        Core.Compiler.Timings.reset_timings()
        fname = gensym(:_cw_probe_legacy)
        Core.eval(@__MODULE__, :($(fname)(x) = x + 1))
        # Wrap the `getfield` binding lookup itself, not just the call it
        # resolves to -- on 1.12 a bare `getfield(@__MODULE__, fname)` right
        # after `Core.eval` can trip the stricter world-age check on its own,
        # even under an outer `Base.invokelatest` around the CALL.
        Base.invokelatest(() -> getfield(@__MODULE__, fname)(1))
        root = Core.Compiler.Timings._timings[1]
        ok = !isempty(root.children)
        Core.Compiler.Timings.reset_timings()
        return ok
    catch
        return false
    end
end

function _walk_timings!(t, samples::Vector{Tuple{Method,Float64,Float64}})
    mi = try t.mi_info.mi catch; nothing end
    if mi isa Core.MethodInstance && mi.def isa Method
        push!(samples, (mi.def, Float64(t.time), 0.0))
    end
    for c in t.children
        _walk_timings!(c, samples)
    end
    return nothing
end

function _drain_legacy!()::Vector{Tuple{Method,Float64,Float64}}
    try
        root = Core.Compiler.Timings._timings[1]
        samples = Tuple{Method,Float64,Float64}[]
        _walk_timings!(root, samples)
        Core.Compiler.Timings.reset_timings()
        return samples
    catch
        return Tuple{Method,Float64,Float64}[]
    end
end

else

_install_dynamic_legacy!() = false
_uninstall_dynamic_legacy!() = nothing
_drain_legacy!() = Tuple{Method,Float64,Float64}[]

end # @static

function _process_legacy!(samples::Vector{Tuple{Method,Float64,Float64}})
    for (method, self_s, compile_s) in samples
        _skip_module(method.module) && continue
        agg = get!(_MethodAgg, _method_agg, method)
        agg.total_infer_self_s += self_s
        agg.total_compile_s += compile_s
        push!(_touched_methods, method)
    end
    return nothing
end

function _install_dynamic!()::Bool
    @static VERSION >= v"1.12-" ? _install_dynamic_1_12!() : _install_dynamic_legacy!()
end

function _uninstall_dynamic!()
    @static VERSION >= v"1.12-" ? _uninstall_dynamic_1_12!() : _uninstall_dynamic_legacy!()
    return nothing
end

# --- aggregation -> diagnostics ----------------------------------------------

# `Base.specializations` only exists from Julia 1.10 on. On 1.9 -- still in
# this package's [compat] range -- read the `Method` field directly: it holds
# either a bare `MethodInstance` (exactly one specialization) or a
# `Core.SimpleVector` used as a hash table, whose empty slots are `nothing`.
# Without this fallback the 1.9 count silently degrades to 0, so
# `dynamic-specializations-over` never fires there and a lower-priority rule
# reports in its place.
@static if isdefined(Base, :specializations)
    _specialization_count(m::Method) = length(collect(Base.specializations(m)))
else
    function _specialization_count(m::Method)
        s = m.specializations
        s isa Core.MethodInstance && return 1
        return count(x -> x !== nothing, s)
    end
end

const _RULE_DYN_SPECIALIZATIONS = Symbol("dynamic-specializations-over")
const _RULE_DYN_INFERENCE_TIME = Symbol("dynamic-inference-time-over")
const _RULE_DYN_REINFER = Symbol("dynamic-reinfer-churn")
const _RULE_DYN_COMPILE_TIME = Symbol("dynamic-compile-time-over")

# `ci.time_compile` only carries a real (non-zero) codegen sample on the 1.12
# `jl_set_newly_inferred` path -- `_process_legacy!`'s samples hardcode the
# compile-time component to 0.0 (see `_walk_timings!`), since the 1.9-1.11
# `Core.Compiler.Timings` tree has no per-CodeInstance codegen time field.
# Gated on a load-time constant (rather than relying on that hardcoded 0.0
# alone) so `dynamic-compile-time-over` is explicitly, unconditionally silent
# on pre-1.12 Julia, per the design.
const _DYNAMIC_HAS_COMPILE_TIME = @static VERSION >= v"1.12-" ? true : false

function _set_dynamic_diag!(method::Method, rule_id::Symbol, file::String, line::Int,
                            message::String, suggestion::String, metric::Dict{String,Any})
    d = CWDiagnostic(rule_id, :warning, file, line, method.name, message, suggestion, :dynamic, metric)
    lock(_session_lock) do
        _dynamic_diagnostics[method] = d
    end
    return nothing
end

function _refresh_dynamic_diagnostics!()
    touched = lock(_session_lock) do
        t = collect(_touched_methods)
        empty!(_touched_methods)
        t
    end
    isempty(touched) && return nothing
    th = _thresholds[]
    for method in touched
        agg = get(_method_agg, method, nothing)
        agg === nothing && continue
        file, line = _method_loc(method)
        file === nothing && continue

        spec_count = try
            _specialization_count(method)
        catch
            0
        end
        reinfer_count = sum((c - 1 for c in values(agg.mi_ci_counts) if c > 1); init=0)
        self_ms = agg.total_infer_self_s * 1000
        compile_ms = agg.total_compile_s * 1000
        total_compile_ms = self_ms + compile_ms   # inference self + codegen, per the design

        metric = Dict{String,Any}(
            "specializations"   => spec_count,
            "inference_self_ms" => round(self_ms; digits=3),
            "compile_ms"        => round(compile_ms; digits=3),
            "reinfer_count"     => reinfer_count,
        )

        if spec_count > th.specializations_over
            _set_dynamic_diag!(method, _RULE_DYN_SPECIALIZATIONS, file, line,
                "Method `$(method.name)` has $(spec_count) specializations (over $(th.specializations_over)).",
                "Consider @nospecialize on hot-varying-type arguments, or bound the domain.",
                metric)
        elseif self_ms > th.inference_self_ms_over
            _set_dynamic_diag!(method, _RULE_DYN_INFERENCE_TIME, file, line,
                "Method `$(method.name)` spent $(round(self_ms; digits=1))ms in self type inference (over $(th.inference_self_ms_over)ms).",
                "Reduce type complexity or specialization pressure for this method.",
                metric)
        elseif reinfer_count > th.reinfer_count_over
            _set_dynamic_diag!(method, _RULE_DYN_REINFER, file, line,
                "Method `$(method.name)` was re-inferred $(reinfer_count) times (over $(th.reinfer_count_over)) -- likely invalidation churn.",
                "Avoid redefining dependencies of this method at runtime; check for non-const globals it depends on.",
                metric)
        elseif _DYNAMIC_HAS_COMPILE_TIME && total_compile_ms > th.compile_ms_over
            _set_dynamic_diag!(method, _RULE_DYN_COMPILE_TIME, file, line,
                "Method `$(method.name)` spent $(round(total_compile_ms; digits=1))ms total compiling (over $(th.compile_ms_over)ms).",
                "Check for over-specialization or large signatures, or move this method to a lower tier.",
                Dict{String,Any}("compile_ms" => round(total_compile_ms; digits=3),
                                  "infer_ms" => round(self_ms; digits=3)))
        else
            lock(_session_lock) do
                delete!(_dynamic_diagnostics, method)
            end
        end
    end
    _dirty[] = true
    return nothing
end

# --- allocation-heavy-method: reads Instrument's :full per-call byte deltas -

const _RULE_ALLOC_HEAVY = Symbol("allocation-heavy-method")

# Reads `Instrument.alloc_snapshot()` (accumulated by the `:full`-instrumentation
# `record` overload -- see Instrument.jl) and turns any function averaging over
# `alloc_bytes_per_call_over` bytes/call into a diagnostic. Keyed by function
# NAME rather than `Method` (unlike the compile-time rules above): Instrument
# tracks plain top-level defs by name, not by resolved Method object, so
# there is no Method to key on here.
function _refresh_alloc_diagnostics!()
    snap = try
        Instrument.alloc_snapshot()
    catch
        return nothing
    end
    isempty(snap) && return nothing
    th = _thresholds[]
    changed = false
    for entry in snap
        entry.file === nothing && continue
        entry.calls > 0 || continue
        bytes_per_call = entry.total_alloc_bytes / entry.calls
        if bytes_per_call > th.alloc_bytes_per_call_over
            metric = Dict{String,Any}(
                "bytes_per_call" => round(bytes_per_call; digits=1),
                "calls"          => entry.calls,
            )
            d = CWDiagnostic(_RULE_ALLOC_HEAVY, :warning, entry.file, entry.line, entry.name,
                "`$(entry.name)` allocates $(round(bytes_per_call; digits=1)) bytes/call on average (over $(th.alloc_bytes_per_call_over)) across $(entry.calls) recorded calls.",
                "Check for intermediate arrays from non-fused vectorized chains and type-unstable accumulators; use in-place .=/@., pre-allocated outputs, and @code_warntype. Concurrent tasks make this per-call figure approximate.",
                :dynamic, metric)
            lock(_session_lock) do
                _alloc_diagnostics[entry.name] = d
            end
            changed = true
        else
            lock(_session_lock) do
                haskey(_alloc_diagnostics, entry.name) || return nothing
                delete!(_alloc_diagnostics, entry.name)
                changed = true
            end
        end
    end
    changed && (_dirty[] = true)
    return nothing
end

function _maybe_drain_and_refresh!()
    _dynamic_active[] || return nothing
    @static if VERSION >= v"1.12-"
        items = _drain_1_12!()
        if !isempty(items)
            _process_1_12!(items)
            _refresh_dynamic_diagnostics!()
        end
    else
        samples = _drain_legacy!()
        if !isempty(samples)
            _process_legacy!(samples)
            _refresh_dynamic_diagnostics!()
        end
    end
    _refresh_alloc_diagnostics!()
    return nothing
end

# ===================================================================
# Background throttled push (mirrors Instrument.start_counter_stream!:
# idempotent + change-gated + 0.5s throttle, never touching a hot path)
# ===================================================================

function _send_snapshot()
    if isdefined(Main, :FlexibleIPC) && isdefined(Main.FlexibleIPC, :send_notification)
        try
            Base.invokelatest(Main.FlexibleIPC.send_notification, "joovy/diagnostics", compile_watch_wire_snapshot())
        catch
        end
    end
    return nothing
end

function _start_stream!(; interval::Real=0.5)
    _stream_started[] && return nothing
    _stream_started[] = true
    @async begin
        while true
            try
                sleep(interval)
                _maybe_drain_and_refresh!()
                if _dirty[]
                    _dirty[] = false
                    _send_snapshot()
                end
            catch
                # keep the streamer alive across transient IPC errors
            end
        end
    end
    return nothing
end

# ===================================================================
# Public API (design section 6)
# ===================================================================

"""
    compile_watch_start!(; static=true, dynamic=true, paths=String[])

Start (or reconfigure) a CompileWatch session.

`static`, if true, runs all 9 static rules over every file in `paths` right
away. `dynamic`, if true, installs the dynamic capture layer and runs a
capability probe; on failure (e.g. an unsupported Julia build) it downgrades
to static-only with a warning rather than silently claiming coverage it
doesn't have. Idempotent: safe to call again (e.g. with a new `paths` list)
without an intervening `compile_watch_stop!`.

Returns `(dynamic_active, static_diagnostic_count)`.
"""
function compile_watch_start!(; static::Bool=true, dynamic::Bool=true,
                              paths::Vector{String}=String[])
    lock(_session_lock) do
        _static_enabled[] = static
        _dynamic_requested[] = dynamic
        _running[] = true
    end

    if static
        for p in paths
            _scan_path!(p)
        end
    end

    if dynamic
        ok = _install_dynamic!()
        _dynamic_capable[] = ok
        _dynamic_active[] = ok
        if !ok
            @warn "CompileWatch: dynamic compile-time capture unavailable on this Julia build -- falling back to static-only diagnostics"
        end
    else
        _dynamic_active[] = false
    end

    _dirty[] = true
    _start_stream!()

    n = lock(_session_lock) do
        sum(length(v) for v in values(_static_diagnostics); init=0)
    end
    return (dynamic_active = _dynamic_active[], static_diagnostic_count = n)
end

"""
    compile_watch_stop!()

Stop the dynamic capture layer (uninstalls the 1.12 `jl_set_newly_inferred`
hook / disables 1.9-1.11 Timings measurement) and marks the session inactive.
The last computed diagnostics remain available via `compile_watch_report()`.
"""
function compile_watch_stop!()
    _uninstall_dynamic!()
    lock(_session_lock) do
        _running[] = false
        _dynamic_active[] = false
    end
    _dirty[] = true
    return nothing
end

"""
    compile_watch_report() -> Vector{CWDiagnostic}

The current full diagnostic snapshot (static + dynamic), sorted by
`(file, line, rule_id)` for deterministic output. Drains and refreshes the
dynamic layer first, so this is always fresh even between throttle ticks.
"""
function compile_watch_report()::Vector{CWDiagnostic}
    _maybe_drain_and_refresh!()
    lock(_session_lock) do
        diags = CWDiagnostic[]
        for v in values(_static_diagnostics)
            append!(diags, v)
        end
        for v in values(_dynamic_diagnostics)
            push!(diags, v)
        end
        for v in values(_alloc_diagnostics)
            push!(diags, v)
        end
        disabled = _disabled_rules[]
        isempty(disabled) || filter!(d -> !(d.rule_id in disabled), diags)
        sort!(diags; by = d -> (d.file, d.line, string(d.rule_id)))
        return diags
    end
end

"""
    compile_watch_status()

Snapshot of session flags: `(running, static_enabled, dynamic_requested,
dynamic_capable, dynamic_active)`.
"""
function compile_watch_status()
    lock(_session_lock) do
        (running = _running[], static_enabled = _static_enabled[],
         dynamic_requested = _dynamic_requested[], dynamic_capable = _dynamic_capable[],
         dynamic_active = _dynamic_active[])
    end
end

# Test/internal-only: reset all session state to a pristine empty state
# without touching the (permanent, idempotent) background streamer task.
function _reset!()
    _uninstall_dynamic!()
    lock(_session_lock) do
        _static_enabled[] = false
        _dynamic_requested[] = false
        _dynamic_capable[] = false
        _dynamic_active[] = false
        _running[] = false
        empty!(_static_diagnostics)
        empty!(_dynamic_diagnostics)
        empty!(_alloc_diagnostics)
        empty!(_method_agg)
        empty!(_touched_methods)
    end
    _dirty[] = false
    _thresholds[] = _Thresholds(32, 50.0, 3, 8, 1_000_000, 100.0)
    _disabled_rules[] = Set{Symbol}()
    return nothing
end

# ===================================================================
# Config integration: `compile_watch = "on"/"off"` in [Joovy].
#
# Config.jl is included/`using`-imported BEFORE this module (see Joovy.jl's
# include order), so the dependency runs the OPPOSITE direction from
# Instrument._config_fn_tier_lookup (which Config, defined later, installs
# into): here CompileWatch (defined later) installs ITSELF into a Ref{Any}
# hook that Config exposes, then Config's `_apply_prefs!` calls that hook
# when it parses the `compile_watch` key -- same Ref{Any}-hook mechanism,
# mirrored across the opposite include-order direction.
# ===================================================================

function _apply_compile_watch_toggle!(enabled::Bool)
    enabled ? compile_watch_start!() : compile_watch_stop!()
    return nothing
end

Config._compile_watch_toggle_hook[] = _apply_compile_watch_toggle!

end # module

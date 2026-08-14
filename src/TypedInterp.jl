module TypedInterp

# Experimental typed-IR interpreter -- "tier 0.5: inference cost without LLVM cost".
#
# Joovy's tier 0 (`@compiler_options compile=min`) skips codegen by running Julia's own
# AST interpreter, which pays a full dynamic dispatch for every operation in the surface
# syntax. This module takes the opposite trade: it pays for TYPE INFERENCE (~1 ms per
# signature once the inference pipeline is warm, vs ~13 ms for a tier-2 first call) and
# then interprets the resulting *typed, optimized* IR, where inference has already
# collapsed the surface syntax into a short list of resolved `:invoke` targets.
#
# Design constraints (all measured on Julia 1.12.3 -- see the design note):
#
#   * INLINING IS OFF by default. Inlined IR made the collection fixture 4.9x SLOWER
#     than tier 0, because inlining drags Base's `foreigncall`/`memoryref` intrinsics
#     into the frame and inflates the statement count ~4.4x (84 vs 19 statements on the
#     probe fixture). `OptimizationParams(inlining=false)` flips it to a win AND shrinks
#     the fallback surface. The inlined form is kept behind `typed_interp_inline!` -- it
#     wins on pure scalar loops only.
#   * `:invoke` executes via `jl_invoke` on a MethodInstance. On 1.12 `Expr(:invoke)`
#     carries a `CodeInstance` (possibly behind a `Core.ABIOverride`); passing that
#     straight to `jl_invoke` SEGFAULTS, so `_unwrap_invoke_target` is mandatory.
#   * PhiNodes obey parallel-copy semantics: a leading run of phis is evaluated into
#     temporaries and committed together, and phis never update the `prev` predecessor
#     index (consecutive phis at a block head all read the block-entry predecessor).
#     Violating either rule produces silently wrong values or `nothing` operands.
#   * SHALLOW mode only: callees run natively through `jl_invoke`, they are not
#     recursively interpreted (measured: fib(24) 27 ms deep vs 0.22 ms shallow).
#
# Safety model. Fallback is per CALL, never per statement, in two stages:
#
#   1. An install-time accept-list scan of the IR. Anything outside the accepted node
#      set -- try/catch (`EnterNode`/`:leave`/`:pop_exception`), `:foreigncall`,
#      `:new_opaque_closure`, `Core.Box` construction, `UpsilonNode`/`PhiCNode`,
#      `SlotNumber`, an unknown `Expr` head, an unknown node type, or a varargs/kwargs
#      signature -- marks the signature unsupported, and it is never interpreted.
#   2. A runtime safety net. Any error escaping the interpreter disables the cache entry
#      permanently and re-runs the ENTIRE call via `Base.invokelatest`. Statements that
#      already ran execute twice, so this is a correctness backstop for interpreter bugs,
#      not a routine mode -- stage 1 is what keeps it unreachable, and the benchmark
#      gates `interp_errors == 0`.
#
# World age. `code_typed`'s `ci.max_world` equals the current world counter at
# acquisition (measured), so it is useless as a staleness oracle. Instead each cache
# entry is stamped with `Base.get_world_counter()`; a mismatch on call entry triggers a
# lazy re-acquisition, and an entry that re-infers more than `MAX_REINFER` times is
# disabled (hot-swap thrash guard). `HotSwap.hotswap_swap!` and
# `DynCompiler.joovy_recompile!` additionally flush the cache through a Ref hook.
#
# Default OFF. `joovy_typed_interp!(true)`, or `typed_interp = true` in the `[Joovy]`
# section of LocalPreferences.toml, opts in.

using ..DynCompiler
import ..HotSwap
import ..TieredCompile

export TypedInterpCallable, typed_interp_callable, typed_interp_enabled,
       joovy_typed_interp!, typed_interp_stats, typed_interp_clear!,
       typed_interp_inline, typed_interp_inline!

# ===================================================================
# Version shims
#
# Rules (design section 1): never enumerate builtins/intrinsics as a fixed list that
# decides SUPPORT (only as a fast path); take nargs/isva from the Method, never from
# CodeInfo (absent <= 1.10); reject unknown heads/node types instead of guessing.
# Only the 1.12 path is exercised on this machine -- the <= 1.11 branches are compiled
# out by `@static` and are untested.
# ===================================================================

@static if VERSION >= v"1.12"
    const CC = Base.Compiler
else
    const CC = Core.Compiler
end

@static if VERSION >= v"1.12"
    # 1.12: `Expr(:invoke).args[1]` is a `CodeInstance`; `.def` is the MethodInstance,
    # or a `Core.ABIOverride` that wraps it. `jl_invoke` accepts a MethodInstance ONLY --
    # handing it a CodeInstance segfaults in gf.c, so this unwrap is load-bearing.
    @inline function _unwrap_invoke_target(@nospecialize(x))
        x isa Core.MethodInstance && return x
        if x isa Core.CodeInstance
            d = getfield(x, :def)
            d isa Core.ABIOverride && (d = getfield(d, :def))
            d isa Core.MethodInstance && return d
        end
        return nothing
    end
else
    # 1.9-1.11: `args[1]` is the MethodInstance itself. UNTESTED on this machine.
    @inline function _unwrap_invoke_target(@nospecialize(x))
        return x isa Core.MethodInstance ? x : nothing
    end
end

"""
    _acquire_ir(f, tt, inline) -> Union{Core.CodeInfo,Nothing}

Infer and optimize `f(::tt...)` and return the typed IR, with inlining disabled unless
`inline` is true. Returns `nothing` when the signature does not resolve to exactly one
method body.

The interpreter object MUST be built with the world counter read here, not earlier: an
interpreter pinned to a world older than the method definition makes `code_typed` return
an empty vector.
"""
function _acquire_ir(@nospecialize(f), @nospecialize(tt), inline::Bool)
    @static if VERSION >= v"1.10"
        # `code_typed(...; interp=)` exists from 1.10 on.
        itp = CC.NativeInterpreter(Base.get_world_counter();
                                   opt_params = CC.OptimizationParams(inlining = inline))
        matches = Base.code_typed(f, tt; interp = itp)
    else
        # 1.9 cannot take a custom interpreter here, so it gets the default (inlined)
        # IR -- still correct, just a worse trade. UNTESTED on this machine.
        matches = Base.code_typed(f, tt; optimize = true)
    end
    length(matches) == 1 || return nothing
    ci = matches[1][1]
    return ci isa Core.CodeInfo ? ci : nothing
end

"""
    _method_nargs(m::Method) -> Int

Number of `Core.Argument` slots, counting the function itself as argument 1. Read from
the Method because `CodeInfo.nargs` does not exist before 1.11.
"""
_method_nargs(m::Method) = Int(m.nargs)

# ===================================================================
# Accept-list scan (fallback stage 1)
# ===================================================================

# IR node types that may appear as a STATEMENT but never as an OPERAND. Anything that is
# neither an accepted operand form nor one of these is a plain literal constant.
@inline function _is_ir_node(@nospecialize(x))
    x isa Expr && return true
    x isa Core.SlotNumber && return true
    x isa Core.NewvarNode && return true
    x isa Core.PhiNode && return true
    x isa Core.PiNode && return true
    x isa Core.UpsilonNode && return true
    x isa Core.PhiCNode && return true
    x isa Core.GotoNode && return true
    x isa Core.GotoIfNot && return true
    x isa Core.ReturnNode && return true
    x isa LineNumberNode && return true
    @static if isdefined(Core, :EnterNode)
        x isa Core.EnterNode && return true
    end
    @static if isdefined(Core, :TypedSlot)
        x isa Core.TypedSlot && return true
    end
    return false
end

# `nstmt` and `nargs` bound-check SSAValue / Argument references so the interpreter can
# never read past its own storage on malformed IR.
@inline function _operand_ok(@nospecialize(x), nstmt::Int, nargs::Int)
    if x isa Core.SSAValue
        return 1 <= x.id <= nstmt
    elseif x isa Core.Argument
        return 1 <= x.n <= nargs
    elseif x isa QuoteNode || x isa GlobalRef
        return true
    end
    # Slots can never be written in the accepted subset (no `:(=)` head), so a slot read
    # could only ever be undefined -- reject rather than guess.
    return !_is_ir_node(x)
end

function _args_ok(a::Vector{Any}, from::Int, nstmt::Int, nargs::Int)
    for i in from:length(a)
        _operand_ok(a[i], nstmt, nargs) || return false
    end
    return true
end

# `Core.Box` construction means a captured mutable binding; rejected by design.
@inline function _is_core_box(@nospecialize(t))
    t === Core.Box && return true
    return t isa GlobalRef && t.mod === Core && t.name === :Box
end

"""
    _scan_supported(ci, nargs) -> Bool

Install-time accept-list scan. `true` only when every statement, every operand and every
branch target of `ci` is in the interpretable subset. Never guesses: an unknown `Expr`
head or an unknown node type is a rejection.
"""
function _scan_supported(ci::Core.CodeInfo, nargs::Int)::Bool
    code = ci.code
    n = length(code)
    n == 0 && return false
    for pc in 1:n
        st = code[pc]
        if st isa Expr
            h = st.head
            a = st.args
            if h === :call
                length(a) >= 1 || return false
                _args_ok(a, 1, n, nargs) || return false
            elseif h === :invoke
                length(a) >= 2 || return false
                _unwrap_invoke_target(a[1]) === nothing && return false
                _args_ok(a, 2, n, nargs) || return false
            elseif h === :new
                length(a) >= 1 || return false
                _is_core_box(a[1]) && return false
                _args_ok(a, 1, n, nargs) || return false
            elseif h === :splatnew
                length(a) == 2 || return false
                _is_core_box(a[1]) && return false
                _args_ok(a, 1, n, nargs) || return false
            elseif h === :boundscheck
                # Value-only node; the interpreter always answers `true`.
            else
                return false          # :foreigncall, :leave, :cfunction, :copyast, ...
            end
        elseif st isa Core.ReturnNode
            # An undefined `.val` marks unreachable code after a proven-throwing call.
            # It is accepted here and raises if control ever reaches it, which routes to
            # the runtime safety net rather than returning a wrong value.
            isdefined(st, :val) || continue
            _operand_ok(st.val, n, nargs) || return false
        elseif st isa Core.GotoNode
            1 <= st.label <= n || return false
        elseif st isa Core.GotoIfNot
            1 <= st.dest <= n || return false
            _operand_ok(st.cond, n, nargs) || return false
        elseif st isa Core.PhiNode
            pc == 1 && return false   # the entry statement has no predecessor
            length(st.edges) == length(st.values) || return false
            for i in 1:length(st.values)
                isassigned(st.values, i) || continue
                _operand_ok(st.values[i], n, nargs) || return false
            end
        elseif st isa Core.PiNode
            _operand_ok(st.val, n, nargs) || return false
        elseif st === nothing || st isa LineNumberNode
            # No-op statement.
        else
            return false              # EnterNode, UpsilonNode, PhiCNode, unknown types
        end
    end
    return true
end

# ===================================================================
# Interpreter
# ===================================================================

struct TypedInterpError <: Exception
    msg::String
end

Base.showerror(io::IO, e::TypedInterpError) = print(io, "TypedInterpError: ", e.msg)

@noinline _interp_error(parts...) = throw(TypedInterpError(string(parts...)))

"""
    _res(x, ssa, argv)

Resolve one operand. `argv[1]` is the function itself, matching `Core.Argument(1)`.
"""
@inline function _res(@nospecialize(x), ssa::Vector{Any}, argv::Vector{Any})
    x isa Core.SSAValue && return ssa[x.id]
    x isa Core.Argument && return argv[x.n]
    x isa QuoteNode && return x.value
    x isa GlobalRef && return getglobal(x.mod, x.name)
    return x
end

# Fast path for the hottest intrinsics: an identity chain skips generic dispatch on the
# statements that dominate an inlined frame (measured 1.76x over a plain `f(a, b)`).
# The chain is a PERFORMANCE shortcut only -- an intrinsic that is not listed still runs
# through the generic call below, so the list never decides what is supported.
@inline function _call2(@nospecialize(f), @nospecialize(a), @nospecialize(b))
    if f isa Core.IntrinsicFunction
        II = Core.Intrinsics
        f === II.add_float && return II.add_float(a, b)
        f === II.mul_float && return II.mul_float(a, b)
        f === II.sub_float && return II.sub_float(a, b)
        f === II.div_float && return II.div_float(a, b)
        f === II.add_int   && return II.add_int(a, b)
        f === II.sub_int   && return II.sub_int(a, b)
        f === II.mul_int   && return II.mul_int(a, b)
        f === II.slt_int   && return II.slt_int(a, b)
        f === II.sle_int   && return II.sle_int(a, b)
        f === II.lt_float  && return II.lt_float(a, b)
        f === II.le_float  && return II.le_float(a, b)
        f === II.eq_int    && return II.eq_int(a, b)
        f === II.and_int   && return II.and_int(a, b)
    end
    return f(a, b)
end

@inline function _call1(@nospecialize(f), @nospecialize(a))
    if f isa Core.IntrinsicFunction
        II = Core.Intrinsics
        f === II.neg_float && return II.neg_float(a)
        f === II.not_int   && return II.not_int(a)
    end
    return f(a)
end

@inline function _do_call(a::Vector{Any}, ssa::Vector{Any}, argv::Vector{Any})
    f = _res(a[1], ssa, argv)
    m = length(a)
    m == 1 && return f()
    m == 2 && return _call1(f, _res(a[2], ssa, argv))
    m == 3 && return _call2(f, _res(a[2], ssa, argv), _res(a[3], ssa, argv))
    m == 4 && return f(_res(a[2], ssa, argv), _res(a[3], ssa, argv), _res(a[4], ssa, argv))
    buf = Vector{Any}(undef, m - 1)
    for i in 2:m
        buf[i-1] = _res(a[i], ssa, argv)
    end
    return f(buf...)
end

# `jl_invoke(F, args, nargs, mi)` takes the arguments AFTER the function, so `nargs` is
# the real argument count (verified: a 2-argument callee needs nargs == 2). When the
# callee has no compiled code yet, jl_invoke compiles it under the CALLEE's own module
# options -- a `compile=min` callee stays interpreted (probe O4), so shallow mode never
# smuggles codegen latency into a tier-0 module.
@inline function _do_invoke(a::Vector{Any}, ssa::Vector{Any}, argv::Vector{Any})
    mi = _unwrap_invoke_target(a[1])
    mi === nothing && _interp_error("cannot resolve :invoke target of type ", typeof(a[1]))
    f = _res(a[2], ssa, argv)
    nb = length(a) - 2
    buf = Vector{Any}(undef, nb)
    for i in 1:nb
        buf[i] = _res(a[i+2], ssa, argv)
    end
    return ccall(:jl_invoke, Any, (Any, Ptr{Any}, UInt32, Any), f, buf, UInt32(nb), mi)
end

@inline function _do_new(a::Vector{Any}, ssa::Vector{Any}, argv::Vector{Any})
    T = _res(a[1], ssa, argv)
    nf = length(a) - 1
    buf = Vector{Any}(undef, nf)
    for i in 1:nf
        buf[i] = _res(a[i+1], ssa, argv)
    end
    return ccall(:jl_new_structv, Any, (Any, Ptr{Any}, UInt32), T, buf, UInt32(nf))
end

@inline function _eval_phi(p::Core.PhiNode, prev::Int, ssa::Vector{Any}, argv::Vector{Any})
    edges = p.edges
    for i in 1:length(edges)
        if Int(edges[i]) == prev
            isassigned(p.values, i) ||
                _interp_error("PhiNode: undefined value on edge from statement ", prev)
            return _res(p.values[i], ssa, argv)
        end
    end
    _interp_error("PhiNode: no edge from statement ", prev)
end

"""
    _interpret(ci, argv) -> Any

Run the typed IR of one method body. `argv[1]` is the function object, `argv[2:end]` the
call arguments. Storage is one `Vector{Any}` indexed by statement number, because in
CodeInfo form an SSA id IS the statement index.
"""
function _interpret(ci::Core.CodeInfo, argv::Vector{Any})
    code = ci.code
    n = length(code)
    ssa = Vector{Any}(undef, n)
    pc = 1
    prev = 0                      # statement index control arrived from
    while true
        st = code[pc]

        # A leading run of phis at a block head is a parallel copy: evaluate every phi
        # against the SAME incoming values, then commit. Committing one at a time lets a
        # phi read another phi's value from THIS iteration instead of the previous one.
        if st isa Core.PhiNode
            j = pc
            while j <= n && code[j] isa Core.PhiNode
                j += 1
            end
            k = j - pc
            if k == 1
                ssa[pc] = _eval_phi(st, prev, ssa, argv)
            else
                tmp = Vector{Any}(undef, k)
                for i in 1:k
                    tmp[i] = _eval_phi(code[pc+i-1]::Core.PhiNode, prev, ssa, argv)
                end
                for i in 1:k
                    ssa[pc+i-1] = tmp[i]
                end
            end
            pc = j
            continue              # `prev` deliberately survives the whole phi run
        end

        if st isa Expr
            h = st.head
            if h === :invoke
                ssa[pc] = _do_invoke(st.args, ssa, argv)
            elseif h === :call
                ssa[pc] = _do_call(st.args, ssa, argv)
            elseif h === :new
                ssa[pc] = _do_new(st.args, ssa, argv)
            elseif h === :splatnew
                ssa[pc] = ccall(:jl_new_structt, Any, (Any, Any),
                                _res(st.args[1], ssa, argv), _res(st.args[2], ssa, argv))
            elseif h === :boundscheck
                # ALWAYS true. Answering false would silently disable bounds checks in
                # the callee and turn an out-of-range index into memory corruption.
                ssa[pc] = true
            else
                _interp_error("unsupported Expr head :", h)
            end
        elseif st isa Core.GotoIfNot
            c = _res(st.cond, ssa, argv)
            prev = pc
            if c === false
                pc = st.dest
            elseif c === true
                pc += 1
            else
                _interp_error("GotoIfNot condition is not a Bool: ", typeof(c))
            end
            continue
        elseif st isa Core.GotoNode
            prev = pc
            pc = st.label
            continue
        elseif st isa Core.ReturnNode
            isdefined(st, :val) ||
                _interp_error("reached an unreachable ReturnNode at statement ", pc)
            return _res(st.val, ssa, argv)
        elseif st isa Core.PiNode
            # Pass-through. A PiNode records what inference PROVED, it is not a runtime
            # typeassert, so checking it here would reject correct values.
            ssa[pc] = _res(st.val, ssa, argv)
        elseif st === nothing || st isa LineNumberNode
            ssa[pc] = nothing
        else
            _interp_error("unsupported node type ", typeof(st))
        end

        prev = pc
        pc += 1
    end
end

# ===================================================================
# Cache, world stamping and stats
# ===================================================================

# An entry that re-infers more often than this is thrashing against hot-swaps; it is
# disabled instead of paying inference forever.
const MAX_REINFER = 8

mutable struct IREntry
    ci::Union{Core.CodeInfo,Nothing}
    world::UInt
    supported::Bool
    disabled::Bool
    reinfers::Int
    hits::Int
end

# One process-wide table keyed by (typeof(f), argtypes), so two callables wrapping the
# same function share inference work and one flush empties everything. The key's first
# slot is `Any`, not `DataType`: `typeof(f)` is a `UnionAll` when the callable is an
# unparameterized type such as `Set`, and a narrower key type would raise on insert
# instead of taking the fallback path.
const _CACHE = Dict{Tuple{Any,Any},IREntry}()
const _CACHE_LOCK = ReentrantLock()

const _ENABLED = Ref(false)
const _INLINE  = Ref(false)

const _HITS      = Threads.Atomic{Int}(0)
const _MISSES    = Threads.Atomic{Int}(0)
const _FALLBACKS = Threads.Atomic{Int}(0)
const _REINFERS  = Threads.Atomic{Int}(0)
const _ERRORS    = Threads.Atomic{Int}(0)

function _accepted_method(@nospecialize(f), @nospecialize(tt))
    m = try
        which(f, tt)
    catch
        return nothing
    end
    m isa Method || return nothing
    m.isva && return nothing                       # varargs signature: rejected
    try
        isempty(Base.kwarg_decl(m)) || return nothing   # kwargs signature: rejected
    catch
        return nothing
    end
    return m
end

function _build_entry(@nospecialize(f), @nospecialize(tt), world::UInt)
    ci = nothing
    ok = false
    try
        m = _accepted_method(f, tt)
        if m !== nothing
            c = _acquire_ir(f, tt, _INLINE[])
            if c !== nothing && _scan_supported(c, _method_nargs(m))
                ci = c
                ok = true
            end
        end
    catch
        ci = nothing
        ok = false
    end
    return IREntry(ci, world, ok, false, 0, 0)
end

"""
    _entry(f, tt) -> IREntry

Cache lookup with world-age revalidation. `code_typed`'s own `max_world` equals the
current world counter at acquisition, so it cannot detect staleness -- the stamp taken
here can.
"""
function _entry(@nospecialize(f), @nospecialize(tt))
    key = (typeof(f), tt)
    world = Base.get_world_counter()
    # Explicit lock/unlock, NOT `lock(_CACHE_LOCK) do ... end`. A do-block here would
    # capture `f` and `tt` in a closure whose type is parameterized on their runtime
    # types, so every new function type would force a fresh `Base.lock` specialization:
    # measured at ~70 ms of codegen PER SIGNATURE, which dwarfs the ~1 ms acquisition it
    # is guarding and made the first interpreted call lose to a tier-2 first call.
    lock(_CACHE_LOCK)
    try
        e = get(_CACHE, key, nothing)
        if e === nothing
            Threads.atomic_add!(_MISSES, 1)
            e = _build_entry(f, tt, world)
            _CACHE[key] = e
            return e
        end
        if e.world != world && !e.disabled
            e.reinfers += 1
            Threads.atomic_add!(_REINFERS, 1)
            if e.reinfers > MAX_REINFER
                e.disabled = true          # hot-swap thrash guard
            else
                ne = _build_entry(f, tt, world)
                e.ci = ne.ci
                e.supported = ne.supported
                e.world = world
            end
        end
        return e
    finally
        unlock(_CACHE_LOCK)
    end
end

# Fired from HotSwap.hotswap_swap! and DynCompiler.joovy_recompile!: a redefinition can
# invalidate any cached body, and re-acquiring lazily is cheaper than reasoning about
# which entries a given swap touched.
function _flush_cache!()
    lock(_CACHE_LOCK) do
        empty!(_CACHE)
    end
    return nothing
end

# ===================================================================
# Public API
# ===================================================================

"""
    TypedInterpCallable(fn, mode)

Callable wrapper that interprets `fn`'s typed IR when the signature is supported and
falls back to `Base.invokelatest(fn, args...)` otherwise. Always substitutable for the
raw function: keyword calls, unsupported signatures and disabled entries all take the
native path.
"""
struct TypedInterpCallable <: AbstractJoovyCallable
    fn::Any
    mode::Symbol
end

TypedInterpCallable(fn) = TypedInterpCallable(fn, :shallow)

# `@nospecialize` on the vararg is what keeps the FIRST call cheap. Without it Julia
# compiles a fresh specialization of this operator -- and of the keyword `invokelatest`
# path inside it -- for every distinct argument-type tuple, measured at ~33 ms of codegen
# per new signature, which alone lost the first-call comparison against tier 2. With it
# there is exactly one specialization, and the per-call cost is a handful of dynamic
# `length`/`getindex` calls against an interpreted body that costs microseconds.
function (tic::TypedInterpCallable)(@nospecialize(args...); kwargs...)
    isempty(kwargs) || return _fallback_kwcall(tic.fn, args, kwargs)
    return _dispatch_call(tic.fn, args)
end

@noinline _fallback_call(@nospecialize(f), @nospecialize(args::Tuple)) =
    Base.invokelatest(f, args...)

@noinline _fallback_kwcall(@nospecialize(f), @nospecialize(args::Tuple), @nospecialize(kw)) =
    Base.invokelatest(f, args...; kw...)

@noinline function _dispatch_call(@nospecialize(f), @nospecialize(args::Tuple))
    _ENABLED[] || return _fallback_call(f, args)

    e = _entry(f, typeof(args))
    if !e.supported || e.disabled
        Threads.atomic_add!(_FALLBACKS, 1)
        return _fallback_call(f, args)
    end

    n = length(args)
    argv = Vector{Any}(undef, n + 1)
    argv[1] = f
    for i in 1:n
        argv[i+1] = args[i]
    end

    try
        r = _interpret(e.ci::Core.CodeInfo, argv)
        e.hits += 1
        Threads.atomic_add!(_HITS, 1)
        return r
    catch
        # Runtime safety net. Re-running the whole call repeats any side effect the
        # interpreted prefix already performed, which is why the accept-list scan --
        # not this branch -- is the real safety mechanism.
        e.disabled = true
        Threads.atomic_add!(_ERRORS, 1)
        Threads.atomic_add!(_FALLBACKS, 1)
        return _fallback_call(f, args)
    end
end

Base.show(io::IO, tic::TypedInterpCallable) =
    print(io, "TypedInterpCallable(", tic.fn, ", :", tic.mode, ")")

function _to_tuple_type(@nospecialize(argtypes))
    argtypes isa Type && argtypes <: Tuple && return argtypes
    return Tuple{argtypes...}
end

"""
    typed_interp_callable(f, argtypes; mode=:shallow) -> Union{TypedInterpCallable,Nothing}

Acquire and accept-list-scan the typed IR of `f(::argtypes...)`. Returns a callable when
the IR is interpretable, and `nothing` when it is not -- so a caller can decide between
tiering strategies instead of silently getting a wrapper that never interprets.

`argtypes` may be a tuple of types or a `Tuple{...}` type. Only `mode = :shallow` is
implemented; deep mode (recursively interpreting callees) was measured and rejected.
"""
function typed_interp_callable(@nospecialize(f), @nospecialize(argtypes); mode::Symbol = :shallow)
    mode === :shallow ||
        throw(ArgumentError("TypedInterp: only mode=:shallow is implemented, got :$mode"))
    tt = _to_tuple_type(argtypes)
    e = _entry(f, tt)
    e.supported || return nothing
    return TypedInterpCallable(f, mode)
end

typed_interp_enabled() = _ENABLED[]

"""
    joovy_typed_interp!(b::Bool) -> Bool

Global on/off switch, default OFF. Turning it on also installs the TieredCompile hook,
so freshly built tier-0/tier-1 callables get wrapped; turning it off removes the hook and
makes every existing wrapper a pass-through.
"""
function joovy_typed_interp!(b::Bool)::Bool
    _ENABLED[] = b
    TieredCompile._typed_interp_hook[] = b ? _wrap_for_tier : nothing
    return b
end

# Installed into TieredCompile as a Ref hook: TieredCompile must not know this module
# exists, because Joovy's include order forbids it from importing us.
_wrap_for_tier(fn) = TypedInterpCallable(fn, :shallow)

"""
    typed_interp_inline() / typed_interp_inline!(b::Bool)

Whether IR is acquired with inlining ON. Default `false`, and that default is
load-bearing: inlined IR measured 4.9x SLOWER than tier 0 on a collection workload. The
inlined form only pays off on pure scalar loops. Flipping the knob flushes the cache.
"""
typed_interp_inline() = _INLINE[]

function typed_interp_inline!(b::Bool)::Bool
    _INLINE[] = b
    _flush_cache!()
    return b
end

"""
    typed_interp_stats() -> NamedTuple

`(entries, hits, misses, fallbacks, reinfers, errors)`. `fallbacks` counts calls that ran
natively because the signature was unsupported or the entry was disabled; `errors` counts
runtime-safety-net trips, which should stay at zero.
"""
function typed_interp_stats()
    entries = lock(_CACHE_LOCK) do
        length(_CACHE)
    end
    return (entries   = entries,
            hits      = _HITS[],
            misses    = _MISSES[],
            fallbacks = _FALLBACKS[],
            reinfers  = _REINFERS[],
            errors    = _ERRORS[])
end

"""
    typed_interp_clear!()

Drop every cached body and reset the statistics counters.
"""
function typed_interp_clear!()
    _flush_cache!()
    _HITS[] = 0
    _MISSES[] = 0
    _FALLBACKS[] = 0
    _REINFERS[] = 0
    _ERRORS[] = 0
    return nothing
end

"""
    typed_interp_supported(f, argtypes) -> Bool

Whether `f(::argtypes...)` passed the accept-list scan. Acquires and caches the IR on
first use, exactly like a call would.
"""
function typed_interp_supported(@nospecialize(f), @nospecialize(argtypes))
    return _entry(f, _to_tuple_type(argtypes)).supported
end

function __init__()
    DynCompiler._cache_flush_hook[] = _flush_cache!
    HotSwap._cache_flush_hook[] = _flush_cache!
    return nothing
end

# Precompile the acquisition + interpretation path. Everything below `_entry` is
# `@nospecialize`d, so ONE walk through it here covers every later signature; without it
# the first interpreted call in a session pays that codegen inline.
#
# The remaining, unavoidable one-time cost is Julia's own inference pipeline: the first
# `code_typed` through a custom NativeInterpreter in a fresh process takes ~130-210 ms,
# after which each new signature costs ~0.3-1.5 ms (probes O5/O5b). That warmup cannot be
# cached into a package image, so `typed_interp_stats().misses == 1` is the cheap way for
# a caller to tell a primed session from a cold one.
if ccall(:jl_generating_output, Cint, ()) == 1
    let
        _pc_interp(a::Int, b::Int) = a < b ? a * 2 + b : b - a
        try
            _ENABLED[] = true
            _dispatch_call(_pc_interp, (3, 4))          # interpreted path
            _ENABLED[] = false
            _dispatch_call(_pc_interp, (3, 4))          # fallback path
        catch
        end
        _ENABLED[] = false                              # default OFF must survive the walk
        _flush_cache!()
        _HITS[] = 0
        _MISSES[] = 0
        _FALLBACKS[] = 0
    end
end

end # module

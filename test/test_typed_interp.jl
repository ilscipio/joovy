using Test
using Joovy

# Tests for the experimental typed-IR interpreter (src/TypedInterp.jl).
#
# Fixtures live at FILE top level, before the @testset: the testset body is a single
# top-level expression, so a `function` written inside it would be a local, and the
# world-age and thrash-guard scenarios need real methods they can redefine.
#
# The module is default OFF, so this file turns it on and MUST turn it back off at the
# end -- while it is on, TieredCompile wraps every new tier-0/tier-1 callable, which
# would leak into the test files that run after this one.

const TIP = Joovy.TypedInterp

# --- supported fixtures ------------------------------------------------------

ti_scalar(x::Int) = x * 3 + 7
ti_float(x::Float64) = sqrt(abs(x)) * 2.0 + sin(x)

struct TIPoint
    x::Float64
    y::Float64
end
ti_make(a::Float64, b::Float64) = TIPoint(a + 1.0, b * 2.0)
ti_norm(p::TIPoint) = sqrt(p.x * p.x + p.y * p.y)

function ti_array(v::Vector{Float64})
    s = 0.0
    n = 0
    for x in v
        y = abs(x)
        if y > 0.5
            s += sqrt(y)
            n += 1
        else
            s -= y * y
        end
    end
    return s + n
end

function ti_nested(n::Int)
    t = 0
    for i in 1:n
        for j in 1:n
            t += i * j
        end
    end
    return t
end

# Two mutually referencing phis at one block head: the parallel-copy case that a
# sequential phi commit gets wrong.
function ti_fibpair(n::Int)
    a = 0
    b = 1
    i = 1
    while i <= n
        a, b = b, a + b
        i += 1
    end
    return a * 1000 + b
end

function ti_swap(n::Int, a::Int, b::Int)
    i = 1
    while i <= n
        a, b = b, a
        i += 1
    end
    return a * 1000 + b
end

# PiNode: the `isa` narrowing inside the loop.
function ti_pi(v::Vector{Any})
    s = 0
    for x in v
        if x isa Int
            s += x
        end
    end
    return s
end

ti_union(b::Bool) = b ? 1 : 2.0          # Union{Int,Float64} return
ti_index(v::Vector{Int}, i::Int) = v[i] + v[end]
ti_string(s::String) = uppercase(s) * string(length(s))
ti_dict(d::Dict{String,Int}) = sum(values(d)) + length(keys(d))

const TI_CONST = 41
ti_global(x::Int) = x + TI_CONST         # GlobalRef read

function ti_closure(n::Int)
    acc = 0
    f = y -> y * 2
    for i in 1:n
        acc += f(i)
    end
    return acc
end

ti_make_adder(n::Int) = x -> x + n       # the returned closure is itself interpreted

# --- fixtures the accept-list must REJECT ------------------------------------

ti_try(x::Int) = try
    x < 0 ? error("negative") : x * 2
catch
    -1
end

# `jl_ver_major` is exported by libjulia on every platform, so the :foreigncall this
# puts in the IR is portable; the result is multiplied out so the value stays `x`.
ti_ccall(x::Int) = Int(ccall(:jl_ver_major, Cint, ())) * 0 + x
ti_kw(x::Int; k::Int = 3) = x * k
ti_va(xs::Int...) = sum(xs)
ti_opaque(n::Int) = (f = Base.Experimental.@opaque x -> x + n; f(1))

function ti_boxed(n::Int)                # captured mutable binding -> Core.Box
    acc = 0
    g = () -> (acc += n)
    for _ in 1:3
        g()
    end
    return acc
end

# --- helpers -----------------------------------------------------------------

# The set of statement kinds in the typed IR actually acquired for a signature, so the
# "every accepted node is exercised" claim is checked against the real IR rather than
# assumed from the source.
function ti_ir_kinds(f, tt; inline::Bool = false)
    ci = TIP._acquire_ir(f, tt, inline)
    ci === nothing && return Set{String}()
    return Set{String}(st isa Expr ? ":" * String(st.head) : string(nameof(typeof(st)))
                       for st in ci.code)
end

ti_cache_entry(f, tt) = get(TIP._CACHE, (typeof(f), tt), nothing)

# --- world-age fixture module ------------------------------------------------
# Redefinitions go through Core.eval into this module, so the generic function object
# stays the same while its body changes.
module TIWorld end
Core.eval(TIWorld, :(swapme(x::Int) = x + 1))

@testset "TypedInterp" begin
    table = ComparisonTable("TypedInterp: Typed-IR Interpretation vs Native Execution")

    # --- Test 1: default OFF ---
    @test typed_interp_enabled() == false
    @test typed_interp_inline() == false
    add_row!(table, "Disabled by default", false, typed_interp_enabled(), 0.0, 0.0)

    # A wrapper built while the switch is off is a pure pass-through.
    off_call = TypedInterpCallable(ti_scalar)
    @test off_call(5) == ti_scalar(5)
    @test typed_interp_stats().hits == 0
    add_row!(table, "Pass-through while OFF", ti_scalar(5), off_call(5), 0.0, 0.0)

    joovy_typed_interp!(true)
    typed_interp_clear!()
    @test typed_interp_enabled() == true

    # --- Test 2: result equality across workload shapes ---
    vec = Float64[i / 7 - 1.0 for i in 1:200]
    ints = [10, 20, 30, 40]
    dict = Dict("a" => 1, "b" => 2, "c" => 3)
    anyv = Any[1, "x", 2, 3.0, 4]

    cases = Any[
        ("scalar", ti_scalar, (5,)),
        ("float", ti_float, (2.5,)),
        ("array loop", ti_array, (vec,)),
        ("nested loops", ti_nested, (12,)),
        ("phi pair (fib)", ti_fibpair, (20,)),
        ("phi swap", ti_swap, (7, 3, 9)),
        ("PiNode / isa", ti_pi, (anyv,)),
        ("union return true", ti_union, (true,)),
        ("union return false", ti_union, (false,)),
        (":new (constructor)", TIPoint, (3.0, 4.0)),
        ("struct build", ti_make, (2.0, 3.0)),
        ("struct read", ti_norm, (TIPoint(3.0, 4.0),)),
        ("array index", ti_index, (ints, 2)),
        ("string", ti_string, ("hello",)),
        ("Dict", ti_dict, (dict,)),
        ("closure call", ti_closure, (10,)),
        ("closure object", ti_make_adder(5), (37,)),
        ("GlobalRef const", ti_global, (1,)),
    ]

    for (name, f, args) in cases
        native = Base.invokelatest(f, args...)
        tic = TypedInterpCallable(f)
        interp = tic(args...)
        @test TIP.typed_interp_supported(f, typeof(args))
        @test interp == native
        @test typeof(interp) === typeof(native)
        add_row!(table, name, native, interp, 0.0, 0.0)
    end

    # --- Test 3: every accepted IR node kind is really exercised ---
    covered = union(ti_ir_kinds(ti_pi, Tuple{Vector{Any}}),
                    ti_ir_kinds(ti_nested, Tuple{Int}),
                    ti_ir_kinds(ti_fibpair, Tuple{Int}),
                    ti_ir_kinds(ti_union, Tuple{Bool}),
                    ti_ir_kinds(TIPoint, Tuple{Float64,Float64}))
    for kind in (":call", ":invoke", ":new", "GotoNode", "GotoIfNot",
                 "PhiNode", "PiNode", "ReturnNode", "Nothing")
        @test kind in covered
    end
    add_row!(table, "IR node coverage", 9, count(k -> k in covered,
             (":call", ":invoke", ":new", "GotoNode", "GotoIfNot",
              "PhiNode", "PiNode", "ReturnNode", "Nothing")), 0.0, 0.0)

    # --- Test 4: the inline knob, where :boundscheck shows up ---
    typed_interp_inline!(true)
    @test typed_interp_inline() == true
    inline_kinds = ti_ir_kinds(ti_index, Tuple{Vector{Int},Int}; inline = true)
    @test ":boundscheck" in inline_kinds
    inline_call = TypedInterpCallable(ti_index)
    @test inline_call(ints, 2) == ti_index(ints, 2)
    @test inline_call(ints, 4) == ti_index(ints, 4)
    add_row!(table, "Inline mode: :boundscheck", ti_index(ints, 2), inline_call(ints, 2), 0.0, 0.0)
    typed_interp_inline!(false)
    @test typed_interp_inline() == false

    # --- Test 5: unsupported IR falls back and returns the SAME value ---
    typed_interp_clear!()
    rejects = Any[
        ("try/catch", ti_try, (5,)),
        ("ccall / foreigncall", ti_ccall, (5,)),
        ("kwargs signature", ti_kw, (5,)),
        ("varargs signature", ti_va, (1, 2, 3)),
        ("opaque closure", ti_opaque, (4,)),
        ("Core.Box capture", ti_boxed, (2,)),
    ]
    for (name, f, args) in rejects
        @test TIP.typed_interp_supported(f, typeof(args)) == false
        @test typed_interp_callable(f, typeof(args)) === nothing
        native = Base.invokelatest(f, args...)
        interp = TypedInterpCallable(f)(args...)
        @test interp == native
        add_row!(table, "Fallback: $name", native, interp, 0.0, 0.0)
    end
    @test typed_interp_stats().errors == 0      # rejection, never a runtime trip

    # Keyword calls always take the native path, even on a supported function.
    @test TypedInterpCallable(ti_kw)(5; k = 4) == 20
    add_row!(table, "Fallback: keyword call", 20, TypedInterpCallable(ti_kw)(5; k = 4), 0.0, 0.0)

    # The rejected try/catch fixture still catches its own error on the fallback path.
    @test TypedInterpCallable(ti_try)(-1) == -1

    # A callable whose `typeof` is a UnionAll (an unparameterized type constructor) must
    # route through the cache like anything else rather than raise on the key insert.
    @test TypedInterpCallable(Set)([1, 2, 3]) == Set([1, 2, 3])
    add_row!(table, "UnionAll callable", Set([1, 2, 3]), TypedInterpCallable(Set)([1, 2, 3]),
             0.0, 0.0)

    # --- Test 6: typed_interp_callable returns nothing vs a callable ---
    @test typed_interp_callable(ti_scalar, (Int,)) isa TypedInterpCallable
    @test typed_interp_callable(ti_scalar, Tuple{Int}) isa TypedInterpCallable
    @test typed_interp_callable(ti_va, (Int, Int)) === nothing
    @test_throws ArgumentError typed_interp_callable(ti_scalar, (Int,); mode = :deep)
    @test TypedInterpCallable(ti_scalar) isa AbstractJoovyCallable
    add_row!(table, "Is AbstractJoovyCallable", true,
             TypedInterpCallable(ti_scalar) isa AbstractJoovyCallable, 0.0, 0.0)

    # --- Test 7: stats accounting ---
    typed_interp_clear!()
    @test typed_interp_stats() == (entries = 0, hits = 0, misses = 0,
                                   fallbacks = 0, reinfers = 0, errors = 0)
    hit_call = TypedInterpCallable(ti_scalar)
    miss_call = TypedInterpCallable(ti_va)
    for i in 1:5
        hit_call(i)
    end
    for i in 1:3
        miss_call(i, i)
    end
    st = typed_interp_stats()
    @test st.hits == 5
    @test st.fallbacks == 3
    @test st.misses == 2            # one cache build per signature
    @test st.entries == 2
    @test st.errors == 0
    add_row!(table, "Stats: hits/fallbacks", "5/3", "$(st.hits)/$(st.fallbacks)", 0.0, 0.0)

    # --- Test 8: world age -- redefine, then interpret again ---
    typed_interp_clear!()
    world_call = TypedInterpCallable(TIWorld.swapme)
    @test world_call(10) == 11
    Core.eval(TIWorld, :(swapme(x::Int) = x + 100))
    @test world_call(10) == 110                       # new semantics, re-acquired IR
    @test Base.invokelatest(TIWorld.swapme, 10) == 110
    @test typed_interp_stats().reinfers >= 1
    add_row!(table, "World age: redefine", 110, world_call(10), 0.0, 0.0)

    # --- Test 9: hotswap fires the cache-flush hook ---
    typed_interp_clear!()
    TypedInterpCallable(ti_scalar)(1)
    @test typed_interp_stats().entries == 1
    hotswap_register!(:ti_hot, "ti_hot(x) = x + 1")
    hotswap_swap!(:ti_hot, "ti_hot(x) = x + 2")
    @test typed_interp_stats().entries == 0           # flushed by hotswap_swap!
    @test hotswap_call(:ti_hot, 1) == 3
    add_row!(table, "Hotswap flushes cache", 0, typed_interp_stats().entries, 0.0, 0.0)

    # --- Test 10: thrash guard trips above MAX_REINFER ---
    typed_interp_clear!()
    Core.eval(Main, :(ti_thrash(x::Int) = x * 11))
    thrash_fn = Base.invokelatest(getfield, Main, :ti_thrash)
    thrash_call = TypedInterpCallable(thrash_fn)
    @test Base.invokelatest(thrash_call, 3) == 33
    for i in 1:(TIP.MAX_REINFER + 2)
        # A method definition is what advances the world counter; nothing here goes
        # through joovy_recompile!, so the entry survives instead of being flushed.
        Core.eval(Main, :($(Symbol("ti_bump_", i))() = $i))
        @test Base.invokelatest(thrash_call, 3) == 33  # answer stays correct throughout
    end
    entry = ti_cache_entry(thrash_fn, Tuple{Int})
    @test entry !== nothing
    @test entry.reinfers > TIP.MAX_REINFER
    @test entry.disabled
    @test typed_interp_stats().fallbacks >= 1          # now served natively
    add_row!(table, "Thrash guard disables entry", true, entry.disabled, 0.0, 0.0)

    # --- Test 11: TieredCompile integration ---
    typed_interp_clear!()
    tc = joovy_compile_tiered("ti_tiered(x) = x * 4 + 1"; tier = 0, name = :ti_tiered,
                              promote_threshold = 10_000)
    @test tc.fn isa TypedInterpCallable                # wrapped because tier < 2
    @test tc(5) == 21
    promote!(tc; tier = 2)
    @test !(tc.fn isa TypedInterpCallable)             # promotion retires the wrapper
    @test tc(5) == 21
    add_row!(table, "Tier 0 wrapped, tier 2 raw", 21, tc(5), 0.0, 0.0)

    tc2 = joovy_compile_tiered("ti_tiered2(x) = x - 1"; tier = 2, name = :ti_tiered2)
    @test !(tc2.fn isa TypedInterpCallable)            # tier 2 is never wrapped
    @test tc2(5) == 4

    # --- Test 12: the Config key ---
    joovy_typed_interp!(false)
    @test typed_interp_enabled() == false
    Joovy.Config._apply_prefs!(Dict{String,Any}("typed_interp" => true))
    @test typed_interp_enabled() == true
    Joovy.Config._apply_prefs!(Dict{String,Any}("typed_interp" => "false"))
    @test typed_interp_enabled() == false
    Joovy.Config._apply_prefs!(Dict{String,Any}())     # leave config state clean
    add_row!(table, "Config typed_interp key", false, typed_interp_enabled(), 0.0, 0.0)

    # --- Test 13: back to the default OFF state for the rest of the suite ---
    joovy_typed_interp!(false)
    typed_interp_clear!()
    @test typed_interp_enabled() == false
    @test Joovy.TieredCompile._typed_interp_hook[] === nothing
    tc3 = joovy_compile_tiered("ti_tiered3(x) = x + 3"; tier = 0, name = :ti_tiered3,
                               promote_threshold = 10_000)
    @test !(tc3.fn isa TypedInterpCallable)
    @test tc3(5) == 8
    add_row!(table, "Switch off removes wrapper", 8, tc3(5), 0.0, 0.0)

    print_table(table)
    @test table_all_passed(table)
end

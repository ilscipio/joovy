# Tests for the CompileWatch submodule: SourcePos line tracking, the 9 static
# rules (true-positive AND false-positive fixture per rule, plus line
# accuracy), compile_watch_check (both raw-code and file-path forms), and the
# dynamic capture layer (capability probe + a real generated diagnostic) --
# verified live against this repo's Julia 1.12.3, per the design's dynamic
# layer table. Also covers the `allocation-heavy-method` dynamic rule, which
# reads Instrument's :full-mode per-call allocation tracking (Instrument.jl)
# rather than the compile-time capture layer.
#
# Included BEFORE the mock_flexible_ipc.jl include (see test/runtests.jl) --
# this file exercises the public Julia API directly, not IPC routes (that's
# test_compile_watch_ipc.jl, included after the mock).

using Test
using Joovy

const CW = Joovy.CompileWatch
const _cwtest_dir = @__DIR__

# Reset CompileWatch's session state between scenarios so one test's
# start!/stop! calls, thresholds, and accumulated diagnostics can't leak into
# the next (mirrors the `_reset_tier_state!` convention in test_config.jl).
_cw_reset!() = CW._reset!()

@testset "CompileWatch" begin

    # =====================================================================
    # 1. SourcePos: line-cursor tracking
    # =====================================================================
    @testset "SourcePos.each_positioned" begin
        src = """
        x = 1
        function f(a)
            b = a + 1
            b * 2
        end
        y = 2
        """
        ast = Joovy.SourcePos.parse_with_lines(src, "sp_test.jl")

        lines = Dict{Symbol,Int}()
        Joovy.SourcePos.each_positioned(ast) do node, line
            if node isa Expr && node.head === :(=) && node.args[1] === :x
                lines[:x] = line
            elseif node isa Expr && node.head === :(=) && node.args[1] === :y
                lines[:y] = line
            elseif node isa Expr && node.head === :call && length(node.args) >= 1 &&
                   node.args[1] === :* && node.args[2] === :b
                lines[:mul] = line
            end
        end
        @test lines[:x] == 1
        @test lines[:y] == 6
        @test lines[:mul] == 4   # statement nested inside the function body
    end

    # =====================================================================
    # 2. Static rules -- true-positive AND false-positive fixture per rule,
    #    plus a spot-check on reported line numbers.
    # =====================================================================
    @testset "rule: closure-arg-respecialization" begin
        tp = compile_watch_check("""
        function apply_cb(cb, x)
            cb(x) + 1
        end
        """)
        @test length(tp) == 1
        @test tp[1].rule_id === Symbol("closure-arg-respecialization")
        @test tp[1].severity === :warning
        @test tp[1].source === :static
        @test tp[1].method_name === :apply_cb
        @test tp[1].line == 2   # the `cb(x)` statement, not the def line
        @test tp[1].fix == Dict("kind" => "nospecialize-arg", "symbol" => "cb")

        fp_nospec = compile_watch_check("""
        function apply_cb2(cb, x)
            @nospecialize cb
            cb(x) + 1
        end
        """)
        @test isempty(fp_nospec)

        fp_inline_nospec = compile_watch_check("""
        function apply_cb3(@nospecialize(cb), x)
            cb(x) + 1
        end
        """)
        @test isempty(fp_inline_nospec)

        fp_invokelatest = compile_watch_check("""
        function apply_cb4(cb, x)
            Base.invokelatest(cb, x) + 1
        end
        """)
        @test isempty(fp_invokelatest)
    end

    @testset "rule: vararg-unbounded-splat" begin
        tp1 = compile_watch_check("""
        function va1(x...)
            sum(x)
        end
        """)
        @test length(tp1) == 1
        @test tp1[1].rule_id === Symbol("vararg-unbounded-splat")
        @test tp1[1].line == 1
        @test tp1[1].fix === nothing   # only closure-arg/int-float-acc/untyped-global attach a fix

        tp2 = compile_watch_check("""
        function va2(x::Vararg{Int})
            sum(x)
        end
        """)
        @test length(tp2) == 1
        @test tp2[1].rule_id === Symbol("vararg-unbounded-splat")

        fp = compile_watch_check("""
        function va3(x::Vararg{Int,3})
            sum(x)
        end
        """)
        @test isempty(fp)
    end

    @testset "rule: large-tuple-signature" begin
        tp_tuple = compile_watch_check("""
        function tup1(x::Tuple{Int,Int,Int,Int,Int,Int,Int,Int,Int})
            x
        end
        """)
        @test length(tp_tuple) == 1
        @test tp_tuple[1].rule_id === Symbol("large-tuple-signature")

        tp_ntuple = compile_watch_check("""
        function tup2(x::NTuple{9,Int})
            x
        end
        """)
        @test length(tp_ntuple) == 1

        fp = compile_watch_check("""
        function tup3(x::NTuple{3,Int})
            x
        end
        """)
        @test isempty(fp)
    end

    @testset "rule: untyped-global-in-fn" begin
        tp = compile_watch_check("""
        cw_threshold = 5
        function useglobal(x)
            x + cw_threshold
        end
        """)
        @test length(tp) == 1
        @test tp[1].rule_id === Symbol("untyped-global-in-fn")
        @test tp[1].severity === :warning   # high-confidence: same-file non-const global
        @test tp[1].line == 3
        @test tp[1].fix == Dict("kind" => "make-const", "symbol" => "cw_threshold", "def_line" => "1")

        fp_const = compile_watch_check("""
        const CW_THRESH = 5
        function useglobal2(x)
            x + CW_THRESH
        end
        """)
        @test isempty(fp_const)

        fp_local = compile_watch_check("""
        function useglobal3(x)
            y = x + 1
            y * 2
        end
        """)
        @test isempty(fp_local)

        fp_sibling = compile_watch_check("""
        function helper_fn(x)
            x + 1
        end
        function caller_fn(x)
            helper_fn(x)
        end
        """)
        @test isempty(fp_sibling)

        # Genuinely unresolvable name -> weaker :hint confidence, not :warning.
        hint = compile_watch_check("""
        function useglobal4(x)
            x + totally_unknown_name_xyz
        end
        """)
        @test length(hint) == 1
        @test hint[1].severity === :hint
        @test hint[1].fix === nothing   # only the same-file non-const-global sub-case gets a fix
    end

    @testset "rule: keyword-heavy-signature" begin
        tp = compile_watch_check("""
        function kw1(a; k1=1,k2=2,k3=3,k4=4,k5=5,k6=6,k7=7)
            a
        end
        """)
        @test length(tp) == 1
        @test tp[1].rule_id === Symbol("keyword-heavy-signature")

        fp = compile_watch_check("""
        function kw2(a; k1=1,k2=2,k3=3,k4=4,k5=5,k6=6)
            a
        end
        """)
        @test isempty(fp)
    end

    @testset "rule: val-type-proliferation" begin
        tp = compile_watch_check("""
        function valfn(i)
            Val(i)
        end
        """)
        @test length(tp) == 1
        @test tp[1].rule_id === Symbol("val-type-proliferation")
        @test tp[1].line == 2

        fp = compile_watch_check("""
        function valfn2(i)
            Val(1)
        end
        """)
        @test isempty(fp)
    end

    @testset "rule: deep-nested-parametric-signature" begin
        tp = compile_watch_check("""
        function nestfn(x::A{B{C{D{Int}}}})
            x
        end
        """)
        @test length(tp) == 1
        @test tp[1].rule_id === Symbol("deep-nested-parametric-signature")

        fp = compile_watch_check("""
        function nestfn2(x::Dict{String,Int})
            x
        end
        """)
        @test isempty(fp)
    end

    @testset "rule: long-broadcast-fusion-chain" begin
        _cw_reset!()
        rid = Symbol("long-broadcast-fusion-chain")

        # TP: a single statement chaining 9 dotted-operator calls (over the
        # default threshold of 8).
        tp_ops = compile_watch_check("""
        function chain_ops(a,b,c,d,e,f,g,h,i,j)
            a .+ b .* c .- d ./ e .^ f .+ g .* h .- i .+ j
        end
        """)
        hits = filter(d -> d.rule_id === rid, tp_ops)
        @test length(hits) == 1
        @test hits[1].severity === :hint
        @test hits[1].source === :static
        @test hits[1].line == 2
        @test hits[1].metric === nothing

        # TP: `f.(args)` broadcast-call sugar chained past the threshold.
        tp_dotcall = compile_watch_check("""
        function chain_dotcall(a)
            sin.(a) .+ cos.(a) .* tan.(a) .- exp.(a) ./ log.(a) .^ 2 .+ sqrt.(a) .- abs.(a) .+ a
        end
        """)
        hits2 = filter(d -> d.rule_id === rid, tp_dotcall)
        @test length(hits2) == 1

        # TP: every call inside an `@.` macrocall counts as a fused op too.
        tp_dotmacro = compile_watch_check("""
        function chain_dotmacro(a,b,c,d,e,f,g,h,i,j)
            @. a + b * c - d / e ^ f + g * h - i + j
        end
        """)
        hits3 = filter(d -> d.rule_id === rid, tp_dotmacro)
        @test length(hits3) == 1

        # FP: field-access chains (`Expr(:., x, QuoteNode)`) are NOT broadcast
        # calls and must never contribute to the count.
        fp_field = compile_watch_check("""
        function fieldchain(a)
            a.b.c.d.e.f.g.h.i.j
        end
        """)
        @test isempty(filter(d -> d.rule_id === rid, fp_field))

        # FP: a short dot-chain (well under the threshold) must not fire.
        fp_short = compile_watch_check("""
        function shortchain(a, b, c)
            a .+ b .* c
        end
        """)
        @test isempty(filter(d -> d.rule_id === rid, fp_short))

        # Config-overridable threshold: lowering it makes the short chain fire.
        compile_watch_set_thresholds!(broadcast_fusion_chain_over=1)
        tp_lowered = compile_watch_check("""
        function shortchain2(a, b, c)
            a .+ b .* c
        end
        """)
        @test length(filter(d -> d.rule_id === rid, tp_lowered)) == 1
        compile_watch_set_thresholds!(broadcast_fusion_chain_over=8)
        _cw_reset!()
    end

    @testset "rule: int-init-float-accumulator" begin
        _cw_reset!()
        rid = Symbol("int-init-float-accumulator")

        # TP (a): compound-assigned with an expression containing a float literal.
        tp_a = compile_watch_check("""
        function acc_compound_float(n)
            k3 = 0
            for i in 1:n
                k3 += i * 1.5
            end
            k3
        end
        """)
        hits_a = filter(d -> d.rule_id === rid, tp_a)
        @test length(hits_a) == 1
        @test hits_a[1].severity === :hint
        @test hits_a[1].source === :static
        @test hits_a[1].line == 2   # reported at the init line, not the promotion site
        @test hits_a[1].metric === nothing
        @test hits_a[1].fix == Dict("kind" => "float-init", "symbol" => "k3")

        # TP (b): plain assignment via division.
        tp_b1 = compile_watch_check("""
        function acc_division(n)
            k = 0
            k = k / n
            k
        end
        """)
        @test length(filter(d -> d.rule_id === rid, tp_b1)) == 1

        # TP (b): compound-assigned via `/=`.
        tp_b2 = compile_watch_check("""
        function acc_div_compound(n)
            k = 0
            k /= n
            k
        end
        """)
        @test length(filter(d -> d.rule_id === rid, tp_b2)) == 1

        # TP (c): reassigned to a bare float literal.
        tp_c = compile_watch_check("""
        function acc_float_lit(n)
            k = 0
            k = 2.0
            k
        end
        """)
        @test length(filter(d -> d.rule_id === rid, tp_c)) == 1

        # FP: a plain int accumulator that stays int must never fire.
        fp = compile_watch_check("""
        function acc_int_only(n)
            x = 0
            for i in 1:n
                x += 1
            end
            x
        end
        """)
        @test isempty(filter(d -> d.rule_id === rid, fp))

        # FP: an unrelated int local with no later reassignment at all.
        fp2 = compile_watch_check("""
        function acc_no_reassign(n)
            x = 0
            x
        end
        """)
        @test isempty(filter(d -> d.rule_id === rid, fp2))
        _cw_reset!()
    end

    # =====================================================================
    # 3. compile_watch_check: both entry-point forms
    # =====================================================================
    @testset "compile_watch_check entry points" begin
        # Raw code string (not an existing file path).
        diags = compile_watch_check("function cwcheck_a(cb, x)\n cb(x)\nend\n")
        @test length(diags) == 1
        @test diags[1].file == "<compile_watch_check>"

        # File path: reads via SourceProvider, reports the ABSOLUTE path.
        tmpfile = joinpath(_cwtest_dir, "scripts", "_cw_check_file.jl")
        write(tmpfile, "function cwcheck_b(cb, x)\n cb(x)\nend\n")
        diags2 = compile_watch_check(tmpfile)
        @test length(diags2) == 1
        @test diags2[1].file == abspath(tmpfile)
        @test diags2[1].line == 2
        rm(tmpfile; force=true)

        # No session state: repeated calls are independent, no start!/stop!.
        diags3 = compile_watch_check("f_noop(x) = x + 1\n")
        @test isempty(diags3)
    end

    # =====================================================================
    # 3b. CWDiagnostic: the old (pre-`fix`) 9-arg constructor still works
    # =====================================================================
    @testset "CWDiagnostic old-arity constructor" begin
        d = CWDiagnostic(Symbol("some-rule"), :warning, "some/path.jl", 7, :some_fn,
                          "some message", "some suggestion", :static, nothing)
        @test d.rule_id === Symbol("some-rule")
        @test d.severity === :warning
        @test d.file == "some/path.jl"
        @test d.line == 7
        @test d.method_name === :some_fn
        @test d.message == "some message"
        @test d.suggestion == "some suggestion"
        @test d.source === :static
        @test d.metric === nothing
        @test d.fix === nothing   # defaults to no fix hint at the old arity

        # A metric-carrying 9-arg call still defaults fix to nothing too.
        d2 = CWDiagnostic(Symbol("some-rule"), :warning, "p.jl", 1, :f,
                           "m", "s", :dynamic, Dict{String,Any}("x" => 1))
        @test d2.fix === nothing
    end

    # =====================================================================
    # 4. Wire snapshot shape (design section 4 contract)
    # =====================================================================
    @testset "wire snapshot shape" begin
        _cw_reset!()
        tmpfile = joinpath(_cwtest_dir, "scripts", "_cw_wire.jl")
        write(tmpfile, "function cw_wire_fn(cb, x)\n cb(x)\nend\n")

        result = compile_watch_start!(static=true, dynamic=false, paths=[tmpfile])
        @test result.static_diagnostic_count == 1

        snap = compile_watch_wire_snapshot()
        @test haskey(snap, "diagnostics")
        d = snap["diagnostics"][1]
        @test d["rule_id"] == "closure-arg-respecialization"   # kebab-case string
        @test d["severity"] == "warning"
        @test d["file"] == abspath(tmpfile)                    # absolute path
        @test d["line"] == 2                                    # 1-based
        @test d["method"] == "cw_wire_fn"
        @test d["source"] == "static"
        @test haskey(d, "message") && haskey(d, "suggestion") && haskey(d, "metric")
        @test d["fix"] == Dict("kind" => "nospecialize-arg", "symbol" => "cb")

        compile_watch_stop!()
        rm(tmpfile; force=true)
        _cw_reset!()
    end

    # =====================================================================
    # 5. Dynamic layer -- verified live on this repo's Julia 1.12.3.
    # =====================================================================
    @testset "dynamic layer: capability probe (1.12 jl_set_newly_inferred)" begin
        _cw_reset!()
        result = compile_watch_start!(static=false, dynamic=true)
        # Escalation per the task brief: if this ever fails on a future
        # Julia build, CompileWatch must downgrade gracefully (never silently
        # claim coverage) -- exercised structurally below regardless of the
        # outcome here.
        @test result.dynamic_active isa Bool
        if VERSION >= v"1.12-"
            @test result.dynamic_active == true
        end
        st = compile_watch_status()
        @test st.dynamic_requested == true
        @test st.dynamic_capable == result.dynamic_active
        compile_watch_stop!()
        @test compile_watch_status().dynamic_active == false
        _cw_reset!()
    end

    @testset "dynamic layer: generates a real diagnostic" begin
        _cw_reset!()
        compile_watch_set_thresholds!(specializations_over=0, inference_self_ms_over=0.0,
                                      reinfer_count_over=0)
        result = compile_watch_start!(static=false, dynamic=true)

        if result.dynamic_active
            # Defined in a FRESH, never-tiered module rather than Main: once
            # ANY code has run `joovy_compile_tiered`/`joovy_use`/etc. against
            # a module (setting `Base.Experimental.@compiler_options` on it,
            # even transiently), Julia 1.12's `jl_set_newly_inferred` silently
            # stops capturing NEW inferences for THAT module -- verified
            # directly while building this test (a clean module still
            # captures correctly; Main, after an earlier
            # `TieredCompile.set_module_tier!(Main, ...)` round-trip, does
            # not, even back at tier 2). Other test files in the suite tier
            # Main before this one runs, so isolating here keeps the test
            # meaningful regardless of run order -- see the task report for
            # this finding's real-world implication.
            m = Module(:CWDynamicTestMod)
            tmpfile = joinpath(_cwtest_dir, "scripts", "_cw_dynamic.jl")
            write(tmpfile, "cw_dynamic_test_fn(x) = x + 1\n")
            Base.include(m, tmpfile)   # a real, file-backed definition (method.file resolves)
            Base.invokelatest(Base.invokelatest(getfield, m, :cw_dynamic_test_fn), 1)

            diags = compile_watch_report()
            dyn = filter(d -> d.source === :dynamic && d.method_name === :cw_dynamic_test_fn, diags)
            @test !isempty(dyn)
            if !isempty(dyn)
                d = dyn[1]
                @test d.rule_id === Symbol("dynamic-specializations-over")
                @test d.severity === :warning
                @test d.file == abspath(tmpfile)
                @test d.line == 1
                @test d.metric !== nothing
                @test haskey(d.metric, "specializations")
                # A called method always has at least one specialization. Assert
                # the real count, not just the key: `Base.specializations` is
                # absent on Julia 1.9, and the fallback silently reporting 0
                # there is what let a lower-priority rule win this test before.
                @test d.metric["specializations"] > 0
            end
            rm(tmpfile; force=true)
        else
            @info "CompileWatch: dynamic capability unavailable in this test run -- static-only path exercised instead" VERSION
        end

        compile_watch_stop!()
        compile_watch_set_thresholds!(specializations_over=32, inference_self_ms_over=50.0,
                                      reinfer_count_over=3)
        _cw_reset!()
    end

    @testset "rule: dynamic-compile-time-over" begin
        _cw_reset!()
        # Push every OTHER threshold far out of reach so only compile_ms_over
        # can fire for this fixture, and push compile_ms_over to zero so any
        # measured total compile time -- however small -- is deterministic,
        # rather than depending on this machine's absolute speed.
        compile_watch_set_thresholds!(specializations_over=1_000_000,
            inference_self_ms_over=1_000_000.0, reinfer_count_over=1_000_000,
            compile_ms_over=0.0)
        result = compile_watch_start!(static=false, dynamic=true)

        if result.dynamic_active
            # Same fresh-module idiom as "dynamic layer: generates a real
            # diagnostic" above (a previously-tiered module stops capturing new
            # inferences on 1.12 -- see that test's comment). A generously
            # sized body (hundreds of distinct statements) forces measurable
            # inference + codegen time even on a fast machine.
            m = Module(:CWSlowCompileTestMod)
            tmpfile = joinpath(_cwtest_dir, "scripts", "_cw_slow_compile.jl")
            body_lines = String["function cw_slow_compile_fn(a)"]
            for i in 1:400
                push!(body_lines, "    x$(i) = a + $(i) * 1 - $(i)")
            end
            push!(body_lines, "    return x400")
            push!(body_lines, "end")
            write(tmpfile, join(body_lines, "\n") * "\n")
            Base.include(m, tmpfile)   # a real, file-backed definition (method.file resolves)
            Base.invokelatest(Base.invokelatest(getfield, m, :cw_slow_compile_fn), 1)

            diags = compile_watch_report()
            dyn = filter(d -> d.rule_id === Symbol("dynamic-compile-time-over") &&
                              d.method_name === :cw_slow_compile_fn, diags)
            # Julia < 1.12 has no per-CodeInstance codegen time, so this rule
            # is unconditionally silent there by design -- see
            # `_DYNAMIC_HAS_COMPILE_TIME` in CompileWatch.jl. Key the branch on
            # that constant, not on `dynamic_active`: the 1.9-1.11 legacy
            # capture layer DOES activate, it just carries no compile time.
            if CW._DYNAMIC_HAS_COMPILE_TIME
                @test !isempty(dyn)
                if !isempty(dyn)
                    d = dyn[1]
                    @test d.severity === :warning
                    @test d.source === :dynamic
                    @test d.file == abspath(tmpfile)
                    @test d.line == 1
                    @test d.metric !== nothing
                    @test haskey(d.metric, "compile_ms")
                    @test haskey(d.metric, "infer_ms")
                    @test d.metric["compile_ms"] > 0
                    @test d.fix === nothing   # dynamic-compile-time-over never attaches a fix hint
                end
            else
                # Assert the documented silence rather than skipping, so a
                # future change that starts emitting this rule pre-1.12 is
                # caught here instead of passing unnoticed.
                @test isempty(dyn)
            end
            rm(tmpfile; force=true)
        else
            @info "CompileWatch: dynamic capability unavailable in this test run -- dynamic-compile-time-over not exercised" VERSION
        end

        compile_watch_stop!()
        compile_watch_set_thresholds!(specializations_over=32, inference_self_ms_over=50.0,
                                      reinfer_count_over=3, compile_ms_over=100.0)
        _cw_reset!()
    end

    @testset "dynamic layer: allocation-heavy-method (Instrument :full mode)" begin
        _cw_reset!()
        Joovy.reset_counters!()
        compile_watch_set_thresholds!(alloc_bytes_per_call_over=1000)
        result = compile_watch_start!(static=false, dynamic=true)

        if result.dynamic_active
            # A vectorized chain of SEPARATE broadcast statements: each line
            # (b, c, d, e) allocates its own full intermediate array before
            # the next step even starts -- the study's "non-fused vectorized
            # chains allocate an intermediate per step" pattern.
            tmpfile = joinpath(_cwtest_dir, "scripts", "_cw_alloc_chain.jl")
            write(tmpfile, """
            function cw_alloc_chain_fn(n)
                a = ones(n, n)
                b = a .* 2.0
                c = b .+ 1.0
                d = sqrt.(c)
                e = d .- 0.5
                return e
            end
            """)
            code = read(tmpfile, String)
            Joovy.joovy_exec(code; instrument=:full, path=tmpfile)
            for _ in 1:5
                Base.invokelatest(Base.invokelatest(getfield, Main, :cw_alloc_chain_fn), 50)
            end

            diags = compile_watch_report()
            hit = filter(d -> d.rule_id === Symbol("allocation-heavy-method") &&
                              d.method_name === :cw_alloc_chain_fn, diags)
            @test !isempty(hit)
            if !isempty(hit)
                d = hit[1]
                @test d.severity === :warning
                @test d.source === :dynamic
                @test d.file == abspath(tmpfile)
                @test d.line == 1
                @test d.metric !== nothing
                @test haskey(d.metric, "bytes_per_call")
                @test haskey(d.metric, "calls")
                @test d.metric["calls"] == 5
                @test d.metric["bytes_per_call"] > 1000
            end
            rm(tmpfile; force=true)

            # FP: a non-allocating function must not fire, even instrumented
            # and called the same way.
            Joovy.joovy_exec("cw_alloc_noalloc_fn(x) = x + 1\n"; instrument=:full)
            for _ in 1:5
                Base.invokelatest(Base.invokelatest(getfield, Main, :cw_alloc_noalloc_fn), 1)
            end
            diags2 = compile_watch_report()
            @test isempty(filter(d -> d.rule_id === Symbol("allocation-heavy-method") &&
                                      d.method_name === :cw_alloc_noalloc_fn, diags2))
        else
            @info "CompileWatch: dynamic capability unavailable in this test run -- allocation-heavy-method not exercised" VERSION
        end

        compile_watch_stop!()
        compile_watch_set_thresholds!(alloc_bytes_per_call_over=1_000_000)
        Joovy.reset_counters!()
        _cw_reset!()
    end

    # =====================================================================
    # 6. Config `compile_watch` on/off key
    # =====================================================================
    @testset "Config compile_watch toggle" begin
        _cw_reset!()
        Cfg = Joovy.Config

        Cfg._apply_prefs!(Dict{String,Any}("compile_watch" => "on"))
        @test compile_watch_status().running == true

        Cfg._apply_prefs!(Dict{String,Any}("compile_watch" => "off"))
        @test compile_watch_status().running == false

        # Invalid value: warns, does not change state, does not throw.
        Cfg._apply_prefs!(Dict{String,Any}("compile_watch" => "on"))
        @test compile_watch_status().running == true
        @test_logs (:warn,) match_mode=:any Cfg._apply_prefs!(
            Dict{String,Any}("compile_watch" => "sideways"))
        @test compile_watch_status().running == true   # unchanged by the ignored invalid value

        Cfg._apply_prefs!(Dict{String,Any}("compile_watch" => "off"))
        _cw_reset!()
    end

    _cw_reset!()
end

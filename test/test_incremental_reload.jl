using Test
using Joovy

@testset "Incremental Reload" begin
    table = ComparisonTable("Incremental Reload: Per-Definition Diffing & Single-Compile Multi-Entry Reload")

    test_dir = @__DIR__

    # =====================================================================
    # Test 1: 5 defs, first load (all added), then edit 1 def -> only that
    # def is reported changed, the other 4 are unchanged.
    # =====================================================================
    file5 = joinpath(test_dir, "scripts", "_incr_five_defs.jl")
    write(file5, """
    incr5_f1(x) = x + 1
    incr5_f2(x) = x + 2
    incr5_f3(x) = x + 3
    incr5_f4(x) = x + 4
    incr5_f5(x) = x + 5
    """)

    r1 = joovy_hot_reload(file5)
    @test r1.status == "ok"
    @test Set(r1.fallback_added) == Set([:incr5_f1, :incr5_f2, :incr5_f3, :incr5_f4, :incr5_f5])
    @test isempty(r1.fallback_changed)
    @test isempty(r1.fallback_unchanged)

    add_row!(table, "First load: 5 added", 5, length(r1.fallback_added), 0.0, 0.0)

    write(file5, """
    incr5_f1(x) = x + 1
    incr5_f2(x) = x + 2
    incr5_f3(x) = x + 30
    incr5_f4(x) = x + 4
    incr5_f5(x) = x + 5
    """)
    sleep(0.05)

    r2 = joovy_hot_reload(file5)
    @test r2.status == "ok"
    @test r2.fallback_changed == [:incr5_f3]
    @test length(r2.fallback_unchanged) == 4
    @test isempty(r2.fallback_added)
    @test isempty(r2.fallback_removed)
    @test Base.invokelatest(Main.incr5_f3, 1) == 31

    add_row!(table, "Edit 1 of 5 defs", 1, length(r2.fallback_changed), 0.0, 0.0)
    add_row!(table, "4 unchanged after edit", 4, length(r2.fallback_unchanged), 0.0, 0.0)

    # =====================================================================
    # Test 2 & 6: unchanged save is a physical no-op re-eval (proven via a
    # side-effecting const marker); incremental=false forces re-eval again.
    # =====================================================================
    Main.eval(:(_incr_side_log = Ref(0)))

    marker_file = joinpath(test_dir, "scripts", "_incr_marker.jl")
    write(marker_file, "const _incr_marker = (Main._incr_side_log[] += 1; 1)\n")

    rm1 = joovy_hot_reload(marker_file)
    @test rm1.status == "ok"
    @test :_incr_marker in rm1.fallback_added
    @test Main._incr_side_log[] == 1

    add_row!(table, "Marker: first load side effect", 1, Main._incr_side_log[], 0.0, 0.0)

    # Test 2: unchanged save must NOT re-run the marker's side effect.
    rm2 = joovy_hot_reload(marker_file)
    @test rm2.status == "ok"
    @test isempty(rm2.fallback_changed)
    @test isempty(rm2.fallback_added)
    @test Main._incr_side_log[] == 1

    add_row!(table, "Marker: unchanged save (no re-eval)", 1, Main._incr_side_log[], 0.0, 0.0)

    # Test 6: incremental=false forces the marker to re-run even though the
    # file did not change on disk.
    rm3 = joovy_hot_reload(marker_file; incremental=false)
    @test rm3.status == "ok"
    @test Main._incr_side_log[] == 2

    add_row!(table, "Marker: incremental=false re-evals", 2, Main._incr_side_log[], 0.0, 0.0)

    # =====================================================================
    # Test 3 & 4: added def is reported; removed def is reported (old
    # method stays callable via invokelatest -- documented limitation).
    # =====================================================================
    ar_file = joinpath(test_dir, "scripts", "_incr_add_remove.jl")
    write(ar_file, """
    incr_ar_f1(x) = x + 1
    incr_ar_f2(x) = x + 2
    """)

    ar1 = joovy_hot_reload(ar_file)
    @test Set(ar1.fallback_added) == Set([:incr_ar_f1, :incr_ar_f2])

    # Add a third def.
    write(ar_file, """
    incr_ar_f1(x) = x + 1
    incr_ar_f2(x) = x + 2
    incr_ar_f3(x) = x + 3
    """)
    sleep(0.05)

    ar2 = joovy_hot_reload(ar_file)
    @test ar2.fallback_added == [:incr_ar_f3]
    @test isempty(ar2.fallback_changed)
    @test length(ar2.fallback_unchanged) == 2

    add_row!(table, "Added def detected", 1, length(ar2.fallback_added), 0.0, 0.0)

    # Remove the first def.
    write(ar_file, """
    incr_ar_f2(x) = x + 2
    incr_ar_f3(x) = x + 3
    """)
    sleep(0.05)

    ar3 = joovy_hot_reload(ar_file)
    @test ar3.fallback_removed == [:incr_ar_f1]
    @test length(ar3.fallback_unchanged) == 2
    @test Base.invokelatest(Main.incr_ar_f1, 10) == 11  # stale method still callable

    add_row!(table, "Removed def detected", 1, length(ar3.fallback_removed), 0.0, 0.0)
    add_row!(table, "Stale removed fn still callable", 11, Base.invokelatest(Main.incr_ar_f1, 10), 0.0, 0.0)

    # =====================================================================
    # Test 5: N=3 SwapEntries backed by ONE file get a SINGLE compile on
    # reload, and each entry resolves to its OWN function (regression test
    # for the "every entry silently gets the file's first function" bug).
    # =====================================================================
    registry5 = HotSwapRegistry()
    hs_file = joinpath(test_dir, "scripts", "_incr_hotswap3.jl")
    write(hs_file, """
    function incr_hs3_a(x)
        return x + 100
    end

    function incr_hs3_b(x)
        return x + 200
    end

    function incr_hs3_c(x)
        return x + 300
    end
    """)

    hotswap_load_file!(:incr_hs3_a, hs_file; registry=registry5)
    hotswap_load_file!(:incr_hs3_b, hs_file; registry=registry5)
    hotswap_load_file!(:incr_hs3_c, hs_file; registry=registry5)

    counter_before = Joovy.DynCompiler._compile_counter[]

    write(hs_file, """
    function incr_hs3_a(x)
        return x * 10
    end

    function incr_hs3_b(x)
        return x * 20
    end

    function incr_hs3_c(x)
        return x * 30
    end
    """)
    sleep(0.05)

    hs_result = joovy_hot_reload(hs_file; registry=registry5)
    @test hs_result.status == "ok"
    @test Set(hs_result.reloaded) == Set([:incr_hs3_a, :incr_hs3_b, :incr_hs3_c])

    counter_after = Joovy.DynCompiler._compile_counter[]
    @test counter_after - counter_before == 1

    ra = hotswap_call(:incr_hs3_a, 5; registry=registry5)
    rb = hotswap_call(:incr_hs3_b, 5; registry=registry5)
    rc = hotswap_call(:incr_hs3_c, 5; registry=registry5)
    @test ra == 50
    @test rb == 100
    @test rc == 150

    add_row!(table, "Single compile for 3 entries", 1, counter_after - counter_before, 0.0, 0.0)
    add_row!(table, "Entry a keeps its own fn", 50, ra, 0.0, 0.0)
    add_row!(table, "Entry b keeps its own fn", 100, rb, 0.0, 0.0)
    add_row!(table, "Entry c keeps its own fn", 150, rc, 0.0, 0.0)

    # =====================================================================
    # Test 7: lazy-module regression -- reload routing must still pick the
    # lazy_incremental path (unaffected by the full_reload changes).
    # =====================================================================
    lazy_file = joinpath(test_dir, "scripts", "_incr_lazy.jl")
    write(lazy_file, """
    incr_lazy_helper(x) = x * 2

    function incr_lazy_compute(x)
        incr_lazy_helper(x) + 1
    end
    """)

    lm7 = joovy_use(lazy_file; tier=1)
    lock(Joovy.IpcBridge._lazy_modules_lock) do
        Joovy.IpcBridge._lazy_modules[abspath(lazy_file)] = lm7
    end

    resp7 = Joovy.IpcBridge._handle_reload(Dict{String,Any}("file" => lazy_file))
    @test resp7["mode"] == "lazy_incremental"

    add_row!(table, "Lazy path still routed", "lazy_incremental", resp7["mode"], 0.0, 0.0)

    # Cleanup
    lock(Joovy.IpcBridge._lazy_modules_lock) do
        delete!(Joovy.IpcBridge._lazy_modules, abspath(lazy_file))
    end
    rm(file5; force=true)
    rm(marker_file; force=true)
    rm(ar_file; force=true)
    rm(hs_file; force=true)
    rm(lazy_file; force=true)

    print_table(table)
    @test table_all_passed(table)
end

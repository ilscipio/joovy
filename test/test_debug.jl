using Test
using Joovy

@testset "Debug" begin
    table = ComparisonTable("Debug: Source Maps, Hot-Reload & Frame Filtering")

    # --- Test 1: Source map created on compile ---
    fn = joovy_compile("debug_add(x, y) = x + y")
    mapping = source_map_lookup(:debug_add)

    @test mapping !== nothing
    @test :debug_add in mapping.original_names
    @test length(mapping.compiled_names) == 1

    compiled_name = mapping.compiled_names[1]
    @test occursin("_joovy_", string(compiled_name))

    add_row!(table, "Source map created", true, mapping !== nothing, 0.0, 0.0)

    # --- Test 2: Source map reverse lookup ---
    original = source_map_reverse(compiled_name)
    @test original === :debug_add
    add_row!(table, "Reverse lookup", "debug_add", string(original), 0.0, 0.0)

    # --- Test 3: Reverse lookup returns nothing for non-joovy names ---
    @test source_map_reverse(:normal_function) === nothing
    add_row!(table, "Reverse non-joovy", "nothing", string(source_map_reverse(:normal_function)), 0.0, 0.0)

    # --- Test 4: is_joovy_frame detection ---
    @test is_joovy_frame(string(compiled_name))
    @test is_joovy_frame("invokelatest")
    @test !is_joovy_frame("my_function")
    @test !is_joovy_frame("add")
    add_row!(table, "Frame detection", true, is_joovy_frame(string(compiled_name)), 0.0, 0.0)

    # --- Test 5: clean_frame_name strips suffix ---
    cleaned = clean_frame_name(string(compiled_name))
    @test cleaned == "debug_add"
    add_row!(table, "Clean frame name", "debug_add", cleaned, 0.0, 0.0)

    # --- Test 6: clean_frame_name passes through non-joovy names ---
    @test clean_frame_name("regular_fn") == "regular_fn"
    add_row!(table, "Clean passthrough", "regular_fn", clean_frame_name("regular_fn"), 0.0, 0.0)

    # --- Test 7: Multi-function source map ---
    joovy_compile("""
        function debug_outer(x)
            debug_inner(x) + 1
        end
        function debug_inner(x)
            x * 2
        end
    """)

    map_outer = source_map_lookup(:debug_outer)
    map_inner = source_map_lookup(:debug_inner)
    @test map_outer !== nothing
    @test map_inner !== nothing
    @test map_outer === map_inner  # same mapping object, both functions compiled together

    add_row!(table, "Multi-fn source map", 2, length(map_outer.original_names), 0.0, 0.0)

    # --- Test 8: Hot reload with registered functions ---
    test_dir = @__DIR__
    tmpfile = joinpath(test_dir, "scripts", "_debug_hotreload.jl")
    registry = HotSwapRegistry()

    write(tmpfile, "debug_proc(x) = x + 1\n")
    hotswap_load_file!(:debug_proc, tmpfile; registry=registry)

    r1 = hotswap_call(:debug_proc, 10; registry=registry)
    @test r1 == 11

    write(tmpfile, "debug_proc(x) = x * 100\n")
    sleep(0.05)

    result = joovy_hot_reload(tmpfile; registry=registry)
    @test result.status == "ok"
    @test :debug_proc in result.reloaded

    r2 = hotswap_call(:debug_proc, 10; registry=registry)
    @test r2 == 1000

    add_row!(table, "Hot reload registered", r2, 1000, 0.0, 0.0)

    # --- Test 9: Hot reload no-op when unchanged ---
    result2 = joovy_hot_reload(tmpfile; registry=registry)
    @test result2.status == "ok"
    @test isempty(result2.reloaded)
    @test :debug_proc in result2.unchanged

    add_row!(table, "Hot reload no-op", 0, length(result2.reloaded), 0.0, 0.0)

    # --- Test 10: Hot reload fallback for unregistered files ---
    tmpfile2 = joinpath(test_dir, "scripts", "_debug_fallback.jl")
    write(tmpfile2, "debug_fallback_fn(x) = x + 999\n")

    result3 = joovy_hot_reload(tmpfile2)
    @test result3.status == "ok"
    @test result3.fallback_definitions == 1

    r3 = Base.invokelatest(Main.debug_fallback_fn, 1)
    @test r3 == 1000

    add_row!(table, "Hot reload fallback", 1, result3.fallback_definitions, 0.0, 0.0)

    # --- Test 11: Hot reload error for missing file ---
    result4 = joovy_hot_reload("/nonexistent/file.jl")
    @test result4.status == "error"
    add_row!(table, "Hot reload missing", "error", result4.status, 0.0, 0.0)

    # --- Test 12: Debug info retrieval ---
    info = joovy_debug_info(:debug_add)
    @test info !== nothing
    @test :debug_add in info.original_names
    @test info.compile_id > 0

    add_row!(table, "Debug info", true, info !== nothing, 0.0, 0.0)

    # --- Test 13: IPC bridge availability (no IDE connected) ---
    @test !joovy_ipc_available()
    add_row!(table, "IPC (no IDE)", false, joovy_ipc_available(), 0.0, 0.0)

    # --- Test 14: Session with debug features ---
    session = JoovySession()
    sfn = session_compile(session, "session_debug_fn(x) = x^2"; name=:sdfn)
    @test sfn(5) == 25

    status = session_status(session)
    @test !isempty(status.source_maps)
    @test status.ide_connected == false

    add_row!(table, "Session debug status", true, !isempty(status.source_maps), 0.0, 0.0)

    # --- Test 15: Session hot reload ---
    write(tmpfile, "debug_proc(x) = x - 1\n")
    sleep(0.05)
    reload_result = session_hot_reload(session, tmpfile)

    add_row!(table, "Session hot reload", "ok", reload_result.status, 0.0, 0.0)

    # Cleanup
    rm(tmpfile; force=true)
    rm(tmpfile2; force=true)

    print_table(table)
    @test table_all_passed(table)
end

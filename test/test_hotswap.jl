using Test
using Joovy

@testset "HotSwap" begin
    table = ComparisonTable("HotSwap: Inline File Updates & Live Code Replacement")

    registry = HotSwapRegistry()

    # --- Test 1: Register and call ---
    hotswap_register!(:calc, "calc_hs(x) = x * 2"; registry=registry)

    t0 = time_ns()
    native_r = 10 * 2
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    joovy_r = hotswap_call(:calc, 10; registry=registry)
    ft = Float64(time_ns() - t0)

    @test native_r == joovy_r
    add_row!(table, "Register + call v1", native_r, joovy_r, nt, ft)

    # --- Test 2: Swap to new implementation ---
    hotswap_swap!(:calc, "calc_hs(x) = x * 3 + 1"; registry=registry)

    t0 = time_ns()
    native_r = 10 * 3 + 1
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    joovy_r = hotswap_call(:calc, 10; registry=registry)
    ft = Float64(time_ns() - t0)

    @test native_r == joovy_r
    add_row!(table, "Swap to v2 (x*3+1)", native_r, joovy_r, nt, ft)

    # --- Test 3: Version tracking ---
    v = hotswap_version(:calc; registry=registry)
    @test v == 2
    add_row!(table, "Version after swap", 2, v, 0.0, 0.0)

    # --- Test 4: Swap again ---
    hotswap_swap!(:calc, "calc_hs(x) = x ^ 2 - x"; registry=registry)

    t0 = time_ns()
    native_r = 10^2 - 10
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    joovy_r = hotswap_call(:calc, 10; registry=registry)
    ft = Float64(time_ns() - t0)

    @test native_r == joovy_r
    add_row!(table, "Swap to v3 (x^2-x)", native_r, joovy_r, nt, ft)

    # --- Test 5: History tracking ---
    hist = hotswap_history(:calc; registry=registry)
    @test length(hist) == 3
    add_row!(table, "History length", 3, length(hist), 0.0, 0.0)

    # --- Test 6: FILE-BASED HOT-SWAP (the key test) ---
    test_dir = @__DIR__
    tmpfile = joinpath(test_dir, "scripts", "_hotswap_test.jl")

    # Write v1
    write(tmpfile, """
        function hotswap_file_fn(x)
            return x + 100
        end
    """)

    hotswap_load_file!(:file_fn, tmpfile; registry=registry)

    t0 = time_ns()
    native_v1 = 5 + 100
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    joovy_v1 = hotswap_call(:file_fn, 5; registry=registry)
    ft = Float64(time_ns() - t0)

    @test native_v1 == joovy_v1
    add_row!(table, "File load v1 (x+100)", native_v1, joovy_v1, nt, ft)

    # --- Test 7: Modify the file on disk and reload ---
    write(tmpfile, """
        function hotswap_file_fn(x)
            return x * 10 + 7
        end
    """)

    sleep(0.1)
    hotswap_reload!(:file_fn; registry=registry)

    t0 = time_ns()
    native_v2 = 5 * 10 + 7
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    joovy_v2 = hotswap_call(:file_fn, 5; registry=registry)
    ft = Float64(time_ns() - t0)

    @test native_v2 == joovy_v2
    add_row!(table, "File reload v2 (x*10+7)", native_v2, joovy_v2, nt, ft)

    # --- Test 8: Modify again — third version ---
    write(tmpfile, """
        function hotswap_file_fn(x)
            return x ^ 3
        end
    """)

    sleep(0.1)
    hotswap_reload!(:file_fn; registry=registry)

    t0 = time_ns()
    native_v3 = 5^3
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    joovy_v3 = hotswap_call(:file_fn, 5; registry=registry)
    ft = Float64(time_ns() - t0)

    @test native_v3 == joovy_v3
    add_row!(table, "File reload v3 (x^3)", native_v3, joovy_v3, nt, ft)

    v = hotswap_version(:file_fn; registry=registry)
    @test v == 3
    add_row!(table, "File version count", 3, v, 0.0, 0.0)

    # --- Test 9: No-op reload when file hasn't changed ---
    hotswap_reload!(:file_fn; registry=registry)
    v_same = hotswap_version(:file_fn; registry=registry)
    @test v_same == 3
    add_row!(table, "No-op reload (same)", 3, v_same, 0.0, 0.0)

    # --- Test 10: Multiple named functions ---
    hotswap_register!(:fn_a, "fn_a_hs(x) = x + 1"; registry=registry)
    hotswap_register!(:fn_b, "fn_b_hs(x) = x * 2"; registry=registry)

    t0 = time_ns()
    native_chain = (5 + 1) * 2
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    r_a = hotswap_call(:fn_a, 5; registry=registry)
    r_b = hotswap_call(:fn_b, r_a; registry=registry)
    ft = Float64(time_ns() - t0)

    @test native_chain == r_b
    add_row!(table, "Chain fn_a → fn_b", native_chain, r_b, nt, ft)

    # Swap fn_a mid-chain
    hotswap_swap!(:fn_a, "fn_a_hs(x) = x + 100"; registry=registry)

    t0 = time_ns()
    native_chain2 = (5 + 100) * 2
    nt = Float64(time_ns() - t0)

    t0 = time_ns()
    r_a2 = hotswap_call(:fn_a, 5; registry=registry)
    r_b2 = hotswap_call(:fn_b, r_a2; registry=registry)
    ft = Float64(time_ns() - t0)

    @test native_chain2 == r_b2
    add_row!(table, "Swapped chain result", native_chain2, r_b2, nt, ft)

    # Cleanup temp file
    rm(tmpfile; force=true)

    print_table(table)
    @test table_all_passed(table)
end

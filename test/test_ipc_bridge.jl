# Tests for the IPC bridge (IpcBridge submodule): handler registration, the
# joovy/ready version notification, and -- for every registered route -- that
# malformed parameters (JSON null, wrong type, missing key) return a graceful
# `"status" => "error"` Dict instead of throwing, alongside a cheap happy path
# per route where one is feasible.
#
# Included LAST (see test/runtests.jl): handlers mutate a lot of shared global
# state (lazy modules, package tiers, dev mode, speculation), so this file
# both depends on Main.FlexibleIPC (the mock, included immediately before this
# file) and cleans that shared state back up at the end for any tooling that
# runs after the suite.

using Test
using Joovy

const _ipc_test_dir = @__DIR__
const FIPC = Main.FlexibleIPC

# Call a route through the ACTUAL registered handler (i.e. through the same
# `Base.invokelatest` wrapper `joovy_register_ipc_handlers!` installs), not by
# reaching into `Joovy.IpcBridge._handle_*` directly.
call(route::String, params::Dict) = FIPC.call(route, params)

@testset "IpcBridge" begin

    # =====================================================================
    # 0. Registration + joovy/ready notification
    # =====================================================================
    @testset "registration + ready notification" begin
        FIPC.reset_notifications!()
        @test Joovy.joovy_register_ipc_handlers!() == true
        @test Joovy.joovy_register_ipc_handlers!() == true   # idempotent

        ready = [n for n in FIPC._notifications if n[1] == "joovy/ready"]
        @test !isempty(ready)
        version = ready[end][2]["version"]
        @test version == string(Base.pkgversion(Joovy))
        @test version != "unknown"
    end

    # =====================================================================
    # 1. compile
    # =====================================================================
    @testset "compile" begin
        @test call("compile", Dict{String,Any}("code" => nothing))["status"] == "error"
        @test call("compile", Dict{String,Any}("code" => 42))["status"] == "error"
        @test call("compile", Dict{String,Any}())["status"] == "error"
        @test call("compile", Dict{String,Any}(
            "code" => "ipc_compile_named(x) = x + 1", "name" => 42))["status"] == "error"

        r = call("compile", Dict{String,Any}(
            "code" => "ipc_compile_named(x) = x + 1", "name" => "ipc_compile_named"))
        @test r["status"] == "ok"
        @test r["name"] == "ipc_compile_named"
        @test haskey(r, "compiled_name")
    end

    # =====================================================================
    # 2. swap
    # =====================================================================
    @testset "swap" begin
        @test call("swap", Dict{String,Any}("name" => nothing, "code" => "x = 1"))["status"] == "error"
        @test call("swap", Dict{String,Any}("name" => "ipc_swap_fn"))["status"] == "error"          # missing code
        @test call("swap", Dict{String,Any}("code" => "x = 1"))["status"] == "error"                # missing name
        @test call("swap", Dict{String,Any}("name" => 42, "code" => "x = 1"))["status"] == "error"   # wrong-typed name

        Joovy.hotswap_register!(:ipc_swap_fn, "ipc_swap_fn(x) = x + 1")
        r = call("swap", Dict{String,Any}("name" => "ipc_swap_fn", "code" => "ipc_swap_fn(x) = x + 100"))
        @test r["status"] == "ok"
        @test r["new_version"] == 2
        @test Joovy.hotswap_call(:ipc_swap_fn, 1) == 101
    end

    # =====================================================================
    # 3. reload (full_reload mode -- no lazy module registered for this path)
    # =====================================================================
    @testset "reload" begin
        @test call("reload", Dict{String,Any}("file" => nothing))["status"] == "error"
        @test call("reload", Dict{String,Any}())["status"] == "error"
        @test call("reload", Dict{String,Any}("file" => "x.jl", "incremental" => "yes"))["status"] == "error"

        tmpfile = joinpath(_ipc_test_dir, "scripts", "_ipc_reload.jl")
        write(tmpfile, "ipc_reload_fn(x) = x + 1\n")
        r = call("reload", Dict{String,Any}("file" => tmpfile))
        @test r["status"] == "ok"
        @test r["mode"] == "full_reload"

        rm(tmpfile; force=true)
    end

    # =====================================================================
    # 4. status
    # =====================================================================
    @testset "status" begin
        r = call("status", Dict{String,Any}("garbage" => 1))   # unused params never throw
        @test haskey(r, "cache_hits")
        @test haskey(r, "registered_functions")
        @test r["ipc_connected"] == true
    end

    # =====================================================================
    # 5. source_map
    # =====================================================================
    @testset "source_map" begin
        @test call("source_map", Dict{String,Any}("name" => nothing))["status"] == "error"
        @test call("source_map", Dict{String,Any}("name" => 42))["status"] == "error"
        @test call("source_map", Dict{String,Any}())["status"] == "error"

        call("compile", Dict{String,Any}(
            "code" => "ipc_srcmap_fn(x) = x * 2", "name" => "ipc_srcmap_fn"))
        r = call("source_map", Dict{String,Any}("name" => "ipc_srcmap_fn"))
        @test r["found"] == true
        @test r["name"] == "ipc_srcmap_fn"
    end

    # =====================================================================
    # 6. breakpoint_map
    # =====================================================================
    @testset "breakpoint_map" begin
        @test call("breakpoint_map", Dict{String,Any}("file" => nothing, "line" => 1))["status"] == "error"
        @test call("breakpoint_map", Dict{String,Any}("file" => "x.jl"))["status"] == "error"         # missing line
        @test call("breakpoint_map", Dict{String,Any}("file" => "x.jl", "line" => "seven"))["status"] == "error"
        @test call("breakpoint_map", Dict{String,Any}("file" => "x.jl", "line" => 0))["status"] == "error"
        @test call("breakpoint_map", Dict{String,Any}("file" => "x.jl", "line" => -1))["status"] == "error"

        r = call("breakpoint_map", Dict{String,Any}("file" => "nonexistent_ipc_xyz.jl", "line" => 1))
        @test r["found"] == false
    end

    # =====================================================================
    # 7. debug_info
    # =====================================================================
    @testset "debug_info" begin
        @test call("debug_info", Dict{String,Any}("name" => nothing))["status"] == "error"
        @test call("debug_info", Dict{String,Any}("name" => 42))["status"] == "error"
        @test call("debug_info", Dict{String,Any}())["status"] == "error"

        r = call("debug_info", Dict{String,Any}("name" => "ipc_srcmap_fn"))
        @test r["found"] == true
    end

    # =====================================================================
    # 8. use
    # =====================================================================
    @testset "use" begin
        @test call("use", Dict{String,Any}("path" => nothing))["status"] == "error"
        @test call("use", Dict{String,Any}())["status"] == "error"
        @test call("use", Dict{String,Any}("path" => "x.jl", "tier" => "high"))["status"] == "error"
        @test call("use", Dict{String,Any}("path" => "x.jl", "tier" => true))["status"] == "error"

        tmpfile = joinpath(_ipc_test_dir, "scripts", "_ipc_use.jl")
        write(tmpfile, """
        ipc_use_helper(x) = x * 2
        function ipc_use_entry(x)
            ipc_use_helper(x) + 1
        end
        """)
        r = call("use", Dict{String,Any}("path" => tmpfile))
        @test r["status"] == "ok"
        @test r["total_definitions"] == 2
        @test r["pending_count"] == 2

        lock(Joovy.IpcBridge._lazy_modules_lock) do
            delete!(Joovy.IpcBridge._lazy_modules, abspath(tmpfile))
        end
        rm(tmpfile; force=true)
    end

    # =====================================================================
    # 9. use + reload (lazy_incremental mode)
    # =====================================================================
    @testset "use + reload (lazy mode)" begin
        tmpfile = joinpath(_ipc_test_dir, "scripts", "_ipc_lazy_reload.jl")
        write(tmpfile, "ipc_lazy_fn(x) = x + 1\n")

        use_r = call("use", Dict{String,Any}("path" => tmpfile))
        @test use_r["status"] == "ok"

        write(tmpfile, "ipc_lazy_fn(x) = x + 100\n")
        sleep(0.05)

        reload_r = call("reload", Dict{String,Any}("file" => tmpfile))
        @test reload_r["status"] == "ok"
        @test reload_r["mode"] == "lazy_incremental"
        @test "ipc_lazy_fn" in reload_r["changed"]

        lock(Joovy.IpcBridge._lazy_modules_lock) do
            delete!(Joovy.IpcBridge._lazy_modules, abspath(tmpfile))
        end
        rm(tmpfile; force=true)
    end

    # =====================================================================
    # 10. lazy_status
    # =====================================================================
    @testset "lazy_status" begin
        r = call("lazy_status", Dict{String,Any}("garbage" => 1))
        @test haskey(r, "modules")
    end

    # =====================================================================
    # 11. timeline
    # =====================================================================
    @testset "timeline" begin
        r = call("timeline", Dict{String,Any}())
        @test haskey(r, "report")
    end

    # =====================================================================
    # 12. dev_mode
    # =====================================================================
    @testset "dev_mode" begin
        @test call("dev_mode", Dict{String,Any}("active" => "notabool"))["status"] == "error"
        @test call("dev_mode", Dict{String,Any}("tier" => "high"))["status"] == "error"
        @test call("dev_mode", Dict{String,Any}("tier" => true))["status"] == "error"

        r = call("dev_mode", Dict{String,Any}("active" => true, "tier" => 1))
        @test r["status"] == "ok"
        @test r["active"] == true
        @test r["tier"] == 1

        # Clean up: leave dev mode off for anything that runs after this suite.
        r_off = call("dev_mode", Dict{String,Any}("active" => false))
        @test r_off["status"] == "ok"
        @test r_off["active"] == false
    end

    # =====================================================================
    # 13. package_tier
    # =====================================================================
    @testset "package_tier" begin
        @test call("package_tier", Dict{String,Any}("package" => nothing))["status"] == "error"
        @test call("package_tier", Dict{String,Any}("package" => 42))["status"] == "error"
        @test call("package_tier", Dict{String,Any}())["status"] == "error"
        @test call("package_tier", Dict{String,Any}("package" => "Base64", "tier" => "high"))["status"] == "error"

        r = call("package_tier", Dict{String,Any}("package" => "Base64", "tier" => 1))
        @test r["status"] == "ok"
        @test r["package"] == "Base64"
    end

    # =====================================================================
    # 14. promote_all
    # =====================================================================
    @testset "promote_all" begin
        @test call("promote_all", Dict{String,Any}("tier" => "high"))["status"] == "error"
        @test call("promote_all", Dict{String,Any}("tier" => true))["status"] == "error"

        r = call("promote_all", Dict{String,Any}())
        @test r["status"] == "ok"
        @test haskey(r, "packages_promoted")
    end

    # =====================================================================
    # 15. apply_preferences (no LocalPreferences.toml in this project -> graceful ok)
    # =====================================================================
    @testset "apply_preferences" begin
        r = call("apply_preferences", Dict{String,Any}("garbage" => 1))
        @test r["status"] == "ok"
        @test haskey(r, "has_config")
    end

    # =====================================================================
    # 16. promote (requires a lazy module already `use`d at the same path)
    # =====================================================================
    @testset "promote" begin
        @test call("promote", Dict{String,Any}("path" => nothing))["status"] == "error"
        @test call("promote", Dict{String,Any}())["status"] == "error"
        @test call("promote", Dict{String,Any}("path" => "x.jl", "tier" => "high"))["status"] == "error"
        @test call("promote", Dict{String,Any}("path" => "x.jl", "function" => 42))["status"] == "error"

        tmpfile = joinpath(_ipc_test_dir, "scripts", "_ipc_promote.jl")
        write(tmpfile, """
        ipc_promote_helper(x) = x + 1
        function ipc_promote_entry(x)
            ipc_promote_helper(x) * 2
        end
        """)
        use_r = call("use", Dict{String,Any}("path" => tmpfile))
        @test use_r["status"] == "ok"

        r = call("promote", Dict{String,Any}("path" => tmpfile, "function" => "ipc_promote_entry"))
        @test r["status"] == "ok"
        @test haskey(r, "enqueued")
        @test r["enqueued"] >= 1
        @test Joovy.joovy_speculate_enabled()   # force-enabled by the handler itself

        lock(Joovy.IpcBridge._lazy_modules_lock) do
            delete!(Joovy.IpcBridge._lazy_modules, abspath(tmpfile))
        end
        rm(tmpfile; force=true)
    end

    # =====================================================================
    # 17. counters
    # =====================================================================
    @testset "counters" begin
        r = call("counters", Dict{String,Any}())
        @test haskey(r, "functions")
    end

    # Teardown: leave shared global state clean for any tooling that runs
    # after the suite (mirrors the teardown convention in test_spec_queue.jl).
    Joovy.SpecQueue.spec_kill!()
    Joovy.joovy_speculate!(false)
    Joovy.joovy_dev_mode!(active=false)
end

# Tests for the CompileWatch IPC routes (joovy/diag_start, joovy/diag_stop,
# joovy/diag_report) and the joovy/diagnostics notification: route success +
# malformed params per the test_ipc_bridge.jl convention.
#
# Included AFTER mock_flexible_ipc.jl AND after test_ipc_bridge.jl (see
# test/runtests.jl) -- test_ipc_bridge.jl documents itself as needing to be
# the first caller of joovy_register_ipc_handlers!() in the suite (its
# "registration + ready notification" test checks the joovy/ready
# notification, and registration is idempotent/only sends it once per
# process), so this file -- which also needs handlers registered to call
# routes through the mock -- runs after it rather than before. This file
# cleans up its own CompileWatch session state at the end.

using Test
using Joovy

const _cwipc_dir = @__DIR__
const FIPC2 = Main.FlexibleIPC

call_diag(route::String, params::Dict) = FIPC2.call(route, params)

@testset "CompileWatch IPC" begin

    Joovy.joovy_register_ipc_handlers!()

    # =====================================================================
    # 1. diag_start
    # =====================================================================
    @testset "diag_start" begin
        @test call_diag("diag_start", Dict{String,Any}("static" => "notabool"))["status"] == "error"
        @test call_diag("diag_start", Dict{String,Any}("dynamic" => 42))["status"] == "error"
        @test call_diag("diag_start", Dict{String,Any}("paths" => "not-an-array"))["status"] == "error"
        @test call_diag("diag_start", Dict{String,Any}("paths" => [42]))["status"] == "error"
        @test call_diag("diag_start", Dict{String,Any}("specializations_over" => "high"))["status"] == "error"
        @test call_diag("diag_start", Dict{String,Any}("inference_self_ms_over" => "high"))["status"] == "error"
        @test call_diag("diag_start", Dict{String,Any}("inference_self_ms_over" => true))["status"] == "error"
        @test call_diag("diag_start", Dict{String,Any}("reinfer_count_over" => "high"))["status"] == "error"

        tmpfile = joinpath(_cwipc_dir, "scripts", "_cwipc_start.jl")
        write(tmpfile, """
        function cwipc_start_fn(cb, x)
            cb(x) + 1
        end
        """)

        FIPC2.reset_notifications!()
        r = call_diag("diag_start", Dict{String,Any}(
            "paths" => [tmpfile], "static" => true, "dynamic" => false))
        @test r["status"] == "ok"
        @test r["static"] == true
        @test r["dynamic_requested"] == false
        @test r["dynamic_active"] == false
        @test r["static_diagnostic_count"] == 1
        @test haskey(r, "time_ns")

        # A joovy/diagnostics full snapshot is pushed right away (not just on
        # the next throttle tick), so the IDE doesn't wait ~0.5s for the
        # first diagnostics after starting a session.
        notif = [n for n in FIPC2._notifications if n[1] == "joovy/diagnostics"]
        @test !isempty(notif)
        @test haskey(notif[end][2], "diagnostics")

        Joovy.compile_watch_stop!()
        rm(tmpfile; force=true)
        Joovy.CompileWatch._reset!()
    end

    # =====================================================================
    # 2. diag_start with default paths (paths omitted -> empty, no error)
    # =====================================================================
    @testset "diag_start with no paths" begin
        r = call_diag("diag_start", Dict{String,Any}("static" => true, "dynamic" => false))
        @test r["status"] == "ok"
        @test r["static_diagnostic_count"] == 0
        Joovy.compile_watch_stop!()
        Joovy.CompileWatch._reset!()
    end

    # =====================================================================
    # 3. diag_report
    # =====================================================================
    @testset "diag_report" begin
        tmpfile = joinpath(_cwipc_dir, "scripts", "_cwipc_report.jl")
        write(tmpfile, "function cwipc_report_fn(x...)\n sum(x)\nend\n")

        r0 = call_diag("diag_start", Dict{String,Any}("paths" => [tmpfile], "dynamic" => false))
        @test r0["status"] == "ok"

        report = call_diag("diag_report", Dict{String,Any}())
        @test haskey(report, "diagnostics")
        @test !isempty(report["diagnostics"])
        d = report["diagnostics"][1]
        @test d["rule_id"] == "vararg-unbounded-splat"
        @test d["file"] == abspath(tmpfile)
        @test d["line"] == 1
        @test d["method"] == "cwipc_report_fn"
        @test d["source"] == "static"
        @test d["metric"] === nothing

        # Callable with unused params without throwing (matches the
        # `status`/`lazy_status`/`timeline` route convention).
        report2 = call_diag("diag_report", Dict{String,Any}("garbage" => 1))
        @test haskey(report2, "diagnostics")

        Joovy.compile_watch_stop!()
        rm(tmpfile; force=true)
        Joovy.CompileWatch._reset!()
    end

    # =====================================================================
    # 4. diag_stop
    # =====================================================================
    @testset "diag_stop" begin
        call_diag("diag_start", Dict{String,Any}("static" => false, "dynamic" => false))
        r = call_diag("diag_stop", Dict{String,Any}())
        @test r["status"] == "ok"
        @test haskey(r, "time_ns")
        @test Joovy.compile_watch_status().running == false

        # Idempotent: stopping an already-stopped session is not an error.
        r2 = call_diag("diag_stop", Dict{String,Any}())
        @test r2["status"] == "ok"
        Joovy.CompileWatch._reset!()
    end

    # =====================================================================
    # 5. dynamic=true end-to-end through IPC (capability verified live on
    #    this repo's Julia 1.12.3 -- see test_compile_watch.jl)
    # =====================================================================
    @testset "diag_start with dynamic=true" begin
        r = call_diag("diag_start", Dict{String,Any}("static" => false, "dynamic" => true))
        @test r["status"] == "ok"
        @test r["dynamic_requested"] == true
        @test r["dynamic_active"] isa Bool   # true on 1.12; false-with-warning on an
                                              # unsupported build -- never silently wrong
        call_diag("diag_stop", Dict{String,Any}())
        Joovy.CompileWatch._reset!()
    end

    # Teardown: leave CompileWatch state clean for test_ipc_bridge.jl (which
    # must stay the LAST included file -- see its own header comment).
    Joovy.compile_watch_stop!()
    Joovy.CompileWatch._reset!()
end

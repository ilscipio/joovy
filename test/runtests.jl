using Test
using Joovy

println("\n" * "╔" * "═"^108 * "╗")
println("║" * lpad("Joovy.jl Test Suite — Compiled Julia vs Dynamic Joovy Compilation", 86) * " "^22 * "║")
println("╚" * "═"^108 * "╝")

@testset "Joovy.jl" begin
    include("test_exprcache.jl")
    include("test_source_provider.jl")
    include("test_compiler.jl")
    include("test_hotswap.jl")
    include("test_scriptengine.jl")
    include("test_autotune.jl")
    include("test_debug.jl")
    include("test_incremental_reload.jl")
    include("test_static_compile.jl")
    include("test_compile_timeline.jl")
    include("test_tiered_compile.jl")
    include("test_lazy_module.jl")
    include("test_spec_queue.jl")
    include("test_warmup.jl")
    include("test_config.jl")
    include("test_comparison.jl")
    include("test_compile_watch.jl")

    # Included once, at top level (binds to Main.FlexibleIPC), right before the one test
    # file that needs it -- test_debug.jl's earlier "no IDE connected" check
    # (`!joovy_ipc_available()`) depends on Main.FlexibleIPC NOT existing yet, so this
    # cannot move any earlier without breaking that pre-existing assertion. A re-include
    # would rebind the module and orphan already-registered handlers, so it must stay put
    # once test_ipc_bridge.jl is reached.
    include("mock_flexible_ipc.jl")

    # test_ipc_bridge.jl documents itself as needing to be the LAST included file (its
    # "registration + ready notification" test is the FIRST caller of
    # joovy_register_ipc_handlers!() in the whole suite, and it is the one that tears
    # down other shared IPC-adjacent global state for anything running after the
    # suite) -- test_compile_watch_ipc.jl is placed AFTER it rather than before so it
    # doesn't front-run that first-call assertion (joovy_register_ipc_handlers! is
    # idempotent: a second caller earlier would silently swallow the joovy/ready
    # notification test_ipc_bridge.jl checks for).
    include("test_ipc_bridge.jl")
    include("test_compile_watch_ipc.jl")
end

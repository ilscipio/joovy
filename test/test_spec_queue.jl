# Tests for speculative background compilation (SpecQueue submodule).
#
# The consumer runs as a single shared background task for the whole file (started
# lazily on the first :queued enqueue and only ever stopped by spec_kill!() in the
# final teardown), so every sub-testset uses distinct file/function names to avoid
# cross-test interference, and polls with a BOUNDED deadline (never an unbounded loop).

using Test
using Joovy

const _spec_test_dir = @__DIR__

# Bounded poll: repeatedly checks `cond()` until it is true or `timeout` seconds pass.
# Returns the last value of `cond()` (so callers can still `@test` a clean failure
# message instead of hanging forever).
function _wait_until(cond; timeout::Real=10.0, interval::Real=0.02)
    deadline = time() + timeout
    while time() < deadline
        cond() && return true
        sleep(interval)
    end
    return cond()
end

# Bring the shared queue back to empty before a test that cares about exact queue
# contents/ordering, so a slow-draining item from a previous sub-testset can't leak in.
function _drain_to_empty!(; timeout::Real=10.0)
    joovy_speculate!(true)
    spec_resume!()
    _wait_until(() -> spec_stats().queue_depth == 0; timeout=timeout)
end

@testset "SpecQueue" begin

    # =====================================================================
    # 1. enqueue + drain: joovy_use on a 4-def chain speculatively compiles
    #    everything in the background; the entry call is still correct.
    # =====================================================================
    @testset "1. enqueue + drain" begin
        joovy_speculate!(true)
        spec_resume!()

        tmpfile = joinpath(_spec_test_dir, "scripts", "_spec_chain.jl")
        write(tmpfile, """
        spec1_helper(x) = x * 2

        function spec1_compute(x)
            spec1_helper(x) + 10
        end

        spec1_standalone(x) = x^3

        function spec1_chain(x)
            spec1_compute(x) + spec1_standalone(x)
        end
        """)

        lm = joovy_use(tmpfile; tier=1)

        ok = _wait_until(() -> length(lazy_compiled(lm)) == 4)
        @test ok
        @test Set(lazy_compiled(lm)) ==
              Set([:spec1_helper, :spec1_compute, :spec1_standalone, :spec1_chain])

        ok2 = _wait_until(() -> spec_stats().queue_depth == 0)
        @test ok2

        expected = (2 * 2 + 10) + 2^3
        @test lm.spec1_chain(2) == expected

        rm(tmpfile; force=true)
    end

    # =====================================================================
    # 2. dedup: the same (owner, name, tier) enqueued twice while paused ->
    #    the second call reports :deduped, not a second queue entry.
    # =====================================================================
    @testset "2. dedup" begin
        _drain_to_empty!()
        joovy_speculate!(false)   # keep joovy_use's own auto-enqueue hook a no-op

        tmpfile = joinpath(_spec_test_dir, "scripts", "_spec_dedup.jl")
        write(tmpfile, "spec2_f(x) = x + 1\n")
        lm = joovy_use(tmpfile; tier=1)
        sleep(0.05)   # let the (disabled) hook settle before re-enabling

        joovy_speculate!(true)
        spec_pause!()

        st1 = spec_enqueue!(lm, :spec2_f; tier=1, class=0, score=0.0)
        st2 = spec_enqueue!(lm, :spec2_f; tier=1, class=0, score=0.0)
        @test st1 == :queued
        @test st2 == :deduped

        spec_resume!()
        ok = _wait_until(() -> length(lazy_compiled(lm)) == 1)
        @test ok

        rm(tmpfile; force=true)
    end

    # =====================================================================
    # 3. priority: a class-2 item enqueued after a class-0 item still comes
    #    out of the queue first.
    # =====================================================================
    @testset "3. priority ordering" begin
        _drain_to_empty!()
        joovy_speculate!(false)

        tmpfile = joinpath(_spec_test_dir, "scripts", "_spec_priority.jl")
        write(tmpfile, """
        spec3_a(x) = x + 1
        spec3_b(x) = x + 2
        """)
        lm = joovy_use(tmpfile; tier=1)
        sleep(0.05)

        joovy_speculate!(true)
        spec_pause!()

        st_low = spec_enqueue!(lm, :spec3_a; tier=1, class=0, score=0.0)
        st_high = spec_enqueue!(lm, :spec3_b; tier=1, class=2, score=0.0)
        @test st_low == :queued
        @test st_high == :queued

        item = Joovy.SpecQueue._pop_next!()
        @test item !== nothing
        @test item.name == :spec3_b
        @test item.class == 2

        leftover = Joovy.SpecQueue._pop_next!()
        @test leftover !== nothing
        @test leftover.name == :spec3_a

        rm(tmpfile; force=true)
    end

    # =====================================================================
    # 4. pause/resume: a paused consumer leaves queued work untouched; once
    #    resumed, it drains.
    # =====================================================================
    @testset "4. pause/resume" begin
        _drain_to_empty!()
        joovy_speculate!(false)

        tmpfile = joinpath(_spec_test_dir, "scripts", "_spec_pause.jl")
        write(tmpfile, "spec4_f(x) = x + 1\n")
        lm = joovy_use(tmpfile; tier=1)
        sleep(0.05)

        joovy_speculate!(true)
        spec_pause!()
        st = spec_enqueue!(lm, :spec4_f; tier=1, class=0, score=0.0)
        @test st == :queued

        sleep(0.1)
        @test spec_stats().queue_depth >= 1
        @test length(lazy_compiled(lm)) == 0   # untouched while paused

        spec_resume!()
        ok = _wait_until(() -> length(lazy_compiled(lm)) == 1)
        @test ok

        rm(tmpfile; force=true)
    end

    # =====================================================================
    # 5. error survival: a define-time failure in one def does not stop a
    #    sibling def from being speculatively compiled.
    # =====================================================================
    @testset "5. error survival" begin
        _drain_to_empty!()
        joovy_speculate!(false)

        tmpfile = joinpath(_spec_test_dir, "scripts", "_spec_error.jl")
        write(tmpfile, """
        bad_fn(x) = @nonexistent_macro_xyz(x)
        spec5_good(x) = x + 42
        """)
        lm = joovy_use(tmpfile; tier=1)
        sleep(0.05)

        errors_before = spec_stats().errors
        joovy_speculate!(true)
        spec_resume!()
        n = spec_enqueue_all!(lm; tier=1, class=0)
        @test n == 2

        ok = _wait_until(() -> spec_stats().errors > errors_before &&
                                :spec5_good in lazy_compiled(lm))
        @test ok
        @test spec_stats().errors > errors_before
        @test :spec5_good in lazy_compiled(lm)
        @test !(:bad_fn in lazy_compiled(lm))

        rm(tmpfile; force=true)
    end

    # =====================================================================
    # 6. first-access speculation: calling one entry point leaves an
    #    unrelated standalone def in the same file untouched at first, then
    #    the first-access hook speculatively compiles it too.
    # =====================================================================
    @testset "6. first-access speculation" begin
        _drain_to_empty!()
        joovy_speculate!(false)

        tmpfile = joinpath(_spec_test_dir, "scripts", "_spec_first_access.jl")
        write(tmpfile, """
        spec6_helper(x) = x * 2

        function spec6_entry1(x)
            spec6_helper(x) + 1
        end

        spec6_standalone(x) = x^2
        """)
        lm = joovy_use(tmpfile; tier=1)
        sleep(0.05)

        joovy_speculate!(true)
        spec_resume!()

        @test lm.spec6_entry1(3) == 7
        @test Set(lazy_compiled(lm)) == Set([:spec6_helper, :spec6_entry1])

        ok = _wait_until(() -> :spec6_standalone in lazy_compiled(lm))
        @test ok

        rm(tmpfile; force=true)
    end

    # =====================================================================
    # 7. _handle_promote: a direct IPC "promote" call enqueues the requested
    #    subtree and force-enables speculation even if it was off.
    # =====================================================================
    @testset "7. _handle_promote via IPC" begin
        _drain_to_empty!()
        joovy_speculate!(false)

        tmpfile = joinpath(_spec_test_dir, "scripts", "_spec_ipc_promote.jl")
        write(tmpfile, """
        spec7_helper(x) = x + 1

        function spec7_entry1(x)
            spec7_helper(x) * 2
        end
        """)
        lm = joovy_use(tmpfile; tier=1)
        sleep(0.05)

        lock(Joovy.IpcBridge._lazy_modules_lock) do
            Joovy.IpcBridge._lazy_modules[abspath(tmpfile)] = lm
        end

        @test !joovy_speculate_enabled()
        resp = Joovy.IpcBridge._handle_promote(Dict{String,Any}(
            "path" => tmpfile, "function" => "spec7_entry1"))

        @test resp["status"] == "ok"
        @test resp["enqueued"] >= 1
        @test haskey(resp, "queue_depth")
        @test joovy_speculate_enabled()   # force-enabled by the handler itself

        ok = _wait_until(() -> length(lazy_compiled(lm)) >= 1)
        @test ok

        lock(Joovy.IpcBridge._lazy_modules_lock) do
            delete!(Joovy.IpcBridge._lazy_modules, abspath(tmpfile))
        end
        rm(tmpfile; force=true)
    end

    # Teardown: hard-stop the queue and leave speculation off for later test files.
    spec_kill!()
    joovy_speculate!(false)
end

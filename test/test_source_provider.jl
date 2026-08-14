using Test
using Joovy

# Tests for the SourceProvider submodule: the single choke point for reading
# user source, backed by a path-keyed cache the IDE fills over IPC
# (`source_push!`), with disk fallback. An empty cache must behave exactly
# like a direct `read(abspath, String)` -- test 1 pins that down explicitly.
#
# `source_clear!()` resets cache + providers + counters; it is called at the
# start/end of this file and after every nested testset below so state never
# leaks into a later testset here, or into test_compiler.jl/test_hotswap.jl/
# test_lazy_module.jl/test_scriptengine.jl/test_debug.jl/
# test_incremental_reload.jl (which run after this file and, via the
# refactored read sites, go through this same cache).

@testset "SourceProvider" begin
    source_clear!()
    test_dir = @__DIR__
    scripts_dir = joinpath(test_dir, "scripts")

    # =====================================================================
    # 1. Miss path = today's behavior: empty cache reads straight from disk.
    # =====================================================================
    @testset "miss falls through to disk (byte-identical to today)" begin
        path = joinpath(scripts_dir, "_sp_miss.jl")
        write(path, "sp_miss_fn(x) = x + 1\n")

        @test source_read(path) == "sp_miss_fn(x) = x + 1\n"
        stats = source_stats()
        @test stats.reads == 1
        @test stats.disk_reads == 1
        @test stats.cache_hits == 0

        rm(path; force=true)
        source_clear!()
    end

    # =====================================================================
    # 2. Cache hit: pushed content is served without touching disk.
    # =====================================================================
    @testset "cache hit serves pushed content, no disk read" begin
        path = joinpath(scripts_dir, "_sp_hit.jl")
        write(path, "sp_hit_fn(x) = x + 1\n")            # disk content -- must NOT come back
        source_push!(path, "sp_hit_fn(x) = x + 999\n")   # unsaved editor buffer

        @test source_read(path) == "sp_hit_fn(x) = x + 999\n"
        stats = source_stats()
        @test stats.cache_hits == 1
        @test stats.disk_reads == 0

        rm(path; force=true)
        source_clear!()
    end

    # =====================================================================
    # 3. Staleness eviction: a newer disk mtime evicts the cached push.
    # =====================================================================
    @testset "external edit (newer disk mtime) evicts the cached entry" begin
        path = joinpath(scripts_dir, "_sp_stale.jl")
        write(path, "sp_stale_fn(x) = x + 1\n")
        source_push!(path, "sp_stale_fn(x) = x + 111\n")
        @test source_read(path) == "sp_stale_fn(x) = x + 111\n"   # cache hit, disk unchanged

        sleep(0.05)   # ensure the next write gets a strictly later mtime
        write(path, "sp_stale_fn(x) = x + 222\n")   # external edit -- e.g. a save from another tool

        @test source_read(path) == "sp_stale_fn(x) = x + 222\n"   # external edit wins
        stats = source_stats()
        @test stats.disk_reads == 1   # only the post-eviction read touched disk

        rm(path; force=true)
        source_clear!()
    end

    # =====================================================================
    # 4. Out-of-order push guard: version <= cached version is dropped.
    # =====================================================================
    @testset "out-of-order push (version <= cached) is dropped" begin
        path = joinpath(scripts_dir, "_sp_version.jl")

        source_push!(path, "sp_version_fn(x) = x + 1\n", 5)
        @test source_read(path) == "sp_version_fn(x) = x + 1\n"

        source_push!(path, "sp_version_fn(x) = x + 999\n", 3)   # older -- dropped
        @test source_read(path) == "sp_version_fn(x) = x + 1\n"

        source_push!(path, "sp_version_fn(x) = x + 999\n", 5)   # equal -- dropped
        @test source_read(path) == "sp_version_fn(x) = x + 1\n"

        source_push!(path, "sp_version_fn(x) = x + 999\n", 6)   # newer -- wins
        @test source_read(path) == "sp_version_fn(x) = x + 999\n"

        source_clear!()
    end

    # =====================================================================
    # 5. Provider registry: tried in registration order on a miss.
    # =====================================================================
    @testset "provider registry: registration order, first hit wins" begin
        path = joinpath(scripts_dir, "_sp_provider.jl")
        calls = Symbol[]

        register_source_provider!(function(p)
            push!(calls, :first)
            nothing   # no opinion -- next provider gets tried
        end)
        register_source_provider!(function(p)
            push!(calls, :second)
            ("sp_provider_fn(x) = x + 1\n", 1)
        end)
        register_source_provider!(function(p)
            push!(calls, :third)   # must never run -- :second already hit
            ("sp_provider_fn(x) = x + 999\n", 1)
        end)

        @test source_read(path) == "sp_provider_fn(x) = x + 1\n"
        @test calls == [:first, :second]

        empty!(calls)
        @test source_read(path) == "sp_provider_fn(x) = x + 1\n"   # now cached
        @test isempty(calls)   # providers not re-tried on a cache hit

        source_clear!()
    end

    # =====================================================================
    # 6. source_exists for a never-saved path (cache-only content).
    # =====================================================================
    @testset "source_exists is true for a never-saved (cache-only) path" begin
        path = joinpath(scripts_dir, "_sp_never_saved.jl")
        @test !isfile(path)
        @test !source_exists(path)

        source_push!(path, "sp_never_saved_fn(x) = x + 1\n")
        @test source_exists(path)
        @test source_read(path) == "sp_never_saved_fn(x) = x + 1\n"
        @test !isfile(path)   # still never touched disk

        source_clear!()
    end

    # =====================================================================
    # 7. source_mtime and source_invalidate!
    # =====================================================================
    @testset "source_mtime and source_invalidate!" begin
        path = joinpath(scripts_dir, "_sp_mtime.jl")
        write(path, "sp_mtime_fn(x) = x + 1\n")
        disk_mtime = mtime(path)
        source_push!(path, "sp_mtime_fn(x) = x + 2\n")

        @test source_mtime(path) == disk_mtime   # cached entry -> push-time disk stamp

        source_invalidate!(path)
        @test source_mtime(path) == mtime(path)                 # falls back to disk
        @test source_read(path) == "sp_mtime_fn(x) = x + 1\n"    # back to real disk content

        never_saved = joinpath(scripts_dir, "_sp_mtime_never_saved.jl")
        source_push!(never_saved, "x = 1\n")
        @test source_mtime(never_saved) == 0.0   # no disk basis at push time

        rm(path; force=true)
        source_clear!()
    end

    # =====================================================================
    # 8. source_stats counters: reads / cache_hits / disk_reads.
    # =====================================================================
    @testset "source_stats counters" begin
        path = joinpath(scripts_dir, "_sp_stats.jl")
        write(path, "sp_stats_fn(x) = x + 1\n")

        source_read(path)                               # miss -> disk_reads
        source_push!(path, "sp_stats_fn(x) = x + 2\n")
        source_read(path)                               # hit -> cache_hits
        source_read(path)                               # hit -> cache_hits

        stats = source_stats()
        @test stats.reads == 3
        @test stats.disk_reads == 1
        @test stats.cache_hits == 2

        rm(path; force=true)
        source_clear!()
    end

    source_clear!()
end

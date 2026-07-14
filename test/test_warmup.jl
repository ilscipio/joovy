using Test
using Joovy
import Pkg
import SHA

@testset "Warmup" begin

    # ---------------------------------------------------------------
    # _sanitize_trace_lines
    # ---------------------------------------------------------------
    @testset "_sanitize_trace_lines" begin
        lines = [
            "precompile(Tuple{typeof(Base.sum), Vector{Int64}})   # recompile",
            "precompile(Tuple{typeof(Main.foo), Int64})",
            "precompile(Tuple{typeof(Base.sum), Vector{Int64}})",
            "precompile(Tuple{JSON.var\"#3#4\", Int64})",
            "not a precompile line",
            "",
        ]
        sanitized = Joovy.Warmup._sanitize_trace_lines(lines)

        @test sanitized == [
            "precompile(Tuple{typeof(Base.sum), Vector{Int64}})",
            "precompile(Tuple{JSON.var\"#3#4\", Int64})",
        ]
        @test !any(l -> occursin("Main.", l), sanitized)
        @test !any(l -> occursin("# recompile", l), sanitized)
        @test length(sanitized) == length(unique(sanitized))
    end

    # ---------------------------------------------------------------
    # _sanitize_trace_lines: --trace-compile-timing (Julia 1.12+) prefixes
    # ---------------------------------------------------------------
    @testset "_sanitize_trace_lines timing prefixes" begin
        lines = [
            "#=   12.3 ms =# precompile(Tuple{typeof(Base.sum), Vector{Int64}})",
            "#=    1.2 ms =# precompile(Tuple{typeof(Main.foo), Int64})",
            "#=  100.0 ms =# precompile(Tuple{typeof(Base.sum), Vector{Int64}})   # recompile",
        ]
        sanitized = Joovy.Warmup._sanitize_trace_lines(lines)

        # Timing-prefixed line is kept and normalized (prefix stripped).
        @test "precompile(Tuple{typeof(Base.sum), Vector{Int64}})" in sanitized
        # Timing-prefixed Main. line is still dropped.
        @test !any(l -> occursin("Main.", l), sanitized)
        # No leftover comment markers or dupes.
        @test !any(l -> occursin("#=", l), sanitized)
        @test !any(l -> occursin("# recompile", l), sanitized)
        @test length(sanitized) == length(unique(sanitized))
        @test sanitized == ["precompile(Tuple{typeof(Base.sum), Vector{Int64}})"]
    end

    # ---------------------------------------------------------------
    # _statement_modules
    # ---------------------------------------------------------------
    @testset "_statement_modules" begin
        @test Joovy.Warmup._statement_modules(
            "precompile(Tuple{typeof(JSON.Parser.parse), String})") == Set(["JSON", "Parser"])
        @test Joovy.Warmup._statement_modules(
            "precompile(Tuple{typeof(JSON.json), Any})") == Set(["JSON"])
        @test Joovy.Warmup._statement_modules(
            "precompile(Tuple{typeof(Base.sum), Vector{Int64}})") == Set(["Base"])
        @test Joovy.Warmup._statement_modules(
            "precompile(Tuple{JSON.var\"#3#4\", Int64})") == Set(["JSON"])
    end

    # ---------------------------------------------------------------
    # warmup_generate: structural test (temp project + synthetic trace file)
    # ---------------------------------------------------------------
    @testset "warmup_generate structure" begin
        orig_project = Base.active_project()

        tmp = mktempdir()
        project_dir = joinpath(tmp, "proj")
        mkpath(project_dir)
        write(joinpath(project_dir, "Project.toml"), "")

        try
            Pkg.activate(project_dir; io=devnull)
            Pkg.instantiate(io=devnull)
        finally
            Pkg.activate(dirname(orig_project); io=devnull)
        end
        @test isfile(joinpath(project_dir, "Manifest.toml"))

        trace_dir = joinpath(tmp, "traces")
        mkpath(trace_dir)
        write(joinpath(trace_dir, "trace-1.jl"), """
        precompile(Tuple{typeof(Base.sum), Vector{Int64}})   # recompile
        precompile(Tuple{typeof(Main.foo), Int64})
        precompile(Tuple{typeof(Base.:(+)), Int64, Int64})
        """)

        pkg_dir = try
            warmup_generate(project_dir, trace_dir)
        finally
            Pkg.activate(dirname(orig_project); io=devnull)
        end

        @test pkg_dir !== nothing
        @test pkg_dir == joinpath(trace_dir, "JoovyWarmup")
        @test isdir(pkg_dir)

        project_toml = read(joinpath(pkg_dir, "Project.toml"), String)
        @test occursin("name = \"JoovyWarmup\"", project_toml)
        @test occursin("7b1a2c3d-0000-4000-8000-1234567890ab", project_toml)
        @test !occursin("[deps]", project_toml)  # only Base referenced; not a real dep

        src = read(joinpath(pkg_dir, "src", "JoovyWarmup.jl"), String)
        @test occursin("module JoovyWarmup", src)
        @test !occursin("Main.", src)
        @test !occursin("# recompile", src)
        @test count("try; precompile", src) == 2  # the Main. line was dropped

        # Balanced try/catch: a broken generated file (e.g. an unstripped
        # "# recompile" comment eating the "; catch; end") would parse with
        # an :error node.
        parsed = Meta.parseall(src)
        has_error = any(a -> a isa Expr && a.head === :error, parsed.args)
        @test !has_error
    end

    # ---------------------------------------------------------------
    # warmup_build: end-to-end via subprocess with a layered scratch depot
    # ---------------------------------------------------------------
    if VERSION >= v"1.10"
        @testset "warmup_build e2e (subprocess)" begin
            joovy_root = dirname(@__DIR__)
            orig_project = Base.active_project()

            tmp = mktempdir()
            project_dir = joinpath(tmp, "proj")
            mkpath(project_dir)
            write(joinpath(project_dir, "Project.toml"), "")

            try
                Pkg.activate(project_dir; io=devnull)
                Pkg.instantiate(io=devnull)
            finally
                Pkg.activate(dirname(orig_project); io=devnull)
            end
            @test isfile(joinpath(project_dir, "Manifest.toml"))

            trace_dir = joinpath(tmp, "traces")
            mkpath(trace_dir)
            write(joinpath(trace_dir, "trace-1.jl"), """
            precompile(Tuple{typeof(Base.sum), Vector{Int64}})
            precompile(Tuple{typeof(Base.:(+)), Int64, Int64})
            """)

            script = joinpath(tmp, "run_e2e.jl")
            write(script, """
            using Joovy
            project = ARGS[1]
            trace_dir = ARGS[2]
            pkg_dir = warmup_generate(project, trace_dir)
            pkg_dir === nothing && error("warmup_generate returned nothing")
            ok = warmup_build(project, pkg_dir)
            ok || error("warmup_build failed")
            println("SUBPROCESS_OK")
            """)

            scratch_depot = joinpath(tmp, "scratch_depot")
            mkpath(scratch_depot)
            depot_sep = Sys.iswindows() ? ";" : ":"
            depot_env = scratch_depot * depot_sep * first(Base.DEPOT_PATH)

            cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(joovy_root) $(script) $(project_dir) $(trace_dir)`
            cmd = addenv(cmd, "JULIA_DEPOT_PATH" => depot_env)

            buf = IOBuffer()
            ok = success(pipeline(cmd; stdout=buf, stderr=buf))
            output = String(take!(buf))

            @test ok
            @test occursin("SUBPROCESS_OK", output)
            @test occursin("__JOOVY_WARMUP_PKG__ status=generated", output)
            @test occursin("__JOOVY_WARMUP_PKG__ status=built", output)

            ver_dir = "v$(VERSION.major).$(VERSION.minor)"
            compiled_pkg_dir = joinpath(scratch_depot, "compiled", ver_dir, "JoovyWarmup")
            @test isdir(compiled_pkg_dir)
            ji_files = isdir(compiled_pkg_dir) ? filter(f -> endswith(f, ".ji"), readdir(compiled_pkg_dir)) : String[]
            @test !isempty(ji_files)

            hash_file = joinpath(trace_dir, "_build_env", ".manifest_hash")
            @test isfile(hash_file)
            hash_lines = split(read(hash_file, String), '\n')
            @test length(hash_lines) >= 2
            @test length(strip(hash_lines[1])) == 64
            @test strip(hash_lines[2]) == "Manifest.toml"

            # The hash is of the SOURCE project's active manifest at build time
            # (not build_env's copy, which Pkg.develop mutates afterwards by
            # adding the JoovyWarmup entry -- that mutated copy is expected to
            # diverge from the recorded hash).
            source_manifest = joinpath(project_dir, "Manifest.toml")
            @test isfile(source_manifest)
            @test bytes2hex(SHA.sha256(read(source_manifest))) == lowercase(strip(hash_lines[1]))

            build_manifest = joinpath(trace_dir, "_build_env", "Manifest.toml")
            @test isfile(build_manifest)
        end
    end

    # ---------------------------------------------------------------
    # _active_manifest_path
    # ---------------------------------------------------------------
    @testset "_active_manifest_path" begin
        tmp = mktempdir()
        write(joinpath(tmp, "Project.toml"), "name = \"Proj\"\n")

        # No manifest at all yet.
        @test Joovy.Warmup._active_manifest_path(tmp) === nothing

        # Only the unversioned Manifest.toml.
        write(joinpath(tmp, "Manifest.toml"), "julia_version = \"1.11.2\"\n")
        @test Joovy.Warmup._active_manifest_path(tmp) == joinpath(tmp, "Manifest.toml")

        # Versioned manifest for the CURRENT running Julia takes priority over
        # the unversioned one, mirroring Julia's own loading resolution.
        versioned_name = "Manifest-v$(VERSION.major).$(VERSION.minor).toml"
        write(joinpath(tmp, versioned_name), "julia_version = \"$(VERSION)\"\n")
        @test Joovy.Warmup._active_manifest_path(tmp) == joinpath(tmp, versioned_name)

        # Directory with a Project.toml but no manifest of any kind.
        tmp2 = mktempdir()
        write(joinpath(tmp2, "Project.toml"), "name = \"Proj2\"\n")
        @test Joovy.Warmup._active_manifest_path(tmp2) === nothing

        # No Project.toml at all.
        tmp3 = mktempdir()
        @test Joovy.Warmup._active_manifest_path(tmp3) === nothing
    end

    # ---------------------------------------------------------------
    # warm_daemon_loop: in-process, using IOBuffer pipes against the CURRENT
    # process env (Pkg is already loaded by the test runner, so world-age
    # is a non-issue here; the subprocess test below additionally exercises
    # the lazy-Pkg-load / invokelatest path).
    # On Julia < 1.10 the daemon (like all Warmup entry points) skips by
    # design, so only the skip marker is asserted there.
    # ---------------------------------------------------------------
    if VERSION < v"1.10"
        @testset "warm_daemon_loop skips on old Julia" begin
            out = IOBuffer()
            warm_daemon_loop(input=IOBuffer("EXIT\n"), io=out)
            @test occursin("status=skip reason=julia_version", String(take!(out)))
        end
    end

    if VERSION >= v"1.10"
    @testset "warm_daemon_loop (in-process)" begin
        input = IOBuffer("WARM\tNonExistentPkgXYZ\t-\nEXIT\n")
        out = IOBuffer()
        warm_daemon_loop(input=input, io=out)
        output = String(take!(out))

        @test occursin("__JOOVY_DAEMON__ status=ready", output)
        @test occursin("__JOOVY_WARM__ pkg=NonExistentPkgXYZ status=skip reason=not_in_env", output)
        @test occursin("__JOOVY_WARM_DONE__ total=1 warmed=0 failed=0", output)
        @test occursin("__JOOVY_DAEMON__ status=idle", output)
        @test occursin("__JOOVY_DAEMON__ status=exit", output)

        # status=idle must follow the WARM markers and precede status=exit.
        idle_pos = findfirst("__JOOVY_DAEMON__ status=idle", output)
        exit_pos = findfirst("__JOOVY_DAEMON__ status=exit", output)
        done_pos = findfirst("__JOOVY_WARM_DONE__", output)
        @test first(done_pos) < first(idle_pos) < first(exit_pos)
    end

    @testset "warm_daemon_loop unknown/malformed commands" begin
        input = IOBuffer("\nFOO\nWARM\tonly-two-parts\nEXIT\n")
        out = IOBuffer()
        warm_daemon_loop(input=input, io=out)
        output = String(take!(out))

        @test occursin("__JOOVY_DAEMON__ status=ready", output)
        @test occursin("__JOOVY_DAEMON_ERR__ unknown command: FOO", output)
        # Malformed WARM (missing cancel_file arg) errors but does not crash
        # the loop -- an idle marker still follows, then EXIT still works.
        @test occursin("__JOOVY_DAEMON_ERR__", output)
        @test occursin("__JOOVY_DAEMON__ status=exit", output)
        @test count("__JOOVY_DAEMON__ status=idle", output) == 2  # FOO, malformed WARM
    end

    @testset "warm_daemon_loop EOF without EXIT exits gracefully" begin
        input = IOBuffer("WARM\tNonExistentPkgXYZ\t-\n")  # no trailing EXIT
        out = IOBuffer()
        warm_daemon_loop(input=input, io=out)
        output = String(take!(out))

        @test occursin("__JOOVY_DAEMON__ status=ready", output)
        @test occursin("__JOOVY_DAEMON__ status=idle", output)
        @test !occursin("__JOOVY_DAEMON__ status=exit", output)
    end
    end # VERSION >= v"1.10" (in-process daemon testsets)

    # ---------------------------------------------------------------
    # warm_daemon_loop: end-to-end via subprocess, exercising the lazy
    # Pkg/SHA load + invokelatest dispatch path with a layered scratch depot
    # (like the warmup_build e2e above). The daemon is launched against a
    # separate EMPTY project env while Joovy itself is reached via LOAD_PATH
    # -- mirroring how an IDE would spawn the daemon with `--project=<user
    # env>` without making Joovy a declared dependency of that env.
    # ---------------------------------------------------------------
    if VERSION >= v"1.10"
        @testset "warm_daemon_loop e2e (subprocess)" begin
            joovy_root = dirname(@__DIR__)

            tmp = mktempdir()
            env_dir = joinpath(tmp, "empty_env")
            mkpath(env_dir)
            write(joinpath(env_dir, "Project.toml"), "")

            scratch_depot = joinpath(tmp, "scratch_depot")
            mkpath(scratch_depot)
            depot_sep = Sys.iswindows() ? ";" : ":"
            depot_env = scratch_depot * depot_sep * first(Base.DEPOT_PATH)

            script = "push!(LOAD_PATH, raw\"$(joovy_root)\"); using Joovy; Joovy.warm_daemon_loop()"
            cmd = `$(Base.julia_cmd()) --project=$(env_dir) --startup-file=no -e $(script)`
            cmd = addenv(cmd, "JULIA_DEPOT_PATH" => depot_env)

            proc = open(cmd, "r+")
            write(proc, "WARM\tTest\t-\nEXIT\n")
            # Signal EOF on the subprocess's stdin. NOT closewrite(proc): on
            # Julia 1.10/Linux that throws ENOTSOCK for process pipes.
            close(proc.in)

            output = read(proc, String)
            wait(proc)

            @test success(proc)
            @test occursin("__JOOVY_DAEMON__ status=ready", output)
            @test occursin("__JOOVY_WARM__ pkg=Test status=skip reason=not_in_env", output)
            @test occursin("__JOOVY_DAEMON__ status=idle", output)
            @test occursin("__JOOVY_DAEMON__ status=exit", output)
        end
    end
end

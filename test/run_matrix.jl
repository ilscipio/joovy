#!/usr/bin/env julia
#
# Run the full test suite against every Julia version the CI matrix covers.
#
#     julia test/run_matrix.jl            # every version in the CI matrix
#     julia test/run_matrix.jl 1.9 1.11   # only these
#
# Why this exists: the suite is normally developed against one local Julia,
# but [compat] claims 1.9 and CI tests four versions. Version-conditional Base
# APIs (`Base.specializations` arrived in 1.10) and version-gated capability
# flags inside Joovy make it easy to write a test that passes locally and
# fails on an older leg. Run this before pushing to see all legs at once.
#
# Requires juliaup (`juliaup add 1.9`, ...). Versions juliaup does not have are
# reported as SKIP, never as a pass.
#
# Each version runs in its own copy of the tracked files, so the four
# resolutions cannot fight over one Manifest.toml.

const ROOT = abspath(joinpath(@__DIR__, ".."))
const WORKFLOW = joinpath(ROOT, ".github", "workflows", "test.yml")

# Parsed out of the workflow rather than duplicated here, so the local matrix
# and the CI matrix cannot drift apart.
function ci_versions()
    m = match(r"julia-version:\s*\[([^\]]*)\]", read(WORKFLOW, String))
    m === nothing && error("no julia-version matrix found in $WORKFLOW")
    return [strip(v, [' ', '\'', '"']) for v in split(m.captures[1], ",")]
end

# Ask the launcher itself rather than parsing `juliaup status`: the status
# table also lists channels like `release`, whose resolved version is not the
# channel name, so a version can be installed and still be unreachable as
# `julia +1.12`. Only a successful launch proves the channel exists.
function have_version(version::AbstractString)
    try
        return success(run(pipeline(ignorestatus(`julia +$version --version`),
                                    stdout=devnull, stderr=devnull)))
    catch
        return false
    end
end

function run_one(version::AbstractString)
    if !have_version(version)
        @info "SKIP $version -- no such juliaup channel (run: juliaup add $version)"
        return :skip
    end
    dir = mktempdir()
    for f in eachline(`git -C $ROOT ls-files`)
        dest = joinpath(dir, f)
        mkpath(dirname(dest))
        cp(joinpath(ROOT, f), dest; force=true)
    end
    @info "RUN  $version"
    ok = success(run(ignorestatus(
        `julia +$version --project=$dir -e "using Pkg; Pkg.test()"`)))
    return ok ? :pass : :fail
end

function main(args)
    versions = isempty(args) ? ci_versions() : args
    results = [(v, run_one(v)) for v in versions]
    println("\n", "="^46)
    for (v, r) in results
        println(rpad("julia $v", 16), uppercase(string(r)))
    end
    println("="^46)
    exit(any(r === :fail for (_, r) in results) ? 1 : 0)
end

main(ARGS)

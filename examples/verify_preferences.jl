# End-to-end verification of the [Joovy] LocalPreferences.toml tier configuration.
#
# Unlike test/test_config.jl (which drives the apply logic with in-memory dicts), each
# scenario here runs in a FRESH julia process against a throwaway project, so it exercises
# the REAL path: on-disk LocalPreferences.toml -> `using Joovy` __init__ -> tiers applied.
# Joovy is loaded the way the IDE loads it (pushed onto LOAD_PATH), which also exercises the
# direct-TOML read fallback (Base.get_preferences returns nothing when Joovy isn't a formal
# dep). The formal-dep path feeds the identical dict into the same apply logic.
#
# Run:   julia examples/verify_preferences.jl
# Exits 0 if every scenario passes, 1 otherwise.

const JOOVY_ROOT = dirname(@__DIR__)   # examples/ -> repo root

struct Scenario
    name::String
    prefs::Union{String,Nothing}   # LocalPreferences.toml content, or nothing for none
    body::String                   # julia run in the child after `using Joovy`
    expect::Vector{Pair{String,String}}
end

function run_child(projdir::String, body::String)
    driver = joinpath(projdir, "_driver.jl")
    open(driver, "w") do io
        println(io, "push!(LOAD_PATH, ", repr(JOOVY_ROOT), ")")
        println(io, "ENV[\"JOOVY_VERIFY_DIR\"] = ", repr(projdir))
        println(io, "using Joovy")
        println(io, body)
    end
    out = IOBuffer()
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$projdir $driver`
    try
        run(pipeline(cmd; stdout=out, stderr=devnull))
    catch e
        return Dict{String,String}("_error" => sprint(showerror, e))
    end
    res = Dict{String,String}()
    for line in split(String(take!(out)), '\n')
        i = findfirst('=', line)
        i === nothing && continue
        res[strip(line[1:i-1])] = strip(line[i+1:end])
    end
    return res
end

const SCENARIOS = Scenario[
    Scenario("default + per-package override",
        """
        [Joovy]
        default = "tier_1"
        Base64 = "tier_0"
        """,
        """
        st = joovy_config_status()
        println("has_config=", st.has_config)
        println("default=", st.default)
        println("dev_tier=", joovy_dev_mode_status().tier)
        Base.eval(Main, :(using Base64)); sleep(0.4)
        println("base64_tier=", get(joovy_package_tiers(), :Base64, (tier=-1,)).tier)
        """,
        ["has_config"=>"true", "default"=>"1", "dev_tier"=>"1", "base64_tier"=>"0"]),

    Scenario("no config is a clean no-op",
        nothing,
        """
        println("has_config=", joovy_config_status().has_config)
        println("dev_active=", joovy_dev_mode_status().active)
        """,
        ["has_config"=>"false", "dev_active"=>"false"]),

    Scenario("selective mode (package key, no default)",
        """
        [Joovy]
        Base64 = "tier_0"
        """,
        """
        Base.eval(Main, :(using Base64)); Base.eval(Main, :(using Dates)); sleep(0.5)
        t = joovy_package_tiers()
        println("base64_tier=", get(t, :Base64, (tier=-1,)).tier)
        println("dates_tiered=", haskey(t, :Dates))
        println("selective=", Joovy.PackageTier._selective_mode[])
        """,
        ["base64_tier"=>"0", "dates_tiered"=>"false", "selective"=>"true"]),

    Scenario("per-function tier via joovy_exec",
        """
        [Joovy]
        "Main.hot_calc" = "tier_2"
        """,
        """
        joovy_exec("hot_calc(x) = x + 1\\nnorm_calc(x) = x + 2"; tier=1, instrument=:count)
        d = Dict(f["name"] => f["tier"] for f in counters_report()["functions"])
        println("hot_tier=", get(d, "hot_calc", -1))
        println("norm_tier=", get(d, "norm_calc", -1))
        """,
        ["hot_tier"=>"2", "norm_tier"=>"1"]),

    Scenario("live re-apply after editing the file (no recompile)",
        """
        [Joovy]
        default = "tier_1"
        """,
        """
        println("t1=", joovy_dev_mode_status().tier)
        open(joinpath(ENV["JOOVY_VERIFY_DIR"], "LocalPreferences.toml"), "w") do io
            write(io, "[Joovy]\\ndefault = \\"tier_0\\"\\n")
        end
        joovy_apply_preferences!()
        println("t2=", joovy_dev_mode_status().tier)
        """,
        ["t1"=>"1", "t2"=>"0"]),
]

function main()
    println("Joovy [Joovy]-preferences end-to-end verification")
    println("repo: ", JOOVY_ROOT)
    println("=" ^ 70)
    npass = 0
    fails = String[]
    for s in SCENARIOS
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"),
                  "name = \"VerifyProj\"\nuuid = \"11111111-2222-3333-4444-555555555555\"\n")
            s.prefs === nothing || write(joinpath(dir, "LocalPreferences.toml"), s.prefs)
            res = run_child(dir, s.body)
            problems = String[]
            if haskey(res, "_error")
                push!(problems, "child process error: " * res["_error"])
            else
                for (k, v) in s.expect
                    got = get(res, k, "<missing>")
                    got == v || push!(problems, "$k: expected `$v`, got `$got`")
                end
            end
            if isempty(problems)
                npass += 1
                println("  PASS  ", s.name)
            else
                push!(fails, s.name)
                println("  FAIL  ", s.name)
                for p in problems
                    println("          - ", p)
                end
            end
        end
    end
    println("=" ^ 70)
    println("$npass/$(length(SCENARIOS)) scenarios passed")
    if !isempty(fails)
        println("FAILED: ", join(fails, ", "))
        exit(1)
    end
    println("All good.")
end

main()

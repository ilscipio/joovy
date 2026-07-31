# Tests for the LocalPreferences.toml tier-config layer (Config submodule).
# The parse/apply logic is exercised via in-memory dicts (Config._apply_prefs!) so no
# on-disk LocalPreferences.toml is required; a small end-to-end read test uses a temp file.

using Base64   # a lightweight already-loaded package to tier

const Cfg = Joovy.Config
const PT  = Joovy.PackageTier

# Reset shared tier state so scenarios don't leak into each other.
function _reset_tier_state!()
    PT.joovy_dev_mode!(active=false)
    Cfg._apply_prefs!(Dict{String,Any}())   # clears config maps, leaves dev mode off
    Joovy.reset_counters!()
    nothing
end

@testset "Config" begin

    @testset "_parse_tier" begin
        for s in ("tier_0", "TIER_0", "0", "interpreted", "min", " tier_0 ")
            @test Cfg._parse_tier(s) == 0
        end
        for s in ("tier_1", "1", "reduced", "fast", "low")
            @test Cfg._parse_tier(s) == 1
        end
        for s in ("tier_2", "2", "full", "native", "opt")
            @test Cfg._parse_tier(s) == 2
        end
        @test Cfg._parse_tier(0) == 0
        @test Cfg._parse_tier(1) == 1
        @test Cfg._parse_tier(2) == 2
        @test Cfg._parse_tier(7) == 2          # clamp high ints to full-native
        @test Cfg._parse_tier(-3) == 0         # clamp low ints to interpreted
        @test Cfg._parse_tier("tier_9") === nothing
        @test Cfg._parse_tier("garbage") === nothing
        @test Cfg._parse_tier(true) === nothing
    end

    @testset "default + package + function keys" begin
        _reset_tier_state!()
        r = Cfg._apply_prefs!(Dict{String,Any}(
            "default"          => "tier_1",
            "Base64"           => "tier_0",
            "SomePkg"          => "tier_2",
            "Main.hot_calc"    => "tier_2",
        ))
        @test r.has_config
        @test r.default == 1
        @test r.packages == 2
        @test r.functions == 1

        # default applied through the existing dev-mode API
        dm = joovy_dev_mode_status()
        @test dm.active
        @test dm.tier == 1
        @test !PT._selective_mode[]

        # lookups reflect the config
        @test Cfg.joovy_config_pkg_tier(:Base64) == 0
        @test Cfg.joovy_config_pkg_tier(:SomePkg) == 2
        @test Cfg.joovy_config_pkg_tier(:Unlisted) === nothing
        @test Cfg.joovy_config_fn_tier(:Main, :hot_calc) == 2
        @test Cfg.joovy_config_fn_tier(:Main, :other) === nothing

        # an already-loaded configured package was retiered immediately
        @test get(joovy_package_tiers(), :Base64, (tier=-1,)).tier == 0
    end

    @testset "selective mode (packages, no default)" begin
        _reset_tier_state!()
        r = Cfg._apply_prefs!(Dict{String,Any}("Base64" => "tier_0"))
        @test r.has_config
        @test r.default === nothing
        @test PT._dev_mode[]              # hook installed so later loads are seen
        @test PT._selective_mode[]        # but only configured packages get tiered
        @test Cfg.joovy_config_pkg_tier(:Base64) == 0
    end

    @testset "invalid entries are ignored, not fatal" begin
        _reset_tier_state!()
        r = (@test_logs (:warn,) (:warn,) match_mode=:any Cfg._apply_prefs!(Dict{String,Any}(
            "default" => "tier_1",
            "Base64"  => "nonsense",
            "Bad.fn"  => "tier_9",
        )))
        @test r.has_config
        @test r.default == 1
        @test r.packages == 0            # the two bad entries were dropped
        @test r.functions == 0
    end

    @testset "speculate key" begin
        _reset_tier_state!()
        SQ = Joovy.SpecQueue
        SQ.joovy_speculate!(false)

        r1 = Cfg._apply_prefs!(Dict{String,Any}("speculate" => true))
        @test r1.has_config
        @test SQ.joovy_speculate_enabled()

        r2 = Cfg._apply_prefs!(Dict{String,Any}("speculate" => false))
        @test r2.has_config
        @test !SQ.joovy_speculate_enabled()

        r3 = Cfg._apply_prefs!(Dict{String,Any}("speculate" => "true"))
        @test SQ.joovy_speculate_enabled()

        r4 = Cfg._apply_prefs!(Dict{String,Any}("speculate" => "false"))
        @test !SQ.joovy_speculate_enabled()

        # An invalid value warns and is ignored -- speculation state is left as-is.
        SQ.joovy_speculate!(true)
        r5 = (@test_logs (:warn,) match_mode=:any Cfg._apply_prefs!(Dict{String,Any}(
            "speculate" => "invalid"
        )))
        @test r5.has_config
        @test SQ.joovy_speculate_enabled()   # unchanged by the ignored invalid value

        SQ.joovy_speculate!(false)   # reset so later test files start with speculation off
    end

    @testset "empty config is a clean no-op" begin
        _reset_tier_state!()
        r = Cfg._apply_prefs!(Dict{String,Any}())
        @test !r.has_config
        @test r.default === nothing
        @test r.packages == 0 && r.functions == 0
        @test !joovy_dev_mode_status().active
    end

    @testset "joovy_exec honours per-function tier (best-effort)" begin
        _reset_tier_state!()
        Cfg._apply_prefs!(Dict{String,Any}("Main.exec_hot" => "tier_2"))
        # session tier 1: exec_hot is overridden to 2, exec_norm keeps the session tier.
        joovy_exec("exec_hot(x) = x + 1\nexec_norm(x) = x + 2"; tier=1, instrument=:count)
        rep = counters_report()["functions"]
        byname = Dict(f["name"] => f["tier"] for f in rep)
        @test byname["exec_hot"] == 2
        @test byname["exec_norm"] == 1
        _reset_tier_state!()
    end

    @testset "end-to-end read from a LocalPreferences.toml" begin
        # A direct read of an on-disk [Joovy] table via the TOML fallback path.
        mktempdir() do dir
            open(joinpath(dir, "LocalPreferences.toml"), "w") do io
                write(io, """
                [Joovy]
                default = "tier_0"
                Makie = "tier_1"
                "Mod.fn" = "tier_2"
                """)
            end
            t = Joovy.Config.TOML.parsefile(joinpath(dir, "LocalPreferences.toml"))
            j = t["Joovy"]
            @test Cfg._parse_tier(j["default"]) == 0
            @test Cfg._parse_tier(j["Makie"]) == 1
            @test Cfg._parse_tier(j["Mod.fn"]) == 2
        end
    end
end

module Config

# Declarative tier configuration via LocalPreferences.toml ([Joovy] section).
#
# This is a thin, runtime-read front-end over the existing imperative tier API — it
# adds no new tier primitives, it just drives them from a config file:
#
#   [Joovy]
#   default               = "tier_1"   # reserved: global default tier
#   Makie                 = "tier_0"   # package/module name  -> joovy_use_package + load hook
#   "MyModule.hot_func"   = "tier_2"   # quoted dotted key    -> best-effort per-function tier
#
# Reads are done at runtime (Base.get_preferences / a direct TOML parse), NOT via the
# `@load_preference` macro, so editing LocalPreferences.toml and starting a new REPL
# (or calling joovy_apply_preferences!) picks up changes with no Joovy recompilation.
#
# Semantics:
#   * `default` set          -> global dev mode at that tier; every loaded package is
#                               tiered to it, and per-package entries override it.
#   * only per-package keys  -> selective mode: ONLY the configured packages are tiered;
#                               everything else keeps native (tier 2).
#   * per-function keys      -> best-effort. Honoured for functions Joovy itself compiles
#                               (user REPL/notebook code via joovy_exec). Already-compiled
#                               external functions fall back to their module/package tier,
#                               because Julia's @compiler_options/@optlevel are module-granular.

import ..PackageTier
import ..Instrument
import ..SpecQueue
import ..TypedInterp
import TOML

export joovy_apply_preferences!, joovy_config_status,
       joovy_config_pkg_tier, joovy_config_fn_tier

const JOOVY_UUID = Base.UUID("f0a2e3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b")

const _cfg_lock = ReentrantLock()
const _pkg_tier_config = Dict{Symbol, Int}()             # package/module name -> tier
const _fn_tier_config  = Dict{Tuple{Symbol,Symbol}, Int}()  # (module, function) -> tier
const _default_tier    = Ref{Union{Int,Nothing}}(nothing)
const _has_config      = Ref{Bool}(false)

# ===================================================================
# Tier-name parsing: "tier_0"/int/alias -> Int (0/1/2), else nothing
# ===================================================================

function _parse_tier(x)::Union{Int,Nothing}
    if x isa Bool
        return nothing
    elseif x isa Integer
        x <= 0 && return 0
        x == 1 && return 1
        return 2                      # clamp anything >= 2 to full-native
    elseif x isa AbstractString
        s = lowercase(strip(x))
        s in ("tier_0", "tier0", "0", "interpreted", "min")        && return 0
        s in ("tier_1", "tier1", "1", "reduced", "fast", "low")    && return 1
        s in ("tier_2", "tier2", "2", "full", "native", "opt")     && return 2
        return nothing
    end
    return nothing
end

# ===================================================================
# Bool-value parsing for the reserved `speculate` key -> Bool/nothing
# ===================================================================

function _parse_bool(x)::Union{Bool,Nothing}
    x isa Bool && return x
    if x isa AbstractString
        s = lowercase(strip(x))
        s == "true"  && return true
        s == "false" && return false
    end
    return nothing
end

# ===================================================================
# Reading the [Joovy] table from LocalPreferences.toml
# ===================================================================

function _read_joovy_prefs()::Dict{String,Any}
    # Primary: Base preference machinery — merged across the environment/depot stack.
    # Works when Joovy is a formal dependency (e.g. `] add Joovy`).
    try
        p = Base.get_preferences(JOOVY_UUID)
        if p isa AbstractDict && !isempty(p)
            return Dict{String,Any}(string(k) => v for (k, v) in p)
        end
    catch
    end
    # Fallback: parse the active project's LocalPreferences.toml directly, keyed by our
    # known package name "Joovy". Works even when Joovy is only on LOAD_PATH (IDE case),
    # where Base.get_preferences can't resolve the uuid -> name mapping.
    try
        proj = Base.active_project()
        if proj !== nothing
            lp = joinpath(dirname(proj), "LocalPreferences.toml")
            if isfile(lp)
                t = TOML.parsefile(lp)
                j = get(t, "Joovy", nothing)
                if j isa AbstractDict
                    return Dict{String,Any}(string(k) => v for (k, v) in j)
                end
            end
        end
    catch
    end
    return Dict{String,Any}()
end

# ===================================================================
# Lookups consulted by the package-load hook and joovy_exec
# ===================================================================

function joovy_config_pkg_tier(name::Symbol)::Union{Int,Nothing}
    lock(_cfg_lock) do
        get(_pkg_tier_config, name, nothing)
    end
end

function joovy_config_fn_tier(mod::Symbol, fn::Symbol)::Union{Int,Nothing}
    lock(_cfg_lock) do
        get(_fn_tier_config, (mod, fn), nothing)
    end
end

function _install_lookups!()
    PackageTier._config_pkg_tier_lookup[] = joovy_config_pkg_tier
    Instrument._config_fn_tier_lookup[] = joovy_config_fn_tier
    return nothing
end

# ===================================================================
# Public API
# ===================================================================

"""
    joovy_apply_preferences!(; fallback_tier=nothing)

Read the `[Joovy]` section of LocalPreferences.toml and apply the configured tiers via
the existing tier API. Idempotent — safe to call repeatedly (e.g. after editing the file).

`fallback_tier`, if given, is used as the global default only when the config has no
`default` key (the IDE passes `1` to preserve its historical tier-1 dev-mode default).

Returns `(has_config, default, packages, functions)`.
"""
function joovy_apply_preferences!(; fallback_tier::Union{Int,Nothing}=nothing)
    return _apply_prefs!(_read_joovy_prefs(); fallback_tier=fallback_tier)
end

# Apply an already-read `[Joovy]` table. Split out from joovy_apply_preferences! so the
# parse/apply logic is testable with an in-memory dict (no file dependency).
function _apply_prefs!(prefs::AbstractDict; fallback_tier::Union{Int,Nothing}=nothing)
    _install_lookups!()
    pkgs = Tuple{Symbol,Int}[]
    fns  = Tuple{Symbol,Symbol,Int}[]
    dtier = nothing

    lock(_cfg_lock) do
        empty!(_pkg_tier_config)
        empty!(_fn_tier_config)
        _default_tier[] = nothing

        for (key, val) in prefs
            if key == "default"
                t = _parse_tier(val)
                t === nothing ?
                    @warn("Joovy config: invalid tier for `default`: $(repr(val)) (ignored)") :
                    (_default_tier[] = t)
                continue
            end
            if key == "speculate"
                b = _parse_bool(val)
                b === nothing ?
                    @warn("Joovy config: invalid value for `speculate`: $(repr(val)) (ignored)") :
                    SpecQueue.joovy_speculate!(b)
                continue
            end
            if key == "typed_interp"
                b = _parse_bool(val)
                b === nothing ?
                    @warn("Joovy config: invalid value for `typed_interp`: $(repr(val)) (ignored)") :
                    TypedInterp.joovy_typed_interp!(b)
                continue
            end
            t = _parse_tier(val)
            if t === nothing
                @warn "Joovy config: invalid tier for `$key`: $(repr(val)) (ignored)"
                continue
            end
            if occursin('.', key)
                parts = rsplit(key, '.'; limit=2)
                length(parts) == 2 || continue
                m = Symbol(parts[1]); f = Symbol(parts[2])
                _fn_tier_config[(m, f)] = t
                push!(fns, (m, f, t))
            else
                nm = Symbol(key)
                _pkg_tier_config[nm] = t
                push!(pkgs, (nm, t))
            end
        end
        dtier = _default_tier[]
        _has_config[] = !isempty(prefs)
    end

    # Resolve the global default: config `default` wins, else caller fallback, else — if
    # only per-package keys were given — install the hook in selective mode.
    applied_default = nothing
    if dtier !== nothing
        PackageTier.joovy_dev_mode!(; tier=dtier)
        applied_default = dtier
    elseif fallback_tier !== nothing
        PackageTier.joovy_dev_mode!(; tier=fallback_tier)
        applied_default = fallback_tier
    elseif !isempty(pkgs)
        PackageTier._enable_config_hook!(selective=true)
    end

    # Apply configured package tiers to ALREADY-LOADED packages right now; the load hook
    # (installed above) handles anything loaded later.
    for (nm, t) in pkgs
        if isdefined(Main, nm) && getfield(Main, nm) isa Module
            try
                PackageTier.joovy_use_package(nm; tier=t)
            catch e
                @warn "Joovy config: failed to tier package $nm" exception=e
            end
        end
    end

    return (has_config = _has_config[], default = applied_default,
            packages = length(pkgs), functions = length(fns))
end

function joovy_config_status()
    lock(_cfg_lock) do
        (has_config = _has_config[],
         default    = _default_tier[],
         packages   = Dict(string(k) => v for (k, v) in _pkg_tier_config),
         functions  = Dict("$(m).$(f)" => t for ((m, f), t) in _fn_tier_config))
    end
end

end # module

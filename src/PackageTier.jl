module PackageTier

using ..CompileTimeline
using ..TieredCompile

export joovy_use_package, joovy_promote_package!, joovy_dev_mode!, joovy_dev_mode_eager!,
       joovy_dev_mode_status, joovy_package_tiers, joovy_promote_loaded!

mutable struct PackageTierState
    tier::Int
    submodules::Vector{Module}
end

const _package_tiers = Dict{Symbol, PackageTierState}()
const _package_tiers_lock = ReentrantLock()

const _dev_mode = Ref{Bool}(false)
const _dev_tier = Ref{Int}(1)
const _hook_installed = Ref{Bool}(false)

# ===================================================================
# Core: set optlevel on a module and all its submodules
# ===================================================================

function _set_tier_recursive!(mod::Module, tier::Int)
    mods = Module[mod]
    _collect_submodules!(mod, mods, Set{UInt64}())

    for m in mods
        try
            set_module_tier!(m, tier)
        catch
        end
    end

    return mods
end

function _collect_submodules!(mod::Module, result::Vector{Module}, seen::Set{UInt64})
    id = objectid(mod)
    id in seen && return
    push!(seen, id)

    for name in names(mod; all=true)
        isdefined(mod, name) || continue
        name === nameof(mod) && continue
        try
            val = getfield(mod, name)
            if val isa Module && val !== mod && val !== Main && val !== Base && val !== Core
                if parentmodule(val) === mod
                    push!(result, val)
                    _collect_submodules!(val, result, seen)
                end
            end
        catch
        end
    end
end

# ===================================================================
# Public API
# ===================================================================

function joovy_use_package(pkg::Symbol; tier::Int=_dev_tier[], mod::Module=Main)
    pkg_mod = if isdefined(mod, pkg)
        getfield(mod, pkg)
    else
        Core.eval(mod, :(using $pkg))
        Base.invokelatest(getfield, mod, pkg)
    end

    pkg_mod isa Module || error("$pkg is not a module")

    t0 = time_ns()
    submodules = _set_tier_recursive!(pkg_mod, tier)
    elapsed = time_ns() - t0

    lock(_package_tiers_lock) do
        _package_tiers[pkg] = PackageTierState(tier, submodules)
    end

    record_compile!(CompileEvent(
        pkg, tier, UInt64(elapsed), :package_tier,
        Symbol[], UInt64(time_ns()), :package_tier
    ))

    return (package=pkg, tier=tier, modules_configured=length(submodules))
end

function joovy_promote_package!(pkg::Symbol; tier::Int=2)
    state = lock(_package_tiers_lock) do
        get(_package_tiers, pkg, nothing)
    end

    if state === nothing
        return joovy_use_package(pkg; tier=tier)
    end

    for m in state.submodules
        try
            set_module_tier!(m, tier)
        catch
        end
    end

    lock(_package_tiers_lock) do
        state.tier = tier
    end

    return (package=pkg, tier=tier)
end

function joovy_dev_mode!(; tier::Int=1, active::Bool=true)
    _dev_mode[] = active
    _dev_tier[] = tier
    if active && !_hook_installed[]
        _install_package_hook!()
    end
    return (active=active, tier=tier)
end

function joovy_dev_mode_eager!(; tier::Int=1, active::Bool=true)
    joovy_dev_mode!(; tier=tier, active=active)
    if active
        _apply_to_loaded_packages!(tier)
    else
        _apply_to_loaded_packages!(2)
    end
    return (active=active, tier=tier)
end

function joovy_dev_mode_status()
    tiers = lock(_package_tiers_lock) do
        Dict(k => v.tier for (k, v) in _package_tiers)
    end
    return (active=_dev_mode[], tier=_dev_tier[], packages=tiers)
end

function joovy_package_tiers()
    lock(_package_tiers_lock) do
        Dict(k => (tier=v.tier, modules=length(v.submodules)) for (k, v) in _package_tiers)
    end
end

function joovy_promote_loaded!(; tier::Int=2)
    tiers = joovy_package_tiers()
    promoted = Symbol[]
    for (pkg, info) in tiers
        info.tier < tier || continue
        try
            joovy_promote_package!(pkg; tier=tier)
            push!(promoted, pkg)
        catch
        end
    end
    return promoted
end

# ===================================================================
# Auto-hook: apply dev tier to newly loaded packages
# ===================================================================

const _SKIP_PACKAGES = Set{Symbol}([
    :Base, :Core, :Main, :Joovy, :InteractiveUtils,
    :Pkg, :REPL, :Test, :Logging, :Serialization, :Statistics
])

function _apply_to_loaded_packages!(tier::Int)
    known = lock(_package_tiers_lock) do
        Set(keys(_package_tiers))
    end

    for name in names(Main; imported=true)
        name in _SKIP_PACKAGES && continue
        name in known && continue
        isdefined(Main, name) || continue
        try
            val = getfield(Main, name)
            if val isa Module && val !== Main && parentmodule(val) !== Main
                joovy_use_package(name; tier=tier)
            end
        catch
        end
    end
end

function _install_package_hook!()
    _hook_installed[] && return

    if isdefined(Base, :package_callbacks) && Base.package_callbacks isa Vector
        push!(Base.package_callbacks, _on_package_load)
        _hook_installed[] = true
    end
end

function _on_package_load(pkg_id)
    _dev_mode[] || return
    @async begin
        sleep(0.01)
        try
            mod = Base.root_module(pkg_id)
            name = nameof(mod)
            name in _SKIP_PACKAGES && return
            lock(_package_tiers_lock) do
                haskey(_package_tiers, name) && return
            end
            joovy_use_package(name; tier=_dev_tier[])
        catch
        end
    end
end

end # module

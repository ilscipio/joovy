module ColdLoad

using ..TieredCompile
using ..PackageTier
using ..CompileTimeline

export prepare_cold_load!, finish_cold_load!, cold_load_active

const _cold_active = Ref{Bool}(false)
const _cold_tier = Ref{Int}(0)
const _sync_callback_installed = Ref{Bool}(false)

cold_load_active() = _cold_active[]

# ===================================================================
# Enumerate all loaded modules (Base, Core, stdlibs, etc.)
# ===================================================================

function _enumerate_all_modules()
    result = Module[]
    seen = Set{UInt64}()
    queue = Module[Main, Base, Core]
    if isdefined(Base, :loaded_modules)
        for (_, mod) in Base.loaded_modules
            push!(queue, mod)
        end
    end
    while !isempty(queue)
        mod = popfirst!(queue)
        id = objectid(mod)
        id in seen && continue
        push!(seen, id)
        push!(result, mod)
        for name in names(mod; all=true)
            isdefined(mod, name) || continue
            name === nameof(mod) && continue
            try
                val = getfield(mod, name)
                if val isa Module && val !== mod && val !== Main && val !== Base && val !== Core
                    push!(queue, val)
                end
            catch
            end
        end
    end
    return result
end

# ===================================================================
# Synchronous package callback — tiers each dependency immediately
# as it loads, before the next dependency starts loading.
# ===================================================================

function _sync_package_callback(pkg_id)
    _cold_active[] || return
    try
        mod = Base.root_module(pkg_id)
        PackageTier._set_tier_recursive!(mod, _cold_tier[])
    catch
    end
end

function _install_sync_callback!()
    _sync_callback_installed[] && return
    if isdefined(Base, :package_callbacks) && Base.package_callbacks isa Vector
        push!(Base.package_callbacks, _sync_package_callback)
        _sync_callback_installed[] = true
    end
end

function _uninstall_sync_callback!()
    _sync_callback_installed[] || return
    if isdefined(Base, :package_callbacks) && Base.package_callbacks isa Vector
        filter!(f -> f !== _sync_package_callback, Base.package_callbacks)
        _sync_callback_installed[] = false
    end
end

# ===================================================================
# Public API
# ===================================================================

function prepare_cold_load!(tier::Int=0)
    _cold_active[] && return
    _cold_tier[] = tier
    _cold_active[] = true

    all_mods = _enumerate_all_modules()
    for mod in all_mods
        try
            set_module_tier!(mod, tier)
        catch
        end
    end

    _install_sync_callback!()
    return nothing
end

function finish_cold_load!()
    _cold_active[] || return
    _cold_active[] = false
    _uninstall_sync_callback!()

    _restore_base_modules!()
    return nothing
end

function _restore_base_modules!()
    skip = PackageTier._SKIP_PACKAGES
    for mod in _enumerate_all_modules()
        name = nameof(mod)
        pm = parentmodule(mod)
        if mod === Base || mod === Core || pm === Base || pm === Core || name in skip
            try
                set_module_tier!(mod, 2)
            catch
            end
        end
    end
end

end # module

module MemoryManager

using ..ExprCache
using ..DynCompiler
using ..HotSwap
using ..CompileTimeline

export cache_trim!, hotswap_trim_history!, source_map_gc!, joovy_memory_stats,
       timeline_trim!

function cache_trim!(cache::JoovyCache; keep::Int=100)
    lock(cache.lock) do
        n = length(cache.content_cache)
        n <= keep && return 0

        sorted = sort(collect(cache.hit_counts); by=last)
        to_remove = n - keep
        removed = 0

        for (hash, _) in sorted
            removed >= to_remove && break
            delete!(cache.content_cache, hash)
            delete!(cache.hit_counts, hash)
            removed += 1
        end

        filter!(kv -> haskey(cache.content_cache, expr_hash(kv.first)), cache.string_cache)
        filter!(kv -> haskey(cache.content_cache, kv.second), cache.name_cache)

        return removed
    end
end

function hotswap_trim_history!(name::Symbol; keep_last::Int=5,
                               registry::HotSwapRegistry=GLOBAL_REGISTRY)
    entry = lock(registry.lock) do
        get(registry.entries, name, nothing)
    end

    if entry === nothing
        error("No hot-swappable function registered as :$name")
    end

    lock(entry.lock) do
        n = length(entry.history)
        if n > keep_last
            deleteat!(entry.history, 1:(n - keep_last))
        end
        return n - length(entry.history)
    end
end

function source_map_gc!()
    lock(DynCompiler._source_map_lock) do
        current_max = DynCompiler._compile_counter[]
        to_delete = Symbol[]

        for (name, mapping) in GLOBAL_SOURCE_MAP
            if mapping.compile_id < current_max - 1000
                push!(to_delete, name)
            end
        end

        for name in to_delete
            delete!(GLOBAL_SOURCE_MAP, name)
        end

        return length(to_delete)
    end
end

function joovy_memory_stats()
    cache_entries = lock(GLOBAL_CACHE.lock) do
        length(GLOBAL_CACHE.content_cache)
    end

    string_cache_entries = lock(GLOBAL_CACHE.lock) do
        length(GLOBAL_CACHE.string_cache)
    end

    map_entries = lock(DynCompiler._source_map_lock) do
        length(GLOBAL_SOURCE_MAP)
    end

    total_history = 0
    registry_entries = 0
    lock(GLOBAL_REGISTRY.lock) do
        registry_entries = length(GLOBAL_REGISTRY.entries)
        for (_, entry) in GLOBAL_REGISTRY.entries
            lock(entry.lock) do
                total_history += length(entry.history)
            end
        end
    end

    timeline_events = lock(CompileTimeline._timeline_lock) do
        length(CompileTimeline._TIMELINE)
    end

    return (
        cache_entries=cache_entries,
        string_cache_entries=string_cache_entries,
        source_map_entries=map_entries,
        registry_entries=registry_entries,
        total_history_entries=total_history,
        compile_counter=DynCompiler._compile_counter[],
        timeline_events=timeline_events
    )
end

function timeline_trim!(; keep_last::Int=1000)
    lock(CompileTimeline._timeline_lock) do
        tl = CompileTimeline._TIMELINE
        n = length(tl)
        if n > keep_last
            deleteat!(tl, 1:(n - keep_last))
        end
        return n - length(tl)
    end
end

end # module

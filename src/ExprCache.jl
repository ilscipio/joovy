module ExprCache

export JoovyCache, cache_put!, cache_get, cache_has, cache_register!,
       cache_lookup, cache_clear!, cache_stats, normalize_expr, expr_hash

struct CacheStats
    content_hits::Int
    content_misses::Int
    name_hits::Int
    name_misses::Int
    total_entries::Int
end

mutable struct JoovyCache
    content_cache::Dict{String, Any}
    string_cache::Dict{String, Any}
    name_cache::Dict{Symbol, String}
    hit_counts::Dict{String, Int}
    lock::ReentrantLock
    stats_content_hits::Int
    stats_content_misses::Int
    stats_name_hits::Int
    stats_name_misses::Int

    JoovyCache() = new(
        Dict{String, Any}(),
        Dict{String, Any}(),
        Dict{Symbol, String}(),
        Dict{String, Int}(),
        ReentrantLock(),
        0, 0, 0, 0
    )
end

function normalize_expr(expr::Expr)
    _strip_linenums(expr)
end

normalize_expr(x) = x

function _strip_linenums(expr::Expr)
    if expr.head === :line
        return nothing
    end
    new_args = []
    for arg in expr.args
        if arg isa LineNumberNode
            continue
        elseif arg isa Expr
            result = _strip_linenums(arg)
            if result !== nothing
                push!(new_args, result)
            end
        else
            push!(new_args, arg)
        end
    end
    Expr(expr.head, new_args...)
end

function expr_hash(expr)
    normalized = normalize_expr(expr)
    string(hash(string(normalized)); base=16)
end

function expr_hash(s::String)
    string(hash(s); base=16)
end

function cache_put!(cache::JoovyCache, code::String, compiled)
    h = expr_hash(code)
    lock(cache.lock) do
        cache.content_cache[h] = compiled
        cache.string_cache[code] = compiled
        cache.hit_counts[h] = 0
    end
    return h
end

function cache_put!(cache::JoovyCache, expr::Expr, compiled)
    h = expr_hash(expr)
    lock(cache.lock) do
        cache.content_cache[h] = compiled
        cache.hit_counts[h] = 0
    end
    return h
end

function cache_get(cache::JoovyCache, code::String)
    lock(cache.lock) do
        if haskey(cache.string_cache, code)
            cache.stats_content_hits += 1
            h = expr_hash(code)
            cache.hit_counts[h] = get(cache.hit_counts, h, 0) + 1
            return cache.string_cache[code]
        end
        cache.stats_content_misses += 1
        return nothing
    end
end

function cache_get(cache::JoovyCache, expr::Expr)
    h = expr_hash(expr)
    lock(cache.lock) do
        if haskey(cache.content_cache, h)
            cache.stats_content_hits += 1
            cache.hit_counts[h] = get(cache.hit_counts, h, 0) + 1
            return cache.content_cache[h]
        else
            cache.stats_content_misses += 1
            return nothing
        end
    end
end

function cache_has(cache::JoovyCache, expr)
    h = expr_hash(expr)
    lock(cache.lock) do
        return haskey(cache.content_cache, h)
    end
end

function cache_register!(cache::JoovyCache, name::Symbol, expr)
    h = expr_hash(expr)
    lock(cache.lock) do
        cache.name_cache[name] = h
    end
    return h
end

function cache_lookup(cache::JoovyCache, name::Symbol)
    lock(cache.lock) do
        if haskey(cache.name_cache, name)
            cache.stats_name_hits += 1
            h = cache.name_cache[name]
            if haskey(cache.content_cache, h)
                return cache.content_cache[h]
            end
        end
        cache.stats_name_misses += 1
        return nothing
    end
end

function cache_clear!(cache::JoovyCache)
    lock(cache.lock) do
        empty!(cache.content_cache)
        empty!(cache.string_cache)
        empty!(cache.name_cache)
        empty!(cache.hit_counts)
        cache.stats_content_hits = 0
        cache.stats_content_misses = 0
        cache.stats_name_hits = 0
        cache.stats_name_misses = 0
    end
end

function cache_stats(cache::JoovyCache)
    lock(cache.lock) do
        CacheStats(
            cache.stats_content_hits,
            cache.stats_content_misses,
            cache.stats_name_hits,
            cache.stats_name_misses,
            length(cache.content_cache)
        )
    end
end

end # module

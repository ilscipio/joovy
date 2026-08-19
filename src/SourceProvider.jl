# src/SourceProvider.jl
#
# One choke point for all user-source reads in Joovy: a path-keyed cache that
# the IDE fills over IPC (`source_push!`), with disk fallback. An empty cache
# is byte-identical to today's "always read the file" behavior -- this module
# only changes anything once something has actually been pushed into it.
#
# This lets reload/use IPC calls (`joovy/reload`, `joovy/use`) consume an
# unsaved editor buffer sent inline by the IDE, instead of requiring the
# buffer to be flushed to disk first.
#
# Zero non-stdlib dependencies. No file I/O ever happens while `_cache_lock`
# (or `_providers_lock`) is held -- `mtime`/`isfile`/`read` calls are always
# performed outside the locked region.

module SourceProvider

export source_read, source_mtime, source_exists, source_push!, source_invalidate!,
       register_source_provider!, source_stats, source_clear!

# ===================================================================
# Cache entry + storage
# ===================================================================

struct _Entry
    content::String
    version::Union{Int,Nothing}
    disk_mtime_at_push::Union{Float64,Nothing}
end

const _cache = Dict{String,_Entry}()
const _cache_lock = ReentrantLock()

# Providers are tried, in registration order, on a cache miss -- e.g. an IDE
# PSI index that can hand back an editor buffer's content without a round
# trip through disk. Each provider is `path::String -> Union{Nothing,Tuple}`:
# `nothing` means "no opinion, try the next one"; a `(content, version)` pair
# is stored via `source_push!` and returned as the read result.
const _providers = Function[]
const _providers_lock = ReentrantLock()

# Internal counters, exposed via `source_stats()` for tests/bench.
const _reads = Ref{Int}(0)
const _cache_hits = Ref{Int}(0)
const _disk_reads = Ref{Int}(0)
const _stats_lock = ReentrantLock()

# ===================================================================
# Small helpers
# ===================================================================

# Disk mtime, or `nothing` if the file does not exist / cannot be stat'd.
# Never throws. Callers must invoke this OUTSIDE any lock held by this module.
function _safe_mtime(abs_path::String)
    try
        isfile(abs_path) ? mtime(abs_path) : nothing
    catch
        nothing
    end
end

function _snapshot_providers()
    lock(_providers_lock) do
        copy(_providers)
    end
end

# ===================================================================
# Public API
# ===================================================================

"""
    source_push!(path, content, version=nothing)

Push editor-buffer `content` for `path` into the cache. Keyed by `abspath`.
The LAST push always wins. There is deliberately NO version-ordering guard:
pushes arrive on one ordered IPC stream, so real reordering cannot happen,
and the IDE's `version` (the document modification stamp) moves BACKWARD on
undo -- a guard here silently ate the undo push, so a reverted fix never got
re-scanned and its mark stayed gone. `version` is stored for observability
only.
"""
function source_push!(path::AbstractString, content::AbstractString,
                       version::Union{Int,Nothing}=nothing)
    abs_path = abspath(path)
    disk_mtime = _safe_mtime(abs_path)   # I/O happens BEFORE the lock is taken

    lock(_cache_lock) do
        _cache[abs_path] = _Entry(String(content), version, disk_mtime)
        return nothing
    end
    return nothing
end

"""
    source_read(path)::String

The one choke point for reading user source. On a cache hit whose disk mtime
has not moved since the push, returns the cached content with no disk I/O.
If the file's current disk mtime is newer than the mtime recorded at push
time, the entry is evicted (an external edit -- e.g. a save from another
tool -- wins) and the miss path runs.

On a miss, registered providers are tried in registration order; the first
one to return a `(content, version)` pair has it stored via `source_push!`
and returned. If no provider has an opinion, falls back to `read(abspath,
String)`, exactly like today's direct-read call sites.
"""
function source_read(path::AbstractString)::String
    abs_path = abspath(path)
    lock(_stats_lock) do
        _reads[] += 1
    end

    entry = lock(_cache_lock) do
        get(_cache, abs_path, nothing)
    end

    if entry !== nothing
        current_mtime = _safe_mtime(abs_path)   # I/O outside the lock
        stale = entry.disk_mtime_at_push !== nothing && current_mtime !== nothing &&
                current_mtime > entry.disk_mtime_at_push
        if !stale
            lock(_stats_lock) do
                _cache_hits[] += 1
            end
            return entry.content
        end
        lock(_cache_lock) do
            delete!(_cache, abs_path)
        end
    end

    for provider in _snapshot_providers()
        result = provider(abs_path)
        result === nothing && continue
        content, version = result
        source_push!(abs_path, content, version)
        return content
    end

    lock(_stats_lock) do
        _disk_reads[] += 1
    end
    return read(abs_path, String)
end

"""
    source_mtime(path)

A cached entry returns the disk mtime recorded at push time (`0.0` if the
file did not exist on disk at that moment); otherwise falls back to
`mtime(path)`, exactly like today's direct `mtime` call sites.
"""
function source_mtime(path::AbstractString)
    abs_path = abspath(path)
    entry = lock(_cache_lock) do
        get(_cache, abs_path, nothing)
    end
    if entry !== nothing
        return entry.disk_mtime_at_push === nothing ? 0.0 : entry.disk_mtime_at_push
    end
    return mtime(abs_path)
end

"""
    source_exists(path)::Bool

`true` if `path` has a cached entry, or `isfile(path)` otherwise -- so a
never-saved editor buffer (no file on disk) still counts as existing.
"""
function source_exists(path::AbstractString)::Bool
    abs_path = abspath(path)
    lock(_cache_lock) do
        haskey(_cache, abs_path)
    end && return true
    return isfile(abs_path)
end

"""
    source_invalidate!(path)

Drop any cached entry for `path`. A no-op if there isn't one.
"""
function source_invalidate!(path::AbstractString)
    abs_path = abspath(path)
    lock(_cache_lock) do
        delete!(_cache, abs_path)
    end
    return nothing
end

"""
    register_source_provider!(f)

Register a miss-path provider `f(abs_path::String) -> Union{Nothing,Tuple}`.
Providers are tried in registration order on a cache miss.
"""
function register_source_provider!(f::Function)
    lock(_providers_lock) do
        push!(_providers, f)
    end
    return nothing
end

"""
    source_stats()

Returns `(reads, cache_hits, disk_reads)`: total `source_read` calls, calls
served from an unstale cache entry, and calls that fell all the way through
to `read(abspath, String)`.
"""
function source_stats()
    lock(_stats_lock) do
        (reads=_reads[], cache_hits=_cache_hits[], disk_reads=_disk_reads[])
    end
end

"""
    source_clear!()

Reset all state (cache entries, registered providers, counters) to a pristine
empty state. For tests/bench isolation.
"""
function source_clear!()
    lock(_cache_lock) do
        empty!(_cache)
    end
    lock(_providers_lock) do
        empty!(_providers)
    end
    lock(_stats_lock) do
        _reads[] = 0
        _cache_hits[] = 0
        _disk_reads[] = 0
    end
    return nothing
end

end # module

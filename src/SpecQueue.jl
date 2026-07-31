module SpecQueue

# Speculative background compilation.
#
# When a lazy module loads, or one of its functions gets hot enough to promote to a
# higher tier, the functions most likely to be called next are queued for compilation
# in the background -- so by the time the user (or the IDE) actually calls them, the
# first call is already warm.
#
# Design constraints (see Joovy's WP-B task brief):
#   * default OFF (`joovy_speculate!(true)` opts in);
#   * on a single OS thread a compile is a blocking quantum for the task running it, so
#     the consumer processes exactly ONE function per quantum and `yield()`s between
#     quanta -- a busy REPL/eval task never stalls for longer than one compile;
#   * producers (LazyModule/TieredCompile) only know about SpecQueue through Ref-based
#     callback hooks (`_on_use_hook` etc.) installed here in `__init__()`, because
#     Joovy's include order forbids those upstream modules from `using` this one;
#   * hooks fire `@async`, never inline, so speculation never adds synchronous latency.
#
# Priority model: each queued item carries a `class` (how it was discovered) and a
# `score` (how likely it is to matter within that class). The queue is kept sorted by
# `(-class, -score, enqueued_ns)`, so class always wins first (an explicit IDE promote
# intent preempts a background guess), ties within a class break on score, and ties on
# both are FIFO.
#
#   class 3 -- IPC "promote" intent (an IDE explicitly said "warm this up")
#   class 2 -- first-access (a sibling definition in the same file was just touched)
#   class 1 -- promotion-callee (a function got promoted; warm what it calls next)
#   class 0 -- lazy-load (a whole file was just `joovy_use`d)

using ..LazyModules
using ..TieredCompile

export spec_enqueue!, spec_enqueue_all!, spec_enqueue_subtree!, spec_stats,
       spec_pause!, spec_resume!, spec_kill!, joovy_speculate!, joovy_speculate_enabled

# ===================================================================
# Flags & bounds
# ===================================================================

const _ENABLED = Ref(false)
const _PAUSED = Ref(false)
const _KILLED = Ref(false)
const _CONSUMER_STARTED = Ref(false)
const _MAX_QUEUE = 500

# ===================================================================
# Queue item + priority ordering
# ===================================================================

struct SpecItem
    owner::LazyModule
    name::Symbol
    tier::Int
    class::Int      # 3=IPC intent, 2=first-access, 1=promotion-callee, 0=lazy-load
    score::Float64
    enqueued_ns::UInt64
end

_sort_key(item::SpecItem) = (-item.class, -item.score, item.enqueued_ns)

const _QUEUE = SpecItem[]
const _SEEN = Set{Tuple{UInt,Symbol,Int}}()   # (objectid(owner), name, tier)
const _QUEUE_LOCK = ReentrantLock()

# ===================================================================
# Stats
# ===================================================================

mutable struct _SpecStats
    enqueued::Int
    deduped::Int
    dropped::Int
    compiled::Int
    skipped::Int
    errors::Int
    last_error::Union{String,Nothing}
end

const _STATS = _SpecStats(0, 0, 0, 0, 0, 0, nothing)
const _STATS_LOCK = ReentrantLock()

# Lock order is always QUEUE before STATS (STATS may be acquired nested inside an
# already-held QUEUE lock; QUEUE must never be acquired while holding STATS).

# ===================================================================
# Enable / pause / kill
# ===================================================================

"""
    joovy_speculate!(on::Bool) -> Bool

Turn speculative background compilation on or off. Default OFF. Returns `on`.
"""
function joovy_speculate!(on::Bool)::Bool
    _ENABLED[] = on
    return on
end

"Whether speculative background compilation is currently enabled."
joovy_speculate_enabled() = _ENABLED[]

"Pause the background consumer. Items already queued stay queued."
function spec_pause!()
    _PAUSED[] = true
    return nothing
end

"Resume a paused consumer."
function spec_resume!()
    _PAUSED[] = false
    return nothing
end

"""
    spec_kill!()

Hard stop: permanently halts the consumer loop (`_KILLED` has no public reset) and
empties the queue and dedup set. Items enqueued afterwards accumulate but are never
drained, since `_ensure_consumer!` refuses to start a new consumer once killed. This is
a test-teardown primitive only, not something production code calls.
"""
function spec_kill!()
    _KILLED[] = true
    lock(_QUEUE_LOCK) do
        empty!(_QUEUE)
        empty!(_SEEN)
    end
    _CONSUMER_STARTED[] = false
    _PAUSED[] = false
    return nothing
end

# ===================================================================
# Bounded, deduped, priority-sorted enqueue
# ===================================================================

# Caller must already hold `_QUEUE_LOCK`. Drops the single oldest (by enqueued_ns) item
# to make room for a new one when the queue is at capacity.
function _drop_oldest!()
    isempty(_QUEUE) && return nothing
    idx = 1
    oldest = _QUEUE[1].enqueued_ns
    for i in 2:length(_QUEUE)
        if _QUEUE[i].enqueued_ns < oldest
            oldest = _QUEUE[i].enqueued_ns
            idx = i
        end
    end
    victim = _QUEUE[idx]
    deleteat!(_QUEUE, idx)
    delete!(_SEEN, (objectid(victim.owner), victim.name, victim.tier))
    lock(_STATS_LOCK) do
        _STATS.dropped += 1
    end
    return nothing
end

"""
    spec_enqueue!(lm, name; tier=lm.default_tier, class=0, score=0.0) -> Symbol

Enqueue `name` from lazy module `lm` for speculative compilation at `tier`. Returns
`:disabled` (speculation is off), `:unknown` (no such definition in `lm`), `:deduped`
(an equivalent `(lm, name, tier)` item is already queued), or `:queued`.
"""
function spec_enqueue!(lm::LazyModule, name::Symbol; tier::Int=lm.default_tier,
                       class::Int=0, score::Float64=0.0)::Symbol
    _ENABLED[] || return :disabled
    haskey(lm.definitions, name) || return :unknown

    status = lock(_QUEUE_LOCK) do
        key = (objectid(lm), name, tier)
        if key in _SEEN
            :deduped
        else
            length(_QUEUE) >= _MAX_QUEUE && _drop_oldest!()
            push!(_SEEN, key)
            item = SpecItem(lm, name, tier, class, score, time_ns())
            idx = searchsortedfirst(_QUEUE, item; by=_sort_key)
            insert!(_QUEUE, idx, item)
            :queued
        end
    end

    lock(_STATS_LOCK) do
        if status === :queued
            _STATS.enqueued += 1
        elseif status === :deduped
            _STATS.deduped += 1
        end
    end

    status === :queued && _ensure_consumer!()
    return status
end

"""
    spec_enqueue_all!(lm; tier=lm.default_tier, class=0) -> Int

Enqueue every definition in `lm`, scored by reverse-dependency out-degree so functions
with more dependents are compiled first. Returns the number newly queued.
"""
function spec_enqueue_all!(lm::LazyModule; tier::Int=lm.default_tier, class::Int=0)::Int
    n = 0
    for name in keys(lm.definitions)
        score = Float64(length(get(lm.reverse_deps, name, Set{Symbol}())))
        spec_enqueue!(lm, name; tier=tier, class=class, score=score) === :queued && (n += 1)
    end
    return n
end

"""
    spec_enqueue_subtree!(lm, name; tier=2, class=3) -> Int

Enqueue `name` and its full transitive dependency subtree, scored by topological
position so dependencies are queued ahead of (and therefore compiled before) the entry
point that needs them. Returns the number newly queued.
"""
function spec_enqueue_subtree!(lm::LazyModule, name::Symbol; tier::Int=2, class::Int=3)::Int
    haskey(lm.definitions, name) || return 0
    order = LazyModules._topo_sort(name, lm.dependencies, Set{Symbol}())
    n = length(order)
    queued = 0
    for (i, sym) in enumerate(order)
        score = Float64(n - i)   # earlier in `order` (deps) outscores later (the target)
        spec_enqueue!(lm, sym; tier=tier, class=class, score=score) === :queued && (queued += 1)
    end
    return queued
end

# ===================================================================
# Background consumer -- one function compiled per quantum, yield() between
# quanta so a single-thread REPL/eval task is never blocked for more than
# one compile at a time.
# ===================================================================

function _ensure_consumer!()
    _KILLED[] && return nothing
    started = lock(_QUEUE_LOCK) do
        if _CONSUMER_STARTED[]
            false
        else
            _CONSUMER_STARTED[] = true
            true
        end
    end
    started && (@async _consumer_loop())
    return nothing
end

function _pop_next!()
    lock(_QUEUE_LOCK) do
        isempty(_QUEUE) && return nothing
        item = popfirst!(_QUEUE)
        delete!(_SEEN, (objectid(item.owner), item.name, item.tier))
        return item
    end
end

function _run_quantum(item::SpecItem)
    lm = item.owner
    tc = get(lm.compiled, item.name, nothing)
    if tc !== nothing && tc.tier >= item.tier
        lock(_STATS_LOCK) do
            _STATS.skipped += 1
        end
        return nothing
    end
    try
        if Threads.nthreads() > 1
            wait(Threads.@spawn joovy_promote_lazy!(lm, item.name; tier=item.tier))
        else
            joovy_promote_lazy!(lm, item.name; tier=item.tier)
        end
        lock(_STATS_LOCK) do
            _STATS.compiled += 1
        end
    catch e
        lock(_STATS_LOCK) do
            _STATS.errors += 1
            _STATS.last_error = sprint(showerror, e)
        end
    end
    return nothing
end

function _consumer_loop()
    while !_KILLED[]
        if _PAUSED[] || !_ENABLED[]
            sleep(0.2)
            continue
        end
        item = _pop_next!()
        if item === nothing
            sleep(0.05)
            continue
        end
        _run_quantum(item)
        yield()
    end
    return nothing
end

# ===================================================================
# Stats snapshot
# ===================================================================

"""
    spec_stats() -> NamedTuple

Snapshot of the speculative-compilation queue: `enabled`, `paused`, `queue_depth`, and
cumulative counters `enqueued`, `deduped`, `dropped`, `compiled`, `skipped`, `errors`,
plus `last_error` (the most recent error message, or `nothing`).
"""
function spec_stats()
    qdepth = lock(_QUEUE_LOCK) do
        length(_QUEUE)
    end
    lock(_STATS_LOCK) do
        return (
            enabled = _ENABLED[],
            paused = _PAUSED[],
            queue_depth = qdepth,
            enqueued = _STATS.enqueued,
            deduped = _STATS.deduped,
            dropped = _STATS.dropped,
            compiled = _STATS.compiled,
            skipped = _STATS.skipped,
            errors = _STATS.errors,
            last_error = _STATS.last_error,
        )
    end
end

# ===================================================================
# Producer hooks -- installed in __init__ so producers (LazyModule,
# TieredCompile) never need to know SpecQueue exists.
# ===================================================================

function _handle_lazy_use(lm)
    _ENABLED[] || return nothing
    try
        spec_enqueue_all!(lm; tier=lm.default_tier, class=0)
    catch
    end
    return nothing
end

function _handle_first_access(lm, name)
    _ENABLED[] || return nothing
    try
        for pending in LazyModules.lazy_pending(lm)
            score = Float64(length(get(lm.reverse_deps, pending, Set{Symbol}())))
            spec_enqueue!(lm, pending; tier=lm.default_tier, class=2, score=score)
        end
    catch
    end
    return nothing
end

function _handle_tc_promoted(tc)
    _ENABLED[] || return nothing
    try
        lm = tc.owner
        lm isa LazyModule || return nothing
        for callee in get(lm.dependencies, tc.name, Set{Symbol}())
            ctc = get(lm.compiled, callee, nothing)
            score = ctc !== nothing ? Float64(ctc.call_count) : 0.0
            spec_enqueue!(lm, callee; tier=2, class=1, score=score)
        end
    catch
    end
    return nothing
end

function __init__()
    LazyModules._on_use_hook[] = _handle_lazy_use
    LazyModules._on_first_access_hook[] = _handle_first_access
    TieredCompile._on_promote_hook[] = _handle_tc_promoted
    return nothing
end

end # module

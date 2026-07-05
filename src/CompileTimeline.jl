module CompileTimeline

export CompileEvent, record_compile!, compile_timeline, compile_tree,
       compile_stats_summary, compile_report, clear_timeline!

struct CompileEvent
    name::Symbol
    tier::Int
    compile_time_ns::UInt64
    trigger::Symbol
    dependencies::Vector{Symbol}
    timestamp_ns::UInt64
    source::Symbol
end

const _TIMELINE = CompileEvent[]
const _timeline_lock = ReentrantLock()

function record_compile!(event::CompileEvent)
    lock(_timeline_lock) do
        push!(_TIMELINE, event)
    end
    return nothing
end

function compile_timeline(; tier::Union{Int,Nothing}=nothing,
                           source::Union{Symbol,Nothing}=nothing)
    lock(_timeline_lock) do
        if tier === nothing && source === nothing
            return copy(_TIMELINE)
        end
        return filter(_TIMELINE) do e
            (tier === nothing || e.tier == tier) &&
            (source === nothing || e.source == source)
        end
    end
end

function compile_tree(name::Symbol)
    events = compile_timeline()
    event_map = Dict{Symbol, CompileEvent}()
    for e in events
        event_map[e.name] = e
    end
    return _build_tree(name, event_map, Set{Symbol}())
end

function _build_tree(name::Symbol, event_map::Dict{Symbol, CompileEvent},
                     visited::Set{Symbol})
    name in visited && return (name=name, tier=-1, compile_time_ns=UInt64(0),
                               trigger=:cycle, deps=NamedTuple[])
    push!(visited, name)

    event = get(event_map, name, nothing)
    if event === nothing
        return (name=name, tier=-1, compile_time_ns=UInt64(0),
                trigger=:unknown, deps=NamedTuple[])
    end

    child_trees = NamedTuple[]
    for dep in event.dependencies
        push!(child_trees, _build_tree(dep, event_map, visited))
    end

    return (name=name, tier=event.tier, compile_time_ns=event.compile_time_ns,
            trigger=event.trigger, deps=child_trees)
end

function compile_stats_summary()
    lock(_timeline_lock) do
        total_time = UInt64(0)
        count_by_tier = Dict{Int,Int}()
        promotions = 0

        for e in _TIMELINE
            total_time += e.compile_time_ns
            count_by_tier[e.tier] = get(count_by_tier, e.tier, 0) + 1
            if e.trigger === :promote
                promotions += 1
            end
        end

        return (total_compile_time_ns=total_time,
                count_by_tier=count_by_tier,
                promotions=promotions)
    end
end

function compile_report()
    events = compile_timeline()
    isempty(events) && return "No compilation events recorded."

    lines = String[]
    push!(lines, "Joovy Compilation Timeline")
    push!(lines, "=" ^ 80)
    push!(lines, rpad("Function", 25) * rpad("Tier", 6) * rpad("Time", 14) *
                 rpad("Trigger", 14) * "Dependencies")
    push!(lines, "-" ^ 80)

    for e in events
        time_str = if e.compile_time_ns < 1_000_000
            "$(round(e.compile_time_ns / 1_000; digits=1)) us"
        else
            "$(round(e.compile_time_ns / 1_000_000; digits=2)) ms"
        end
        deps_str = isempty(e.dependencies) ? "-" : join(e.dependencies, ", ")
        push!(lines, rpad(string(e.name), 25) * rpad(string(e.tier), 6) *
                     rpad(time_str, 14) * rpad(string(e.trigger), 14) * deps_str)
    end

    push!(lines, "-" ^ 80)
    stats = compile_stats_summary()
    total_ms = round(stats.total_compile_time_ns / 1_000_000; digits=2)
    push!(lines, "Total: $(length(events)) events, $(total_ms) ms compile time, $(stats.promotions) promotions")
    push!(lines, "=" ^ 80)

    return join(lines, "\n")
end

function clear_timeline!()
    lock(_timeline_lock) do
        empty!(_TIMELINE)
    end
    return nothing
end

end # module

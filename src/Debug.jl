module Debug

using ..DynCompiler
using ..HotSwap
using ..ExprCache

export joovy_hot_reload, joovy_debug_info, is_joovy_frame, clean_frame_name,
       joovy_filter_stacktrace, joovy_breakpoint_map

const _joovy_name_pattern = r"^(.+)_joovy_(\d+)$"

function is_joovy_frame(name::AbstractString)
    return occursin(_joovy_name_pattern, name) ||
           name == "invokelatest" ||
           name == "(::Joovy.DynCompiler.JoovyCallable)"
end

function is_joovy_frame(name::Symbol)
    is_joovy_frame(string(name))
end

function clean_frame_name(name::AbstractString)
    m = match(_joovy_name_pattern, name)
    m !== nothing ? m.captures[1] : name
end

function clean_frame_name(name::Symbol)
    Symbol(clean_frame_name(string(name)))
end

function joovy_hot_reload(file::String;
                          registry::HotSwapRegistry=GLOBAL_REGISTRY,
                          mod::Module=Main)
    file = abspath(file)
    isfile(file) || return (status="error", error="File not found: $file",
                            reloaded=Symbol[], unchanged=Symbol[],
                            fallback_definitions=0)

    new_source = read(file, String)
    reloaded = Symbol[]
    unchanged = Symbol[]
    matched_paths = Set{String}()

    lock(registry.lock) do
        for (name, entry) in registry.entries
            entry_path = entry.file_path
            entry_path === nothing && continue
            if abspath(entry_path) == file
                push!(matched_paths, file)
                old_code = lock(entry.lock) do
                    entry.source
                end
                if new_source != old_code
                    push!(reloaded, name)
                else
                    push!(unchanged, name)
                end
            end
        end
    end

    for name in reloaded
        try
            hotswap_reload!(name; registry=registry, mod=mod)
        catch e
            return (status="error", error="Failed to reload :$name: $(sprint(showerror, e))",
                    reloaded=Symbol[], unchanged=unchanged,
                    fallback_definitions=0)
        end
    end

    fallback_defs = 0
    if isempty(matched_paths)
        fallback_defs = _include_definitions(new_source, file, mod)
    end

    return (status="ok", error=nothing,
            reloaded=reloaded, unchanged=unchanged,
            fallback_definitions=fallback_defs)
end

function _is_definition(expr)
    expr isa Expr || return false
    h = expr.head
    h === :function && return true
    h === :macro && return true
    h === :struct && return true
    h === :abstract && return true
    h === :primitive && return true
    h === :const && return true
    if h === :(=) && length(expr.args) >= 2
        lhs = expr.args[1]
        if lhs isa Expr && (lhs.head === :call || lhs.head === :where)
            return true
        end
    end
    return false
end

function _include_definitions(source::String, file::String, mod::Module)
    source_lines = split(source, '\n')
    keep = fill(false, length(source_lines))
    defs_count = 0
    pos = 1
    while pos <= lastindex(source)
        start_pos = pos
        expr, next_pos = try
            Meta.parse(source, pos; raise=false)
        catch
            break
        end
        pos = next_pos
        expr === nothing && continue
        if expr isa Expr && expr.head === :error
            continue
        end
        if _is_definition(expr)
            start_line = count(==('\n'), SubString(source, 1, max(1, start_pos - 1))) + 1
            end_line = count(==('\n'), SubString(source, 1, max(1, prevind(source, next_pos)))) + 1
            for l in start_line:min(end_line, length(keep))
                keep[l] = true
            end
            defs_count += 1
        end
    end

    if defs_count > 0
        for i in 1:length(source_lines)
            if !keep[i]
                source_lines[i] = ""
            end
        end
        defs_str = join(source_lines, '\n')
        Base.include_string(mod, defs_str, file)
    end

    return defs_count
end

function joovy_debug_info(name::Symbol)
    mapping = source_map_lookup(name)
    mapping === nothing && return nothing

    return (
        original_names=mapping.original_names,
        compiled_names=mapping.compiled_names,
        source_file=mapping.source_file,
        compile_id=mapping.compile_id
    )
end

function joovy_breakpoint_map(file::String, line::Int;
                              registry::HotSwapRegistry=GLOBAL_REGISTRY)
    file = abspath(file)

    lock(registry.lock) do
        for (name, entry) in registry.entries
            entry_path = entry.file_path
            entry_path === nothing && continue
            if abspath(entry_path) == file
                mapping = source_map_lookup(name)
                if mapping !== nothing
                    return (
                        original_name=mapping.original_names[1],
                        compiled_name=mapping.compiled_names[1],
                        compile_id=mapping.compile_id
                    )
                end
            end
        end
        return nothing
    end
end

function joovy_filter_stacktrace(frames::Vector)
    filtered = []
    for frame in frames
        name = string(_frame_name(frame))
        if name == "invokelatest" || contains(name, "JoovyCallable")
            continue
        end
        push!(filtered, _clean_frame(frame, name))
    end
    return filtered
end

function _frame_name(frame)
    if frame isa StackFrame
        return frame.func
    elseif frame isa NamedTuple && haskey(frame, :func)
        return frame.func
    elseif frame isa NamedTuple && haskey(frame, :name)
        return frame.name
    end
    return :unknown
end

function _clean_frame(frame, name::String)
    m = match(_joovy_name_pattern, name)
    m === nothing && return frame
    original = m.captures[1]
    if frame isa StackFrame
        return StackFrame(Symbol(original), frame.file, frame.line,
                          frame.linfo, frame.from_c, frame.inlined, frame.pointer)
    end
    return frame
end

end # module

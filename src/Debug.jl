module Debug

using ..DynCompiler
using ..HotSwap
using ..ExprCache
using ..SourceProvider

export joovy_hot_reload, joovy_debug_info, is_joovy_frame, clean_frame_name,
       joovy_filter_stacktrace, joovy_breakpoint_map

const _joovy_name_pattern = r"^(.+)_joovy_(\d+)$"

# Per-(file, module) map of definition name -> content hash, used by _include_definitions
# to diff a saved file against its previous state so only changed/added definitions get
# re-evaluated (avoiding Julia backedge invalidation of every caller on every save).
const _file_def_hashes = Dict{Tuple{String,Module}, Dict{Symbol,UInt64}}()
const _file_def_hashes_lock = ReentrantLock()

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
                          mod::Module=Main,
                          incremental::Bool=true)
    file = abspath(file)
    if !source_exists(file)
        return (status="error", error="File not found: $file",
                reloaded=Symbol[], unchanged=Symbol[],
                fallback_definitions=0,
                fallback_changed=Symbol[], fallback_added=Symbol[],
                fallback_removed=Symbol[], fallback_unchanged=Symbol[])
    end

    new_source = source_read(file)
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

    if !isempty(matched_paths)
        if incremental
            try
                fr = hotswap_reload_file!(file; registry=registry, mod=mod)
                reloaded = fr.reloaded
                unchanged = fr.unchanged
            catch e
                return (status="error", error="Failed to reload file: $(sprint(showerror, e))",
                        reloaded=Symbol[], unchanged=Symbol[],
                        fallback_definitions=0,
                        fallback_changed=Symbol[], fallback_added=Symbol[],
                        fallback_removed=Symbol[], fallback_unchanged=Symbol[])
            end
        else
            for name in reloaded
                try
                    hotswap_reload!(name; registry=registry, mod=mod)
                catch e
                    return (status="error", error="Failed to reload :$name: $(sprint(showerror, e))",
                            reloaded=Symbol[], unchanged=unchanged,
                            fallback_definitions=0,
                            fallback_changed=Symbol[], fallback_added=Symbol[],
                            fallback_removed=Symbol[], fallback_unchanged=Symbol[])
                end
            end
        end
    end

    fallback_changed = Symbol[]
    fallback_added = Symbol[]
    fallback_removed = Symbol[]
    fallback_unchanged = Symbol[]
    if isempty(matched_paths)
        fr = _include_definitions(new_source, file, mod; incremental=incremental)
        fallback_changed = fr.changed
        fallback_added = fr.added
        fallback_removed = fr.removed
        fallback_unchanged = fr.unchanged
    end

    return (status="ok", error=nothing,
            reloaded=reloaded, unchanged=unchanged,
            fallback_definitions=length(fallback_changed) + length(fallback_added),
            fallback_changed=fallback_changed, fallback_added=fallback_added,
            fallback_removed=fallback_removed, fallback_unchanged=fallback_unchanged)
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

# Extract the name being defined by the call-like LHS of a function/macro/short-form def.
# Handles `foo(x)` and `foo(x) where T`; anything else (e.g. a dotted callee like
# `Base.:+(a,b)`) is intentionally unresolved so the caller falls back to "always re-eval".
function _call_lhs_name(expr)
    expr isa Symbol && return expr
    expr isa Expr || return nothing
    if expr.head === :where
        return _call_lhs_name(expr.args[1])
    end
    if expr.head === :call
        callee = expr.args[1]
        return callee isa Symbol ? callee : nothing
    end
    return nothing
end

# Extract the name from a type-definition head: a bare Symbol, `Name{T}` (:curly), or
# `Name <: Super` (:(<:)), possibly nested (e.g. `Name{T} <: Super{T}`).
function _type_head_name(expr)
    expr isa Symbol && return expr
    expr isa Expr || return nothing
    if expr.head === :curly || expr.head === :(<:)
        return _type_head_name(expr.args[1])
    end
    return nothing
end

# Extract the name from the inner assignment of a `const ... = ...` statement.
function _const_name(expr)
    expr isa Expr && expr.head === :(=) && length(expr.args) >= 1 || return nothing
    lhs = expr.args[1]
    lhs isa Symbol && return lhs
    if lhs isa Expr && lhs.head === :(::) && length(lhs.args) >= 1 && lhs.args[1] isa Symbol
        return lhs.args[1]
    end
    return nothing
end

# Best-effort name extraction for a top-level definition `expr` (already known to satisfy
# `_is_definition`). Returns `nothing` when the name cannot be determined; callers must
# treat that as "always re-evaluate" (safe over-approximation), e.g. for
# `Base.:+(a::Foo, b::Foo) = ...`.
function _definition_name(expr::Expr)
    h = expr.head
    if h === :function || h === :(=) || h === :macro
        length(expr.args) >= 1 || return nothing
        return _call_lhs_name(expr.args[1])
    elseif h === :struct
        length(expr.args) >= 2 || return nothing
        return _type_head_name(expr.args[2])
    elseif h === :abstract || h === :primitive
        length(expr.args) >= 1 || return nothing
        return _type_head_name(expr.args[1])
    elseif h === :const
        length(expr.args) >= 1 || return nothing
        return _const_name(expr.args[1])
    end
    return nothing
end

# Scan `source` for top-level definitions and re-evaluate only the ones that changed since
# the last call for this (file, mod) pair, instead of re-evaluating every definition on
# every save (which triggers Julia backedge invalidation of every caller, even callers of
# definitions that did not change).
#
# `incremental=false` reproduces the historical behavior: every recognized definition is
# kept and re-evaluated on every call. Hashes are still updated in that mode so a later
# switch back to `incremental=true` has a fresh baseline instead of reporting everything as
# newly "added".
function _include_definitions(source::String, file::String, mod::Module;
                              incremental::Bool=true)
    source_lines = split(source, '\n')
    n_lines = length(source_lines)

    defs = NamedTuple{(:name, :start_line, :end_line, :expr),
                       Tuple{Union{Symbol,Nothing}, Int, Int, Any}}[]

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
            push!(defs, (name=_definition_name(expr), start_line=start_line,
                         end_line=min(end_line, n_lines), expr=expr))
        end
    end

    keep = fill(false, n_lines)
    name_lines = Dict{Symbol, Vector{Int}}()
    name_hash = Dict{Symbol, UInt64}()
    has_anon = false

    for d in defs
        if d.name === nothing
            # Unresolvable name: always keep/re-evaluate this def's own lines.
            has_anon = true
            for l in d.start_line:d.end_line
                1 <= l <= n_lines && (keep[l] = true)
            end
            continue
        end
        if haskey(name_hash, d.name)
            name_hash[d.name] = hash(string(d.expr), name_hash[d.name])
            append!(name_lines[d.name], d.start_line:d.end_line)
        else
            name_hash[d.name] = hash(string(d.expr))
            name_lines[d.name] = collect(d.start_line:d.end_line)
        end
    end

    changed = Symbol[]
    added = Symbol[]
    removed = Symbol[]
    unchanged = Symbol[]

    key = (abspath(file), mod)
    lock(_file_def_hashes_lock) do
        stored = get!(() -> Dict{Symbol,UInt64}(), _file_def_hashes, key)
        seen = keys(name_hash)

        for (name, h) in name_hash
            prior = get(stored, name, nothing)
            if incremental
                if prior === nothing
                    push!(added, name)
                    for l in name_lines[name]
                        1 <= l <= n_lines && (keep[l] = true)
                    end
                elseif prior != h
                    push!(changed, name)
                    for l in name_lines[name]
                        1 <= l <= n_lines && (keep[l] = true)
                    end
                else
                    push!(unchanged, name)
                end
            else
                # Non-incremental: reproduce "always re-evaluate everything" but still
                # report an accurate added-vs-changed classification.
                prior === nothing ? push!(added, name) : push!(changed, name)
                for l in name_lines[name]
                    1 <= l <= n_lines && (keep[l] = true)
                end
            end
            stored[name] = h
        end

        for name in collect(keys(stored))
            if !(name in seen)
                push!(removed, name)
                delete!(stored, name)
            end
        end
    end

    if !isempty(changed) || !isempty(added) || has_anon
        for i in 1:n_lines
            if !keep[i]
                source_lines[i] = ""
            end
        end
        defs_str = join(source_lines, '\n')
        Base.include_string(mod, defs_str, file)
    end

    return (changed=changed, added=added, removed=removed, unchanged=unchanged)
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

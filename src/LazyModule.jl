module LazyModules

using ..DynCompiler
using ..CompileTimeline
using ..TieredCompile

export LazyModule, joovy_use, joovy_reload!, joovy_watch_lazy!, joovy_promote_lazy!,
       lazy_status, lazy_compiled, lazy_pending

mutable struct LazyModule
    path::String
    mod::Module
    preamble::Vector{Any}
    definitions::Dict{Symbol, Expr}
    dependencies::Dict{Symbol, Set{Symbol}}
    reverse_deps::Dict{Symbol, Set{Symbol}}
    compiled::Dict{Symbol, TieredCallable}
    source_hashes::Dict{Symbol, UInt64}
    default_tier::Int
    promote_threshold::Int
    lock::ReentrantLock
end

const _LAZY_MODULE_FIELDS = fieldnames(LazyModule)

# ===================================================================
# AST splitting: preamble vs definitions
# ===================================================================

const _PREAMBLE_HEADS = Set{Symbol}([
    :using, :import, :const, :struct, :abstract, :macro,
    :module, :export, :macrocall, :primitive
])

function _split_preamble_defs(ast::Expr)
    preamble = Any[]
    definitions = Dict{Symbol, Expr}()

    stmts = ast.head in (:block, :toplevel) ? ast.args : Any[ast]

    for expr in stmts
        expr isa LineNumberNode && continue

        if _is_function_def(expr)
            name = _extract_def_name(expr)
            if name !== nothing
                if haskey(definitions, name)
                    definitions[name] = Expr(:block, definitions[name], expr)
                else
                    definitions[name] = expr
                end
            else
                push!(preamble, expr)
            end
        elseif expr isa Expr && expr.head in _PREAMBLE_HEADS
            push!(preamble, expr)
        else
            push!(preamble, expr)
        end
    end

    return preamble, definitions
end

function _is_function_def(expr)
    expr isa Expr || return false
    expr.head === :function && return true
    if expr.head === :(=) && length(expr.args) >= 1
        lhs = expr.args[1]
        lhs isa Expr || return false
        lhs.head === :call && return true
        if lhs.head === :where && length(lhs.args) >= 1
            inner = lhs.args[1]
            inner isa Expr && inner.head === :call && return true
        end
    end
    return false
end

function _extract_def_name(expr::Expr)
    (expr.head === :function || expr.head === :(=)) || return nothing
    length(expr.args) >= 1 || return nothing
    lhs = expr.args[1]
    lhs isa Expr || return nothing

    if lhs.head === :call && length(lhs.args) >= 1 && lhs.args[1] isa Symbol
        return lhs.args[1]
    elseif lhs.head === :where && length(lhs.args) >= 1
        inner = lhs.args[1]
        if inner isa Expr && inner.head === :call && length(inner.args) >= 1 && inner.args[1] isa Symbol
            return inner.args[1]
        end
    end
    return nothing
end

# ===================================================================
# Dependency graph
# ===================================================================

function _build_dep_graph(definitions::Dict{Symbol, Expr})
    local_names = Set(keys(definitions))
    deps = Dict{Symbol, Set{Symbol}}(n => Set{Symbol}() for n in local_names)
    reverse_deps = Dict{Symbol, Set{Symbol}}(n => Set{Symbol}() for n in local_names)

    for (name, expr) in definitions
        callees = Set{Symbol}()
        _extract_callees!(expr, callees)
        local_callees = intersect(callees, local_names)
        delete!(local_callees, name)
        deps[name] = local_callees
        for callee in local_callees
            push!(reverse_deps[callee], name)
        end
    end

    return deps, reverse_deps
end

function _extract_callees!(expr::Expr, callees::Set{Symbol})
    if expr.head === :call && length(expr.args) >= 1
        callee = expr.args[1]
        if callee isa Symbol
            push!(callees, callee)
        end
    elseif expr.head === :(.) && length(expr.args) >= 1 && expr.args[1] isa Symbol
        push!(callees, expr.args[1])
    end

    for arg in expr.args
        if arg isa Expr
            _extract_callees!(arg, callees)
        end
    end
end

_extract_callees!(::Any, ::Set{Symbol}) = nothing

# ===================================================================
# Topological sort
# ===================================================================

function _topo_sort(name::Symbol, deps::Dict{Symbol, Set{Symbol}},
                    already_compiled::Set{Symbol})
    visited = Set{Symbol}()
    order = Symbol[]
    _topo_visit!(name, deps, already_compiled, visited, order)
    return order
end

function _topo_visit!(name::Symbol, deps::Dict{Symbol, Set{Symbol}},
                      already_compiled::Set{Symbol}, visited::Set{Symbol},
                      order::Vector{Symbol})
    name in already_compiled && return
    name in visited && return
    push!(visited, name)

    for dep in get(deps, name, Set{Symbol}())
        _topo_visit!(dep, deps, already_compiled, visited, order)
    end

    push!(order, name)
end

# ===================================================================
# Lazy compilation
# ===================================================================

const _show_stats = Ref(get(ENV, "JULIA_IDE_JOOVY_STATS", "") == "1")

function _compile_subtree!(lm::LazyModule, name::Symbol)
    haskey(lm.compiled, name) && return lm.compiled[name]
    haskey(lm.definitions, name) || error("No definition for :$name in $(lm.path)")

    compiled_set = Set(keys(lm.compiled))
    order = _topo_sort(name, lm.dependencies, compiled_set)

    for sym in order
        if !haskey(lm.compiled, sym) && haskey(lm.definitions, sym)
            expr = lm.definitions[sym]
            code = string(expr)
            dep_list = collect(get(lm.dependencies, sym, Set{Symbol}()))

            t0 = time_ns()
            fn = TieredCompile.compile_in_module!(lm.mod, expr, sym, lm.default_tier)
            elapsed = time_ns() - t0

            tc = make_tiered_callable(fn, lm.default_tier, code, sym, lm.mod;
                                      promote_threshold=lm.promote_threshold)

            record_compile!(CompileEvent(
                sym, lm.default_tier, UInt64(elapsed), :first_call,
                dep_list, UInt64(time_ns()), :lazy_module
            ))

            lm.compiled[sym] = tc

            if _show_stats[]
                time_str = elapsed < 1_000_000 ? "$(round(elapsed / 1_000; digits=1))μs" : "$(round(elapsed / 1_000_000; digits=2))ms"
                deps_str = isempty(dep_list) ? "" : " deps=[$(join(dep_list, ","))]"
                compiled_n = length(lm.compiled)
                total_n = length(lm.definitions)
                @info "joovy compile: $(sym) tier=$(lm.default_tier) $(time_str) [$(compiled_n)/$(total_n)]$(deps_str)"
            end
        end
    end

    return lm.compiled[name]
end

# ===================================================================
# Invalidation
# ===================================================================

function _invalidate_dependents!(lm::LazyModule, name::Symbol)
    queue = Symbol[name]
    invalidated = Set{Symbol}()
    while !isempty(queue)
        current = popfirst!(queue)
        for dependent in get(lm.reverse_deps, current, Set{Symbol}())
            if !(dependent in invalidated) && haskey(lm.compiled, dependent)
                push!(invalidated, dependent)
                delete!(lm.compiled, dependent)
                push!(queue, dependent)
            end
        end
    end
    return invalidated
end

# ===================================================================
# Property access for lazy compilation
# ===================================================================

function Base.getproperty(lm::LazyModule, name::Symbol)
    name in _LAZY_MODULE_FIELDS && return getfield(lm, name)
    compiled = getfield(lm, :compiled)
    existing = get(compiled, name, nothing)
    existing !== nothing && return existing
    lock(getfield(lm, :lock)) do
        _compile_subtree!(lm, name)
    end
end

function Base.propertynames(lm::LazyModule)
    own = collect(_LAZY_MODULE_FIELDS)
    defs = lock(getfield(lm, :lock)) do
        collect(keys(getfield(lm, :definitions)))
    end
    return tuple(own..., defs...)
end

# ===================================================================
# Public API
# ===================================================================

function joovy_use(path::String; mod::Module=Main, tier::Int=1,
                   promote_threshold::Int=10)
    isfile(path) || error("File not found: $path")
    code = read(path, String)
    ast = Meta.parse("begin\n$code\nend")

    preamble, definitions = _split_preamble_defs(ast)

    for p in preamble
        Core.eval(mod, p)
    end

    deps, reverse_deps = _build_dep_graph(definitions)

    source_hashes = Dict{Symbol, UInt64}()
    for (name, expr) in definitions
        source_hashes[name] = hash(string(expr))
    end

    return LazyModule(
        abspath(path), mod, preamble, definitions, deps, reverse_deps,
        Dict{Symbol, TieredCallable}(), source_hashes,
        tier, promote_threshold, ReentrantLock()
    )
end

function joovy_reload!(lm::LazyModule)
    isfile(lm.path) || error("File not found: $(lm.path)")
    code = read(lm.path, String)
    ast = Meta.parse("begin\n$code\nend")

    new_preamble, new_definitions = _split_preamble_defs(ast)

    lock(lm.lock) do
        changed = Symbol[]
        removed = Symbol[]
        added = Symbol[]

        for (name, expr) in new_definitions
            new_hash = hash(string(expr))
            if !haskey(lm.source_hashes, name)
                push!(added, name)
            elseif lm.source_hashes[name] != new_hash
                push!(changed, name)
            end
            lm.source_hashes[name] = new_hash
        end

        for name in keys(lm.definitions)
            if !haskey(new_definitions, name)
                push!(removed, name)
                delete!(lm.source_hashes, name)
            end
        end

        lm.definitions = new_definitions
        lm.dependencies, lm.reverse_deps = _build_dep_graph(new_definitions)

        lm.preamble = new_preamble
        for p in new_preamble
            try
                Core.eval(lm.mod, p)
            catch
            end
        end

        invalidated = Set{Symbol}()
        for name in vcat(changed, removed)
            delete!(lm.compiled, name)
            union!(invalidated, _invalidate_dependents!(lm, name))
        end

        if _show_stats[] && (!isempty(changed) || !isempty(removed) || !isempty(added))
            @info "joovy reload: $(basename(lm.path)) changed=$(changed) added=$(added) removed=$(removed) invalidated=$(collect(invalidated))"
        end

        return (changed=changed, removed=removed, added=added)
    end
end

function joovy_watch_lazy!(lm::LazyModule; interval::Float64=0.5)
    @async begin
        last_mtime = mtime(lm.path)
        while true
            sleep(interval)
            isfile(lm.path) || break
            current_mtime = mtime(lm.path)
            if current_mtime > last_mtime
                last_mtime = current_mtime
                try
                    joovy_reload!(lm)
                catch e
                    @warn "LazyModule reload failed" exception=(e, catch_backtrace())
                end
            end
        end
    end
    return nothing
end

function joovy_promote_lazy!(lm::LazyModule, name::Symbol; tier::Int=2)
    lock(lm.lock) do
        if !haskey(lm.compiled, name)
            _compile_subtree!(lm, name)
        end
        if haskey(lm.compiled, name)
            tc = lm.compiled[name]
            tier <= tc.tier && return nothing
            expr = lm.definitions[name]
            fn = TieredCompile.compile_in_module!(lm.mod, expr, name, tier)
            lock(tc.lock) do
                tc.fn = fn
                tc.tier = tier
                tc.call_count = 0
                tc.promoting = false
            end
        end
    end
    return nothing
end

function lazy_status(lm::LazyModule)
    lock(lm.lock) do
        return (
            path=lm.path,
            total_definitions=length(lm.definitions),
            compiled_count=length(lm.compiled),
            pending=collect(setdiff(keys(lm.definitions), keys(lm.compiled))),
            tiers=Dict(name => tc.tier for (name, tc) in lm.compiled),
            call_counts=Dict(name => tc.call_count for (name, tc) in lm.compiled)
        )
    end
end

function lazy_compiled(lm::LazyModule)
    lock(lm.lock) do
        collect(keys(lm.compiled))
    end
end

function lazy_pending(lm::LazyModule)
    lock(lm.lock) do
        collect(setdiff(keys(lm.definitions), keys(lm.compiled)))
    end
end

end # module

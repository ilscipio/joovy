# src/SourcePos.jl
#
# Internal helper module (zero deps): turns a `Meta.parseall` result back into
# (node, line) pairs so callers can report accurate 1-based source positions
# for arbitrary AST nodes without re-implementing LineNumberNode bookkeeping
# at every call site.
#
# Not a general "expression location" index -- just a line CURSOR that updates
# at each `LineNumberNode` encountered during a preorder walk and carries the
# most-recently-seen line into every node visited after it (including nested
# scopes, e.g. a function body's own internal LineNumberNodes). Statement-level
# granularity: every node produced by a given source statement shares that
# statement's line, which is all CompileWatch's static rules need.
#
# Deliberately separate from Debug.jl's inline byte-offset logic (used for
# incremental-reload diffing) -- this module only ever deals in LINE NUMBERS
# via the standard `Meta.parseall(...; filename=path)` idiom (see
# Instrument.jl:181, the repo's only other filename-preserving parse site).

module SourcePos

export parse_with_lines, each_positioned

"""
    parse_with_lines(source::AbstractString, path::AbstractString) -> Expr

Parse `source` with `Meta.parseall(source; filename=path)`, preserving the
`LineNumberNode`s a caller needs to resolve positions with [`each_positioned`](@ref).
"""
function parse_with_lines(source::AbstractString, path::AbstractString)
    return Meta.parseall(String(source); filename=String(path))
end

"""
    each_positioned(f, ast; startline::Int=1)

Walk `ast` (an `Expr` tree, typically from [`parse_with_lines`](@ref)) in
preorder. A line cursor starts at `startline` and updates every time a
`LineNumberNode` is visited; recursion carries the CURRENT cursor value into
nested `Expr` bodies, so a statement inside a function/block/etc. reported
after its own local `LineNumberNode` gets that statement's line, not the
enclosing definition's.

`f(node, line)` is called for every node in the tree EXCEPT `LineNumberNode`
itself (which only updates the cursor) -- this includes `Expr` nodes, bare
`Symbol`s, and literals, so rules that need to inspect leaf reads (e.g. a
free-variable scan) don't need a second traversal helper.
"""
function each_positioned(f, ast; startline::Int=1)
    cursor = Ref(startline)
    _walk!(f, ast, cursor)
    return nothing
end

function _walk!(@nospecialize(f), node::LineNumberNode, cursor::Ref{Int})
    cursor[] = node.line
    return nothing
end

function _walk!(@nospecialize(f), node::Expr, cursor::Ref{Int})
    f(node, cursor[])
    for arg in node.args
        _walk!(f, arg, cursor)
    end
    return nothing
end

function _walk!(@nospecialize(f), node, cursor::Ref{Int})
    f(node, cursor[])
    return nothing
end

end # module

module WorldAgeBridge

export joovy_eval, joovy_function, invoke_joovy

function joovy_eval(mod::Module, expr::Expr)
    Core.eval(mod, expr)
end

function joovy_eval(expr::Expr)
    joovy_eval(Main, expr)
end

function joovy_function(mod::Module, expr::Expr)
    Core.eval(mod, expr)
    if expr.head === :function || expr.head === :(=)
        fname = _extract_name(expr)
        if fname !== nothing
            return (args...; kwargs...) -> Base.invokelatest(getfield(mod, fname), args...; kwargs...)
        end
    end
    return nothing
end

function joovy_function(expr::Expr)
    joovy_function(Main, expr)
end

function _extract_name(expr::Expr)
    if expr.head === :function
        sig = expr.args[1]
        if sig isa Expr && sig.head === :call
            return sig.args[1] isa Symbol ? sig.args[1] : nothing
        end
    elseif expr.head === :(=)
        lhs = expr.args[1]
        if lhs isa Expr && lhs.head === :call
            return lhs.args[1] isa Symbol ? lhs.args[1] : nothing
        end
    end
    return nothing
end

function invoke_joovy(mod::Module, name::Symbol, args...; kwargs...)
    f = getfield(mod, name)
    Base.invokelatest(f, args...; kwargs...)
end

end # module

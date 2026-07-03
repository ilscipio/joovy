module JoovyObjects

export JoovyObject, joovy_override!, joovy_remove_override!, joovy_call,
       joovy_has_override, joovy_list_overrides, joovy_reset!

mutable struct JoovyObject{T}
    value::T
    overrides::Dict{Symbol, Any}
    lock::ReentrantLock

    JoovyObject(val::T) where T = new{T}(val, Dict{Symbol, Any}(), ReentrantLock())
end

function Base.getproperty(obj::JoovyObject, name::Symbol)
    if name in (:value, :overrides, :lock)
        return getfield(obj, name)
    end

    overrides = getfield(obj, :overrides)
    lk = getfield(obj, :lock)
    fn = lock(lk) do
        get(overrides, name, nothing)
    end

    if fn !== nothing
        return fn
    end

    val = getfield(obj, :value)
    return getproperty(val, name)
end

function joovy_override!(obj::JoovyObject, method::Symbol, impl)
    lock(obj.lock) do
        obj.overrides[method] = impl
    end
    return obj
end

function joovy_remove_override!(obj::JoovyObject, method::Symbol)
    lock(obj.lock) do
        delete!(obj.overrides, method)
    end
    return obj
end

function joovy_call(obj::JoovyObject, method::Symbol, args...; kwargs...)
    overrides = getfield(obj, :overrides)
    lk = getfield(obj, :lock)

    fn = lock(lk) do
        get(overrides, method, nothing)
    end

    if fn !== nothing
        return fn(getfield(obj, :value), args...; kwargs...)
    end

    val = getfield(obj, :value)
    f = getfield(parentmodule(typeof(val)), method)
    return f(val, args...; kwargs...)
end

function joovy_has_override(obj::JoovyObject, method::Symbol)
    lock(obj.lock) do
        haskey(obj.overrides, method)
    end
end

function joovy_list_overrides(obj::JoovyObject)
    lock(obj.lock) do
        collect(keys(obj.overrides))
    end
end

function joovy_reset!(obj::JoovyObject)
    lock(obj.lock) do
        empty!(obj.overrides)
    end
    return obj
end

function Base.show(io::IO, obj::JoovyObject{T}) where T
    n = lock(obj.lock) do
        length(obj.overrides)
    end
    print(io, "JoovyObject{$T}($(obj.value), $n overrides)")
end

end # module

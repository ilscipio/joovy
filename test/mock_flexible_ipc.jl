module FlexibleIPC
const _handlers = Dict{String,Function}()
const _notifications = Vector{Tuple{String,Dict}}()
register_handler(route::String, fn::Function) = (_handlers[route] = fn; nothing)
send_notification(method::String, params::Dict) = (push!(_notifications, (method, params)); nothing)
reset_notifications!() = empty!(_notifications)
call(route::String, params::Dict) = _handlers["joovy/" * route](params)
end

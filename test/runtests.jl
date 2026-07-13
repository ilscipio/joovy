using Test
using Joovy

println("\n" * "╔" * "═"^108 * "╗")
println("║" * lpad("Joovy.jl Test Suite — Compiled Julia vs Dynamic Joovy Compilation", 86) * " "^22 * "║")
println("╚" * "═"^108 * "╝")

@testset "Joovy.jl" begin
    include("test_exprcache.jl")
    include("test_compiler.jl")
    include("test_hotswap.jl")
    include("test_scriptengine.jl")
    include("test_autotune.jl")
    include("test_debug.jl")
    include("test_static_compile.jl")
    include("test_compile_timeline.jl")
    include("test_tiered_compile.jl")
    include("test_lazy_module.jl")
    include("test_warmup.jl")
    include("test_comparison.jl")
end

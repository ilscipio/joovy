# Joovy.jl

Dynamic compilation, hot-swapping, and runtime code generation for Julia.

Joovy brings Groovy-style dynamic capabilities to Julia. It compiles functions from strings or expressions at runtime, caches them by content, and lets you swap implementations without restarting your process.

The name is a portmanteau of **J**ulia + Gr**oovy**.

## Features

- **Dynamic compilation** from strings, expressions, or files with content-addressed caching
- **Hot-swapping** of function implementations at runtime (inline or file-based)
- **Per-object method overrides** similar to Groovy's ExpandoMetaClass
- **Script engine** with variable bindings and error capture
- **Auto-tuning** that generates parametric code variants, benchmarks them, and picks the fastest
- **Integration API** for embedding Joovy into IDEs and tools

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/nicholasgasior/joovy.git")
```

Or in the Julia REPL package manager:

```
] add https://github.com/nicholasgasior/joovy.git
```

## Quick start

### Compile a function from a string

```julia
using Joovy

add = joovy_compile("add(x, y) = x + y")
add(3, 4)  # 7
```

The compiled function is cached. Calling `joovy_compile` again with the same code returns the cached version instantly.

### Hot-swap a function at runtime

```julia
hotswap_register!(:greet, "greet(name) = \"Hello, \$name\"")
hotswap_call(:greet, "world")  # "Hello, world"

hotswap_swap!(:greet, "greet(name) = \"Hey \$name!\"")
hotswap_call(:greet, "world")  # "Hey world!"
```

### Hot-swap from a file

```julia
hotswap_load_file!(:process, "processor.jl")
hotswap_call(:process, data)

# Edit processor.jl, then:
hotswap_reload!(:process)
hotswap_call(:process, data)  # uses the new version
```

### Per-object method overrides

```julia
struct Sensor
    id::String
    value::Float64
end

s1 = JoovyObject(Sensor("temp-1", 22.5))
s2 = JoovyObject(Sensor("temp-2", 22.5))

joovy_override!(s1, :calibrate, s -> s.value * 1.0)
joovy_override!(s2, :calibrate, s -> s.value * 1.05 - 0.3)

joovy_call(s1, :calibrate)  # 22.5
joovy_call(s2, :calibrate)  # 23.325
```

Two objects of the same type, different behavior.

### Run code with bindings

```julia
engine = JoovyEngine(sandbox=false)

result = joovy_run(engine, "sum(data) / length(data)";
    bindings=Dict{Symbol,Any}(:data => [1.0, 2.0, 3.0]))

result.value    # 2.0
result.success  # true
```

### Auto-tune a kernel

```julia
base_code = "kernel(x) = REDUCE(xi -> xi^POWER, +, x)"
params = Dict{Symbol,Any}(:POWER => [2, 3, 4], :REDUCE => [:mapreduce, :mapfoldl])

result = joovy_autotune(base_code, params, rand(10_000))

result.best_variant.params   # the fastest combination
result.speedup_vs_first      # speedup over the slowest variant
```

Joovy generates all combinations, benchmarks each one, and returns the winner. Wisdom (cached results) can be saved to disk and reloaded across sessions.

## Embedding Joovy in tools

The `JoovySession` API is designed for IDE plugins and external tools that manage a Julia process. It wraps compilation, hot-swapping, and status queries behind a single session object.

```julia
using Joovy

session = JoovySession()

# Compile and track
fn = session_compile(session, "f(x) = x^2 + 1"; name=:f)
fn(5)  # 26

# Eval arbitrary code
result = session_eval(session, "1 + 2 + 3")
result.value  # 6

# Inspect session state
status = session_status(session)
status.cache_hits
status.cache_entries
status.registered_functions
status.compile_log
```

This is the primary interface for integrating Joovy with the [Flexible Julia](https://plugins.jetbrains.com/plugin/25635-flexible-julia) IDE plugin. The IDE sends code strings over IPC, Joovy compiles and caches them, and the session tracks everything for status reporting back to the IDE.

## Architecture

Joovy is organized into independent modules with a clear dependency graph:

```
ExprCache          WorldAgeBridge
    |                    |
    +--- DynCompiler ----+
    |        |           |
    |    ScriptEngine    |
    |                    |
    +--- HotSwap         |
    |                    |
    +--- AutoTune        |
    |                    |
    +--- Integration ----+
              |
         JoovySession

JoovyObjects (standalone)
```

**ExprCache** handles content-addressed caching using SHA1 hashes. Expressions are normalized (line numbers stripped) so that formatting differences do not cause cache misses.

**WorldAgeBridge** wraps `Base.invokelatest` to handle Julia's world-age restriction when calling functions defined via `eval`.

**DynCompiler** is the core compilation pipeline. It parses code, renames functions to avoid collisions, evaluates them, wraps results in `JoovyCallable` structs, and caches everything.

**HotSwap** manages named function registrations that can be swapped to new implementations at runtime, with version tracking and full history.

**JoovyObjects** provides per-instance method overrides with thread-safe locking.

**ScriptEngine** offers a managed execution environment with variable bindings and file watching.

**AutoTune** generates parametric code variants from a template, benchmarks them, and selects the fastest. Supports a wisdom cache for persisting results.

**Integration** provides the `JoovySession` facade for external tools and IDE plugins.

## Performance

Joovy compiles through the same pipeline as native Julia. The overhead comes from two sources:

1. **Compilation**: parsing the string and evaluating via `Core.eval`. This cost is paid once and amortized by the cache.
2. **Invocation**: each call goes through `Base.invokelatest`, which adds roughly 50-200ns. This is negligible for any non-trivial function.

Cache hits skip compilation entirely and return in nanoseconds.

## Running tests

```julia
using Pkg
Pkg.test("Joovy")
```

## Running the demo

```julia
include("examples/demo.jl")
```

The demo compares native Julia and Joovy side by side across compilation, hot-swapping, code generation, auto-tuning, script execution, and per-object overrides.

## Requirements

- Julia 1.9 or later
- Standard library only (SHA, Statistics, Serialization)

## License

MIT. See [LICENSE](LICENSE).

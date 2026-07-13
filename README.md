# Joovy.jl

[![Tests](https://github.com/ilscipio/joovy/actions/workflows/test.yml/badge.svg)](https://github.com/ilscipio/joovy/actions/workflows/test.yml)

Groovy for Julia. Tiered compilation, lazy modules, and hot-swapping at runtime.

The name is a portmanteau of **J**ulia + Gr**oovy**. Like Groovy gives Java a dynamic layer without leaving the JVM, Joovy gives Julia a dynamic layer without leaving the Julia runtime.

## What this is

Joovy is a dynamic compilation engine that sits between you and Julia's native compiler. It compiles your code through the same pipeline Julia uses, but controls when and how aggressively things get optimized. Functions start fast at a low optimization tier and get promoted to native speed in the background once they are hot.

## How Joovy differs from Revise

[Revise.jl](https://github.com/timholy/Revise.jl) is an excellent tool for automatic code reloading during development. Joovy solves a different problem: it controls *how* code is compiled — starting at a low optimization tier for fast first response, then promoting hot paths to native speed in the background. They are complementary.

## How it works

**Three tiers.** Tier 0 is interpreted (2ms compile, slow runtime). Tier 1 uses reduced optimization with @nospecialize (5-9ms compile, moderate runtime). Tier 2 is full native Julia (18ms compile, full speed). Functions start at tier 1 and promote automatically after a configurable number of calls.

**Lazy modules.** When you load a file with `joovy_use`, we parse it, execute the preamble (imports, structs, consts), and build a dependency graph. Nothing else compiles until you call it. When you call a function, we compile it and its dependencies in topological order. Everything else stays untouched.

**Package tiering.** External packages can be set to a lower tier so their JIT compilation is faster during development. When you are ready to benchmark, promote them back to native.

**Hot-swapping.** Register a function by name, swap its implementation at runtime. Version history is tracked. File-based reload with dependency-aware invalidation.

## Quick start

```julia
using Joovy

# Tiered compilation. Fast first compile, promotes when hot.
fn = joovy_compile_tiered("f(x) = x^2 + sin(x)"; tier=1)
fn(3.0)

# Lazy module. Only compiles what you call.
lm = joovy_use("mylib.jl"; tier=1)
lm.some_function(42)

# See what happened.
println(compile_report())

# Hot-swap a function at runtime.
hotswap_register!(:greet, "greet(name) = \"Hello, \$name\"")
hotswap_call(:greet, "world")
hotswap_swap!(:greet, "greet(name) = \"Hey \$name!\"")
hotswap_call(:greet, "world")
```

## IDE integration

Joovy is the backend for the [Flexible Julia](https://plugins.jetbrains.com/plugin/29356-flexible-julia/) IDE plugin. The plugin communicates over IPC (JSON-RPC over TCP) and handles tiered compilation, lazy loading, dev mode, and hot-reload transparently. You write normal Julia. The IDE handles the rest.

## Background warmup

`joovy_warm` precompiles a list of packages one at a time in a background process, so the depot cache is warm before you need it. `warmup_generate` turns a `--trace-compile` log into a standalone `JoovyWarmup` package covering your project's actual call patterns, and `warmup_build` precompiles that package against your project's exact dependency resolution. The IDE runs all three automatically; you normally never call them yourself.

```julia
using Joovy
joovy_warm(["JSON", "HTTP"]; project="/path/to/my_project")

pkg_dir = warmup_generate("/path/to/my_project", "trace_output_dir")
warmup_build("/path/to/my_project", pkg_dir)
```

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/ilscipio/joovy.git")
```

## Requirements

- Julia 1.9 or later
- Standard library only (Serialization, Pkg, SHA)

## Benchmark

Run the benchmark to see how Joovy affects compile and execution times in your environment:

```julia
include("examples/joovy_benchmark.jl")
```

It runs a set of functions twice (first call = compile cost, second call = runtime cost) and prints a comparison table. Run once with Joovy enabled, restart the REPL with Joovy disabled, and compare the first-call totals.

## Running tests

```julia
using Pkg
Pkg.test("Joovy")
```

## Contributing

Bugfixes and improvements are welcome. Open a pull request against main. Keep changes focused. One fix per PR. Include a test if the fix is non-trivial.

## License

Apache 2.0. See [LICENSE](LICENSE).

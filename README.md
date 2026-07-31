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

## Incremental reload

When the IDE saves a file, `joovy_hot_reload` (and the `joovy/reload` IPC route) hash
each definition and re-evaluate only the ones that changed, instead of the whole file.
This also fixes hot-swap entries: each one now maps to its own compiled function, not
whichever function happened to compile first. Pass `incremental=false` to fall back to
the old re-evaluate-everything behavior. Measured on a 50-definition file with a
1-definition edit: 1 re-evaluation instead of 50, and the reload itself runs 5.5x faster.

## Speculative compilation

`SpecQueue` compiles likely-next lazy-module functions in the background, one function
per quantum, so the REPL stays responsive while it works. It is off by default. Turn it
on with `joovy_speculate!(true)`, the `speculate = true` preference key, or by letting
the IDE send the `joovy/promote` intent route, which force-enables it. Measured on a
40-definition module, speculation cuts the first-call burst from 518ms to 62ms (8.4x).
Native codegen per call still happens on demand, so a single first call only improves
about 1.6x; the win is the burst across many first calls.

## Configuration

You can set tiers in a `LocalPreferences.toml` file next to your `Project.toml`, instead of calling the API by hand. Joovy reads its `[Joovy]` section automatically when you run `using Joovy` — no IDE needed.

```toml
[Joovy]
default = "tier_1"            # default tier for every package you load
Makie = "tier_0"              # load this package at tier 0 instead
"MyModule.hot_fn" = "tier_2"  # one function at tier 2 (best-effort)
speculate = true              # enable speculative background compilation (default false)
```

Per-package lines override `default`; omit `default` and only the packages you list are tiered. Tier values can be `"tier_0"`/`"tier_1"`/`"tier_2"` or `0`/`1`/`2`, and edits apply on your next REPL start. Per-function keys only affect code Joovy compiles (your own functions), not functions already built into an external package. The `speculate` key is a bool, default false; it turns on background speculative compilation (see below) at `using Joovy` time, same as calling `joovy_speculate!(true)`.

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

`joovy_warm` precompiles a list of packages one at a time in a background process, so the depot cache is warm before you need it. `warmup_generate` turns a `--trace-compile` log into a standalone `JoovyWarmup` package covering your project's actual call patterns, and `warmup_build` precompiles that package against your project's exact dependency resolution. The IDE runs all three automatically; you normally never call them yourself. For long-lived projects, `warmup_compact!` merges accumulated trace files into one deduped file so trace-dir growth stays bounded, and `warmup_should_rebuild` gives the IDE a cheap advisory signal for when a rebuild is due.

Julia 1.12 has a community-documented startup regression versus 1.10 on large package sets (~50% slower across 1000 packages, per reports on the JuliaLang discourse). Joovy's cold-load tiering and background warmup claw back that regression and then some: 3x faster cold time-to-first-plot on Plots, and 85% faster time-to-first-execution via trace-driven warmup, as reported anecdotally on 1.12.3. Our own reproducible measurement, using the `bench/run_benchmarks.jl` harness against a DataFrames fixture, shows cold time-to-first-execution dropping from 879ms to 24ms warm (97% faster). Run the harness yourself to measure your project.

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
- Standard library only (Serialization, Pkg, SHA, TOML)

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

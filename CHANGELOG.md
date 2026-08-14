# Joovy Changelog

All notable changes to Joovy are documented here. This project adheres to
[Semantic Versioning](https://semver.org).

## [0.4.1] - 2026-08-14

### Added

- Two static CompileWatch rules from the classic Julia vectorization study:
  `long-broadcast-fusion-chain` (more than 8 fused dot operations in one
  statement build a deeply nested `Broadcasted` type whose inference cost
  grows with depth) and `int-init-float-accumulator` (an integer-literal
  init later promoted to float widens inference and boxes the accumulator).
- Dynamic rule `allocation-heavy-method`: `Instrument`'s `:full` mode now
  records a per-call allocated-bytes delta (`Instrument.alloc_snapshot()`),
  and CompileWatch flags functions above `alloc_bytes_per_call_over`
  (default 1000000 bytes/call). Suggestion text covers non-fused vectorized
  chains and type-unstable accumulators. Overhead on instrumented calls:
  ~0.6% measured.
- Deterministic allocation benchmark: the study's vectorized-chain vs loop
  fixture, gated at >= 10x allocation reduction (measured 12.02x), plus a
  gate that the chain fixture is flagged by `long-broadcast-fusion-chain`.
- New config thresholds `broadcast_fusion_chain_over` (default 8) and
  `alloc_bytes_per_call_over` (default 1000000).
- As-you-type diagnostics: `joovy/source_push` re-scans the pushed buffer
  while a watch session runs. The IDE debounces and pushes on each edit.
  Marks update without a save and without a manual re-scan.

### Changed

- The compile-watch overhead gate now measures the in-process per-call cost
  of the `:full` record path against an identical plain call (measured
  ~90 ns/call, gated at 2000 ns). The old child-process wall-clock
  comparison swung -16.8%..+11.5% between identical runs and is kept as a
  reporting-only metric.

### Fixed

- The new allocation-recording overload is `@noinline`: inlining its
  `GC_Diff` arithmetic into every instrumented definition made each
  hot-reload re-evaluation re-infer it, slowing incremental reload ~4x.
  Caught by the reload bench gate before release.

## [0.4.0] - 2026-08-14

### Added

- `SourceProvider`: single choke point for user-source reads. The IDE pushes
  editor buffers over IPC (`joovy/source_push`, `joovy/source_invalidate`) and
  `joovy/reload` / `joovy/use` accept inline `content` and `version` params, so
  a cached reload performs zero disk reads and always sees unsaved edits.
- `CompileWatch`: a compile-time watchdog with 7 static rules -
  `closure-arg-respecialization`, `vararg-unbounded-splat`,
  `large-tuple-signature`, `untyped-global-in-fn`, `keyword-heavy-signature`,
  `val-type-proliferation`, and `deep-nested-parametric-signature` - plus
  Julia 1.12 dynamic inference metrics captured live. New IPC routes
  `joovy/diag_start`, `joovy/diag_stop`, `joovy/diag_report`, and a streamed
  `joovy/diagnostics` event. New `compile_watch` preference key.
- New `bench/bench_source_cache.jl` and `bench/bench_compile_watch.jl`, wired
  into `bench/run_benchmarks.jl` with pass/fail gates. Measured: source-cache
  reload min 1.65x faster / 25 disk reads eliminated; compile-watch overhead
  -3.2%; value fixture 5.39x compile-time reduction; incremental reload 6.96x
  faster than a full reload.

### Known limits

- On Julia 1.12, the dynamic capture hook stops observing modules that were
  tiered via compiler options.
- An empty-string `content` param is treated as absent.
- An experimental typed-IR interpreter lives on branch `typed-interp`.
  Excluded from this release: the first-call latency gate failed. Steady-state
  runs recorded 1.4-2.8x wins.

## [0.3.0] - 2026-07-31

### Added

- Incremental reload: `joovy_hot_reload` and the `joovy/reload` IPC route now diff
  definitions per save and re-evaluate only changed ones (`incremental` parameter,
  default true; new `hotswap_reload_file!`). Measured on a 50-definition file with a
  1-definition edit: 1 re-evaluation instead of 50, reload wall time 5.5x faster.
- Speculative background compilation: new `SpecQueue` module compiles likely-next
  lazy-module functions in the background (one function per quantum, REPL stays
  responsive). Opt-in via `joovy_speculate!(true)`, the `[Joovy]` preference key
  `speculate = true`, or automatically on the new `joovy/promote` IPC intent route.
  Measured on a 40-definition module: first-call burst 518ms -> 62ms (8.4x); REPL max
  eval delay unchanged (~6.5ms both ways). Note honestly: per-call native codegen
  remains demand-driven, so a single first call improves ~1.6x.
- Warmup maintenance: `warmup_compact!` merges accumulated trace files into one
  deduped `trace-compacted.jl`; `warmup_should_rebuild` gives the IDE an advisory
  rebuild signal (manifest hash + trace byte growth); `warm_daemon_loop` gains a
  `COMPACT` command.
- Benchmark harness under `bench/` (`run_benchmarks.jl` + warmup/reload/speculative
  benches) with a `__JOOVY_BENCH__` marker contract. Baseline measurement of the
  existing cross-session warmup pipeline: cold TTFX 879ms -> 24ms warm (97%) on a
  DataFrames fixture.
- First IPC test suite (`test/test_ipc_bridge.jl` + mock FlexibleIPC).
- End-to-end verification script for [Joovy] preferences (`examples/verify_preferences.jl`).

### Changed

- `joovy/ready` reports the real package version via `Base.pkgversion` instead of a
  hard-coded string.
- All `joovy/*` IPC handlers validate parameters and return a `{"status": "error"}`
  object instead of throwing on null or wrong-typed input.
- README LocalPreferences section tightened.

### Fixed

- With several hot-swap entries registered against one file, a reload recompiled the
  whole file once per entry, and every entry silently received the file's FIRST
  function; a file now compiles once and each entry maps to its own function.
- `Base64` added to test extras so `test_config.jl` loads on Julia 1.9.

## [0.2.0] - 2026-07-21

### Added

- Declarative tier configuration via `LocalPreferences.toml`. A `[Joovy]` section lets you
  set a `default` tier, assign tiers to individual packages/modules, and (best-effort)
  to individual functions Joovy compiles. Applied automatically on `using Joovy` — no IDE
  required. Reads are runtime, so edits take effect on the next REPL start (or
  `joovy_apply_preferences!()`) with no Joovy recompilation.
- `joovy_apply_preferences!` and `joovy_config_status` API.
- IPC route `joovy/apply_preferences` so the IDE can re-apply the config live.

### Changed

- The package-load hook now honours per-package config tiers, and supports a selective
  mode (only configured packages are tiered when no `default` is set).
- Added `TOML` (standard library) as a dependency for reading `LocalPreferences.toml`.

### Notes

- First tagged release. Establishes version/tagging discipline for the repo.

## [0.1.0]

- Initial release: tiered compilation, lazy modules, hot-swapping, package tiering,
  transparent execution, background warmup, and the Flexible Julia IDE IPC bridge.

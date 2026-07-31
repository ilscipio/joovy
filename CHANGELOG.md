# Joovy Changelog

All notable changes to Joovy are documented here. This project adheres to
[Semantic Versioning](https://semver.org).

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

# Joovy Changelog

All notable changes to Joovy are documented here. This project adheres to
[Semantic Versioning](https://semver.org).

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

# Contributing to RamLume

Thanks for your interest in RamLume! Contributions of all kinds are welcome: bug reports,
measurements from Macs we haven't tested, documentation fixes, and code.

## Principles

RamLume's value comes from being trustworthy. Every change should keep these true:

1. **Never fabricate a value.** If a reading is unavailable, show that it's unavailable. No
   placeholder numbers, no interpolation across gaps, no "typical" values.
2. **Label estimates.** Anything that isn't reported directly by macOS is marked as derived,
   estimated, or heuristic, and its formula is documented in
   [docs/memory-metrics.md](docs/memory-metrics.md).
3. **Don't alarm people.** High memory usage, compression, and allocated swap aren't problems on
   their own. Wording is calm, specific, and cautious about causes RamLume can't observe.
4. **Stay light.** No polling loops besides the coordinator's, no work while nothing is visible
   that doesn't need to happen, and no third-party dependencies.
5. **Stay private and unprivileged.** No networking, analytics, or elevated privileges.
6. **No "RAM cleaner" features** and no process killing.

## Getting started

```bash
git clone https://github.com/13nik09/RamLume.git
cd RamLume
open RamLume.xcodeproj
```

Requirements: macOS 14+, Xcode 26+. The project uses Swift 6 language mode with complete
concurrency checking; please keep the build free of warnings.

Run the tests before opening a pull request:

```bash
xcodebuild -project RamLume.xcodeproj -scheme RamLume -configuration Debug test
```

## Project layout

See [docs/architecture.md](docs/architecture.md). In short: system readers and the
`MonitoringCoordinator` live in `RamLume/Core`, pure rules in `RamLume/Diagnostics`, history in
`RamLume/Storage`, and SwiftUI views in `RamLume/UI`. Views never call system APIs directly.

## Tests

- Unit tests use Swift Testing and live in `RamLumeTests/`, mirroring the app's folders.
- Logic belongs in pure types (value types or functions) so it can be tested without the UI.
- Fakes and fixtures live only in `RamLumeTests/Support`. The one exception is the screenshot
  demo mode in `RamLume/Debug/DemoData.swift`, which is wrapped in `#if DEBUG`; never reference
  it outside `#if DEBUG`. `scripts/make-release.sh` refuses to package a build that contains
  debug-only code.
- New diagnostics rules need tests for when they fire, when they don't, and their wording
  (for example that no text recommends restarting the Mac).
- Chart hover: never let anything drawn for the hovered value change the layout of the view that
  receives hover (see "Chart hover" in [docs/architecture.md](docs/architecture.md)).
  `HoverLoopRegressionTests` exercises every chart and `DashboardLifecycleTests` the whole
  dashboard; both start a hidden copy of the app and need a logged-in GUI session.

## Screenshots

The README screenshots use example data, never anyone's real processes. To regenerate them,
build the Debug configuration and launch it with `--demo` plus a section, for example:

```bash
open -n build/DerivedData/Build/Products/Debug/RamLume.app --args --demo --dashboard history
```

`--panel-window` shows the menu bar panel's content in a window, and `--no-activate` keeps
RamLume from taking keyboard focus. Set the appearance and chart range in Settings (or with
`defaults write io.github.13nik09.RamLume appearance dark` and `dashboardRange oneDay`)
before launching. All debug arguments are listed in [docs/building.md](docs/building.md).

## Reporting bugs

Use the bug report template. If a number looks wrong, include the output of:

```bash
/Applications/RamLume.app/Contents/MacOS/RamLume --dump-metrics
```

together with `vm_stat` and, if possible, a screenshot of Activity Monitor's Memory tab taken at
the same moment. The report contains memory statistics only — no app names.

## Pull requests

- Keep pull requests focused; describe what changed and why.
- Update documentation when behaviour or formulas change.
- Match the surrounding code style (Swift API Design Guidelines, small focused files, no force
  unwraps, constants named and documented).
- UI changes: include before/after screenshots in light and dark mode, and check VoiceOver labels.

By contributing you agree that your contributions are licensed under the MIT License.

# Changelog

All notable changes to RamLume are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.0] — Unreleased

First public version. Release notes: [docs/release-notes/v0.1.0.md](docs/release-notes/v0.1.0.md).

### Added

- Menu bar item with icon only, percentage, or used/total display, and health-based tinting.
- Menu bar panel: memory in use, composition bar, live five-minute chart, key figures, health
  explanation, largest apps, and the top insight.
- Dashboard with Overview, History, Processes, Insights, Events, and About the Numbers sections.
- Kernel-based measurements (`host_statistics64`, `sysctl`, dispatch memory-pressure events) with
  a documented, exact partition of installed memory.
- Health assessment (Healthy, Elevated, Under pressure, Critical, Insufficient data), with a
  documented fallback to dispatch events if the kernel's pressure level can't be read.
- Rule-based insights, including app-specific context for browsers and a cautious possible-leak
  heuristic.
- Opt-in notifications with per-type cooldowns, and a "Send Test Notification" button.
- Multi-resolution history (raw, 10 s, 1 min, 5 min) with gaps for sleep, pauses, and time
  RamLume wasn't running; retention of 1 hour, 24 hours, or 7 days; table view of every chart.
- Process list grouped by app bundle, with search, sorting, details, and restricted-process
  labelling.
- Settings: launch at login, menu bar style, appearance, monitoring mode (Responsive, Balanced,
  Energy Saver), Low Power Mode behaviour, notifications, history retention, clear history.
- Opening a second copy of RamLume shows the running copy's dashboard instead of adding a second
  menu bar item.
- Help menu links to the GitHub repository and issue tracker.
- `--dump-metrics` command-line report for validation and bug reports.
- `scripts/make-release.sh`: universal release archive with build checks, checksum, and optional
  Developer ID signing and notarization.

### Changed (before the first release)

- Simpler navigation: Home, Applications, Recommendations, and Advanced Details. Home answers
  "Is my Mac healthy?", "Which apps use my RAM?", and "What should I do?"; the technical pages
  (memory breakdown, history, events, definitions) live under Advanced Details.
- The menu bar panel shows the status in one sentence, memory in use with one bar, the three
  largest apps, and one recommendation, instead of a grid of statistics and a chart.
- Health labels are Healthy, Elevated, High Pressure, and Checking, with plain-English sentences;
  memory terms have short explanations behind info buttons and on the Definitions page.
- A shorter welcome card explains what RamLume watches and why high RAM use can be normal.
- WebKit's shared processes are listed as "Web pages (WebKit)" rather than by executable name.

### Added (before the first release)

- Recommendations: offline, rule-based tips with the reason, a suggested action, step-by-step
  instructions (such as turning on Memory Saver in Brave or Chrome), and buttons that open
  Applications, Activity Monitor, or Login Items settings.

### Fixed (before the first release)

- Resting the pointer on a history chart could make RamLume spin at 100% of a CPU core and stop
  redrawing. A tooltip placed left of the crosshair widened the chart overlay's layout and moved
  its hover area; SwiftUI re-checked hover after that layout, the pointer then pointed at a
  different value whose tooltip went right, and the cycle repeated without end. The hover area
  is now independent of the tooltip, hover state changes only when its value changes, and a
  regression test drives real SwiftUI hover in a separate process to keep it that way.
- With a long event timeline (a couple of hundred events), opening Events made AppKit log
  "reentrant operation in its NSTableView delegate", which it says will become an assertion. The
  timeline is now a lazy stack instead of a `List`, which also stopped AppKit from keeping about
  ten table buttons (about 90 KB) alive every time the timeline was shown.
- The Processes section rebuilt and re-sorted its whole table every second, although the list only
  changes when processes are scanned. It no longer depends on the per-second memory reading,
  which cut the work it does while visible by about 40% (instructions retired, same data).

### Known issues

- While Processes is visible, AppKit sometimes logs "reentrant operation in its NSTableView
  delegate" when a scan reorders a long process list (SwiftUI's `Table` applying the change).
  No effect on the table or on CPU use has been seen; `--processes-probe` in Debug builds
  reproduces it.
- Each time the dashboard is opened and closed, AppKit keeps one of the sidebar's buttons alive
  (about 9 KB), roughly 1 MB per 100 openings until RamLume quits. The leak is inside AppKit; see
  [docs/performance.md](docs/performance.md).

### Notes

- Release archives are ad-hoc signed and **not notarized** unless a release says otherwise.
- The current pressure level is read from `kern.memorystatus_vm_pressure_level`, which Apple
  doesn't document; see [docs/memory-metrics.md](docs/memory-metrics.md) for why and for the
  fallback.

[0.1.0]: https://github.com/13nik09/RamLume/releases/tag/v0.1.0

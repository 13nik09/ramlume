# Changelog

All notable changes to RamLume are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- Home shows the memory details below the largest apps and the recommendation, so the status,
  the chart, the apps, and the recommendation fit in the window without scrolling.
- Home uses about a third less CPU while it's visible (3.6 % to about 2.3 % of one core in an
  optimized build): its memory details no longer lay out their grid twice on every update.
- The menu bar panel redraws less: its tiles and status badge update only when what they show
  changes.
- While the displays are asleep, RamLume samples at its slow idle rate even if the panel or the
  dashboard was left open.
- History is saved every 15 minutes instead of every 5 (and, as before, when the Mac sleeps or
  RamLume quits). Each save rewrites the whole file, about 0.7 MB with 24 hours of history.

### Fixed

- Chart time labels started at their grid lines instead of being centered under them: Swift
  Charts on macOS 27 ignores the label anchor RamLume used. Labels are now centered, and those
  near either end of the axis extend inwards instead of sticking out past the chart.
- Pausing or resuming monitoring didn't notify the views that show it, and with sampling paused
  nothing else redrew them: the panel's menu could still offer "Pause Monitoring" (which then
  resumed) and its "Monitoring is paused" note could stay hidden.
- Setting the clock back stopped process scans and history saves until the clock caught up, and
  a history file saved while the clock was ahead kept data dated in the future.

## [0.1.0] — 2026-10-30

First public version. Release notes: [docs/release-notes/v0.1.0.md](docs/release-notes/v0.1.0.md).

### Added

- Menu bar item with icon only, percentage, or used/total display, tinted only when memory needs
  attention.
- Menu bar panel: the status in one sentence, memory in use with one bar, app memory, compressed
  memory, cached files, and swap, the three largest apps, and one recommendation.
- Dashboard with Home, Applications, Recommendations, and Advanced Details. Home answers "Is my
  Mac healthy?", "Which apps use my RAM?", and "What should I do?", and shows the figures
  Activity Monitor shows (physical memory, memory in use, app, wired, and compressed memory,
  cached files, swap used) with the pressure level macOS reports.
- Advanced Details: the full memory breakdown, every insight with its evidence, history charts,
  the event timeline, and a definition of each memory term next to its exact formula.
- Kernel-based measurements (`host_statistics64`, `sysctl`, dispatch memory-pressure events) with
  a documented, exact partition of installed memory.
- Health status (Healthy, Elevated, High Pressure, Checking) with plain-English sentences, based
  on the pressure level macOS reports and measured swap activity, with a documented fallback to
  dispatch events if the kernel's pressure level can't be read.
- Recommendations: offline, rule-based tips with the reason, a suggested action, step-by-step
  instructions (such as turning on Memory Saver in Brave or Chrome), and buttons that open
  Applications, Activity Monitor, or Login Items settings.
- Rule-based insights, including app-specific context for browsers and a cautious possible-leak
  heuristic.
- Opt-in notifications with per-type cooldowns, and a "Send Test Notification" button.
- Multi-resolution history (raw, 10 s, 1 min, 5 min) with gaps for sleep, pauses, and time
  RamLume wasn't running; retention of 1 hour, 24 hours, or 7 days; table view of every chart.
- Applications: processes grouped by app, with search, sorting, details, and restricted-process
  labelling. WebKit's shared processes are listed as "Web pages (WebKit)".
- Short explanations of memory terms behind info buttons and on the Definitions page, and a short
  welcome card on first launch.
- Settings: launch at login, menu bar style, appearance, monitoring mode (Responsive, Balanced,
  Energy Saver), Low Power Mode behaviour, notifications, history retention, clear history.
- Opening a second copy of RamLume shows the running copy's dashboard instead of adding a second
  menu bar item.
- Help menu links to the GitHub repository and issue tracker.
- `--dump-metrics` command-line report for validation and bug reports.
- `scripts/make-release.sh`: universal release archive with build checks, checksum, and optional
  Developer ID signing and notarization.

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
- The Processes section (now Applications) rebuilt and re-sorted its whole table every second,
  although the list only changes when processes are scanned. It no longer depends on the
  per-second memory reading, which cut the work it does while visible by about 40% (instructions
  retired, same data).
- The menu bar item could be drawn black on a dark menu bar, while the items around it were
  white: macOS picks light or dark content for each item and sometimes left RamLume's in the
  light style. While the Mac uses Dark mode, the item now always uses the dark menu bar style.
- A gap that began before a chart's time range (for example the hours before RamLume was opened,
  shown on the five-minute chart) drew its gray band past the chart's left edge, over the axis
  labels, the card, and the sidebar. Gaps are now cut to the visible range, and chart marks stay
  inside the plot. A gap's caption appears only when it fits on one line.

### Known issues

- While Applications is visible, AppKit sometimes logs "reentrant operation in its NSTableView
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

[Unreleased]: https://github.com/13nik09/ramlume/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/13nik09/ramlume/releases/tag/v0.1.0

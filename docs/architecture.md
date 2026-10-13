# Architecture

RamLume is a single macOS app target with no third-party dependencies. It uses SwiftUI for
views, Swift Charts for graphs, and AppKit where a menu-bar-only app needs precise control
(the status item, its panel, window activation, and the Settings window).

```
RamLume/
├── App/            Entry point, AppDelegate (composition root), AppModel, main menu, --dump-metrics
├── Models/         Value types: statistics, partition, activity, pressure, history points, insights
├── Core/           System readers, process grouping, sampling scheduler, MonitoringCoordinator
├── Diagnostics/    Trend analysis, health rules, insights, leak heuristic, notification policy
├── Storage/        Ring buffer, multi-resolution history, persistence, settings
├── Services/       Notifications, launch at login, sleep/wake and power observers
├── Debug/          Example data for screenshots (compiled into Debug builds only)
├── UI/
│   ├── MenuBar/    Status item, its presentation logic, the panel
│   ├── Dashboard/  Window controller and the dashboard sections
│   ├── Components/ Theme, cards, charts, tooltips, shared views
│   └── Settings/   Settings window and panes
└── Resources/      Asset catalog and the layered app icon (AppIcon.icon)
```

## Data flow

```
                 ┌──────────────────────── MonitoringCoordinator (main actor) ───────────────────────┐
 timer loop ───▶ │ tick ─▶ SystemMemoryReader ─▶ MemoryBreakdown ─┐                                  │
 (one Task)      │      ├▶ SystemSwapReader                          ├▶ HistoryStore (ring buffers)   │
                 │      ├▶ KernelPressureReader ─▶ PressureState ────┤                                 │
 dispatch  ────▶ │ pressure events ──────────────────────────────────┤                                 │
 pressure source │      └▶ ProcessReader (actor, off main) ─────────────▶ ProcessGrowthTracker          │
                 │                                                    ▼                                │
                 │      MemoryTrendAnalyzer ─▶ HealthRules ─▶ DiagnosticsEngine ─▶ NotificationPolicy │
                 │                                                    │                                │
                 │   `current` state (always fresh)        published copies (only while visible)     │
                 └──────────────┬──────────────────────────────────────────┬────────────────────────┘
                                ▼                                          ▼
                     StatusItemController                       SwiftUI panel and dashboard
```

### One coordinator, one loop

`MonitoringCoordinator` owns every piece of monitoring state and the only polling loop. Each
tick samples memory (a few microseconds), and starts a process scan when its longer interval has
elapsed. No view, window, or service polls the system on its own.

The loop is a single `Task` that sleeps with a 10 % tolerance so macOS can coalesce RamLume's
wake-ups with other timers. It's cancelled and restarted when the cadence changes, and stopped
entirely while monitoring is paused or the Mac is asleep.

### Cadence

`SamplingScheduler` is a pure value type that maps (profile, visibility, displays asleep, Low
Power Mode) to intervals:

| Profile | Window visible | Background | Displays asleep | Processes (visible / background) |
|---|---|---|---|---|
| Responsive | 1 s | 2 s | 30 s | 10 s / 30 s |
| Balanced (default) | 1 s | 5 s | 30 s | 15 s / 60 s |
| Energy Saver | 2 s | 15 s | 60 s | 30 s / 5 min |

"Visible" means the menu bar panel is open or the dashboard window is actually on screen (an
occluded, minimized, or other-Space dashboard counts as hidden). Low Power Mode switches to
Energy Saver unless the user opts out.

### Monitoring state

`MonitoringStateMachine` (pure, unit tested) combines three flags — started, paused by the user,
system asleep — and reports whether sampling must start or stop. Stopping opens a history gap
with a reason (sleep or pause); starting closes it, clears the activity baseline (so no rate
spans the gap), forgets the pressure observation (so no duration spans the gap), and samples
immediately. Process refreshes requested while paused are ignored.

### Publishing only what's on screen

The coordinator keeps an always-current `MonitoringState` (`current`) that drives the status
item, diagnostics, and notifications. SwiftUI reads separate published properties that are
refreshed only while a RamLume surface is visible, and each is assigned only when it changed.
History appends bump an observable `revision` the same way. As a result, a closed panel or a
hidden dashboard causes no view updates at all, and when a surface appears it is refreshed
immediately.

Charts redraw on their own schedule (every 2 s for the 5-minute range up to every 60 s for the
7-day range), and chart hover is drawn by a separate overlay that owns its state, so moving the
pointer never re-renders a chart's marks.

## Concurrency

- Swift 6 language mode with complete concurrency checking.
- UI types, the coordinator, settings, and history are `@MainActor`.
- `SystemMemoryReader`, `SystemSwapReader`, and `KernelPressureReader` are immutable `Sendable`
  values; a memory read is cheap enough to run on the main actor.
- `ProcessReader` is an `actor`: process enumeration (hundreds of syscalls) runs off the main
  thread, and its caches are actor-isolated.
- History is written by a `HistoryWriter` actor off the main thread (atomic file writes), and
  synchronously on quit, power-off, SIGTERM, and SIGINT.
- System notifications (sleep/wake, displays, Low Power Mode, power-off) are delivered on the main
  queue and handled with `MainActor.assumeIsolated`.

## History

`MemoryHistory` is a value type with four tiers, each a fixed-capacity `RingBuffer`:

| Tier | Resolution | Span | Capacity |
|---|---|---|---|
| Raw | each sample | 15 min | 1,200 |
| 10 s | 10 s | 1 h | 360 |
| 1 min | 1 min | 24 h | 1,440 |
| 5 min | 5 min | 7 days | 2,016 |

Every raw sample is merged into the in-progress bucket of each enabled tier (means, peaks, worst
pressure, summed activity). Buckets are aligned to their resolution and exist only if a real
sample fell inside them. Chart series are downsampled into aligned buckets (never merging across
buckets) and split into line segments after recorded gaps or unexplained spacing, so nothing is
interpolated across missing data.

Buckets keep *counts* rather than only the worst value where the difference matters to a chart:
each point records how many of its samples were at warning and at critical, so the pressure
timeline draws the share of each level (one brief warning in a 12-minute bucket is a sliver, not
a 12-minute band), and the swap-activity chart plots each point's bytes written divided by the
time its counters cover, so bar heights don't depend on how samples fall into bars.

If the system clock is set back by more than a few seconds, samples now dated "in the future"
are discarded so the history stays chronological and recording continues; rates are unaffected
because they use uptime, not the wall clock. Events older than the retention window are dropped
whenever history is saved.

Persistence (`HistoryPersistence`) writes the aggregated tiers, in-progress buckets, gaps, and
the event timeline to `~/Library/Application Support/RamLume/History.json` — under 2 MB even
with a full week of history. The time RamLume wasn't running is recorded as a gap on the next launch. An unreadable
file is set aside (`History.unreadable.json`) and RamLume starts fresh.

## Windows in a menu-bar-only app

- `LSUIElement` keeps RamLume out of the Dock by default.
- `StatusItemController` shows an `NSPopover` hosting SwiftUI. Its hierarchy is created when it
  opens and released when it closes. A global event monitor closes it on clicks in other apps.
- The dashboard and Settings are AppKit-managed windows hosting SwiftUI. While either is open,
  `ActivationPolicyController` switches RamLume to a regular app (Dock icon, ⌘-Tab, main menu);
  it returns to menu-bar-only when the last one closes.
- Re-opening RamLume from Finder or Spotlight opens the dashboard.
- Only one copy runs at a time. A second copy with the same bundle identifier (say, one still
  in Downloads) posts a distributed notification asking the running copy to show its dashboard,
  then quits, so there's never a second menu bar item writing the same history file.

## Testing seams

Readers are protocols (`MemoryStatisticsProviding`, `SwapUsageProviding`,
`PressureLevelProviding`, `ProcessProviding`). The coordinator accepts an injectable clock and can
run without its timer loop, so tests drive samples deterministically. Fakes live only in the test
target. The app detects that it's hosting unit tests and doesn't start monitoring or add a status
item.

For screenshots, Debug builds have a demo mode (`--demo`, `RamLume/Debug/DemoData.swift`) that
plugs example readers into the same coordinator, so every figure still goes through the real
partition, history, health, and insight code. The file is compiled only into Debug builds, demo
mode has no history persistence and never notifies, and `scripts/make-release.sh` refuses to
package a binary that contains debug-only code.

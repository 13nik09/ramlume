# Performance

RamLume's targets are an idle memory footprint under 120 MB, average idle CPU under 1 % of one
core, no network requests, and history storage well under 20 MB. This page records how those
were measured and what was found. Numbers are measurements on one machine, not guarantees.

## Test machine and method

- Apple silicon MacBook with 16 GB of memory, macOS 27.0.1, Xcode 27.0.
- Optimized **Release** builds without code-coverage instrumentation (verified with `nm`),
  Balanced monitoring mode, real data. macOS reported **warning** memory pressure throughout the
  final round, with about 2 GB in swap; under pressure the kernel also compresses and
  decompresses RamLume's own memory, which counts towards its CPU time, so a Mac with normal
  pressure should see the same or lower numbers.
- CPU: cumulative CPU time from `ps -o time=` before and after a fixed period, divided by the
  period (`scripts/measure-usage.sh`). 1 % = 10 ms of CPU time per second on one core.
- Memory: `footprint -p <pid>` (physical footprint, the same metric as Activity Monitor).
- Rows with a visible panel or dashboard used the debug-only `--assume-visible` switch, so the
  dashboard renders at its on-screen cadence without covering the desktop during testing. Since
  that switch is compiled out of Release builds, those rows were measured with an otherwise
  identical optimized build that keeps it (`-configuration Release
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG ONLY_ACTIVE_ARCH=YES CLANG_COVERAGE_MAPPING=NO`,
  arm64) in its default 1,080 × 720 window. This measures RamLume's own work (SwiftUI updates,
  layout, Core Animation commits); compositing in WindowServer isn't included.

## Results

| Scenario | Sampling | CPU (one core) | Footprint |
|---|---|---|---|
| **Menu bar only (no windows)** | every 5 s | **0.09–0.21 %** (0.13 % over 5 minutes) | **17–18 MB** |
| After the dashboard has been opened and closed | every 5 s | 0.12 % | ≈ 45–60 MB |
| Menu bar panel open | every 1 s | ≈ 0.5–3 % | ≈ 35–89 MB |
| Dashboard visible, Overview (15-minute range) | every 1 s | ≈ 4.4–4.9 % | ≈ 67–70 MB |
| Dashboard visible, History, 15-minute range | every 1 s | ≈ 2.0–2.6 % | ≈ 71 MB |
| Dashboard visible, History, 1-hour range | every 1 s | ≈ 1.4 %¹ | ≈ 87 MB¹ |
| Dashboard visible, History, 24-hour range | every 1 s | ≈ 0.9 %¹ | ≈ 85 MB¹ |

¹ Measured once, in a larger 1,120 × 860 window. Other ranges span several runs. The idle row is the target that matters most:
RamLume spends nearly all of its time in the menu bar, where it measured 0.09 % installed in
`/Applications` (0.11 s of CPU over 120 s) and about 0.1 idle wake-ups per second (`top`). The
panel and dashboard figures apply only while you're looking at them. Earlier measurements on
these pages used builds that, without anyone intending it, carried code-coverage
instrumentation; they have all been redone.

After a window closes, CPU returns to the idle level immediately. The footprint stays somewhat
higher than at launch because macOS keeps framework and graphics caches and freed memory for
reuse. Over 30 automated open/close cycles of the dashboard (`--open-close-cycles`, all sections)
the footprint settled at about 84 MB after roughly 20 cycles and stayed there, rather than
growing. `leaks` found no leaked RamLume objects; its only reports (about 20 KB) are retain cycles
inside a system XPC connection to `com.apple.linkd`, which don't grow with use. Memory graphs from
the later stress testing found one small framework leak per dashboard window (see below).

Other figures:

- **Network:** RamLume contains no networking code and makes no requests.
- **History file:** 330–400 bytes per stored point (measured 330 bytes on average for a fresh
  file); a full week of history (3,816 aggregated points plus events and gaps) stays under 2 MB.
- **Process scan:** the system calls for ~630 processes take about 1–2 ms (median 1.2 ms over
  10 runs); grouping and labelling add a few milliseconds more, with bundle names and icons
  cached. Scans run on a background actor every 60 s in the background and every 15 s while a
  window is visible.
- **One memory sample:** the kernel calls (`host_statistics64` plus three sysctls) take about
  3 µs (2.8 µs average over 10,000 calls).
- **App size:** about 10 MB for the universal app bundle.

## Stress and soak testing

Before the first release, a CPU hang in the chart hover was found and fixed (see the
[changelog](../CHANGELOG.md)). Afterwards the dashboard, the panel's content, and every chart were
stress-tested with the Debug-only harnesses in `RamLume/Debug` ([building.md](building.md) lists
them), in optimized builds that keep those harnesses, with scratch history files, no menu bar item,
and windows that were never activated or under the pointer. Hover in these runs is synthetic: SwiftUI's real hover handling,
entered at the hosting view (see "Chart hover" in [architecture.md](architecture.md)).

| Run | Result |
|---|---|
| Hover lab: 69 scenarios on all six charts (pointer resting on data and on gaps, sweeps, entering and leaving, data arriving, range changes, empty and single-point series) | No stalls. At most 301 hover-handler calls and 149 state writes in a scenario, never more than the events delivered; longest main-thread gap 90–112 ms over two full runs. Before the fix, a pointer resting just right of a chart's middle hung every chart, at about 10,000 handler calls per second. |
| 100 dashboard cycles (`--ui-stress 100`, final code): every section and range, hover over History and Overview, dark, light, and system appearance, the panel with hover, pause and resume, simulated sleep and wake, 50 pressure changes, close, then 10 rapid open/close pairs | All 100 cycles completed, the watchdog never fired, and AppKit logged no warnings. All 1,100 closed dashboards and 100 panels were released. Steady throughout: 3.8 s of CPU per 10.4 s cycle (at most 4.2 s); footprint, measured right after the rapid open/close burst, levelled off at about 185 MB from cycle 30; idle at the end, 130 MB, of which 41 MB were live allocations and the rest freed memory that malloc keeps. |
| 30-minute soak: History visible, sampling every second, a hover sweep every 5 s (a build with the hover fix, before the Events and Processes changes) | Exit 0; the watchdog never fired (the longest gap, 2.7 s, was `leaks` suspending the process; otherwise at most 390 ms). CPU rose from 5 % to about 9.5 % over the first 19 minutes while the chart filled, then stayed flat; footprint swung between 78 and 177 MB without a trend (117 MB at the end). `leaks` at minute 29 found only the system `com.apple.linkd` cycles described above (19.5 KB). |
| 100 launch/quit cycles (quit by SIGTERM after 2 s) | None hung, no non-zero exits (both builds). |

The longest main-thread gap of every dashboard cycle (median 0.73 s, at most 1.0 s, with the main
thread busy 95 % of it) fell in the rapid open/close step: a History dashboard takes roughly
70–80 ms of main-thread time to build, so ten opened 20 ms apart keep the main thread busy for most
of a second. The watchdog records how much of each gap the main thread spent running, which
separates work from macOS delaying the timers of a background app.

Memory graphs taken after cycle 20 and after cycle 100 (`leaks --outputGraph`, `heap --diffFrom`)
show one thing that grows with every dashboard opened and closed: a disclosure button that AppKit
creates for the sidebar's outline view and keeps alive through a notification observer it never
removes (`-[NSView _commonAwake]`), about 9 KB each, exactly one per window. That is inside AppKit,
not RamLume's code, and comes to roughly 1 MB per 100 times the dashboard is opened, until RamLume
quits; keeping the dashboard alive instead would cost 40–60 MB. `leaks` doesn't report it, because
the buttons stay reachable. In the build before the Events change, about 11 leaked per window; the
extra ones came from the Events `List`.

### Before and after the Events and Processes changes

Same history file, same Mac, builds alternating, 60 s each after a 20 s warm-up, pointer ignored.
"Before" already has the hover fix. CPU time on Apple silicon depends on which cores macOS picks
(here 9–51 % of the time ran on performance cores), so instructions retired, which measure the work
itself, are the better comparison. The history file came from the stress runs (300 events and
hundreds of gaps), so compare columns, not this table with the one above.

| Visible | CPU, before → after | Instructions/s, before → after | Footprint, before → after |
|---|---|---|---|
| Overview | 7.6 % → 5.6 % | 198 M → 203 M | 79 → 71 MB |
| History | 2.6 % → 1.8 % | 89 M → 86 M | 88 → 87 MB |
| Processes | 1.3 % → 0.4 % | 29 M → **17 M** | 65 → 63 MB |
| Events (300 events) | 0.37 % → 0.24 % | 8.5 M → 7.4 M | 46 → 42 MB |
| Panel content | 2.7 % → 2.8 % | 67 M → 68 M | 91 → 90 MB |
| Menu bar only | 0.08 % → 0.07 % | 2.3 M → 2.2 M | 20 → 20 MB |

## What keeps it light

- One sampling loop for the whole app, with a 10 % timer tolerance so macOS can coalesce
  wake-ups. Sampling slows to every 5 s when no window is visible, and to every 30–60 s while the
  displays sleep; it stops entirely while the Mac sleeps or monitoring is paused.
- SwiftUI is updated only while a RamLume surface is actually on screen. A covered or minimized
  dashboard, or a closed panel, causes no view updates.
- Views receive pre-formatted values and are compared with `Equatable`, so a second in which no
  displayed text changes doesn't re-render them.
- Charts redraw on their own schedule (every 2 s for the 5-minute range, up to every 60 s for
  7 days) with at most 120 points per series, and the hover crosshair is a separate overlay so
  moving the pointer doesn't re-render chart marks.
- The panel and the dashboard release their SwiftUI hierarchies when closed.
- The composition bar animates only when usage changes by at least 2 % of RAM.
- History lives in fixed-capacity ring buffers; process lists are never stored.

## Reproducing

```bash
xcodebuild -project RamLume.xcodeproj -scheme RamLume -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/RamLume.app
sleep 20
scripts/measure-usage.sh 120
```

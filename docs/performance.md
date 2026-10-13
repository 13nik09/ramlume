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
inside a system XPC connection to `com.apple.linkd`, which don't grow with use.

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

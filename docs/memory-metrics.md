# How RamLume measures memory

RamLume reads memory statistics directly from the macOS kernel. It never runs `top`,
`vm_stat`, or `memory_pressure` to sample, needs no administrator privileges, and uses no
private frameworks. This document lists every figure RamLume shows, where it comes from, how
it's calculated, and whether it is **measured**, **derived**, **estimated**, or a **heuristic**.

| Kind | Meaning |
|---|---|
| Measured | Reported directly by macOS. |
| Derived | Simple arithmetic on measured values (a sum or a difference of counters). |
| Estimated | An approximation of a concept macOS doesn't report directly. Shown with "≈" in the app. |
| Heuristic | A judgement made by RamLume's rules (the health assessment). |

## Sources

| Interface | What RamLume reads | Notes |
|---|---|---|
| `host_statistics64(HOST_VM_INFO64)` | Page counts and cumulative counters (`vm_statistics64`) | The same source `vm_stat` uses. The host port is obtained once with `mach_host_self()`. |
| `host_page_size` | Kernel page size | 16 KB on Apple silicon, 4 KB on Intel. |
| `sysctl hw.memsize` | Installed memory | Also available as `ProcessInfo.physicalMemory`. |
| `sysctl hw.memsize_usable` | Memory managed by the OS | Excludes memory reserved by hardware and firmware. Optional: if missing, that memory appears as "unaccounted". |
| `sysctl vm.swapusage` | Swap allocated / used / available, encryption | `struct xsw_usage`. |
| `sysctl kern.memorystatus_vm_pressure_level` | Current pressure level | 1 = normal, 2 = warning, 4 = critical. Read on every sample (see below). |
| `sysctl kern.memorystatus_level` | "System-wide memory free percentage" | The value `memory_pressure` prints. Shown for reference only. |
| `DispatchSource.makeMemoryPressureSource` | Pressure transitions as they happen | Event-driven; costs nothing between events. |
| `proc_listallpids`, `proc_pid_rusage(RUSAGE_INFO_V4)`, `proc_pidpath`, `proc_pidinfo(PROC_PIDT_SHORTBSDINFO)` | Per-process footprint, path, owner | See [Processes](#processes). |

Every `sysctl` is read with a size check: if the kernel returns a different size than expected
(for example because a future macOS changes the type), the value is treated as unavailable
instead of being misread.

### Why both a sysctl and a dispatch source for pressure?

Dispatch memory-pressure sources only fire when the level **changes**. On their own they can't
tell whether the system was already under pressure when RamLume launched (verified: activating
a source while the system is at the warning level delivers no event). The
`kern.memorystatus_vm_pressure_level` sysctl provides the current level; the dispatch source
delivers transitions between samples immediately. Because macOS can merge back-to-back events
into one, RamLume treats an event as a prompt rather than as the answer: it re-reads the sysctl
and applies that level (falling back to the event's own level only if the sysctl is
unavailable), then re-evaluates health and insights right away instead of waiting for the next
sample.

### Why an undocumented sysctl, and what happens without it

The sysctl isn't described in Apple's developer documentation. It is a public, read-only kernel
interface (defined in XNU's open-source `kern_memorystatus.c` and reported by Apple's
`memory_pressure` tool), it needs no privileges or entitlements, and there is no documented API
that returns the *current* level: the documented dispatch source only reports changes. RamLume
therefore uses the documented dispatch source for every transition and the sysctl only to know
the level when no transition has been seen, treating it as optional:

- Values are size-checked and must be 1, 2, or 4; anything else counts as unavailable.
- The "About the Numbers" page shows where the current level came from: the kernel level, or
  dispatch events only.
- **Without the sysctl**, RamLume runs on dispatch events alone:
  - After launch, the level is *Not reported* until macOS reports a change. Health is then
    based on swap activity only and says so; RamLume needs a few minutes of measurements before
    calling memory healthy this way, and never claims *Under pressure* or *Critical*.
  - Each event sets the level. Samples without a kernel level never erase it.
  - Events are remembered while monitoring is paused or the Mac sleeps (they still describe the
    current level), and are applied as a new, lower-bound observation when sampling resumes.
  - When macOS merges several transitions into one event, their order is lost, so the level
    becomes *Not reported* rather than a guess.

This fallback is unit tested and can be exercised in a Debug build with
`--pressure-events-only` (see [building.md](building.md)).

## The memory partition

Every byte of installed memory is placed in exactly one category, so the categories always add
up to installed memory and nothing is counted twice.

| Category | Formula | Kind |
|---|---|---|
| **Wired** | `wire_count × page size` | Measured |
| **Compressed** | `compressor_page_count × page size` | Measured |
| **App** | `(internal_page_count − purgeable_count) × page size` | Derived |
| **Cached files** | `(external_page_count + purgeable_count) × page size` | Estimated (reclaimable) |
| **Free** | `(free_count − speculative_count) × page size` | Derived |
| **Reserved** | `hw.memsize − hw.memsize_usable` | Derived |
| **Unaccounted** | whatever remains (normally zero) | Derived |

Three facts from the kernel headers and from measurement make this partition exact:

1. `free_count` **already includes** speculative pages (see the comment in
   `mach/vm_statistics.h`). That's why `vm_stat` prints "Pages free" as
   `free_count − speculative_count`, and why RamLume subtracts speculative pages from Free
   instead of adding them anywhere.
2. `internal_page_count + external_page_count = active + inactive + speculative`. Anonymous and
   file-backed pages are two views of the same pageable pages, so RamLume uses one pair or the
   other, never both.
3. Compressed memory is counted **once**, as the physical pages the compressor occupies
   (`compressor_page_count`). The larger amount of data it holds
   (`total_uncompressed_pages_in_compressor`) is shown for information ("10 GB stored in 5.7 GB")
   but never added to any total, because those pages are not resident.

On the 16 GB Apple silicon Mac RamLume was developed on, `(free − speculative) + internal +
external + wired + compressor` equalled `hw.memsize_usable` **to the page**, and adding
`hw.memsize − hw.memsize_usable` (632 MB of hardware-reserved memory) gave exactly
`hw.memsize`. The unit tests use those real page counts to check the partition.

Purgeable memory is anonymous memory that apps marked as discardable, so RamLume moves it from
App to Cached files. If counters read at slightly different instants are inconsistent (for
example purgeable exceeding internal pages), values are clamped at zero rather than going
negative.

## Derived figures

| Figure | Formula | Kind |
|---|---|---|
| **Used** | `App + Wired + Compressed + Reserved + Unaccounted`, i.e. everything except Cached files and Free | Estimated |
| **Used %** | `Used ÷ Installed` | Estimated |
| **Available without swapping** | `Cached files + Free` | Estimated (upper bound) |
| **Compression ratio** | `stored ÷ occupied` | Derived |
| **Saved by compression** | `stored − occupied` | Derived |

Reserved memory counts as used because no app can use it. With this definition
`Used + Cached files + Free = Installed`.

### Comparison with Activity Monitor

Activity Monitor's *Memory Used*, *Cached Files*, and *Memory Pressure* graph come from Apple's
own, unpublished calculations, so RamLume doesn't claim to reproduce them. A side-by-side
reading taken within one second on the development Mac (macOS 27.0.1, 16 GB, Apple silicon):

| Figure | Activity Monitor | RamLume |
|---|---|---|
| App Memory | 5.05 GB | 4.97 GB |
| Wired Memory | 1.95 GB | 2.09 GB |
| Compressed | 5.51 GB | 5.50 GB |
| Cached Files | 2.56 GB | 2.54 GB |
| Swap Used | 340.5 MB | 340.5 MB |
| Memory Used | 13.21 GB | 13.18 GB (RamLume's Used) |
| Pressure | yellow graph | Warning (kernel level 2) |

Observations:

- **Swap** matches exactly (same `vm.swapusage` source).
- **Compressed** and **Cached files** agree within 0.02 GB, which is consistent with counters
  changing between the two readings.
- **Memory Used** matches when Reserved memory is included. Activity Monitor's own
  App + Wired + Compressed adds up to only 12.51 GB, so its Memory Used evidently includes the
  ~0.6 GB of hardware-reserved memory too.
- **App** and **Wired** differ by about 0.1 GB in opposite directions: Activity Monitor appears
  to attribute a small amount of memory to App that the kernel counts as wired. RamLume reports
  `wire_count` as-is. Expect differences of this size; they don't change any conclusion.

### Comparison with `vm_stat` and `sysctl`

`RamLume --dump-metrics` prints one reading with every raw counter and formula (see
[Checking the numbers yourself](#checking-the-numbers-yourself)). Compared with `vm_stat` run
immediately afterwards on the development Mac:

| Value | `vm_stat` / `sysctl` | RamLume |
|---|---|---|
| Pages wired down | 110,375 | 110,375 |
| Pages occupied by compressor | 347,227 | 347,227 |
| Pages stored in compressor | 654,412 | 654,412 |
| Swapins / Swapouts | 1,637,092 / 2,110,531 | 1,637,092 / 2,110,531 |
| Compressions | 93,320,841 | 93,320,841 |
| Pages free | 60,056 | 60,092 (`free_count − speculative_count`) |
| Pages active | 245,321 | 245,312 |
| `vm.swapusage` used | 340.50M | 357,040,128 bytes (340.5 MB) |
| `kern.memorystatus_vm_pressure_level` | 1 | 1 (Normal) |

Counters that change continuously (free, active) differ by a few dozen pages because the two
tools read them a fraction of a second apart.

## Activity rates

Cumulative counters (`pageins`, `pageouts`, `swapins`, `swapouts`, `compressions`,
`decompressions`, `faults`) are turned into per-interval deltas by subtracting the previous
reading. Byte values multiply page counts by the kernel page size; for swap, the kernel counts
the pages of compressed segments written to or read from the swap files, so "swap written" is
swap I/O, not the uncompressed size of the data.

A delta is reported **only** when both readings are comparable:

- the interval (system uptime excluding sleep) is positive and at most 5 minutes;
- the page size didn't change;
- no counter went backwards (a decrease means a reset; RamLume never invents a value).

The baseline is cleared on sleep, pause, and read failures, so no rate ever spans a gap.

## Swap

`vm.swapusage` reports the space currently **allocated** to swap files (macOS creates them on
demand), how much of it is used, and whether swap is encrypted. Allocated swap can stay in place
long after memory demand drops; RamLume therefore looks at *swap activity* (bytes written
recently) rather than swap size when judging health.

## Memory pressure

The pressure level shown as "macOS memory pressure" is the kernel's own classification. RamLume
reports it unchanged and never computes it. RamLume's **health** rating is a separate,
clearly-labelled heuristic; see [diagnostics.md](diagnostics.md).

Durations only cover time RamLume actually observed:

- **Elevated time** is measured from when pressure last became warning *or worse*, so moving
  between warning and critical doesn't restart it; it ends when pressure returns to normal.
- Observation **starts over** at launch, after sleep, and after a pause. Time asleep or paused
  is never counted as time under pressure.
- If pressure is already elevated at the first reading after one of those points, it may have
  started earlier, so the duration is reported as a lower bound ("for at least 5 min").

## Processes

- **Memory** is the physical footprint (`ri_phys_footprint` from `proc_pid_rusage`), the same
  metric as Activity Monitor's Memory column. It includes compressed memory attributed to the
  process.
- **Peak** is `ri_lifetime_max_phys_footprint`.
- macOS only lets an unprivileged app read `proc_pid_rusage` for the **current user's**
  processes. For processes owned by root or other users the call fails with `EPERM`; RamLume
  lists those as *Restricted* and never substitutes another number (such as resident size).
  On the development Mac, 455 of 701 processes were measurable; all 245 restricted processes
  belonged to other users.
- **Grouping** uses only certain relationships. Processes whose executables live inside the same
  `.app` bundle form one group (a browser's renderer and GPU helpers live inside the browser's
  bundle). Processes outside any app bundle that run the same executable (for example several
  `com.apple.WebKit.WebContent` processes) form a shared group whose owner RamLume does not
  claim to know. Nothing is grouped by a name match.
- **Group totals** sum each member's footprint. Shared memory may be attributed to more than one
  process or to none, so a total is an approximation of the group's impact.

## Units

RamLume uses binary units (1 GB = 1,073,741,824 bytes), like macOS's own memory figures.
Compact values drop a trailing ".0" ("2 GB").

## Known limitations

- `host_statistics64` reads counters without a global lock, so values from one reading can be
  very slightly inconsistent. RamLume clamps instead of producing negative numbers.
- `hw.memsize_usable` may not exist on every Mac or macOS version; reserved memory then appears
  as "unaccounted".
- `kern.memorystatus_vm_pressure_level` and `kern.memorystatus_level` aren't documented by Apple.
  RamLume uses them read-only and degrades gracefully if they disappear.
- Per-process memory is unavailable for other users' processes without elevated privileges,
  which RamLume intentionally doesn't request.
- RamLume ships as a universal binary and runs natively on Apple silicon and Intel. Running it
  under Rosetta translation hasn't been tested.

## Checking the numbers yourself

```bash
vm_stat
sysctl vm.swapusage kern.memorystatus_vm_pressure_level kern.memorystatus_level hw.memsize hw.memsize_usable
memory_pressure
/Applications/RamLume.app/Contents/MacOS/RamLume --dump-metrics
```

`scripts/compare-with-system-tools.sh` runs RamLume's report next to `vm_stat` and `sysctl`.

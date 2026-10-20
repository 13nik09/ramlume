# Health, insights, and notifications

RamLume's diagnostics are deterministic rules over measured data. There is no AI model, no
network call, and no randomness: the same measurements always produce the same assessment and
the same wording. Every rule is unit tested (`RamLumeTests/Diagnostics`).

The code lives in `RamLume/Diagnostics/`:

| File | Responsibility |
|---|---|
| `MemoryTrendAnalyzer.swift` | Summarizes recent raw samples: swap written/read in the last 5 minutes, swap and compression change over the current uninterrupted segment, time spent at elevated pressure. |
| `HealthRules.swift` | Turns the current reading, the kernel pressure level, and the trends into a `HealthAssessment`. |
| `DiagnosticsEngine.swift` | Produces plain-English `Insight`s. |
| `KnownApplications.swift` | App-specific context for the "largest consumer" insight, keyed by bundle identifier. |
| `ProcessGrowthTracker.swift` | Heuristic for possible memory leaks. |
| `NotificationPolicy.swift` | Decides when (rarely) to notify. |

## Principles

1. **The kernel's pressure level is the primary signal.** RamLume shows it as "macOS memory
   pressure" exactly as reported. The health rating is labelled as RamLume's assessment and is
   never presented as Apple's Memory Pressure reading.
2. **High utilization alone is never a problem.** macOS keeps memory busy with apps and file
   caches on purpose. A Mac with normal pressure using 12 GB of 16 GB is healthy.
3. **Compression is normal.** It's faster than swapping. It only matters together with rising
   pressure and swap activity.
4. **Allocated swap isn't active swapping.** RamLume looks at how much is being written to swap
   now, not at how much swap space exists.
5. **No restart advice for normal swap.** RamLume never suggests restarting the Mac to clear swap.
6. **Cautious language.** Where RamLume can't observe a cause (which tab uses memory, whether
   growth is a leak), it says "may" and explains alternatives.
7. **No data, no verdict.** Without a pressure level or enough activity data the state is
   *Insufficient data*, and nothing is extrapolated.

## Health states

Evaluated in order; the first matching rule wins.

| State | Condition | Color |
|---|---|---|
| Insufficient data | No reading yet, a read failure, or no pressure level *and* too little counter data: < 20 s, or < 4 minutes without notable swapping (see below) | Gray |
| Critical | macOS reports critical pressure | Red |
| Under pressure | macOS reports warning pressure. The explanation mentions swapping only when the [swap test](#the-swap-test) passes, and gives the duration once pressure has been elevated for ≥ 2 min | Orange |
| Elevated | Pressure is normal, but ≥ 256 MB was written to swap in the last 5 minutes ("Heavy swapping" at ≥ 1 GB), or pressure was elevated within the last 10 minutes ("Recovering") | Amber |
| Healthy | Pressure is normal and none of the above apply | Green |

The interface shows four labels: **Healthy**, **Elevated**, **High Pressure** (Under pressure and
Critical, told apart by color and wording), and **Checking** (Insufficient data), each with a plain
sentence such as "Your Mac is running smoothly." Short swings don't flip the state: pressure
counts as sustained only after 2 minutes, and the state stays Elevated for 10 minutes after
pressure returns to normal.

## Recommendations

`RecommendationEngine` turns the same input as the insights into tips with a title, a plain
explanation, the reason, a suggested action, step-by-step instructions, and optional actions
(View Applications, Open Activity Monitor, Open Login Items Settings, Learn More). It runs once
per sample in the coordinator, never per redraw, and it's fully offline and deterministic.

| Recommendation | Priority | When |
|---|---|---|
| Free up memory now | Urgent | macOS reports critical pressure |
| Reduce memory use | Important | Warning pressure for ≥ 2 min; mentions swapping when swap is growing, and names the largest apps |
| Memory is getting tight | Suggested | Warning pressure for less than 2 min |
| *Browser* is using *size* | Optional, or Suggested while memory is tight | A known browser among the three largest apps, using ≥ 1 GB and ≥ 8 % of RAM; includes the browser's own Memory Saver or sleeping-tabs steps where it has them |
| *App* is using *size* | Optional, or Suggested while memory is tight | The largest app (not a browser) uses ≥ 1.5 GB and ≥ 10 % of RAM and RamLume has a tip for it |
| *App*'s memory keeps growing | Optional, or Suggested while memory is tight | A growth finding (see below); suggests reopening the app if it becomes slow, without diagnosing a leak |
| Review apps that run in the background | Optional | Memory is tight; explains where Login Items are and opens that settings page |
| Your Mac used swap recently | Optional | ≥ 256 MB written to swap in 5 minutes while pressure is normal |
| Swap in use is normal here | Status | Swap allocated but quiet while pressure is normal; says no restart is needed |
| Your Mac is managing memory normally / Checking / Your Mac is coping | Status | Shown first whenever nothing above asks for action |

Nothing is suggested while a Mac is healthy, apart from optional tips about large or growing apps.
RamLume never suggests restarting to clear swap, never "cleans" memory, and never quits apps or
changes settings itself.

### How long pressure has lasted

The duration RamLume reports is the time since pressure last became warning *or worse*:
switching between warning and critical doesn't restart it. Only observed time counts —
observation starts over at launch, after sleep, and after a pause — and when pressure is already
elevated at the first reading, the duration is phrased as a lower bound ("at least 5 min").
Pressure events from macOS are confirmed against the current kernel level and trigger an
immediate re-evaluation, so the health state, insights, and notifications don't lag behind the
level shown. Details in [memory-metrics.md](memory-metrics.md#memory-pressure).

### The swap test

Health explanations, the sustained-pressure insight, and its notification all use one test for
"your Mac is swapping": ≥ 256 MB written to swap in the last 5 minutes (counted only once there
are ≥ 20 s of counter data), or swap use grew ≥ 512 MB over the current uninterrupted stretch of
up to 15 minutes. Because the wording comes from the same function (`HealthRules.swapSentence`),
the health card and the insights can't contradict each other.

If macOS reports no pressure level at all, RamLume can still say *Healthy* or *Elevated* from
swap activity, states that its assessment is based on swap activity only, and never claims
*Critical* or *Under pressure*. Measured swapping is reported after 20 s of counter data, but
"no notable swapping" is weaker evidence (swap writes come in bursts), so without a pressure level
RamLume waits for 4 minutes of data before calling memory healthy.

Thresholds are defined once, in `HealthThresholds`:

| Threshold | Value | Why |
|---|---|---|
| `notableSwapOut` | 256 MB written in 5 min | Swapping that size in minutes reflects real demand, while occasional small swap-outs are routine. |
| `heavySwapOut` | 1 GB written in 5 min | Sustained, heavy disk traffic that users typically notice. |
| `sustainedPressureDuration` | 2 min | Brief warnings during app launches are common; this filters them. |
| `recoveryWindow` | 10 min | Keeps the state from flapping right after a busy period. |
| `minimumActivityCoverage` | 20 s | Enough counter data for a 5-minute total to be meaningful. |
| `swapOnlyVerdictCoverage` | 4 min | Without a pressure level, how much quiet counter data it takes to call memory healthy. |
| `highUtilizationFraction` | 75 % | Only changes the *wording* ("Most of your memory is in use, which is normal…"), never the state. |
| `notableSwapGrowth` | 512 MB | Swap growth that, with warning pressure, indicates sustained demand. |

The status item is tinted orange for *Under pressure* and red for *Critical* (optional, on by
default). It is never colored because of the usage percentage.

## Insights

Insights are sorted most severe first. *Info* explains; *Suggestion* offers an optional action;
*Attention* and *Critical* deserve action.

| Insight | Kind | When |
|---|---|---|
| Critical memory pressure | Critical | macOS reports critical pressure. Names the largest app. |
| Sustained memory pressure | Attention | Warning pressure, elevated (warning or critical) for ≥ 2 min, and the [swap test](#the-swap-test) passes. "Your Mac may be experiencing sustained memory pressure: macOS has reported elevated pressure for 12 min. Your Mac wrote 600 MB to swap… Closing unnecessary applications could improve performance." |
| Memory pressure is elevated | Suggestion | Warning pressure that isn't sustained or accompanied by swapping. A brief spike is described as common; a longer stretch says how long it has lasted and that there's been little swapping so far. |
| Recent swapping | Suggestion | Normal pressure, but ≥ 256 MB written to swap in 5 min. |
| *App* is using *N GB* | Info, or Suggestion if pressure is elevated or the app holds ≥ 25 % of RAM | The largest measurable app holds ≥ max(1.5 GB, 10 % of RAM). Adds app-specific context (for example Brave: "Its tabs, extensions, and renderer processes may contribute to this usage. Consider enabling Memory Saver…"). |
| *App*'s memory keeps growing | Suggestion | See [Possible leaks](#possible-leaks). |
| Pressure is back to normal | Info | Pressure was elevated within the last 10 minutes. |
| High usage is normal here | Info | ≥ 75 % used, normal pressure, little swapping: "Your Mac is using most of its RAM, but memory pressure appears low. This is usually normal because macOS uses available memory efficiently." |
| Swap is allocated but quiet | Info | ≥ 256 MB swap in use, normal pressure, almost no swap writes: "…this doesn't necessarily mean your Mac is running low on memory. macOS may retain swapped-out inactive data after earlier demand." Recommends no action and says restarting isn't necessary. |
| Compression is saving memory | Info | ≥ 512 MB compressed at ≥ 1.5× with normal pressure. States that compression isn't a problem. |
| Pressure level not reported | Info | macOS didn't report a level. |

Each insight carries its evidence (the values it used, each tagged Measured / Derived /
Estimate), shown under "Why am I seeing this?".

### App-specific context

`KnownApplications` matches **bundle identifiers** (and one exact executable name for the
Virtualization framework's VM service), never substrings of process names. Browsers get context
about tabs, extensions, and renderer processes plus their own memory-saving feature where one
exists; Electron-style apps are told that several helper processes add up; Safari is explained
honestly (its web content runs in shared WebKit processes RamLume can't attribute to Safari).

## Possible leaks

`ProcessGrowthTracker` follows the 15 largest app groups across process scans and flags a group
only when **all** of these hold within the last hour:

- at least 8 observations spanning at least 20 minutes;
- growth of at least 1 GB **and** at least 50 % of the starting size (medians of the first and
  last three observations, to resist outliers);
- at least 70 % of steps don't decrease;
- no temporary decline larger than 15 % of the overall growth.

A drop to below half of the previous value is treated as a relaunch and restarts the series. The
resulting insight says the growth "can be expected for some workloads… but it can also be a sign
of a memory leak", and suggests saving work and reopening the app only if it becomes slow.

## Notifications

Off until the user turns them on (macOS permission is requested at that moment). Each type can
be disabled individually. Conditions are only evaluated while macOS reports that permission is
granted — RamLume re-checks when it becomes active and again right before posting — so an alert
that couldn't have been shown (for example at launch, before the permission check finishes) is
never recorded as sent.

| Notification | Condition | Repeats at most |
|---|---|---|
| Critical memory pressure | macOS reports critical pressure | every 15 minutes |
| Sustained memory pressure | Warning or worse for ≥ 5 minutes (time at warning and critical counts together) while the [swap test](#the-swap-test) passes | hourly |
| Rapid swap growth | Swap use grew ≥ 2 GB within the current 15-minute segment | hourly |
| Steady app memory growth (off by default) | A [possible-leak](#possible-leaks) finding | every 6 hours per app |

Rules that keep notifications rare:

- A fixed RAM percentage never triggers a notification.
- Each condition notifies once per *episode*; it must clear before it can notify again, and
  the cooldown above still applies across episodes.
- Non-critical notifications are spaced at least 10 minutes apart; one that arrives too soon is
  held back, not dropped.

Clicking a notification opens the dashboard's Insights page.

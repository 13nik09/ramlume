# Building, signing, and releasing

## Requirements

- macOS 14 Sonoma or later to run RamLume.
- Xcode 26 or later to build (developed with Xcode 27.0); the layered app icon uses the Icon
  Composer format, which older Xcode versions can't compile. The project uses Swift 6 language
  mode and Xcode's folder-synchronized groups, so new files added under `RamLume/` or
  `RamLumeTests/` are picked up automatically.
- No package dependencies.

## Build and run

Open `RamLume.xcodeproj`, choose the **RamLume** scheme and **My Mac**, and press ⌘R. RamLume
appears in the menu bar (it has no Dock icon until you open a window).

From the command line:

```bash
xcodebuild -project RamLume.xcodeproj -scheme RamLume -configuration Debug build
xcodebuild -project RamLume.xcodeproj -scheme RamLume -configuration Debug test
```

## Release archive

```bash
scripts/make-release.sh
```

builds a universal (Apple silicon + Intel) Release, checks it, and writes
`dist/RamLume-<version>-macOS.zip` plus a `.sha256` file. The script refuses to package a build
that isn't universal, contains code-coverage instrumentation or debug-only code, or whose
`--dump-metrics` self-check fails. Without signing credentials the archive is **ad-hoc signed and
not notarized**; the script says so in its output.

## Configuration

Everything you're likely to change lives in `Configuration/Base.xcconfig`:

| Setting | Default | Notes |
|---|---|---|
| `RAMLUME_BUNDLE_ID_PREFIX` | `io.github.13nik09` | The official builds are `io.github.13nik09.RamLume`. If you distribute your own modified build, use a prefix you control so it doesn't share preferences, notification permission, or a login item with the official app. |
| `MARKETING_VERSION` | `0.1.1` | The release version. |
| `CURRENT_PROJECT_VERSION` | `2` | The build number; increase it for every published build. |
| `CODE_SIGN_IDENTITY` | `-` (ad-hoc) | Leave as is; `make-release.sh` re-signs with your Developer ID (below). |
| `DEVELOPMENT_TEAM` | empty | Your Team ID, if you sign in Xcode. |

Machine-specific overrides belong in `Configuration/Local.xcconfig`, which is optional and
ignored by git. Copy `Configuration/Local.xcconfig.example` to start.

Changing the bundle identifier gives RamLume a new preferences domain, so settings start fresh;
history lives under `~/Library/Application Support/RamLume` and is kept.

## Signing and notarization

Ad-hoc signing ("Sign to Run Locally") is enough to build and run RamLume on your own Mac.
Builds made that way are **not notarized**: on other Macs, Gatekeeper stops the first launch
and people have to allow it in System Settings › Privacy & Security (the README explains how).
To ship a build that opens without that step you need:

1. **An Apple Developer Program membership** (paid, yearly).
2. **A "Developer ID Application" certificate** in your login keychain. Create it in Xcode
   (Settings › Accounts › Manage Certificates › + › Developer ID Application) or on
   developer.apple.com. Check that it's installed:
   ```bash
   security find-identity -v -p codesigning
   ```
3. **A notarytool keychain profile**, created once with an app-specific password
   (appleid.apple.com › Sign-In and Security › App-Specific Passwords):
   ```bash
   xcrun notarytool store-credentials ramlume --apple-id you@example.com --team-id TEAMID
   ```

Then build, sign, notarize, staple, and package in one step:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=ramlume scripts/make-release.sh
```

The script signs with the hardened runtime and a secure timestamp (both required for
notarization), submits the archive with `notarytool`, staples the ticket to the app, verifies it
with `spctl`, and only then writes the final zip and checksum. If Apple rejects the submission,
it prints the command that shows Apple's log.

RamLume needs no entitlements and no App Sandbox exceptions. The Release configuration enables
the hardened runtime; Debug builds don't, so unit tests can be injected into the app.

Only describe a release as notarized when the script reported
"Developer ID signed and notarized" for that exact archive. You can double-check a downloaded
copy with `spctl --assess --type execute -vv /Applications/RamLume.app`: a notarized build reports
`source=Notarized Developer ID`; an ad-hoc build is `rejected`.

## Publishing a release on GitHub

1. Update `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`, `CHANGELOG.md`, and the release notes
   in `docs/release-notes/`.
2. Run `scripts/make-release.sh` (with signing credentials if you have them).
3. Commit, tag (`git tag -a v0.1.0 -m "RamLume 0.1.0"`), and push the tag.
4. Create a release for the tag, paste the release notes with the checksum from
   `dist/RamLume-<version>-macOS.zip.sha256`, and attach the zip.

## Diagnostics for bug reports

```bash
/Applications/RamLume.app/Contents/MacOS/RamLume --dump-metrics
```

prints one reading with every raw kernel value and each formula, then exits.

## Console messages you can ignore

When RamLume runs from Xcode, macOS logs messages such as `Error registering app with intents
framework`, `Unable to get synchronousRemoteObjectProxy`, and `Unable to re-register with Process
Instance Registry`, all with `NSCocoaErrorDomain Code=4097` and `com.apple.linkd.autoShortcut`.
They come from macOS registering every app with its App Intents service and being refused; a
minimal AppKit app with no App Intents logs exactly the same lines. RamLume doesn't use App Intents
(the build already skips App Intents metadata), and the messages don't affect it. There's no
supported setting to turn the registration off, so RamLume leaves it alone.

## Debug-only launch arguments

Debug builds accept a few arguments for screenshots, testing, and performance measurements.
They're compiled out of Release builds (`make-release.sh` checks this).

| Argument | Effect |
|---|---|
| `--dashboard <section>` | Opens the dashboard at `home`, `applications`, `recommendations`, or `advanced`. |
| `--advanced-page <page>` | With `--dashboard advanced`: opens `memory`, `history`, `events`, or `definitions`. |
| `--settings <tab>` | Opens Settings at `general`, `monitoring`, `notifications`, `history`, or `about`. |
| `--panel` | Opens the menu bar panel. |
| `--panel-window` | Shows the panel's content in a title-less window, which renders even when the menu bar isn't on screen (for example in a full-screen Space). |
| `--demo` | Example data for screenshots (`RamLume/Debug/DemoData.swift`): no history file is read or written, and no notifications are sent. |
| `--no-activate` | Opens windows without activating RamLume or adding it to the Dock, so automated screenshots and stress runs don't take keyboard focus or flicker a Dock icon. |
| `--front` | Floats windows above other apps without activating RamLume. |
| `--no-mouse` | Windows ignore the pointer, so hover doesn't affect measurements. |
| `--assume-visible` | Treats the dashboard as on screen even when it's covered or on another Space. |
| `--pressure-events-only` | Ignores the pressure sysctls, to exercise the fallback to dispatch events alone. |
| `--test-notification` | Runs the "Allow notifications" flow and sends a test notification, printing the result. |
| `--login-item on\|off\|status` | Calls the same code as the "Open RamLume at login" toggle and prints the resulting state. |
| `--open-close-cycles <n>` | Opens and closes the dashboard *n* times, cycling through its sections, for leak checks. |
| `--hover-lab [scenario prefix]` | Runs the chart hover scenarios in an invisible window (see `RamLume/Debug/HoverLab.swift`); used by `HoverLoopRegressionTests`. |
| `--ui-stress <cycles>` | Repeats the dashboard lifecycle (every section and range, hover, appearance, pause, sleep/wake, pressure flapping) and reports CPU, memory, redraws, main-thread stalls, and whether each closed dashboard was released, per cycle (`RamLume/Debug/UIStress.swift`). |
| `--soak <minutes>` | Keeps History visible with live sampling and periodic hover; reports once a minute. |
| `--events-probe` | Shows the Events section with timelines of 5 to 300 events; used by `DashboardLifecycleTests`. |
| `--processes-probe` | Shows Processes with scripted process lists that change one way per scan, and marks each step, to tie AppKit table warnings to a kind of change. |
| `--history-file <path>` | Reads and writes history at `path` instead of `~/Library/Application Support/RamLume`. |
| `--no-status-item` | Runs without a menu bar item, so long stress runs don't flicker one. |

The hover lab, `--ui-stress`, `--soak`, both probes, and any run with `--history-file` are
*harness runs*. They don't hand off to a running copy of RamLume, start from default settings
kept in a separate `<bundle identifier>.debug-harness` domain (cleared at every launch), and,
without `--history-file`, keep history in memory only: the stress runs record made-up events, so
they never touch your real settings or history file. `RAMLUME_STRESS_HOLD_SECONDS=<n>` keeps a
`--ui-stress` or `--soak` process idle for *n* seconds after its report, for `leaks`, `heap`, or
`vmmap`.

`scripts/measure-usage.sh [seconds]` reports RamLume's CPU time and memory footprint over a
period; see [performance.md](performance.md) for the methodology.

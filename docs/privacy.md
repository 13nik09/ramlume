# Privacy

RamLume runs entirely on your Mac.

- **No network access.** RamLume makes no network requests: no analytics, telemetry, crash
  reporting, update checks, or cloud services. It contains no networking code. The "View on
  GitHub" and "Report an Issue" links open your web browser; RamLume itself sends nothing.
- **No account.** There is nothing to sign up for.
- **No elevated privileges.** RamLume never asks for an administrator password, Full Disk Access,
  Accessibility access, or Screen Recording. Processes owned by macOS or other users are listed
  as *Restricted* rather than worked around.
- **No App Sandbox.** RamLume is distributed outside the Mac App Store and isn't sandboxed,
  because sandboxed apps can't read other processes' memory footprints. It uses this only to read
  memory statistics, process names, and executable paths, plus the name and icon of the app
  bundle a process belongs to (from that bundle's `Info.plist`), so it can label processes. It
  doesn't read documents or any other data.

## What RamLume stores

| Data | Where | Contents |
|---|---|---|
| Memory history | `~/Library/Application Support/RamLume/History.json` | Aggregated memory statistics (used, compressed, swap, pressure level, swap activity) and an event timeline (pressure changes, sleep/wake, pauses). **No app or process names.** Under 2 MB even with a week of history. |
| Preferences | `~/Library/Preferences/io.github.13nik09.RamLume.plist` | Your settings. |

Process lists are kept in memory only and never written to disk.

History is plain JSON, so you can inspect it. Settings › History › Clear History… deletes it;
deleting the folder above has the same effect. The retention setting (1 hour, 24 hours, or
7 days) limits how much is kept: older statistics and events are dropped each time history is
saved.

## Permissions RamLume may ask for

| Permission | When | Why |
|---|---|---|
| Notifications | Only when you turn notifications on in Settings | To alert you about the conditions you choose. "Send Test Notification" in Settings shows what one looks like. |
| Login item | Only when you enable "Open RamLume at login" | Registered with `SMAppService`; manage it in System Settings › General › Login Items. |

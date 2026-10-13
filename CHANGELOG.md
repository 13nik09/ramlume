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

### Notes

- Release archives are ad-hoc signed and **not notarized** unless a release says otherwise.
- The current pressure level is read from `kern.memorystatus_vm_pressure_level`, which Apple
  doesn't document; see [docs/memory-metrics.md](docs/memory-metrics.md) for why and for the
  fallback.

[0.1.0]: https://github.com/13nik09/RamLume/releases/tag/v0.1.0

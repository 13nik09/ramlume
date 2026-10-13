# Roadmap

RamLume 0.1 focuses on accurate measurement, honest explanations, and a light footprint. These
are candidates for future releases, roughly in priority order. Nothing here is promised.

## 0.2

- **Signed, notarized releases** with a Developer ID, published on GitHub Releases, and an
  in-app "What's new" note. (0.1 builds are ad-hoc signed and not notarized.)
- **Optional update check** that is off by default and clearly explained, or documented
  instructions for package managers instead.
- **Localization** (the UI is English-only in 0.1; strings are ready to move into a string catalog).
- **Per-app history**: footprint charts for an app group over the last hour, using the samples
  the leak heuristic already collects.
- **Smarter insight tuning** using thresholds scaled by installed memory (8 GB vs. 64 GB Macs),
  validated against more machines.
- **Validation on more hardware**, especially Intel Macs and machines with 8 GB of memory, and
  documenting any differences from Activity Monitor found there.
- **Keyboard-driven panel navigation** and a global shortcut to open the panel.

## Later

- Widgets (WidgetKit) for the desktop and Notification Center.
- Exporting history as CSV.
- A "focus" view that compares memory before and after quitting an app.
- An accessibility pattern (texture) option for the composition bar and stacked chart, for
  print and color-vision-deficiency use.
- Shortcuts / App Intents actions ("Get memory pressure", "Get largest app").

## Explicitly not planned

- "RAM cleaner" or "free memory" buttons. Purging caches or forcing memory into swap makes Macs
  slower, not faster.
- Killing processes from RamLume.
- Anything that requires administrator privileges for baseline functionality.
- Accounts, analytics, telemetry, or cloud features.

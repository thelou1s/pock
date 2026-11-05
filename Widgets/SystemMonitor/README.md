# System Monitor (Pock widget)

A [Pock](https://github.com/pock/pock) widget that keeps an eye on your system
right from the Touch Bar: **CPU**, **memory** and **disk** usage, each with an
icon, the current percentage and a small usage bar.

- Values are colour coded: white under 60%, orange under 85%, red above.
- Tap an item to open the most useful app for that metric
  (Activity Monitor for CPU and memory, System Settings › General › Storage
  for the disk).
- Long press any item to toggle the usage bars for a compact, numbers-only look.
- CPU usage is sampled from the host's tick counters, memory usage matches
  Activity Monitor's "Memory Used" and disk usage reflects the root APFS volume.

## Requirements

- macOS 11.0 or later
- [Pock](https://pock.app) installed

## Build & install

```bash
cd Widgets/SystemMonitor
make install
```

This resolves dependencies with CocoaPods, builds the `SystemMonitor.pock`
bundle and copies it to `~/Library/Application Support/Pock/Widgets/`.

## Settings

Open Pock's widget manager and select **System Monitor** to configure:

- which items are shown (CPU / Memory / Disk, icons and usage bars)
- the refresh interval, from 1 to 10 seconds (default: 2 seconds)

The interval can also be set from the command line, e.g.
`defaults write com.pigigaldi.pock refreshInterval -int 5`.

## Project layout

```
Widgets/SystemMonitor/
├── Makefile
├── Podfile
└── SystemMonitor/
    ├── Info.plist
    └── Sources/
        ├── SystemMetrics.swift               # CPU / memory / disk samplers
        ├── Preferences.swift                 # user preferences
        ├── MetricItem.swift                  # single metric item (icon + % + bar)
        ├── SystemMonitorWidget.swift         # PKWidget entry point
        └── PreferencesPane/                  # settings pane (nib based)
```

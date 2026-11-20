# System Monitor (Pock widget)

A [Pock](https://github.com/pock/pock) widget that keeps an eye on your system
right from the Touch Bar: **CPU**, **memory** and **disk** usage plus the **CPU
temperature**, each with an icon, the current reading and a small usage bar.

- Values are colour coded: white under 60%, orange under 85%, red above. For the
  temperature the same thresholds mean 60 °C and 85 °C.
- Tap an item to open the most useful app for that metric
  (Activity Monitor for CPU, memory and temperature, System Settings › General ›
  Storage for the disk).
- Long press any item to toggle the usage bars for a compact, numbers-only look.
- CPU usage is sampled from the host's tick counters, memory usage matches
  Activity Monitor's "Memory Used", disk usage reflects the root APFS volume and
  the temperature comes from the System Management Controller.

## CPU temperature

The reading is taken through the `AppleSMC` user client, which needs no root
privileges and no entitlements and does not shell out to any helper tool. The key
list is enumerated once, in the background (about half a second on an M1), and
every refresh then re-reads only the sensors found by that scan.

Apple does not name the sensors, so the number is derived:

1. `TC0P`, the CPU package sensor. That is the key the `istats` command line tool
   reports as "CPU temp", so on an Intel Mac the two agree.
2. Otherwise the hottest of the CPU core sensors (`Tp…` for the performance
   cores, `Te…` for the efficiency cores). Apple Silicon publishes no `TC0P`, so
   on an M-series Mac this is the path taken.

Values outside 10…115 °C are treated as a register that happens to start with
`T`, not as a sensor. `Tg…` (GPU), `TH…` (SSD) and `TB…` (battery) are other
parts and are not mixed in. The interface is undocumented, so on a machine that
does not expose it the temperature item simply shows `--` instead of affecting
the other items.

### Cross-checking it

- `sudo powermetrics --samplers smc | grep -i "CPU die"` prints Apple's own CPU
  number. On an M1 it tracks this widget within a degree or two, because both
  report the hottest point of the die.
- `istats cpu` is only useful on Intel Macs: it reads `TC0P` and decodes it as an
  `sp78` value. Neither exists on Apple Silicon — there is no `TC0P` key and no
  `sp78` typed key at all on an M1 — so `istats` prints `0.0° C` there rather
  than a temperature this widget disagrees with.

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

- which items are shown (CPU / Memory / Disk / CPU temperature, icons and usage bars)
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
        ├── Temperature.swift                 # CPU temperature through AppleSMC
        ├── Preferences.swift                 # user preferences
        ├── MetricItem.swift                  # single metric item (icon + reading + bar)
        ├── SystemMonitorWidget.swift         # PKWidget entry point
        └── PreferencesPane/                  # settings pane (nib based)
```

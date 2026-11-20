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
  the temperature comes from the CPU core sensors Apple publishes on the HID bus.

## CPU temperature

The reading comes from the sensors Apple itself labels as CPU. Every Apple
Silicon Mac publishes its core temperatures on the HID event bus under names such
as `pACC MTR Temp Sensor3`, one per performance and efficiency core, and the
widget shows the hottest of them — the same rule the open-source monitor
[Hot](https://github.com/macmade/Hot) uses. That interface is not part of the
public SDK, so its functions are looked up in IOKit at run time; nothing is
shelled out to and no third-party library is linked.

The event bus needs no root privileges and no entitlements, and a reading costs
about 10 ms, so it is taken on every refresh. A machine that publishes no such
sensor falls back to the `AppleSMC` user client: first the package key `TC0P`,
then the hottest CPU core key (`Tp…` for the performance cores, `Te…` for the
efficiency ones). That fallback enumerates the key list once, in the background
(about half a second on an M1), and every refresh then re-reads only what that
scan found.

Both interfaces are undocumented, so the number is filtered rather than trusted:

- Only sensors named `pACC…`/`eACC…` count as CPU on the event bus; the other
  temperature services there are battery, charger and ports.
- Only keys `TC0P`, `Tp…` and `Te…` count as CPU on the SMC. `TC…`/`Tc…` are left
  out because they republish other sensors instead of measuring a core, and
  `Tg…` (GPU), `TH…` (SSD) and `TB…` (battery) are other parts.
- Readings outside 10…115 °C (SMC) or 0…120 °C (event bus) are treated as a
  register that happens to start with `T`, not as a temperature.

On a machine where neither interface is available the temperature item simply
shows `--` instead of affecting the other items.

### Cross-checking it

- [Hot](https://github.com/macmade/Hot) is the closest comparison, because this
  widget deliberately copies its rule: the hottest `pACC`/`eACC` sensor. The two
  numbers agree, within the fraction of a second between their refreshes.
- `sudo powermetrics --samplers smc | grep -i "CPU die"` prints Apple's own CPU
  number. It runs hotter than the core sensors because it is sampled under load
  by a privileged tool, but the two track each other.
- `istats cpu` is only useful on Intel Macs: it reads the key `TC0P` and decodes
  it as an `sp78` value. Neither exists on Apple Silicon — there is no `TC0P` key
  and no `sp78` typed key at all on an M1 — so `istats` prints `0.0° C` there
  rather than a temperature this widget disagrees with.
- To see the readings as the widget takes them, enable its tracer:
  `defaults write com.pigigaldi.pock smTickLog -bool true`, then
  `tail -f /tmp/systemmonitor-ticks.log` prints a `celsius=…` line per refresh.

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
        ├── Temperature.swift                 # CPU temperature (HID sensors, SMC fallback)
        ├── Preferences.swift                 # user preferences
        ├── MetricItem.swift                  # single metric item (icon + reading + bar)
        ├── SystemMonitorWidget.swift         # PKWidget entry point
        └── PreferencesPane/                  # settings pane (nib based)
```

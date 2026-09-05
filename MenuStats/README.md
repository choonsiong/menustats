# MenuStats

A native macOS menu bar app that shows live CPU, memory, temperature, and network stats. No dependencies, no Dock icon, no Xcode project — just Swift Package Manager and the system frameworks.

By default it sits in the menu bar as a single small icon. Clicking it opens a panel with history graphs, a breakdown of each metric, top processes, per-interface network detail, and every thermal sensor the machine exposes. Hovering shows a summary tooltip without opening anything.

If you would rather read the numbers at a glance, Settings → Menu bar → **Show stats as text** switches to the inline form:

```
CPU 14%  MEM 62%  ↓1.4M ↑210K  58°C
```

and the Text Segments toggles below it control which of those four appear.

## Build

Requires macOS 12 or later and the Xcode command line tools (`xcode-select --install`).

```bash
cd MenuStats
chmod +x build.sh
./build.sh --install     # builds, copies to /Applications, launches
```

Or build without installing:

```bash
swift build -c release
./build.sh
open MenuStats.app
```

To stop it: click the menu bar item → Settings is at the bottom, Quit below it. Or `pkill -x MenuStats`.

## What it measures

**CPU** — per-core tick counters from `host_processor_info`, sampled as deltas between refreshes. This is the same source Activity Monitor uses, so numbers should match closely. The menu shows user/system/idle split, 1/5/15-minute load averages, and the top five processes by CPU.

**Memory** — `host_statistics64`. "Used" is app memory + wired + compressed, which is how Activity Monitor defines it, so the percentage lines up with what you see there. Swap usage and memory pressure come from sysctl.

**Temperature** — two different paths depending on the machine:

- Apple Silicon reads the HID thermal sensors (`pACC`/`eACC`/`SOC` clusters, GPU, battery, and so on). CPU temperature is the average of the performance and efficiency core sensors.
- Intel reads SMC keys (`TCXC`, `TC0D`, `TC0P`, `TG0D`, ambient, palm rest, battery).

Fan RPM is read from the SMC on both. If nothing is available, the temperature section hides itself and the menu bar just omits that segment — no crash, no placeholder.

**Network** — per-interface byte counters from `getifaddrs`, converted to a rate using the actual elapsed time between samples. Loopback, VPN tunnels, AWDL, and bridge interfaces are excluded so traffic isn't double counted. Counters are 32-bit and wrap at 4 GB; deltas use wrapping subtraction so the roll is handled correctly.

## Settings

In the menu, under Settings:

- Menu bar: icon only (default) or stats as text
- Which text segments appear, when in text mode
- Update interval: 1, 2, 5, or 10 seconds
- Network in bytes or bits (Mbps)
- Celsius or Fahrenheit
- Launch at Login (macOS 13+, uses `SMAppService`)

Everything persists in `UserDefaults` under the `com.local.menustats` domain.

## Notes and caveats

**Temperature may be unavailable.** The Apple Silicon path uses `IOHIDEventSystemClient`, which isn't a public API. The symbols are resolved with `dlsym` at runtime, so if Apple changes or restricts them in a future macOS release the app degrades gracefully instead of failing to launch. Some VMs and older Intel models expose no usable keys at all.

**Gatekeeper.** The build script signs ad-hoc, which is enough to run locally. If macOS complains, right-click the app → Open, or run `xattr -dr com.apple.quarantine MenuStats.app`.

**Top processes** shell out to `/bin/ps`, and only while the menu is open. Background sampling never spawns a process.

**Cost.** At the 2-second default the app sits well under 1% CPU. Sensor reads happen on a background queue so the menu bar never stutters.

## Layout

```
Package.swift
Resources/Info.plist            bundle metadata, LSUIElement
build.sh                        compile + bundle + sign
Sources/MenuStats/
  main.swift                    entry point, accessory activation policy
  AppDelegate.swift             status item, menu, refresh loop
  Settings.swift                UserDefaults wrapper
  Support.swift                 sysctl helpers, formatters
  Monitors/
    CPUMonitor.swift
    MemoryMonitor.swift
    NetworkMonitor.swift
    TemperatureMonitor.swift    HID sensors + SMC dispatch
    SMC.swift                   read-only SMC client
    ProcessMonitor.swift
  Views/
    SparklineView.swift         history graphs in the menu
```

## Extending it

The monitors are independent and each expose a single `read()` returning a value struct, so adding disk I/O (`IOKit` block storage statistics) or battery detail (`IOPowerSources`) means writing one more monitor and one more menu section. The status bar string is assembled in `updateStatusBar`, which is the one place to touch if you want a different format.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

The Swift package lives in `MenuStats/`, not at the repository root. Paths and commands below are relative to `MenuStats/` unless they say otherwise.

## What this is

MenuStats is a macOS menu bar app that displays live CPU, memory, temperature, and network statistics. It is written in Swift against AppKit and the Darwin/IOKit C APIs, with **zero third-party dependencies**. There is no Xcode project — it builds with Swift Package Manager and a shell script assembles the `.app` bundle.

By default the menu bar shows a single icon; clicking it opens a menu containing all the detail. A setting switches the menu bar to inline text (`CPU 14%  MEM 62%  ↓1.4M ↑210K  58°C`).

- Deployment target: macOS 12
- Swift tools version: 5.7
- Bundle identifier: `com.local.menustats`
- Runs unsandboxed, as an accessory app (`LSUIElement`, no Dock icon)

## Commands

```bash
cd MenuStats                      # swift build fails from the repository root
swift build                       # debug build, fastest way to check it compiles
swift build -c release            # release build
./build.sh                        # release build + assemble MenuStats.app + ad-hoc sign
./build.sh --install              # the above, then copy to /Applications and launch
pkill -x MenuStats                # stop a running instance
defaults delete com.local.menustats   # reset all preferences
```

After `--install`, the previous instance is killed and the app relaunches, so this is the normal edit-test loop.

There is no test target, so `swift test` stops with "no tests found", and no linter or formatter is configured. Verification is `swift build` plus the manual checklist at the bottom.

## Branches and releases

`main` is protected by a GitHub ruleset: no direct pushes, no force pushes, no deletion. Every change goes on a `feat/`, `fix/`, `enhance/`, `docs/`, or `chore/` branch and lands through a pull request.

After a merge, tag `main` with the next version and push the tag (`git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z`): a minor bump if a `feat/` branch merged, a patch bump otherwise. `.github/workflows/release.yml` at the repository root then publishes the "vX.Y.Z release" GitHub release with generated notes, and fails on a tag that isn't on `main`. Nothing is built or attached, so a release is not a deploy. It is the only workflow, so nothing builds pull requests either: the only check on a change is what you run locally.

## Hard constraint: this only builds on macOS

Every monitor calls a Darwin, Mach, or IOKit API. The package will not compile on Linux and there is nothing to stub out. If you are running in a container without a Swift toolchain and macOS SDK:

- Do not attempt `swift build` and do not report success or failure of a build you did not run.
- Write the change, then tell the user to run `./build.sh --install` and report what happened.
- Be conservative about C interop details you cannot verify — struct layouts, pointer lifetimes, and imported type widths are the things that break, and they break at compile time or with silently wrong numbers.

## Architecture

A single `Timer` drives everything:

```
Timer (RunLoop .common, interval from Settings)
  └─ AppDelegate.refresh()
       ├─ CPUMonitor.read()      → CPUUsage      ┐
       ├─ MemoryMonitor.read()   → MemoryUsage   ├─ cached in lastCPU / lastMemory / lastNetwork
       ├─ NetworkMonitor.read()  → NetworkUsage  ┘
       ├─ refreshTemperature()   → background queue → TemperatureReading
       ├─ updateStatusBar(...)   → NSStatusItem button (icon or text) + tooltip
       └─ updateMenu(...)        → only when the menu is open
```

`ProcessMonitor` is not on this path. It shells out to `/bin/ps` on a background queue, and only when the menu opens.

`Sources/MenuStats/AppDelegate.swift` is everything UI (status item, menu construction, refresh loop, actions) and the only large file. `main.swift` is top-level code, so there is no `@main`. `Support.swift` holds the `Sysctl` helpers and the `Fmt` formatters. `TemperatureMonitor` uses HID sensors on Apple Silicon and the SMC on Intel, and reads fan RPM from the SMC on both.

## Conventions

**Monitors are independent and uniform.** CPU, memory, and network each expose a `read()` returning a plain value struct, marked `@discardableResult`, and own their history capped at 60 samples. `TemperatureMonitor` keeps no history, and `ProcessMonitor` is a stateless enum of static functions. A monitor never touches UI and never reads `Settings`. Unit conversion and display formatting happen in the view layer.

**All formatting goes through `Fmt`.** Never inline a `String(format:)` for bytes, rates, percentages, or temperature in `AppDelegate`. The one deliberate exception is per-process CPU, which can exceed 100% across cores and so must not use `Fmt.percent` (it clamps).

**Settings are read at draw time, never cached.** Add a preference by adding a key, a registered default, and a computed property in `Settings.swift`, in that order.

**Menu items are created once and mutated.** `buildMenu()` runs a single time. Variable-length sections (top processes, network interfaces, sensors) use a fixed pool of pre-created items that get `isHidden` toggled — the exception is the sensors submenu, which is cheap to rebuild and is cleared with `removeAllItems()` each update. Do not insert or remove items from the main menu at runtime; the stored item references are what the update path writes into.

**`menu.autoenablesItems = false`.** Consequence: every interactive item must set `isEnabled = true` explicitly, including items that only carry a submenu. Informational rows are left disabled so they render grey.

**Menu rows use `configure(_:label:value:indented:)`.** Secondary-colour label, monospaced-digit value. Section titles use `header(_:)`. Don't hand-roll attributed strings for new rows.

**Actions dispatch on `sender.tag`,** not on title comparison. Current maps: display segments `1=CPU 2=Memory 3=Network 4=Temperature`; menu bar mode `1=icon only 2=text`; interval tag is the number of seconds; units `1=bits 2=Fahrenheit`.

**Comments explain *why*, not *what*.** The existing comments mark non-obvious platform behaviour. Keep that bar; don't narrate ordinary code.

## Non-obvious decisions worth preserving

**The timer is added to `RunLoop.main` in `.common` mode.** A default-mode timer stops firing while a menu is being tracked, which would freeze the graphs exactly when the user is looking at them.

**`refresh()` samples; `redraw()` repaints from `lastCPU` / `lastMemory` / `lastNetwork`.** Anything triggered by user interaction — opening the menu, flipping a setting — must call `redraw()`. Calling `refresh()` there would take a delta over a few milliseconds and push a meaningless value into the history graph.

**Counters are primed in `applicationDidFinishLaunching`.** CPU and network both need a baseline; the first `read()` after launch is discarded by design.

**Temperature runs on a background queue** guarded by `temperatureBusy`, because the HID sensor sweep can take tens of milliseconds. The result lands in `self.temperature` on the main thread. `TemperatureMonitor.read()` is blocking — never call it from the main thread.

**The status icon is a template image.** That is what makes it tint correctly in light mode, dark mode, and while the menu is highlighted. If you replace the icon, keep `isTemplate = true` and draw in black.

**The menu bar text has a constant width.** `statusTitle(_:)` puts each segment on tab stops: a left stop where the label starts and a right stop where the value ends, sized from the widest value the segment can show (`Fmt.percent(100)`, `Fmt.widestShortRates`, a 3-digit temperature). Readings can then change without resizing the item and pushing neighbouring menu bar items around. Only toggling segments or units changes the width. The label needs its own stop because a right stop aligns everything up to the next tab. This relies on `Fmt` never printing more than three digits (`1.0K`, not `1023B` or `100.0K`), so keep that guarantee if you touch `Fmt.scale`.

**The status item never renders empty.** If every text segment is switched off, `updateStatusBar` falls back to the icon; otherwise the item would collapse to zero width and become unclickable.

## Platform API landmines

**`SMC.ParamStruct` must stay exactly 80 bytes** and match the kernel's layout. The `padding: UInt16` field exists to push `result` to offset 40. `dataSize` is deliberately `UInt32` rather than `IOByteCount`, whose width varies. Changing field order or types silently breaks every SMC read — reads will return zeros or garbage rather than failing loudly.

**Apple Silicon temperatures use private API.** `IOHIDEventSystemClientCreate` and friends are not in the public headers. They are resolved with `dlsym` at runtime precisely so that a future macOS removing or restricting them degrades to "no sensors" instead of failing to link or crashing. Do not switch this to direct linkage, and keep every failure path returning an empty array. Event type 15 is temperature; the field constant is `15 << 16`.

**`if_data` byte counters are 32-bit and wrap at 4 GB.** Deltas use wrapping subtraction (`&-`), which stays correct across the roll as long as the interval is short. Values are read through `UInt32(truncatingIfNeeded:)` so the code does not depend on how the SDK types those fields. The 8 GB-per-interval `limit` is meant to absorb interface resets but cannot fire: a `UInt32` delta never exceeds about 4.3 GB, so a reset shows up as a one-sample spike and inflates the session totals.

**Interface filtering avoids double counting.** Loopback, VPN tunnels (`utun`, `ipsec`), AWDL, link-local, and bridges are excluded from the total. A VPN would otherwise be counted alongside the physical interface carrying it.

**Memory "used" is app + wired + compressed,** matching Activity Monitor's definition, where app memory is `internal_page_count - purgeable_count`. If the number stops agreeing with Activity Monitor, this formula is the place to look, not the page size.

**Mach `host_processor_info` allocates.** The `vm_deallocate` in the `defer` block is required; without it the app leaks a few hundred bytes per sample.

## Adding a new metric

1. Add `Sources/MenuStats/Monitors/XMonitor.swift` with a value struct and a `read()`, following the existing shape. Cap any history at 60, which is `SparklineView.capacity`.
2. Instantiate it in `AppDelegate`, sample it in `refresh()`, cache the result alongside `lastCPU`.
3. Add stored `NSMenuItem` properties, build the section in `buildMenu()` (header, optional `SparklineView`, rows), and populate it in `updateMenu(...)`.
4. If it belongs in the menu bar text, extend `updateStatusBar` and add a segment toggle with a new tag.
5. Add any preference to `Settings.swift` with a registered default.

Likely candidates, in rough order of usefulness: disk I/O via IOKit block storage statistics, battery detail via `IOPowerSources`, GPU utilisation, per-core CPU display (`CPUUsage.perCore` is already populated but unused).

## Manual test checklist

Run through this after any change to sampling or the status item:

- Numbers agree with Activity Monitor for CPU total and memory used.
- Network rates move when you start a download and return to near zero when idle.
- Graphs keep updating while the menu is held open.
- Temperature section appears on Apple Silicon and Intel, and hides itself entirely on hardware with no readable sensors rather than showing zeros.
- Switching between icon and text mode takes effect immediately and survives a relaunch.
- Changing the interval restarts the timer without leaving the old one running.
- Idle CPU cost stays well under 1% at the 2-second default.

## Known limitations

- No unit tests, and no practical way to add them for the C-interop layers without a Mac in CI.
- Temperature is unavailable in most VMs and on some older Intel models.
- Sampling is wall-clock; readings are skewed for one interval after waking from sleep.
- Session network totals reset on quit — they are not persisted.
- Ad-hoc signing means Gatekeeper may need `xattr -dr com.apple.quarantine MenuStats.app`.

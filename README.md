# MenuStats

A small native macOS menu bar app for live CPU, memory, network, and temperature stats. It is written in Swift against AppKit and the system frameworks, with no third-party dependencies and no Xcode project.

```
CPU 14%  MEM 62%  ↓1.4M ↑210K  58°C
```

## Features

- **CPU**: total and user/system/idle split, load averages, top processes
- **Memory**: used memory (as Activity Monitor defines it), app/wired/compressed breakdown, swap, and memory pressure
- **Network**: download and upload rates, totals since launch, and per-interface detail
- **Temperature**: CPU and GPU readings, every sensor the machine exposes (HID on Apple Silicon, SMC on Intel), and fan speeds
- History graphs for CPU, memory, and network inside the menu
- Icon-only or inline-text menu bar display. In text mode the item keeps a fixed width, so changing numbers don't push neighbouring menu bar items around
- Update interval of 1–10 seconds, bytes or bits, °C or °F, and Launch at Login (macOS 13+)

## Requirements

- macOS 12 or later
- Xcode command line tools (`xcode-select --install`)

## Install

```bash
git clone https://github.com/choonsiong/menustats.git
cd menustats/MenuStats
./build.sh --install
```

This compiles a release build, assembles and ad-hoc signs `MenuStats.app`, copies it to `/Applications`, and launches it. Run the same command after pulling changes; it replaces the running copy.

If Gatekeeper blocks the app, run `xattr -dr com.apple.quarantine /Applications/MenuStats.app`.

## Usage

MenuStats starts as a single icon on the right side of the menu bar. Click it for graphs and detail, or hover over it for a summary tooltip. To show the numbers in the menu bar itself, choose Settings → **Show stats as text**, then pick which segments appear under Text Segments.

- Quit from the bottom of the menu, or run `pkill -x MenuStats`
- Reset all preferences with `defaults delete com.local.menustats`
- Uninstall by quitting the app and deleting `/Applications/MenuStats.app`

## Documentation

- [MenuStats/README.md](MenuStats/README.md): how each metric is measured, every setting, and known caveats
- [CLAUDE.md](CLAUDE.md): architecture, conventions, and platform API notes for working on the code

## License

MIT. See [LICENSE](LICENSE).

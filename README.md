# noctalia-monitor-controls

A [Noctalia](https://github.com/noctalia-dev/noctalia) plugin exposing full DDC/CI monitor control through
[`ddcutil`](https://www.ddcutil.com/) -- not just brightness (which Noctalia already supports natively), but every
VCP feature the monitor reports: contrast, RGB gain, input source, audio volume/mute, and anything else, grouped by
category, per connected monitor.

Ported from a richer feature I originally built for [tama-shell](https://github.com/heprado/tama-shell)
(`shell/configuration/Monitor/MonitorSection.qml`), rewritten for Noctalia's Luau plugin runtime.

## Requirements

- `ddcutil` installed and on `PATH`.
- DDC/CI enabled in each monitor's own OSD menu (most monitors ship with this off by default).
- Your user typically needs `i2c-dev` access (e.g. in the `i2c` group) for `ddcutil` to talk to the monitor without
  root.
- `wlr-randr` installed and on `PATH` (only needed for the monitor arrangement grid — the DDC/CI
  controls work without it). Any compositor implementing `wlr-output-management-v1` is supported
  (Hyprland, Sway, river, ...); the arrangement screen shows an explanatory message instead of the
  grid when it's missing or unsupported.

## What it does

- A bar widget shows how many DDC/CI-capable monitors are detected; click it to open the controls panel.
- The panel lists every connected monitor and, for each, every VCP feature `ddcutil capabilities` +
  `ddcutil vcpinfo --verbose` report, classified into the right control automatically:
  - **Read Write, Continuous** -> slider (brightness, contrast, RGB gain, ...)
  - **Read Write, Non-Continuous with a value list** -> dropdown (input source, picture mode, ...)
  - **Write Only** -> trigger button
  - Everything else -> read-only text
  - Audio speaker volume (`62`) gets a mute toggle composited onto its slider from Audio mute (`8D`)
- A Refresh button re-runs `ddcutil detect` and re-reads every monitor's capabilities/values (nothing polls
  continuously -- DDC/CI queries are slow I2C round-trips).
- All writes are fire-and-forget `ddcutil setvcp` calls with an optimistic local update; a failed write surfaces a
  notification.
- Manufacturer-specific picture-mode names (e.g. ASUS's GameVisual presets) aren't known to `ddcutil` at all -- see
  [`monitor-controls/devices/`](monitor-controls/devices/README.md) for the community-contributed, per-model override
  files that fix this without touching any plugin code.

## Installing locally (development)

Drop the `monitor-controls/` directory into Noctalia's plugin data dir, matching the id after the slash:

```sh
git clone https://github.com/heprado/noctalia-monitor-controls.git
mkdir -p "$XDG_DATA_HOME/noctalia/plugins"
ln -s "$(pwd)/noctalia-monitor-controls/monitor-controls" "$XDG_DATA_HOME/noctalia/plugins/monitor-controls"
```

Then enable it once from Noctalia's plugin settings. `.luau` edits hot-reload automatically; `plugin.toml` changes
need a config reload.

## Installing as a source

This repo is laid out like `official-plugins`/`community-plugins` (a `catalog.toml` at the root, plugins in their own
subdirectory), so it can be added as a plugin source directly:

```sh
noctalia msg plugins source add heprado-monitor-controls git https://github.com/heprado/noctalia-monitor-controls
```

Then enable **Monitor Controls (DDC/CI)** from the plugin store.

## Status

First working version -- built and tested against the ddcutil parsing logic already proven in tama-shell, but not
yet run against real hardware through Noctalia itself. If a monitor's `capabilities`/`vcpinfo` output doesn't parse
the way it does on the ASUS VG278QR this was originally developed against, please open an issue with the raw
`ddcutil capabilities --verbose` / `ddcutil vcpinfo --verbose` output for that monitor.

# noctalia-monitor-settings

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
- `wlr-randr` installed and on `PATH`, for the arrangement canvas and display settings. Any compositor implementing
  `wlr-output-management-v1` is supported (Hyprland, Sway, river, ...). If it's missing or the compositor doesn't
  support it, the panel shows an explanatory message instead of the canvas, but the rest of the plugin (DDC/CI
  controls) still works. Adaptive sync needs version 4 of that protocol; on older compositors the toggle is disabled.

## What it does

- A bar widget shows how many DDC/CI-capable monitors are detected; click it to open the controls panel.
- **The panel opens on a monitor arrangement canvas**, in the style of `nwg-displays`: every output `wlr-randr`
  reports, drawn to scale (rotation and scale included) at its real position. Drag a monitor by its name chip to move
  it anywhere -- on release it snaps flush against the nearest edges of its neighbours, never overlaps one, and never
  floats off on its own (a gap between monitors is a dead zone the cursor can't cross). The X/Y fields below the
  canvas set an exact position.
- **Per-output display settings** for the selected monitor:
  - on/off (the last enabled output can't be switched off),
  - resolution and refresh rate, from the modes the output advertises,
  - rotation (all eight `wl_output` transforms, plus quick rotate buttons),
  - scale -- presets or any custom value -- and **DPI**: the monitor's physical and effective DPI (from its EDID
    size), plus a target-DPI field that derives the scale. Wayland has no per-monitor DPI separate from scale; scale
    *is* that setting,
  - **adaptive sync** (VRR -- what FreeSync and G-Sync Compatible are on Wayland), when the compositor can report it.
- Edits are a draft until **Apply**, which sends every change as **one atomic `wlr-randr` call**. A change limited to
  position/adaptive sync is kept right away; a riskier one (mode, scale, rotation, on/off) has to be confirmed within
  15 seconds or it's rolled back automatically -- the usual safety net for a mode the monitor can't show.
- Confirmed configs persist to the plugin's own data directory (`displays.json`, keyed by connector name) -- never to
  the compositor's own config, which on a Nix/home-manager setup is read-only -- and are reapplied automatically the
  next time Noctalia starts.
- The two halves are independent: no `wlr-randr` means no canvas but working DDC/CI controls (from a plain monitor
  list), and no `ddcutil` means working display settings without the DDC/CI section.
- Each monitor's settings screen lists every VCP feature `ddcutil capabilities` +
  `ddcutil vcpinfo --verbose` report, classified into the right control automatically:
  - **Read Write, Continuous** -> slider (brightness, contrast, RGB gain, ...)
  - **Read Write, Non-Continuous with a value list** -> dropdown (input source, picture mode, ...)
  - **Write Only** -> trigger button
  - Everything else -> read-only text
  - Audio speaker volume (`62`) gets a mute toggle composited onto its slider from Audio mute (`8D`)
- A Refresh button re-runs `ddcutil detect` and re-reads every monitor's capabilities/values, and re-reads
  `wlr-randr --json` so a monitor plugged in since the last scan shows up on the canvas (nothing polls
  continuously -- DDC/CI queries are slow I2C round-trips).
- All writes are fire-and-forget `ddcutil setvcp` calls with an optimistic local update; a failed write surfaces a
  notification.
- Manufacturer-specific picture-mode names (e.g. ASUS's GameVisual presets) aren't known to `ddcutil` at all -- see
  [`monitor-settings/devices/`](monitor-settings/devices/README.md) for the community-contributed, per-model override
  files that fix this without touching any plugin code.

## Installing locally (development)

Drop the `monitor-settings/` directory into Noctalia's plugin data dir, matching the id after the slash:

```sh
git clone https://github.com/heprado/noctalia-monitor-settings.git
mkdir -p "$XDG_DATA_HOME/noctalia/plugins"
ln -s "$(pwd)/noctalia-monitor-settings/monitor-settings" "$XDG_DATA_HOME/noctalia/plugins/monitor-settings"
```

Then enable it once from Noctalia's plugin settings. `.luau` edits hot-reload automatically; `plugin.toml` changes
need a config reload.

## Installing as a source

This repo is laid out like `official-plugins`/`community-plugins` (a `catalog.toml` at the root, plugins in their own
subdirectory), so it can be added as a plugin source directly:

```sh
noctalia msg plugins source add heprado-monitor-settings git https://github.com/heprado/noctalia-monitor-settings
```

Then enable **Monitor Settings (DDC/CI)** from the plugin store.

## Status

First working version -- built and tested against the ddcutil parsing logic already proven in tama-shell, but not
yet run against real hardware through Noctalia itself. If a monitor's `capabilities`/`vcpinfo` output doesn't parse
the way it does on the ASUS VG278QR this was originally developed against, please open an issue with the raw
`ddcutil capabilities --verbose` / `ddcutil vcpinfo --verbose` output for that monitor.

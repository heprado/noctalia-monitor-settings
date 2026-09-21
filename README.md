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
- `wlr-randr` installed and on `PATH`, for the monitor arrangement grid. Any compositor implementing
  `wlr-output-management-v1` is supported (Hyprland, Sway, river, ...). If it's missing or the
  compositor doesn't support it, the arrangement screen shows an explanatory message instead of the
  grid, but the rest of the plugin (DDC/CI controls) still works.

## What it does

- A bar widget shows how many DDC/CI-capable monitors are detected; click it to open the controls panel.
- **The panel opens on a monitor arrangement grid**: every output `wlr-randr` reports as a tile on a 3x3 grid of
  cells. Drag a tile to another cell to move that monitor relative to the others -- the new arrangement is applied
  live via `wlr-randr --pos`, and dropping onto a cell that's already occupied swaps the two. Select a tile and press
  **Configurações** to open that monitor's DDC/CI settings (below); a back arrow returns to the grid.
- The arrangement persists to the plugin's own data directory (`layout.json`, as cell assignments rather than raw
  pixel positions) -- never to the compositor's own config, which on a Nix/home-manager setup is read-only -- and is
  reapplied automatically the next time Noctalia starts.
- The two halves are independent: no `wlr-randr` means no grid but working DDC/CI controls, and no `ddcutil` means a
  working grid with the settings button disabled.
- Each monitor's settings screen lists every VCP feature `ddcutil capabilities` +
  `ddcutil vcpinfo --verbose` report, classified into the right control automatically:
  - **Read Write, Continuous** -> slider (brightness, contrast, RGB gain, ...)
  - **Read Write, Non-Continuous with a value list** -> dropdown (input source, picture mode, ...)
  - **Write Only** -> trigger button
  - Everything else -> read-only text
  - Audio speaker volume (`62`) gets a mute toggle composited onto its slider from Audio mute (`8D`)
- A Refresh button re-runs `ddcutil detect` and re-reads every monitor's capabilities/values, and re-reads
  `wlr-randr --json` so a monitor plugged in since the last scan shows up on the grid (nothing polls
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

Then enable **Monitor Controls (DDC/CI)** from the plugin store.

## Status

First working version -- built and tested against the ddcutil parsing logic already proven in tama-shell, but not
yet run against real hardware through Noctalia itself. If a monitor's `capabilities`/`vcpinfo` output doesn't parse
the way it does on the ASUS VG278QR this was originally developed against, please open an issue with the raw
`ddcutil capabilities --verbose` / `ddcutil vcpinfo --verbose` output for that monitor.

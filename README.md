# noctalia-monitor-settings

A [Noctalia](https://github.com/noctalia-dev/noctalia) plugin that opens **Monitor Settings**, a
[Quickshell](https://quickshell.org/) app for everything about your monitors:

- **Display arrangement** in the style of `nwg-displays`: a canvas with every output drawn to scale, dragged freely
  with the mouse, snapping flush against its neighbours.
- **Per-output display settings** through `wlr-randr`: on/off, resolution, refresh rate, rotation, scale, DPI and
  adaptive sync (FreeSync / G-Sync).
- **Full DDC/CI control** through [`ddcutil`](https://www.ddcutil.com/): not just brightness (which Noctalia already
  supports natively) but every VCP feature the monitor reports, including contrast, RGB gain, input source and audio
  volume/mute, grouped by category.

The app follows the **active Qt theme**: whatever `QT_QPA_PLATFORMTHEME` provides (hyprqt6engine, qt6ct, KDE, ...)
supplies its palette and fonts. With Noctalia's `qt` template on, it wears the Noctalia colors.

## Layout

```
monitor-settings/
  plugin.toml, widget.luau, launcher.luau, service.luau   Noctalia side: open the app, reapply at login
  lib/app.luau                                             how those entries launch/toggle the app
  app/                                                     the Quickshell app (qs -p monitor-settings/app)
    shell.qml                                              entry: window, IPC, headless "reapply" mode
    services/                                              Exec, I18n, DisplayService, DdcService, Draft
    components/                                            canvas, display settings, DDC/CI cards, apply bar
    lib/Displays.js, lib/Ddc.js                            pure parsing/layout logic
    tests/run.mjs                                          node tests for the two libs
  translations/                                            shared by the Noctalia entries and the app
  devices/                                                 per-manufacturer DDC/CI label overrides
```

The Noctalia plugin only launches the app:

- The **bar widget** and the **launcher result** ("monitor") toggle the window: an open window closes, otherwise
  one is started (`quickshell -p <plugin>/app -n`).
- The **service** runs the app once at startup in its headless `reapply` mode, which reapplies the saved display
  configuration and exits.

## Requirements

- `quickshell` on `PATH` (0.3 or newer).
- `wlr-randr` on `PATH`, and a compositor implementing `wlr-output-management-v1` (Hyprland, Sway, river, ...).
  Adaptive sync needs version 4 of that protocol; on older compositors the switch is disabled.
- `ddcutil` on `PATH` for the DDC/CI tab. DDC/CI also has to be enabled in each monitor's own OSD menu, and your user
  needs `i2c-dev` access (e.g. the `i2c` group).

Missing `ddcutil` only disables the DDC/CI tab; missing `wlr-randr` only disables the arrangement and display
settings.

## Using it

- **Arrangement:** drag a monitor anywhere on the canvas. While dragging, an outline shows where it will land. On
  release it snaps flush against the nearest edges, never overlaps another monitor, and never floats off on its own
  (a gap between monitors is a dead zone the cursor can't cross). Click a monitor to select it. Disabled outputs
  aren't on the canvas, so they're selected (and turned on) from the button row below it.
- **Display tab:** resolution and refresh rate come from the modes the output advertises. Rotation offers all eight
  `wl_output` transforms, plus quick rotate buttons. Scale takes a preset or any custom value. DPI shows the monitor's
  physical and effective DPI (from its EDID size), and a target-DPI field derives the scale from it. Wayland has no
  per-monitor DPI separate from scale: scale *is* that setting. X/Y set an exact position.
- **Apply:** edits are a draft until **Apply**, which sends every change as **one atomic `wlr-randr` call**.
  - Changes limited to position or adaptive sync are kept right away.
  - Riskier changes (mode, scale, rotation, on/off) must be confirmed within 15 seconds, or they're rolled back
    automatically.
- **Persistence:** confirmed configs are saved to `~/.local/share/quickshell/by-shell/heprado-monitor-settings/
  displays.json`, keyed by connector name. Nothing is written to the compositor's own config, which on a
  Nix/home-manager setup is read-only. They're reapplied at the next login.
- **DDC/CI tab:** shows the controls for the selected output's monitor. The output is matched to its `ddcutil`
  display by DRM connector, falling back to the model name. Every VCP feature that `ddcutil capabilities` +
  `ddcutil vcpinfo --verbose` report becomes the right control:
  - **Read Write, Continuous** → slider plus an exact value (brightness, contrast, RGB gain with a color gradient, ...)
  - **Read Write, Non-Continuous with a value list** → dropdown (input source, picture mode, ...)
  - **Write Only** → trigger button
  - everything else → read-only text
  - Audio speaker volume (`62`) gets a mute toggle from Audio mute (`8D`).

  Writes are `ddcutil setvcp` calls with an optimistic update; nothing polls, because DDC/CI queries are slow I2C
  round-trips. **Refresh** re-reads both outputs and monitors.
- Manufacturer-specific picture-mode names (e.g. ASUS's GameVisual presets) aren't known to `ddcutil` at all. See
  [`monitor-settings/devices/`](monitor-settings/devices/README.md) for the community-contributed per-manufacturer
  override files.

The window's app id (Hyprland's `class`) is `heprado.monitor-settings`, for a compositor rule that floats it.

## Installing locally (development)

Drop the `monitor-settings/` directory into Noctalia's plugin data dir, matching the id after the slash:

```sh
git clone https://github.com/heprado/noctalia-monitor-settings.git
mkdir -p "$XDG_DATA_HOME/noctalia/plugins"
ln -s "$(pwd)/noctalia-monitor-settings/monitor-settings" "$XDG_DATA_HOME/noctalia/plugins/monitor-settings"
```

Then enable it once from Noctalia's plugin settings. The app can also be run on its own while working on it, and
reloads on save:

```sh
quickshell -p monitor-settings/app
node monitor-settings/app/tests/run.mjs   # parsing/layout tests
```

## Installing as a source

This repo is laid out like `official-plugins`/`community-plugins` (a `catalog.toml` at the root, plugins in their own
subdirectory), so it can be added as a plugin source directly:

```sh
noctalia msg plugins source add heprado-monitor-settings git https://github.com/heprado/noctalia-monitor-settings
```

Then enable **Monitor Settings (DDC/CI)** from the plugin store.

## Status

The app has been exercised end to end under a headless Sway (real drag and drop, apply, confirm/auto-revert,
login reapply) with a stand-in `ddcutil`, but not yet on real hardware. If a monitor's `capabilities`/`vcpinfo`
output doesn't parse the way it does on the ASUS VG278QR this was originally developed against, please open an issue
with the raw `ddcutil capabilities --verbose` / `ddcutil vcpinfo --verbose` output for that monitor.

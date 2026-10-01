# Monitor Settings as a standalone package: the Quickshell app in
# monitor-settings/app, plus the translations/ and devices/ directories it
# reads from `Quickshell.shellDir + "/.."`, behind a `monitor-settings`
# command that does what the Noctalia entries do (see ../monitor-settings/
# lib/app.luau).
{
  lib,
  stdenvNoCC,
  writeShellApplication,
  symlinkJoin,
  makeDesktopItem,
  quickshell,
  wlr-randr,
  ddcutil,
  coreutils,
}:

let
  version = "2.0.0";

  # Same layout as the plugin directory, minus the Noctalia (Luau) side.
  share = stdenvNoCC.mkDerivation {
    pname = "monitor-settings-share";
    inherit version;
    src = lib.fileset.toSource {
      root = ../monitor-settings;
      fileset = lib.fileset.unions [
        ../monitor-settings/app
        ../monitor-settings/translations
        ../monitor-settings/devices
      ];
    };
    installPhase = ''
      mkdir -p $out/share/monitor-settings
      cp -r app translations devices $out/share/monitor-settings/
      rm -r $out/share/monitor-settings/app/tests
    '';
  };

  appDir = "${share}/share/monitor-settings/app";

  launcher = writeShellApplication {
    name = "monitor-settings";
    # quickshell runs the app; wlr-randr, ddcutil and cat are what the app
    # itself spawns.
    runtimeInputs = [
      quickshell
      wlr-randr
      ddcutil
      coreutils
    ];
    text = ''
      app=${appDir}

      case "''${1:-}" in
        "")
          # Opens the window, or closes it if it's already open: the
          # `monitorsettings.toggle` IPC call only fails when no instance
          # is running. `-n` keeps a double launch from starting two.
          quickshell -p "$app" ipc call monitorsettings toggle >/dev/null 2>&1 \
            || exec quickshell -p "$app" -n -d
          ;;
        --reapply)
          # Headless: reapply the saved display configuration, then exit.
          MONITOR_SETTINGS_MODE=reapply exec quickshell -p "$app"
          ;;
        --quit)
          exec quickshell -p "$app" ipc call monitorsettings quit
          ;;
        -h | --help)
          echo "usage: monitor-settings [--reapply | --quit]"
          echo "  (no option)  open the window, or close it if it's open"
          echo "  --reapply    reapply the saved display configuration and exit"
          echo "  --quit       close a running window"
          ;;
        *)
          echo "monitor-settings: unknown option '$1' (see --help)" >&2
          exit 2
          ;;
      esac
    '';
  };

  desktopItem = makeDesktopItem {
    name = "monitor-settings";
    desktopName = "Monitor Settings";
    genericName = "Display configuration";
    comment = "Arrange displays and control monitors over DDC/CI";
    exec = "monitor-settings";
    icon = "preferences-desktop-display";
    categories = [
      "Settings"
      "HardwareSettings"
    ];
    keywords = [
      "monitor"
      "display"
      "ddcutil"
      "brightness"
      "resolution"
    ];
    startupWMClass = "heprado.monitor-settings";
  };
in
symlinkJoin {
  name = "monitor-settings-${version}";
  inherit version;
  paths = [
    launcher
    desktopItem
    share
  ];
  passthru = { inherit appDir; };
  meta = {
    description = "Display arrangement and DDC/CI monitor controls, as a Quickshell app";
    homepage = "https://github.com/heprado/noctalia-monitor-settings";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "monitor-settings";
  };
}

//@ pragma ShellId heprado-monitor-settings
//@ pragma AppId heprado.monitor-settings

// Monitor Settings -- the Quickshell application the Noctalia plugin
// launches (see ../widget.luau, ../launcher.luau, ../service.luau).
//
// Theming: nothing here hardcodes a palette. Quickshell runs Qt Quick
// Controls with the Fusion style and stays desktop-settings aware, so the
// active Qt platform theme (QT_QPA_PLATFORMTHEME: hyprqt6engine, qt6ct,
// KDE, ...) supplies the palette and fonts, and every custom-drawn item
// reads the same palette through SystemPalette.
//
// Modes (MONITOR_SETTINGS_MODE):
//   unset     -- the settings window. Closing it quits the app.
//   "reapply" -- no window: reapply the saved display configuration for
//                whatever outputs are connected, then exit. The plugin's
//                service runs this once at login.

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import qs.components

ShellRoot {
    id: root

    readonly property string mode: Quickshell.env("MONITOR_SETTINGS_MODE") ?? ""

    Component.onCompleted: {
        if (mode === "reapply") {
            DisplayService.reapplySaved(() => Qt.quit())
        } else {
            DisplayService.refresh(null)
        }
    }

    LazyLoader {
        active: root.mode !== "reapply"

        FloatingWindow {
            title: I18n.t("panel.title")
            implicitWidth: 980
            implicitHeight: 820
            minimumSize: Qt.size(640, 560)
            color: "transparent"

            onClosed: Qt.quit()

            MainView {
                anchors.fill: parent
            }
        }
    }

    // `qs -p <dir> ipc call monitorsettings toggle` -- what the plugin's
    // widget and launcher run first: an open window closes, and a non-zero
    // exit (no instance running) tells them to launch one instead.
    IpcHandler {
        target: "monitorsettings"

        function toggle(): void {
            Qt.quit()
        }

        function quit(): void {
            Qt.quit()
        }
    }
}

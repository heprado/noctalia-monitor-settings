import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.services
import "../lib/Displays.js" as Displays

// Every wlr-output-management setting for the selected output. Edits go
// to the draft (Draft.patch); nothing reaches the compositor before Apply.
ColumnLayout {
    id: root

    required property string name
    readonly property var output: Draft.output(name)
    readonly property var cfg: Draft.configs[name] || ({})
    readonly property bool on: cfg.enabled === true

    SystemPalette { id: pal; colorGroup: SystemPalette.Active }

    spacing: 12

    function fmt(n, decimals) {
        return Displays.trimNumber(Number(n).toFixed(decimals))
    }

    // Header: name, description, on/off.
    RowLayout {
        Layout.fillWidth: true
        spacing: 10

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Label {
                text: root.name
                font.bold: true
                font.pointSize: Qt.application.font.pointSize + 2
            }
            Label {
                Layout.fillWidth: true
                text: root.output ? root.output.description : ""
                color: pal.placeholderText
                elide: Text.ElideRight
            }
        }

        Label { text: I18n.t("display.enabled") }
        Switch {
            checked: root.on
            // Never the last enabled screen.
            enabled: !(root.on && Draft.enabledCount() <= 1)
            onToggled: Draft.setEnabled(root.name, checked)
        }
    }

    GridLayout {
        Layout.fillWidth: true
        visible: root.on && root.output !== null
        columns: 2
        columnSpacing: 16
        rowSpacing: 10

        // Resolution + refresh rate ------------------------------------
        Label { text: I18n.t("display.resolution") }
        RowLayout {
            Layout.fillWidth: true

            ComboBox {
                id: resolution
                Layout.fillWidth: true
                readonly property var list: root.output ? Displays.resolutions(root.output) : []
                model: list.map(r => r.width + " × " + r.height)
                currentIndex: list.findIndex(r => r.width === root.cfg.width && r.height === root.cfg.height)
                onActivated: index => {
                    const r = list[index]
                    // Fastest rate the new resolution supports.
                    const rate = Displays.refreshRates(root.output, r.width, r.height)[0]
                    Draft.patch(root.name, { width: r.width, height: r.height, refresh: rate })
                }
            }

            ComboBox {
                id: rate
                Layout.preferredWidth: 140
                readonly property var list: root.output ? Displays.refreshRates(root.output, root.cfg.width, root.cfg.height) : []
                model: list.map(r => root.fmt(r, 2) + " Hz")
                currentIndex: list.findIndex(r => Math.abs(r - root.cfg.refresh) < 0.0005)
                onActivated: index => Draft.patch(root.name, { refresh: list[index] })
            }
        }

        // Rotation ------------------------------------------------------
        Label { text: I18n.t("display.rotation") }
        RowLayout {
            Layout.fillWidth: true

            ComboBox {
                Layout.fillWidth: true
                model: Displays.TRANSFORMS.map(t => I18n.t("transform." + t.replace("-", "_")))
                currentIndex: Displays.TRANSFORMS.indexOf(root.cfg.transform || "normal")
                onActivated: index => Draft.patch(root.name, { transform: Displays.TRANSFORMS[index] })
            }
            ToolButton {
                text: "↺"
                font.pointSize: Qt.application.font.pointSize + 3
                ToolTip.visible: hovered
                ToolTip.text: I18n.t("display.rotate_ccw")
                onClicked: Draft.patch(root.name, { transform: Displays.rotateTransform(root.cfg.transform, -1) })
            }
            ToolButton {
                text: "↻"
                font.pointSize: Qt.application.font.pointSize + 3
                ToolTip.visible: hovered
                ToolTip.text: I18n.t("display.rotate_cw")
                onClicked: Draft.patch(root.name, { transform: Displays.rotateTransform(root.cfg.transform, 1) })
            }
        }

        // Scale: presets, plus the current value when it isn't one --------
        Label { text: I18n.t("display.scale") }
        RowLayout {
            Layout.fillWidth: true

            ComboBox {
                id: scale
                Layout.fillWidth: true
                readonly property var list: {
                    const l = Displays.SCALE_PRESETS.slice()
                    const s = root.cfg.scale || 1
                    if (!l.some(p => Math.abs(p - s) < 0.0001)) {
                        l.push(s)
                        l.sort((a, b) => a - b)
                    }
                    return l
                }
                model: list.map(s => root.fmt(s * 100, 1) + "%")
                currentIndex: list.findIndex(s => Math.abs(s - (root.cfg.scale || 1)) < 0.0001)
                onActivated: index => Draft.patch(root.name, { scale: list[index] })
            }

            TextField {
                Layout.preferredWidth: 90
                placeholderText: I18n.t("display.custom_scale")
                text: Displays.formatScale(root.cfg.scale || 1)
                validator: DoubleValidator { bottom: 0.25; top: 4; decimals: 4; notation: DoubleValidator.StandardNotation }
                onEditingFinished: {
                    const v = Number(text.replace(",", "."))
                    if (v >= 0.25 && v <= 4) Draft.patch(root.name, { scale: v })
                    else text = Displays.formatScale(root.cfg.scale || 1)
                }
            }
        }

        // DPI: Wayland has no per-monitor DPI of its own -- scale *is* that
        // setting -- so this shows the physical density and what it works
        // out to at the chosen scale, and derives a scale from a target.
        Label { text: I18n.t("display.dpi") }
        RowLayout {
            Layout.fillWidth: true
            readonly property var physical: root.output ? Displays.physicalDpi(root.output, root.cfg) : null
            readonly property var effective: root.output ? Displays.effectiveDpi(root.output, root.cfg) : null

            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: parent.physical === null
                      ? I18n.t("display.dpi_unknown")
                      : I18n.t("display.dpi_value", { physical: Math.round(parent.physical), effective: Math.round(parent.effective) })
                color: parent.physical === null ? pal.placeholderText : pal.windowText
            }
            TextField {
                visible: parent.physical !== null
                Layout.preferredWidth: 90
                placeholderText: I18n.t("display.target_dpi")
                text: parent.effective === null ? "" : String(Math.round(parent.effective))
                validator: IntValidator { bottom: 24; top: 1200 }
                ToolTip.visible: hovered
                ToolTip.text: I18n.t("display.target_dpi")
                onEditingFinished: {
                    const s = Displays.scaleForDpi(root.output, root.cfg, Number(text))
                    if (s !== null) Draft.patch(root.name, { scale: s })
                }
            }
        }

        // Adaptive sync (VRR): what FreeSync and G-Sync Compatible are on
        // Wayland. null = the compositor can't report or set it.
        Label { text: I18n.t("display.adaptive_sync") }
        RowLayout {
            Layout.fillWidth: true
            readonly property bool supported: root.output !== null && root.output.adaptiveSync !== null

            Switch {
                enabled: parent.supported
                checked: root.cfg.adaptiveSync === true
                onToggled: Draft.patch(root.name, { adaptiveSync: checked })
            }
            Label {
                Layout.fillWidth: true
                visible: !parent.supported
                wrapMode: Text.WordWrap
                text: I18n.t("display.adaptive_sync_unsupported")
                color: pal.placeholderText
            }
        }

        // Exact position -------------------------------------------------
        Label { text: I18n.t("display.position") }
        RowLayout {
            Layout.fillWidth: true

            Label { text: "X" }
            SpinBox {
                from: -32768; to: 32767
                editable: true
                // Plain digits: locale grouping ("3.000") reads as a decimal
                // in half the world.
                textFromValue: (v, locale) => String(v)
                valueFromText: (text, locale) => parseInt(text, 10) || 0
                value: root.cfg.x || 0
                onValueModified: Draft.setPosition(root.name, value, root.cfg.y)
            }
            Label { text: "Y" }
            SpinBox {
                from: -32768; to: 32767
                editable: true
                textFromValue: (v, locale) => String(v)
                valueFromText: (text, locale) => parseInt(text, 10) || 0
                value: root.cfg.y || 0
                onValueModified: Draft.setPosition(root.name, root.cfg.x, value)
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                readonly property var size: Displays.logicalSize(root.cfg)
                text: I18n.t("display.logical_size", { width: size.width, height: size.height })
                color: pal.placeholderText
            }
        }
    }
}

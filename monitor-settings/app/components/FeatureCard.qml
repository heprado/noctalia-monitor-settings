import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.services
import "../lib/Ddc.js" as Ddc

// One VCP feature, with the control its classification calls for:
// slider (+ exact value), dropdown, trigger button, or read-only text.
Rectangle {
    id: root

    required property string monitorId
    required property var feature
    // 8D (Audio mute), composited onto 62's (speaker volume) slider.
    property var muteFeature: null

    SystemPalette { id: pal; colorGroup: SystemPalette.Active }

    // Video gain codes -> RGB channel. A gain of 0 means the channel
    // contributes nothing, so the honest spectrum is black -> pure color.
    readonly property var gainChannel: ({ "16": "#ff0000", "18": "#00ff00", "1A": "#0000ff" })[feature.code] || ""

    implicitHeight: content.implicitHeight + 20
    radius: 8
    color: Qt.rgba(pal.button.r, pal.button.g, pal.button.b, 0.45)
    border.color: Qt.rgba(pal.mid.r, pal.mid.g, pal.mid.b, 0.6)

    function send(value, optimistic) {
        DdcService.setvcp(monitorId, feature.code, value, optimistic, () => {
            errorLabel.text = I18n.t("errors.setvcp_failed", { code: root.feature.code, id: root.monitorId })
        })
    }

    ColumnLayout {
        id: content
        anchors.fill: parent
        anchors.margins: 10
        spacing: 4

        Label {
            Layout.fillWidth: true
            text: I18n.tr("feature." + root.feature.code.toLowerCase()) ?? root.feature.name
            font.bold: true
            elide: Text.ElideRight
        }
        Label {
            Layout.fillWidth: true
            visible: root.feature.description !== ""
            text: I18n.tr("feature_desc." + root.feature.code.toLowerCase()) ?? root.feature.description
            color: pal.placeholderText
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            font.pointSize: Math.max(7, Qt.application.font.pointSize - 1)
        }

        // Slider ----------------------------------------------------------
        RowLayout {
            Layout.fillWidth: true
            visible: root.feature.widget === "slider"
            spacing: 8

            readonly property int maxValue: root.feature.max > 0 ? root.feature.max : 100

            function commit(v) {
                const rounded = Math.max(0, Math.min(maxValue, Math.round(v)))
                root.send(String(rounded), rounded)
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                // Writes once on release, not on every step of the drag --
                // each one is a slow I2C round-trip.
                Slider {
                    id: slider
                    Layout.fillWidth: true
                    from: 0
                    to: parent.parent.maxValue
                    stepSize: 1
                    value: root.feature.current ?? 0
                    onPressedChanged: if (!pressed) parent.parent.commit(value)
                    onMoved: if (!pressed) parent.parent.commit(value)
                }
                Rectangle {
                    visible: root.gainChannel !== ""
                    Layout.fillWidth: true
                    Layout.leftMargin: slider.leftPadding
                    Layout.rightMargin: slider.rightPadding
                    height: 6
                    radius: 3
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: "black" }
                        GradientStop { position: 1; color: root.gainChannel || "black" }
                    }
                }
            }

            SpinBox {
                Layout.preferredWidth: 110
                from: 0
                to: parent.maxValue
                editable: true
                value: slider.pressed ? slider.value : (root.feature.current ?? 0)
                onValueModified: parent.commit(value)
            }

            Button {
                visible: root.feature.code === "62" && root.muteFeature !== null
                readonly property bool muted: root.muteFeature !== null && root.muteFeature.current === 1
                // Not checkable: the state always comes from the monitor's
                // (optimistically updated) 8D value, and Fusion's checked
                // look is too subtle on dark palettes -- highlighted isn't.
                highlighted: muted
                text: I18n.t("ddc.mute")
                onClicked: DdcService.setvcp(root.monitorId, "8D", muted ? "0x02" : "0x01", muted ? 2 : 1)
            }
        }

        // Dropdown --------------------------------------------------------
        ComboBox {
            Layout.fillWidth: true
            visible: root.feature.widget === "combobox"
            model: (root.feature.values || []).map(v => v.name)
            currentIndex: (root.feature.values || []).findIndex(v => parseInt(v.code, 16) === root.feature.current)
            onActivated: index => {
                const v = root.feature.values[index]
                root.send("0x" + v.code, parseInt(v.code, 16))
            }
        }

        // Write-only trigger ----------------------------------------------
        Button {
            visible: root.feature.widget === "button"
            text: I18n.t("panel.trigger")
            onClicked: root.send("1", null)
        }

        // Read-only -------------------------------------------------------
        Label {
            visible: root.feature.widget === "readonly"
            text: Ddc.readOnlyDisplay(root.feature) ?? I18n.t("readonly.no_data")
            color: pal.placeholderText
        }

        Label {
            id: errorLabel
            Layout.fillWidth: true
            visible: text !== ""
            color: "#e5534b"
            wrapMode: Text.WordWrap
        }
    }
}

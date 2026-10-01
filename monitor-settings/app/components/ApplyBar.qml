import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.services

// Apply / Discard for the draft -- or, while a risky change awaits
// confirmation, Keep / Revert with the auto-revert countdown.
Rectangle {
    id: root

    SystemPalette { id: pal; colorGroup: SystemPalette.Active }

    readonly property bool confirming: DisplayService.pending !== null
    property real now: Date.now()

    implicitHeight: row.implicitHeight + 16
    radius: 8
    color: confirming ? Qt.rgba(pal.highlight.r, pal.highlight.g, pal.highlight.b, 0.18) : "transparent"
    border.color: confirming ? pal.highlight : "transparent"

    Timer {
        running: root.confirming
        repeat: true
        interval: 250
        triggeredOnStart: true
        onTriggered: root.now = Date.now()
    }

    RowLayout {
        id: row
        anchors.fill: parent
        anchors.margins: 8
        spacing: 8

        Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            visible: root.confirming || DisplayService.lastError !== ""
            text: root.confirming
                  ? I18n.t("display.confirm", { seconds: Math.max(0, Math.ceil((DisplayService.pending.deadline - root.now) / 1000)) })
                  : I18n.t("errors.apply_failed", { error: DisplayService.lastError })
            color: root.confirming ? pal.windowText : "#e5534b"
        }
        Item { Layout.fillWidth: true; visible: !root.confirming && DisplayService.lastError === "" }

        Button {
            visible: root.confirming
            text: I18n.t("display.revert")
            onClicked: DisplayService.revert()
        }
        Button {
            visible: root.confirming
            highlighted: true
            text: I18n.t("display.keep")
            onClicked: DisplayService.confirm()
        }

        Button {
            visible: !root.confirming
            enabled: Draft.dirty
            text: I18n.t("display.discard")
            onClicked: Draft.discard()
        }
        Button {
            visible: !root.confirming
            enabled: Draft.dirty
            highlighted: true
            text: I18n.t("display.apply")
            onClicked: Draft.apply()
        }
    }
}

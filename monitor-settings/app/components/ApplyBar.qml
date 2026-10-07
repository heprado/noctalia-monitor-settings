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

    // Apply turns green for a moment once a change is in for good (see
    // DisplayService.persisted) -- after Apply for a safe change, or after
    // Keep for a risky one.
    property bool justApplied: false
    readonly property color appliedColor: "#2ea043"

    Connections {
        target: DisplayService
        function onPersisted() {
            root.justApplied = true
            appliedTimer.restart()
        }
    }

    Timer {
        id: appliedTimer
        interval: 2000
        onTriggered: root.justApplied = false
    }

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
            // Kept enabled while green: the disabled palette would grey the
            // green out. With nothing left to apply, a click does nothing.
            enabled: Draft.dirty || root.justApplied
            highlighted: true
            text: I18n.t("display.apply")
            // Fusion fills a button from palette.button (highlighted only
            // tints the outline), so both are swapped; going through the
            // palette keeps Fusion's gradient, hover and outline.
            palette.button: root.justApplied ? root.appliedColor : pal.button
            palette.highlight: root.justApplied ? root.appliedColor : pal.highlight
            palette.buttonText: root.justApplied ? "white" : pal.buttonText
            onClicked: if (Draft.dirty) Draft.apply()
        }
    }
}

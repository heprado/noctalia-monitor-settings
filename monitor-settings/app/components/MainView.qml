import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.services

// Arrangement canvas on top; below it, the selected output's display
// settings and DDC/CI controls in two tabs.
Rectangle {
    id: root

    SystemPalette { id: pal; colorGroup: SystemPalette.Active }
    color: pal.window

    readonly property var selectedOutput: Draft.output(Draft.selected)

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 10

        // Header ------------------------------------------------------------
        RowLayout {
            Layout.fillWidth: true
            Label {
                Layout.fillWidth: true
                text: I18n.t("panel.title")
                font.bold: true
                font.pointSize: Qt.application.font.pointSize + 3
            }
            Button {
                text: I18n.t("panel.refresh")
                onClicked: {
                    DisplayService.refresh(null)
                    DdcService.detect()
                }
            }
        }

        Label {
            Layout.fillWidth: true
            visible: DisplayService.loaded && !DisplayService.supported
            wrapMode: Text.WordWrap
            text: I18n.t("panel.arrangement_unsupported")
            color: pal.placeholderText
        }

        // Canvas ------------------------------------------------------------
        ArrangementCanvas {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(220, root.height * 0.36)
            visible: DisplayService.supported
        }

        // Every output -- disabled ones included, since they aren't on the
        // canvas and this is the only way to select (and turn) them on.
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            visible: DisplayService.supported

            Repeater {
                model: DisplayService.outputs
                delegate: Button {
                    required property var modelData
                    checkable: true
                    checked: Draft.selected === modelData.name
                    text: modelData.name + ((Draft.configs[modelData.name] && !Draft.configs[modelData.name].enabled)
                                            ? " (" + I18n.t("display.off") + ")" : "")
                    onClicked: Draft.selected = modelData.name
                }
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                wrapMode: Text.WordWrap
                text: I18n.t("display.canvas_hint")
                color: pal.placeholderText
                font.pointSize: Math.max(7, Qt.application.font.pointSize - 1)
            }
        }

        // Tabs ----------------------------------------------------------------
        TabBar {
            id: tabs
            Layout.fillWidth: true
            visible: root.selectedOutput !== null
            TabButton { text: I18n.t("display.tab_display") }
            TabButton { text: I18n.t("display.ddc_header") }
            onCurrentIndexChanged: if (currentIndex === 1) DdcService.ensureLoaded()
        }

        ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.selectedOutput !== null
            contentWidth: availableWidth
            clip: true

            StackLayout {
                width: scroll.availableWidth
                currentIndex: tabs.currentIndex

                DisplaySettings {
                    name: Draft.selected
                }

                DdcSection {
                    output: root.selectedOutput
                }
            }
        }

        ApplyBar {
            Layout.fillWidth: true
            visible: DisplayService.supported
        }
    }
}

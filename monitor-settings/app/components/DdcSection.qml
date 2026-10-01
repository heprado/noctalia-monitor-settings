import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.services
import "../lib/Ddc.js" as Ddc

// DDC/CI controls for the monitor behind one wlr-randr output, grouped by
// MCCS category. "Others" (manufacturer codes with no known meaning and no
// devices/ override) is left out: real values, but noise without a name.
ColumnLayout {
    id: root

    required property var output
    readonly property var monitor: DdcService.monitorForOutput(output)
    readonly property var groups: monitor
        ? Ddc.groupFeaturesByCategory(monitor.features || []).filter(g => g.category !== "Others")
        : []
    readonly property var muteFeature: monitor ? Ddc.findFeature(monitor.features || [], "8D") : null

    SystemPalette { id: pal; colorGroup: SystemPalette.Active }

    spacing: 10

    readonly property var categoryKeys: ({
        "Image": "category.image",
        "Audio": "category.audio",
        "Preset": "category.preset",
        "Control": "category.control",
        "Miscellaneous": "category.miscellaneous",
        "Others": "category.others"
    })

    function categoryLabel(category) {
        const key = categoryKeys[category]
        return (key ? I18n.tr(key) : null) ?? category
    }

    RowLayout {
        Layout.fillWidth: true
        Label {
            Layout.fillWidth: true
            text: root.monitor
                  ? (root.monitor.model || I18n.t("panel.display_fallback", { id: root.monitor.id }))
                  : ""
            font.bold: true
            font.pointSize: Qt.application.font.pointSize + 1
        }
        BusyIndicator {
            visible: DdcService.detecting || (root.monitor !== null && root.monitor.loading)
            running: visible
            Layout.preferredHeight: 24
            Layout.preferredWidth: 24
        }
    }

    Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: pal.placeholderText
        visible: text !== ""
        text: {
            if (DdcService.detecting || !DdcService.checked) return I18n.t("panel.detecting")
            if (!DdcService.available || DdcService.monitors.length === 0) return I18n.t("panel.no_monitors")
            if (!root.monitor) return I18n.t("panel.settings_unavailable")
            return ""
        }
    }

    Repeater {
        model: root.groups

        delegate: ColumnLayout {
            required property var modelData
            Layout.fillWidth: true
            spacing: 6

            Label {
                text: root.categoryLabel(modelData.category).toUpperCase()
                font.bold: true
                font.pointSize: Math.max(7, Qt.application.font.pointSize - 1)
                color: pal.highlight
            }

            GridLayout {
                Layout.fillWidth: true
                columns: root.width > 640 ? 2 : 1
                columnSpacing: 8
                rowSpacing: 8

                Repeater {
                    model: modelData.features

                    delegate: FeatureCard {
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1 // equal columns
                        Layout.alignment: Qt.AlignTop
                        monitorId: root.monitor.id
                        feature: modelData
                        muteFeature: root.muteFeature
                    }
                }
            }
        }
    }
}

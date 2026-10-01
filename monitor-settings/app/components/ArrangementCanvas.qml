import QtQuick
import QtQuick.Controls
import qs.services
import "../lib/Displays.js" as Displays

// The monitor arrangement, drawn to scale (rotation and scale included).
// Drag a monitor anywhere: while dragging, a dashed outline shows where it
// will snap to; on release it lands there, flush against its neighbours.
// Click to select it.
Rectangle {
    id: root

    SystemPalette { id: pal; colorGroup: SystemPalette.Active }

    readonly property real padding: 16
    // Edges within this many on-screen pixels of a neighbour's snap together.
    readonly property real snapPixels: 14

    color: Qt.darker(pal.window, 1.18)
    radius: 8
    border.color: pal.mid
    border.width: 1
    clip: true

    // Frozen while a drag is in progress (Draft.configs doesn't change
    // until the drop), so the drag and its preview share one mapping.
    readonly property var view: Displays.computeView(Draft.configs, width - padding * 2, height - padding * 2)

    function toCanvasX(x) { return padding + (x - view.ox) * view.scale }
    function toCanvasY(y) { return padding + (y - view.oy) * view.scale }
    function toLogicalX(cx) { return (cx - padding) / view.scale + view.ox }
    function toLogicalY(cy) { return (cy - padding) / view.scale + view.oy }

    // Reassigning a Repeater's JS-array model recreates every delegate --
    // mid-animation tiles included -- so this only changes when the *set*
    // of monitors on the canvas does, not on every position edit.
    property var enabledNames: []

    function refreshNames() {
        const names = Object.keys(Draft.configs).filter(n => Draft.configs[n].enabled && Draft.configs[n].width).sort()
        if (names.join("\n") !== enabledNames.join("\n")) enabledNames = names
    }

    Connections {
        target: Draft
        function onConfigsChanged() { root.refreshNames() }
    }

    Component.onCompleted: refreshNames()

    // Click on empty space: nothing selected stays selected -- clearing it
    // would only hide the settings below.
    Label {
        anchors.centerIn: parent
        visible: root.enabledNames.length === 0
        text: DisplayService.loaded ? I18n.t("display.no_outputs") : I18n.t("display.loading")
        color: pal.placeholderText
    }

    // Snap preview: where the monitor being dragged will land. Drawn above
    // the dragged tile itself -- often the two nearly coincide, and an
    // outline underneath would be invisible exactly then.
    Rectangle {
        id: ghost
        visible: false
        z: 3
        color: "transparent"
        radius: 6
        border.color: pal.highlight
        border.width: 2
        opacity: 0.9

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: 4
            color: pal.highlight
            opacity: 0.15
        }
    }

    Repeater {
        model: root.enabledNames

        delegate: Rectangle {
            id: tile
            required property string modelData
            readonly property string name: modelData
            readonly property var cfg: Draft.configs[name] || ({})
            readonly property var size: Displays.logicalSize(cfg)
            readonly property bool selected: Draft.selected === name
            readonly property bool dragging: drag.active

            readonly property real homeX: root.toCanvasX(cfg.x || 0)
            readonly property real homeY: root.toCanvasY(cfg.y || 0)

            // Offset from the home position: follows the pointer while
            // dragging, then eases back to 0 from wherever the monitor was
            // dropped once its new home (the snapped spot) is committed.
            property real offX: 0
            property real offY: 0

            x: homeX + offX
            y: homeY + offY
            z: dragging ? 2 : 0
            width: Math.max(8, size.width * root.view.scale)
            height: Math.max(8, size.height * root.view.scale)
            radius: 6
            color: selected ? pal.highlight : pal.button
            border.color: selected ? Qt.lighter(pal.highlight, 1.3) : pal.mid
            border.width: selected ? 2 : 1
            opacity: dragging ? 0.85 : 1

            ParallelAnimation {
                id: settle
                NumberAnimation { target: tile; property: "offX"; to: 0; duration: 160; easing.type: Easing.OutCubic }
                NumberAnimation { target: tile; property: "offY"; to: 0; duration: 160; easing.type: Easing.OutCubic }
            }

            Column {
                anchors.centerIn: parent
                width: parent.width - 8
                spacing: 2

                Label {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: tile.name
                    font.bold: true
                    elide: Text.ElideRight
                    color: tile.selected ? pal.highlightedText : pal.buttonText
                }
                Label {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    visible: tile.height > 54
                    text: (tile.cfg.width || 0) + "×" + (tile.cfg.height || 0)
                          + (tile.cfg.scale !== 1 ? "  " + Math.round(tile.cfg.scale * 100) + "%" : "")
                    font.pointSize: Math.max(7, Qt.application.font.pointSize - 2)
                    elide: Text.ElideRight
                    color: tile.selected ? pal.highlightedText : pal.buttonText
                    opacity: 0.8
                }
            }

            // The panel's top edge, so a rotated monitor reads as rotated.
            Rectangle {
                readonly property string t: tile.cfg.transform || "normal"
                readonly property int edge: t.endsWith("90") ? 1 : t.endsWith("180") ? 2 : t.endsWith("270") ? 3 : 0
                color: tile.selected ? pal.highlightedText : pal.buttonText
                opacity: 0.35
                radius: 1.5
                width: (edge === 0 || edge === 2) ? parent.width * 0.3 : 3
                height: (edge === 0 || edge === 2) ? 3 : parent.height * 0.3
                x: edge === 1 ? parent.width - width - 4 : edge === 3 ? 4 : (parent.width - width) / 2
                y: edge === 0 ? 4 : edge === 2 ? parent.height - height - 4 : (parent.height - height) / 2
            }

            HoverHandler {
                cursorShape: tile.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            }

            TapHandler {
                onTapped: Draft.selected = tile.name
            }

            DragHandler {
                id: drag
                target: null
                cursorShape: Qt.ClosedHandCursor

                function dropPoint() {
                    return {
                        x: root.toLogicalX(tile.homeX + activeTranslation.x),
                        y: root.toLogicalY(tile.homeY + activeTranslation.y)
                    }
                }

                onActiveChanged: {
                    if (active) {
                        settle.stop()
                        tile.offX = 0
                        tile.offY = 0
                        Draft.selected = tile.name
                        ghost.width = tile.width
                        ghost.height = tile.height
                        return
                    }
                    ghost.visible = false
                    const droppedX = tile.x
                    const droppedY = tile.y
                    const threshold = root.snapPixels / root.view.scale
                    const p = {
                        x: root.toLogicalX(droppedX),
                        y: root.toLogicalY(droppedY)
                    }
                    Draft.dropAt(tile.name, p.x, p.y, threshold)
                    // homeX/homeY are now the snapped spot (bindings update
                    // synchronously): start from where it was let go.
                    tile.offX = droppedX - tile.homeX
                    tile.offY = droppedY - tile.homeY
                    settle.start()
                }

                onActiveTranslationChanged: {
                    if (!active) return
                    tile.offX = activeTranslation.x
                    tile.offY = activeTranslation.y
                    const p = dropPoint()
                    const snapped = Draft.previewDrop(tile.name, p.x, p.y, root.snapPixels / root.view.scale)
                    ghost.x = root.toCanvasX(snapped.x)
                    ghost.y = root.toCanvasY(snapped.y)
                    ghost.visible = true
                }
            }
        }
    }
}

pragma Singleton

import QtQuick
import Quickshell
import "../lib/Displays.js" as Displays

// The UI edits a *draft* of every output's config and only hands it to
// DisplayService on Apply, like any display-settings dialog: dragging
// three monitors around shouldn't reconfigure the compositor three times,
// and a half-finished arrangement should never be live.
//
// Rebuilt from the live outputs whenever there are no unapplied edits;
// while there are, outputs that appear/disappear are merged in/out.
Singleton {
    id: root

    property var configs: ({})
    property bool dirty: false
    property string selected: ""

    readonly property var outputs: DisplayService.outputs

    function output(name) {
        for (const o of outputs) {
            if (o.name === name) return o
        }
        return null
    }

    function sync() {
        const live = Displays.configsFromOutputs(outputs)
        if (!dirty) {
            configs = live
        } else {
            const merged = {}
            for (const name in live) merged[name] = configs[name] || live[name]
            configs = merged
        }
        if (!selected || !configs[selected]) selected = outputs.length > 0 ? outputs[0].name : ""
    }

    Connections {
        target: DisplayService
        function onOutputsChanged() { root.sync() }
    }

    function commit(next) {
        configs = next
        dirty = true
    }

    function enabledCount() {
        let n = 0
        for (const name in configs) {
            if (configs[name].enabled) n++
        }
        return n
    }

    // Applies `changes` to one output. A change to its logical size (mode,
    // scale, rotation) can leave it overlapping a neighbour or detached,
    // so it's re-resolved in place -- no snapping distance, just "make it
    // valid again".
    function patch(name, changes) {
        const next = Displays.copyConfigs(configs)
        const cfg = next[name]
        if (!cfg) return
        Object.assign(cfg, changes)
        if (cfg.enabled) {
            const p = Displays.snapPosition(next, name, cfg.x, cfg.y, 0)
            cfg.x = p.x
            cfg.y = p.y
            Displays.normalizeOrigin(next)
        }
        commit(next)
    }

    function setEnabled(name, on) {
        if (!configs[name] || configs[name].enabled === on) return
        if (!on && enabledCount() <= 1) return // never the last screen
        if (!on) {
            patch(name, { enabled: false })
            return
        }
        // Comes back on to the right of the current arrangement.
        let maxX = 0
        for (const other in configs) {
            const c = configs[other]
            if (other !== name && c.enabled && c.width) maxX = Math.max(maxX, c.x + Displays.logicalSize(c).width)
        }
        patch(name, { enabled: true, x: maxX, y: 0 })
    }

    // A canvas drop: (x, y) is where the user let go, in logical
    // coordinates; snapPosition turns it into a flush, valid placement.
    function dropAt(name, x, y, threshold) {
        const next = Displays.copyConfigs(configs)
        const p = Displays.snapPosition(next, name, x, y, threshold)
        next[name].x = p.x
        next[name].y = p.y
        Displays.normalizeOrigin(next)
        commit(next)
    }

    // Where a drop at (x, y) would land, without committing it -- the
    // canvas draws this as the snap preview while dragging.
    function previewDrop(name, x, y, threshold) {
        return Displays.snapPosition(configs, name, x, y, threshold)
    }

    // Exact position from the X/Y fields: taken as typed.
    function setPosition(name, x, y) {
        const next = Displays.copyConfigs(configs)
        next[name].x = Math.round(x)
        next[name].y = Math.round(y)
        commit(next)
    }

    function discard() {
        dirty = false
        sync()
    }

    function apply() {
        const snapshot = Displays.copyConfigs(configs)
        dirty = false
        DisplayService.apply(snapshot)
    }
}

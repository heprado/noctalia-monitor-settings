pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "../lib/Displays.js" as Displays

// Owns every `wlr-randr` invocation: reads the live outputs, applies a
// draft atomically, runs the confirm-or-revert safety net, and persists
// confirmed configs so they can be reapplied at login.
Singleton {
    id: root

    // How long a risky change (mode, scale, rotation, on/off) stays applied
    // without being confirmed before it's rolled back -- a mode the
    // monitor can't show leaves no screen to click "undo" on.
    readonly property int confirmSeconds: 15

    property bool loaded: false
    // false once wlr-randr turns out to be missing or the compositor
    // doesn't speak wlr-output-management.
    property bool supported: true
    property var outputs: []
    property string lastError: ""

    // Set while a risky change awaits confirmation:
    // { previous, next, deadline (ms since epoch) }.
    property var pending: null

    readonly property string configPath: Quickshell.dataPath("displays.json")
    property var saved: ({})

    signal applied(bool ok)
    // A change is in for good: applied and kept without confirmation, or
    // confirmed with Keep. Not emitted for one still awaiting confirmation.
    signal persisted()

    FileView {
        id: savedFile
        path: root.configPath
        blockLoading: true
        printErrors: false
        onLoaded: {
            try {
                const parsed = JSON.parse(savedFile.text())
                root.saved = (parsed && typeof parsed === "object") ? parsed : {}
            } catch (e) {
                root.saved = {}
            }
        }
    }

    // Merged into what's already saved rather than replacing it, so a
    // monitor that's unplugged right now keeps its config for next time.
    function persist(configs) {
        const merged = Object.assign({}, saved)
        for (const name in configs) merged[name] = configs[name]
        saved = merged
        savedFile.setText(JSON.stringify(merged, null, 2) + "\n")
        root.persisted()
    }

    function refresh(onDone) {
        Exec.run(["wlr-randr", "--json"], result => {
            if (result.exitCode === 0) {
                try {
                    root.outputs = Displays.parseOutputs(JSON.parse(result.stdout))
                    root.supported = true
                } catch (e) {
                    root.supported = false
                }
            } else {
                root.supported = false
            }
            root.loaded = true
            if (onDone) onDone()
        })
    }

    // One atomic wlr-randr call for every output whose config differs from
    // its live state, then a re-read so the UI shows the real outcome.
    // onDone(ok, risky) runs after that re-read.
    function applyConfigs(configs, onDone) {
        const plan = Displays.buildApplyArgs(outputs, configs)
        if (!plan.args) {
            if (onDone) onDone(true, false)
            return
        }
        Exec.run(plan.args, result => {
            const ok = result.exitCode === 0
            root.lastError = ok ? "" : (result.stderr || "").trim()
            root.refresh(() => {
                if (onDone) onDone(ok, plan.risky)
            })
        })
    }

    // Applies the UI's draft. Position/adaptive-sync-only changes are kept
    // and persisted straight away; anything riskier only once confirmed.
    function apply(configs) {
        // A new apply while an earlier one awaits confirmation builds on
        // it: the rollback target stays the last *confirmed* state.
        const previous = pending ? pending.previous : Displays.configsFromOutputs(outputs)
        applyConfigs(configs, (ok, risky) => {
            root.applied(ok)
            if (!ok) return
            if (!risky && !root.pending) {
                root.persist(configs)
                return
            }
            root.pending = { previous: previous, next: configs, deadline: Date.now() + root.confirmSeconds * 1000 }
            revertTimer.restart()
        })
    }

    function confirm() {
        if (!pending) return
        revertTimer.stop()
        persist(pending.next)
        pending = null
    }

    function revert() {
        if (!pending) return
        revertTimer.stop()
        const previous = pending.previous
        pending = null
        applyConfigs(previous, null)
    }

    Timer {
        id: revertTimer
        interval: root.confirmSeconds * 1000
        onTriggered: root.revert()
    }

    // Login: reapply whatever was saved for the outputs connected now. No
    // confirmation -- this is a state the user already confirmed once.
    function reapplySaved(onDone) {
        refresh(() => {
            const configs = {}
            let any = false
            for (const o of root.outputs) {
                if (root.saved[o.name] !== undefined) {
                    configs[o.name] = Displays.sanitizeSaved(o, root.saved[o.name])
                    any = true
                }
            }
            if (!any) {
                if (onDone) onDone(true)
                return
            }
            root.applyConfigs(configs, ok => {
                if (onDone) onDone(ok)
            })
        })
    }
}

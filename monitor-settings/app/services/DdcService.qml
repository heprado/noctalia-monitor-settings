pragma Singleton

import QtQuick
import Quickshell
import "../lib/Ddc.js" as Ddc

// Owns every ddcutil invocation and publishes classified per-monitor VCP
// features. Nothing polls: DDC/CI queries are slow I2C round-trips, so
// values are read on detect/refresh and writes update optimistically.
Singleton {
    id: root

    property bool detecting: false
    property bool checked: false  // a detect has run at least once
    property bool available: true // false when ddcutil isn't installed
    // Published snapshots: [{ id, model, mfgId, connector, features, loading }].
    // Fresh objects on every publish -- the fetch callbacks mutate their
    // own (internal) entries in place, and QML only re-evaluates a binding
    // when the value it reads is a different object.
    property var monitors: []
    property var internal: []

    property var vcpInfo: ({})
    property var deviceNamesCache: ({})

    function publish() {
        monitors = internal.map(m => ({
            id: m.id,
            model: m.model,
            mfgId: m.mfgId,
            connector: m.connector,
            features: m.features.slice(),
            loading: m.loading
        }))
    }

    function ensureLoaded() {
        if (!checked) detect()
    }

    // Re-detects the connected set, keeping existing entries so their
    // features stay on screen while they're re-read.
    function detect() {
        detecting = true
        checked = true
        Exec.run(["ddcutil", "detect"], result => {
            root.detecting = false
            if (result.exitCode === Exec.notFound) {
                root.available = false
                root.internal = []
                root.publish()
                return
            }
            root.available = true
            if (result.exitCode !== 0) {
                root.internal = []
                root.publish()
                return
            }
            const byId = {}
            for (const m of root.internal) byId[m.id] = m
            const rebuilt = []
            for (const d of Ddc.parseDetect(result.stdout)) {
                const m = byId[d.id] || { id: d.id, features: [], loading: true }
                m.model = d.model
                m.mfgId = d.mfgId
                m.connector = d.connector
                rebuilt.push(m)
            }
            root.internal = rebuilt
            root.publish()
            for (const m of rebuilt) root.fetchMonitor(m)
        })
    }

    // The ddcutil display behind a wlr-randr output: by DRM connector when
    // ddcutil reports one ("card1-DP-2" <-> "DP-2"), else by the model
    // name appearing in the output's description.
    function monitorForOutput(output) {
        if (!output) return null
        for (const m of monitors) {
            if (m.connector && m.connector === output.name) return m
        }
        for (const m of monitors) {
            if (m.model && (output.description || "").indexOf(m.model) !== -1) return m
        }
        return null
    }

    function findMonitor(id) {
        for (const m of internal) {
            if (m.id === id) return m
        }
        return null
    }

    // Community-contributed OSD label overrides (devices/<MFG>.json, keyed
    // by the 3-letter VESA PNP id) -- optional and additive. The id comes
    // from the display's own EDID, so it's sanitized before becoming a path.
    function loadDeviceNames(mfgId, onDone) {
        const safe = (mfgId || "").replace(/[^A-Za-z0-9_-]/g, "_")
        if (!safe) {
            onDone({})
            return
        }
        if (deviceNamesCache[safe] !== undefined) {
            onDone(deviceNamesCache[safe])
            return
        }
        Exec.run(["cat", Quickshell.shellDir + "/../devices/" + safe + ".json"], result => {
            let names = {}
            if (result.exitCode === 0) {
                try {
                    const parsed = JSON.parse(result.stdout)
                    if (parsed && typeof parsed === "object") names = parsed
                } catch (e) {}
            }
            root.deviceNamesCache[safe] = names
            onDone(names)
        })
    }

    function classifyAll(m, raw, deviceNames) {
        m.features = raw.map(f => Ddc.classifyFeature(f, root.vcpInfo, deviceNames))
    }

    // capabilities (what the monitor declares) has to come first: it's the
    // only source of which codes to ask vcpinfo and getvcp about.
    function fetchMonitor(m) {
        m.loading = true
        publish()
        Exec.run(["ddcutil", "--display", m.id, "capabilities", "--terse"], caps => {
            if (caps.exitCode !== 0) {
                m.loading = false
                root.publish()
                return
            }
            const raw = Ddc.parseCapabilities(caps.stdout)
            const codes = raw.map(f => f.code)
            root.loadDeviceNames(m.mfgId, deviceNames => {
                m.raw = raw
                m.deviceNames = deviceNames
                root.classifyAll(m, raw, deviceNames)
                root.publish()
                if (codes.length === 0) {
                    m.loading = false
                    root.publish()
                    return
                }

                Exec.run(["ddcutil", "vcpinfo"].concat(codes, ["--verbose"]), info => {
                    if (info.exitCode === 0) {
                        Object.assign(root.vcpInfo, Ddc.parseVcpInfo(info.stdout))
                        root.classifyAll(m, m.raw, m.deviceNames)
                        root.publish()
                    }
                })

                // Exactly the codes this monitor declared -- not "getvcp
                // KNOWN", which drops manufacturer codes ddcutil has no
                // generic entry for. ddcutil exits 1 whenever any code is
                // unreadable (every Write Only one), yet still prints every
                // value that did read, so the exit code isn't checked.
                Exec.run(["ddcutil", "--display", m.id, "getvcp"].concat(codes, ["--terse"]), values => {
                    const parsed = Ddc.parseTerseValues(values.stdout)
                    for (const f of m.raw) {
                        const v = parsed[f.code]
                        if (v) {
                            f.current = v.current
                            f.max = v.max
                        }
                    }
                    root.classifyAll(m, m.raw, m.deviceNames)
                    m.loading = false
                    root.publish()
                })
            })
        })
    }

    // value is the string ddcutil expects (decimal for continuous, "0xNN"
    // for enum/button). The UI updates optimistically; setvcp's exit code
    // is the only confirmation ddcutil gives quickly.
    function setvcp(id, code, value, optimisticCurrent, onError) {
        const m = findMonitor(id)
        if (!m) return
        if (optimisticCurrent !== undefined && optimisticCurrent !== null) {
            for (const f of (m.raw || [])) {
                if (f.code === code) f.current = optimisticCurrent
            }
            classifyAll(m, m.raw || [], m.deviceNames)
            publish()
        }
        Exec.run(["ddcutil", "--display", id, "setvcp", code, value], result => {
            if (result.exitCode !== 0 && onError) onError(result.stderr)
        })
    }
}

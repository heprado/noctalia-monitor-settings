.pragma library
// Monitor Settings -- ddcutil output parsing and VCP feature classification.
//
// Pure functions: DdcService.qml runs ddcutil and feeds the output in,
// the UI renders what classifyFeature decides. No process or file access
// here, so tests/run.mjs can exercise it under node.

var categoryOrder = ["Image", "Audio", "Preset", "Control", "Miscellaneous", "Others"]

function lines(text) {
    return String(text || "").split("\n")
}

// `ddcutil detect`: one "Display N" header per monitor, followed by an
// indented "Model:" line and, under "EDID synopsis:", a "Mfg id:" line --
// the 3-letter VESA PNP id (e.g. "AUS" for ASUSTeK) that devices/ keys its
// override files by, so one file covers a manufacturer's whole lineup.
// The connector ("DRM connector: card1-DP-2") is what ties a display to
// its wlr-randr output name ("DP-2").
function parseDetect(text) {
    var displays = []
    var current = null
    var ls = lines(text)
    for (var i = 0; i < ls.length; i++) {
        var line = ls[i]
        var id = line.match(/^Display (\d+)/)
        if (id) {
            if (current) displays.push(current)
            current = { id: id[1], model: "", mfgId: "", connector: "" }
            continue
        }
        if (!current) continue
        var model = line.match(/^\s+Model:\s+(.+)/)
        if (model) current.model = model[1].trim()
        var mfg = line.match(/^\s+Mfg id:\s+([A-Za-z]+)/)
        if (mfg) current.mfgId = mfg[1].trim()
        var drm = line.match(/^\s+DRM connector:\s+card\d+-(\S+)/)
        if (drm) current.connector = drm[1].trim()
    }
    if (current) displays.push(current)
    return displays
}

// `ddcutil capabilities --terse`'s "vcp(...)" group in the raw MCCS
// capabilities string: bare feature codes ("10") or codes with a value
// list ("14(05 06 08 0B)"), nested one level.
function parseCapabilities(text) {
    var features = []
    text = String(text || "")
    var start = text.indexOf("vcp(")
    if (start === -1) return features
    var i = start + 4
    var depth = 1
    var innerStart = i
    while (i < text.length && depth > 0) {
        var c = text[i]
        if (c === "(") depth++
        else if (c === ")") depth--
        i++
    }
    var inner = text.slice(innerStart, i - 1)

    var re = /([0-9A-Fa-f]{2})(\s*\(([^)]*)\))?/g
    var m
    while ((m = re.exec(inner)) !== null) {
        var values = []
        if (m[3] !== undefined) {
            var vs = m[3].match(/[0-9A-Fa-f]{2}/g) || []
            for (var v = 0; v < vs.length; v++) values.push({ code: vs[v], name: "" })
        }
        features.push({ code: m[1], name: "", values: values })
    }
    return features
}

// `ddcutil getvcp <codes> --terse` mixes three line formats:
//   VCP <code> C <current-dec> <max-dec>
//   VCP <code> SNC x<value-hex>
//   VCP <code> CNC x<max-hi> x<max-lo> x<cur-hi> x<cur-lo>
function parseTerseValues(text) {
    var result = {}
    var ls = lines(text)
    for (var i = 0; i < ls.length; i++) {
        var line = ls[i]
        var c = line.match(/^VCP\s+([0-9A-Fa-f]+)\s+C\s+(\d+)\s+(\d+)/)
        if (c) {
            result[c[1]] = { current: parseInt(c[2], 10), max: parseInt(c[3], 10) }
            continue
        }
        var cnc = line.match(/^VCP\s+([0-9A-Fa-f]+)\s+CNC\s+x([0-9A-Fa-f]+)\s+x([0-9A-Fa-f]+)\s+x([0-9A-Fa-f]+)\s+x([0-9A-Fa-f]+)/)
        if (cnc) {
            result[cnc[1]] = {
                current: parseInt(cnc[4], 16) * 256 + parseInt(cnc[5], 16),
                max: parseInt(cnc[2], 16) * 256 + parseInt(cnc[3], 16)
            }
            continue
        }
        var snc = line.match(/^VCP\s+([0-9A-Fa-f]+)\s+SNC\s+x([0-9A-Fa-f]+)/)
        if (snc) result[snc[1]] = { current: parseInt(snc[2], 16), max: null }
    }
    return result
}

// `ddcutil vcpinfo <codes> --verbose`: generic MCCS knowledge, one
// "VCP code XX: name" block per feature with a description line, an
// "Attributes: ..." (or per-version "Attributes (vX.X): ...") line, an
// optional "Simple NC values:" block and "MCCS specification groups:".
function parseVcpInfo(text) {
    var result = {}
    var code = null, name = null, description = null, descriptionDone = false
    var attrsPlain = null, attrsVersioned = null
    var values = [], inValues = false, groups = []

    function flush() {
        if (!code) return
        var attrs = "", continuity = ""
        var attrsLine = attrsPlain || attrsVersioned
        if (attrsLine) {
            var parts = attrsLine.split(",").map(function (s) { return s.trim() })
            attrs = parts[0] || ""
            continuity = parts[1] || ""
        }
        result[code] = {
            name: name,
            description: description || "",
            attrs: attrs,
            continuity: continuity,
            values: values,
            groups: groups
        }
    }

    var ls = lines(text)
    for (var i = 0; i < ls.length; i++) {
        var line = ls[i]
        var header = line.match(/^VCP code ([0-9A-Fa-f]+): (.+)$/)
        if (header) {
            flush()
            code = header[1]
            name = header[2].trim()
            description = null
            descriptionDone = false
            attrsPlain = attrsVersioned = null
            values = []
            inValues = false
            groups = []
            continue
        }
        if (!code) continue

        if (!descriptionDone) {
            if (/^\s*(MCCS versions:|MCCS specification groups:|ddcutil feature subsets:|Attributes)/.test(line)) {
                descriptionDone = true
            } else if (line.trim().length > 0) {
                description = line.trim()
                descriptionDone = true
            }
        }

        var plain = line.match(/^\s*Attributes:\s*(.+)$/)
        if (plain) {
            attrsPlain = plain[1]
        } else {
            // One line per MCCS version on some features; the newest wins.
            var versioned = line.match(/^\s*Attributes \(v[\d.]+\):\s*(.+)$/)
            if (versioned) attrsVersioned = versioned[1]
        }

        if (/^\s*Simple NC values:\s*$/.test(line)) {
            inValues = true
        } else if (inValues) {
            var v = line.match(/^\s+0x([0-9A-Fa-f]+):\s*(.+)$/)
            if (v) values.push({ code: v[1], name: v[2].trim() })
            else inValues = false
        }

        if (groups.length === 0) {
            var g = line.match(/^\s*MCCS specification groups:\s*(.+)$/)
            if (g) groups = g[1].split(",").map(function (s) { return s.trim() }).filter(function (s) { return s.length > 0 })
        }
    }
    flush()
    return result
}

// Merges a capabilities-derived feature (this monitor's own declared
// codes -- authoritative for what it accepts) with vcpinfo's generic
// knowledge (name/description/attributes/category) and decides which
// control renders it.
//
// deviceNames: proprietary OSD labels ddcutil can't know (devices/*.json),
// keyed by lowercase feature code, then lowercase value code.
function classifyFeature(capFeature, vcpInfoData, deviceNames) {
    var info = vcpInfoData[capFeature.code] || {}
    var attrs = info.attrs || ""
    var continuity = info.continuity || ""
    var device = (deviceNames || {})[capFeature.code.toLowerCase()] || {}

    var vcpNames = {}
    var infoValues = info.values || []
    for (var i = 0; i < infoValues.length; i++)
        vcpNames[infoValues[i].code.toLowerCase()] = infoValues[i].name

    // Which codes a feature accepts is device-specific and only the
    // monitor's own capabilities are authoritative for it. Device OSD
    // names win over vcpinfo's generic ones, which win over bare hex.
    var values = []
    var capValues = capFeature.values || []
    for (var j = 0; j < capValues.length; j++) {
        var lc = capValues[j].code.toLowerCase()
        values.push({ code: capValues[j].code, name: device[lc] || vcpNames[lc] || ("0x" + lc) })
    }

    // Read-only display has no write risk, so it may prefer vcpinfo's
    // (possibly more complete) value names.
    var displayValues = infoValues.length > 0 ? infoValues : values

    var category = (info.groups && info.groups.length > 0) ? info.groups[0] : "Others"

    var widget = "readonly"
    var isContinuous = continuity.indexOf("Continuous") === 0
    var code = capFeature.code
    if (attrs === "Write Only") {
        widget = "button"
    } else if (attrs === "Read Write" && (isContinuous
            || (continuity === "Non-Continuous with continuous subrange" && (code === "10" || code === "12" || code === "62")))) {
        widget = "slider"
    } else if (attrs === "Read Write"
            && (continuity === "Non-Continuous (simple)" || continuity === "Non-Continuous (complex)")
            && values.length > 0) {
        widget = "combobox"
    }

    var displayName = capFeature.name
    if (info.name) displayName = info.name
    else if (!displayName) displayName = "VCP " + code

    return {
        code: code,
        name: displayName,
        description: info.description || "",
        category: category,
        attrs: attrs,
        continuity: continuity,
        values: values,
        displayValues: displayValues,
        widget: widget,
        current: capFeature.current === undefined ? null : capFeature.current,
        max: capFeature.max === undefined ? null : capFeature.max
    }
}

// AC/AE (horizontal/vertical frequency) are Continuous, but ddcutil scales
// them specifically: AC is Hz as-is, AE is centihertz.
function readOnlyDisplay(f) {
    if (f.current === null || f.current === undefined) return null
    if (f.code === "AC") return f.current + " Hz"
    if (f.code === "AE") return (f.current / 100).toFixed(2) + " Hz"
    var dv = f.displayValues || []
    for (var i = 0; i < dv.length; i++) {
        if (parseInt(dv[i].code, 16) === f.current) return dv[i].name
    }
    return String(f.current)
}

function findFeature(features, code) {
    for (var i = 0; i < (features || []).length; i++) {
        if (features[i].code === code) return features[i]
    }
    return null
}

// Buckets features by category in categoryOrder (unknown categories
// alphabetically in between, Others last). 8D (Audio mute) is excluded:
// it's composited onto 62's (speaker volume) slider as a mute button.
function groupFeaturesByCategory(features) {
    var byCategory = {}
    var seen = []
    for (var i = 0; i < features.length; i++) {
        var f = features[i]
        if (f.code === "8D") continue
        if (!byCategory[f.category]) {
            byCategory[f.category] = []
            seen.push(f.category)
        }
        byCategory[f.category].push(f)
    }
    var ordered = []
    for (var k = 0; k < categoryOrder.length; k++) {
        var cat = categoryOrder[k]
        if (cat !== "Others" && byCategory[cat]) ordered.push({ category: cat, features: byCategory[cat] })
    }
    var extra = seen.filter(function (c) { return categoryOrder.indexOf(c) === -1 }).sort()
    for (var e = 0; e < extra.length; e++) ordered.push({ category: extra[e], features: byCategory[extra[e]] })
    if (byCategory["Others"]) ordered.push({ category: "Others", features: byCategory["Others"] })
    return ordered
}

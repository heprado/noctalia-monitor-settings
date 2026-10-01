.pragma library
// Monitor Settings -- wlroots output parsing and display-arrangement math.
//
// Pure functions over `wlr-randr --json`, the generic wlroots equivalent
// of xrandr -- works on any compositor implementing
// wlr-output-management-v1 (Hyprland, Sway, river, ...). DisplayService.qml
// owns every `wlr-randr` invocation; this file never touches a process or
// a file, so tests/run.mjs can exercise it under node.
//
// Two shapes flow through here:
//   * an *output* is what wlr-randr reports (parseOutputs): identity,
//     every mode it supports, physical size, and its live settings;
//   * a *config* is the editable subset of an output's settings
//     (configFromOutput): { enabled, width, height, refresh, x, y,
//     transform, scale, adaptiveSync }. The UI edits configs as a draft,
//     DisplayService diffs them against the live outputs into one atomic
//     `wlr-randr` invocation (buildApplyArgs) and persists them.

// Every value `wlr-randr --transform` accepts, in wl_output's enum order.
var TRANSFORMS = ["normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270"]

// Common fractional scales, offered as presets.
var SCALE_PRESETS = [0.5, 0.75, 1, 1.25, 1.5, 1.6, 1.75, 2, 2.25, 2.5, 3]

function isTransform(t) {
    return TRANSFORMS.indexOf(t) !== -1
}

// rawList is one already-parsed `wlr-randr --json` array. Each element
// (wlr-randr's print_state_json): { name, description, make, model,
// serial, physical_size: {width, height} (mm), enabled, modes: [{width,
// height, refresh, preferred, current}] } -- plus, only when enabled,
// position: {x, y}, transform, scale and adaptive_sync (true/false, or
// null when the compositor's protocol version can't report it).
// Disabled outputs are kept: the UI needs them listed to turn them on.
function parseOutputs(rawList) {
    var outputs = []
    if (!Array.isArray(rawList)) return outputs
    for (var i = 0; i < rawList.length; i++) {
        var raw = rawList[i]
        if (!raw || typeof raw.name !== "string") continue
        var modes = []
        var width = null, height = null, refresh = null
        var rawModes = Array.isArray(raw.modes) ? raw.modes : []
        for (var j = 0; j < rawModes.length; j++) {
            var m = rawModes[j]
            if (!m || typeof m.width !== "number" || typeof m.height !== "number") continue
            var mode = {
                width: m.width,
                height: m.height,
                refresh: Number(m.refresh) || 0,
                preferred: m.preferred === true,
                current: m.current === true
            }
            modes.push(mode)
            if (mode.current) {
                width = mode.width
                height = mode.height
                refresh = mode.refresh
            }
        }
        var phys = raw.physical_size || {}
        outputs.push({
            name: raw.name,
            description: raw.description || "",
            make: raw.make || "",
            model: raw.model || "",
            serial: raw.serial || "",
            enabled: raw.enabled !== false,
            modes: modes,
            width: width,
            height: height,
            refresh: refresh,
            x: (raw.position && raw.position.x) || 0,
            y: (raw.position && raw.position.y) || 0,
            transform: isTransform(raw.transform) ? raw.transform : "normal",
            scale: Number(raw.scale) || 1,
            adaptiveSync: (raw.adaptive_sync === true || raw.adaptive_sync === false) ? raw.adaptive_sync : null,
            physWidth: Number(phys.width) || 0,
            physHeight: Number(phys.height) || 0
        })
    }
    return outputs
}

// The mode a disabled output would come back on with: current, else
// preferred, else the first -- wlr-randr's own `--on` fixup order.
function fallbackMode(o) {
    var preferred = null, first = null
    for (var i = 0; i < o.modes.length; i++) {
        var m = o.modes[i]
        if (m.current) return m
        if (m.preferred && !preferred) preferred = m
        if (!first) first = m
    }
    return preferred || first
}

function configFromOutput(o) {
    var width = o.width, height = o.height, refresh = o.refresh
    if (width === null || width === undefined) {
        var m = fallbackMode(o)
        if (m) {
            width = m.width
            height = m.height
            refresh = m.refresh
        }
    }
    return {
        enabled: o.enabled !== false,
        width: width,
        height: height,
        refresh: refresh,
        x: o.x || 0,
        y: o.y || 0,
        transform: o.transform || "normal",
        scale: o.scale || 1,
        adaptiveSync: o.adaptiveSync
    }
}

function configsFromOutputs(outputs) {
    var configs = {}
    for (var i = 0; i < outputs.length; i++)
        configs[outputs[i].name] = configFromOutput(outputs[i])
    return configs
}

function copyConfigs(configs) {
    var out = {}
    for (var name in configs)
        out[name] = Object.assign({}, configs[name])
    return out
}

function isRotated(transform) {
    return transform === "90" || transform === "270" || transform === "flipped-90" || transform === "flipped-270"
}

// The size an output occupies in the compositor's logical coordinate
// space: its mode, swapped for a quarter turn, divided by scale. Rounded,
// because wlroots positions are integers -- a fractional edge would leave
// "touching" outputs one pixel apart (or overlapping).
function logicalSize(cfg) {
    var w = cfg.width || 0
    var h = cfg.height || 0
    if (isRotated(cfg.transform)) {
        var t = w; w = h; h = t
    }
    var scale = cfg.scale > 0 ? cfg.scale : 1
    return { width: Math.round(w / scale), height: Math.round(h / scale) }
}

// Rotates a transform a quarter turn, keeping whether it is flipped:
// direction 1 is clockwise, -1 counter-clockwise.
function rotateTransform(transform, direction) {
    var flipped = transform.indexOf("flipped") === 0
    var base = flipped ? transform.slice(8) : transform
    var degrees = (base === "" || base === "normal") ? 0 : (parseInt(base, 10) || 0)
    degrees = (((degrees + 90 * direction) % 360) + 360) % 360
    if (flipped) return degrees === 0 ? "flipped" : "flipped-" + degrees
    return degrees === 0 ? "normal" : String(degrees)
}

function trimNumber(s) {
    if (s.indexOf(".") === -1) return s
    return s.replace(/0+$/, "").replace(/\.$/, "")
}

// wlr-randr --json prints refresh with %f and matches a requested mode by
// rounding the given Hz to mHz, so three decimals is always exact.
function formatRefresh(refresh) {
    return trimNumber(Number(refresh).toFixed(3))
}

function formatScale(scale) {
    return trimNumber(Number(scale).toFixed(4))
}

function modeArg(cfg) {
    return cfg.width + "x" + cfg.height + "@" + formatRefresh(cfg.refresh || 0) + "Hz"
}

// Distinct resolutions an output supports, largest first.
function resolutions(o) {
    var seen = {}
    var list = []
    for (var i = 0; i < o.modes.length; i++) {
        var m = o.modes[i]
        var key = m.width + "x" + m.height
        if (seen[key]) continue
        seen[key] = true
        list.push({ width: m.width, height: m.height })
    }
    list.sort(function (a, b) {
        if (a.width * a.height !== b.width * b.height) return b.width * b.height - a.width * a.height
        return b.width - a.width
    })
    return list
}

// Distinct refresh rates at one resolution, fastest first.
function refreshRates(o, width, height) {
    var seen = {}
    var list = []
    for (var i = 0; i < o.modes.length; i++) {
        var m = o.modes[i]
        if (m.width !== width || m.height !== height) continue
        var key = formatRefresh(m.refresh)
        if (seen[key]) continue
        seen[key] = true
        list.push(m.refresh)
    }
    list.sort(function (a, b) { return b - a })
    return list
}

function hasMode(o, width, height, refresh) {
    if (width == null || height == null || refresh == null) return false
    var want = formatRefresh(refresh)
    for (var i = 0; i < o.modes.length; i++) {
        var m = o.modes[i]
        if (m.width === width && m.height === height && formatRefresh(m.refresh) === want) return true
    }
    return false
}

// Pixel density from the EDID's physical size (millimetres). null when
// the size is unknown (0x0 -- projectors, some TVs, virtual outputs).
function physicalDpi(o, cfg) {
    var w = cfg.width || 0, h = cfg.height || 0
    if (o.physWidth <= 0 || o.physHeight <= 0 || w <= 0 || h <= 0) return null
    var diagPx = Math.sqrt(w * w + h * h)
    var diagIn = Math.sqrt(o.physWidth * o.physWidth + o.physHeight * o.physHeight) / 25.4
    return diagPx / diagIn
}

// What a scaled output's DPI looks like to applications: Wayland has no
// separate per-monitor DPI knob -- scale is that knob.
function effectiveDpi(o, cfg) {
    var dpi = physicalDpi(o, cfg)
    if (dpi === null) return null
    return dpi / (cfg.scale > 0 ? cfg.scale : 1)
}

// Inverse of effectiveDpi, rounded to a multiple of 1/120 (the
// fractional-scale-v1 protocol's granularity) and clamped.
function scaleForDpi(o, cfg, targetDpi) {
    var dpi = physicalDpi(o, cfg)
    if (dpi === null || !(targetDpi > 0)) return null
    var scale = Math.round(dpi / targetDpi * 120) / 120
    return Math.min(4, Math.max(0.25, scale))
}

// ---------------------------------------------------------------------
// Arrangement
// ---------------------------------------------------------------------

function rectOf(cfg) {
    var s = logicalSize(cfg)
    return { x: cfg.x || 0, y: cfg.y || 0, w: s.width, h: s.height }
}

function overlaps(a, b) {
    return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

function touches(a, b) {
    var xTouch = (a.x + a.w === b.x || b.x + b.w === a.x) && a.y < b.y + b.h && b.y < a.y + a.h
    var yTouch = (a.y + a.h === b.y || b.y + b.h === a.y) && a.x < b.x + b.w && b.x < a.x + a.w
    return xTouch || yTouch
}

// Other enabled outputs' rects, in a stable (name) order so the same drop
// always resolves the same way.
function otherRects(configs, exclude) {
    var names = Object.keys(configs).sort()
    var rects = []
    for (var i = 0; i < names.length; i++) {
        var cfg = configs[names[i]]
        if (names[i] !== exclude && cfg.enabled && cfg.width) rects.push(rectOf(cfg))
    }
    return rects
}

// Where a monitor dragged to (x, y) should actually land:
//   1. its edges snap to other monitors' edges within `threshold`
//      (side by side, or aligned), independently per axis;
//   2. any overlap left is pushed out along the shortest direction;
//   3. a monitor floating apart from all the others is pulled in to touch
//      the nearest one -- a gap between monitors is a dead zone the cursor
//      can't cross.
// Every other monitor stays where it is.
function snapPosition(configs, name, x, y, threshold) {
    var size = logicalSize(configs[name])
    var w = size.width, h = size.height
    var others = otherRects(configs, name)
    x = Math.round(x)
    y = Math.round(y)
    if (others.length === 0) return { x: x, y: y }

    function bestSnap(value, candidates) {
        var best = value, bestDist = threshold + 1
        for (var i = 0; i < candidates.length; i++) {
            var d = Math.abs(candidates[i] - value)
            if (d < bestDist) {
                best = candidates[i]
                bestDist = d
            }
        }
        return bestDist <= threshold ? best : value
    }

    var xs = [], ys = []
    for (var i = 0; i < others.length; i++) {
        var o = others[i]
        xs.push(o.x - w, o.x + o.w, o.x, o.x + o.w - w)
        ys.push(o.y - h, o.y + o.h, o.y, o.y + o.h - h)
    }
    x = bestSnap(x, xs)
    y = bestSnap(y, ys)

    function self() { return { x: x, y: y, w: w, h: h } }

    function resolveOverlaps() {
        // Bounded: each push clears one overlap but can create another
        // with a neighbour; a handful of rounds settles any real layout.
        for (var round = 0; round < 16; round++) {
            var hit = null
            for (var k = 0; k < others.length; k++) {
                if (overlaps(self(), others[k])) {
                    hit = others[k]
                    break
                }
            }
            if (!hit) return
            var moves = [
                { dx: hit.x - w - x, dy: 0 },
                { dx: hit.x + hit.w - x, dy: 0 },
                { dx: 0, dy: hit.y - h - y },
                { dx: 0, dy: hit.y + hit.h - y }
            ]
            var best = moves[0]
            for (var m = 1; m < moves.length; m++) {
                if (Math.abs(moves[m].dx) + Math.abs(moves[m].dy) < Math.abs(best.dx) + Math.abs(best.dy))
                    best = moves[m]
            }
            x += best.dx
            y += best.dy
        }
    }

    resolveOverlaps()

    var touching = false
    for (var t = 0; t < others.length; t++) {
        if (touches(self(), others[t])) {
            touching = true
            break
        }
    }
    if (!touching) {
        var nearest = null, nearestGap = Infinity
        for (var n = 0; n < others.length; n++) {
            var oo = others[n]
            var gx0 = Math.max(oo.x - (x + w), x - (oo.x + oo.w), 0)
            var gy0 = Math.max(oo.y - (y + h), y - (oo.y + oo.h), 0)
            if (gx0 + gy0 < nearestGap) {
                nearest = oo
                nearestGap = gx0 + gy0
            }
        }
        var p = nearest
        var gx = Math.max(p.x - (x + w), x - (p.x + p.w), 0)
        var gy = Math.max(p.y - (y + h), y - (p.y + p.h), 0)
        // Side by side along the axis with the bigger gap; on the other
        // axis, a monitor entirely past the neighbour's edge (a diagonal
        // drop) is aligned to that edge -- touching at a corner isn't
        // adjacency the cursor can cross.
        if (gx >= gy) {
            x = (x + w <= p.x) ? p.x - w : p.x + p.w
            if (y + h <= p.y) y = p.y
            else if (y >= p.y + p.h) y = p.y + p.h - h
        } else {
            y = (y + h <= p.y) ? p.y - h : p.y + p.h
            if (x + w <= p.x) x = p.x
            else if (x >= p.x + p.w) x = p.x + p.w - w
        }
        resolveOverlaps()
    }
    return { x: x, y: y }
}

// Shifts every enabled output so the arrangement's top-left corner sits
// at (0, 0) -- some clients misbehave with negative global coordinates,
// and a drag left of the leftmost monitor produces exactly that.
function normalizeOrigin(configs) {
    var minX = Infinity, minY = Infinity
    for (var name in configs) {
        var cfg = configs[name]
        if (cfg.enabled && cfg.width) {
            minX = Math.min(minX, cfg.x || 0)
            minY = Math.min(minY, cfg.y || 0)
        }
    }
    if (minX === Infinity) return
    for (var n in configs) {
        var c = configs[n]
        if (c.enabled && c.width) {
            c.x = (c.x || 0) - minX
            c.y = (c.y || 0) - minY
        }
    }
}

// View transform for drawing the arrangement on a canvasW x canvasH area:
// the bounding box of every enabled output plus a margin (room to drop a
// monitor beside the outermost ones), scaled to fit and centred.
// canvasX = (x - ox) * scale.
function computeView(configs, canvasW, canvasH) {
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity, maxDim = 0
    for (var name in configs) {
        var cfg = configs[name]
        if (!cfg.enabled || !cfg.width) continue
        var r = rectOf(cfg)
        minX = Math.min(minX, r.x)
        minY = Math.min(minY, r.y)
        maxX = Math.max(maxX, r.x + r.w)
        maxY = Math.max(maxY, r.y + r.h)
        maxDim = Math.max(maxDim, r.w, r.h)
    }
    if (minX === Infinity || canvasW <= 0 || canvasH <= 0)
        return { scale: Math.max(canvasW, 1) / 3840, ox: 0, oy: 0 }
    var margin = maxDim * 0.3
    var scale = Math.min(canvasW / (maxX - minX + 2 * margin), canvasH / (maxY - minY + 2 * margin))
    return {
        scale: scale,
        ox: minX - (canvasW / scale - (maxX - minX)) / 2,
        oy: minY - (canvasH / scale - (maxY - minY)) / 2
    }
}

// ---------------------------------------------------------------------
// Applying
// ---------------------------------------------------------------------

function sameNumber(a, b, eps) {
    if (a == null || b == null) return a == b
    return Math.abs(a - b) < eps
}

// One `wlr-randr` argv covering every output whose config differs from
// its live state, or null when nothing differs. A single invocation is
// one wlr-output-management configuration, applied atomically by the
// compositor -- moving three monitors at once never passes through an
// intermediate overlapping arrangement it could reject.
//
// Once anything changes, every output that stays on gets its position in
// the call, changed or not. Hyprland lays out any output the request
// doesn't position by its own monitor rule, so with the common
// `position = "auto"` rule, moving one monitor shoves an untouched
// neighbour aside (eDP-1 moved below HDMI-A-1 sends HDMI-A-1 from 0,0 to
// the right of it) -- which is exactly the state right after login.
//
// `risky` reports whether anything beyond position/adaptive sync changed
// (mode, scale, rotation, on/off): the changes that can leave a screen
// unreadable, which DisplayService asks the user to confirm.
function buildApplyArgs(outputs, configs, program) {
    var args = [program || "wlr-randr"]
    var any = false
    var risky = false
    var perOutput = []

    // Never turn every output off: no screen would be left to undo it on.
    var anyEnabled = false
    for (var i = 0; i < outputs.length; i++) {
        var c0 = configs[outputs[i].name]
        if (c0 ? c0.enabled : outputs[i].enabled) anyEnabled = true
    }
    if (!anyEnabled) return { args: null, risky: false }

    for (var k = 0; k < outputs.length; k++) {
        var o = outputs[k]
        var cfg = configs[o.name]
        var out = []
        if (!cfg) {
            perOutput.push({ output: o, cfg: null, out: out })
            continue
        }
        if (!cfg.enabled) {
            if (o.enabled) {
                out.push("--off")
                risky = true
            }
        } else {
            if (!o.enabled) {
                out.push("--on")
                risky = true
            }
            var modeChanged = cfg.width !== o.width || cfg.height !== o.height || !sameNumber(cfg.refresh, o.refresh, 0.0005)
            if (cfg.width && (modeChanged || !o.enabled) && hasMode(o, cfg.width, cfg.height, cfg.refresh)) {
                out.push("--mode", modeArg(cfg))
                risky = true
            }
            if (cfg.transform !== o.transform || !o.enabled) {
                out.push("--transform", cfg.transform)
                if (cfg.transform !== o.transform) risky = true
            }
            var scaleChanged = !sameNumber(cfg.scale, o.scale, 0.0001)
            if (scaleChanged || !o.enabled) {
                out.push("--scale", formatScale(cfg.scale))
                if (scaleChanged) risky = true
            }
            if (cfg.x !== o.x || cfg.y !== o.y || !o.enabled)
                out.push("--pos", Math.floor(cfg.x) + "," + Math.floor(cfg.y))
            // null means the compositor can't report (or set) it; passing
            // the flag then makes wlr-randr fail the whole command.
            if (cfg.adaptiveSync != null && o.adaptiveSync != null && cfg.adaptiveSync !== o.adaptiveSync)
                out.push("--adaptive-sync", cfg.adaptiveSync ? "enabled" : "disabled")
        }
        if (out.length > 0) any = true
        perOutput.push({ output: o, cfg: cfg, out: out })
    }
    if (!any) return { args: null, risky: false }

    for (var p = 0; p < perOutput.length; p++) {
        var entry = perOutput[p]
        var staysOn = entry.cfg ? entry.cfg.enabled : entry.output.enabled
        if (staysOn && entry.out.indexOf("--pos") < 0) {
            var at = entry.cfg || entry.output
            entry.out.push("--pos", Math.floor(at.x) + "," + Math.floor(at.y))
        }
        if (entry.out.length > 0) {
            args.push("--output", entry.output.name)
            for (var a = 0; a < entry.out.length; a++) args.push(entry.out[a])
        }
    }
    return { args: args, risky: risky }
}

// A saved config, minus anything the live output can no longer honour (a
// mode it stopped advertising, an adaptive-sync state the compositor
// can't set) -- those fields fall back to the live value.
function sanitizeSaved(o, saved) {
    var cfg = configFromOutput(o)
    if (!saved || typeof saved !== "object") return cfg
    if (typeof saved.enabled === "boolean") cfg.enabled = saved.enabled
    if (hasMode(o, saved.width, saved.height, saved.refresh)) {
        cfg.width = saved.width
        cfg.height = saved.height
        cfg.refresh = saved.refresh
    }
    if (isTransform(saved.transform)) cfg.transform = saved.transform
    if (typeof saved.scale === "number" && saved.scale > 0) cfg.scale = saved.scale
    if (typeof saved.x === "number" && typeof saved.y === "number") {
        cfg.x = Math.floor(saved.x)
        cfg.y = Math.floor(saved.y)
    }
    if (o.adaptiveSync != null && typeof saved.adaptiveSync === "boolean") cfg.adaptiveSync = saved.adaptiveSync
    return cfg
}

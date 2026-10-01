// Tests for app/lib/*.js -- the pure parsing/layout logic.
//
// Run: node monitor-settings/app/tests/run.mjs
//
// The libs are QML JavaScript resources (`.pragma library` first line),
// not ES modules; this strips the pragma and evaluates each in its own
// context, the same isolation QML gives a `.pragma library` file.

import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import vm from "node:vm"
import assert from "node:assert/strict"

const here = dirname(fileURLToPath(import.meta.url))

function loadLib(name) {
  const src = readFileSync(join(here, "..", "lib", name), "utf8").replace(/^\.pragma library\s*\n/, "")
  const ctx = vm.createContext({})
  vm.runInContext(src, ctx, { filename: name })
  return ctx
}

const D = loadLib("Displays.js")
const C = loadLib("Ddc.js")

let passed = 0
function test(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    console.error(`FAIL ${name}\n  ${e.message}`)
    process.exitCode = 1
  }
}

// --- Displays.js -------------------------------------------------------

// nwg-displays' screenshot setup: portrait DP-1 left, 120 Hz laptop panel
// middle, a TV that's currently off.
const raw = [
  {
    name: "eDP-1", description: "Unknown 0xD0ED 0x00000000 (eDP-1)", make: "Unknown", model: "0xD0ED",
    physical_size: { width: 344, height: 194 }, enabled: true,
    modes: [
      { width: 1920, height: 1080, refresh: 120.114, preferred: true, current: true },
      { width: 1920, height: 1080, refresh: 60.0, preferred: false, current: false },
      { width: 1280, height: 720, refresh: 60.0, preferred: false, current: false },
    ],
    position: { x: 1080, y: 840 }, transform: "normal", scale: 1.0, adaptive_sync: false,
  },
  {
    name: "DP-1", description: "ASUSTek COMPUTER INC VG278 M3LMQS291655 (DP-1)",
    physical_size: { width: 598, height: 336 }, enabled: true,
    modes: [{ width: 1920, height: 1080, refresh: 144.001007, preferred: true, current: true }],
    position: { x: 0, y: 0 }, transform: "90", scale: 1.0, adaptive_sync: null,
  },
  {
    name: "HDMI-A-1", description: "Some TV (HDMI-A-1)", physical_size: { width: 0, height: 0 }, enabled: false,
    modes: [
      { width: 3840, height: 2160, refresh: 60.0, preferred: true, current: false },
      { width: 1920, height: 1080, refresh: 60.0, preferred: false, current: false },
    ],
  },
]

const outputs = D.parseOutputs(raw)
const [edp, dp, hdmi] = outputs

test("parseOutputs keeps disabled outputs and reads every field", () => {
  assert.equal(outputs.length, 3)
  assert.equal(edp.width, 1920)
  assert.equal(edp.refresh, 120.114)
  assert.equal(edp.adaptiveSync, false)
  assert.equal(edp.modes.length, 3)
  assert.equal(dp.transform, "90")
  assert.equal(dp.adaptiveSync, null)
  assert.equal(hdmi.enabled, false)
  assert.equal(hdmi.width, null)
})

test("configFromOutput falls back to the preferred mode when disabled", () => {
  const cfg = D.configFromOutput(hdmi)
  assert.equal(cfg.width, 3840)
  assert.equal(cfg.enabled, false)
})

test("logicalSize swaps for rotation and divides by scale", () => {
  assert.deepEqual({ ...D.logicalSize(D.configFromOutput(dp)) }, { width: 1080, height: 1920 })
  assert.deepEqual({ ...D.logicalSize({ width: 2560, height: 1440, transform: "normal", scale: 1.25 }) }, { width: 2048, height: 1152 })
})

test("rotateTransform keeps flip and wraps", () => {
  assert.equal(D.rotateTransform("normal", 1), "90")
  assert.equal(D.rotateTransform("normal", -1), "270")
  assert.equal(D.rotateTransform("270", 1), "normal")
  assert.equal(D.rotateTransform("flipped", 1), "flipped-90")
  assert.equal(D.rotateTransform("flipped-90", -1), "flipped")
})

test("formatting round-trips through wlr-randr's parser", () => {
  assert.equal(D.formatRefresh(120.114), "120.114")
  assert.equal(D.formatRefresh(60), "60")
  assert.equal(D.formatRefresh(144.001007), "144.001")
  assert.equal(D.modeArg({ width: 1920, height: 1080, refresh: 59.94 }), "1920x1080@59.94Hz")
  assert.equal(D.formatScale(1.25), "1.25")
  assert.equal(D.formatScale(2), "2")
})

test("resolutions and refresh rates are distinct and sorted", () => {
  const res = D.resolutions(edp)
  assert.equal(res.length, 2)
  assert.equal(res[0].width, 1920)
  const rates = D.refreshRates(edp, 1920, 1080)
  assert.equal(rates.length, 2)
  assert.equal(rates[0], 120.114)
})

test("DPI from physical size, and scale from a target DPI", () => {
  const dpi = D.physicalDpi(edp, D.configFromOutput(edp))
  assert.ok(dpi > 140 && dpi < 143, `~141 dpi, got ${dpi}`)
  assert.equal(D.physicalDpi(hdmi, D.configFromOutput(hdmi)), null)
  const s = D.scaleForDpi(edp, D.configFromOutput(edp), 96)
  assert.ok(Math.abs(s - 1.475) < 0.01, `scale ${s}`)
})

test("buildApplyArgs: no change -> null", () => {
  assert.equal(D.buildApplyArgs(outputs, D.configsFromOutputs(outputs)).args, null)
})

test("buildApplyArgs: position-only change isn't risky", () => {
  const configs = D.configsFromOutputs(outputs)
  configs["eDP-1"].x = 1200
  const r = D.buildApplyArgs(outputs, configs)
  // DP-1 is untouched but still pinned, or an "auto" monitor rule moves it.
  assert.equal(r.args.join(" "), "wlr-randr --output eDP-1 --pos 1200,840 --output DP-1 --pos 0,0")
  assert.equal(r.risky, false)
})

test("buildApplyArgs: mode + adaptive sync + turning an output on, atomically", () => {
  const configs = D.configsFromOutputs(outputs)
  configs["eDP-1"].refresh = 60
  configs["eDP-1"].adaptiveSync = true
  configs["DP-1"].adaptiveSync = true // unknown live state: never passed
  configs["HDMI-A-1"].enabled = true
  configs["HDMI-A-1"].x = 3000
  const r = D.buildApplyArgs(outputs, configs)
  assert.equal(r.args.join(" "),
    "wlr-randr --output eDP-1 --mode 1920x1080@60Hz --adaptive-sync enabled --pos 1080,840"
    + " --output DP-1 --pos 0,0"
    + " --output HDMI-A-1 --on --mode 3840x2160@60Hz --transform normal --scale 1 --pos 3000,0")
  assert.equal(r.risky, true)
})

test("buildApplyArgs pins every output that stays on, even one with no config", () => {
  // The login case: Hyprland just laid every output out by its "auto" rule,
  // and only eDP-1 differs from what was saved. DP-1 has nothing saved.
  const configs = { "eDP-1": { ...D.configsFromOutputs(outputs)["eDP-1"], y: 0 } }
  assert.equal(D.buildApplyArgs(outputs, configs).args.join(" "),
    "wlr-randr --output eDP-1 --pos 1080,0 --output DP-1 --pos 0,0")
})

test("buildApplyArgs doesn't pin an output being turned off", () => {
  const configs = D.configsFromOutputs(outputs)
  configs["DP-1"].enabled = false
  assert.equal(D.buildApplyArgs(outputs, configs).args.join(" "),
    "wlr-randr --output eDP-1 --pos 1080,840 --output DP-1 --off")
})

test("buildApplyArgs refuses to turn every output off", () => {
  const configs = D.configsFromOutputs(outputs)
  configs["eDP-1"].enabled = false
  configs["DP-1"].enabled = false
  assert.equal(D.buildApplyArgs(outputs, configs).args, null)
})

test("buildApplyArgs never passes a mode the output doesn't advertise", () => {
  const configs = D.configsFromOutputs(outputs)
  configs["eDP-1"].width = 1234
  assert.equal(D.buildApplyArgs(outputs, configs).args, null)
})

const layout = () => ({
  A: { enabled: true, width: 1920, height: 1080, refresh: 60, transform: "90", scale: 1, x: 0, y: 0 },
  B: { enabled: true, width: 1920, height: 1080, refresh: 60, transform: "normal", scale: 1, x: 1080, y: 840 },
})

test("snapPosition snaps flush to a neighbour's edges", () => {
  const p = D.snapPosition(layout(), "B", 1120, 800, 100)
  assert.deepEqual({ ...p }, { x: 1080, y: 840 })
})

test("snapPosition pushes an overlapping drop out", () => {
  const p = D.snapPosition(layout(), "B", 500, 300, 50)
  assert.ok(!(p.x < 1080 && p.x + 1920 > 0 && p.y < 1920 && p.y + 1080 > 0), `overlap at ${p.x},${p.y}`)
})

test("snapPosition pulls a detached monitor in", () => {
  const p = D.snapPosition(layout(), "B", 5000, 200, 50)
  assert.deepEqual({ ...p }, { x: 1080, y: 200 })
})

test("snapPosition aligns a diagonal drop instead of touching at a corner", () => {
  const p = D.snapPosition(layout(), "B", -3000, -2000, 50)
  assert.deepEqual({ ...p }, { x: -1920, y: 0 })
})

test("snapPosition never leaves an overlap after pulling in", () => {
  const configs = {
    A: { enabled: true, width: 1000, height: 1000, transform: "normal", scale: 1, x: 0, y: 0 },
    C: { enabled: true, width: 1000, height: 1000, transform: "normal", scale: 1, x: 1000, y: 0 },
    B: { enabled: true, width: 1000, height: 1000, transform: "normal", scale: 1, x: 0, y: 0 },
  }
  const p = D.snapPosition(configs, "B", 900, 5000, 10)
  for (const o of [configs.A, configs.C]) {
    assert.ok(!(p.x < o.x + 1000 && o.x < p.x + 1000 && p.y < o.y + 1000 && o.y < p.y + 1000), `overlap at ${p.x},${p.y}`)
  }
})

test("normalizeOrigin moves the top-left to 0,0 and skips disabled outputs", () => {
  const c = {
    A: { enabled: true, width: 100, height: 100, transform: "normal", scale: 1, x: -100, y: 50 },
    B: { enabled: true, width: 100, height: 100, transform: "normal", scale: 1, x: 0, y: 60 },
    C: { enabled: false, width: 100, height: 100, transform: "normal", scale: 1, x: -500, y: -500 },
  }
  D.normalizeOrigin(c)
  assert.deepEqual([c.A.x, c.A.y, c.B.x, c.B.y, c.C.x], [0, 0, 100, 10, -500])
})

test("computeView fits every monitor inside the canvas", () => {
  const v = D.computeView(layout(), 640, 300)
  assert.ok(v.scale > 0)
  assert.ok((0 - v.ox) * v.scale >= 0)
  assert.ok((1080 + 1920 - v.ox) * v.scale <= 640)
  assert.ok((1920 - v.oy) * v.scale <= 300)
})

test("sanitizeSaved drops a mode the output no longer has", () => {
  const cfg = D.sanitizeSaved(edp, { enabled: true, width: 9999, height: 9999, refresh: 60, transform: "180", scale: 1.5, x: 10, y: 20 })
  assert.equal(cfg.width, 1920)
  assert.equal(cfg.transform, "180")
  assert.equal(cfg.scale, 1.5)
  assert.equal(cfg.x, 10)
})

// --- Ddc.js ------------------------------------------------------------

const detect = `Display 1
   I2C bus:  /dev/i2c-5
   DRM connector:           card1-DP-2
   EDID synopsis:
      Mfg id:               AUS - ASUSTek COMPUTER INC
      Model:                VG278
      Product code:         9081  (0x2379)
      Serial number:        M3LMQS291655
   VCP version:         2.2

Display 2
   I2C bus:  /dev/i2c-7
   DRM connector:           card1-HDMI-A-1
   EDID synopsis:
      Mfg id:               DEL - Dell Inc.
      Model:                DELL U2720Q
   VCP version:         2.1
`

test("parseDetect reads id, model, manufacturer and connector", () => {
  const d = C.parseDetect(detect)
  assert.equal(d.length, 2)
  assert.deepEqual({ ...d[0] }, { id: "1", model: "VG278", mfgId: "AUS", connector: "DP-2" })
  assert.equal(d[1].connector, "HDMI-A-1")
  assert.equal(d[1].model, "DELL U2720Q")
})

const caps = `Unparsed capabilities string: (prot(monitor)type(LCD)model(VG278)cmds(01 02 03 07 0C F3)vcp(02 04 05 08 0B 0C 10 12 14(05 06 08 0B) 16 18 1A 60(01 03 11 0F) 62 8D(01 02) AC AE B6 C6 C8 CA CC(01 02 03 04 05 06 07 08 09 0A 0C 0D 11 12 14 1A 1E 1F 20 24 25) D6(01 04) DF E0 E1)mswhql(1)asset_eep(32)mccs_ver(2.2))`

test("parseCapabilities reads bare codes and nested value lists", () => {
  const f = C.parseCapabilities(caps)
  const codes = f.map((x) => x.code)
  assert.ok(codes.includes("10") && codes.includes("E1"))
  const input = f.find((x) => x.code === "60")
  assert.deepEqual([...input.values.map((v) => v.code)], ["01", "03", "11", "0F"])
  assert.equal(f.find((x) => x.code === "10").values.length, 0)
  assert.equal(f.length, 26)
})

test("parseTerseValues handles C, SNC and CNC lines", () => {
  const v = C.parseTerseValues(`VCP 10 C 50 100
VCP 60 SNC x0f
VCP DF CNC x00 x00 x02 x02
Feature 04 (Restore factory defaults) is not readable`)
  assert.deepEqual({ ...v["10"] }, { current: 50, max: 100 })
  assert.deepEqual({ ...v["60"] }, { current: 15, max: null })
  assert.deepEqual({ ...v["DF"] }, { current: 514, max: 0 })
})

const vcpinfo = `VCP code 10: Brightness
   Increase/decrease the brightness of the image.
   MCCS versions: 2.0, 2.1, 3.0, 2.2
   MCCS specification groups: Image
   ddcutil feature subsets: Color
   Attributes: Read Write, Continuous (normal)

VCP code 60: Input Source
   Selects active video source
   MCCS versions: 2.0, 2.1, 3.0, 2.2
   MCCS specification groups: Miscellaneous
   Attributes (v2.0): Read Write, Non-Continuous (simple)
   Attributes (v2.2): Read Write, Non-Continuous (simple)
   Simple NC values:
      0x01: VGA-1
      0x03: DVI-1
      0x0f: DisplayPort-1
      0x11: HDMI-1

VCP code 04: Restore factory defaults
   Restore all factory presets including luminance/contrast, geometry, color and TV defaults.
   MCCS versions: 2.0, 2.1, 3.0, 2.2
   MCCS specification groups: Control
   Attributes: Write Only, Non-Continuous (non-table)

VCP code AE: Vertical frequency
   Vertical synchronization signal frequency as determined by the display, in .01 hz
   MCCS specification groups: Miscellaneous
   Attributes: Read Only, Continuous (normal)
`

test("parseVcpInfo reads name, description, attributes, values and groups", () => {
  const info = C.parseVcpInfo(vcpinfo)
  assert.equal(info["10"].name, "Brightness")
  assert.equal(info["10"].description, "Increase/decrease the brightness of the image.")
  assert.equal(info["10"].attrs, "Read Write")
  assert.equal(info["10"].continuity, "Continuous (normal)")
  assert.deepEqual([...info["10"].groups], ["Image"])
  assert.equal(info["60"].continuity, "Non-Continuous (simple)")
  assert.equal(info["60"].values.length, 4)
  assert.equal(info["60"].values[2].name, "DisplayPort-1")
  assert.equal(info["04"].attrs, "Write Only")
})

test("classifyFeature picks slider/combobox/button/readonly", () => {
  const info = C.parseVcpInfo(vcpinfo)
  const caps = C.parseCapabilities("vcp(04 10 60(01 0F 11) AE E0)")
  const byCode = Object.fromEntries(caps.map((f) => [f.code, C.classifyFeature(f, info, { "60": { "11": "HDMI (rear)" } })]))
  assert.equal(byCode["10"].widget, "slider")
  assert.equal(byCode["60"].widget, "combobox")
  assert.equal(byCode["60"].values.length, 3, "only the codes this monitor declared")
  assert.equal(byCode["60"].values[2].name, "HDMI (rear)", "device override wins")
  assert.equal(byCode["60"].values[1].name, "DisplayPort-1")
  assert.equal(byCode["04"].widget, "button")
  assert.equal(byCode["AE"].widget, "readonly")
  assert.equal(byCode["E0"].name, "VCP E0")
  assert.equal(byCode["E0"].category, "Others")
})

test("readOnlyDisplay formats frequencies and value names", () => {
  assert.equal(C.readOnlyDisplay({ code: "AE", current: 11980 }), "119.80 Hz")
  assert.equal(C.readOnlyDisplay({ code: "AC", current: 3728 }), "3728 Hz")
  assert.equal(C.readOnlyDisplay({ code: "60", current: 15, displayValues: [{ code: "0f", name: "DP" }] }), "DP")
  assert.equal(C.readOnlyDisplay({ code: "99", current: null }), null)
})

test("groupFeaturesByCategory orders categories and hides 8D", () => {
  const g = C.groupFeaturesByCategory([
    { code: "E0", category: "Others" },
    { code: "62", category: "Audio" },
    { code: "8D", category: "Audio" },
    { code: "10", category: "Image" },
    { code: "XX", category: "Zebra" },
  ])
  assert.deepEqual([...g.map((x) => x.category)], ["Image", "Audio", "Zebra", "Others"])
  assert.equal(g[1].features.length, 1)
})

console.log(`${passed} tests passed${process.exitCode ? " (with failures)" : ""}`)

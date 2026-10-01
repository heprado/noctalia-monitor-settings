-- Tests for lib/wlr_output.luau's pure functions.
--
-- Run: nix run nixpkgs#luau -- monitor-settings/lib/wlr_output_test.luau
--
-- wlr_output.luau touches no noctalia.*/ui.* global on purpose, which is
-- exactly what lets the standalone luau CLI (which has none of them) run
-- this file with no plugin runtime, no compositor and no second monitor
-- attached. Noctalia never loads this file -- it isn't referenced by
-- plugin.toml and requires nothing the plugin runtime provides.

local wlr = require("./wlr_output")

local function eq(actual, expected, what)
  assert(actual == expected, what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

-- The same three-monitor setup as nwg-displays' screenshot: a portrait
-- DP-1 on the left, a 120 Hz laptop panel in the middle, HDMI on the right.
local raw = {
  {
    name = "eDP-1",
    description = "Unknown 0xD0ED 0x00000000 (eDP-1)",
    make = "Unknown",
    model = "0xD0ED",
    physical_size = { width = 344, height = 194 },
    enabled = true,
    modes = {
      { width = 1920, height = 1080, refresh = 120.114, preferred = true, current = true },
      { width = 1920, height = 1080, refresh = 60.0, preferred = false, current = false },
      { width = 1280, height = 720, refresh = 60.0, preferred = false, current = false },
    },
    position = { x = 1080, y = 840 },
    transform = "normal",
    scale = 1.0,
    adaptive_sync = false,
  },
  {
    name = "DP-1",
    description = "ASUSTek COMPUTER INC VG278 M3LMQS291655 (DP-1)",
    physical_size = { width = 598, height = 336 },
    enabled = true,
    modes = {
      { width = 1920, height = 1080, refresh = 144.001007, preferred = true, current = true },
    },
    position = { x = 0, y = 0 },
    transform = "90",
    scale = 1.0,
    adaptive_sync = nil,
  },
  {
    name = "HDMI-A-1",
    description = "Some TV (HDMI-A-1)",
    physical_size = { width = 0, height = 0 },
    enabled = false,
    modes = {
      { width = 3840, height = 2160, refresh = 60.0, preferred = true, current = false },
      { width = 1920, height = 1080, refresh = 60.0, preferred = false, current = false },
    },
  },
}

local outputs = wlr.parseOutputs(raw)
eq(#outputs, 3, "disabled outputs are kept")
local edp, dp, hdmi = outputs[1], outputs[2], outputs[3]
eq(edp.width, 1920, "eDP width")
eq(edp.refresh, 120.114, "eDP refresh")
eq(edp.adaptiveSync, false, "eDP adaptive sync")
eq(#edp.modes, 3, "eDP mode count")
eq(dp.transform, "90", "DP transform")
eq(dp.adaptiveSync, nil, "DP adaptive sync unknown")
eq(hdmi.enabled, false, "HDMI disabled")
eq(hdmi.width, nil, "disabled output has no current mode")

-- configFromOutput falls back to the preferred mode for a disabled output.
local hdmiCfg = wlr.configFromOutput(hdmi)
eq(hdmiCfg.width, 3840, "disabled fallback width")
eq(hdmiCfg.enabled, false, "disabled config")

-- logicalSize swaps for rotation and divides by scale.
local w, h = wlr.logicalSize(wlr.configFromOutput(dp))
eq(w, 1080, "rotated logical width")
eq(h, 1920, "rotated logical height")
w, h = wlr.logicalSize({ width = 2560, height = 1440, transform = "normal", scale = 1.25 })
eq(w, 2048, "scaled logical width")
eq(h, 1152, "scaled logical height")

-- rotateTransform keeps flip and wraps around.
eq(wlr.rotateTransform("normal", 1), "90", "cw from normal")
eq(wlr.rotateTransform("normal", -1), "270", "ccw from normal")
eq(wlr.rotateTransform("270", 1), "normal", "cw wraps")
eq(wlr.rotateTransform("flipped", 1), "flipped-90", "flip kept")
eq(wlr.rotateTransform("flipped-90", -1), "flipped", "flip back to plain flipped")

-- Formatting matches what wlr-randr parses back exactly.
eq(wlr.formatRefresh(120.114), "120.114", "refresh fmt")
eq(wlr.formatRefresh(60.0), "60", "integer refresh fmt")
eq(wlr.formatRefresh(144.001007), "144.001", "refresh rounding")
eq(wlr.modeArg({ width = 1920, height = 1080, refresh = 59.94 }), "1920x1080@59.94Hz", "mode arg")
eq(wlr.formatScale(1.25), "1.25", "scale fmt")
eq(wlr.formatScale(2), "2", "integer scale fmt")

-- resolutions/refreshRates are distinct and sorted.
local res = wlr.resolutions(edp)
eq(#res, 2, "distinct resolutions")
eq(res[1].width, 1920, "largest first")
local rates = wlr.refreshRates(edp, 1920, 1080)
eq(#rates, 2, "rates at 1080p")
eq(rates[1], 120.114, "fastest first")

-- DPI: a 15.6" 1080p panel is ~141 DPI; unknown physical size -> nil.
local dpi = wlr.physicalDpi(edp, wlr.configFromOutput(edp))
assert(dpi and dpi > 140 and dpi < 143, "eDP dpi ~141, got " .. tostring(dpi))
eq(wlr.physicalDpi(hdmi, hdmiCfg), nil, "no physical size -> no dpi")
local s = wlr.scaleForDpi(edp, wlr.configFromOutput(edp), 96)
assert(s and math.abs(s - 1.475) < 0.01, "scale for 96 dpi, got " .. tostring(s))

-- buildApplyArgs: nothing changed -> nil.
local configs = wlr.configsFromOutputs(outputs)
local args, risky = wlr.buildApplyArgs(outputs, configs)
eq(args, nil, "no-op apply")

-- A position-only change is not risky and touches only that output.
configs["eDP-1"].x = 1200
args, risky = wlr.buildApplyArgs(outputs, configs)
assert(args, "position change produces args")
eq(table.concat(args, " "), "wlr-randr --output eDP-1 --pos 1200,840", "pos args")
eq(risky, false, "position change is not risky")

-- Mode + scale + adaptive sync + turning HDMI on, in one atomic call.
configs = wlr.configsFromOutputs(outputs)
configs["eDP-1"].refresh = 60.0
configs["eDP-1"].adaptiveSync = true
configs["DP-1"].adaptiveSync = true -- unknown on the live output: never passed
configs["HDMI-A-1"].enabled = true
configs["HDMI-A-1"].x = 3000
args, risky = wlr.buildApplyArgs(outputs, configs)
eq(
  table.concat(args, " "),
  "wlr-randr --output eDP-1 --mode 1920x1080@60Hz --adaptive-sync enabled"
    .. " --output HDMI-A-1 --on --mode 3840x2160@60Hz --transform normal --scale 1 --pos 3000,0",
  "combined args"
)
eq(risky, true, "mode change is risky")

-- Refuses to turn every output off.
configs = wlr.configsFromOutputs(outputs)
configs["eDP-1"].enabled = false
configs["DP-1"].enabled = false
args = wlr.buildApplyArgs(outputs, configs)
eq(args, nil, "all-off refused")

-- An unknown mode is never passed (wlr-randr would fail the whole call).
configs = wlr.configsFromOutputs(outputs)
configs["eDP-1"].width = 1234
args = wlr.buildApplyArgs(outputs, configs)
eq(args, nil, "unknown mode dropped")

-- snapPosition: DP-1 (1080x1920 rotated) at 0,0; eDP-1 1920x1080.
local layout = {
  A = { enabled = true, width = 1920, height = 1080, refresh = 60, transform = "90", scale = 1, x = 0, y = 0 },
  B = { enabled = true, width = 1920, height = 1080, refresh = 60, transform = "normal", scale = 1, x = 1080, y = 840 },
}
-- Dropped close to A's right edge and bottom alignment -> snaps flush.
local x, y = wlr.snapPosition(layout, "B", 1120, 800, 100)
eq(x, 1080, "snap x to A's right edge")
eq(y, 840, "snap bottom edges aligned")
-- Dropped overlapping A -> pushed out.
x, y = wlr.snapPosition(layout, "B", 500, 300, 50)
assert(not (x < 1080 and x + 1920 > 0 and y < 1920 and y + 1080 > 0), "overlap resolved: " .. x .. "," .. y)
-- Dropped far away -> pulled in to touch A.
x, y = wlr.snapPosition(layout, "B", 5000, 200, 50)
eq(x, 1080, "detached monitor pulled to A's edge")
eq(y, 200, "keeps its vertical position")

-- Dropped diagonally above-left of A -> beside A, top edges aligned
-- (never touching at just a corner).
x, y = wlr.snapPosition(layout, "B", -3000, -2000, 50)
eq(x, -1920, "diagonal drop goes beside A")
eq(y, 0, "diagonal drop aligns to A's top")
-- normalizeOrigin moves the top-left corner to 0,0.
local shifted = {
  A = { enabled = true, width = 100, height = 100, transform = "normal", scale = 1, x = -100, y = 50 },
  B = { enabled = true, width = 100, height = 100, transform = "normal", scale = 1, x = 0, y = 60 },
  C = { enabled = false, width = 100, height = 100, transform = "normal", scale = 1, x = -500, y = -500 },
}
wlr.normalizeOrigin(shifted)
eq(shifted.A.x, 0, "normalized A.x")
eq(shifted.A.y, 0, "normalized A.y")
eq(shifted.B.x, 100, "normalized B.x")
eq(shifted.B.y, 10, "normalized B.y")
eq(shifted.C.x, -500, "disabled outputs untouched")

-- computeView fits everything with margin.
local view = wlr.computeView(layout, 640, 288)
assert(view.scale > 0, "positive scale")
assert((0 - view.ox) * view.scale >= 0, "A fits on the left")
assert((1080 + 1920 - view.ox) * view.scale <= 640, "B fits on the right")

-- sanitizeSaved drops a mode the output no longer has.
local saved = { enabled = true, width = 9999, height = 9999, refresh = 60, transform = "180", scale = 1.5, x = 10, y = 20 }
local cfg = wlr.sanitizeSaved(edp, saved)
eq(cfg.width, 1920, "stale mode replaced by live one")
eq(cfg.transform, "180", "saved transform kept")
eq(cfg.scale, 1.5, "saved scale kept")
eq(cfg.x, 10, "saved x kept")

print("wlr_output: all tests passed")

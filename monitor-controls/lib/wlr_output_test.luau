local wlr = require("./wlr_output")

-- One enabled output with a current mode, matching a real `wlr-randr
-- --json` element captured live against an ASUS VG278QR on DP-2.
local raw = {
  {
    name = "DP-2",
    description = "ASUSTek COMPUTER INC VG278 M3LMQS291655 (DP-2)",
    enabled = true,
    modes = {
      { width = 1920, height = 1080, refresh = 60.0, current = false },
      { width = 1920, height = 1080, refresh = 144.001007, current = true },
    },
    position = { x = 0, y = 0 },
    scale = 1.0,
  },
}

local outputs = wlr.parseOutputs(raw)
assert(#outputs == 1, "expected 1 output, got " .. #outputs)
assert(outputs[1].name == "DP-2", "wrong name: " .. tostring(outputs[1].name))
assert(outputs[1].width == 1920, "wrong width: " .. tostring(outputs[1].width))
assert(outputs[1].height == 1080, "wrong height: " .. tostring(outputs[1].height))
assert(outputs[1].refresh == 144.001007, "wrong refresh: " .. tostring(outputs[1].refresh))
assert(outputs[1].x == 0, "wrong x: " .. tostring(outputs[1].x))
assert(outputs[1].y == 0, "wrong y: " .. tostring(outputs[1].y))
assert(outputs[1].scale == 1.0, "wrong scale: " .. tostring(outputs[1].scale))

-- A disabled output must be skipped entirely.
local rawWithDisabled = {
  raw[1],
  { name = "HDMI-A-1", enabled = false, modes = {}, position = { x = 1920, y = 0 }, scale = 1.0 },
}
local outputs2 = wlr.parseOutputs(rawWithDisabled)
assert(#outputs2 == 1, "disabled output should be skipped, got " .. #outputs2)

print("wlr_output_test: parseOutputs OK")

-- Table/HTML-style grid packing: colWidth[c] = tallest... no, widest
-- output in that column; rowHeight[r] = tallest in that row; offset of a
-- cell = sum of the columns/rows before it. Three outputs, mixed sizes
-- and one non-1.0 scale, arranged in an L: A top-left, B top-right
-- (narrower physical width, so column 1 is narrower than a 1920-wide
-- column would be), C bottom-left under A.
local outputsForLayout = {
  { name = "A", width = 1920, height = 1080, scale = 1.0 }, -- logical 1920x1080
  { name = "B", width = 2560, height = 1440, scale = 2.0 }, -- logical 1280x720
  { name = "C", width = 1920, height = 1080, scale = 1.0 }, -- logical 1920x1080
}
local cellMap = {
  A = { row = 0, col = 0 },
  B = { row = 0, col = 1 },
  C = { row = 1, col = 0 },
}
local positions = wlr.computeLayout(outputsForLayout, cellMap, 3, 3)

assert(positions.A.x == 0 and positions.A.y == 0, "A should be at origin")
assert(positions.B.x == 1920 and positions.B.y == 0, "B should be right of A's 1920 logical width")
assert(positions.C.x == 0 and positions.C.y == 1080, "C should be below A's 1080 logical height")

-- An output with no cell assignment at all must not appear in the result.
local cellMapMissingC = { A = cellMap.A, B = cellMap.B }
local positions2 = wlr.computeLayout(outputsForLayout, cellMapMissingC, 3, 3)
assert(positions2.C == nil, "C has no cell assignment, should not be positioned")

print("wlr_output_test: computeLayout OK")

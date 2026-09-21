-- Tests for lib/wlr_output.luau's three pure functions.
--
-- Run: nix run nixpkgs#luau -- monitor-settings/lib/wlr_output_test.luau
--
-- wlr_output.luau touches no noctalia.*/ui.* global on purpose, which is
-- exactly what lets the standalone luau CLI (which has none of them) run
-- this file with no plugin runtime, no compositor and no second monitor
-- attached. Noctalia never loads this file -- it isn't referenced by
-- plugin.toml and requires nothing the plugin runtime provides.

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

-- An enabled output with no mode flagged `current` (possible mid-hotplug)
-- parses with nil width/height rather than failing -- computeLayout below
-- is the one that has to cope with that.
local rawNoCurrentMode = {
  {
    name = "DP-3",
    description = "no current mode (DP-3)",
    enabled = true,
    modes = { { width = 1920, height = 1080, refresh = 60.0, current = false } },
    position = { x = 0, y = 0 },
    scale = 1.0,
  },
}
local outputs3 = wlr.parseOutputs(rawNoCurrentMode)
assert(#outputs3 == 1, "output with no current mode should still be listed")
assert(outputs3[1].width == nil, "expected nil width with no current mode")

print("wlr_output_test: parseOutputs OK")

-- Table/HTML-style grid packing: colWidth[c] = widest output in that
-- column; rowHeight[r] = tallest in that row; offset of a cell = sum of
-- the columns/rows before it. Three outputs, mixed sizes and one non-1.0
-- scale, arranged in an L: A top-left, B top-right (narrower logical
-- width, so column 1 is narrower than a 1920-wide column would be), C
-- bottom-left under A.
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

-- Defensive cases: layout.json is persisted state, so a cellMap can be
-- stale (saved by a run with a bigger grid) or hand-edited, and a live
-- read can report an output with no current mode. None of these may
-- throw; each bad entry is simply left out of the result, and the good
-- entries around it still get positioned.
local outputsWithBadMode = {
  { name = "A", width = 1920, height = 1080, scale = 1.0 },
  { name = "NOMODE", width = nil, height = nil, scale = 1.0 },
}
local hostileCellMap = {
  A = { row = 0, col = 0 },
  NOMODE = { row = 0, col = 1 }, -- valid cell, but no width/height
  TOOFAR = { row = 7, col = 9 }, -- out of a 3x3 grid entirely
  NEGATIVE = { row = -1, col = 0 }, -- below the grid
  NILCELL = { row = nil, col = 2 }, -- malformed entry
}
local okCompute, positions3 = pcall(function()
  return wlr.computeLayout(outputsWithBadMode, hostileCellMap, 3, 3)
end)
assert(okCompute, "computeLayout must not throw on a stale/malformed cellMap: " .. tostring(positions3))
assert(positions3.A ~= nil and positions3.A.x == 0 and positions3.A.y == 0, "valid entry A should still be positioned")
assert(positions3.NOMODE == nil, "output with nil width/height must be excluded")
assert(positions3.TOOFAR == nil, "out-of-range cell must be excluded")
assert(positions3.NEGATIVE == nil, "negative cell index must be excluded")
assert(positions3.NILCELL == nil, "malformed cell must be excluded")

-- A nil-width output must also contribute nothing to its column's width:
-- A is alone in column 0, so nothing to its right shifts because of it.
local positions4 = wlr.computeLayout(
  { { name = "A", width = 1920, height = 1080, scale = 1.0 }, { name = "NOMODE", scale = 1.0 } },
  { A = { row = 0, col = 1 }, NOMODE = { row = 0, col = 0 } },
  3,
  3
)
assert(positions4.A.x == 0, "a nil-width occupant of column 0 must add no width, got " .. tostring(positions4.A.x))

print("wlr_output_test: computeLayout OK")

-- Zero outputs -> empty map.
local seeded0 = wlr.seedCellMap({}, 3, 3)
local count0 = 0
for _ in pairs(seeded0) do count0 = count0 + 1 end
assert(count0 == 0, "expected empty cell map for 0 outputs")

-- One output -> dead center of a 3x3 grid, regardless of its real x/y.
local seeded1 = wlr.seedCellMap({ { name = "DP-2", x = 0, y = 0 } }, 3, 3)
assert(seeded1["DP-2"].row == 1 and seeded1["DP-2"].col == 1, "single output should be centered")

-- Three outputs left-to-right by real x (a typical triple-monitor desk)
-- should rank into distinct, increasing columns, all on the same row
-- since their y is identical.
local seeded3 = wlr.seedCellMap({
  { name = "left", x = 0, y = 0 },
  { name = "center", x = 1920, y = 0 },
  { name = "right", x = 3840, y = 0 },
}, 3, 3)
assert(seeded3.left.col < seeded3.center.col, "left should rank before center")
assert(seeded3.center.col < seeded3.right.col, "center should rank before right")
assert(seeded3.left.row == seeded3.center.row and seeded3.center.row == seeded3.right.row,
  "all three share the same y, so must share the same row")

-- Every seeded cell must be inside the grid -- service.luau's collision
-- resolution assumes it only ever has to move a suggestion off an
-- already-taken cell, not off an invalid one.
for name, cell in pairs(seeded3) do
  assert(cell.row >= 0 and cell.row <= 2, "seeded row out of grid for " .. name)
  assert(cell.col >= 0 and cell.col <= 2, "seeded col out of grid for " .. name)
end

print("wlr_output_test: seedCellMap OK")
print("wlr_output_test: all OK")

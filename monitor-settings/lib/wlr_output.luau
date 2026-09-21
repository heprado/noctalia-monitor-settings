--!strict
-- Monitor Controls -- wlroots output parsing and grid-layout math.
--
-- Pure parsing/layout for `wlr-randr --json`, the generic wlroots
-- equivalent of xrandr -- works on any compositor implementing
-- wlr-output-management-v1 (Hyprland, Sway, river, ...), not just
-- Hyprland, which is why this plugin uses it instead of `hyprctl`.
-- service.luau owns every `wlr-randr` invocation and every
-- noctalia.json.decode call; this module never touches either, so it
-- stays testable with the standalone `luau` CLI, which has neither
-- global available.

-- Public surface: parseOutputs (raw wlr-randr JSON array -> normalized
-- output list), computeLayout (outputs + cell assignment -> pixel
-- positions), seedCellMap (outputs' real positions -> a first-guess cell
-- assignment, used only when no saved layout.json entry exists yet).

local M = {}

-- rawList is one already-decoded `wlr-randr --json` array. Each element's
-- shape (confirmed live): { name, description, enabled, modes: [{width,
-- height, refresh, current}], position: {x, y}, scale }.
function M.parseOutputs(rawList: {any}): {any}
  local outputs = {}
  for _, raw in ipairs(rawList or {}) do
    if raw.enabled ~= false then
      local width, height, refresh = nil, nil, nil
      for _, mode in ipairs(raw.modes or {}) do
        if mode.current then
          width = mode.width
          height = mode.height
          refresh = mode.refresh
          break
        end
      end
      table.insert(outputs, {
        name = raw.name,
        description = raw.description or "",
        width = width,
        height = height,
        refresh = refresh,
        x = (raw.position and raw.position.x) or 0,
        y = (raw.position and raw.position.y) or 0,
        scale = raw.scale or 1,
      })
    end
  end
  return outputs
end

-- Same algorithm an HTML table uses for column/row sizing: colWidth[c] is
-- the widest occupant of column c (0 for an empty column), rowHeight[r]
-- the tallest occupant of row r; an output's offset is the sum of every
-- column/row before its own. Guarantees zero overlap for any arrangement
-- of occupied cells, using only each output's current mode and scale --
-- no per-arrangement special-casing needed.
--
-- Defensive about its own inputs, because cellMap comes from layout.json
-- on disk -- persisted state that can be stale (saved by a previous run
-- with different grid dimensions) or hand-edited -- and `outputs` comes
-- from a live wlr-randr read that can legitimately report an output with
-- no current mode (width/height nil) mid-hotplug. Any entry that would
-- make the arithmetic or the colWidth/rowHeight indexing throw is simply
-- excluded from the result rather than taking the whole layout down.
function M.computeLayout(outputs: {any}, cellMap: {[string]: any}, gridRows: number, gridCols: number): {[string]: any}
  local function cellInRange(cell: any): boolean
    return type(cell) == "table"
      and type(cell.row) == "number"
      and type(cell.col) == "number"
      and cell.row >= 0
      and cell.row <= gridRows - 1
      and cell.col >= 0
      and cell.col <= gridCols - 1
  end

  local byName = {}
  for _, o in ipairs(outputs) do
    byName[o.name] = o
  end

  local colWidth = {}
  local rowHeight = {}
  for c = 0, gridCols - 1 do
    colWidth[c] = 0
  end
  for r = 0, gridRows - 1 do
    rowHeight[r] = 0
  end

  for name, cell in pairs(cellMap) do
    local o = byName[name]
    if o and o.width ~= nil and o.height ~= nil and cellInRange(cell) then
      local logicalWidth = o.width / (o.scale or 1)
      local logicalHeight = o.height / (o.scale or 1)
      if logicalWidth > colWidth[cell.col] then
        colWidth[cell.col] = logicalWidth
      end
      if logicalHeight > rowHeight[cell.row] then
        rowHeight[cell.row] = logicalHeight
      end
    end
  end

  local colOffset = {}
  local acc = 0
  for c = 0, gridCols - 1 do
    colOffset[c] = acc
    acc = acc + colWidth[c]
  end
  local rowOffset = {}
  acc = 0
  for r = 0, gridRows - 1 do
    rowOffset[r] = acc
    acc = acc + rowHeight[r]
  end

  local positions = {}
  for name, cell in pairs(cellMap) do
    local o = byName[name]
    -- Same exclusions as the sizing loop above, so an output that
    -- contributed no logical size (no current mode) or sits on an
    -- out-of-grid cell never gets a position computed for it either --
    -- moving a monitor to an offset derived from sizes it wasn't part of
    -- is worse than leaving it where the compositor already put it.
    if o and o.width ~= nil and o.height ~= nil and cellInRange(cell) then
      positions[name] = {
        x = math.floor(colOffset[cell.col] + 0.5),
        y = math.floor(rowOffset[cell.row] + 0.5),
      }
    end
  end
  return positions
end

-- Only ever needed once per output, the first time it's ever seen with no
-- saved layout.json entry for it -- a rough starting point the user can
-- drag to correct, not an attempt at pixel-perfect reconstruction of
-- whatever arrangement was already in effect. Ranks outputs into column
-- bands by *distinct* real x values and into row bands by distinct real y
-- values (not by output rank directly -- ranking outputs themselves,
-- rather than their distinct coordinate values, splits same-y outputs
-- across different rows on ties, confirmed live with three same-y
-- outputs: naive per-output ranking put them in three different rows
-- despite being perfectly level).
function M.seedCellMap(outputs: {any}, gridRows: number, gridCols: number): {[string]: any}
  local cellMap = {}
  local n = #outputs
  if n == 0 then
    return cellMap
  end
  if n == 1 then
    cellMap[outputs[1].name] = { row = math.floor(gridRows / 2), col = math.floor(gridCols / 2) }
    return cellMap
  end

  local function rankOfDistinct(getValue, gridSize: number)
    local distinct = {}
    local seen = {}
    for _, o in ipairs(outputs) do
      local v = getValue(o)
      if not seen[v] then
        seen[v] = true
        table.insert(distinct, v)
      end
    end
    table.sort(distinct)
    local rankByValue = {}
    local m = #distinct
    for i, v in ipairs(distinct) do
      rankByValue[v] = math.min(gridSize - 1, math.floor((i - 1) * gridSize / m))
    end
    return rankByValue
  end

  local colRank = rankOfDistinct(function(o) return o.x end, gridCols)
  local rowRank = rankOfDistinct(function(o) return o.y end, gridRows)

  for _, o in ipairs(outputs) do
    cellMap[o.name] = { row = rowRank[o.y], col = colRank[o.x] }
  end
  return cellMap
end

return M

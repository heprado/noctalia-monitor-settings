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
function M.computeLayout(outputs: {any}, cellMap: {[string]: any}, gridRows: number, gridCols: number): {[string]: any}
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
    if o then
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
    if byName[name] then
      positions[name] = {
        x = math.floor(colOffset[cell.col] + 0.5),
        y = math.floor(rowOffset[cell.row] + 0.5),
      }
    end
  end
  return positions
end

return M

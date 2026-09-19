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

return M

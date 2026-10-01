--!strict
-- Monitor Settings -- wlroots output parsing and display-arrangement math.
--
-- Pure parsing/layout for `wlr-randr --json`, the generic wlroots
-- equivalent of xrandr -- works on any compositor implementing
-- wlr-output-management-v1 (Hyprland, Sway, river, ...), not just
-- Hyprland, which is why this plugin uses it instead of `hyprctl`.
-- service.luau owns every `wlr-randr` invocation and every
-- noctalia.json.decode call; this module never touches either, so it
-- stays testable with the standalone `luau` CLI, which has neither
-- global available.
--
-- Two shapes flow through here:
--   * an *output* is what wlr-randr reports (parseOutputs): identity,
--     every mode it supports, physical size, and its live settings;
--   * a *config* is the editable subset of an output's settings
--     (configFromOutput): { enabled, width, height, refresh, x, y,
--     transform, scale, adaptiveSync }. The panel edits configs as a
--     draft, the service diffs them against the live outputs into one
--     atomic `wlr-randr` invocation (buildApplyArgs) and persists them.

local M = {}

-- Every value `wlr-randr --transform` accepts, in wl_output's own enum
-- order (normal, then the three rotations, then their flipped variants).
M.TRANSFORMS = { "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" }

-- Common fractional scales, offered as presets in the panel.
M.SCALE_PRESETS = { 0.5, 0.75, 1, 1.25, 1.5, 1.6, 1.75, 2, 2.25, 2.5, 3 }

local function isTransform(t: any): boolean
  for _, v in ipairs(M.TRANSFORMS) do
    if v == t then
      return true
    end
  end
  return false
end

-- rawList is one already-decoded `wlr-randr --json` array. Each element's
-- shape (wlr-randr's print_state_json): { name, description, make, model,
-- serial, physical_size: {width, height} (mm), enabled, modes: [{width,
-- height, refresh, preferred, current}] } -- plus, only when enabled,
-- position: {x, y}, transform, scale and adaptive_sync (true/false, or
-- null when the compositor's protocol version can't report it).
--
-- Disabled outputs are kept (unlike the first version of this module) --
-- the panel needs them listed to be able to turn them back on.
function M.parseOutputs(rawList: {any}): {any}
  local outputs = {}
  for _, raw in ipairs(rawList or {}) do
    if type(raw) == "table" and type(raw.name) == "string" then
      local modes = {}
      local width, height, refresh = nil, nil, nil
      for _, mode in ipairs((raw.modes or {}) :: {any}) do
        if type(mode) == "table" and type(mode.width) == "number" and type(mode.height) == "number" then
          table.insert(modes, {
            width = mode.width,
            height = mode.height,
            refresh = tonumber(mode.refresh) or 0,
            preferred = mode.preferred == true,
            current = mode.current == true,
          })
          if mode.current then
            width = mode.width
            height = mode.height
            refresh = tonumber(mode.refresh) or 0
          end
        end
      end
      local adaptiveSync = nil
      if raw.adaptive_sync == true or raw.adaptive_sync == false then
        adaptiveSync = raw.adaptive_sync
      end
      table.insert(outputs, {
        name = raw.name,
        description = raw.description or "",
        make = raw.make or "",
        model = raw.model or "",
        enabled = raw.enabled ~= false,
        modes = modes,
        width = width,
        height = height,
        refresh = refresh,
        x = (raw.position and raw.position.x) or 0,
        y = (raw.position and raw.position.y) or 0,
        transform = isTransform(raw.transform) and raw.transform or "normal",
        scale = tonumber(raw.scale) or 1,
        adaptiveSync = adaptiveSync,
        physWidth = (raw.physical_size and tonumber(raw.physical_size.width)) or 0,
        physHeight = (raw.physical_size and tonumber(raw.physical_size.height)) or 0,
      })
    end
  end
  return outputs
end

-- The mode a disabled output would come back on with: the one it reports
-- as current if any, else its preferred mode, else its first -- the same
-- order wlr-randr's own `--on` fixup uses.
local function fallbackMode(o: any): any
  local preferred, first = nil, nil
  for _, m in ipairs((o.modes or {}) :: {any}) do
    if m.current then
      return m
    end
    if m.preferred and not preferred then
      preferred = m
    end
    first = first or m
  end
  return preferred or first
end

function M.configFromOutput(o: any): any
  local width, height, refresh = o.width, o.height, o.refresh
  if width == nil then
    local m = fallbackMode(o)
    if m then
      width, height, refresh = m.width, m.height, m.refresh
    end
  end
  return {
    enabled = o.enabled ~= false,
    width = width,
    height = height,
    refresh = refresh,
    x = o.x or 0,
    y = o.y or 0,
    transform = o.transform or "normal",
    scale = o.scale or 1,
    adaptiveSync = o.adaptiveSync,
  }
end

function M.configsFromOutputs(outputs: {any}): {[string]: any}
  local configs = {}
  for _, o in ipairs(outputs) do
    configs[o.name] = M.configFromOutput(o)
  end
  return configs
end

function M.copyConfig(cfg: any): any
  local out = {}
  for k, v in pairs(cfg) do
    out[k] = v
  end
  return out
end

function M.isRotated(transform: string?): boolean
  return transform == "90" or transform == "270" or transform == "flipped-90" or transform == "flipped-270"
end

-- The size an output occupies in the compositor's logical coordinate
-- space: its mode, swapped for a quarter-turn rotation, divided by scale.
-- Rounded, because wlroots positions are integers -- a fractional edge
-- would make "touching" outputs one pixel apart (or overlapping).
function M.logicalSize(cfg: any): (number, number)
  local w = cfg.width or 0
  local h = cfg.height or 0
  if M.isRotated(cfg.transform) then
    w, h = h, w
  end
  local scale = (cfg.scale and cfg.scale > 0) and cfg.scale or 1
  return math.floor(w / scale + 0.5), math.floor(h / scale + 0.5)
end

-- Rotates a transform by a quarter turn, keeping whether it is flipped:
-- direction 1 is clockwise, -1 counter-clockwise.
function M.rotateTransform(transform: string, direction: number): string
  local flipped = string.sub(transform, 1, 7) == "flipped"
  local base = flipped and string.sub(transform, 9) or transform
  local degrees = (base == "" or base == "normal") and 0 or (tonumber(base) or 0)
  degrees = (degrees + 90 * direction) % 360
  if flipped then
    return degrees == 0 and "flipped" or ("flipped-" .. degrees)
  end
  return degrees == 0 and "normal" or tostring(degrees)
end

-- wlr-randr --json prints refresh with %f (e.g. 120.114000) and matches a
-- requested mode by rounding the given Hz to mHz, so three decimals is
-- always exact.
function M.formatRefresh(refresh: number): string
  local s = string.format("%.3f", refresh)
  s = string.gsub(s, "0+$", "")
  s = string.gsub(s, "%.$", "")
  return s
end

function M.formatScale(scale: number): string
  local s = string.format("%.4f", scale)
  s = string.gsub(s, "0+$", "")
  s = string.gsub(s, "%.$", "")
  return s
end

function M.modeArg(cfg: any): string
  return cfg.width .. "x" .. cfg.height .. "@" .. M.formatRefresh(cfg.refresh or 0) .. "Hz"
end

-- Distinct resolutions an output supports, largest first.
function M.resolutions(o: any): {any}
  local seen = {}
  local list: {any} = {}
  for _, m in ipairs((o.modes or {}) :: {any}) do
    local key = m.width .. "x" .. m.height
    if not seen[key] then
      seen[key] = true
      table.insert(list, { width = m.width, height = m.height })
    end
  end
  table.sort(list, function(a: any, b: any)
    if a.width * a.height ~= b.width * b.height then
      return a.width * a.height > b.width * b.height
    end
    return a.width > b.width
  end)
  return list
end

-- Distinct refresh rates an output supports at one resolution, fastest first.
function M.refreshRates(o: any, width: number, height: number): {number}
  local seen = {}
  local list: {any} = {}
  for _, m in ipairs((o.modes or {}) :: {any}) do
    if m.width == width and m.height == height then
      local key = M.formatRefresh(m.refresh)
      if not seen[key] then
        seen[key] = true
        table.insert(list, m.refresh)
      end
    end
  end
  table.sort(list, function(a: any, b: any) return a > b end)
  return list
end

function M.hasMode(o: any, width: number?, height: number?, refresh: number?): boolean
  if width == nil or height == nil or refresh == nil then
    return false
  end
  local want = M.formatRefresh(refresh)
  for _, m in ipairs((o.modes or {}) :: {any}) do
    if m.width == width and m.height == height and M.formatRefresh(m.refresh) == want then
      return true
    end
  end
  return false
end

-- Pixel density from the EDID's physical size (wlr-randr's
-- physical_size, millimetres). nil when the size is unknown (0x0 --
-- projectors, some TVs and virtual outputs report that), since any
-- number derived from it would be meaningless.
function M.physicalDpi(o: any, cfg: any): number?
  local physW = o.physWidth or 0
  local physH = o.physHeight or 0
  local w = cfg.width or 0
  local h = cfg.height or 0
  if physW <= 0 or physH <= 0 or w <= 0 or h <= 0 then
    return nil
  end
  local diagPx = math.sqrt(w * w + h * h)
  local diagIn = math.sqrt(physW * physW + physH * physH) / 25.4
  return diagPx / diagIn
end

-- What a scaled output's DPI looks like to applications: Wayland has no
-- separate per-monitor DPI knob, scale is that knob.
function M.effectiveDpi(o: any, cfg: any): number?
  local dpi = M.physicalDpi(o, cfg)
  if dpi == nil then
    return nil
  end
  return dpi / ((cfg.scale and cfg.scale > 0) and cfg.scale or 1)
end

-- Inverse of effectiveDpi: the scale that makes this output look like
-- `targetDpi` to applications, rounded to a multiple of 1/120 (the
-- fractional-scale-v1 protocol's granularity) and clamped to a sane range.
function M.scaleForDpi(o: any, cfg: any, targetDpi: number): number?
  local dpi = M.physicalDpi(o, cfg)
  if dpi == nil or targetDpi <= 0 then
    return nil
  end
  local scale = math.floor(dpi / targetDpi * 120 + 0.5) / 120
  if scale < 0.25 then scale = 0.25 end
  if scale > 4 then scale = 4 end
  return scale
end

-- ---------------------------------------------------------------------
-- Arrangement
-- ---------------------------------------------------------------------

local function rectOf(cfg: any): (number, number, number, number)
  local w, h = M.logicalSize(cfg)
  return cfg.x or 0, cfg.y or 0, w, h
end

local function overlaps(ax: number, ay: number, aw: number, ah: number, bx: number, by: number, bw: number, bh: number): boolean
  return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah
end

local function touches(ax: number, ay: number, aw: number, ah: number, bx: number, by: number, bw: number, bh: number): boolean
  local xTouch = (ax + aw == bx or bx + bw == ax) and ay < by + bh and by < ay + ah
  local yTouch = (ay + ah == by or by + bh == ay) and ax < bx + bw and bx < ax + aw
  return xTouch or yTouch
end

local function sortedNames(configs: {[string]: any}): {string}
  local names = {}
  for name in pairs(configs) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

-- Other enabled outputs' rects, in a stable (name) order so the same drop
-- always resolves the same way.
local function otherRects(configs: {[string]: any}, exclude: string): {any}
  local rects = {}
  for _, name in ipairs(sortedNames(configs)) do
    local cfg = configs[name]
    if name ~= exclude and cfg.enabled and cfg.width then
      local x, y, w, h = rectOf(cfg)
      table.insert(rects, { x = x, y = y, w = w, h = h })
    end
  end
  return rects
end

-- Where a monitor dragged to (x, y) should actually land:
--   1. its edges snap to any other monitor's edges within `threshold`
--      (side by side, or aligned), independently per axis;
--   2. any overlap left is pushed out along the shortest direction;
--   3. a monitor left floating apart from all the others is pulled in to
--      touch the nearest one -- a gap between monitors is a dead zone the
--      cursor can't cross.
-- Every other monitor stays where it is.
function M.snapPosition(configs: {[string]: any}, name: string, x: number, y: number, threshold: number): (number, number)
  local cfg = configs[name]
  local _, _, w, h = rectOf(cfg)
  local others = otherRects(configs, name)
  x = math.floor(x + 0.5)
  y = math.floor(y + 0.5)
  if #others == 0 then
    return x, y
  end

  local function bestSnap(value: number, candidates: {number}): number
    local best, bestDist = value, threshold + 1
    for _, c in ipairs(candidates) do
      local d = math.abs(c - value)
      if d < bestDist then
        best, bestDist = c, d
      end
    end
    return bestDist <= threshold and best or value
  end

  local xs, ys = {}, {}
  for _, o in ipairs(others) do
    table.insert(xs, o.x - w)
    table.insert(xs, o.x + o.w)
    table.insert(xs, o.x)
    table.insert(xs, o.x + o.w - w)
    table.insert(ys, o.y - h)
    table.insert(ys, o.y + o.h)
    table.insert(ys, o.y)
    table.insert(ys, o.y + o.h - h)
  end
  x = bestSnap(x, xs)
  y = bestSnap(y, ys)

  local function resolveOverlaps()
    -- Bounded: each push clears at least one overlap, but can create a new
    -- one with a neighbour; a handful of rounds settles any real layout.
    for _ = 1, 16 do
      local hit = nil
      for _, o in ipairs(others) do
        if overlaps(x, y, w, h, o.x, o.y, o.w, o.h) then
          hit = o
          break
        end
      end
      if not hit then
        break
      end
      local moves: {any} = {
        { dx = hit.x - w - x, dy = 0 },
        { dx = hit.x + hit.w - x, dy = 0 },
        { dx = 0, dy = hit.y - h - y },
        { dx = 0, dy = hit.y + hit.h - y },
      }
      local best = moves[1]
      for _, m in ipairs(moves) do
        if math.abs(m.dx) + math.abs(m.dy) < math.abs(best.dx) + math.abs(best.dy) then
          best = m
        end
      end
      x = x + best.dx
      y = y + best.dy
    end
  end

  resolveOverlaps()

  local touching = false
  for _, o in ipairs(others) do
    if touches(x, y, w, h, o.x, o.y, o.w, o.h) then
      touching = true
      break
    end
  end
  if not touching then
    -- Nearest neighbour by gap between rectangles.
    local nearest, nearestGap = nil, math.huge
    for _, o in ipairs(others) do
      local gx = math.max(o.x - (x + w), x - (o.x + o.w), 0)
      local gy = math.max(o.y - (y + h), y - (o.y + o.h), 0)
      local gap = gx + gy
      if gap < nearestGap then
        nearest, nearestGap = o, gap
      end
    end
    if nearest then
      local o = nearest
      local gx = math.max(o.x - (x + w), x - (o.x + o.w), 0)
      local gy = math.max(o.y - (y + h), y - (o.y + o.h), 0)
      -- Side by side along the axis with the bigger gap; on the other
      -- axis, a monitor entirely past the neighbour's edge (a diagonal
      -- drop) is aligned to that edge -- touching only at a corner isn't
      -- adjacency the cursor can cross.
      if gx >= gy then
        x = (x + w <= o.x) and (o.x - w) or (o.x + o.w)
        if y + h <= o.y then
          y = o.y
        elseif y >= o.y + o.h then
          y = o.y + o.h - h
        end
      else
        y = (y + h <= o.y) and (o.y - h) or (o.y + o.h)
        if x + w <= o.x then
          x = o.x
        elseif x >= o.x + o.w then
          x = o.x + o.w - w
        end
      end
      resolveOverlaps()
    end
  end

  return x, y
end

-- Shifts every enabled output so the arrangement's top-left corner sits
-- at (0, 0). Some clients misbehave with negative global coordinates,
-- and a drag left of the leftmost monitor produces exactly that.
function M.normalizeOrigin(configs: {[string]: any})
  local minX, minY = math.huge, math.huge
  for _, cfg in pairs(configs) do
    if cfg.enabled and cfg.width then
      minX = math.min(minX, cfg.x or 0)
      minY = math.min(minY, cfg.y or 0)
    end
  end
  if minX == math.huge then
    return
  end
  for _, cfg in pairs(configs) do
    if cfg.enabled and cfg.width then
      cfg.x = (cfg.x or 0) - minX
      cfg.y = (cfg.y or 0) - minY
    end
  end
end

-- The view transform for drawing the arrangement on a canvas of
-- canvasW x canvasH pixels: the bounding box of every enabled output,
-- plus a margin so there's room to drop a monitor beside the outermost
-- ones, scaled to fit and centred.
-- Returns { scale, ox, oy }: canvasX = (x - ox) * scale.
function M.computeView(configs: {[string]: any}, canvasW: number, canvasH: number): any
  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  local maxDim = 0
  for _, cfg in pairs(configs) do
    if cfg.enabled and cfg.width then
      local x, y, w, h = rectOf(cfg)
      minX = math.min(minX, x)
      minY = math.min(minY, y)
      maxX = math.max(maxX, x + w)
      maxY = math.max(maxY, y + h)
      maxDim = math.max(maxDim, w, h)
    end
  end
  if minX == math.huge then
    return { scale = canvasW / 3840, ox = 0, oy = 0 }
  end
  local margin = maxDim * 0.6
  local spanW = maxX - minX + 2 * margin
  local spanH = maxY - minY + 2 * margin
  local scale = math.min(canvasW / spanW, canvasH / spanH)
  local ox = minX - (canvasW / scale - (maxX - minX)) / 2
  local oy = minY - (canvasH / scale - (maxY - minY)) / 2
  return { scale = scale, ox = ox, oy = oy }
end

-- ---------------------------------------------------------------------
-- Applying
-- ---------------------------------------------------------------------

local function sameNumber(a: number?, b: number?, eps: number): boolean
  if a == nil or b == nil then
    return a == b
  end
  return math.abs(a - b) < eps
end

-- One `wlr-randr` argv covering every output whose config differs from
-- its live state, or nil when nothing differs. A single invocation is one
-- wlr-output-management configuration, applied atomically by the
-- compositor -- moving three monitors at once never passes through an
-- intermediate overlapping arrangement it could reject.
--
-- Also reports whether anything beyond position/adaptive sync changed
-- (mode, scale, rotation, on/off): those are the changes that can leave
-- a screen unreadable, so the service asks for confirmation before
-- keeping them.
function M.buildApplyArgs(outputs: {any}, configs: {[string]: any}): ({string}?, boolean)
  local args = { "wlr-randr" }
  local any = false
  local risky = false

  -- Refuse to turn every output off: the session would be left with no
  -- screen to undo it from.
  local anyEnabled = false
  for _, o in ipairs(outputs) do
    local cfg = configs[o.name]
    if (cfg and cfg.enabled) or (not cfg and o.enabled) then
      anyEnabled = true
    end
  end
  if not anyEnabled then
    return nil, false
  end

  for _, o in ipairs(outputs) do
    local cfg = configs[o.name]
    if cfg then
      local outArgs = {}
      if not cfg.enabled then
        if o.enabled then
          table.insert(outArgs, "--off")
          risky = true
        end
      else
        if not o.enabled then
          table.insert(outArgs, "--on")
          risky = true
        end
        local modeChanged = cfg.width ~= o.width
          or cfg.height ~= o.height
          or not sameNumber(cfg.refresh, o.refresh, 0.0005)
        if cfg.width and (modeChanged or not o.enabled) and M.hasMode(o, cfg.width, cfg.height, cfg.refresh) then
          table.insert(outArgs, "--mode")
          table.insert(outArgs, M.modeArg(cfg))
          risky = true
        end
        if cfg.transform ~= o.transform or not o.enabled then
          table.insert(outArgs, "--transform")
          table.insert(outArgs, cfg.transform)
          if cfg.transform ~= o.transform then
            risky = true
          end
        end
        if not sameNumber(cfg.scale, o.scale, 0.0001) or not o.enabled then
          table.insert(outArgs, "--scale")
          table.insert(outArgs, M.formatScale(cfg.scale))
          if not sameNumber(cfg.scale, o.scale, 0.0001) then
            risky = true
          end
        end
        if cfg.x ~= o.x or cfg.y ~= o.y or not o.enabled then
          table.insert(outArgs, "--pos")
          table.insert(outArgs, math.floor(cfg.x) .. "," .. math.floor(cfg.y))
        end
        -- adaptiveSync nil means the compositor can't report (or set) it;
        -- passing the flag then makes wlr-randr fail the whole command.
        if cfg.adaptiveSync ~= nil and o.adaptiveSync ~= nil and cfg.adaptiveSync ~= o.adaptiveSync then
          table.insert(outArgs, "--adaptive-sync")
          table.insert(outArgs, cfg.adaptiveSync and "enabled" or "disabled")
        end
      end
      if #outArgs > 0 then
        any = true
        table.insert(args, "--output")
        table.insert(args, o.name)
        for _, a in ipairs(outArgs) do
          table.insert(args, a)
        end
      end
    end
  end

  if not any then
    return nil, false
  end
  return args, risky
end

-- Drops anything from a saved config the live output can no longer honour
-- (a mode it stopped advertising, an adaptive-sync state the compositor
-- can't set), falling back to the live value for those fields.
function M.sanitizeSaved(o: any, saved: any): any
  local cfg = M.configFromOutput(o)
  if type(saved) ~= "table" then
    return cfg
  end
  if type(saved.enabled) == "boolean" then
    cfg.enabled = saved.enabled
  end
  if M.hasMode(o, saved.width, saved.height, saved.refresh) then
    cfg.width, cfg.height, cfg.refresh = saved.width, saved.height, saved.refresh
  end
  if isTransform(saved.transform) then
    cfg.transform = saved.transform
  end
  if type(saved.scale) == "number" and saved.scale > 0 then
    cfg.scale = saved.scale
  end
  if type(saved.x) == "number" and type(saved.y) == "number" then
    cfg.x, cfg.y = math.floor(saved.x), math.floor(saved.y)
  end
  if o.adaptiveSync ~= nil and type(saved.adaptiveSync) == "boolean" then
    cfg.adaptiveSync = saved.adaptiveSync
  end
  return cfg
end

return M

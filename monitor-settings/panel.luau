--!nonstrict
-- Monitor Settings -- [[panel]] entry.
--
-- Renders whatever service.luau has published: every connected monitor,
-- its VCP features grouped by category (Image/Audio/Preset/Control/
-- Miscellaneous/Others), each as a card with the control its
-- classification calls for (button / slider / dropdown / read-only text).
-- All writes go back through state.set(COMMAND, ...) -- this file never
-- shells out itself.

local ddc = require("./lib/ddc.luau")
local wlr = require("./lib/wlr_output.luau")

local STATUS = "monitor_controls.status"
local COMMAND = "monitor_controls.command"

local status = noctalia.state.get(STATUS) or { detecting = false, checked = false, monitors = {} }

local LAYOUT = "monitor_controls.layout"
local layout = noctalia.state.get(LAYOUT) or { supported = false, outputs = {} }

-- Slider drags fire onChange continuously but should only hit ddcutil
-- once, on release (onDragEnd) -- this tracks the latest in-flight value
-- per "monitorId:code" between those two callbacks. The host itself
-- keeps showing the live drag position while dragging regardless of what
-- we render, so no extra bookkeeping is needed for the visual side.
local pendingSlider = {}

-- Video gain codes -> which RGB channel they drive. A gain slider's 0
-- means that channel contributes nothing at all, not "no color cast on
-- top of white" -- so the honest spectrum for one is black (0%) to that
-- channel's pure color (100%), not white to the color.
local RGB_GAIN_CHANNEL = { ["16"] = "r", ["18"] = "g", ["1A"] = "b" }

local function rgbGainSwatchColor(channel: string, level: number): string
  if level < 0 then level = 0 end
  if level > 1 then level = 1 end
  local hex = string.format("%02x", math.floor(level * 255 + 0.5))
  if channel == "r" then
    return "#" .. hex .. "0000"
  elseif channel == "g" then
    return "#00" .. hex .. "00"
  end
  return "#0000" .. hex
end

-- No native gradient primitive exists in this UI toolkit -- a row of many
-- flat-colored boxes was tried first, but flex-width rounding across that
-- many items leaves visible seams. A real image has no such seams, so
-- this renders one: a tiny 24-bit BMP (the simplest format that needs no
-- compression library, unlike PNG's mandatory DEFLATE), black at column 0
-- shading to the channel's pure color at the last column, then stretched
-- to fill the bar via ui.image's fit="stretch". Every row is identical
-- (a purely horizontal gradient), so storage order (BMP is bottom-up by
-- convention) doesn't matter and one row-height suffices.
local GRADIENT_WIDTH = 64

local function u16le(n: number): string
  n = n % 65536
  return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32le(n: number): string
  n = n % 4294967296
  return string.char(
    n % 256,
    math.floor(n / 256) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 16777216) % 256
  )
end

local function generateGradientBmp(width: number, channel: string): string
  local rowBytes = width * 3
  local padding = (4 - (rowBytes % 4)) % 4
  local pixelDataSize = rowBytes + padding
  local fileSize = 54 + pixelDataSize

  local fileHeader = "BM" .. u32le(fileSize) .. u16le(0) .. u16le(0) .. u32le(54)
  local dibHeader = u32le(40) .. u32le(width) .. u32le(1) .. u16le(1) .. u16le(24)
    .. u32le(0) .. u32le(pixelDataSize) .. u32le(0) .. u32le(0) .. u32le(0) .. u32le(0)

  local row = {}
  for x = 0, width - 1 do
    local level = (width > 1) and (x / (width - 1)) or 0
    local v = math.floor(level * 255 + 0.5)
    local r, g, b = 0, 0, 0
    if channel == "r" then r = v
    elseif channel == "g" then g = v
    else b = v end
    table.insert(row, string.char(b, g, r)) -- BMP pixel order is BGR
  end
  if padding > 0 then
    table.insert(row, string.rep("\0", padding))
  end

  return fileHeader .. dibHeader .. table.concat(row)
end

-- Generated once per channel into the plugin's persistent data dir (never
-- noctalia.pluginDir() -- that's a runtime copy the host can rewrite from
-- under a git-installed plugin) and reused after that; the file never
-- needs regenerating since its content is a pure function of the channel.
local gradientPathCache = {}

local function rgbGainGradientImagePath(channel: string): string
  local cached = gradientPathCache[channel]
  if cached then return cached end

  local path = noctalia.pluginDataDir() .. "/gradient_" .. channel .. ".bmp"
  if not noctalia.fileExists(path) then
    noctalia.writeFile(path, generateGradientBmp(GRADIENT_WIDTH, channel))
  end
  gradientPathCache[channel] = path
  return path
end

local function rgbGainGradientBar(channel: string)
  return ui.image({
    path = rgbGainGradientImagePath(channel),
    flexGrow = 1,
    height = 8,
    fit = "stretch",
  })
end

-- Selected monitor in the no-wlr-randr fallback list below (render()'s
-- else branch). Unrelated to selectedOutputName, which does the same job
-- for the arrangement canvas.
local selectedMonitorId = nil

-- Forward-declared: the icon row's click handler needs to trigger a
-- re-render, but render() (below) is what builds the icon row in the
-- first place. `local function render()` further down would create a
-- second, later local that the icon-row closure -- defined above it in
-- the file -- can never see; this earlier declaration is the one both ends
-- close over.
local render

local function sendSetvcp(monitorId, code, valueStr, optimisticCurrent)
  noctalia.state.set(COMMAND, {
    action = "setvcp",
    id = monitorId,
    code = code,
    value = valueStr,
    optimisticCurrent = optimisticCurrent,
  })
end

local function featureControl(monitorId, f, muteFeature)
  if f.widget == "button" then
    return ui.button({
      text = noctalia.tr("panel.trigger"),
      controlSize = "sm",
      onClick = function()
        sendSetvcp(monitorId, f.code, "1", nil)
      end,
    })
  elseif f.widget == "slider" then
    local key = monitorId .. ":" .. f.code
    local maxVal = (f.max and f.max > 0) and f.max or 100
    local current = f.current or 0

    local function commitTyped(text)
      local v = tonumber(text)
      if v == nil then return end
      local rounded = math.floor(v + 0.5)
      if rounded < 0 then rounded = 0 end
      if rounded > maxVal then rounded = maxVal end
      sendSetvcp(monitorId, f.code, tostring(rounded), rounded)
    end

    local sliderNode = ui.slider({
      min = 0,
      max = maxVal,
      value = current,
      flexGrow = 1,
      onChange = function(v)
        pendingSlider[key] = tonumber(v)
      end,
      onDragEnd = function()
        local v = pendingSlider[key]
        if v ~= nil then
          local rounded = math.floor(v + 0.5)
          sendSetvcp(monitorId, f.code, tostring(rounded), rounded)
          pendingSlider[key] = nil
        end
      end,
    })

    -- ui.input is uncontrolled (host owns the text once seeded), so the
    -- key is re-derived from the published value: an external change
    -- (write confirmed, refresh) forces a fresh field seeded with the new
    -- number, while typing itself never changes `current` and so never
    -- gets clobbered mid-edit.
    local valueInput = ui.input({
      key = key .. ":value:" .. tostring(current),
      value = tostring(current),
      controlSize = "sm",
      width = 48,
      submitOnEnter = true,
      onSubmit = commitTyped,
    })

    local channel = RGB_GAIN_CHANNEL[f.code]
    local sliderRow = ui.row({ gap = 8, align = "center", flexGrow = 1 }, { sliderNode, valueInput })

    if channel then
      sliderRow = ui.column({ gap = 6 }, { sliderRow, rgbGainGradientBar(channel) })
    end

    -- Code 62 (Audio speaker volume): composite with 8D (Audio
    -- mute/Screen blank) as a mute button next to the slider, mirroring
    -- the tama-shell original -- 8D itself never gets its own card (see
    -- groupFeaturesByCategory).
    if f.code == "62" and muteFeature then
      local muted = muteFeature.current == 1
      return ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
        sliderRow,
        ui.button({
          glyph = muted and "volume-off" or "volume",
          controlSize = "sm",
          variant = "ghost",
          onClick = function()
            local nextState = muted and 0 or 1
            sendSetvcp(monitorId, "8D", nextState == 1 and "0x01" or "0x02", nextState)
          end,
        }),
      })
    end
    return sliderRow
  elseif f.widget == "combobox" then
    local options = {}
    local selectedIndex = nil
    for i, v in ipairs(f.values) do
      table.insert(options, v.name)
      if f.current ~= nil and tonumber(v.code, 16) == f.current then
        selectedIndex = i - 1
      end
    end
    return ui.select({
      options = options,
      selectedIndex = selectedIndex,
      controlSize = "sm",
      onChange = function(indexStr, _text)
        local idx = tonumber(indexStr)
        local v = idx and f.values[idx + 1]
        if v then
          sendSetvcp(monitorId, f.code, "0x" .. v.code, tonumber(v.code, 16))
        end
      end,
    })
  end

  return ui.label({
    text = ddc.readOnlyDisplay(f) or noctalia.tr("readonly.no_data"),
    color = "on_surface_variant",
    fontSize = 13,
  })
end

-- Same situation as CATEGORY_TR_KEY below: ddc.luau's classifyFeature
-- passes vcpinfo's raw English feature name straight through (f.name) so
-- it stays a pure parser. This maps the standard MCCS VCP codes (per
-- ddcutil's own vcpinfo table) to a translated label; a code not in this
-- table -- typically an E0-FF manufacturer-extension code with no generic
-- MCCS name at all, or a rarer one not yet translated here -- falls back
-- to ddcutil's raw name, same as devices/ overrides do for value names.
local FEATURE_TR_KEY = {
  ["01"] = "feature.01", ["02"] = "feature.02", ["03"] = "feature.03", ["04"] = "feature.04",
  ["05"] = "feature.05", ["06"] = "feature.06", ["08"] = "feature.08", ["0a"] = "feature.0a",
  ["0b"] = "feature.0b", ["0c"] = "feature.0c", ["0e"] = "feature.0e", ["10"] = "feature.10",
  ["11"] = "feature.11", ["12"] = "feature.12", ["13"] = "feature.13", ["14"] = "feature.14",
  ["16"] = "feature.16", ["17"] = "feature.17", ["18"] = "feature.18", ["1a"] = "feature.1a",
  ["1c"] = "feature.1c", ["1e"] = "feature.1e", ["1f"] = "feature.1f", ["20"] = "feature.20",
  ["22"] = "feature.22", ["24"] = "feature.24", ["26"] = "feature.26", ["28"] = "feature.28",
  ["29"] = "feature.29", ["2a"] = "feature.2a", ["2c"] = "feature.2c", ["2e"] = "feature.2e",
  ["30"] = "feature.30", ["32"] = "feature.32", ["34"] = "feature.34", ["36"] = "feature.36",
  ["38"] = "feature.38", ["39"] = "feature.39", ["3a"] = "feature.3a", ["3c"] = "feature.3c",
  ["3e"] = "feature.3e", ["40"] = "feature.40", ["41"] = "feature.41", ["42"] = "feature.42",
  ["43"] = "feature.43", ["44"] = "feature.44", ["46"] = "feature.46", ["48"] = "feature.48",
  ["4a"] = "feature.4a", ["4c"] = "feature.4c", ["52"] = "feature.52", ["54"] = "feature.54",
  ["56"] = "feature.56", ["58"] = "feature.58", ["59"] = "feature.59", ["5a"] = "feature.5a",
  ["5b"] = "feature.5b", ["5c"] = "feature.5c", ["5d"] = "feature.5d", ["5e"] = "feature.5e",
  ["60"] = "feature.60", ["62"] = "feature.62", ["63"] = "feature.63", ["64"] = "feature.64",
  ["66"] = "feature.66", ["6b"] = "feature.6b", ["6c"] = "feature.6c", ["6d"] = "feature.6d",
  ["6e"] = "feature.6e", ["6f"] = "feature.6f", ["70"] = "feature.70", ["71"] = "feature.71",
  ["72"] = "feature.72", ["73"] = "feature.73", ["74"] = "feature.74", ["75"] = "feature.75",
  ["76"] = "feature.76", ["78"] = "feature.78", ["7a"] = "feature.7a", ["7c"] = "feature.7c",
  ["7e"] = "feature.7e", ["80"] = "feature.80", ["82"] = "feature.82", ["84"] = "feature.84",
  ["86"] = "feature.86", ["87"] = "feature.87", ["88"] = "feature.88", ["8a"] = "feature.8a",
  ["8b"] = "feature.8b", ["8c"] = "feature.8c", ["8d"] = "feature.8d", ["8e"] = "feature.8e",
  ["8f"] = "feature.8f", ["90"] = "feature.90", ["91"] = "feature.91", ["92"] = "feature.92",
  ["93"] = "feature.93", ["94"] = "feature.94", ["95"] = "feature.95", ["96"] = "feature.96",
  ["97"] = "feature.97", ["98"] = "feature.98", ["99"] = "feature.99", ["9a"] = "feature.9a",
  ["9b"] = "feature.9b", ["9c"] = "feature.9c", ["9d"] = "feature.9d", ["9e"] = "feature.9e",
  ["9f"] = "feature.9f", ["a0"] = "feature.a0", ["a2"] = "feature.a2", ["a4"] = "feature.a4",
  ["a5"] = "feature.a5", ["aa"] = "feature.aa", ["ac"] = "feature.ac", ["ae"] = "feature.ae",
  ["b0"] = "feature.b0", ["b2"] = "feature.b2", ["b4"] = "feature.b4", ["b6"] = "feature.b6",
  ["b7"] = "feature.b7", ["b8"] = "feature.b8", ["b9"] = "feature.b9", ["ba"] = "feature.ba",
  ["bb"] = "feature.bb", ["bc"] = "feature.bc", ["bd"] = "feature.bd", ["be"] = "feature.be",
  ["c0"] = "feature.c0", ["c2"] = "feature.c2", ["c3"] = "feature.c3", ["c4"] = "feature.c4",
  ["c6"] = "feature.c6", ["c8"] = "feature.c8", ["c9"] = "feature.c9", ["ca"] = "feature.ca",
  ["cc"] = "feature.cc", ["cd"] = "feature.cd", ["ce"] = "feature.ce", ["cf"] = "feature.cf",
  ["d0"] = "feature.d0", ["d2"] = "feature.d2", ["d4"] = "feature.d4", ["d6"] = "feature.d6",
  ["d7"] = "feature.d7", ["da"] = "feature.da", ["db"] = "feature.db", ["dc"] = "feature.dc",
  ["de"] = "feature.de", ["df"] = "feature.df",
}

local function featureLabel(code, rawName)
  local key = FEATURE_TR_KEY[string.lower(code)]
  return key and noctalia.tr(key) or rawName
end

-- Same standard-MCCS-code set as FEATURE_TR_KEY (reused instead of a
-- second 150-entry table -- a code translated has a description
-- translated too, by construction of how the translation files are
-- built), just under the "feature_desc" namespace instead of "feature".
local function featureDescLabel(code, rawDesc)
  local lc = string.lower(code)
  if not FEATURE_TR_KEY[lc] then return rawDesc end
  return noctalia.tr("feature_desc." .. lc) or rawDesc
end

local function featureCard(monitorId, f, muteFeature)
  local children = {
    ui.label({ text = featureLabel(f.code, f.name), fontSize = 13, fontWeight = "semibold", color = "on_surface" }),
  }
  if f.description ~= "" then
    table.insert(children, ui.label({
      text = featureDescLabel(f.code, f.description),
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 2,
    }))
  end
  table.insert(children, featureControl(monitorId, f, muteFeature))

  return ui.column({
    key = monitorId .. ":" .. f.code,
    gap = 4,
    padding = 10,
    radius = 8,
    fill = "secondary/0.10",
  }, children)
end

local function monitorDisplayName(m)
  return (m.model ~= nil and m.model ~= "") and m.model or noctalia.tr("panel.display_fallback", { id = m.id })
end

-- ddcutil's own "MCCS specification groups:" line is always plain English
-- ("Image", "Audio", ...) -- ddc.luau passes that raw text through as-is
-- (it stays a pure, host-agnostic parser, so it never calls noctalia.tr
-- itself), so the translation lookup happens here at render time instead.
-- Any category text not in this table (an MCCS group this plugin hasn't
-- seen) is shown as ddcutil printed it, untranslated.
local CATEGORY_TR_KEY = {
  Image = "category.image",
  Audio = "category.audio",
  Preset = "category.preset",
  Control = "category.control",
  Miscellaneous = "category.miscellaneous",
  Others = "category.others",
}

local function categoryLabel(category)
  local key = CATEGORY_TR_KEY[category]
  return key and noctalia.tr(key) or category
end

-- ---------------------------------------------------------------------
-- Display arrangement canvas + per-output display settings
-- ---------------------------------------------------------------------

-- Which output is selected on the canvas -- distinct from
-- selectedMonitorId (used only by the no-wlr-randr fallback list below):
-- selecting one is what shows its display and DDC/CI settings below.
local selectedOutputName = nil

-- The panel edits a *draft* of every output's config (see wlr_output.luau)
-- and only sends it to the service on Apply, like any display-settings
-- dialog: dragging three monitors around shouldn't reconfigure the
-- compositor three times, and a half-finished arrangement shouldn't ever
-- be live. Rebuilt from the live outputs whenever there are no unapplied
-- edits; while there are, outputs that appear/disappear are merged in.
local draft = {}
local draftDirty = false

local function outputsByName()
  local byName = {}
  for _, o in ipairs(layout.outputs or {}) do
    byName[o.name] = o
  end
  return byName
end

local function syncDraft()
  local live = wlr.configsFromOutputs(layout.outputs or {})
  if not draftDirty then
    draft = live
    return
  end
  for name, cfg in pairs(live) do
    if draft[name] == nil then
      draft[name] = cfg
    end
  end
  for name in pairs(draft) do
    if live[name] == nil then
      draft[name] = nil
    end
  end
end

local function markDirty()
  draftDirty = true
  render()
end

-- The canvas is a grid of small drop zones: the host's drag and drop only
-- ever reports *which* zone a drop landed on, never pointer coordinates,
-- and it has no absolutely-positioned layout -- so a fine grid of zones is
-- what turns "dropped on zone (col,row)" into a free position. Monitors
-- are drawn by tinting the cells they cover (gap 0, so they read as solid
-- rectangles), and every cell -- covered or not -- stays a drop target.
-- Kept to a few hundred cells: the whole tree is reconciled on every render.
local CANVAS_CELL = 16
local CANVAS_COLS = 40
local CANVAS_ROWS = 18

-- Per-output tint, cycled, so two monitors sharing an edge stay
-- distinguishable.
local OUTPUT_TINTS = { "primary", "secondary", "tertiary" }

-- View transform from the last render, used to map a drop's cell back to
-- logical coordinates. The drop always refers to the canvas as it was
-- drawn, which is the last render's.
local lastView = nil

local function sortedOutputNames()
  local names = {}
  for _, o in ipairs(layout.outputs or {}) do
    table.insert(names, o.name)
  end
  return names
end

-- The drag chip sits at the centre of its monitor, so the cell under the
-- pointer at release is taken as the monitor's new centre; snapPosition
-- then turns that rough spot into a flush, non-overlapping placement.
local function onCanvasDrop(name, value)
  local c, r, owner = string.match(value, "^(%d+),(%d+),?(.*)$")
  local cfg = draft[name]
  if not (c and r and cfg and cfg.enabled and lastView) then
    return
  end
  if owner == name then
    return -- dropped back onto its own label: no move intended
  end
  local unit = CANVAS_CELL / lastView.scale -- logical px per cell
  local cx = lastView.ox + (tonumber(c) + 0.5) * unit
  local cy = lastView.oy + (tonumber(r) + 0.5) * unit
  local w, h = wlr.logicalSize(cfg)
  local x, y = wlr.snapPosition(draft, name, cx - w / 2, cy - h / 2, unit * 2)
  cfg.x, cfg.y = x, y
  wlr.normalizeOrigin(draft)
  selectedOutputName = name
  markDirty()
end

local function outputChip(name, selected)
  return ui.dragSource({
    key = "output-drag-" .. name,
    dragType = "output",
    payload = name,
    previewAncestor = 0,
    tooltip = noctalia.tr("display.drag_hint"),
    align = "center",
    gap = 4,
    paddingH = 6,
    radius = 6,
    fill = selected and "primary" or "surface/0.85",
  }, {
    ui.glyph({ name = "device-desktop", size = 11, color = selected and "on_primary" or "on_surface" }),
    ui.label({
      text = name,
      fontSize = 10,
      fontWeight = selected and "bold" or "normal",
      color = selected and "on_primary" or "on_surface",
      maxLines = 1,
    }),
  })
end

local function arrangementCanvas()
  local canvasW = CANVAS_COLS * CANVAS_CELL
  local canvasH = CANVAS_ROWS * CANVAS_CELL
  local view = wlr.computeView(draft, canvasW, canvasH)
  lastView = view

  -- owner[r][c] = output name covering that cell; label[name] = the row
  -- its chip goes on and the column span it covers there.
  local owner = {}
  for r = 0, CANVAS_ROWS - 1 do
    owner[r] = {}
  end
  local tint = {}
  local labelRow = {}
  for i, name in ipairs(sortedOutputNames()) do
    local cfg = draft[name]
    tint[name] = OUTPUT_TINTS[(i - 1) % #OUTPUT_TINTS + 1]
    if cfg and cfg.enabled and cfg.width then
      local w, h = wlr.logicalSize(cfg)
      local px0 = (cfg.x - view.ox) * view.scale / CANVAS_CELL
      local py0 = (cfg.y - view.oy) * view.scale / CANVAS_CELL
      local px1 = (cfg.x + w - view.ox) * view.scale / CANVAS_CELL
      local py1 = (cfg.y + h - view.oy) * view.scale / CANVAS_CELL
      local c0 = math.max(0, math.floor(px0 + 0.5))
      local r0 = math.max(0, math.floor(py0 + 0.5))
      local c1 = math.min(CANVAS_COLS - 1, math.max(c0, math.floor(px1 + 0.5) - 1))
      local r1 = math.min(CANVAS_ROWS - 1, math.max(r0, math.floor(py1 + 0.5) - 1))
      for r = r0, r1 do
        for c = c0, c1 do
          if owner[r][c] == nil then
            owner[r][c] = name
          end
        end
      end
      labelRow[name] = { row = math.floor((r0 + r1) / 2), c0 = c0, c1 = c1 }
    end
  end

  local function cellFill(name)
    if name == nil then
      return nil
    end
    return tint[name] .. (name == selectedOutputName and "/0.55" or "/0.28")
  end

  local rows = {}
  for r = 0, CANVAS_ROWS - 1 do
    local cells = {}
    local c = 0
    while c < CANVAS_COLS do
      local name = owner[r][c]
      local lr = name and labelRow[name]
      if lr and lr.row == r and lr.c0 == c then
        -- The monitor's label strip: one wide zone holding the drag chip.
        local span = lr.c1 - lr.c0 + 1
        local centre = lr.c0 + math.floor(span / 2)
        table.insert(cells, ui.dropZone({
          key = "label-" .. name,
          accepts = { "output" },
          value = centre .. "," .. r .. "," .. name,
          onDrop = onCanvasDrop,
          direction = "row",
          justify = "center",
          align = "center",
          width = span * CANVAS_CELL,
          height = CANVAS_CELL,
          fill = cellFill(name),
        }, { outputChip(name, name == selectedOutputName) }))
        c = lr.c1 + 1
      else
        table.insert(cells, ui.dropZone({
          key = "cell-" .. c,
          accepts = { "output" },
          value = c .. "," .. r,
          onDrop = onCanvasDrop,
          direction = "row",
          width = CANVAS_CELL,
          height = CANVAS_CELL,
          fill = cellFill(name),
        }))
        c = c + 1
      end
    end
    table.insert(rows, ui.row({ key = "canvas-row-" .. r, gap = 0 }, cells))
  end

  local selectorButtons = {}
  for _, name in ipairs(sortedOutputNames()) do
    local cfg = draft[name]
    local text = name
    if cfg and not cfg.enabled then
      text = name .. " (" .. noctalia.tr("display.off") .. ")"
    end
    table.insert(selectorButtons, ui.button({
      key = "select-" .. name,
      text = text,
      glyph = "device-desktop",
      controlSize = "sm",
      selected = name == selectedOutputName,
      onClick = function()
        selectedOutputName = name
        render()
      end,
    }))
  end

  return ui.column({ key = "arrangement", gap = 8, align = "center" }, {
    ui.column({
      key = "canvas",
      gap = 0,
      width = canvasW + 2,
      padding = 1,
      radius = 8,
      fill = "surface_variant/0.35",
      border = "outline/0.4",
      borderWidth = 1,
    }, rows),
    ui.label({ text = noctalia.tr("display.canvas_hint"), fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
    ui.row({ gap = 6, justify = "center" }, selectorButtons),
  })
end

local TRANSFORM_TR_KEY = {
  normal = "transform.normal",
  ["90"] = "transform.90",
  ["180"] = "transform.180",
  ["270"] = "transform.270",
  flipped = "transform.flipped",
  ["flipped-90"] = "transform.flipped_90",
  ["flipped-180"] = "transform.flipped_180",
  ["flipped-270"] = "transform.flipped_270",
}

local function settingRow(labelText, controls)
  local children = {
    ui.label({ text = labelText, fontSize = 12, color = "on_surface_variant", width = 150, maxLines = 2 }),
  }
  for _, c in ipairs(controls) do
    table.insert(children, c)
  end
  return ui.row({ gap = 8, align = "center" }, children)
end

local function fmtNumber(n, decimals)
  local s = string.format("%." .. decimals .. "f", n)
  s = string.gsub(s, "0+$", "")
  s = string.gsub(s, "%.$", "")
  return s
end

-- After a change to an output's logical size (mode, scale, rotation) its
-- old position may now overlap a neighbour or leave a gap: re-resolve it
-- in place with no snapping distance.
local function resettle(name)
  local cfg = draft[name]
  if cfg and cfg.enabled then
    cfg.x, cfg.y = wlr.snapPosition(draft, name, cfg.x, cfg.y, 0)
    wlr.normalizeOrigin(draft)
  end
end

local function enabledCount()
  local n = 0
  for _, cfg in pairs(draft) do
    if cfg.enabled then
      n = n + 1
    end
  end
  return n
end

local function displaySettings(o, cfg)
  local name = o.name
  local enabled = cfg.enabled
  local children = {}

  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "device-desktop", size = 16, color = "primary" }),
    ui.column({ gap = 1, flexGrow = 1 }, {
      ui.label({ text = name, fontSize = 14, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = o.description or "", fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    ui.label({ text = noctalia.tr("display.enabled"), fontSize = 12, color = "on_surface_variant" }),
    ui.toggle({
      key = "enabled-" .. name,
      checked = enabled,
      -- Never let the last enabled output be switched off from here.
      enabled = not (enabled and enabledCount() <= 1),
      onChange = function(v)
        local on = v == "true"
        if on == cfg.enabled then return end
        cfg.enabled = on
        if on then
          -- Comes back to the right of the current arrangement.
          local maxX = 0
          for other, oc in pairs(draft) do
            if other ~= name and oc.enabled and oc.width then
              local w = wlr.logicalSize(oc)
              maxX = math.max(maxX, oc.x + w)
            end
          end
          cfg.x, cfg.y = maxX, 0
          resettle(name)
        end
        markDirty()
      end,
    }),
  }))

  if enabled then
    -- Resolution / refresh rate
    local resolutions = wlr.resolutions(o)
    local resOptions, resIndex = {}, nil
    for i, r in ipairs(resolutions) do
      table.insert(resOptions, r.width .. " × " .. r.height)
      if r.width == cfg.width and r.height == cfg.height then
        resIndex = i - 1
      end
    end
    local rates = wlr.refreshRates(o, cfg.width or 0, cfg.height or 0)
    local rateOptions, rateIndex = {}, nil
    for i, rate in ipairs(rates) do
      table.insert(rateOptions, wlr.formatRefresh(math.floor(rate * 100 + 0.5) / 100) .. " Hz")
      if cfg.refresh and math.abs(rate - cfg.refresh) < 0.0005 then
        rateIndex = i - 1
      end
    end
    table.insert(children, settingRow(noctalia.tr("display.resolution"), {
      ui.select({
        key = "res-" .. name,
        options = resOptions,
        selectedIndex = resIndex,
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(idx)
          local r = resolutions[(tonumber(idx) or -1) + 1]
          if not r then return end
          cfg.width, cfg.height = r.width, r.height
          -- Fastest rate the new resolution supports.
          cfg.refresh = wlr.refreshRates(o, r.width, r.height)[1]
          resettle(name)
          markDirty()
        end,
      }),
      ui.select({
        key = "rate-" .. name,
        options = rateOptions,
        selectedIndex = rateIndex,
        controlSize = "sm",
        width = 130,
        onChange = function(idx)
          local rate = rates[(tonumber(idx) or -1) + 1]
          if not rate then return end
          cfg.refresh = rate
          markDirty()
        end,
      }),
    }))

    -- Rotation
    local transformOptions, transformIndex = {}, nil
    for i, t in ipairs(wlr.TRANSFORMS) do
      table.insert(transformOptions, noctalia.tr(TRANSFORM_TR_KEY[t]))
      if t == cfg.transform then
        transformIndex = i - 1
      end
    end
    local function rotate(direction)
      cfg.transform = wlr.rotateTransform(cfg.transform, direction)
      resettle(name)
      markDirty()
    end
    table.insert(children, settingRow(noctalia.tr("display.rotation"), {
      ui.select({
        key = "transform-" .. name,
        options = transformOptions,
        selectedIndex = transformIndex,
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(idx)
          local t = wlr.TRANSFORMS[(tonumber(idx) or -1) + 1]
          if not t then return end
          cfg.transform = t
          resettle(name)
          markDirty()
        end,
      }),
      ui.button({
        glyph = "rotate",
        controlSize = "sm",
        variant = "ghost",
        tooltip = noctalia.tr("display.rotate_ccw"),
        onClick = function() rotate(-1) end,
      }),
      ui.button({
        glyph = "rotate-clockwise",
        controlSize = "sm",
        variant = "ghost",
        tooltip = noctalia.tr("display.rotate_cw"),
        onClick = function() rotate(1) end,
      }),
    }))

    -- Scale: presets, plus the current value when it isn't one of them.
    local scaleValues = {}
    local isPreset = false
    for _, s in ipairs(wlr.SCALE_PRESETS) do
      table.insert(scaleValues, s)
      if math.abs(s - cfg.scale) < 0.0001 then
        isPreset = true
      end
    end
    if not isPreset then
      table.insert(scaleValues, cfg.scale)
      table.sort(scaleValues)
    end
    local scaleOptions, scaleIndex = {}, nil
    for i, s in ipairs(scaleValues) do
      table.insert(scaleOptions, fmtNumber(s * 100, 1) .. "%")
      if math.abs(s - cfg.scale) < 0.0001 then
        scaleIndex = i - 1
      end
    end
    local function setScale(s)
      if not s or s < 0.25 or s > 4 then return end
      cfg.scale = s
      resettle(name)
      markDirty()
    end
    table.insert(children, settingRow(noctalia.tr("display.scale"), {
      ui.select({
        key = "scale-" .. name,
        options = scaleOptions,
        selectedIndex = scaleIndex,
        controlSize = "sm",
        flexGrow = 1,
        onChange = function(idx)
          setScale(scaleValues[(tonumber(idx) or -1) + 1])
        end,
      }),
      ui.input({
        key = "scale-input-" .. name .. ":" .. wlr.formatScale(cfg.scale),
        value = wlr.formatScale(cfg.scale),
        placeholder = noctalia.tr("display.custom_scale"),
        controlSize = "sm",
        width = 70,
        submitOnEnter = true,
        onSubmit = function(text)
          setScale(tonumber((string.gsub(text, ",", "."))))
        end,
      }),
    }))

    -- DPI: Wayland has no per-monitor DPI setting of its own -- scale *is*
    -- that setting -- so this shows what the monitor's physical density
    -- works out to at the chosen scale, and takes a target DPI to derive
    -- the scale from.
    local physical = wlr.physicalDpi(o, cfg)
    if physical then
      local effective = wlr.effectiveDpi(o, cfg)
      table.insert(children, settingRow(noctalia.tr("display.dpi"), {
        ui.label({
          text = noctalia.tr("display.dpi_value", {
            physical = tostring(math.floor(physical + 0.5)),
            effective = tostring(math.floor(effective + 0.5)),
          }),
          fontSize = 12,
          color = "on_surface",
          flexGrow = 1,
        }),
        ui.input({
          key = "dpi-input-" .. name .. ":" .. tostring(math.floor(effective + 0.5)),
          value = tostring(math.floor(effective + 0.5)),
          placeholder = noctalia.tr("display.target_dpi"),
          controlSize = "sm",
          width = 70,
          submitOnEnter = true,
          onSubmit = function(text)
            local target = tonumber((string.gsub(text, ",", ".")))
            if target then
              setScale(wlr.scaleForDpi(o, cfg, target))
            end
          end,
        }),
      }))
    else
      table.insert(children, settingRow(noctalia.tr("display.dpi"), {
        ui.label({ text = noctalia.tr("display.dpi_unknown"), fontSize = 12, color = "on_surface_variant", maxLines = 2, flexGrow = 1 }),
      }))
    end

    -- Adaptive sync (VRR) -- what FreeSync and G-Sync Compatible both are
    -- on Wayland. nil = the compositor can't report or set it.
    local vrrSupported = o.adaptiveSync ~= nil
    table.insert(children, settingRow(noctalia.tr("display.adaptive_sync"), {
      ui.toggle({
        key = "vrr-" .. name,
        checked = cfg.adaptiveSync == true,
        enabled = vrrSupported,
        onChange = function(v)
          cfg.adaptiveSync = v == "true"
          markDirty()
        end,
      }),
      ui.label({
        text = vrrSupported and "" or noctalia.tr("display.adaptive_sync_unsupported"),
        fontSize = 11,
        color = "on_surface_variant",
        maxLines = 2,
        flexGrow = 1,
      }),
    }))

    -- Exact position, for what the canvas grid is too coarse to place.
    local function positionInput(axis)
      return ui.input({
        key = "pos-" .. axis .. "-" .. name .. ":" .. tostring(cfg[axis]),
        value = tostring(cfg[axis]),
        controlSize = "sm",
        width = 80,
        submitOnEnter = true,
        onSubmit = function(text)
          local v = tonumber(text)
          if v == nil then return end
          cfg[axis] = math.floor(v)
          markDirty()
        end,
      })
    end
    local lw, lh = wlr.logicalSize(cfg)
    table.insert(children, settingRow(noctalia.tr("display.position"), {
      ui.label({ text = "X", fontSize = 12, color = "on_surface_variant" }),
      positionInput("x"),
      ui.label({ text = "Y", fontSize = 12, color = "on_surface_variant" }),
      positionInput("y"),
      ui.label({
        text = noctalia.tr("display.logical_size", { width = tostring(lw), height = tostring(lh) }),
        fontSize = 11,
        color = "on_surface_variant",
        flexGrow = 1,
      }),
    }))
  end

  return ui.column({
    key = "display-settings-" .. name,
    gap = 10,
    padding = 12,
    radius = 10,
    fill = "secondary/0.10",
  }, children)
end

local function applyBar()
  local now = noctalia.nowMs()
  local confirm = layout.confirm
  if confirm and confirm.deadlineMs and confirm.deadlineMs > now then
    local seconds = math.max(0, math.ceil((confirm.deadlineMs - now) / 1000))
    return ui.row({
      key = "confirm-bar",
      gap = 8,
      align = "center",
      padding = 10,
      radius = 10,
      fill = "tertiary/0.18",
    }, {
      ui.glyph({ name = "alert-triangle", size = 16, color = "tertiary" }),
      ui.label({
        text = noctalia.tr("display.confirm", { seconds = tostring(seconds) }),
        fontSize = 12,
        color = "on_surface",
        flexGrow = 1,
        maxLines = 2,
      }),
      ui.button({
        text = noctalia.tr("display.revert"),
        controlSize = "sm",
        variant = "ghost",
        onClick = function()
          noctalia.state.set(COMMAND, { action = "revert_config" })
        end,
      }),
      ui.button({
        text = noctalia.tr("display.keep"),
        controlSize = "sm",
        onClick = function()
          noctalia.state.set(COMMAND, { action = "confirm_config" })
        end,
      }),
    })
  end

  return ui.row({ key = "apply-bar", gap = 8, justify = "end" }, {
    ui.button({
      text = noctalia.tr("display.discard"),
      glyph = "arrow-back-up",
      controlSize = "sm",
      variant = "ghost",
      enabled = draftDirty,
      onClick = function()
        draftDirty = false
        syncDraft()
        render()
      end,
    }),
    ui.button({
      text = noctalia.tr("display.apply"),
      glyph = "check",
      controlSize = "sm",
      enabled = draftDirty,
      onClick = function()
        local configs = {}
        for name, cfg in pairs(draft) do
          configs[name] = wlr.copyConfig(cfg)
        end
        draftDirty = false
        noctalia.state.set(COMMAND, { action = "apply_config", configs = configs })
        render()
      end,
    }),
  })
end

-- A monitor's DDC/CI controls. onBack (the fallback list's only) collapses
-- this back out; under the arrangement canvas there's nothing to go back
-- to -- deselecting the output there hides it -- so it's nil.
local function monitorContent(m, onBack)
  local muteFeature = ddc.findFeature(m.features or {}, "8D")

  -- "Others" is the true fallback bucket -- codes with no vcpinfo entry
  -- at all (manufacturer-reserved, e.g. this ASUS's E0-EB) and nothing in
  -- devices/<model>.json either. They're real, readable values (see
  -- ddc.luau), just not meaningful without knowing what they mean, so
  -- they're noise in the common case: drop the whole category from what
  -- renders, without touching what gets parsed/classified.
  local groups = {}
  for _, g in ipairs(ddc.groupFeaturesByCategory(m.features or {})) do
    if g.category ~= "Others" then
      table.insert(groups, g)
    end
  end

  local header = {}
  if onBack then
    table.insert(header, ui.button({
      glyph = "arrow-left",
      controlSize = "sm",
      variant = "ghost",
      onClick = onBack,
    }))
  else
    table.insert(header, ui.label({
      text = noctalia.tr("display.ddc_header"),
      fontSize = 11,
      fontWeight = "bold",
      color = "primary",
    }))
  end
  table.insert(header, ui.label({
    text = monitorDisplayName(m),
    fontSize = 14,
    fontWeight = "bold",
    color = "on_surface",
  }))
  local children = {
    ui.row({ align = "center", gap = 8 }, header),
  }

  for _, g in ipairs(groups) do
    table.insert(children, ui.label({
      text = string.upper(categoryLabel(g.category)),
      fontSize = 11,
      fontWeight = "bold",
      color = "on_surface_variant",
    }))
    for _, f in ipairs(g.features) do
      table.insert(children, featureCard(m.id, f, muteFeature))
    end
  end

  return ui.column({ key = "monitor-content-" .. m.id, gap = 8 }, children)
end

render = function()
  local sections = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ align = "center", gap = 6 }, {
        ui.glyph({ name = "device-desktop", color = "primary", size = 18 }),
        ui.label({ text = noctalia.tr("panel.title"), fontSize = 15, fontWeight = "bold", color = "on_surface" }),
      }),
      ui.row({ gap = 6 }, {
        ui.button({
          glyph = "refresh",
          controlSize = "sm",
          variant = "ghost",
          tooltip = noctalia.tr("panel.refresh"),
          onClick = function()
            noctalia.state.set(COMMAND, { action = "refresh" })
          end,
        }),
        ui.button({
          glyph = "close",
          controlSize = "sm",
          variant = "ghost",
          onClick = function()
            panel.close()
          end,
        }),
      }),
    }),
  }

  -- The canvas (or, without wlr-randr, a plain monitor list) always stays
  -- on screen; clicking a monitor appends its DDC/CI settings below it
  -- rather than replacing the canvas. ddcutil status (detecting/not found)
  -- doesn't gate the canvas at all -- wlr-randr and ddcutil are independent
  -- dependencies, so a machine missing one still gets the other working.
  local monitors = status.monitors or {}

  local function ddcStatusNote()
    if status.detecting or not status.checked then
      -- Covers both: the real "detecting" window, and the brief instant
      -- between onOpen's ensure_loaded and the service actually flipping
      -- detecting true -- never shows the "no monitors" message for a
      -- monitor set that simply hasn't been checked yet.
      return ui.label({ text = noctalia.tr("panel.detecting"), color = "on_surface_variant", fontSize = 12 })
    elseif #monitors == 0 then
      return ui.label({
        text = noctalia.tr("panel.no_monitors"),
        color = "on_surface_variant",
        fontSize = 12,
        maxLines = 4,
      })
    end
    return nil
  end

  if layout.supported then
    -- Always have an output selected (like any display-settings dialog),
    -- falling back to the first one when nothing is, or the selected one
    -- was unplugged.
    local byName = outputsByName()
    if selectedOutputName == nil or byName[selectedOutputName] == nil then
      selectedOutputName = (layout.outputs[1] or {}).name
    end
    table.insert(sections, arrangementCanvas())

    -- If the selected output disappeared (unplugged, then Refresh), its
    -- settings simply stop rendering -- no separate screen to fall back
    -- out of.
    local selectedOutput = selectedOutputName and byName[selectedOutputName] or nil
    if selectedOutput and draft[selectedOutput.name] then
      table.insert(sections, displaySettings(selectedOutput, draft[selectedOutput.name]))
    end
    table.insert(sections, applyBar())

    local note = ddcStatusNote()
    if note then
      table.insert(sections, note)
    end

    -- Match the selected output back to its ddcutil monitor entry by
    -- model name appearing in wlr-randr's output description (e.g.
    -- "ASUSTek COMPUTER INC VG278 ..." contains ddcutil's Model "VG278").
    local targetMonitor = nil
    if selectedOutput then
      for _, m in ipairs(monitors) do
        if m.model and m.model ~= "" and string.find(selectedOutput.description or "", m.model, 1, true) then
          targetMonitor = m
          break
        end
      end
    end

    if targetMonitor then
      table.insert(sections, monitorContent(targetMonitor, nil))
    elseif selectedOutput then
      table.insert(sections, ui.label({
        text = noctalia.tr("panel.settings_unavailable"),
        color = "on_surface_variant",
        fontSize = 12,
      }))
    end
  else
    table.insert(sections, ui.label({
      text = noctalia.tr("panel.arrangement_unsupported"),
      color = "on_surface_variant",
      maxLines = 3,
    }))

    local note = ddcStatusNote()
    if note then
      table.insert(sections, note)
    end

    -- Without the canvas there'd be no route into the DDC/CI screens at
    -- all (selecting an output is normally what shows them), which would
    -- make the arrangement feature's missing dependency disable an
    -- unrelated one. A plain list of detected monitors keeps that half
    -- reachable, each expanding its own settings below the list on click.
    local selected = nil
    if selectedMonitorId ~= nil then
      for _, m in ipairs(monitors) do
        if m.id == selectedMonitorId then
          selected = m
          break
        end
      end
      if not selected then
        selectedMonitorId = nil
      end
    end

    for _, m in ipairs(monitors) do
      table.insert(sections, ui.button({
        key = "ddc-monitor-" .. m.id,
        text = monitorDisplayName(m),
        controlSize = "sm",
        selected = m.id == selectedMonitorId,
        onClick = function()
          selectedMonitorId = (selectedMonitorId == m.id) and nil or m.id
          render()
        end,
      }))
    end

    if selected then
      table.insert(sections, monitorContent(selected, function()
        selectedMonitorId = nil
        render()
      end))
    end
  end

  panel.render(ui.scroll({ flexGrow = 1, gap = 14, padding = 4 }, sections))
end

-- Second ticks only while a change awaits confirmation, to count its
-- revert deadline down on screen.
local function updateTicks()
  panel.setWantsSecondTicks(layout.confirm ~= nil)
end

function update()
  if layout.confirm then
    render()
  end
end

function onOpen(_context)
  status = noctalia.state.get(STATUS) or status
  layout = noctalia.state.get(LAYOUT) or layout
  syncDraft()
  updateTicks()
  -- The service does no ddcutil work at all until something actually
  -- needs it -- this is that trigger. checked latches true the instant a
  -- real detect starts, so re-opening the panel mid-fetch (or long after
  -- it finished) never re-triggers a redundant scan.
  if not status.checked then
    noctalia.state.set(COMMAND, { action = "ensure_loaded" })
  end
  render()
end

noctalia.state.watch(STATUS, function(val)
  if type(val) == "table" then
    status = val
    render()
  end
end)

noctalia.state.watch(LAYOUT, function(val)
  if type(val) == "table" then
    layout = val
    syncDraft()
    updateTicks()
    render()
  end
end)

syncDraft()
render()

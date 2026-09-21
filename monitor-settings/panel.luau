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

local STATUS = "monitor_controls.status"
local COMMAND = "monitor_controls.command"

local status = noctalia.state.get(STATUS) or { detecting = false, checked = false, monitors = {} }

local LAYOUT = "monitor_controls.layout"
local layout = noctalia.state.get(LAYOUT) or { supported = false, outputs = {}, cellMap = {} }

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
-- for the arrangement-grid tiles.
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

-- Which output tile is selected in the arrangement grid -- distinct from
-- selectedMonitorId (used only by the no-wlr-randr fallback list below):
-- selecting a tile is what makes its DDC/CI settings appear under the grid.
local selectedOutputName = nil

-- Matches the ui.dropZone width/height in arrangementGrid below -- an
-- occupied cell's own fill comes from the tile inside it (see cellFill in
-- arrangementGrid), so the tile has to actually fill the cell itself, not
-- just sit centered and smaller inside it.
local GRID_CELL_SIZE = 90

local function outputTile(o)
  local selected = selectedOutputName == o.name
  -- ui.dragSource swallows every click in its area to arm a possible drag
  -- (drag_source.cpp) and never forwards to a nested onClick, even on a
  -- plain tap -- there's no press-duration signal either, so a single
  -- area can't be "hold to drag, tap to open settings". Hence the split:
  -- the whole icon+name is the dragSource, and a separate gear button
  -- (outside it) opens this monitor's settings.
  return ui.column({
    key = "output-tile-" .. o.name,
    width = GRID_CELL_SIZE,
    height = GRID_CELL_SIZE,
    gap = 2,
    padding = 6,
    radius = 12,
    fill = selected and "primary/0.18" or "secondary/0.10",
  }, {
    -- ui.button always bakes in Style::spaceSm padding around its content
    -- (Button's constructor, unconditionally -- there's no "padding" prop
    -- to override it for buttons), which read as an oversized pink box
    -- around a 14px glyph. A plain row has no padding unless given one, so
    -- it sizes to exactly the glyph.
    ui.row({ justify = "end" }, {
      ui.row({
        onClick = function()
          selectedOutputName = o.name
          render()
        end,
      }, {
        ui.glyph({ name = "settings", size = 14, color = "on_surface_variant" }),
      }),
    }),
    ui.dragSource({
      key = "output-drag-" .. o.name,
      dragType = "output",
      payload = o.name,
      previewAncestor = 1,
      flexGrow = 1,
      align = "center",
      justify = "center",
    }, {
      -- drag_source is hardcoded Horizontal internally (createControl in
      -- the host's ui_tree_reconciler.cpp) regardless of any prop -- this
      -- inner column is what actually stacks the icon above the name.
      ui.column({ align = "center", gap = 3 }, {
        ui.glyph({
          name = "device-desktop",
          size = 30,
          color = selected and "primary" or "on_surface",
        }),
        ui.label({
          text = o.name,
          fontSize = 11,
          color = selected and "primary" or "on_surface_variant",
          maxLines = 1,
        }),
      }),
    }),
    -- Mirrors the gear row's own height (a 14px glyph) so this flexGrow
    -- area's center lines up with the whole tile's center, not just the
    -- center of the leftover space below the gear row -- without this the
    -- icon reads as sitting low, since only the top has a reserved strip.
    ui.spacer({ height = 14 }),
  })
end

local GRID_ROWS = 3
local GRID_COLS = 3

local function arrangementGrid(outputs, cellMap)
  local byCell = {}
  for name, cell in pairs(cellMap) do
    byCell[cell.row .. "," .. cell.col] = name
  end
  local byName = {}
  for _, o in ipairs(outputs) do
    byName[o.name] = o
  end

  local rows = {}
  for r = 0, GRID_ROWS - 1 do
    local rowCells = {}
    for c = 0, GRID_COLS - 1 do
      local occupantName = byCell[r .. "," .. c]
      local cellChildren = {}
      if occupantName and byName[occupantName] then
        table.insert(cellChildren, outputTile(byName[occupantName]))
      end

      -- An occupied cell takes no fill of its own (the tile inside it
      -- supplies the color); an empty one gets a faint one so the drop
      -- targets are visible. Written out rather than as
      -- `occupantName and nil or "secondary/0.05"`, which is the classic
      -- Lua ternary trap: with nil in the middle it yields the right-hand
      -- side unconditionally, so every cell got the empty-cell fill.
      local cellFill = nil
      if #cellChildren == 0 then
        cellFill = "secondary/0.05"
      end
      table.insert(rowCells, ui.dropZone({
        key = "cell-" .. r .. "-" .. c,
        accepts = { "output" },
        value = r .. "," .. c,
        onDrop = function(outputName, target)
          local row, col = string.match(target, "^(%d+),(%d+)$")
          noctalia.state.set(COMMAND, {
            action = "set_cell",
            name = outputName,
            row = tonumber(row),
            col = tonumber(col),
          })
        end,
        width = GRID_CELL_SIZE,
        height = GRID_CELL_SIZE,
        radius = 12,
        fill = cellFill,
      }, cellChildren))
    end
    table.insert(rows, ui.row({ key = "arrangement-row-" .. r, gap = 10 }, rowCells))
  end
  -- align = "center": ui.scroll (the panel's root container) stretches
  -- every top-level section to the panel's full width by default: without
  -- this, each row -- narrower than the panel -- sits pinned to the left
  -- edge of that stretched width instead of centered.
  return ui.column({ gap = 10, align = "center" }, rows)
end

-- A monitor's DDC/CI controls. onBack collapses this back out -- clears
-- selectedOutputName or selectedMonitorId, depending on which caller
-- rendered it.
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

  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.button({
        glyph = "arrow-left",
        controlSize = "sm",
        variant = "ghost",
        onClick = onBack,
      }),
      ui.label({
        text = monitorDisplayName(m),
        fontSize = 14,
        fontWeight = "bold",
        color = "on_surface",
      }),
    }),
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

  -- The grid (or, without wlr-randr, a plain monitor list) always stays
  -- on screen; clicking a monitor appends its DDC/CI settings below it
  -- rather than replacing the grid. ddcutil status (detecting/not found)
  -- doesn't gate the grid at all -- wlr-randr and ddcutil are independent
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
    table.insert(sections, arrangementGrid(layout.outputs, layout.cellMap))

    local note = ddcStatusNote()
    if note then
      table.insert(sections, note)
    end

    -- Match the selected tile's output back to its ddcutil monitor entry
    -- by model name appearing in wlr-randr's output description (e.g.
    -- "ASUSTek COMPUTER INC VG278 ..." contains ddcutil's Model "VG278").
    -- If the selected output disappeared (unplugged, then Refresh), this
    -- naturally comes back nil and the settings section just doesn't
    -- render -- no separate screen to fall back out of.
    local targetMonitor = nil
    if selectedOutputName then
      local selectedOutput = nil
      for _, o in ipairs(layout.outputs) do
        if o.name == selectedOutputName then
          selectedOutput = o
          break
        end
      end
      if selectedOutput then
        for _, m in ipairs(monitors) do
          if m.model and m.model ~= "" and string.find(selectedOutput.description or "", m.model, 1, true) then
            targetMonitor = m
            break
          end
        end
      end
    end

    if targetMonitor then
      table.insert(sections, monitorContent(targetMonitor, function()
        selectedOutputName = nil
        render()
      end))
    elseif selectedOutputName then
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

    -- Without the grid there'd be no route into the DDC/CI screens at
    -- all (a tile click is normally what selects a monitor), which would
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

function onOpen(_context)
  status = noctalia.state.get(STATUS) or status
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
    render()
  end
end)

render()

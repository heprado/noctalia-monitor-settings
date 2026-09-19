--!nonstrict
-- Monitor Controls -- [[panel]] entry.
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

-- Which monitor's settings are showing below the icon row -- one at a
-- time, tab-switcher style, picked by clicking its icon. nil until the
-- first render actually has a monitor list to default from.
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
      text = "Trigger",
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
    text = ddc.readOnlyDisplay(f),
    color = "on_surface_variant",
    fontSize = 13,
  })
end

local function featureCard(monitorId, f, muteFeature)
  local children = {
    ui.label({ text = f.name, fontSize = 13, fontWeight = "semibold", color = "on_surface" }),
  }
  if f.description ~= "" then
    table.insert(children, ui.label({
      text = f.description,
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
  return (m.model ~= nil and m.model ~= "") and m.model or ("Display " .. m.id)
end

-- Which output tile is highlighted in the arrangement grid -- distinct
-- from selectedMonitorId (which DDC/CI settings screen is open): this is
-- "highlighted for the Configurações button", that is "which screen is
-- currently showing".
local selectedOutputName = nil

local function outputTile(o)
  local selected = selectedOutputName == o.name
  -- onClick belongs on this inner column, NOT on the dragSource: the
  -- host's drag_source has no onClick prop at all (it drops unknown
  -- props with a `'drag_source' has no prop 'onClick', ignored` warning),
  -- so selecting a tile -- and with it the whole "Configurações" route
  -- into the DDC/CI screen -- silently never fired. Clicks on a control
  -- nested inside a drag source still work normally; dragging only takes
  -- over once the pointer passes the host's movement threshold.
  local content = ui.column({
    align = "center",
    gap = 6,
    onClick = function()
      selectedOutputName = o.name
      render()
    end,
  }, {
    ui.glyph({
      name = "device-desktop",
      size = 44,
      color = selected and "primary" or "on_surface",
    }),
    ui.label({
      text = o.name,
      fontSize = 12,
      color = selected and "primary" or "on_surface_variant",
      maxLines = 1,
    }),
  })

  return ui.dragSource({
    key = "output-tile-" .. o.name,
    dragType = "output",
    payload = o.name,
    previewAncestor = 0,
    align = "center",
    gap = 6,
    padding = 14,
    radius = 12,
    fill = selected and "primary/0.18" or "secondary/0.10",
  }, { content })
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
        width = 90,
        height = 90,
        radius = 12,
        fill = cellFill,
      }, cellChildren))
    end
    table.insert(rows, ui.row({ key = "arrangement-row-" .. r, gap = 10 }, rowCells))
  end
  return ui.column({ gap = 10 }, rows)
end

-- The selected monitor's own screen: a back button into the grid, then
-- everything monitorSection used to render below its old header.
local function monitorContent(m)
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
        onClick = function()
          selectedMonitorId = nil
          render()
        end,
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
      text = string.upper(g.category),
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
        ui.label({ text = "Monitor Controls", fontSize = 15, fontWeight = "bold", color = "on_surface" }),
      }),
      ui.row({ gap = 6 }, {
        ui.button({
          glyph = "refresh",
          controlSize = "sm",
          variant = "ghost",
          tooltip = "Refresh",
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

  -- Two screens: the home screen (arrangement grid) and one monitor's
  -- DDC/CI controls (selectedMonitorId set, from pressing
  -- "Configurações" with an output tile selected). If the selected
  -- monitor disappeared (unplugged, then Refresh), fall back to the home
  -- screen rather than showing a stale/missing screen.
  --
  -- The ddcutil status (detecting / none found) deliberately does NOT
  -- gate this split. Arrangement needs only wlr-randr and DDC/CI needs
  -- only ddcutil -- they're independent dependencies, so a machine with
  -- no ddcutil, no i2c-dev access, or DDC/CI switched off in the OSD
  -- still gets a fully working arrangement grid; that status is shown as
  -- a note under the grid (it explains a disabled "Configurações"
  -- button) instead of replacing everything.
  local monitors = status.monitors or {}
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

  local function ddcStatusNote()
    if status.detecting or not status.checked then
      -- Covers both: the real "detecting" window, and the brief instant
      -- between onOpen's ensure_loaded and the service actually flipping
      -- detecting true -- never shows the "no monitors" message for a
      -- monitor set that simply hasn't been checked yet.
      return ui.label({ text = "Detecting DDC/CI monitors…", color = "on_surface_variant", fontSize = 12 })
    elseif #monitors == 0 then
      return ui.label({
        text = "No DDC/CI monitors found. Make sure ddcutil is installed and DDC/CI is enabled in the monitor's own OSD menu.",
        color = "on_surface_variant",
        fontSize = 12,
        maxLines = 4,
      })
    end
    return nil
  end

  if selected then
    table.insert(sections, monitorContent(selected))
  elseif layout.supported then
    table.insert(sections, arrangementGrid(layout.outputs, layout.cellMap))

    local canConfigure = false
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
      canConfigure = targetMonitor ~= nil
    end
    table.insert(sections, ui.button({
      text = "Configurações",
      controlSize = "sm",
      enabled = canConfigure,
      onClick = function()
        selectedMonitorId = targetMonitor.id
        render()
      end,
    }))

    local note = ddcStatusNote()
    if note then
      table.insert(sections, note)
    end
  else
    table.insert(sections, ui.label({
      text = "Monitor arrangement requires wlr-randr and a compositor that supports "
        .. "wlr-output-management (Hyprland, Sway, river, ...).",
      color = "on_surface_variant",
      maxLines = 3,
    }))

    -- Without the grid there'd be no route into the DDC/CI screens at
    -- all (the "Configurações" button lives on a tile), which would make
    -- the arrangement feature's missing dependency disable an unrelated
    -- one. A plain list of detected monitors keeps that half reachable.
    local note = ddcStatusNote()
    if note then
      table.insert(sections, note)
    end
    for _, m in ipairs(monitors) do
      table.insert(sections, ui.button({
        key = "ddc-monitor-" .. m.id,
        text = monitorDisplayName(m),
        controlSize = "sm",
        onClick = function()
          selectedMonitorId = m.id
          render()
        end,
      }))
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

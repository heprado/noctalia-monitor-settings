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

local status = noctalia.state.get(STATUS) or { detecting = false, monitors = {} }

-- Slider drags fire onChange continuously but should only hit ddcutil
-- once, on release (onDragEnd) -- this tracks the latest in-flight value
-- per "monitorId:code" between those two callbacks. The host itself
-- keeps showing the live drag position while dragging regardless of what
-- we render, so no extra bookkeeping is needed for the visual side.
local pendingSlider = {}

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
    local sliderNode = ui.slider({
      min = 0,
      max = (f.max and f.max > 0) and f.max or 100,
      value = f.current or 0,
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

    -- Code 62 (Audio speaker volume): composite with 8D (Audio
    -- mute/Screen blank) as a mute button next to the slider, mirroring
    -- the tama-shell original -- 8D itself never gets its own card (see
    -- groupFeaturesByCategory).
    if f.code == "62" and muteFeature then
      local muted = muteFeature.current == 1
      return ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
        sliderNode,
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
    return sliderNode
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

local function monitorSection(m)
  local groups = ddc.groupFeaturesByCategory(m.features or {})
  local muteFeature = ddc.findFeature(m.features or {}, "8D")

  local children = {
    ui.row({ align = "center", gap = 8 }, {
      ui.label({
        text = (m.model ~= nil and m.model ~= "") and m.model or ("Display " .. m.id),
        fontSize = 14,
        fontWeight = "bold",
        color = "on_surface",
      }),
      m.loading and ui.label({ text = "loading…", fontSize = 11, color = "on_surface_variant" }) or ui.spacer({}),
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

  return ui.column({ key = "monitor-" .. m.id, gap = 8 }, children)
end

local function render()
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

  if status.detecting then
    table.insert(sections, ui.label({ text = "Detecting monitors…", color = "on_surface_variant" }))
  elseif not status.monitors or #status.monitors == 0 then
    table.insert(sections, ui.label({
      text = "No DDC/CI monitors found. Make sure ddcutil is installed and DDC/CI is enabled in the monitor's own OSD menu.",
      color = "on_surface_variant",
      maxLines = 4,
    }))
  else
    for _, m in ipairs(status.monitors) do
      table.insert(sections, monitorSection(m))
    end
  end

  panel.render(ui.scroll({ flexGrow = 1, gap = 14, padding = 4 }, sections))
end

function onOpen(_context)
  status = noctalia.state.get(STATUS) or status
  render()
end

noctalia.state.watch(STATUS, function(val)
  if type(val) == "table" then
    status = val
    render()
  end
end)

render()

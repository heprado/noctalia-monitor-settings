--!nonstrict
-- Monitor Settings -- [[widget]] entry (bar icon).
--
-- A launcher for the Quickshell app: click opens it, click again closes it.
-- Beside the icon, the refresh rate of the output this bar sits on.

local app = require("./lib/app.luau")

-- noctalia.outputs() has no refresh rate, and onOutputsChanged misses a change
-- that keeps the geometry (120 Hz to 100 Hz), so this asks wlr-randr.
local POLL_MS = 10000

-- "120Hz" for 119.982 Hz, which is 120 Hz to anyone reading a bar, but "59.94Hz"
-- for a rate that really differs from the round number.
local function hzText(hz)
  local rounded = math.floor(hz + 0.5)
  return math.abs(hz - rounded) < 0.05 and tostring(rounded) or string.format("%.2f", hz)
end

local function currentMode(outputs, name)
  for _, output in ipairs(outputs or {}) do
    if output.name == name then
      for _, mode in ipairs(output.modes or {}) do
        if mode.current == true then
          return mode
        end
      end
    end
  end
  return nil
end

local function render(mode, name)
  barWidget.setGlyph("device-desktop")
  local subtitle = noctalia.tr("launcher.subtitle")
  if mode == nil then
    barWidget.setText("")
    barWidget.setTooltip(subtitle)
    return
  end
  barWidget.setText(hzText(mode.refresh) .. "Hz")
  barWidget.setTooltip(
    string.format("%s\n%s: %dx%d @ %.2f Hz", subtitle, name, mode.width, mode.height, mode.refresh)
  )
end

local function refresh()
  local name = barWidget.outputName() or noctalia.focusedOutputName()
  noctalia.runAsync({ "wlr-randr", "--json" }, function(result)
    local outputs = result.exitCode == 0 and noctalia.json.decode(result.stdout) or nil
    render(currentMode(outputs, name), name)
  end)
end

function onClick()
  app.toggle()
  refresh()
end

function update()
  refresh()
end

render(nil, nil)
refresh()
noctalia.setUpdateInterval(POLL_MS)

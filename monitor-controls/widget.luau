--!nonstrict
-- Monitor Controls -- [[widget]] entry (bar icon).
--
-- Purely a status readout + panel launcher: service.luau owns every
-- ddcutil call, this just mirrors its published state into a glyph and a
-- tooltip, and opens the panel on click.

local STATUS = "monitor_controls.status"

local status = noctalia.state.get(STATUS) or { detecting = false, monitors = {} }

local function render()
  barWidget.setGlyph("device-desktop")

  if status.detecting then
    barWidget.setTooltip("Detecting monitors…")
  elseif status.monitors and #status.monitors > 0 then
    barWidget.setTooltip(string.format("%d monitor(s) with DDC/CI control", #status.monitors))
  else
    barWidget.setTooltip("No DDC/CI monitors detected")
  end
end

noctalia.state.watch(STATUS, function(val)
  if type(val) == "table" then
    status = val
    render()
  end
end)

function onClick()
  noctalia.togglePanel("heprado/monitor-controls:panel")
end

render()

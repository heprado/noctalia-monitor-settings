--!nonstrict
-- Monitor Controls -- [[widget]] entry (bar icon).
--
-- Purely a status readout + panel launcher: service.luau owns every
-- ddcutil call, this just mirrors its published state into a glyph and a
-- tooltip, and opens the panel on click.

local STATUS = "monitor_controls.status"

local status = noctalia.state.get(STATUS) or { detecting = false, checked = false, monitors = {} }

-- barWidget.render's declarative tree replaces the imperative
-- setGlyph/setText patches for the glyph/count row, but setTooltip is a
-- separate, still-live call (the tooltip prop on ui.row/ui.column itself
-- needs a newer plugin_api than this plugin declares). A horizontal bar
-- is thin in height (a row fits: icon beside the count), a side bar is
-- thin in width (only a column fits without clipping) -- branch on
-- barWidget.isVertical(), same as the runtime-api reference example.
local function render()
  local container = barWidget.isVertical() and ui.column or ui.row
  local children = { ui.glyph({ name = "device-desktop", size = 14 }) }

  if status.detecting then
    barWidget.setTooltip(noctalia.tr("widget.detecting"))
  elseif not status.checked then
    -- The service does no ddcutil work until the panel is opened once
    -- (see service.luau's ensure_loaded) -- an unchecked "none found"
    -- would be a flat-out guess, so say nothing's been checked instead.
    barWidget.setTooltip(noctalia.tr("widget.click_to_check"))
  elseif status.monitors and #status.monitors > 0 then
    table.insert(children, ui.label({ text = tostring(#status.monitors), fontWeight = "bold" }))
    barWidget.setTooltip(noctalia.trp("widget.monitors_found", #status.monitors))
  else
    barWidget.setTooltip(noctalia.tr("widget.none_detected"))
  end

  barWidget.render(container({ gap = 4, align = "center" }, children))
end

noctalia.state.watch(STATUS, function(val)
  if type(val) == "table" then
    status = val
    render()
  end
end)

function onClick()
  noctalia.togglePanel("heprado/monitor-settings:panel")
end

render()

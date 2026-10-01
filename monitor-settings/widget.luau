--!nonstrict
-- Monitor Settings -- [[widget]] entry (bar icon).
--
-- A launcher for the Quickshell app: click opens it, click again closes it.

local app = require("./lib/app.luau")

local function render()
  barWidget.setTooltip(noctalia.tr("launcher.subtitle"))
  barWidget.render(ui.glyph({ name = "device-desktop", size = 14 }))
end

function onClick()
  app.toggle()
end

render()

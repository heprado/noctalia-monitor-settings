--!nonstrict
-- Monitor Settings -- [[service]] entry.
--
-- The one thing that has to happen without the user opening anything:
-- reapply the saved display configuration at login. The app does that
-- itself in its headless "reapply" mode (see app/shell.qml); this starts
-- it once when the service does.

local app = require("./lib/app.luau")

app.reapply()

-- A plugin that's being turned off shouldn't leave its window behind.
function onExit(_signal, reason)
  if reason == "disable" or reason == "uninstall" then
    app.quit()
  end
end

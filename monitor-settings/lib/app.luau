--!nonstrict
-- Monitor Settings -- launching the Quickshell app in ../app.
--
-- Everything the plugin does -- the arrangement canvas, display settings,
-- DDC/CI controls -- lives in that app. The Noctalia entries only open it
-- (widget, launcher) and reapply the saved display configuration at login
-- (service).

local M = {}

local function quickshell(): string?
  if noctalia.commandExists("quickshell") then
    return "quickshell"
  elseif noctalia.commandExists("qs") then
    return "qs"
  end
  return nil
end

local function appDir(): string?
  local dir = noctalia.pluginDir()
  return dir and (dir .. "/app") or nil
end

local function missing()
  noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("errors.quickshell_missing"))
end

-- Opens the window, or closes it if it's already open: the app's
-- `monitorsettings.toggle` IPC call quits a running instance, and only
-- fails (non-zero exit) when there's none -- then one is launched. `-n`
-- keeps a double click from starting two.
function M.toggle()
  local qs, dir = quickshell(), appDir()
  if not qs or not dir then
    missing()
    return
  end
  noctalia.runAsync({ qs, "-p", dir, "ipc", "call", "monitorsettings", "toggle" }, function(result)
    if result.exitCode ~= 0 then
      noctalia.runAsync({ qs, "-p", dir, "-n", "-d" })
    end
  end)
end

-- Runs the app headless (no window): it reapplies the saved display
-- configuration for the connected outputs and exits.
function M.reapply()
  local qs, dir = quickshell(), appDir()
  if not qs or not dir then
    return
  end
  noctalia.runAsync({ "env", "MONITOR_SETTINGS_MODE=reapply", qs, "-p", dir })
end

function M.quit()
  local qs, dir = quickshell(), appDir()
  if qs and dir then
    noctalia.runAsync({ qs, "-p", dir, "ipc", "call", "monitorsettings", "quit" })
  end
end

return M

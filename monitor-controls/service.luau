--!nonstrict
-- Monitor Controls -- [[service]] entry.
--
-- Owns every ddcutil invocation and publishes classified per-monitor VCP
-- feature data to shared plugin state. widget.luau and panel.luau are
-- pure renderers of that state; they never shell out themselves, so every
-- write funnels through one place and stays consistent across both
-- surfaces.

local ddc = require("./lib/ddc.luau")

local STATUS = "monitor_controls.status"
local COMMAND = "monitor_controls.command"

local detecting = false
local monitors = {} -- ordered array of { id, model, features, loading }
local vcpInfoData = {}

local function publish()
  noctalia.state.set(STATUS, { detecting = detecting, monitors = monitors })
end

local function reclassifyAll()
  for _, m in ipairs(monitors) do
    local reclassified = {}
    for _, f in ipairs(m.features) do
      table.insert(reclassified, ddc.classifyFeature(f, vcpInfoData))
    end
    m.features = reclassified
  end
end

-- Generic MCCS protocol knowledge (not device-specific) -- fetched once,
-- not once per monitor.
local function loadVcpInfo()
  noctalia.runAsync({ "ddcutil", "vcpinfo", "--verbose" }, function(result)
    if result.exitCode == 0 then
      vcpInfoData = ddc.parseVcpInfo(result.stdout)
      reclassifyAll()
      publish()
    end
  end)
end

-- Real I2C queries against one display. capsProc (what's possible) and
-- valuesProc (what's current) run concurrently and independently, so
-- pendingValues (an upvalue shared by both closures) may still be empty
-- when the capabilities callback runs -- the values callback re-merges
-- current/max into m.features itself once it lands, whichever order they
-- finish in.
local function fetchMonitor(m)
  m.loading = true
  publish()

  local capsDone, valuesDone = false, false
  local pendingValues = {}

  local function finalize()
    if capsDone and valuesDone then
      m.loading = false
      publish()
    end
  end

  noctalia.runAsync({ "ddcutil", "--display", m.id, "capabilities", "--terse" }, function(result)
    if result.exitCode == 0 then
      local parsed = ddc.parseCapabilities(result.stdout)
      for _, f in ipairs(parsed) do
        local v = pendingValues[f.code]
        if v then
          f.current = v.current
          f.max = v.max
        end
      end
      local classified = {}
      for _, f in ipairs(parsed) do
        table.insert(classified, ddc.classifyFeature(f, vcpInfoData))
      end
      m.features = classified
    end
    capsDone = true
    finalize()
  end)

  noctalia.runAsync({ "ddcutil", "--display", m.id, "getvcp", "KNOWN", "--terse" }, function(result)
    if result.exitCode == 0 then
      pendingValues = ddc.parseTerseValues(result.stdout)
      if m.features then
        for _, f in ipairs(m.features) do
          local v = pendingValues[f.code]
          if v then
            f.current = v.current
            f.max = v.max
          end
        end
        if #m.features > 0 then
          local classified = {}
          for _, f in ipairs(m.features) do
            table.insert(classified, ddc.classifyFeature(f, vcpInfoData))
          end
          m.features = classified
        end
      end
    end
    valuesDone = true
    finalize()
  end)
end

-- Re-detects the connected display set (catches monitors turned on/off
-- since the last run), reusing existing monitor entries so in-flight
-- state survives, then re-fetches every display's capabilities/values --
-- this doubles as the "Refresh" button's handler.
local function detectAndRefreshAll()
  detecting = true
  publish()

  noctalia.runAsync({ "ddcutil", "detect" }, function(result)
    detecting = false

    if result.exitCode ~= 0 then
      publish()
      return
    end

    local displays = ddc.parseDetect(result.stdout)
    local byId = {}
    for _, m in ipairs(monitors) do
      byId[m.id] = m
    end

    local rebuilt = {}
    for _, d in ipairs(displays) do
      local m = byId[d.id]
      if m then
        m.model = d.model
      else
        m = { id = d.id, model = d.model, features = {}, loading = true }
      end
      table.insert(rebuilt, m)
    end
    monitors = rebuilt
    publish()

    for _, m in ipairs(monitors) do
      fetchMonitor(m)
    end
  end)
end

local function findMonitor(id: string)
  for _, m in ipairs(monitors) do
    if m.id == id then return m end
  end
  return nil
end

-- cmd = { action = "setvcp", id, code, value (string, as ddcutil expects
-- it -- decimal for continuous, "0xNN" for enum/button), optimisticCurrent
-- (number?) }. The UI updates optimistically (no readback poll) since
-- setvcp's own exit code is the only confirmation ddcutil gives quickly;
-- a full re-read happens on the next manual Refresh.
local function handleSetvcp(cmd)
  local m = findMonitor(cmd.id)
  if not m then return end

  if cmd.optimisticCurrent ~= nil then
    local f = ddc.findFeature(m.features, cmd.code)
    if f then
      f.current = cmd.optimisticCurrent
      publish()
    end
  end

  noctalia.runAsync({ "ddcutil", "--display", cmd.id, "setvcp", cmd.code, cmd.value }, function(result)
    if result.exitCode ~= 0 then
      noctalia.notifyError("Monitor Controls", "Failed to set " .. cmd.code .. " on display " .. cmd.id)
    end
  end)
end

noctalia.state.watch(COMMAND, function(cmd)
  if type(cmd) ~= "table" then return end
  if cmd.action == "refresh" then
    detectAndRefreshAll()
  elseif cmd.action == "setvcp" then
    handleSetvcp(cmd)
  end
end)

publish()
loadVcpInfo()
detectAndRefreshAll()

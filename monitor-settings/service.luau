--!nonstrict
-- Monitor Settings -- [[service]] entry.
--
-- Owns every ddcutil invocation and publishes classified per-monitor VCP
-- feature data to shared plugin state. widget.luau and panel.luau are
-- pure renderers of that state; they never shell out themselves, so every
-- write funnels through one place and stays consistent across both
-- surfaces.

local ddc = require("./lib/ddc.luau")
local wlr = require("./lib/wlr_output.luau")

local STATUS = "monitor_controls.status"
local COMMAND = "monitor_controls.command"
local LAYOUT = "monitor_controls.layout"

-- How long a risky change (mode, scale, rotation, on/off) stays applied
-- without being confirmed in the panel before it's rolled back -- the
-- same safety net every desktop's display settings has, since a mode the
-- monitor can't show leaves the user with no screen to click "undo" on.
local CONFIRM_SECONDS = 15

local function configFilePath()
  return noctalia.pluginDataDir() .. "/displays.json"
end

local wlrRandrSupported = noctalia.commandExists("wlr-randr")
local layoutOutputs = {} -- array, same shape wlr.parseOutputs returns

-- Set while a risky change is waiting for the user's confirmation:
-- { token, previous (configs to roll back to), next (configs to persist
-- on confirm), deadlineMs }.
local pendingConfirm = nil
local confirmSeq = 0

local function publishLayout()
  noctalia.state.set(LAYOUT, {
    supported = wlrRandrSupported,
    outputs = layoutOutputs,
    confirm = pendingConfirm and { deadlineMs = pendingConfirm.deadlineMs, token = pendingConfirm.token } or nil,
  })
end

-- Saved configs, keyed by output (connector) name -- the plugin's own data
-- directory, never the compositor's config, which on a Nix/home-manager
-- setup is read-only.
local savedConfigs = nil
local lastPersistedJson = nil

local function loadSaved()
  if savedConfigs ~= nil then
    return savedConfigs
  end
  savedConfigs = {}
  local raw = noctalia.readFile(configFilePath())
  local decoded = raw and noctalia.json.decode(raw)
  if type(decoded) == "table" then
    savedConfigs = decoded
  end
  return savedConfigs
end

-- Merged into what's already saved rather than replacing it, so a monitor
-- that's unplugged right now keeps its saved config for next time.
local function persist(configs)
  local saved = loadSaved()
  for name, cfg in pairs(configs) do
    saved[name] = cfg
  end
  local encoded = noctalia.json.encode(saved)
  if encoded ~= lastPersistedJson then
    lastPersistedJson = encoded
    noctalia.writeFile(configFilePath(), encoded)
  end
end

-- Re-reads the live output list and republishes it. `onDone` (optional)
-- runs once the fresh list is in.
local function refreshLayout(onDone)
  publishLayout()
  if not wlrRandrSupported then
    return
  end
  noctalia.runAsync({ "wlr-randr", "--json" }, function(result)
    if result.exitCode == 0 then
      local decoded = noctalia.json.decode(result.stdout)
      if type(decoded) == "table" then
        layoutOutputs = wlr.parseOutputs(decoded)
      end
    end
    publishLayout()
    if onDone then
      onDone()
    end
  end)
end

-- Runs one atomic `wlr-randr` invocation for every output whose config
-- differs from its live state (see wlr.buildApplyArgs), then re-reads the
-- live layout so the panel reflects the real outcome, not the request.
-- onApplied(ok, risky) runs after that re-read.
local function applyConfigs(configs, onApplied)
  local args, risky = wlr.buildApplyArgs(layoutOutputs, configs)
  if not args then
    if onApplied then
      onApplied(true, false)
    end
    return
  end
  noctalia.runAsync(args, function(result)
    local ok = result.exitCode == 0
    if not ok then
      noctalia.notifyError(
        noctalia.tr("panel.title"),
        noctalia.tr("errors.apply_failed", { error = (result.stderr or ""):gsub("%s+$", "") })
      )
    end
    refreshLayout(function()
      if onApplied then
        onApplied(ok, risky)
      end
    end)
  end)
end

local function revertPending()
  local p = pendingConfirm
  if not p then
    return
  end
  pendingConfirm = nil
  publishLayout()
  applyConfigs(p.previous, nil)
end

-- Applies the panel's draft. A change limited to position/adaptive sync
-- is kept and persisted straight away; anything riskier is kept only once
-- the user confirms it within CONFIRM_SECONDS, else rolled back.
local function handleApply(configs)
  if type(configs) ~= "table" then
    return
  end
  -- A new apply while an earlier one awaits confirmation builds on it:
  -- the rollback target stays the last *confirmed* state.
  local previous = pendingConfirm and pendingConfirm.previous or wlr.configsFromOutputs(layoutOutputs)
  applyConfigs(configs, function(ok, risky)
    if not ok then
      return
    end
    if not risky and not pendingConfirm then
      persist(configs)
      return
    end
    confirmSeq = confirmSeq + 1
    local token = confirmSeq
    pendingConfirm = {
      token = token,
      previous = previous,
      next = configs,
      deadlineMs = noctalia.nowMs() + CONFIRM_SECONDS * 1000,
    }
    publishLayout()
    -- No timer API in the service runtime; a `sleep` child is one.
    noctalia.runAsync({ "sleep", tostring(CONFIRM_SECONDS) }, function()
      if pendingConfirm and pendingConfirm.token == token then
        noctalia.notify(noctalia.tr("panel.title"), noctalia.tr("panel.reverted"))
        revertPending()
      end
    end)
  end)
end

local function handleConfirm()
  local p = pendingConfirm
  if not p then
    return
  end
  pendingConfirm = nil
  persist(p.next)
  publishLayout()
end

-- Startup: reapply whatever was saved for the outputs connected now. No
-- confirmation here -- this is a state the user already confirmed once.
local function reapplySaved()
  refreshLayout(function()
    local saved = loadSaved()
    local configs = {}
    local any = false
    for _, o in ipairs(layoutOutputs) do
      if saved[o.name] ~= nil then
        configs[o.name] = wlr.sanitizeSaved(o, saved[o.name])
        any = true
      end
    end
    if any then
      applyConfigs(configs, nil)
    end
  end)
end

local detecting = false
local checked = false -- true once the first detect/fetch cycle has ever run
local monitors = {} -- ordered array of { id, model, features, loading }
local vcpInfoData = {}

local function publish()
  noctalia.state.set(STATUS, { detecting = detecting, checked = checked, monitors = monitors })
end

-- Community-contributed, per-manufacturer OSD label overrides (see
-- devices/ and its README) -- keyed by the 3-letter VESA PNP id
-- (`ddcutil detect`'s "Mfg id:", e.g. "AUS" for ASUSTeK), not the exact
-- model, so one file covers a manufacturer's whole lineup instead of
-- needing an entry per model. Optional and additive: a manufacturer with
-- no matching file just gets {}, and classifyFeature falls back to
-- vcpinfo's generic name or a bare hex value. Cached per id since it's
-- read from disk on every classify call otherwise; sanitized because
-- mfgId comes from this display's own EDID, not a trusted literal.
local deviceNamesCache = {}

local function loadDeviceNames(mfgId: string?)
  if not mfgId or mfgId == "" then return {} end
  local safeId = mfgId:gsub("[^%w_%-]", "_")
  local cached = deviceNamesCache[safeId]
  if cached ~= nil then return cached end

  local names = {}
  local path = "devices/" .. safeId .. ".json"
  if noctalia.fileExists(path) then
    local raw = noctalia.readFile(path)
    if raw then
      local decoded = noctalia.json.decode(raw)
      if type(decoded) == "table" then
        names = decoded
      end
    end
  end
  deviceNamesCache[safeId] = names
  return names
end

local function reclassifyAll()
  for _, m in ipairs(monitors) do
    local deviceNames = loadDeviceNames(m.mfgId)
    local reclassified = {}
    for _, f in ipairs(m.features) do
      table.insert(reclassified, ddc.classifyFeature(f, vcpInfoData, deviceNames))
    end
    m.features = reclassified
  end
end

-- Generic MCCS protocol knowledge (not device-specific), but only for the
-- codes a monitor's own `capabilities` actually declared -- NOT the ~150
-- codes ddcutil knows about in total ("ddcutil vcpinfo --verbose" with no
-- code list). That whole-database dump produces ~1250 lines, and parsing
-- it reliably blew the plugin runtime's per-callback CPU budget (confirmed
-- live: "script callback 'async command callback' exceeded its CPU
-- budget").
--
-- Even the scoped ~30-code version has since tripped the same budget once,
-- at cold start specifically -- every other service, plugin, and the
-- compositor itself are all doing their own startup work in that window,
-- and the budget is wall-clock, not CPU-time-for-this-script-alone, so the
-- same parse that's comfortably fine once the system is idle can miss it
-- under that contention. Splitting the request into small batches bounds
-- what any *one* callback has to parse in one go, independent of how busy
-- the system is when it runs -- each batch is its own runAsync call, all
-- fired together, merging into vcpInfoData/reclassifying independently and
-- idempotently as each comes back.
local VCPINFO_BATCH_SIZE = 8

local function fetchVcpInfoForCodes(codes)
  for batchStart = 1, #codes, VCPINFO_BATCH_SIZE do
    local cmd = { "ddcutil", "vcpinfo" }
    for i = batchStart, math.min(batchStart + VCPINFO_BATCH_SIZE - 1, #codes) do
      table.insert(cmd, codes[i])
    end
    table.insert(cmd, "--verbose")
    noctalia.runAsync(cmd, function(result)
      if result.exitCode == 0 then
        for code, info in pairs(ddc.parseVcpInfo(result.stdout)) do
          vcpInfoData[code] = info
        end
        reclassifyAll()
        publish()
      end
    end)
  end
end

-- Current/max for exactly the codes this monitor's own capabilities
-- declared -- NOT "getvcp KNOWN", which silently drops every code
-- ddcutil has no generic vcpinfo entry for (confirmed live: `getvcp
-- KNOWN` omits this ASUS unit's manufacturer-specific E0-EB codes
-- entirely, even though `getvcp E0` alone reads it back fine -- KNOWN is
-- ddcutil's own generic-database membership test, not a capability
-- check). That's the whole reason "Others"-category cards never showed a
-- value: they're real, readable features, just never asked for.
local function fetchValuesForCodes(m, codes, onDone)
  if #codes == 0 then
    onDone()
    return
  end
  local cmd = { "ddcutil", "--display", m.id, "getvcp" }
  for _, code in ipairs(codes) do
    table.insert(cmd, code)
  end
  table.insert(cmd, "--terse")
  noctalia.runAsync(cmd, function(result)
    -- ddcutil exits 1 whenever ANY requested code is "not readable"
    -- (every Write Only feature always is, e.g. "Restore factory
    -- defaults") -- confirmed live: it still prints a valid "VCP <code>
    -- ..." line to stdout for every code that *did* read, alongside a
    -- "Feature XX (...) is not readable" line for the ones that didn't.
    -- Gating the merge on exitCode == 0 was throwing away every good
    -- value in the batch over one unrelated write-only code, which is
    -- worse than the "Others" bug this function was written to fix: it
    -- blanked every feature on the monitor, not just the unknown ones.
    if #m.features > 0 then
      local values = ddc.parseTerseValues(result.stdout)
      for _, f in ipairs(m.features) do
        local v = values[f.code]
        if v then
          f.current = v.current
          f.max = v.max
        end
      end
      local deviceNames = loadDeviceNames(m.mfgId)
      local reclassified = {}
      for _, f in ipairs(m.features) do
        table.insert(reclassified, ddc.classifyFeature(f, vcpInfoData, deviceNames))
      end
      m.features = reclassified
      publish()
    end
    onDone()
  end)
end

-- capabilities (what's possible) has to resolve before getvcp/vcpinfo
-- (what's current, and what those codes mean) can even know which codes
-- to ask about -- a monitor's own capability list is the only source for
-- that, so this is sequenced, not the independent-races shape the
-- capsProc/valuesProc split used to be.
local function fetchMonitor(m)
  m.loading = true
  publish()

  noctalia.runAsync({ "ddcutil", "--display", m.id, "capabilities", "--terse" }, function(result)
    if result.exitCode ~= 0 then
      m.loading = false
      publish()
      return
    end

    local parsed = ddc.parseCapabilities(result.stdout)
    local deviceNames = loadDeviceNames(m.mfgId)
    local classified = {}
    local codes = {}
    for _, f in ipairs(parsed) do
      table.insert(classified, ddc.classifyFeature(f, vcpInfoData, deviceNames))
      table.insert(codes, f.code)
    end
    m.features = classified
    publish()

    fetchVcpInfoForCodes(codes)
    fetchValuesForCodes(m, codes, function()
      m.loading = false
      publish()
    end)
  end)
end

-- Re-detects the connected display set (catches monitors turned on/off
-- since the last run), reusing existing monitor entries so in-flight
-- state survives, then re-fetches every display's capabilities/values --
-- this doubles as the "Refresh" button's handler.
local function detectAndRefreshAll()
  detecting = true
  checked = true
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
        m.mfgId = d.mfgId
      else
        m = { id = d.id, model = d.model, mfgId = d.mfgId, features = {}, loading = true }
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
      noctalia.notifyError(
        noctalia.tr("panel.title"),
        noctalia.tr("errors.setvcp_failed", { code = cmd.code, id = cmd.id })
      )
    end
  end)
end

noctalia.state.watch(COMMAND, function(cmd)
  if type(cmd) ~= "table" then return end
  if cmd.action == "refresh" then
    detectAndRefreshAll()
    -- The two halves of this plugin have entirely separate notions of
    -- "what's connected" -- ddcutil's display list and wlr-randr's output
    -- list -- and one Refresh press is meant to re-read both, so a
    -- monitor plugged in since startup appears in the arrangement canvas
    -- without reloading the whole plugin.
    refreshLayout(nil)
  elseif cmd.action == "ensure_loaded" then
    -- The panel/shortcut send this from onOpen, every time they open --
    -- checked (latched true the moment a real detect starts, not when it
    -- finishes) makes this idempotent, so opening the panel again while
    -- the first fetch is still in flight, or after it's long done, never
    -- re-triggers a redundant scan.
    if not checked then
      detectAndRefreshAll()
    end
  elseif cmd.action == "setvcp" then
    handleSetvcp(cmd)
  elseif cmd.action == "apply_config" then
    handleApply(cmd.configs)
  elseif cmd.action == "confirm_config" then
    handleConfirm()
  elseif cmd.action == "revert_config" then
    revertPending()
  end
end)

publish()
reapplySaved()

--!nonstrict
-- Monitor Controls -- [[service]] entry.
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

local GRID_ROWS = 3
local GRID_COLS = 3

local function layoutFilePath()
  return noctalia.pluginDataDir() .. "/layout.json"
end

local wlrRandrSupported = noctalia.commandExists("wlr-randr")
local layoutOutputs = {} -- array, same shape wlr.parseOutputs returns
local layoutCellMap = {} -- { [outputName] = { row, col } }

local function publishLayout()
  noctalia.state.set(LAYOUT, {
    supported = wlrRandrSupported,
    outputs = layoutOutputs,
    cellMap = layoutCellMap,
  })
end

-- Forward-declared: applyCellMap (below) re-reads via refreshLayout once
-- a `wlr-randr --pos` move completes, but refreshLayout itself is defined
-- further down (it needs applyCellMap to exist first).
local refreshLayout

-- The exact JSON last handed to noctalia.writeFile, so an applyCellMap
-- that changes nothing (every startup reapply, every refresh) doesn't
-- rewrite an identical layout.json over and over.
local lastPersistedJson = nil

-- Runs one `wlr-randr --output <name> --pos <x>,<y>` per output whose
-- computed position differs from what refreshLayout last read, then
-- persists the cell assignment (not the pixels -- see layoutFilePath)
-- and re-reads the live layout so the grid reflects the real outcome
-- rather than the optimistic guess.
--
-- That post-move re-read is deliberately the *non-applying* variant
-- (refreshLayout(false)). Re-applying from inside a callback this very
-- function started is an unbounded loop whenever the move doesn't take:
-- a failed `--pos` (or a compositor that reports back a position other
-- than the one requested) leaves the same difference in place, so the
-- next apply fires the same command again, forever -- spawning a
-- wlr-randr process and a notifyError on every lap. Re-reading and
-- republishing the real state is all this path ever needs to do.
local function applyCellMap(cellMap)
  layoutCellMap = cellMap
  publishLayout()

  if not wlrRandrSupported then
    return
  end

  local positions = wlr.computeLayout(layoutOutputs, cellMap, GRID_ROWS, GRID_COLS)
  local byName = {}
  for _, o in ipairs(layoutOutputs) do
    byName[o.name] = o
  end

  for name, pos in pairs(positions) do
    local current = byName[name]
    if current and (current.x ~= pos.x or current.y ~= pos.y) then
      noctalia.runAsync(
        { "wlr-randr", "--output", name, "--pos", pos.x .. "," .. pos.y },
        function(result)
          if result.exitCode ~= 0 then
            noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("errors.move_failed", { name = name }))
          end
          refreshLayout(false)
        end
      )
    end
  end

  local encoded = noctalia.json.encode(cellMap)
  if encoded ~= lastPersistedJson then
    lastPersistedJson = encoded
    noctalia.writeFile(layoutFilePath(), encoded)
  end
end

local layoutLoadedFromDisk = false

-- Returns the first cell of the grid that nothing in `taken` occupies,
-- scanning row-major, or nil when every cell is already spoken for (only
-- reachable with more outputs than GRID_ROWS * GRID_COLS cells -- such an
-- output simply stays unassigned rather than being stacked on top of
-- another one).
local function firstFreeCell(taken)
  for r = 0, GRID_ROWS - 1 do
    for c = 0, GRID_COLS - 1 do
      if not taken[r .. "," .. c] then
        return { row = r, col = c }
      end
    end
  end
  return nil
end

-- Re-reads the live output list. Called on service startup, from the
-- panel's Refresh button (so a monitor plugged in since the last read
-- actually shows up), and -- as refreshLayout(false) -- from
-- applyCellMap's own post-move callback.
--
-- `shouldApply` chooses what happens once the fresh output list is in:
-- true re-applies the current cell map through applyCellMap (which is
-- what makes a saved arrangement survive a restart, and what positions a
-- newly seeded output); false only republishes the state that was just
-- read. The post-move path must pass false -- see applyCellMap's comment
-- on why re-applying from inside its own callback never terminates.
--
-- Everything else here happens on every variant alike, exactly once:
-- the first read (whichever call gets there first) is the one that loads
-- layout.json off disk, and any output with no cell yet is seeded on
-- whichever read first sees it.
refreshLayout = function(shouldApply)
  if not wlrRandrSupported then
    publishLayout()
    return
  end
  -- Publish the support flag before the read, not after it: the panel's
  -- own default for this state is `supported = false`, so a panel opened
  -- in the window before the first `wlr-randr --json` resolves would
  -- otherwise tell a perfectly capable machine that it needs wlr-randr.
  publishLayout()
  noctalia.runAsync({ "wlr-randr", "--json" }, function(result)
    if result.exitCode ~= 0 then
      return
    end
    local decoded = noctalia.json.decode(result.stdout)
    if type(decoded) ~= "table" then
      return
    end
    layoutOutputs = wlr.parseOutputs(decoded)

    if not layoutLoadedFromDisk then
      layoutLoadedFromDisk = true
      local raw = noctalia.readFile(layoutFilePath())
      local saved = raw and noctalia.json.decode(raw)
      if type(saved) == "table" then
        -- Merged into the existing map, not swapped in for it: now that
        -- LAYOUT is published before this read resolves, the panel can
        -- show a live grid -- and the user can drag a tile, landing a
        -- set_cell in layoutCellMap -- while this first read is still in
        -- flight. A wholesale replacement would silently throw that
        -- drag away.
        for name, cell in pairs(saved) do
          layoutCellMap[name] = cell
        end
      end
    end

    -- Seed any output with no cell yet (a monitor plugged in for the
    -- first time, or the very first run with no saved file at all).
    -- wlr.seedCellMap is a pure heuristic over the unassigned outputs
    -- alone -- it has no idea which cells the saved entries already
    -- occupy -- so its suggestions are filtered here against the cells
    -- actually in use, both saved ones and the ones handed out earlier
    -- in this same pass. Without that, a seeded output could land on top
    -- of a saved one: two outputs at the identical computed position,
    -- and only one of them still visible in the grid (the panel keys
    -- cells by "row,col"), with no way to drag the other back out.
    local unassigned = {}
    for _, o in ipairs(layoutOutputs) do
      if layoutCellMap[o.name] == nil then
        table.insert(unassigned, o)
      end
    end
    if #unassigned > 0 then
      local taken = {}
      for _, cell in pairs(layoutCellMap) do
        if cell and cell.row and cell.col then
          taken[cell.row .. "," .. cell.col] = true
        end
      end

      local seeded = wlr.seedCellMap(unassigned, GRID_ROWS, GRID_COLS)
      -- Iterated over `unassigned` rather than `seeded` so the order is
      -- the output order wlr-randr reported, not pairs()' arbitrary one
      -- -- which output wins a contested cell then doesn't change from
      -- run to run.
      for _, o in ipairs(unassigned) do
        local cell = seeded[o.name]
        if cell then
          local key = cell.row .. "," .. cell.col
          if taken[key] then
            cell = firstFreeCell(taken)
            key = cell and (cell.row .. "," .. cell.col) or nil
          end
          if cell and key then
            taken[key] = true
            layoutCellMap[o.name] = cell
          end
        end
      end
    end

    if shouldApply then
      applyCellMap(layoutCellMap)
    else
      publishLayout()
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
    -- monitor plugged in since startup appears in the arrangement grid
    -- without reloading the whole plugin.
    refreshLayout(true)
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
  elseif cmd.action == "set_cell" then
    local newCellMap = {}
    for name, cell in pairs(layoutCellMap) do
      newCellMap[name] = cell
    end

    -- A cell holds at most one output (the design's rule, and what the
    -- panel's "row,col"-keyed cell lookup assumes). Dropping a tile onto
    -- an occupied cell is therefore a *swap*, not an overwrite: the
    -- output already there takes the dragged one's old cell. Overwriting
    -- instead would give both the identical computed pixel position, and
    -- the displaced tile would vanish from the grid with no way to drag
    -- it back.
    local previous = newCellMap[cmd.name]
    for name, cell in pairs(newCellMap) do
      if name ~= cmd.name and cell and cell.row == cmd.row and cell.col == cmd.col then
        -- previous is nil only for an output that had no cell at all
        -- (never seeded); then there's nowhere to swap the occupant to,
        -- so it's evicted to "unassigned" rather than stacked.
        newCellMap[name] = previous
        break
      end
    end

    newCellMap[cmd.name] = { row = cmd.row, col = cmd.col }
    applyCellMap(newCellMap)
  end
end)

publish()
refreshLayout(true)

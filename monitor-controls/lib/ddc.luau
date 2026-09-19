--!strict
-- Shared ddcutil output parsing and VCP feature classification.
--
-- Ported from tama-shell's shell/configuration/Monitor/MonitorSection.qml
-- (QML/JS, using JS regex) to Luau (using Lua patterns) for the Noctalia
-- plugin runtime. service.luau drives ddcutil and uses every function here;
-- panel.luau only needs groupFeaturesByCategory/readOnlyDisplay/findFeature
-- to render the classified data service.luau already published to state.
--
-- One real behavioral simplification vs. the QML original: every
-- Read-Write continuous feature renders as a single "slider" widget kind
-- here (the original QML split these into "slider" for codes 10/12/62 and
-- "spinbox" for the rest) -- panel.luau pairs every slider with an
-- editable ui.input for exact values, so the distinction doesn't change
-- what's adjustable.

local M = {}

M.categoryOrder = { "Image", "Audio", "Preset", "Control", "Miscellaneous", "Others" }

local function trim(s: string): string
  return (s:match("^%s*(.-)%s*$"))
end

-- `ddcutil detect`'s output: one "Display N" header per monitor, followed
-- by an indented "Model:" line and, under "EDID synopsis:", a "Mfg id:"
-- line -- the 3-letter PNP ID VESA assigns each manufacturer (e.g. "AUS"
-- for ASUSTeK), before the " - <name>" suffix ddcutil appends when it
-- doesn't recognize that id. This is what devices/ keys files by, not the
-- model, so an override applies across a manufacturer's whole lineup
-- instead of one exact model string.
function M.parseDetect(text: string)
  local displays = {}
  local current = nil
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local id = line:match("^Display (%d+)")
    if id then
      if current then table.insert(displays, current) end
      current = { id = id, model = "", mfgId = "" }
    elseif current then
      local model = line:match("^%s+Model:%s+(.+)")
      if model then
        current.model = trim(model)
      end
      local mfgId = line:match("^%s+Mfg id:%s+(%a+)")
      if mfgId then
        current.mfgId = trim(mfgId)
      end
    end
  end
  if current then table.insert(displays, current) end
  return displays
end

-- `ddcutil capabilities --terse`'s "Unparsed capabilities string:" line --
-- the raw VESA/MCCS "(...vcp(02 04 10 14(05 06 08 0B) 60(03 0F 11) ...)...)"
-- grammar. Walks to the matching close paren for vcp(...) (entries like
-- "14(05 06 08 0B)" nest one level), then tokenizes: a bare feature code
-- ("10") or a code with a space-separated value list ("14(05 06 08 0B)").
function M.parseCapabilities(text: string)
  local features = {}
  local vcpStart = text:find("vcp%(")
  if not vcpStart then return features end

  local i = vcpStart + 4
  local depth = 1
  local innerStart = i
  local len = #text
  while i <= len and depth > 0 do
    local c = text:sub(i, i)
    if c == "(" then
      depth = depth + 1
    elseif c == ")" then
      depth = depth - 1
    end
    i = i + 1
  end
  local inner = text:sub(innerStart, i - 2)

  local pos = 1
  local ilen = #inner
  while pos <= ilen do
    local s, e, code = inner:find("(%x%x)", pos)
    if not s then break end
    pos = e + 1

    local values = {}
    local ps, pe = inner:find("^%s*%(", pos)
    if ps then
      local closeRel = inner:find("%)", pe)
      if closeRel then
        local valuesRaw = inner:sub(pe + 1, closeRel - 1)
        for vcode in valuesRaw:gmatch("%x%x") do
          table.insert(values, { code = vcode, name = "" })
        end
        pos = closeRel + 1
      end
    end

    table.insert(features, {
      code = code,
      name = "",
      values = values,
    })
  end
  return features
end

-- `ddcutil getvcp KNOWN --terse` mixes three line formats depending on the
-- feature's type:
--   VCP <code> C <current-dec> <max-dec>
--   VCP <code> SNC x<value-hex>
--   VCP <code> CNC x<max-hi> x<max-lo> x<cur-hi> x<cur-lo>
function M.parseTerseValues(text: string)
  local result = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local code, cur, max = line:match("^VCP%s+(%x+)%s+C%s+(%d+)%s+(%d+)")
    if code then
      result[code] = { current = tonumber(cur), max = tonumber(max) }
    else
      local ccode, maxhi, maxlo, curhi, curlo =
        line:match("^VCP%s+(%x+)%s+CNC%s+x(%x+)%s+x(%x+)%s+x(%x+)%s+x(%x+)")
      if ccode then
        result[ccode] = {
          current = tonumber(curhi, 16) * 256 + tonumber(curlo, 16),
          max = tonumber(maxhi, 16) * 256 + tonumber(maxlo, 16),
        }
      else
        local scode, sval = line:match("^VCP%s+(%x+)%s+SNC%s+x(%x+)")
        if scode then
          result[scode] = { current = tonumber(sval, 16), max = nil }
        end
      end
    end
  end
  return result
end

-- `ddcutil vcpinfo --verbose`: generic MCCS protocol knowledge (not
-- device-specific), one "VCP code XX: name" block per feature with a
-- description line, an "Attributes: ..." (or versioned "Attributes
-- (vX.X): ...") line, an optional "Simple NC values:" block, and an
-- optional "MCCS specification groups:" line.
-- One linear pass over every line, not one `text:sub(...)` block slice
-- (~200 features x up to a few KB each) re-scanned with its own nested
-- gmatch per field -- that O(features x block length) shape reliably blew
-- the plugin runtime's per-callback CPU budget against ddcutil's real
-- ~200-feature vcpinfo dump (confirmed live: "script callback 'async
-- command callback' exceeded its CPU budget" from this exact function).
function M.parseVcpInfo(text: string)
  local result = {}

  local code, name = nil, nil
  local description = nil
  local descriptionDone = false
  local attrsPlain, attrsVersioned = nil, nil
  local values = {}
  local inValuesBlock = false
  local groups = {}

  local function flush()
    if not code then return end
    local attrs, continuity = "", ""
    local attrsLine = attrsPlain or attrsVersioned
    if attrsLine then
      local parts = {}
      for part in attrsLine:gmatch("([^,]+)") do
        table.insert(parts, trim(part))
      end
      attrs = parts[1] or ""
      continuity = parts[2] or ""
    end
    result[code] = {
      name = name,
      description = description or "",
      attrs = attrs,
      continuity = continuity,
      values = values,
      groups = groups,
    }
  end

  for line in (text .. "\n"):gmatch("(.-)\n") do
    local hcode, hname = line:match("^VCP code (%x+): (.+)$")
    if hcode then
      flush()
      code, name = hcode, trim(hname)
      description = nil
      descriptionDone = false
      attrsPlain, attrsVersioned = nil, nil
      values = {}
      inValuesBlock = false
      groups = {}
    elseif code then
      if not descriptionDone then
        if line:match("^%s*MCCS versions:")
          or line:match("^%s*MCCS specification groups:")
          or line:match("^%s*ddcutil feature subsets:")
          or line:match("^%s*Attributes")
        then
          descriptionDone = true
        else
          local trimmed = trim(line)
          if #trimmed > 0 then
            description = trimmed
            descriptionDone = true
          end
        end
      end

      local plain = line:match("^%s*Attributes:%s*(.+)$")
      if plain then
        attrsPlain = plain
      else
        -- Some features list one "Attributes (vX.X): ..." line per MCCS
        -- version; the newest (last) one wins, same as the QML original.
        local versioned = line:match("^%s*Attributes %(v[%d%.]+%):%s*(.+)$")
        if versioned then
          attrsVersioned = versioned
        end
      end

      if line:match("^%s*Simple NC values:%s*$") then
        inValuesBlock = true
      elseif inValuesBlock then
        local vcode, vname = line:match("^%s+0x(%x+):%s*(.+)$")
        if vcode then
          table.insert(values, { code = vcode, name = trim(vname) })
        else
          inValuesBlock = false
        end
      end

      if #groups == 0 then
        local groupsLine = line:match("^%s*MCCS specification groups:%s*(.+)$")
        if groupsLine then
          for g in groupsLine:gmatch("([^,]+)") do
            table.insert(groups, trim(g))
          end
        end
      end
    end
  end
  flush()

  return result
end

-- Merges a capabilities-derived feature (this monitor's own declared
-- codes -- authoritative for what it actually accepts) with vcpinfo's
-- generic protocol knowledge (name/description/attributes/category), and
-- decides which control to render.
--
-- deviceFeatureNames: proprietary OSD labels ddcutil has no way to know --
-- it only knows generic MCCS-defined names. Keyed by feature code
-- (lowercase), then by value code (lowercase); pass {} (or nil) when this
-- monitor's model has no matching file under devices/. The caller
-- (service.luau) owns loading devices/<model>.json -- this module stays a
-- pure parser/classifier with no file I/O of its own, so it stays usable
-- (and testable) independent of the plugin runtime.
function M.classifyFeature(capFeature, vcpInfoData, deviceFeatureNames)
  local info = vcpInfoData[capFeature.code] or {}
  local attrs = info.attrs or ""
  local continuity = info.continuity or ""

  local deviceNames = (deviceFeatureNames or {})[string.lower(capFeature.code)] or {}

  local vcpInfoNames = {}
  for _, v in ipairs(info.values or {}) do
    vcpInfoNames[string.lower(v.code)] = v.name
  end

  local values = {}
  for _, v in ipairs(capFeature.values or {}) do
    local codeLower = string.lower(v.code)
    -- Which codes a feature actually accepts is device-specific, and only
    -- capabilities (this monitor's own declaration) is authoritative for
    -- that -- vcpinfo is generic MCCS protocol knowledge and can list
    -- codes this monitor doesn't implement. deviceNames (this exact
    -- model, OSD-confirmed) wins over vcpinfo's generic name, which wins
    -- over a bare hex fallback when neither source knows this code.
    local vname = deviceNames[codeLower] or vcpInfoNames[codeLower] or ("0x" .. codeLower)
    table.insert(values, { code = v.code, name = vname })
  end

  -- Read-only display has no write risk, so it can prefer vcpinfo's
  -- (possibly more complete) generic names over the capabilities-derived
  -- list above.
  local displayValues = values
  if info.values and #info.values > 0 then
    displayValues = info.values
  end

  local category = "Others"
  if info.groups and #info.groups > 0 then
    category = info.groups[1]
  end

  local widget = "readonly"
  local isContinuous = continuity:sub(1, 10) == "Continuous"
  if attrs == "Write Only" then
    widget = "button"
  elseif attrs == "Read Write" and (isContinuous
      or (continuity == "Non-Continuous with continuous subrange"
        and (capFeature.code == "10" or capFeature.code == "12" or capFeature.code == "62"))) then
    widget = "slider"
  elseif attrs == "Read Write"
    and (continuity == "Non-Continuous (simple)" or continuity == "Non-Continuous (complex)")
    and #values > 0
  then
    widget = "combobox"
  end

  -- capFeature.name is always "" (parseCapabilities never has real names),
  -- and vcpInfoData has nothing at all for a code outside the generic MCCS
  -- spec (typically E0-FF manufacturer-extension codes) -- fall back to
  -- the raw code so the card always has a visible, non-blank title.
  local displayName = capFeature.name
  if info.name ~= nil and info.name ~= "" then
    displayName = info.name
  elseif displayName == "" then
    displayName = "VCP " .. capFeature.code
  end

  return {
    code = capFeature.code,
    name = displayName,
    description = info.description or "",
    category = category,
    attrs = attrs,
    continuity = continuity,
    values = values,
    displayValues = displayValues,
    widget = widget,
    current = capFeature.current,
    max = capFeature.max,
  }
end

-- AC/AE (Horizontal/Vertical frequency) are Continuous features, so their
-- raw current value is just a number to the generic path above -- but
-- ddcutil's own verbose getvcp output (confirmed live) scales them
-- specifically: AC is already Hz as-is (e.g. raw 3728 -> "3728 hz"), AE
-- is centihz (raw 11980 -> "119.80 hz", the monitor's actual refresh
-- rate). Neither scaling is generic MCCS knowledge exposed via vcpinfo --
-- it's ddcutil's own per-feature formatting -- so it has to be hardcoded
-- here the same way.
local FREQUENCY_DISPLAY = {
  AC = function(v: number) return tostring(v) .. " Hz" end,
  AE = function(v: number) return string.format("%.2f Hz", v / 100) end,
}

function M.readOnlyDisplay(f): string
  local freqFormat = FREQUENCY_DISPLAY[f.code]
  if freqFormat and f.current ~= nil then
    return freqFormat(f.current)
  end
  if f.displayValues and #f.displayValues > 0 and f.current ~= nil then
    for _, v in ipairs(f.displayValues) do
      if tonumber(v.code, 16) == f.current then
        return v.name
      end
    end
  end
  if f.current ~= nil then
    return tostring(f.current)
  end
  return "No data"
end

function M.findFeature(features, code: string)
  for _, f in ipairs(features) do
    if f.code == code then return f end
  end
  return nil
end

-- Buckets a monitor's classified features by .category, in categoryOrder
-- (Others last), any category present in the data but not in that fixed
-- list sorted alphabetically in between. Code 8D (Audio mute/Screen blank)
-- is excluded here, not just at render time -- it's composited onto 62's
-- (Audio speaker volume) slider instead of getting its own card, so a
-- monitor where 8D is the only Miscellaneous feature must not get an
-- empty "Miscellaneous" header.
function M.groupFeaturesByCategory(features)
  local byCategory = {}
  local seenOrder = {}
  for _, f in ipairs(features) do
    if f.code ~= "8D" then
      if not byCategory[f.category] then
        byCategory[f.category] = {}
        table.insert(seenOrder, f.category)
      end
      table.insert(byCategory[f.category], f)
    end
  end

  local ordered = {}
  for _, cat in ipairs(M.categoryOrder) do
    if cat ~= "Others" and byCategory[cat] then
      table.insert(ordered, { category = cat, features = byCategory[cat] })
    end
  end

  local known = {}
  for _, cat in ipairs(M.categoryOrder) do
    known[cat] = true
  end
  local extra = {}
  for _, cat in ipairs(seenOrder) do
    if not known[cat] then table.insert(extra, cat) end
  end
  table.sort(extra)
  for _, cat in ipairs(extra) do
    table.insert(ordered, { category = cat, features = byCategory[cat] })
  end

  if byCategory["Others"] then
    table.insert(ordered, { category = "Others", features = byCategory["Others"] })
  end

  return ordered
end

return M

--!nonstrict
-- Monitor Controls -- [[launcher_provider]] entry.
--
-- Answers behind the "/monitor" prefix and also the plain global search
-- (include_in_global_search = true in plugin.toml) -- typing "monitor" (or
-- anything that fuzzy-matches it) anywhere in the launcher surfaces one
-- result that opens the panel. No ddcutil calls here; the panel itself
-- triggers the service's lazy first load on open (see panel.luau/onOpen).

local RESULT_ID = "open-panel"

function onQuery(text)
  local score = 100
  if text ~= "" then
    score = noctalia.fuzzyScore(text, "Monitor Controls")
    if score == nil then
      launcher.setResults(text, {})
      return
    end
  end

  launcher.setResults(text, {
    {
      id = RESULT_ID,
      title = "Monitor Controls",
      subtitle = "DDC/CI monitor settings",
      glyph = "device-desktop",
      score = score,
    },
  })
end

function onActivate(id)
  if id == RESULT_ID then
    noctalia.togglePanel("heprado/monitor-controls:panel")
  end
end

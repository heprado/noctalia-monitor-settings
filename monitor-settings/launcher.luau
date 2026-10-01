--!nonstrict
-- Monitor Settings -- [[launcher_provider]] entry.
--
-- Answers behind the "/monitor" prefix and also the plain global search
-- (include_in_global_search = true in plugin.toml) -- typing "monitor" (or
-- anything that fuzzy-matches it) anywhere in the launcher surfaces one
-- result that opens the app.

local app = require("./lib/app.luau")

local RESULT_ID = "open-app"

function onQuery(text)
  local title = noctalia.tr("launcher.title")
  local score = 100
  if text ~= "" then
    -- Matched against the translated title, not a hardcoded English
    -- string, so searching in the user's own language finds this result.
    score = noctalia.fuzzyScore(text, title)
    if score == nil then
      launcher.setResults(text, {})
      return
    end
  end

  launcher.setResults(text, {
    {
      id = RESULT_ID,
      title = title,
      subtitle = noctalia.tr("launcher.subtitle"),
      glyph = "device-desktop",
      score = score,
    },
  })
end

function onActivate(id)
  if id == RESULT_ID then
    app.toggle()
  end
end

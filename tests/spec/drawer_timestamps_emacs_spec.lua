-- Timestamps inside drawers and property values, as Emacs Org 9.8 treats
-- them: org-agenda-get-timestamps keeps a match when org-at-timestamp-p
-- 'agenda is true (a timestamp object, e.g. in a drawer's paragraph, or
-- org-at-property-p); the TIMESTAMP / TIMESTAMP_IA properties and sparse
-- trees want timestamp objects (org-entry-properties skips node
-- properties, whose :type is nil); clock lines are clocks.
local parser = require("org.parser")
local date = require("org.date")
local T = date.days_from_civil(2026, 9, 28)

local function parse(lines)
  return parser.parse(lines)
end

local function agenda_titles(file)
  local out = {}
  for _, it in ipairs(require("org.agenda.items").agenda({ file }, T, T, { today = T })[T] or {}) do
    out[#out + 1] = it.title
  end
  table.sort(out)
  return out
end

describe("timestamps in drawers (Emacs)", function()
  it("puts timestamps of custom drawers, LOGBOOK notes and property values in the agenda", function()
    local file = parse({
      "* In a drawer",
      ":NOTES:",
      "Call about <2026-09-28 Mon 10:00>",
      ":END:",
      "* In a property",
      ":PROPERTIES:",
      ":WHEN:     <2026-09-28 Mon>",
      ":END:",
      "* Only a clock",
      ":LOGBOOK:",
      "CLOCK: [2026-09-28 Mon 10:00]--[2026-09-28 Mon 11:00] =>  1:00",
      ":END:",
      "* Commented",
      ":NOTES:",
      "# <2026-09-28 Mon>",
      ":END:",
      "* In a block in a drawer",
      ":NOTES:",
      "#+begin_example",
      "<2026-09-28 Mon>",
      "#+end_example",
      ":END:",
    })
    eq({ "In a drawer", "In a property" }, agenda_titles(file))
  end)

  it("leaves property values out of TIMESTAMP but uses drawer paragraphs", function()
    local file = parse({
      "* Entry",
      ":PROPERTIES:",
      ":WHEN:     <2026-09-01 Tue>",
      ":END:",
      ":NOTES:",
      "<2026-09-28 Mon>",
      ":END:",
    })
    eq("<2026-09-28 Mon>", file.headlines[1]:get_property("TIMESTAMP"))
  end)

  it("takes TIMESTAMP_IA from a LOGBOOK note but not from a clock line", function()
    local file = parse({
      "* Entry",
      ":LOGBOOK:",
      "CLOCK: [2026-09-01 Tue 10:00]--[2026-09-01 Tue 11:00] =>  1:00",
      '- State "DONE"       from "TODO"       [2026-09-02 Wed 09:00]',
      ":END:",
    })
    eq("[2026-09-02 Wed 09:00]", file.headlines[1]:get_property("TIMESTAMP_IA"))
  end)

  it("matches drawer timestamps but not property values in date sparse trees", function()
    org_buffer({
      "* Drawer",
      ":NOTES:",
      "<2026-09-01 Tue>",
      ":END:",
      "* Property",
      ":PROPERTIES:",
      ":WHEN:     <2026-09-01 Tue>",
      ":END:",
    }, { 1, 0 })
    local found = require("org.agenda.sparse").dates("before", date.parse("<2026-09-10 Thu>"))
    eq({ { lnum = 1 } }, found)
  end)
end)

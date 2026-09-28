-- Date sparse trees (org-check-before-date / -after-date / -dates-range)
-- with the date types of org-sparse-tree-default-date-type, and archived
-- trees kept folded (org-sparse-tree-open-archived-trees). The expected
-- matches and visible lines come from Emacs 9.8.10 (org-occur-highlights
-- after each command, see the round-5 probe sparse.el).
local sparse = require("org.agenda.sparse")
local fold = require("org.fold")
local date = require("org.date")
local config = require("org.config")

local doc = {
  "* A",
  "SCHEDULED: <2026-09-10 Thu>",
  "* B",
  "DEADLINE: <2026-09-20 Sun 10:00> SCHEDULED: <2026-09-15 Tue>",
  "* C",
  "Body <2026-09-15 Tue> and [2026-09-16 Wed] also <2026-09-30 Wed>--<2026-10-02 Fri>",
  "* DONE D",
  "CLOSED: [2026-09-14 Mon 09:00]",
  "* E",
  "text SCHEDULED: <2026-09-12 Sat> not planning",
  "=<2026-09-13 Sun>= verbatim",
  "* F :ARCHIVE:",
  "** G",
  "SCHEDULED: <2026-09-11 Fri>",
}

local function run(kind, type, d1, d2)
  local buf = org_buffer(doc, { 1, 0 })
  local notify = vim.notify
  vim.notify = function() end
  local out = sparse.dates(kind, date.parse("<" .. d1 .. ">"), d2 and date.parse("<" .. d2 .. ">"), type)
  vim.notify = notify
  local lines = buf_lines(buf)
  local got = {}
  for _, m in ipairs(out) do
    got[#got + 1] = m.lnum .. ":" .. lines[m.lnum]:sub(m.col, m.end_col)
  end
  local visible = {}
  for l = 1, #lines do
    if fold.line_visible(l) then
      visible[#visible + 1] = l
    end
  end
  return got, visible
end

describe("date sparse trees (Emacs 9.8.10)", function()
  local cases = {
    -- type, kind, dates, matches, visible lines
    { false, "before", { "2026-09-15" }, { "2:SCHEDULED: <2026-09-10 Thu>", "14:SCHEDULED: <2026-09-11 Fri>" }, { 1, 2, 3, 5, 7, 9, 12 } },
    { false, "after", { "2026-09-15" }, { "4:DEADLINE: <2026-09-20 Sun 10:00>", "4:SCHEDULED: <2026-09-15 Tue>" }, { 1, 3, 4, 5, 7, 9, 12 } },
    { false, "between", { "2026-09-12", "2026-09-16" }, { "4:SCHEDULED: <2026-09-15 Tue>" }, { 1, 3, 4, 5, 7, 9, 12 } },
    { "all", "before", { "2026-09-15" }, { "10:<2026-09-12 Sat>" }, { 1, 3, 5, 7, 9, 10, 11, 12 } },
    { "all", "after", { "2026-09-15" }, { "6:<2026-09-15 Tue>", "6:[2026-09-16 Wed]", "6:<2026-09-30 Wed>", "6:<2026-10-02 Fri>" }, { 1, 3, 5, 6, 7, 9, 12 } },
    { "all", "between", { "2026-09-12", "2026-09-16" }, { "6:<2026-09-15 Tue>", "10:<2026-09-12 Sat>" }, { 1, 3, 5, 6, 7, 9, 10, 11, 12 } },
    { "active", "after", { "2026-09-15" }, { "6:<2026-09-15 Tue>", "6:<2026-09-30 Wed>", "6:<2026-10-02 Fri>" }, { 1, 3, 5, 6, 7, 9, 12 } },
    { "inactive", "before", { "2026-09-15" }, {}, { 1, 3, 5, 7, 9, 12 } },
    { "inactive", "after", { "2026-09-15" }, { "6:[2026-09-16 Wed]" }, { 1, 3, 5, 6, 7, 9, 12 } },
    { "scheduled", "before", { "2026-09-15" }, { "2:SCHEDULED: <2026-09-10 Thu>", "14:SCHEDULED: <2026-09-11 Fri>" }, { 1, 2, 3, 5, 7, 9, 12 } },
    { "scheduled", "after", { "2026-09-15" }, { "4:SCHEDULED: <2026-09-15 Tue>" }, { 1, 3, 4, 5, 7, 9, 12 } },
    { "deadline", "before", { "2026-09-15" }, {}, { 1, 3, 5, 7, 9, 12 } },
    { "deadline", "after", { "2026-09-15" }, { "4:DEADLINE: <2026-09-20 Sun 10:00>" }, { 1, 3, 4, 5, 7, 9, 12 } },
    { "closed", "before", { "2026-09-15" }, { "8:CLOSED: [2026-09-14 Mon 09:00]" }, { 1, 3, 5, 7, 8, 9, 12 } },
    { "closed", "after", { "2026-09-15" }, {}, { 1, 3, 5, 7, 9, 12 } },
    { "closed", "between", { "2026-09-12", "2026-09-16" }, { "8:CLOSED: [2026-09-14 Mon 09:00]" }, { 1, 3, 5, 7, 8, 9, 12 } },
  }
  for _, c in ipairs(cases) do
    it(string.format("%s %s %s", tostring(c[1]), c[2], table.concat(c[3], " ")), function()
      local got, visible = run(c[2], c[1], c[3][1], c[3][2])
      eq(c[4], got)
      eq(c[5], visible)
    end)
  end

  it("uses sparse_tree_default_date_type when no type is given", function()
    config.opts.sparse_tree_default_date_type = "closed"
    local got = run("before", nil, "2026-09-15")
    config.opts.sparse_tree_default_date_type = nil
    eq({ "8:CLOSED: [2026-09-14 Mon 09:00]" }, got)
    eq({ "2:SCHEDULED: <2026-09-10 Thu>", "14:SCHEDULED: <2026-09-11 Fri>" }, (run("before", nil, "2026-09-15")))
  end)

  it("opens archived trees with sparse_tree_open_archived_trees", function()
    config.opts.sparse_tree_open_archived_trees = true
    local _, visible = run("before", false, "2026-09-15")
    config.opts.sparse_tree_open_archived_trees = false
    eq({ 1, 2, 3, 5, 7, 9, 12, 13, 14 }, visible)
  end)

  it("skips timestamps in property drawers, clocks, blocks and comments", function()
    -- Emacs 9.8.10 (probe sparse2.el): only the item, the table cell, the
    -- plain timestamp and the headline's match
    local buf = org_buffer({
      "* A",
      ":PROPERTIES:",
      ":WHEN: <2026-09-10 Thu>",
      ":END:",
      "CLOCK: [2026-09-10 Thu 10:00]--[2026-09-10 Thu 11:00] =>  1:00",
      "#+begin_src sh",
      "echo <2026-09-10 Thu>",
      "#+end_src",
      "# comment <2026-09-10 Thu>",
      "- item <2026-09-10 Thu>",
      "| <2026-09-10 Thu> |",
      "<2026-09-10 Thu 10:00-11:00>",
      "* B <2026-09-10 Thu>",
    }, { 1, 0 })
    local got = {}
    for _, m in ipairs(sparse.dated(buf, "all")) do
      got[#got + 1] = m.lnum
    end
    eq({ 10, 11, 12, 13 }, got)
  end)

  it("c in the menu cycles the date types like Emacs", function()
    org_buffer(doc, { 1, 0 })
    local titles = {}
    local answers = { "c", "c", "q" }
    local ui = require("org.ui")
    local menu = ui.menu
    ui.menu = function(o)
      titles[#titles + 1] = o.title
      local a = table.remove(answers, 1)
      return a ~= "q" and a or nil
    end
    sparse.prompt()
    ui.menu = menu
    eq({
      "Sparse tree (dates: scheduled/deadline)",
      "Sparse tree (dates: all timestamps)",
      "Sparse tree (dates: only scheduled)",
    }, titles)
  end)
end)

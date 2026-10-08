-- Timestamps in comments, fixed-width lines, keywords and verbatim blocks
-- (src, example, export, comment) are not timestamp objects in Emacs
-- (org-at-timestamp-p 'agenda needs one), so the agenda ignores them;
-- org-agenda-skip also skips diary sexps inside src blocks.
local date = require("org.date")
local items = require("org.agenda.items")
local parser = require("org.parser")

local today = date.parse("<2026-09-25 Fri>")
local T = today:days()
local stamp = "<2026-09-25 Fri>"

local function titles(list)
  local out = {}
  for _, it in ipairs(list or {}) do
    out[#out + 1] = it.title
  end
  table.sort(out)
  return out
end

local function day_titles(lines)
  local file = parser.parse(lines, "/tmp/agenda_skip_verbatim.org")
  return titles(items.agenda({ file }, T, T, { today = T })[T])
end

describe("agenda: timestamps outside timestamp objects", function()
  it("ignores comment, fixed-width and keyword lines", function()
    eq(
      { "Paragraph" },
      day_titles({
        "* Comment",
        "# " .. stamp,
        "  #",
        "* Fixed width",
        "  : " .. stamp,
        "* Keyword",
        "#+DATE: " .. stamp,
        "* Paragraph",
        "#not a comment " .. stamp,
      })
    )
  end)

  it("ignores src, example, export and comment blocks", function()
    local lines = {}
    for _, name in ipairs({ "src", "EXAMPLE", "export", "comment" }) do
      vim.list_extend(lines, {
        "* In " .. name,
        "#+begin_" .. name .. " org",
        stamp,
        ":FOO:",
        "#+end_" .. name,
      })
    end
    vim.list_extend(lines, {
      "* After blocks",
      "#+begin_src sh",
      "#+end_src",
      stamp,
    })
    eq({ "After blocks" }, day_titles(lines))
  end)

  it("keeps timestamps in other blocks and unterminated ones", function()
    eq(
      { "Quote", "Unterminated", "Verse" },
      day_titles({
        "* Quote",
        "#+begin_quote",
        stamp,
        "#+end_quote",
        "* Verse",
        "#+begin_verse",
        stamp,
        "#+end_verse",
        "* Unterminated",
        "#+begin_src sh",
        stamp,
      })
    )
  end)

  it("keeps the first inactive timestamp out of comments too", function()
    local file = parser.parse({
      "* H",
      "# [2026-01-01 Thu]",
      "#+begin_example",
      "[2026-01-02 Fri]",
      "#+end_example",
      "[2026-01-03 Sat]",
    }, "/tmp/agenda_skip_verbatim.org")
    eq("[2026-01-03 Sat]", file.headlines[1].first_inactive:to_string())
  end)

  it("skips diary sexps inside src blocks only", function()
    eq(
      { "in example", "outside" },
      day_titles({
        "* H",
        "#+begin_src emacs-lisp",
        "%%(diary-date 9 25 2026) in src",
        "#+end_src",
        "#+begin_example",
        "%%(diary-date 9 25 2026) in example",
        "#+end_example",
        "%%(diary-date 9 25 2026) outside",
      })
    )
  end)
  -- Emacs Org 9.8.10 (emacs -Q --batch, org-agenda-list)
  it("ignores verbatim, code, inline src, links and LaTeX environments", function()
    eq(
      { "Plain" },
      day_titles({
        "* Verbatim",
        "  see =" .. stamp .. "= here",
        "* Code",
        "  see ~" .. stamp .. "~ here",
        "* Inline src",
        "  src_sh{echo " .. stamp .. "} src_sh[:exports none]{x " .. stamp .. "}",
        "* Link desc",
        "  see [[https://x.org][" .. stamp .. "]] here",
        "* Link path [[" .. stamp .. "]]",
        "* Title =" .. stamp .. "= verbatim",
        "* Latex",
        "  \\begin{align*}",
        "  " .. stamp,
        "  \\end{align*}",
        "* Plain",
        "  " .. stamp,
      })
    )
  end)

  it("keeps a timestamp after an inline src block on the same line", function()
    eq({ "Src" }, day_titles({ "* Src", "  src_sh{echo x} and " .. stamp }))
  end)

  it("lists active timestamps inside drawers, not on CLOCK lines", function()
    eq(
      { "Drawer", "Logbook", "Prop" },
      day_titles({
        "* Prop",
        "  :PROPERTIES:",
        "  :WHEN: " .. stamp,
        "  :END:",
        "* Drawer",
        "  :org-gcal:",
        "  " .. stamp,
        "  :END:",
        "* Logbook",
        "  :LOGBOOK:",
        "  - Note taken on [2026-09-10 Thu 10:00] \\\\",
        "    follow up " .. stamp,
        "  :END:",
        "* Clock",
        "  :LOGBOOK:",
        "  CLOCK: <2026-09-25 Fri 10:00>--<2026-09-25 Fri 11:00> =>  1:00",
        "  :END:",
      })
    )
  end)

  it("todo_ignore_timestamp sees a property drawer timestamp", function()
    local config = require("org.config")
    local saved = config.opts.agenda.todo_ignore_timestamp
    config.opts.agenda.todo_ignore_timestamp = "past"
    local file = parser.parse({
      "* TODO Prop ts",
      "  :PROPERTIES:",
      "  :WHEN: <2026-09-20 Sun>",
      "  :END:",
      "* TODO Kept",
    }, "/tmp/agenda_skip_verbatim.org")
    local ok_, list = pcall(items.todo, { file }, nil, { today = T })
    config.opts.agenda.todo_ignore_timestamp = saved
    assert(ok_, list)
    eq({ "Kept" }, titles(list))
  end)
end)

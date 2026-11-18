-- Habit consistency graphs pinned to Emacs Org 9.8.10: org-habit-build-graph
-- over org-habit-parse-todo, drawn from (time-subtract nil ...) with "now"
-- at 2026-10-01 12:00 UTC and the default 21 preceding and 7 following
-- days. Each case is a habit's SCHEDULED line and its done dates; the
-- expected text and faces (per column, the blank last one left out) are
-- what Emacs prints for it.

local P = require("tests.emacs_parity")
local files = require("org.files")
local habits = require("org.agenda.habits")

local CASES = {
  {
    "a done date after the scheduled day",
    "SCHEDULED: <2026-09-21 +1d>",
    { "2026-09-29" },
    "                   * !       ",
    "cccccccccccaOOOOOOOOOOoooooo",
  },
  {
    ".+ with a maximum interval",
    "SCHEDULED: <2026-10-01 .+2d/4d>",
    { "2026-09-20", "2026-09-25", "2026-09-29" },
    "          *    *   * !       ",
    "ccccccccccRcrraOcrrRcRraoooo",
  },
  {
    "++ weekly",
    "SCHEDULED: <2026-10-05 ++1w>",
    { "2026-09-14", "2026-09-21", "2026-09-28" },
    "    *      *      *  !       ",
    "ccccRccccccRccccccRccCcccaoo",
  },
  {
    "+ overdue",
    "SCHEDULED: <2026-09-27 +3d>",
    { "2026-09-12", "2026-09-18" },
    "  *     *            !       ",
    "ccCcccccCccccccccaOOOOoooooo",
  },
  {
    ".+ with a done date before the graph",
    "SCHEDULED: <2026-09-30 .+1d>",
    { "2026-09-05", "2026-09-20" },
    "          *          !       ",
    "OOOOOOOOOOOcccccccccaOoooooo",
  },
  {
    "+ with a maximum interval, scheduled ahead",
    "SCHEDULED: <2026-10-03 +2d/5d>",
    { "2026-09-11", "2026-09-13", "2026-09-26" },
    " * *            *    !       ",
    "cRcCccccccccccccCccccCcrrrao",
  },
}

-- one letter per face: upper case for the face, lower case for its
-- Future variant
local LETTER = {
  C = "OrgAgendaHabitClear",
  R = "OrgAgendaHabitReady",
  A = "OrgAgendaHabitAlert",
  O = "OrgAgendaHabitOverdue",
}

local function expected_groups(letters)
  local out = {}
  for ch in letters:gmatch(".") do
    local base = LETTER[ch:upper()]
    out[#out + 1] = ch:match("%u") and base or (base .. "Future")
  end
  return out
end

describe("habit graphs (Emacs org-habit-build-graph)", function()
  P.freeze_time()

  for _, case in ipairs(CASES) do
    local name, scheduled, done, text, faces = unpack(case)
    it(name, function()
      local lines = { "* TODO Habit", scheduled, ":PROPERTIES:", ":STYLE: habit", ":END:" }
      for i = #done, 1, -1 do
        lines[#lines + 1] = ('- State "DONE"       from "TODO"       [%s 09:00]'):format(done[i])
      end
      local buf = org_buffer(lines)
      local h = habits.parse(files.get_buffer(buf).headlines[1])
      local g = habits.graph(h, require("org.date").today():days())
      local chars, groups = {}, {}
      for i, cell in ipairs(g) do
        chars[i] = cell[1]
        if i < #g then
          groups[i] = cell[2]
        end
      end
      eq(text, table.concat(chars))
      eq(expected_groups(faces), groups)
    end)
  end
end)

-- The done dates org-habit-parse-todo reads, pinned to Emacs Org 9.8.12
-- (org-habit-done-dates of the parsed habit, as dates). Its regexp takes a
-- change to a done keyword (the last inactive timestamp of the line) or a
-- note line of (cdr (assq 'done org-log-note-headings)) with %t / %d an
-- inactive timestamp, %T / %D an active one, %s / %S a quoted state and
-- %u / %U any text (org-replace-escapes). It reads at most
-- org-habit-preceding-days + org-habit-following-days of them: from the
-- heading down with org-log-states-order-reversed (the default), else from
-- the end of the entry up, which is org-entry-end-position: the next
-- heading line, an inline task's included.
describe("habit done dates (Emacs org-habit-parse-todo)", function()
  local config = require("org.config")

  --- The habit's lines: `logs` indented under its heading, a line that
  --- starts with "*" (an inline task) as it is.
  local function habit_lines(logs)
    local lines =
      { "* TODO Habit", "  SCHEDULED: <2026-10-01 Thu .+1d>", "  :PROPERTIES:", "  :STYLE: habit", "  :END:" }
    for _, l in ipairs(logs) do
      lines[#lines + 1] = (l:sub(1, 1) == "*" and "" or "  ") .. l
    end
    return lines
  end

  --- `fn()` with `heading` as `log_note_headings.done`, `opts.reversed`
  --- (default true) as `log_states_order_reversed` and `opts.config` set.
  local function with_heading(heading, opts, fn)
    local overrides = vim.tbl_extend("force", opts.config or {}, {
      log_note_headings = vim.tbl_extend("force", config.opts.log_note_headings or {}, { done = heading }),
      log_states_order_reversed = opts.reversed ~= false,
    })
    local saved = {}
    for k, v in pairs(overrides) do
      saved[k] = { config.opts[k] }
      config.opts[k] = v
    end
    local ok_, res = pcall(fn)
    for k, v in pairs(saved) do
      config.opts[k] = v[1]
    end
    assert(ok_, res)
    return res
  end

  local function done_dates(heading, logs, opts)
    opts = opts or {}
    local h = with_heading(heading, opts, function()
      return habits.parse(files.get_buffer(org_buffer(habit_lines(logs))).headlines[1])
    end)
    local out = {}
    for d in pairs(h.done_days) do
      out[#out + 1] = require("org.date").from_days(d):to_date_string()
    end
    table.sort(out)
    return out
  end

  it("reads the default heading", function()
    eq(
      { "2026-09-27", "2026-09-29" },
      done_dates("CLOSING NOTE %t", {
        "- CLOSING NOTE [2026-09-29 Tue 09:00] \\\\",
        "  ran",
        '- State "DONE"       from "TODO"       [2026-09-27 Sun 09:00]',
      })
    )
  end)

  it("reads a custom heading, and no longer the default one", function()
    eq(
      { "2026-09-29" },
      done_dates("Finished %t", { "- Finished [2026-09-29 Tue 09:00]", "- CLOSING NOTE [2026-09-25 Fri 09:00]" })
    )
    eq(
      { "2026-09-27" },
      done_dates("Finished %t", {
        "- CLOSING NOTE [2026-09-29 Tue 09:00] \\\\",
        "  ran",
        '- State "DONE"       from "TODO"       [2026-09-27 Sun 09:00]',
      })
    )
  end)

  it("reads a heading that starts with the date", function()
    eq(
      { "2026-09-29" },
      done_dates("%t done by %u", { "- [2026-09-29 Tue 09:00] done by osvaldo", "- [2026-09-28 Mon 09:00] skipped" })
    )
  end)

  it("takes an active timestamp for %T and both kinds of date for %d", function()
    eq(
      { "2026-09-29" },
      done_dates("Closed %T", { "- Closed <2026-09-29 Tue 09:00>", "- Closed [2026-09-28 Mon 09:00]" })
    )
    eq(
      { "2026-09-28", "2026-09-29" },
      done_dates("Closed on %d", { "- Closed on [2026-09-29 Tue]", "- Closed on [2026-09-28 Mon 10:00]" })
    )
  end)

  it("takes the last timestamp of a state change line", function()
    eq(
      { "2026-09-22" },
      done_dates(
        "CLOSING NOTE %t",
        { '- State "DONE"       from "TODO"       [2026-09-20 Sun 09:00] [2026-09-22 Tue 09:00]' }
      )
    )
  end)

  it("pads an escape with a width as org-replace-escapes pads its regexp", function()
    -- (format "%-12s" "\"\\S-+\"") adds 6 spaces after the 6 characters
    -- of the regexp, which the note written for "DONE" has too (one more
    -- before the date); "CANCELLED" leaves 2 and doesn't match
    eq(
      { "2026-09-29" },
      done_dates("Done %-12s %t", {
        '- Done "DONE"       [2026-09-29 Tue 09:00]',
        '- Done "DONE" [2026-09-28 Mon 09:00]',
        '- Done "CANCELLED"  [2026-09-27 Sun 09:00]',
      })
    )
    -- without "-" the spaces go before it
    eq(
      { "2026-09-29" },
      done_dates(
        "Done %12s %t",
        { '- Done       "DONE" [2026-09-29 Tue 09:00]', '- Done "DONE" [2026-09-28 Mon 09:00]' }
      )
    )
    -- (regexp-quote "%.3s") is %\\.3s, which no escape matches: text
    eq(
      { "2026-09-29" },
      done_dates("Done %.3s %t", { "- Done %.3s [2026-09-29 Tue 09:00]", '- Done "DON [2026-09-28 Mon 09:00]' })
    )
  end)

  it("reads a note org.nvim wrote with a padded heading", function()
    local stamp = require("org.date").parse("[2026-09-29 Tue 09:00]")
    local heading = with_heading("Done %-12s %t", {}, function()
      return require("org.edit").log_heading("done", "DONE", "TODO", stamp)
    end)
    eq({ "2026-09-29" }, done_dates("Done %-12s %t", { "- " .. heading }))
  end)

  it("stops at an inline task, as org-entry-end-position does", function()
    local inline = { config = { inlinetask_min_level = 15 } }
    local logs = {
      "*************** TODO Inline",
      '- State "DONE"       from "TODO"       [2026-09-28 Mon 09:00]',
      "*************** END",
      '- State "DONE"       from "TODO"       [2026-09-27 Sun 09:00]',
    }
    eq({}, done_dates("CLOSING NOTE %t", logs, inline))
    eq({}, done_dates("CLOSING NOTE %t", logs, vim.tbl_extend("force", inline, { reversed = false })))
    eq(
      { "2026-09-26" },
      done_dates("CLOSING NOTE %t", {
        '- State "DONE"       from "TODO"       [2026-09-26 Sat 09:00]',
        "*************** TODO Inline",
        "*************** END",
        '- State "DONE"       from "TODO"       [2026-09-27 Sun 09:00]',
      }, inline)
    )
  end)

  it("stops at an inline task in api.completed too", function()
    -- the inline task's own log line is its own completion, not the habit's
    local got = with_heading("CLOSING NOTE %t", { config = { inlinetask_min_level = 15 } }, function()
      local buf = org_buffer(habit_lines({
        "*************** TODO Inline",
        '- State "DONE"       from "TODO"       [2026-09-28 Mon 09:00]',
        "*************** END",
      }))
      local out = {}
      for _, c in ipairs(assert(require("org.api").completed({ bufnr = buf }))) do
        out[#out + 1] = c.headline.title .. " " .. c.type
      end
      return out
    end)
    eq({ "Inline state" }, got)
  end)

  it("reads 28 of them, from the top or, not reversed, from the bottom", function()
    -- 35 daily changes to DONE, oldest first
    local logs = {}
    local first = require("org.date").parse("[2026-08-20 Thu]"):days()
    for i = 0, 34 do
      local d = require("org.date").from_days(first + i)
      logs[#logs + 1] = '- State "DONE"       from "TODO"       [' .. d:to_date_string() .. " 09:00]"
    end
    local top = done_dates("CLOSING NOTE %t", logs)
    eq(28, #top)
    eq({ "2026-08-20", "2026-09-16" }, { top[1], top[#top] })
    local bottom = done_dates("CLOSING NOTE %t", logs, { reversed = false })
    eq(28, #bottom)
    eq({ "2026-08-27", "2026-09-23" }, { bottom[1], bottom[#bottom] })
  end)
end)

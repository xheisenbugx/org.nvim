-- The drill extension against org-drill.el (gitlab.com/phillord/org-drill):
-- scheduling algorithms, card types, session order, leeches and cram mode.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local date = require("org.date")
local sm2 = require("org.extensions.drill.sm2")
local schedule = require("org.extensions.drill.schedule")
local card = require("org.extensions.drill.card")
local parser = require("org.parser")

local function setup(drill)
  require("org").setup({
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
    extensions = drill ~= nil and { drill = drill } or nil,
  })
end

local function close_to(expected, actual, msg)
  ok(math.abs(expected - actual) < 1e-9, (msg or "") .. " expected " .. expected .. ", got " .. tostring(actual))
end

local function read(lines, n)
  local f = parser.parse(lines, "/tmp/drill-test.org")
  return card.read(f, f.headlines[n or 1])
end

-- frozen at 2026-09-29 Tue 10:30
local saved = {}
local function freeze()
  saved.today, saved.now, saved.today_days = date.today, date.now, date.today_days
  date.today = function()
    return date.Date.new({ year = 2026, month = 9, day = 29 })
  end
  date.now = function()
    return date.Date.new({ year = 2026, month = 9, day = 29, hour = 10, min = 30 })
  end
  date.today_days = function()
    return date.days_from_civil(2026, 9, 29)
  end
end
local function thaw()
  date.today, date.now, date.today_days = saved.today, saved.now, saved.today_days
end

describe("drill scheduling (org-drill parity)", function()
  local NEW = { last_interval = 0, repeats = 0, failures = 0, total_repeats = 0 }

  it("rounds halfway cases to the even number, like Emacs round", function()
    eq(2, schedule.round(2.5))
    eq(4, schedule.round(3.5))
    eq(3, schedule.round(2.6))
    eq(10, sm2.days_ahead(10.5))
    eq(16, sm2.days_ahead(15.5))
  end)

  it("org-drill-determine-next-interval-sm5 starts at the initial interval", function()
    local d, m = schedule.sm5(NEW, 4, {})
    close_to(4.0, d.last_interval)
    eq(2, d.repeats)
    close_to(2.5, d.ease)
    eq(1, d.total_repeats)
    -- the new optimal factor is stored under (n, the new ease)
    close_to(4.0, m["1"][schedule.ef_key(2.5)])
    d, m = schedule.sm5(d, 4, m)
    close_to(10.0, d.last_interval) -- factor 2.5 (the ease) * 4
    eq(3, d.repeats)
  end)

  it("org-drill-determine-next-interval-sm5 learns optimal factors", function()
    local d, m = schedule.sm5(NEW, 5, {})
    -- 0.5 * 4 + 0.5 * 4 * (0.72 + 5 * 0.07)
    close_to(4.14, d.last_interval)
    close_to(2.6, d.ease)
    close_to(4.14, m["1"][schedule.ef_key(2.6)])
    -- a failed card keeps its ease 2.6 and starts over at the learned factor
    local data = { last_interval = 10, repeats = 3, failures = 0, total_repeats = 3, ease = 2.6 }
    local failed, m2 = schedule.sm5(data, 2, m)
    eq(-1, failed.last_interval)
    eq(1, failed.repeats)
    eq(1, failed.failures)
    close_to(2.6, failed.ease)
    local again = schedule.sm5(failed, 4, m2)
    close_to(0.5 * 4.14 + 0.5 * 4.14 * (0.72 + 0.28), again.last_interval)
  end)

  it("org-drill-determine-next-interval-simple8", function()
    local d = schedule.simple8(NEW, 4)
    close_to(2.4849, d.last_interval)
    eq(1, d.repeats)
    eq(1, d.total_repeats)
    close_to(0.0542 * 256 - 0.4848 * 64 + 1.4916 * 16 - 1.2403 * 4 + 1.4515, d.ease)
    local d2 = schedule.simple8(d, 4)
    -- factor 1.2 + (ease - 1.2) * 0.5 ^ log2(1)
    close_to(2.4849 * (1.2 + (d.ease - 1.2)), d2.last_interval)
    -- a failure resets the repetitions and does not count in the total
    local f = schedule.simple8(d2, 1)
    eq(-1, f.last_interval)
    eq(0, f.repeats)
    eq(1, f.failures)
    eq(2, f.total_repeats)
    close_to(2.4849 * math.exp(-0.057), schedule.simple8(f, 4).last_interval)
  end)

  it("org-drill-hypothetical-next-review-dates never go down with the quality", function()
    local data = { last_interval = 6, repeats = 3, failures = 0, total_repeats = 2, ease = 1.3 }
    local dates = schedule.review_dates("sm2", data, nil, {})
    eq({ 0, 0, 0 }, { dates[1], dates[2], dates[3] })
    for q = 4, 6 do
      ok(dates[q] >= dates[q - 1])
    end
  end)

  it("org-drill-smart-reschedule stores the days ahead, 0 after a failure", function()
    local data = { last_interval = 6, repeats = 3, failures = 0, total_repeats = 2, ease = 2.5 }
    local d, days, failed, _, unschedule = schedule.answer("sm2", data, 1, nil, {})
    eq(true, failed)
    eq(true, unschedule)
    eq(0, d.last_interval)
    eq(0, days)
    d, days, failed, _, unschedule = schedule.answer("sm2", data, 4, nil, {})
    eq(false, failed)
    eq(false, unschedule)
    eq(15, days)
    close_to(15, d.last_interval)
  end)

  it("divides the interval growth by DRILL_CARD_WEIGHT", function()
    local data = { last_interval = 6, repeats = 3, failures = 0, total_repeats = 2, ease = 2.5 }
    -- 6 + (15 - 6) / 2 = 10.5, rounded to even
    local d, days = schedule.answer("sm2", data, 4, nil, {}, 2)
    close_to(10.5, d.last_interval)
    eq(10, days)
  end)
end)

describe("drill card types (org-drill parity)", function()
  local function first()
    return 1
  end
  local function any(m)
    return math.random(m)
  end
  local function clozes(ctype, total)
    local lines = { "* C :drill:", "  :PROPERTIES:", "  :DRILL_CARD_TYPE: " .. ctype }
    if total then
      lines[#lines + 1] = "  :DRILL_TOTAL_REPEATS: " .. total
    end
    vim.list_extend(lines, { "  :END:", "  [a] [b] [c] [d]" })
    return read(lines)
  end

  it("hidefirst and hidelast hide one end", function()
    eq({ [1] = true }, card.choose(clozes("hidefirst"), first).hidden)
    eq({ [4] = true }, card.choose(clozes("hidelast"), first).hidden)
  end)

  it("show2cloze shows two clozes", function()
    eq(2, vim.tbl_count(card.choose(clozes("show2cloze"), any).hidden))
  end)

  it("multicloze is hide1cloze", function()
    eq("multicloze", clozes("multicloze").type)
    eq(1, vim.tbl_count(card.choose(clozes("multicloze"), any).hidden))
  end)

  it("hide1_firstmore hides the first cloze, another one every weight-th repetition", function()
    eq({ [1] = true }, card.choose(clozes("hide1_firstmore", 0), any, 4).hidden)
    -- (1 + 3) mod 4 = 0: any cloze but the first
    for _ = 1, 10 do
      local h = card.choose(clozes("hide1_firstmore", 3), any, 4).hidden
      eq(nil, h[1])
      eq(1, vim.tbl_count(h))
    end
    -- without a weight it is hide1cloze
    eq(1, vim.tbl_count(card.choose(clozes("hide1_firstmore", 0), any).hidden))
  end)

  it("show1_lastmore shows the last cloze, another one every weight-th repetition", function()
    eq({ [1] = true, [2] = true, [3] = true }, card.choose(clozes("show1_lastmore", 0), any, 4).hidden)
    for _ = 1, 10 do
      local h = card.choose(clozes("show1_lastmore", 3), any, 4).hidden
      eq(true, h[1]) -- force-hide-first
      eq(3, vim.tbl_count(h))
    end
  end)

  it("show1_firstless shows a cloze but the first, the first every weight-th repetition", function()
    for _ = 1, 10 do
      local h = card.choose(clozes("show1_firstless", 0), any, 4).hidden
      eq(true, h[1])
      eq(3, vim.tbl_count(h))
      h = card.choose(clozes("show1_firstless", 3), any, 4).hidden
      eq(nil, h[1])
      eq(3, vim.tbl_count(h))
    end
  end)

  it("inherits DRILL_CARD_TYPE like org-drill-entry-f", function()
    local f = parser.parse({
      "* Deck",
      "  :PROPERTIES:",
      "  :DRILL_CARD_TYPE: hidefirst",
      "  :END:",
      "** Q :drill:",
      "   [x] and [y]",
    }, "/tmp/drill-test.org")
    eq("hidefirst", card.read(f, f.headlines[2]).type)
  end)

  it("marks card types org-drill does not know", function()
    eq("nonsense", read({ "* X :drill:", "  :PROPERTIES:", "  :DRILL_CARD_TYPE: nonsense", "  :END:", "  y" }).unknown)
    eq(nil, read({ "* X :drill:", "  :PROPERTIES:", "  :DRILL_CARD_TYPE: conjugate", "  :END:", "  y" }).unknown)
  end)

  it("reads the old LEARN_DATA property like org-drill-get-item-data", function()
    local c = read({
      "* X :drill:",
      "  :PROPERTIES:",
      "  :LEARN_DATA: (6.0 3 2.36)",
      "  :DRILL_LAST_QUALITY: 4",
      "  :END:",
      "  y",
    })
    eq(6, c.data.last_interval)
    eq(3, c.data.repeats)
    close_to(2.36, c.data.ease)
    eq(4, c.data.meanq)
  end)
end)

local DECK = {
  "* Capital of France :drill:",
  "  What is the capital of France?",
  "** Answer",
  "   Paris",
  "* Opposite of hot :drill:",
  "  SCHEDULED: <2026-09-28 Mon>",
  "  :PROPERTIES:",
  "  :DRILL_LAST_INTERVAL: 6.0",
  "  :DRILL_REPEATS_SINCE_FAIL: 3",
  "  :DRILL_TOTAL_REPEATS: 2",
  "  :DRILL_FAILURE_COUNT: 0",
  "  :DRILL_AVERAGE_QUALITY: 4.0",
  "  :DRILL_EASE: 2.5",
  "  :END:",
  "  cold",
}

describe("drill sessions (org-drill parity)", function()
  local drill = require("org.extensions.drill")
  local real_random, real_seconds, notify
  local T = os.time({ year = 2026, month = 9, day = 29, hour = 10, min = 30, sec = 0 })
  local matrix_file
  before_each(function()
    freeze()
    matrix_file = vim.fn.tempname() .. ".json"
    setup({ shuffle = false, save_buffers = false, algorithm = "sm2", sm5_matrix_file = matrix_file })
    real_random, real_seconds = drill.random, drill.now_seconds
    drill.random = function()
      return 1
    end
    drill.now_seconds = function()
      return T
    end
    notify = vim.notify
    vim.notify = function() end
  end)
  after_each(function()
    vim.notify = notify
    local s = drill.session
    if s and s.win and vim.api.nvim_win_is_valid(s.win) then
      vim.api.nvim_win_close(s.win, true)
    end
    drill.session = nil
    drill.random, drill.now_seconds = real_random, real_seconds
    thaw()
    vim.fn.delete(matrix_file)
    setup(nil)
  end)

  local function titles(list)
    return vim.tbl_map(function(c)
      return c.card.title
    end, list)
  end

  it("orders failed, overdue, young, then old and new cards (org-drill-pop-next-pending-entry)", function()
    org_buffer({
      "* New :drill:",
      "  n",
      "* Old :drill:",
      "  SCHEDULED: <2026-09-29 Tue>",
      "  :PROPERTIES:",
      "  :DRILL_LAST_INTERVAL: 30.0",
      "  :DRILL_LAST_QUALITY: 4",
      "  :END:",
      "  o",
      "* Young :drill:",
      "  SCHEDULED: <2026-09-29 Tue>",
      "  :PROPERTIES:",
      "  :DRILL_LAST_INTERVAL: 6.0",
      "  :DRILL_LAST_QUALITY: 4",
      "  :END:",
      "  y",
      "* Overdue :drill:",
      "  SCHEDULED: <2026-09-20 Sun>",
      "  :PROPERTIES:",
      "  :DRILL_LAST_INTERVAL: 6.0",
      "  :DRILL_LAST_QUALITY: 5",
      "  :END:",
      "  late",
      "* Very overdue :drill:",
      "  SCHEDULED: <2026-09-01 Tue>",
      "  :PROPERTIES:",
      "  :DRILL_LAST_INTERVAL: 6.0",
      "  :END:",
      "  later",
      "* Failed :drill:",
      "  :PROPERTIES:",
      "  :DRILL_LAST_INTERVAL: 0.0",
      "  :DRILL_LAST_QUALITY: 1",
      "  :END:",
      "  f",
      "* Future :drill:",
      "  SCHEDULED: <2026-10-20 Tue>",
      "  later",
    }, { 1, 0 })
    local today = date.today():days()
    eq({ "Failed", "Very overdue", "Overdue", "Young", "Old", "New" }, titles(drill.due_cards("file", today)))
  end)

  it("skips empty simple cards and unknown card types (org-drill-entry-status)", function()
    org_buffer({
      "* Only an answer :drill:",
      "** Answer",
      "   x",
      "* Unknown :drill:",
      "  :PROPERTIES:",
      "  :DRILL_CARD_TYPE: nonsense",
      "  :END:",
      "  text",
      "* Sides :drill:",
      "  :PROPERTIES:",
      "  :DRILL_CARD_TYPE: twosided",
      "  :END:",
      "** A",
      "   a",
      "** B",
      "   b",
    }, { 1, 0 })
    eq({ "Sides" }, titles(drill.due_cards("file", date.today():days())))
  end)

  local LEECH = {
    "* Hard :drill:",
    "  SCHEDULED: <2026-09-28 Mon>",
    "  :PROPERTIES:",
    "  :DRILL_LAST_INTERVAL: 1.0",
    "  :DRILL_REPEATS_SINCE_FAIL: 2",
    "  :DRILL_TOTAL_REPEATS: 30",
    "  :DRILL_FAILURE_COUNT: 15",
    "  :DRILL_AVERAGE_QUALITY: 2.0",
    "  :DRILL_EASE: 1.3",
    "  :END:",
    "  question",
  }

  it("tags a card failed more than org-drill-leech-failure-threshold times :leech:", function()
    require("org.config").opts.extensions.drill.repeat_failed = false
    local buf = org_buffer(LEECH, { 1, 0 })
    drill.start("file")
    drill.reveal()
    drill.grade(1)
    local l1 = buf_lines(buf)[1]
    ok(l1:match(":drill:leech:$"), l1)
    ok(table.concat(buf_lines(buf), "\n"):find(":DRILL_FAILURE_COUNT: 16", 1, true))
  end)

  it("leaves leeches out with org-drill-leech-method skip, asks them with warn", function()
    local lines = vim.deepcopy(LEECH)
    lines[1] = "* Hard :drill:leech:"
    org_buffer(lines, { 1, 0 })
    eq({}, drill.due_cards("file", date.today():days()))
    require("org.config").opts.extensions.drill.leech_method = "warn"
    local s = drill.start("file")
    ok(s)
    ok(table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), "\n"):find("leech", 1, true))
  end)

  it("crams cards not reviewed in org-drill-cram-hours and writes nothing", function()
    local lines = {
      "* Recent :drill:",
      "  SCHEDULED: <2026-10-20 Tue>",
      "  :PROPERTIES:",
      "  :DRILL_LAST_REVIEWED: [2026-09-29 Tue 08:00]",
      "  :END:",
      "  r",
      "* Earlier :drill:",
      "  SCHEDULED: <2026-10-20 Tue>",
      "  :PROPERTIES:",
      "  :DRILL_LAST_REVIEWED: [2026-09-28 Mon 20:00]",
      "  :END:",
      "  e",
    }
    local buf = org_buffer(lines, { 1, 0 })
    eq({ "Earlier" }, titles(drill.due_cards("file", date.today():days(), true)))
    local s = drill.cram("file")
    ok(s.cram)
    drill.reveal()
    drill.grade(1)
    drill.reveal()
    drill.grade(4)
    ok(s.finished)
    eq(lines, buf_lines(buf))
  end)

  it("asks failed cards again after org-drill-maximum-duration", function()
    require("org.config").opts.extensions.drill.maximum_duration = 1
    org_buffer(DECK, { 1, 0 })
    local t = T
    drill.now_seconds = function()
      return t
    end
    local s = drill.start("file")
    eq("Opposite of hot", s.queue[s.index].card.title)
    t = t + 61
    drill.reveal()
    drill.grade(1)
    ok(not s.finished)
    eq("Opposite of hot", s.queue[s.index].card.title)
    drill.reveal()
    drill.grade(4)
    ok(s.finished)
    eq(2, s.stats.reviewed)
  end)

  it("writes the drawer and planning at the indentation of the card text", function()
    local buf = org_buffer({ "* Q :drill:", "  question", "** A", "   answer" }, { 1, 0 })
    drill.start("file")
    drill.reveal()
    drill.grade(4)
    local lines = buf_lines(buf)
    eq("  SCHEDULED: <2026-09-30 Wed>", lines[2])
    eq("  :PROPERTIES:", lines[3])
    eq("  :DRILL_LAST_INTERVAL: 1.0", lines[4])
    eq("  :END:", lines[12])
    eq("  question", lines[13])
  end)

  it("keeps the folds of the card's buffer, like org-save-outline-visibility", function()
    local path = vim.fn.tempname() .. ".org"
    vim.fn.writefile({
      "#+STARTUP: content",
      "* Card 1 :drill:",
      "  Question 1",
      "** Answer",
      "   answer 1",
      "* Card 2 :drill:",
      "  Question 2",
      "** Answer",
      "   answer 2",
    }, path)
    vim.cmd("edit! " .. vim.fn.fnameescape(path))
    local win = vim.api.nvim_get_current_win()
    local function closed(l)
      return vim.api.nvim_win_call(win, function()
        return vim.fn.foldclosed(l)
      end)
    end
    eq(4, closed(4)) -- ** Answer of card 1
    drill.start("file")
    drill.reveal()
    drill.grade(4)
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    eq("  SCHEDULED: <2026-09-30 Wed>", lines[3])
    eq(-1, closed(2)) -- the card stays open
    eq(4, closed(4)) -- its new drawer is folded
    local answer = vim.fn.index(lines, "** Answer") + 1
    eq(answer, closed(answer)) -- and its answer still is
    drill.quit()
    drill.quit()
    vim.cmd("bwipeout!")
    vim.fn.delete(path)
  end)

  it("keeps other properties and planning, and deletes LEARN_DATA", function()
    local buf = org_buffer({
      "* Q :drill:",
      "DEADLINE: <2026-12-01 Tue>",
      ":PROPERTIES:",
      ":ID:       abc",
      ":LEARN_DATA: (6.0 3 2.5)",
      ":END:",
      "question",
    }, { 1, 0 })
    drill.start("file")
    drill.reveal()
    drill.grade(4)
    local lines = buf_lines(buf)
    eq("DEADLINE: <2026-12-01 Tue> SCHEDULED: <2026-10-14 Wed>", lines[2])
    eq(":ID:       abc", lines[4])
    ok(not table.concat(lines, "\n"):find("LEARN_DATA", 1, true))
  end)

  it("keeps the SM-5 matrix of optimal factors in sm5_matrix_file", function()
    require("org.config").opts.extensions.drill.algorithm = "sm5"
    drill.reset_matrix()
    local buf = org_buffer({ "* Q :drill:", "  question" }, { 1, 0 })
    drill.start("file")
    drill.reveal()
    drill.grade(5)
    local m = vim.json.decode(table.concat(vim.fn.readfile(matrix_file), "\n"))
    close_to(4.14, m["1"][schedule.ef_key(2.6)])
    -- 4.14 days, rounded
    ok(table.concat(buf_lines(buf), "\n"):find("SCHEDULED: <2026-10-03 Sat>", 1, true))
  end)

  it("completes the scope of :Org drill", function()
    local c = require("org.commands").complete("", "Org drill ")
    ok(vim.tbl_contains(c, "agenda"))
    ok(vim.tbl_contains(c, "tag:"))
    eq({ "tree" }, require("org.commands").complete("tr", "Org drill_cram tr"))
  end)

  it("writes cards org-lint (and the lsp extension's diagnostics) has nothing to say about", function()
    local buf = org_buffer(
      { "* Q :drill:", "  The capital of [France||country] is [Paris].", "** A", "   x" },
      { 1, 0 }
    )
    drill.start("file")
    drill.reveal()
    drill.grade(1)
    drill.quit()
    eq({}, require("org.lint").lint(buf, require("org.lint").checker_names()))
  end)
end)

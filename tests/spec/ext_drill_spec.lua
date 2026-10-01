local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local date = require("org.date")
local sm2 = require("org.extensions.drill.sm2")
local cloze = require("org.extensions.drill.cloze")
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
  if saved.today then
    date.today, date.now, date.today_days = saved.today, saved.now, saved.today_days
  end
end

local function prop(lines, name)
  for _, l in ipairs(lines) do
    local v = l:match("^%s*:" .. name .. ":%s*(.-)%s*$")
    if v then
      return v
    end
  end
end

describe("drill sm2", function()
  it("changes the ease by SM-2's formula", function()
    close_to(2.6, sm2.modify_ease(2.5, 5))
    close_to(2.5, sm2.modify_ease(2.5, 4))
    close_to(2.36, sm2.modify_ease(2.5, 3))
    close_to(2.18, sm2.modify_ease(2.5, 2))
    close_to(1.96, sm2.modify_ease(2.5, 1))
    close_to(1.7, sm2.modify_ease(2.5, 0))
    eq(1.3, sm2.modify_ease(1.2, 5))
  end)

  it("schedules 1, 6, then interval * ease", function()
    local d = { last_interval = 0, repeats = 0, failures = 0, total_repeats = 0 }
    local n1, f1 = sm2.next(d, 4)
    eq(false, f1)
    eq(1, n1.last_interval)
    eq(2, n1.repeats)
    close_to(2.5, n1.ease)
    eq(1, n1.total_repeats)
    local n2 = sm2.next(n1, 4)
    eq(6, n2.last_interval)
    eq(3, n2.repeats)
    local n3 = sm2.next(n2, 4)
    close_to(15, n3.last_interval)
    eq(4, n3.repeats)
    local n4 = sm2.next(n3, 5)
    close_to(15 * 2.6, n4.last_interval)
    close_to(2.6, n4.ease)
  end)

  it("uses the new ease for the interval", function()
    local d = { last_interval = 10, repeats = 3, failures = 0, total_repeats = 5, ease = 2.5, meanq = 4 }
    local n = sm2.next(d, 3)
    close_to(23.6, n.last_interval)
    close_to(2.36, n.ease)
  end)

  it("resets the repetitions on a failure but keeps the ease", function()
    local d = { last_interval = 15, repeats = 4, failures = 1, total_repeats = 6, ease = 2.2, meanq = 4 }
    local n, failed = sm2.next(d, 2)
    eq(true, failed)
    eq(0, n.last_interval)
    eq(1, n.repeats)
    eq(2, n.failures)
    eq(7, n.total_repeats)
    close_to(2.2, n.ease)
    -- after a failure the item starts over at 1 day
    local again = sm2.next(n, 4)
    eq(1, again.last_interval)
    eq(2, again.repeats)
  end)

  it("fails at or below failure_quality", function()
    local d = { last_interval = 0, repeats = 0, failures = 0, total_repeats = 0 }
    eq(true, select(2, sm2.next(d, 0)))
    eq(true, select(2, sm2.next(d, 2)))
    eq(false, select(2, sm2.next(d, 3)))
    eq(true, select(2, sm2.next(d, 3, 3)))
  end)

  it("keeps a running average quality", function()
    local d = { last_interval = 0, repeats = 0, failures = 0, total_repeats = 0 }
    local n = sm2.next(d, 5)
    eq(5, n.meanq)
    n = sm2.next(n, 3)
    eq(4, n.meanq)
    n = sm2.next(n, 1)
    close_to(3, n.meanq)
  end)

  it("rejects qualities outside 0-5", function()
    eq(false, pcall(sm2.next, {}, 6))
    eq(false, pcall(sm2.next, {}, -1))
  end)

  it("formats floats like number-to-string", function()
    eq("6.0", sm2.float_string(6, 4))
    eq("2.36", sm2.float_string(2.36, 3))
    eq("2.36", sm2.float_string(2.3599999, 3))
    eq("15.0", sm2.float_string(15.00001, 4))
    eq("23.6", sm2.float_string(23.6, 4))
    eq("3.333", sm2.float_string(10 / 3, 3))
    eq("0.0", sm2.float_string(0, 4))
    eq("-1.0", sm2.float_string(-1, 4))
  end)

  it("rounds intervals to whole days", function()
    eq(0, sm2.days_ahead(0))
    eq(0, sm2.days_ahead(-1))
    eq(1, sm2.days_ahead(1))
    eq(15, sm2.days_ahead(15.4))
    eq(16, sm2.days_ahead(15.5))
  end)
end)

describe("drill cloze", function()
  it("finds clozes with and without hints", function()
    eq({ { s = 16, e = 22, text = "Paris" } }, cloze.parse("The capital is [Paris]."))
    eq({ { s = 1, e = 16, text = "Paris", hint = "capital" } }, cloze.parse("[Paris||capital] is nice"))
    local cs = cloze.parse("[a] and [b||x] and [c]")
    eq(3, #cs)
    eq({ "a", "b", "c" }, { cs[1].text, cs[2].text, cs[3].text })
    eq("x", cs[2].hint)
  end)

  it("keeps an empty hint as no hint", function()
    eq({ { s = 1, e = 9, text = "Paris" } }, cloze.parse("[Paris||]"))
  end)

  it("ignores other bracketed syntax", function()
    eq({}, cloze.parse("see [[https://example.com][a link]] here"))
    eq({}, cloze.parse("- [ ] a checkbox"))
    eq({}, cloze.parse("- [X] done"))
    eq({}, cloze.parse("- [-] partly"))
    eq({}, cloze.parse("* Project [1/3] [50%]"))
    eq({}, cloze.parse("on [2026-09-29 Tue]"))
    eq({}, cloze.parse("a footnote[fn:1]"))
    eq({}, cloze.parse("prio [#A]"))
    eq({}, cloze.parse("[ spaced ]"))
    eq({}, cloze.parse("unclosed [bracket"))
    eq({}, cloze.parse("an escaped \\[bracket]"))
  end)

  it("finds a cloze after a link", function()
    local cs = cloze.parse("[[x][y]] is [z]")
    eq(1, #cs)
    eq("z", cs[1].text)
  end)

  it("shows hidden text with the hint", function()
    eq("[...]", cloze.hidden_text({ text = "a" }))
    eq("[city...]", cloze.hidden_text({ text = "a", hint = "city" }))
  end)

  it("tells whether lines hold clozes", function()
    eq(true, cloze.has_any({ "no", "yes [y]" }))
    eq(false, cloze.has_any({ "no", "- [ ] box" }))
  end)
end)

local function read(lines, n)
  local f = parser.parse(lines, "/tmp/drill-test.org")
  return card.read(f, f.headlines[n or 1])
end

describe("drill cards", function()
  it("reads a simple card with an answer subheading", function()
    local c = read({
      "* Capital of France :drill:",
      "  :PROPERTIES:",
      "  :DRILL_EASE: 2.36",
      "  :DRILL_TOTAL_REPEATS: 3",
      "  :END:",
      "  What is the capital of France?",
      "** Answer",
      "   Paris",
    })
    eq("simple", c.type)
    eq({ "What is the capital of France?" }, c.body)
    eq(1, #c.sides)
    eq("Answer", c.sides[1].title)
    eq({ "Paris" }, c.sides[1].lines)
    close_to(2.36, c.data.ease)
    eq(3, c.data.total_repeats)
    eq(false, c.new)
    local q = card.render(c, {}, false)
    eq({ "Capital of France", "", "What is the capital of France?" }, q.lines)
    local a = card.render(c, {}, true)
    ok(vim.tbl_contains(a.lines, "── Answer ──"))
    ok(vim.tbl_contains(a.lines, "Answer"))
    ok(vim.tbl_contains(a.lines, "  Paris"))
  end)

  it("uses the body as the answer when there are no subheadings", function()
    local c = read({ "* Opposite of hot :drill:", "  SCHEDULED: <2026-09-20 Sun>", "  cold" })
    eq({ "cold" }, c.body)
    eq(true, c.new)
    eq(2026, c.scheduled.year)
    local q = card.render(c, {}, false)
    eq({ "Opposite of hot", "" }, q.lines)
    local a = card.render(c, {}, true)
    eq("cold", a.lines[#a.lines])
  end)

  it("hides every cloze of a simple card", function()
    local c = read({ "* Geography :drill:", "  The capital of [France||country] is [Paris]." })
    eq(2, c.nclozes)
    local q = card.render(c, {}, false)
    eq("The capital of [country...] is [...].", q.lines[3])
    local hidden = vim.tbl_filter(function(h)
      return h[4] == "OrgDrillHidden"
    end, q.hls)
    eq(2, #hidden)
    eq({ 2, 15, 27, "OrgDrillHidden" }, hidden[1])
    local a = card.render(c, {}, true)
    eq("The capital of France is Paris.", a.lines[3])
    local shown = vim.tbl_filter(function(h)
      return h[4] == "OrgDrillCloze"
    end, a.hls)
    eq({ 2, 15, 21, "OrgDrillCloze" }, shown[1])
  end)

  it("hides one cloze of a hide1cloze card", function()
    local c = read({
      "* Dates :drill:",
      "  :PROPERTIES:",
      "  :DRILL_CARD_TYPE: hide1cloze",
      "  :END:",
      "  [1066] Hastings, [1415] Agincourt",
    })
    eq("hide1cloze", c.type)
    -- the shuffle of { 1, 2 } with random() = 1 swaps them: 2 comes first
    local choice = card.choose(c, function()
      return 1
    end)
    eq({ hidden = { [2] = true } }, choice)
    eq("1066 Hastings, [...] Agincourt", card.render(c, choice, false).lines[3])
  end)

  it("shows one cloze of a show1cloze card", function()
    local c = read({
      "* Dates :drill:",
      "  :PROPERTIES:",
      "  :DRILL_CARD_TYPE: show1cloze",
      "  :END:",
      "  [a] [b] [c]",
    })
    -- shuffled positions { 1, 2, 3 } -> 3, 2, 1: two hidden, "a" shown
    local calls = { 1, 2 }
    local choice = card.choose(c, function()
      return table.remove(calls, 1)
    end)
    eq({ [2] = true, [3] = true }, choice.hidden)
    eq("a [...] [...]", card.render(c, choice, false).lines[3])
  end)

  it("hides two clozes of a hide2cloze card", function()
    local c = read({
      "* Dates :drill:",
      "  :PROPERTIES:",
      "  :DRILL_CARD_TYPE: hide2cloze",
      "  :END:",
      "  [a] [b] [c]",
    })
    -- the shuffle keeps { 1, 2, 3 } (random(i) = i): the first two are hidden
    local choice = card.choose(c, function(m)
      return m
    end)
    eq({ [1] = true, [2] = true }, choice.hidden)
    eq("[...] [...] c", card.render(c, choice, false).lines[3])
  end)

  it("shows one side of a twosided card", function()
    local c = read({
      "* Word :drill:",
      "  :PROPERTIES:",
      "  :DRILL_CARD_TYPE: twosided",
      "  :END:",
      "  Translate.",
      "** English",
      "   dog",
      "** Spanish",
      "   perro",
      "** Notes",
      "   a noun",
    })
    eq(3, #c.sides)
    local choice = card.choose(c, function(m)
      eq(2, m) -- only the first two sides are questions
      return 2
    end)
    local q = card.render(c, choice, false)
    ok(vim.tbl_contains(q.lines, "Spanish"))
    ok(vim.tbl_contains(q.lines, "  perro"))
    ok(not vim.tbl_contains(q.lines, "  dog"))
    local a = card.render(c, choice, true)
    ok(vim.tbl_contains(a.lines, "  dog"))
    ok(vim.tbl_contains(a.lines, "  a noun"))
  end)

  it("picks any side of a multisided card", function()
    local c = read({
      "* Word :drill:",
      "  :PROPERTIES:",
      "  :DRILL_CARD_TYPE: multisided",
      "  :END:",
      "** A",
      "** B",
      "** C",
    })
    local choice = card.choose(c, function(m)
      eq(3, m)
      return 3
    end)
    eq(3, choice.side)
  end)

  it("treats an unknown card type as simple", function()
    eq("simple", read({ "* X :drill:", "  :PROPERTIES:", "  :DRILL_CARD_TYPE: spanish_verb", "  :END:", "  y" }).type)
  end)

  it("leaves drawers and planning out of the text", function()
    local c = read({
      "* Q :drill:",
      "  SCHEDULED: <2026-09-20 Sun>",
      "  :LOGBOOK:",
      "  - note",
      "  :END:",
      "  question",
      "** Answer",
      "   :PROPERTIES:",
      "   :ID: x",
      "   :END:",
      "   answer",
      "*** Deeper",
      "    more",
    })
    eq({ "question" }, c.body)
    eq({ "answer", { heading = "Deeper", level = 3 }, " more" }, c.sides[1].lines)
    local a = card.render(c, {}, true)
    ok(vim.tbl_contains(a.lines, "  ▸ Deeper"))
  end)

  it("knows empty and due cards", function()
    eq(true, card.is_empty(read({ "* Nothing :drill:" })))
    -- org-drill-entry-empty-p: only the entry's own text counts
    eq(true, card.is_empty(read({ "* Q :drill:", "** A" })))
    eq(false, card.is_empty(read({ "* Q :drill:", "  q", "** A" })))
    -- two- and multisided cards are asked without text (DRILL-EMPTY-P)
    eq(
      false,
      card.is_empty(read({ "* Q :drill:", "  :PROPERTIES:", "  :DRILL_CARD_TYPE: twosided", "  :END:", "** A" }))
    )
    local today = date.days_from_civil(2026, 9, 29)
    eq(true, card.is_due(read({ "* Q :drill:", "  x" }), today))
    eq(true, card.is_due(read({ "* Q :drill:", "  SCHEDULED: <2026-09-29 Tue>", "  x" }), today))
    eq(false, card.is_due(read({ "* Q :drill:", "  SCHEDULED: <2026-09-30 Wed>", "  x" }), today))
  end)
end)

describe("drill extension", function()
  it("is inert when off", function()
    setup(nil)
    eq(nil, require("org.actions").list.drill)
    eq(nil, require("org.commands").extra.drill)
    eq("", vim.fn.maparg("<leader>oD", "n"))
  end)

  it("registers actions, the command and a key when on", function()
    setup({})
    ok(require("org.actions").list.drill)
    ok(require("org.actions").list.drill_resume)
    ok(require("org.commands").extra.drill)
    ok(vim.fn.maparg("<leader>oD", "n") ~= "")
    eq("drill", require("org.config").opts.extensions.drill.tag)
    setup(nil)
    eq(nil, require("org.actions").list.drill)
  end)
end)

local DECK = {
  "#+TITLE: Deck",
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
  "* Not due :drill:",
  "  SCHEDULED: <2026-10-10 Sat>",
  "  later",
  "* Not a card",
  "  text",
  "* Empty :drill:",
}

describe("drill session", function()
  local drill = require("org.extensions.drill")
  local real_random, real_seconds
  before_each(function()
    freeze()
    setup({ shuffle = false, save_buffers = false, algorithm = "sm2" })
    real_random, real_seconds = drill.random, drill.now_seconds
    drill.random = function()
      return 1
    end
    local t = 1000
    drill.now_seconds = function()
      return t
    end
  end)
  after_each(function()
    local s = drill.session
    if s and s.win and vim.api.nvim_win_is_valid(s.win) then
      vim.api.nvim_win_close(s.win, true)
    end
    drill.session = nil
    drill.random, drill.now_seconds = real_random, real_seconds
    thaw()
    setup(nil)
  end)

  local function win_text()
    return table.concat(vim.api.nvim_buf_get_lines(drill.session.buf, 0, -1, false), "\n")
  end

  it("collects due cards: overdue first, then new, without empty cards", function()
    org_buffer(DECK, { 1, 0 })
    local cards = drill.due_cards("file", date.today():days())
    eq({ "Opposite of hot", "Capital of France" }, {
      cards[1].card.title,
      cards[2].card.title,
    })
    eq(4, #drill.cards("file"))
  end)

  it("limits the cards per session", function()
    require("org.config").opts.extensions.drill.maximum_items_per_session = 1
    org_buffer(DECK, { 1, 0 })
    eq(1, #drill.due_cards("file", date.today():days()))
  end)

  it("restricts the tree scope to the subtree at the cursor", function()
    org_buffer(DECK, { 3, 0 })
    local cards = drill.cards("tree")
    eq(1, #cards)
    eq("Capital of France", cards[1].card.title)
  end)

  it("filters by an extra tag", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "* A :drill:spanish:", "  x", "* B :drill:", "  y" }, dir .. "/deck.org")
    require("org.config").opts.agenda_files = { dir .. "/deck.org" }
    local cards = drill.cards("tag:spanish")
    eq(1, #cards)
    eq("A", cards[1].card.title)
    eq(2, #drill.cards(dir .. "/*.org"))
    vim.fn.delete(dir, "rf")
  end)

  it("reviews cards in a float and writes the schedule", function()
    local buf = org_buffer(DECK, { 1, 0 })
    local s = drill.start("file")
    ok(s)
    ok(vim.api.nvim_win_is_valid(s.win))
    eq(2, #s.queue)
    local text = win_text()
    ok(text:find("Opposite of hot", 1, true))
    ok(not text:find("cold", 1, true), "answer hidden")
    drill.reveal()
    ok(win_text():find("cold", 1, true))
    drill.grade(4)
    -- the second card: new
    ok(win_text():find("Capital of France", 1, true))
    ok(not win_text():find("Paris", 1, true))
    drill.grade(5) -- the first grade key shows the answer
    ok(win_text():find("Paris", 1, true))
    drill.grade(5)
    ok(s.finished)
    ok(win_text():find("Passed", 1, true))
    ok(win_text():find("Reviewed   2 cards", 1, true))
    ok(win_text():find("Passed     2", 1, true))

    local lines = buf_lines(buf)
    local f = require("org.files").get_buffer(buf)
    local hot = f:find_by_title("Opposite of hot")
    -- repeats 3: 6.0 * 2.5 = 15 days
    eq("2026-10-14", hot.planning.scheduled:to_date_string())
    local sect = vim.list_slice(lines, hot.line, hot.end_line)
    eq("15.0", prop(sect, "DRILL_LAST_INTERVAL"))
    eq("4", prop(sect, "DRILL_REPEATS_SINCE_FAIL"))
    eq("3", prop(sect, "DRILL_TOTAL_REPEATS"))
    eq("0", prop(sect, "DRILL_FAILURE_COUNT"))
    eq("4.0", prop(sect, "DRILL_AVERAGE_QUALITY"))
    eq("2.5", prop(sect, "DRILL_EASE"))
    eq("4", prop(sect, "DRILL_LAST_QUALITY"))
    eq("[2026-09-29 Tue 10:30]", prop(sect, "DRILL_LAST_REVIEWED"))

    local cap = f:find_by_title("Capital of France")
    eq("2026-09-30", cap.planning.scheduled:to_date_string())
    local csect = vim.list_slice(lines, cap.line, cap.end_line)
    eq("1.0", prop(csect, "DRILL_LAST_INTERVAL"))
    eq("2", prop(csect, "DRILL_REPEATS_SINCE_FAIL"))
    eq("2.6", prop(csect, "DRILL_EASE"))
    eq("5.0", prop(csect, "DRILL_AVERAGE_QUALITY"))
    -- the answer subheading stays below the card's drawer
    eq("** Answer", lines[cap.end_line - 1])

    drill.quit()
    eq(nil, s.win)
  end)

  it("asks failed cards again at the end", function()
    local buf = org_buffer(DECK, { 1, 0 })
    local s = drill.start("file")
    drill.reveal()
    drill.grade(1) -- Opposite of hot fails
    drill.reveal()
    drill.grade(4) -- Capital of France
    ok(not s.finished)
    ok(win_text():find("Opposite of hot", 1, true))
    ok(win_text():find("again", 1, true))
    drill.reveal()
    drill.grade(3)
    ok(s.finished)
    eq(3, s.stats.reviewed)
    eq(1, s.stats.failed)
    eq(2, s.stats.passed)
    eq(1, s.stats.new)
    ok(win_text():find("Reviewed   2 cards, 3 answers", 1, true))
    local f = require("org.files").get_buffer(buf)
    local hot = f:find_by_title("Opposite of hot")
    local sect = vim.list_slice(f.lines, hot.line, hot.end_line)
    eq("1", prop(sect, "DRILL_FAILURE_COUNT"))
    eq("4", prop(sect, "DRILL_TOTAL_REPEATS"))
    -- failed (repeats 1), then passed: 1 day
    eq("2", prop(sect, "DRILL_REPEATS_SINCE_FAIL"))
    eq("2026-09-30", hot.planning.scheduled:to_date_string())
  end)

  it("unschedules a failed card, like org-drill-smart-reschedule with 0 days ahead", function()
    require("org.config").opts.extensions.drill.repeat_failed = false
    local buf = org_buffer(DECK, { 1, 0 })
    drill.start("file")
    drill.reveal()
    drill.grade(0)
    local f = require("org.files").get_buffer(buf)
    local hot = f:find_by_title("Opposite of hot")
    eq(nil, hot.planning.scheduled)
    local sect = vim.list_slice(f.lines, hot.line, hot.end_line)
    eq("0.0", prop(sect, "DRILL_LAST_INTERVAL"))
    eq("1", prop(sect, "DRILL_REPEATS_SINCE_FAIL"))
    eq("0", prop(sect, "DRILL_LAST_QUALITY"))
  end)

  it("skips cards and quits with a summary", function()
    org_buffer(DECK, { 1, 0 })
    local s = drill.start("file")
    drill.skip()
    drill.quit()
    ok(s.finished)
    eq(1, s.stats.skipped)
    ok(win_text():find("Skipped    1", 1, true))
    ok(win_text():find("Still due  1", 1, true))
    drill.quit()
    eq(nil, s.win)
  end)

  it("ends after maximum_duration", function()
    require("org.config").opts.extensions.drill.maximum_duration = 1
    org_buffer(DECK, { 1, 0 })
    local t = 1000
    drill.now_seconds = function()
      return t
    end
    local s = drill.start("file")
    t = t + 61
    drill.reveal()
    drill.grade(4)
    ok(s.finished)
    eq(1, s.stats.reviewed)
  end)

  it("edits a card and resumes the session", function()
    local buf = org_buffer(DECK, { 1, 0 })
    local s = drill.start("file")
    local notify = vim.notify
    vim.notify = function() end
    drill.edit()
    vim.notify = notify
    eq(nil, s.win)
    eq(buf, vim.api.nvim_get_current_buf())
    eq(6, vim.api.nvim_win_get_cursor(0)[1])
    -- a line added above moves the card
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "* New heading" })
    vim.api.nvim_buf_set_lines(buf, 17, 17, false, { "  (edited)" })
    drill.resume()
    ok(vim.api.nvim_win_is_valid(s.win))
    ok(win_text():find("Opposite of hot", 1, true))
    drill.reveal()
    ok(win_text():find("(edited)", 1, true))
    drill.grade(4)
    local f = require("org.files").get_buffer(buf)
    local hot = f:find_by_title("Opposite of hot")
    eq(7, hot.line)
    eq("2026-10-14", hot.planning.scheduled:to_date_string())
  end)

  it("runs from its keys in the float", function()
    org_buffer(DECK, { 1, 0 })
    local s = drill.start("file")
    eq(s.buf, vim.api.nvim_get_current_buf())
    vim.api.nvim_feedkeys(" ", "x", false)
    ok(s.revealed)
    vim.api.nvim_feedkeys("4", "x", false)
    eq(1, s.stats.reviewed)
    vim.api.nvim_feedkeys("s", "x", false)
    ok(s.finished)
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
    eq(nil, s.win)
  end)

  it("says so when nothing is due", function()
    org_buffer({ "* Not due :drill:", "  SCHEDULED: <2026-10-10 Sat>", "  x" }, { 1, 0 })
    local msgs = {}
    local notify = vim.notify
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    local s = drill.start("file")
    vim.notify = notify
    eq(nil, s)
    eq("No drill cards are due", msgs[1])
  end)

  it("counts cards", function()
    org_buffer(DECK, { 1, 0 })
    local notify = vim.notify
    vim.notify = function() end
    local st = drill.stats("file")
    vim.notify = notify
    eq({ total = 4, due = 1, new = 3, failing = 0 }, st)
  end)

  it("counts the cards of the session's file from the session window", function()
    org_buffer(DECK, { 1, 0 })
    local s = drill.start("file")
    eq(s.buf, vim.api.nvim_get_current_buf())
    local notify = vim.notify
    vim.notify = function() end
    local st = drill.stats("file")
    vim.notify = notify
    eq(4, st.total)
  end)

  it("saves named files when the session ends", function()
    require("org.config").opts.extensions.drill.save_buffers = true
    local path = vim.fn.tempname() .. ".org"
    vim.fn.writefile({ "* Q :drill:", "  question", "** A", "   answer" }, path)
    vim.cmd("edit! " .. vim.fn.fnameescape(path))
    drill.start("file")
    drill.reveal()
    drill.grade(5)
    ok(drill.session.finished)
    local disk = vim.fn.readfile(path)
    eq(8, #vim.tbl_filter(function(l)
      return l:find(":DRILL_", 1, true) ~= nil
    end, disk))
    ok(table.concat(disk, "\n"):find("SCHEDULED: <2026%-09%-30 Wed>"))
    vim.cmd("bwipeout!")
    vim.fn.delete(path)
  end)
end)

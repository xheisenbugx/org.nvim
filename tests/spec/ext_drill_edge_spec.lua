-- Edge cases of the drill extension: damaged DRILL_* properties, odd
-- cloze syntax, cards with no clozes for cloze types, and random answer
-- sequences and documents (seeds from tests/helpers/fuzz.lua).
local fuzz = require("tests.helpers.fuzz")
local card = require("org.extensions.drill.card")
local cloze = require("org.extensions.drill.cloze")
local schedule = require("org.extensions.drill.schedule")
local sm2 = require("org.extensions.drill.sm2")
local parser = require("org.parser")

local function read(lines, n)
  local f = parser.parse(lines, "/tmp/drill-edge.org")
  return card.read(f, f.headlines[n or 1])
end

local function finite(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

describe("drill edge cases", function()
  it("reads damaged DRILL_* properties as missing", function()
    local c = read({
      "* Card :drill:",
      "  :PROPERTIES:",
      "  :DRILL_EASE: two point five",
      "  :DRILL_LAST_INTERVAL:",
      "  :DRILL_TOTAL_REPEATS: many",
      "  :DRILL_FAILURE_COUNT: -",
      "  :DRILL_LAST_REVIEWED: not a date",
      "  :END:",
      "  Question",
    })
    eq(nil, c.data.ease)
    eq(0, c.data.last_interval)
    eq(0, c.data.total_repeats)
    eq(0, c.data.failures)
    eq(nil, c.last_reviewed)
    -- and it can be answered
    local d, days = schedule.answer("sm2", c.data, 4, nil, {})
    ok(finite(d.ease))
    eq(1, days)
  end)

  it("reads a short or garbled LEARN_DATA", function()
    local c = read({ "* Card :drill:", "  :PROPERTIES:", "  :LEARN_DATA: (oops)", "  :END:", "  Q" })
    eq({ 0, 0 }, { c.data.last_interval, c.data.repeats })
    eq(nil, c.data.ease)
    c = read({ "* Card :drill:", "  :PROPERTIES:", "  :LEARN_DATA: (3.5)", "  :END:", "  Q" })
    eq(3.5, c.data.last_interval)
  end)

  it("treats a blank or oddly cased card type as simple", function()
    eq("simple", read({ "* C", "  :PROPERTIES:", "  :DRILL_CARD_TYPE:   ", "  :END:", "  Q" }).type)
    eq("hide1cloze", read({ "* C", "  :PROPERTIES:", "  :DRILL_CARD_TYPE: Hide1Cloze", "  :END:", "  [x]" }).type)
  end)

  it("finds no cloze in brackets that aren't one", function()
    for _, line in ipairs({
      "[",
      "]",
      "[]",
      "[ leading space]",
      "[unterminated",
      "a ]stray[ bracket",
      "[[link][desc]]",
      "[[unterminated link",
      "[fn:note] [#A] [50%] [1/3] [X] [-]",
      "[2026-09-29 Tue] [cite:@key]",
      "\\[escaped]",
    }) do
      eq({}, cloze.parse(line), line)
    end
  end)

  it("parses clozes with unicode, a hint only, and several on a line", function()
    local cs = cloze.parse("[Zürich||城市] and [東京] then [||only hint]")
    eq(3, #cs)
    eq({ "Zürich", "城市" }, { cs[1].text, cs[1].hint })
    eq({ "東京", nil }, { cs[2].text, cs[2].hint })
    eq("[城市...]", cloze.hidden_text(cs[1]))
    -- byte columns: the line can be cut at them
    local line = "[Zürich||城市] and [東京]"
    eq("[東京]", line:sub(cloze.parse(line)[2].s, cloze.parse(line)[2].e))
  end)

  it("asks a cloze card with no clozes like a simple one", function()
    for _, t in ipairs({ "hide1cloze", "hide2cloze", "show1cloze", "show2cloze", "hidefirst", "hidelast" }) do
      local c = read({ "* C", "  :PROPERTIES:", "  :DRILL_CARD_TYPE: " .. t, "  :END:", "  No clozes here" })
      eq(0, c.nclozes)
      local choice = card.choose(c, function(m)
        return m
      end)
      local r = card.render(c, choice, false)
      ok(vim.tbl_contains(r.lines, "No clozes here"), t)
    end
  end)

  it("hides no more clozes than there are", function()
    local function first(m)
      return 1
    end
    eq(1, vim.tbl_count(card.hide_n(1, 2, first)))
    eq(0, vim.tbl_count(card.hide_n(0, 1, first)))
    eq(0, vim.tbl_count(card.hide_n(1, -2, first)))
    eq({}, card.hide_nth(0, 1))
  end)

  it("keeps a sidedness card with one side askable", function()
    local c = read({ "* C", "  :PROPERTIES:", "  :DRILL_CARD_TYPE: twosided", "  :END:", "** Only side", "   text" })
    eq(false, card.is_empty(c))
    local choice = card.choose(c, function(m)
      return m
    end)
    eq(1, choice.side)
  end)

  it("keeps ease, interval and counters sane over random answers", function()
    local failures = {}
    for _, seed in ipairs(fuzz.seeds(40)) do
      local rng = fuzz.rng(seed)
      for _, algo in ipairs({ "sm2", "sm5", "simple8" }) do
        local data = { last_interval = 0, repeats = 0, failures = 0, total_repeats = 0 }
        local matrix
        -- org-drill's simple8 counts only passed repetitions, and its ease
        -- (from the mean quality) has no SM-2 floor
        local total, min_ease = 0, algo == "simple8" and 0 or 1.3
        for step = 1, 30 do
          local q = rng:int(0, 5)
          if algo ~= "simple8" or q > 2 then
            total = total + 1
          end
          local okn, d, days, failed, m = pcall(schedule.answer, algo, data, q, matrix, {})
          local bad
          if not okn then
            bad = tostring(d)
          elseif not (finite(d.last_interval) and d.last_interval >= 0) then
            bad = "interval " .. tostring(d.last_interval)
          elseif not (days >= 0 and days == math.floor(days)) then
            bad = "days " .. tostring(days)
          elseif d.ease and not (finite(d.ease) and d.ease > 0 and d.ease >= min_ease - 1e-9) then
            bad = "ease " .. tostring(d.ease)
          elseif d.total_repeats ~= total then
            bad = "total_repeats " .. tostring(d.total_repeats)
          elseif failed ~= (q <= 2) then
            bad = "failed " .. tostring(failed)
          end
          if bad then
            failures[#failures + 1] = ("seed %d %s step %d q=%d: %s; replay: %s"):format(
              seed,
              algo,
              step,
              q,
              bad,
              fuzz.replay(seed)
            )
            break
          end
          data, matrix = d, m
        end
      end
    end
    eq({}, failures)
  end)

  it("reads and renders any heading of a random document", function()
    local failures = {}
    for _, seed in ipairs(fuzz.seeds(20)) do
      local rng = fuzz.rng(seed)
      local lines = fuzz.doc(rng)
      local f = parser.parse(lines, "/tmp/drill-fuzz.org")
      for _, hl in ipairs(f.headlines) do
        local okr, err = pcall(function()
          local c = card.read(f, hl)
          local choice = card.choose(c, function(m)
            return rng:int(math.max(1, m))
          end)
          card.render(c, choice, false)
          card.render(c, choice, true)
        end)
        if not okr then
          failures[#failures + 1] = ("seed %d line %d: %s; replay: %s"):format(seed, hl.line, err, fuzz.replay(seed))
          break
        end
      end
    end
    eq({}, failures)
  end)

  it("formats rounding edge cases like Emacs", function()
    eq("0.0", sm2.float_string(-0.0001, 2))
    eq("2.0", sm2.float_string(2, 2))
    eq(0, sm2.days_ahead(-5))
    eq(2, sm2.days_ahead(2.5))
    eq(4, sm2.days_ahead(3.5))
  end)
end)

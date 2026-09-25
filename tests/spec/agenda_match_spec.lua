-- Tags/property matches (org-make-tags-matcher) and search view queries
-- (org-search-view). Expected results come from Emacs Org 9.8.10 batch runs
-- (org-tags-view / org-search-view) on the same file, compared as sets of
-- headline titles.
local parser = require("org.parser")
local search = require("org.agenda.search")

local lines = {
  "#+TODO: TODO NEXT WAITING | DONE CANCELLED",
  "* TODO [#A] Alpha :work:boss:",
  "  SCHEDULED: <2026-09-20 Sun>",
  "  :PROPERTIES:",
  "  :Effort:   1:30",
  "  :With:     Sarah",
  "  :Coffee:   unlimited",
  "  :END:",
  "  body text mentions banana split",
  "** NEXT Alpha child :urgent:",
  "   :PROPERTIES:",
  "   :Effort:   0:20",
  "   :END:",
  "*** Grandchild plain",
  "* DONE Beta :work:",
  "  CLOSED: [2026-09-24 Thu 10:00] DEADLINE: <2026-10-02 Fri>",
  "  :PROPERTIES:",
  "  :Effort:   3",
  "  :With:     Denny",
  "  :END:",
  "* WAITING [#C] Gamma :home:",
  "  :PROPERTIES:",
  "  :CATEGORY: gcat",
  "  :END:",
  "  Some text with Banana",
  "  and more lines",
  "* Delta stuff <2026-09-26 Sat>",
  "  apple pie recipe",
  "** TODO Delta sub",
}
local file = parser.parse(lines, "/tmp/agenda_match.org")

local function run(pred)
  local out = {}
  for _, hl in ipairs(file.headlines) do
    if pred(hl) then
      out[#out + 1] = hl.title
    end
  end
  table.sort(out)
  return out
end

local D = "Delta stuff <2026-09-26 Sat>"
local ALL_BUT_ALPHA = { "Alpha child", "Beta", D, "Delta sub", "Gamma", "Grandchild plain" }
local NO_EFFORT_OR_LOW = { "Alpha", "Alpha child", D, "Delta sub", "Gamma", "Grandchild plain" }

local MATCHES = {
  { "Effort<*2", { "Alpha", "Alpha child" } },
  { "Effort>*1", { "Beta" } },
  { "Effort<2", NO_EFFORT_OR_LOW },
  { "Effort>60", {} },
  { "Effort=3", { "Beta" } },
  { "Effort=*0", { "Alpha child" } },
  { "Effort<>*3", { "Alpha", "Alpha child" } },
  { "Effort!=3", NO_EFFORT_OR_LOW },
  { "Effort/=*3", {} },
  { 'PRIORITY/="A"', ALL_BUT_ALPHA },
  { 'PRIORITY<>"A"', ALL_BUT_ALPHA },
  { 'PRIORITY!="B"', { "Alpha", "Gamma" } },
  { 'work+TODO="WAITING"|home+TODO="WAITING"', { "Gamma" } },
  { "LEVEL=2&urgent", { "Alpha child" } },
  { "LEVEL>=2", { "Alpha child", "Delta sub", "Grandchild plain" } },
  { "LEVEL<=1-work", { D, "Gamma" } },
  { "work:boss", { "Alpha", "Alpha child", "Grandchild plain" } },
  { "work:urgent", { "Alpha child", "Grandchild plain" } },
  { ":boss", { "Alpha", "Alpha child", "Grandchild plain" } },
  { "+{^wo}-boss", { "Beta" } },
  { "{^WO}", { "Alpha", "Alpha child", "Beta", "Grandchild plain" } },
  { "{o.s}", { "Alpha", "Alpha child", "Grandchild plain" } },
  { "{ur+}", { "Alpha child", "Grandchild plain" } },
  { "{^b\\|^h}", { "Alpha", "Alpha child", "Gamma", "Grandchild plain" } },
  { "{\\(ss\\|me\\)$}", { "Alpha", "Alpha child", "Gamma", "Grandchild plain" } },
  { "{^[[:alpha:]]+$}", { "Alpha", "Alpha child", "Beta", "Gamma", "Grandchild plain" } },
  { "{[@]}", {} },
  { 'PRIORITY>"B"', { "Gamma" } },
  { 'Coffee<"z"', { "Alpha", "Alpha child", "Beta", D, "Delta sub", "Gamma", "Grandchild plain" } },
  { 'Coffee="unlimited"', { "Alpha" } },
  { 'Coffee<>"unlimited"', ALL_BUT_ALPHA },
  { "With={^s}", { "Alpha" } },
  { "With={^S}", { "Alpha" } },
  { "With<>{^S}", ALL_BUT_ALPHA },
  { "With<*{a}", { "Alpha" } },
  { 'SCHEDULED>="<2026-09-20 12:00>"', {} },
  { 'SCHEDULED<="<2026-09-20 12:00>"', { "Alpha" } },
  -- Emacs's org-time<> tests equality (it calls `\=')
  { 'SCHEDULED<>"<2026-09-20 Sun>"', { "Alpha" } },
  { 'SCHEDULED="<2026-09-20>"', { "Alpha" } },
  { 'CLOSED<"<now>"', { "Beta" } },
  { 'TIMESTAMP>"<2026-01-01>"', { D } },
  { 'TODO<>"DONE"+work', { "Alpha", "Alpha child", "Grandchild plain" } },
  { 'urgent-TODO="DONE"', { "Alpha child", "Grandchild plain" } },
  { "work/NEXT", { "Alpha child" } },
  { "work/!-NEXT", { "Alpha" } },
  { "/!", { "Alpha", "Alpha child", "Delta sub", "Gamma" } },
  { "/-DONE", NO_EFFORT_OR_LOW },
  { "-work", { D, "Delta sub", "Gamma" } },
  -- text that does not start a term ends the match
  { "work&&boss", { "Alpha", "Alpha child", "Beta", "Grandchild plain" } },
  { "work boss", { "Alpha", "Alpha child", "Beta", "Grandchild plain" } },
  { "work -boss", { "Alpha", "Alpha child", "Beta", "Grandchild plain" } },
  { "TODO=WAITING", {} },
  { 'CATEGORY="gcat"', { "Gamma" } },
  { "CATEGORY={^g}", { "Gamma" } },
  { "ITEM={^Delta}", { D, "Delta sub" } },
  { 'ITEM="Beta"', { "Beta" } },
  { 'FOO="unterminated', {} },
  { "Effort<=1.5", NO_EFFORT_OR_LOW },
  { "Effort>=.3", { "Alpha", "Beta" } },
  { "LEVEL=2.0", { "Alpha child", "Delta sub" } },
  { "LEVEL<3e0", { "Alpha", "Alpha child", "Beta", D, "Delta sub", "Gamma" } },
}

local SEARCHES = {
  { "banana", { "Alpha", "Gamma" } },
  { "banana split", { "Alpha" } },
  { "banana   split", { "Alpha" } },
  { "+banana", { "Alpha", "Gamma" } },
  { "+banana -split", { "Gamma" } },
  { "banana +apple", {} },
  { "+{ban+a}", { "Alpha", "Gamma" } },
  { "{^apple}", {} },
  { "+Banana", { "Alpha", "Gamma" } },
  { "*Alpha", { "Alpha", "Alpha child" } },
  { "+alp", { "Alpha", "Alpha child" } },
  { "text lines", {} },
  { "Some text with Banana and more", { "Gamma" } },
  { "+text +lines", { "Gamma" } },
  { ":work:", { "Alpha", "Beta" } },
  { "Effort", { "Alpha", "Alpha child", "Beta" } },
  { "+apple +pie", { D } },
  { "apple -pie", {} },
  { "+{^  apple}", {} },
  { "+{pie$}", {} },
  { "+{e\\s-+r}", { D } },
  { "+{\\(apple\\|banana\\)} -split", { D, "Gamma" } },
  { '+"banana split"', { "Alpha" } },
  { '+"text with"', { "Gamma" } },
  { '"banana split"', {} },
  { ":+ban", {} },
  { ":+banana", { "Alpha", "Gamma" } },
  { "banana\\ split", { "Alpha" } },
  { "+{ban\\{2\\}}", {} },
  { "+{(an)}", {} },
  { "*!+alp", { "Alpha", "Alpha child" } },
  { "!alpha", { "Alpha", "Alpha child" } },
  { "*+delta -stuff", { "Delta sub" } },
  { "+{[[:upper:]]amma}", { "Gamma" } },
  { "+{a.m} +more", { "Gamma" } },
  { "+{Ban?nana}", { "Alpha", "Gamma" } },
  { "+{ban*?a}", { "Alpha", "Gamma" } },
  { "text\\ with", { "Gamma" } },
  { "+work: -boss", { "Beta" } },
  { "-boss", ALL_BUT_ALPHA },
  { "*", { "Alpha", "Alpha child", "Beta", D, "Delta sub", "Gamma", "Grandchild plain" } },
}

describe("agenda match syntax (Emacs parity)", function()
  it("gives Emacs's results for tags, property and TODO matches", function()
    for _, c in ipairs(MATCHES) do
      local pred, err = search.try_compile(c[1])
      ok(pred, c[1] .. ": " .. tostring(err))
      eq(c[2], run(pred), c[1])
    end
  end)

  it("errors on invalid regexps", function()
    local pred, err = search.try_compile("{a\\(}")
    eq(nil, pred)
    ok(err)
    eq(nil, (search.try_compile("With={[a}")))
  end)

  it("reads numbers like string-to-number", function()
    eq(1, search.string_to_number("1:30"))
    eq(3, search.string_to_number("3"))
    eq(0.5, search.string_to_number(".5"))
    eq(1000, search.string_to_number("1e3"))
    eq(0, search.string_to_number("abc"))
    eq(0, search.string_to_number(nil))
    eq(-2, search.string_to_number("  -2x"))
  end)

  it("compares dates relative to today", function()
    local date = require("org.date")
    local function stamp(n)
      return "<" .. date.today():add(n, "d"):to_string({ brackets = false }) .. ">"
    end
    local f = parser.parse({
      "* Past",
      "  SCHEDULED: " .. stamp(-2),
      "* Future",
      "  SCHEDULED: " .. stamp(3),
      "* None",
    }, "/tmp/agenda_match_dates.org")
    local function m(q)
      local pred = search.compile(q)
      local out = {}
      for _, hl in ipairs(f.headlines) do
        if pred(hl) then
          out[#out + 1] = hl.title
        end
      end
      return out
    end
    eq({ "Past" }, m('SCHEDULED<"<today>"'))
    eq({ "Future" }, m('SCHEDULED>"<+2d>"'))
    eq({ "Past", "Future" }, m('SCHEDULED<"<+1w>"'))
    eq({ "Past" }, m('SCHEDULED<"<-1d>"'))
    -- like Emacs, "<yesterday>" is not recognized as a date operand, so it
    -- compares as a string
    eq({ "Past", "Future", "None" }, m('SCHEDULED<"<yesterday>"'))
    -- entries without the property never match a date comparison
    eq({}, m('SCHEDULED<"<-1y>"'))
  end)
end)

describe("agenda search view (Emacs parity)", function()
  it("gives Emacs's results", function()
    for _, c in ipairs(SEARCHES) do
      eq(c[2], run(search.compile_text(c[1])), c[1])
    end
  end)

  it("honours the search_view_* options", function()
    local function s(q, opts)
      return run(search.compile_text(q, opts))
    end
    local b = { search_view_always_boolean = true }
    eq({ "Alpha" }, s("banana split", b))
    eq({ "Gamma" }, s("banana -split", b))
    eq({ "Alpha child" }, s("alpha child", b))
    eq({ D }, s("{^ +apple}", b))
    local w = { search_view_force_full_words = true }
    eq({}, s("+ban", w))
    eq({ "Alpha", "Gamma" }, s("+banana", w))
    eq({ "Alpha" }, s("banana split", w))
    eq({}, s("+alp -child", w))
    local l = { search_view_max_outline_level = 1 }
    eq({ "Alpha" }, s("+alpha", l))
    eq({ "Alpha" }, s("grandchild", l))
    eq({}, s("+child -boss", l))
    eq({ "Alpha" }, s("*grandchild", l))
  end)
end)

describe("Emacs regexp translation", function()
  -- { emacs regexp, string, start of the Emacs (string-match) match or nil }
  local cases = {
    { "ban+a", "xbana", 1 },
    { "ba\\(na\\)+", "banana", 0 },
    { "ba\\(?:na\\)\\{2\\}", "banana", 0 },
    { "ba\\(?:na\\)\\{3\\}", "banana", nil },
    { "^apple", "pie\napple", 4 },
    { "apple$", "apple\npie", 0 },
    { "^pie", "apple pie", nil },
    { "a.b", "a\nb", nil },
    { "a\\s-+b", "a \n b", 0 },
    { "a\\S-b", "a\nb", nil },
    { "\\bfoo\\b", "a foo b", 2 },
    { "\\bfoo\\b", "afoo", nil },
    { "\\`foo", "x\nfoo", nil },
    { "foo\\'", "foo\nx", nil },
    { "[^a]b", "\nb", 0 },
    { "[]a]", "]", 0 },
    { "[a\\]", "\\", 0 },
    { "a~b", "a~b", 0 },
    { "a|b", "a|b", 0 },
    { "(an)", "b(an)", 1 },
    { "{2}", "a{2}", 1 },
    { "*a", "*a", 0 },
    { "+a", "+a", 0 },
    { "^*a", "*a", 0 },
    { "a?c", "ac", 0 },
    { "a??c", "abc", 2 },
    { "\\w+", "__", nil },
    { "\\W", "_", 0 },
    { "\\s_", "_", 0 },
    { "c\\.d", "cxd", nil },
    { "a\\{,2\\}b", "aaab", 1 },
    { "\\(a\\)\\1", "aa", 0 },
    { "[[:upper:]]", "a", 0 },
  }
  it("matches like Emacs (case-fold-search t)", function()
    for _, c in ipairs(cases) do
      local r = search.compile_emacs_regexp(c[1])
      eq(c[3], (r:match_str(c[2])), c[1] .. " on " .. vim.inspect(c[2]))
    end
  end)
end)

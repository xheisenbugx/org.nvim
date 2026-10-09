-- Seeded random Org documents for the differential test against Emacs
-- (tests/difftest/init.lua, `make difftest`).
--
-- Unlike tests/helpers/fuzz.lua, whose documents are meant to break the
-- parser (truncated timestamps, CRLF, unterminated drawers), these are
-- mostly well-formed Org with the edge cases sprinkled in: a difference
-- from Emacs should point at a real behaviour, not at garbage both sides
-- read differently. Dates cluster around the fixed "now" (2026-10-01,
-- scripts/emacs-parity/common.el) so that agenda views have entries.
--
--   local doc = require("tests.difftest.gen").doc(seed)  -- lines

local fuzz = require("tests.helpers.fuzz")

local M = {}

-- the footnotes and <<target>> of the document being generated
M.refs, M.defs, M.target = {}, {}, false

local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local WORDS = {
  "alpha",
  "beta",
  "gamma",
  "delta",
  "task",
  "note",
  "Review",
  "plan",
  "x",
  "42",
  "ünïcödé",
  "日本語",
  "a:b",
  "foo-bar",
  "(paren)",
  "end.",
}

-- Inline markup, including the cases where it should not apply.
local MARKUP = {
  "*bold*",
  "/italic/",
  "=verbatim=",
  "~code~",
  "+strike+",
  "_under_",
  "*two words*",
  "*/nested/*",
  "_*mixed*_",
  "(*paren*)",
  "*bold*.",
  "a*b*c",
  "* not bold*",
  "*not bold *",
  "=*verb*=",
  "~a=b~",
  "x^2",
  "x^{10}",
  "H_2O",
  "a_{i}",
  "\\alpha",
  "\\alpha{}b",
  "\\to",
  "--",
  "---",
  "...",
  "$x+1$",
  "\\(a^2\\)",
  "src_python{1+1}",
  "@@html:<b>@@",
  "{{{title}}}",
  "<<target>>",
  "<<<radio>>>",
  "\\\\",
  "&",
  "<b>",
  '"quoted"',
  "it's",
}

local LINKS = {
  "[[https://example.com/a?b=c][a link]]",
  "https://orgmode.org",
  "[[https://example.com]]",
  "[[file:other.org][other]]",
  "[[file:img.png]]",
  "[[#custom][custom id]]",
  "[[*Alpha][heading]]",
  "[[target]]",
  "[[id:abc-123][an id]]",
  "<https://example.com/angle>",
  "mailto:me@example.com",
  "[[elisp:(+ 1 2)][sexp]]",
}

local TAGS = { "work", "home", "@ctx", "a_b", "urgent", "noexport" }

---@param rng fuzz.Rng
local function word(rng)
  if rng:chance(0.2) then
    local w = rng:pick(MARKUP)
    if w == "<<target>>" then
      -- one target per document: which of two a link reaches is a known
      -- difference (tests/difftest/known.lua), not worth finding again
      if M.target then
        return "<target>"
      end
      M.target = true
    end
    return w
  end
  return rng:pick(WORDS)
end

---@param rng fuzz.Rng
local function words(rng, n)
  local t = {}
  for i = 1, n or rng:int(1, 5) do
    t[i] = word(rng)
  end
  return table.concat(t, " ")
end

-- 2026-10-01 is day 0
local NOW = os.time({ year = 2026, month = 10, day = 1, hour = 12 })

---@param rng fuzz.Rng
---@param past? boolean before "now"
local function date(rng, past)
  local offset
  if past then
    offset = rng:int(-30, -1)
  elseif rng:chance(0.85) then
    offset = rng:int(-10, 14)
  else
    offset = rng:int(-800, 800)
  end
  local t = os.date("*t", NOW + offset * 86400)
  local day = DAYS[t.wday]
  if rng:chance(0.02) then
    day = rng:pick(DAYS) -- a wrong weekday name
  end
  return ("%04d-%02d-%02d %s"):format(t.year, t.month, t.day, day)
end

--- A timestamp: active or inactive, sometimes with a time, a time range,
--- a repeater, a warning delay, or as a date range.
---@param rng fuzz.Rng
---@param active? boolean
---@param plain? boolean no repeater or warning
function M.timestamp(rng, active, plain)
  if active == nil then
    active = rng:chance(0.7)
  end
  local o, c = active and "<" or "[", active and ">" or "]"
  local function one(simple)
    local s = date(rng)
    if rng:chance(0.45) then
      local h, m = rng:int(6, 21), rng:pick({ 0, 15, 30, 45 })
      s = s .. (" %02d:%02d"):format(h, m)
      if not simple and rng:chance(0.2) then
        s = s .. ("-%02d:%02d"):format(math.min(h + rng:int(1, 2), 23), m)
      end
    end
    if not simple and not plain then
      if rng:chance(0.2) then
        s = s .. " " .. rng:pick({ "+", "++", ".+" }) .. rng:int(1, 3) .. rng:pick({ "d", "w", "m", "y" })
      end
      if rng:chance(0.15) then
        s = s .. " " .. rng:pick({ "-", "--" }) .. rng:int(1, 5) .. "d"
      end
    end
    return o .. s .. c
  end
  if rng:chance(0.1) then
    return one(true) .. "--" .. one(true)
  end
  return one(false)
end

---@param rng fuzz.Rng
local function text(rng)
  local parts = { words(rng) }
  local r = rng:float()
  if r < 0.15 then
    parts[#parts + 1] = rng:pick(LINKS)
  elseif r < 0.25 then
    parts[#parts + 1] = M.timestamp(rng)
  elseif r < 0.32 then
    local label = tostring(rng:int(1, 3))
    M.refs[label] = true
    parts[#parts + 1] = "[fn:" .. label .. "]"
  elseif r < 0.35 then
    parts[#parts + 1] = "[fn::inline " .. words(rng, 2) .. "]"
  elseif r < 0.38 then
    M.refs.named = true
    parts[#parts + 1] = "[fn:named]"
  end
  if rng:chance(0.4) then
    parts[#parts + 1] = words(rng, rng:int(1, 3))
  end
  local s = table.concat(parts, " ")
  if s:match("^%*+ ") then
    s = "x " .. s -- not a headline
  end
  return s
end

--- A headline, and whether its subtree isn't exported (COMMENT or the
--- noexport tag).
---@param rng fuzz.Rng
---@param keywords string[]
---@return string, boolean
local function headline(rng, level, keywords)
  local p = { string.rep("*", level) }
  if rng:chance(0.45) then
    p[#p + 1] = rng:pick(keywords)
  end
  if rng:chance(0.2) then
    p[#p + 1] = "[#" .. rng:pick({ "A", "B", "C" }) .. "]"
  end
  local excluded = false
  if rng:chance(0.05) then
    p[#p + 1] = "COMMENT"
    excluded = true
  end
  p[#p + 1] = rng:chance(0.15) and rng:pick({ "Alpha", "Beta" }) or words(rng, rng:int(1, 4))
  if rng:chance(0.08) then
    p[#p + 1] = rng:pick({ "[/]", "[%]" })
  end
  local s = table.concat(p, " ")
  if rng:chance(0.3) then
    local t, seen = {}, {}
    for _ = 1, rng:int(1, 2) do
      local tag = rng:pick(TAGS)
      if not seen[tag] then
        seen[tag] = true
        t[#t + 1] = tag
        excluded = excluded or tag == "noexport"
      end
    end
    s = s .. " :" .. table.concat(t, ":") .. ":"
  end
  return s, excluded
end

---@param rng fuzz.Rng
local function planning(rng, done)
  local p = {}
  if done and rng:chance(0.7) then
    p[#p + 1] = "CLOSED: " .. M.timestamp(rng, false, true)
  end
  if rng:chance(0.6) then
    p[#p + 1] = "SCHEDULED: " .. M.timestamp(rng, true)
  end
  if rng:chance(0.4) or #p == 0 then
    p[#p + 1] = "DEADLINE: " .. M.timestamp(rng, true)
  end
  return table.concat(p, " ")
end

---@param rng fuzz.Rng
local function properties(rng, out, n)
  out[#out + 1] = ":PROPERTIES:"
  local used = {}
  for _ = 1, rng:int(1, 3) do
    local k = rng:pick({ "CUSTOM_ID", "CATEGORY", "Effort", "ID", "ORDERED", "Owner", "EXPORT_TITLE" })
    if not used[k] then
      used[k] = true
      local v = ({
        CUSTOM_ID = "custom" .. (n > 1 and n or ""),
        CATEGORY = rng:pick({ "proj", "life", "x" }),
        Effort = rng:pick({ "0:30", "1:00", "2:15" }),
        ID = "id-" .. n,
        ORDERED = "t",
        Owner = rng:pick(WORDS),
        EXPORT_TITLE = "Exported",
      })[k]
      out[#out + 1] = ":" .. k .. ": " .. v
    end
  end
  out[#out + 1] = ":END:"
end

---@param rng fuzz.Rng
local function logbook(rng, out)
  out[#out + 1] = ":LOGBOOK:"
  for _ = 1, rng:int(1, 3) do
    local d = date(rng)
    if rng:chance(0.7) then
      local h1 = rng:int(6, 12)
      local h2 = h1 + rng:int(0, 5)
      out[#out + 1] = ("CLOCK: [%s %02d:00]--[%s %02d:30] => %2d:30"):format(d, h1, d, h2, h2 - h1)
    else
      out[#out + 1] = ('- State "DONE"       from "TODO"       [%s 10:00]'):format(d)
    end
  end
  out[#out + 1] = ":END:"
end

---@param rng fuzz.Rng
local function list(rng, out, indent, depth)
  local kind = rng:pick({ "-", "-", "+", "1.", "1)" })
  local desc = kind:match("^%d") == nil and rng:chance(0.2)
  for i = 1, rng:int(1, 4) do
    local bullet = kind:match("^%d") and (i .. kind:sub(-1)) or kind
    local s = indent .. bullet .. " "
    if kind:match("^%d") and i == 1 and rng:chance(0.15) then
      s = s .. "[@" .. rng:int(2, 9) .. "] "
    end
    if rng:chance(0.3) then
      s = s .. rng:pick({ "[ ] ", "[X] ", "[-] " })
    end
    if desc then
      s = s .. words(rng, 1) .. " :: "
    end
    out[#out + 1] = s .. text(rng)
    if rng:chance(0.15) then
      out[#out + 1] = indent .. string.rep(" ", #bullet + 1) .. text(rng)
    end
    if depth < 2 and rng:chance(0.2) then
      list(rng, out, indent .. string.rep(" ", #bullet + 1), depth + 1)
    end
  end
  if rng:chance(0.3) then
    out[#out + 1] = ""
  end
end

local FORMULAS = {
  "$3=$1+$2",
  "$3=$1*$2",
  "$3=$1-$2;%.2f",
  "$3=$2/$1;%.1f",
  "@>$1=vsum(@I..@II)",
  "@>$2=vsum(@2..@-1)",
  "$2=vmean($1..$1)",
  "@2$3=@2$1*10",
  "$3='(+ $1 $2);N",
  "$3=if($1>$2, 1, 0)",
  "$3=round($1/3)",
  "$3=$1*2::@2$1=7",
  "$4=$1+$2+$3",
  "$3=$1 + $2; E",
  "$3=$1..$2",
  "$3=vmax($1..$2)",
}

---@param rng fuzz.Rng
local function tbl(rng, out)
  local cols = rng:int(2, 4)
  local rows = rng:int(2, 5)
  local header = rng:chance(0.6)
  if header then
    local h = {}
    for c = 1, cols do
      h[c] = rng:pick({ "Name", "Qty", "Price", "Total", "N", "x" }) .. c
    end
    out[#out + 1] = "| " .. table.concat(h, " | ") .. " |"
    out[#out + 1] = "|" .. string.rep("---+", cols - 1) .. "---|"
  end
  for _ = 1, rows do
    local cells = {}
    for c = 1, cols do
      local r = rng:float()
      if r < 0.6 then
        cells[c] = tostring(rng:int(-5, 120))
      elseif r < 0.75 then
        cells[c] = ("%.1f"):format(rng:int(0, 999) / 10)
      elseif r < 0.85 then
        cells[c] = ""
      else
        cells[c] = words(rng, 1)
      end
    end
    out[#out + 1] = "| " .. table.concat(cells, " | ") .. " |"
  end
  if rng:chance(0.3) then
    out[#out + 1] = "|" .. string.rep("---+", cols - 1) .. "---|"
    local cells = {}
    for c = 1, cols do
      cells[c] = c == 1 and "Sum" or ""
    end
    out[#out + 1] = "| " .. table.concat(cells, " | ") .. " |"
  end
  if rng:chance(0.55) then
    out[#out + 1] = "#+TBLFM: " .. rng:pick(FORMULAS)
  end
end

---@param rng fuzz.Rng
local function block(rng, out)
  local kind = rng:pick({ "src", "src", "example", "quote", "center", "verse", "export", "comment" })
  if rng:chance(0.2) then
    out[#out + 1] = "#+NAME: blk" .. rng:int(1, 9)
  end
  if rng:chance(0.1) then
    out[#out + 1] = "#+CAPTION: A " .. words(rng, 2)
  end
  local head = "#+begin_" .. kind
  if kind == "src" then
    head = head .. " " .. rng:pick({ "python", "emacs-lisp", "sh", "lua", "c", "org" })
    if rng:chance(0.2) then
      head = head .. " -n"
    end
    if rng:chance(0.3) then
      head = head .. " :exports " .. rng:pick({ "code", "both", "none", "results" })
    end
  elseif kind == "export" then
    head = head .. " " .. rng:pick({ "html", "latex", "ascii" })
  elseif kind == "example" and rng:chance(0.2) then
    head = head .. " -n"
  end
  out[#out + 1] = head
  for _ = 1, rng:int(1, 3) do
    local r = rng:float()
    if r < 0.1 then
      out[#out + 1] = ",* escaped headline"
    elseif r < 0.15 then
      out[#out + 1] = ",#+begin_x"
    elseif kind == "src" or kind == "example" then
      out[#out + 1] = rng:pick({ "x = 1", "print(x) # <b>&", "  indented()", '(message "hi")', "" })
    else
      out[#out + 1] = text(rng)
    end
  end
  out[#out + 1] = "#+end_" .. kind
end

--- Body elements of a section; `excluded`: in a subtree that isn't
--- exported (COMMENT, noexport).
---@param rng fuzz.Rng
---@param excluded? boolean
local function body(rng, out, excluded)
  for _ = 1, rng:int(0, 3) do
    local r = rng:float()
    if r < 0.25 then
      for _ = 1, rng:int(1, 3) do
        out[#out + 1] = text(rng)
      end
      out[#out + 1] = ""
    elseif r < 0.4 then
      list(rng, out, "", 0)
    elseif r < 0.52 then
      tbl(rng, out)
    elseif r < 0.64 then
      block(rng, out)
    elseif r < 0.68 then
      out[#out + 1] = ":NOTES:"
      out[#out + 1] = text(rng)
      out[#out + 1] = ":END:"
    elseif r < 0.72 then
      local label = rng:pick({ "1", "2", "named" })
      if M.defs[label] == nil then -- one definition per label
        -- one in a subtree that isn't exported doesn't count: Emacs
        -- refuses to export a reference without a definition, so the
        -- footnote section gets one too
        M.defs[label] = not excluded
        out[#out + 1] = "[fn:" .. label .. "] " .. text(rng)
      end
    elseif r < 0.76 then
      -- an inline task (org-inlinetask-min-level is 15)
      out[#out + 1] = string.rep("*", 15) .. " " .. (rng:chance(0.5) and "TODO " or "") .. words(rng, 2)
      if rng:chance(0.5) then
        out[#out + 1] = text(rng)
        out[#out + 1] = string.rep("*", 15) .. " END"
      end
    elseif r < 0.82 then
      out[#out + 1] = rng:pick({
        "-----",
        ": fixed width",
        "# a comment",
        "#+KEYWORD: value",
        "\\begin{equation}",
        "Text with a timestamp " .. M.timestamp(rng) .. " inside.",
        M.timestamp(rng),
      })
      if out[#out]:match("begin{") then
        out[#out + 1] = "x = 1"
        out[#out + 1] = "\\end{equation}"
      end
    elseif r < 0.9 then
      out[#out + 1] = text(rng)
    else
      out[#out + 1] = ""
    end
  end
end

--- A habit (agenda.habits, org-habit): a repeated TODO with STYLE habit.
---@param rng fuzz.Rng
local function habit(rng, out, level)
  out[#out + 1] = string.rep("*", level) .. " TODO " .. words(rng, 2)
  local d = date(rng)
  local rep = rng:pick({ ".+1d", ".+2d", "++1w", ".+2d/4d", "+1d" })
  out[#out + 1] = "SCHEDULED: <" .. d .. " " .. rep .. ">"
  out[#out + 1] = ":PROPERTIES:"
  out[#out + 1] = ":STYLE: habit"
  out[#out + 1] = ":END:"
  if rng:chance(0.7) then
    out[#out + 1] = ":LOGBOOK:"
    for _ = 1, rng:int(1, 4) do
      out[#out + 1] = ('- State "DONE"       from "TODO"       [%s 09:00]'):format(date(rng, true))
    end
    out[#out + 1] = ":END:"
  end
end

---@param rng fuzz.Rng
---@param excluded? boolean in a subtree that isn't exported
local function entry(rng, out, level, depth, keywords, done, n, excluded)
  if rng:chance(0.05) then
    habit(rng, out, level)
    return
  end
  local h, ex = headline(rng, level, keywords)
  excluded = excluded or ex
  out[#out + 1] = h
  local kw = h:match("^%*+ (%u+)")
  if rng:chance(0.4) then
    out[#out + 1] = planning(rng, kw and done[kw])
  end
  if rng:chance(0.25) then
    n[1] = n[1] + 1
    properties(rng, out, n[1])
  end
  if rng:chance(0.12) then
    logbook(rng, out)
  end
  body(rng, out, excluded)
  if depth < 2 then
    for _ = 1, rng:int(0, 2) do
      entry(rng, out, level + 1, depth + 1, keywords, done, n, excluded)
    end
  end
end

--- A random document for `seed` as lines.
---@param seed integer
---@return string[]
function M.doc(seed)
  local rng = fuzz.rng(seed)
  local out = {}
  -- footnote labels referenced and defined: every reference gets a
  -- definition (Emacs refuses to export a document without one)
  M.refs, M.defs, M.target = {}, {}, false
  local keywords, done = { "TODO", "DONE" }, { DONE = true }
  if rng:chance(0.4) then
    -- not {{{title}}} itself: a circular macro
    out[#out + 1] = "#+title: " .. words(rng, 2):gsub("{{{title}}}", "Title")
  end
  if rng:chance(0.15) then
    out[#out + 1] = "#+TODO: TODO NEXT WAITING | DONE CANCELLED"
    keywords = { "TODO", "NEXT", "WAITING", "DONE", "CANCELLED" }
    done = { DONE = true, CANCELLED = true }
  end
  if rng:chance(0.15) then
    out[#out + 1] = "#+STARTUP: " .. rng:pick({ "overview", "content", "showall", "showeverything", "fold" })
  end
  if rng:chance(0.2) then
    out[#out + 1] = "#+OPTIONS: "
      .. rng:pick({ "toc:nil", "num:nil", "^:{}", "toc:nil num:nil", "H:2", "todo:nil", "tags:nil", "p:t" })
  end
  if rng:chance(0.1) then
    out[#out + 1] = "#+MACRO: m Value $1"
  end
  if #out > 0 then
    out[#out + 1] = ""
  end
  if rng:chance(0.5) then
    body(rng, out)
  end
  local n = { 0 }
  for _ = 1, rng:int(1, 4) do
    entry(rng, out, 1, 0, keywords, done, n)
  end
  -- the missing definitions in a footnote section (org-footnote-section),
  -- which isn't exported itself and can't be in a noexport subtree
  local missing = {}
  for label in pairs(M.refs) do
    if not M.defs[label] then
      missing[#missing + 1] = label
    end
  end
  table.sort(missing)
  if #missing > 0 then
    out[#out + 1] = "* Footnotes"
    for _, label in ipairs(missing) do
      out[#out + 1] = "[fn:" .. label .. "] Note " .. label .. "."
      out[#out + 1] = ""
    end
  end
  return out
end

return M

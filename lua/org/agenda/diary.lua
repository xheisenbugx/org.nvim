---@mod org.agenda.diary The Emacs diary file in the agenda
---
--- A port of what `org-agenda-include-diary` runs for each day of a date
--- agenda: `diary-list-entries` (diary-lib.el) on `diary-file`, the fancy
--- diary display (with the day's holidays) and Org's clean-up of it
--- (`org-get-entries-from-diary`, `org-agenda-cleanup-fancy-diary`).
---
--- The diary file has one entry per date line, in the forms of
--- `calendar-date-style` (`diary-date-forms`): `9/27`, `9/27/2026`,
--- `Sep 27`, `September 27, 2026`, `Sunday`, `*` wildcards, the `&`
--- non-marking prefix, lines indented under an entry continuing it, and
--- `%%(SEXP) text` entries evaluated by org.agenda.sexp. With
--- `agenda.diary_include_files`, `#include "FILE"` lines add the entries of
--- other diary files; `agenda.diary_nongregorian` adds the Hebrew (H),
--- Islamic (I), Bahá’í (B) and Chinese (C) date entries.

local config = require("org.config")
local date = require("org.date")

local M = {}

-- files, includes and sexps already reported (once per session)
M._warned = {}

local function warn_once(key, msg)
  if not M._warned[key] then
    M._warned[key] = true
    vim.schedule(function()
      vim.notify("org agenda: " .. msg, vim.log.levels.WARN)
    end)
  end
end

--- The diary file: `agenda.diary_file`, else Emacs's default
--- (locate-user-emacs-file "diary" "diary"): ~/diary when it exists, else
--- `diary` in the Emacs user directory.
---@return string
function M.file()
  local f = config.opts.agenda.diary_file
  if f and f ~= "" then
    return vim.fs.normalize(vim.fn.expand(f))
  end
  local home = vim.fs.normalize("~")
  if vim.fn.filereadable(home .. "/diary") == 1 then
    return home .. "/diary"
  end
  if vim.fn.isdirectory(home .. "/.emacs.d") == 0 then
    local xdg = vim.env.XDG_CONFIG_HOME
    xdg = (xdg and xdg ~= "") and xdg or (home .. "/.config")
    if vim.fn.isdirectory(xdg .. "/emacs") == 1 then
      return xdg .. "/emacs/diary"
    end
  end
  return home .. "/.emacs.d/diary"
end

---------------------------------------------------------------------------
-- Reading a diary file
---------------------------------------------------------------------------

---@class org.DiaryText
---@field path string
---@field text string the file (CRLF line ends read as LF)
---@field low string `text` lower-cased (case-fold-search)
---@field starts integer[] byte position of each line

--- Read and index a diary file; nil when it cannot be read.
---@return org.DiaryText|nil
local function read_file(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local text = fd:read("*a") or ""
  fd:close()
  text = text:gsub("\r\n", "\n")
  local starts = { 1 }
  for p in text:gmatch("()\n") do
    if p < #text then
      starts[#starts + 1] = p + 1
    end
  end
  return { path = path, text = text, low = text:lower(), starts = starts }
end

--- Line number of byte position `pos`.
local function line_of(f, pos)
  local lo, hi = 1, #f.starts
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if f.starts[mid] <= pos then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo
end

--- The text of line `lnum` (without its newline).
local function line_text(f, lnum)
  local s = f.starts[lnum]
  local e = f.text:find("\n", s, true)
  return f.text:sub(s, (e or #f.text + 1) - 1)
end

--- A word constituent of `diary-syntax-table` (letters, digits, `*`, `:`).
local function is_word(c)
  return c ~= "" and (c:match("[%w%*:]") ~= nil or c:byte() >= 128)
end

---------------------------------------------------------------------------
-- Date forms (diary-date-forms)
---------------------------------------------------------------------------

-- Each element of a form is a list of alternatives, tried in order with
-- backtracking like the Emacs regexp; an alternative returns the position
-- after its match or nil.

local function lit(str)
  return function(low, pos)
    if low:sub(pos, pos + #str - 1) == str then
      return pos + #str
    end
  end
end

local function pat(p)
  return function(low, pos)
    local _, e = low:find("^" .. p, pos)
    return e and e + 1
  end
end

--- `0*N`
local function zeros(n)
  local s = tostring(n)
  return function(low, pos)
    local p = pos
    while low:sub(p, p) == "0" do
      p = p + 1
    end
    -- back off the zeros for N = 0
    for q = p, pos, -1 do
      if low:sub(q, q + #s - 1) == s then
        return q + #s
      end
    end
  end
end

--- `\W`: one non-word character (a newline too).
local function nonword(low, pos)
  local c = low:sub(pos, pos)
  if c ~= "" and not is_word(c) then
    return pos + 1
  end
end

--- The tail of the european `backup` form,
--- `\W+\<\([^*0-9]\|\([0-9]+[:.aApP]\)\)`, backed up to the word start.
local function backup_tail(low, pos)
  local p = pos
  while nonword(low, p) do
    p = p + 1
  end
  if p == pos then
    return nil
  end
  local c = low:sub(p, p)
  if not is_word(c) or c == "*" then
    return nil
  elseif not c:match("%d") then
    return p
  end
  local _, e = low:find("^%d+[:.ap]", p)
  return e and p
end

local W = { nonword }
local BACKUP = { backup_tail }

local FORMS = {
  american = {
    { "month", "/", "day", "[^/0-9]" },
    { "month", "/", "day", "/", "year", "%D" },
    { "monthname", " *", "day", "[^,0-9]" },
    { "monthname", " *", "day", ", *", "year", "%D" },
    { "dayname", W },
  },
  european = {
    { "day", "/", "month", "[^/0-9]" },
    { "day", "/", "month", "/", "year", "%D" },
    { "day", " *", "monthname", BACKUP },
    { "day", " *", "monthname", " *", "year", "[^0-9:.ap]" },
    { "dayname", W },
  },
  iso = {
    { "month", "[%-/]", "day", "[^%-/0-9]" },
    { "year", "[%-/]", "month", "[%-/]", "day", "%D" },
    { "monthname", " *", "day", "[^%-0-9]" },
    { "year", " *", "monthname", " *", "day", "%D" },
    { "dayname", W },
  },
}

local DAY_ABBREVS = { "sun", "mon", "tue", "wed", "thu", "fri", "sat" }

--- The keyword elements for a date (diary-list-entries-2): MONTH DAY YEAR
--- of the calendar, the month names (nil = the Gregorian names, which can
--- be abbreviated) and the day of the week (0 = Sunday).
local function keywords(month, day, year, names, dow)
  local cal = require("org.agenda.calendars")
  local mname = (names or cal.MONTH_NAMES)[month]
  local monthname = { lit("*") }
  if mname then
    -- (there is no month before the epoch of a calendar)
    monthname[2] = lit(mname:lower())
  end
  if mname and not names then
    local abbrev = mname:sub(1, 3):lower()
    monthname[#monthname + 1] = lit(abbrev .. ".")
    monthname[#monthname + 1] = lit(abbrev)
  end
  local dayname = cal.DAY_NAMES[dow + 1]:lower()
  local years = { lit("*"), zeros(year) }
  -- diary-abbreviated-year-flag
  years[#years + 1] = lit(string.format("%02d", math.fmod(year, 100)))
  return {
    month = { lit("*"), zeros(month) },
    day = { lit("*"), zeros(day) },
    year = years,
    monthname = monthname,
    dayname = { lit(dayname), lit(DAY_ABBREVS[dow + 1] .. "."), lit(DAY_ABBREVS[dow + 1]) },
  }
end

--- Compile the date forms of the style for the keyword elements.
local function compile(style, kw)
  local forms = {}
  for i, form in ipairs(FORMS[style] or FORMS.american) do
    local elems = {}
    for j, piece in ipairs(form) do
      if type(piece) == "table" then
        elems[j] = piece
      else
        elems[j] = kw[piece] or { pat(piece) }
      end
    end
    forms[i] = elems
  end
  return forms
end

local function match_seq(low, pos, elems, i)
  if i > #elems then
    return pos
  end
  for _, alt in ipairs(elems[i]) do
    local e = alt(low, pos)
    if e then
      local r = match_seq(low, e, elems, i + 1)
      if r then
        return r
      end
    end
  end
end

---------------------------------------------------------------------------
-- Entries (diary-list-entries-2, diary-list-sexp-entries)
---------------------------------------------------------------------------

local ATTRS = {
  "foreground:[-%a]+",
  "background:[-%a]+",
  "width:[-%a]+",
  "height:[.%d]+",
  "weight:[-%a]+",
  "slant:[-%a]+",
  "underline:[-%a]+",
  "overline:[-%a]+",
  "strike%-through:[-%a]+",
  "inverse%-video:[-%a]+",
  "face:[-%w]+",
  "font:[-%w]+",
}

--- diary-pull-attrs: remove the face attributes (`[foreground:red]`, ...).
local function pull_attrs(s)
  for _, a in ipairs(ATTRS) do
    s = s:gsub(" *%[" .. a .. "%] *", "")
  end
  return s
end

--- The entry text after a date or sexp ending at `pos` (the rest of the
--- line and the indented lines below it) and the position of its end.
local function entry_after(f, pos)
  local text = f.text
  local n = #text
  local start = pos
  local p = text:find("\n", pos, true)
  p = p and p + 1 or n + 1
  while p <= n and text:sub(p, p):match("[ \t]") do
    local e = text:find("\n", p, true)
    p = e and e + 1 or n + 1
  end
  -- (unless (and (eobp) (not (bolp))) (backward-char 1))
  if not (p > n and text:sub(n, n) ~= "\n") then
    p = p - 1
  end
  return text:sub(start, p - 1), p
end

--- Is `pos` at the beginning of a line that is not indented (a date line
--- with no entry text)?
local function bare_date(f, pos)
  return f.text:sub(pos - 1, pos - 1) == "\n" and not f.text:sub(pos, pos):match("[ \t]")
end

--- Add the entries of the date forms matching the date (diary-list-entries-2).
local function list_forms(f, forms, symbol, out)
  local text, low = f.text, f.low
  for _, elems in ipairs(forms) do
    for _, ls in ipairs(f.starts) do
      local p = ls
      if low:sub(p, p) == "&" then
        p = p + 1
      end
      local ok = true
      if symbol then
        ok = low:sub(p, p + #symbol - 1) == symbol:lower()
        p = p + #symbol
      end
      local pos = ok and match_seq(low, p, elems, 1)
      if pos and not bare_date(f, pos) then
        if text:find("^[ \t]*\n[ \t]", pos) then
          pos = text:find("\n", pos, true) + 1
        end
        local s, e = entry_after(f, pos)
        out[#out + 1] = { text = pull_attrs(s), file = f, lnum = line_of(f, math.min(e, #text)) }
      end
    end
  end
end

local parsed = {}

--- Add the `%%(SEXP)` entries applying to DAY (diary-list-sexp-entries).
local function list_sexps(f, day, out)
  local sexp = require("org.agenda.sexp")
  local text = f.text
  for _, ls in ipairs(f.starts) do
    local s = text:match("^&?%%%%%(()", ls)
    if s then
      local open = s - 1
      local close = sexp.sexp_end(text, open)
      if close then
        local src = text:sub(open, close)
        local entry, p = "", close + 2
        if p > #text + 1 or bare_date(f, p) then
          p = p - 1
        else
          entry, p = entry_after(f, p)
        end
        local node = parsed[src]
        if node == nil then
          local err
          node, err = sexp.parse(src)
          parsed[src] = node or false
          if not node then
            warn_once(src, string.format("bad diary sexp %s: %s; skipping", src, tostring(err)))
          end
        end
        if node then
          local res, err = sexp.eval_diary(node, day, entry)
          if res == nil then
            warn_once(src, string.format("bad diary sexp %s in %s: %s; skipping", src, f.path, tostring(err)))
          elseif res then
            out[#out + 1] = { text = pull_attrs(res), file = f, lnum = line_of(f, math.min(p, #text)) }
          end
        end
      end
    end
  end
end

local HEBREW_LEAP_MONTHS = {
  "Nisan",
  "Iyar",
  "Sivan",
  "Tammuz",
  "Av",
  "Elul",
  "Tishri",
  "Heshvan",
  "Kislev",
  "Teveth",
  "Shevat",
  "Adar I",
  "Adar II",
}
local CHINESE_MONTHS = {
  "正月",
  "二月",
  "三月",
  "四月",
  "五月",
  "六月",
  "七月",
  "八月",
  "九月",
  "十月",
  "冬月",
  "臘月",
}

--- The calendars of `agenda.diary_nongregorian`: entry symbol, month names
--- and the date of an absolute day (diary-*-list-entries).
local NONGREGORIAN = {
  hebrew = function(abs)
    local m, d, y = require("org.agenda.holidays.hebrew").from_absolute(abs)
    return "H", HEBREW_LEAP_MONTHS, m, d, y
  end,
  islamic = function(abs)
    local m, d, y = require("org.agenda.holidays.islamic").from_absolute(abs)
    return "I", require("org.agenda.calendars").ISLAMIC_MONTHS, m, d, y
  end,
  bahai = function(abs)
    local m, d, y = require("org.agenda.holidays.bahai").from_absolute(abs)
    return "B", require("org.agenda.calendars").BAHAI_MONTHS, m, d, y
  end,
  chinese = function(abs)
    -- calendar-chinese-from-absolute-for-diary: the year is CYCLE * 100 + YEAR
    local c, y, m, d = require("org.agenda.holidays.chinese").from_absolute(abs)
    return "C", CHINESE_MONTHS, math.floor(m), d, c * 100 + y
  end,
}

---@class org.DiaryEntry
---@field text string
---@field file org.DiaryText|nil
---@field lnum integer|nil

--- The entries of diary file `path` for DAY, in Emacs's order: sexp
--- entries, then each date form, then the other calendars, then the
--- included files (diary-list-entries).
---@param path string
---@param day integer org.date day number
---@param ctx { files: table<string, org.DiaryText|false>, included: table<string, boolean>, style: string }
---@param out org.DiaryEntry[]
---@param main boolean the diary file itself (not an included file)
local function list_entries(path, day, ctx, out, main)
  local acfg = config.opts.agenda
  local f = ctx.files[path]
  if f == nil then
    f = read_file(path) or false
    ctx.files[path] = f
  end
  if f then
    list_sexps(f, day, out)
    local y, m, d = date.civil_from_days(day)
    list_forms(f, compile(ctx.style, keywords(m, d, y, nil, (day + 4) % 7)), nil, out)
    local astro = require("org.agenda.holidays.astro")
    local abs = day + astro.EPOCH_ABS
    for _, name in ipairs(acfg.diary_nongregorian or {}) do
      local conv = NONGREGORIAN[name]
      if conv then
        local symbol, names, cm, cd, cy = conv(abs)
        -- calendar-day-name of the date taken as Gregorian, like Emacs
        local dow = math.floor(astro.absolute_from_gregorian(cm, cd, cy)) % 7
        list_forms(f, compile(ctx.style, keywords(cm, cd, cy, names, dow)), symbol, out)
      end
    end
  end
  if main then
    -- org-diary-default-entry: keeps the day in the fancy diary
    out[#out + 1] = { text = "Org mode dummy" }
  end
  if f and acfg.diary_include_files then
    local dir = vim.fs.dirname(ctx.main)
    for inc in f.text:gmatch('%f[^\n%z]#include "([^"]*)"') do
      local file = vim.fs.normalize(vim.fn.expand(inc))
      if not file:match("^/") then
        file = vim.fs.normalize(dir .. "/" .. file)
      end
      if vim.fn.filereadable(file) == 0 then
        warn_once("include " .. file, string.format("can't find included diary file %s", inc))
      elseif ctx.included[file] then
        warn_once("recursive " .. file, string.format("recursive diary include for %s", inc))
      else
        ctx.included[file] = true
        list_entries(file, day, ctx, out, false)
      end
    end
  end
end

---------------------------------------------------------------------------
-- The fancy diary and Org's clean-up of it
---------------------------------------------------------------------------

--- `^[0-9]?[0-9]` followed by am/pm, h, hHH or :MM / .MM (diary-time-regexp).
local function is_time(s)
  for n = 2, 1, -1 do
    local digits = s:sub(1, n)
    if #digits == n and digits:match("^%d+$") then
      local rest = s:sub(n + 1)
      if rest:match("^[AaPp][Mm]") or rest:match("^[Hh]") or rest:match("^[:.]%d%d") then
        return true
      end
    end
  end
  return false
end

---@class org.DiaryLine
---@field text string
---@field entry org.DiaryEntry|nil where the line comes from (nil for a holiday)

--- The agenda lines of the diary for DAY: the lines of the fancy diary
--- display after org-agenda-cleanup-fancy-diary, with indented lines that
--- do not start with a time joined to the line before with "; ".
---@param day integer org.date day number
---@param cache? table shared between the days of one agenda
---@return org.DiaryLine[]
function M.day_lines(day, cache)
  local acfg = config.opts.agenda
  cache = cache or {}
  cache.files = cache.files or {}
  local main = M.file()
  local entries = {}
  list_entries(main, day, {
    files = cache.files,
    included = { [main] = true },
    style = require("org.agenda.calendars").date_style(),
    main = main,
  }, entries, true)
  -- diary-fancy-display: the holidays follow the date line (and become
  -- lines of their own in the clean-up), then the non-empty entries
  local lines = {}
  if acfg.diary_show_holidays ~= false then
    for _, h in ipairs(require("org.agenda.holidays").check(day)) do
      lines[#lines + 1] = { text = h }
    end
  end
  for _, e in ipairs(entries) do
    if e.text ~= "" then
      for _, l in ipairs(vim.split(e.text, "\n", { plain = true })) do
        lines[#lines + 1] = { text = l, entry = e }
      end
    end
  end
  -- remove the lines of spaces, then the Org mode dummy
  local kept = {}
  for _, l in ipairs(lines) do
    if not l.text:match("^ +$") then
      kept[#kept + 1] = l
    end
  end
  for i, l in ipairs(kept) do
    if l.text:sub(1, 14) == "Org mode dummy" then
      if #l.text == 14 then
        table.remove(kept, i)
      else
        l.text = l.text:sub(15)
      end
      break
    end
  end
  -- "\n[ \t]+\(.+\)$" not followed by a time: joined with "; "
  local out = {}
  for i, l in ipairs(kept) do
    local ws, rest = l.text:match("^([ \t]*)(.*)$")
    if rest == "" and #ws >= 2 then
      ws, rest = ws:sub(1, -2), ws:sub(-1)
    end
    if i > 1 and #ws > 0 and rest ~= "" and not is_time(rest) then
      local prev = out[#out]
      prev.text = prev.text .. "; " .. rest
      prev.entry = l.entry
    else
      out[#out + 1] = { text = l.text, entry = l.entry }
    end
  end
  -- org-split-string drops an empty first and last line
  if out[1] and out[1].text == "" then
    table.remove(out, 1)
  end
  if out[#out] and out[#out].text == "" then
    table.remove(out)
  end
  return out
end

---@private
function M._line_text(f, lnum)
  return line_text(f, lnum)
end

return M

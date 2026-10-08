---@mod org.extensions.quickadd.parse Todoist-style quick-add parser
---
--- `parse(text, now, opts)` turns one line such as
---
---   Call Bob fri 3pm #work #phone !A ~30m @Inbox due mon every week
---
--- into the parts of an entry (title, keyword, priority, tags, effort,
--- SCHEDULED / DEADLINE, repeater and target). It never touches buffers or
--- files, so it can run on every keystroke of the preview.

local date = require("org.date")

local M = {}

---@class org.QuickaddItem
---@field title string
---@field todo string|nil keyword (nil for none)
---@field priority string|nil
---@field tags string[]
---@field effort integer|nil minutes
---@field scheduled table|nil org.date of SCHEDULED
---@field deadline table|nil org.date of DEADLINE
---@field planning { scheduled?: string, deadline?: string } timestamps as written
---@field repeater { type: string, value: integer, unit: string }|nil
---@field target { raw: string, file?: string, heading?: string }|nil

---@class org.QuickaddParseOpts
---@field keyword? string|false default keyword
---@field keywords? string[] keywords `*KW` may name
---@field date_kind? "scheduled"|"deadline"
---@field priority_highest? string
---@field priority_lowest? string

---------------------------------------------------------------------------
-- Tokens
---------------------------------------------------------------------------

--- Split `text` into words. A backslash makes the next character literal;
--- "double quotes" (at the start of a word or after its @ / # sigil) and
--- 'single quotes' (at the start of a word) group words into one literal
--- word. Returns { text, plain, sigil } tokens: `plain` when no character
--- was quoted or escaped (only plain words can be dates or keywords),
--- `sigil` the unescaped first character.
---@param text string
---@return { text: string, plain: boolean, sigil: string|nil }[]
function M.tokenize(text)
  local tokens = {}
  local cur, plain, sigil, started
  local function flush()
    if started then
      tokens[#tokens + 1] = { text = table.concat(cur), plain = plain, sigil = sigil }
    end
    cur, plain, sigil, started = {}, true, nil, false
  end
  flush()
  local i, n = 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if c:match("%s") then
      flush()
      i = i + 1
    elseif c == "\\" and i < n then
      started = true
      plain = false
      -- the next (possibly multibyte) character
      local ch = text:sub(i + 1):match("^[%z\1-\127\194-\244][\128-\191]*")
      cur[#cur + 1] = ch
      i = i + 1 + #ch
    else
      local at_start = #cur == 0 and not started
      local after_sigil = started and #cur == 1 and sigil ~= nil and plain
      local close
      if (c == '"' and (at_start or after_sigil)) or (c == "'" and at_start) then
        -- the closing quote ends a word
        local j = i + 1
        while j <= n do
          if text:sub(j, j) == c and (j == n or text:sub(j + 1, j + 1):match("%s")) then
            close = j
            break
          end
          j = j + 1
        end
      end
      if close then
        started = true
        plain = false
        cur[#cur + 1] = text:sub(i + 1, close - 1)
        i = close + 1
      else
        if at_start and (c == "@" or c == "#" or c == "!" or c == "~" or c == "*") then
          sigil = c
        end
        started = true
        cur[#cur + 1] = c
        i = i + 1
      end
    end
  end
  flush()
  return tokens
end

---------------------------------------------------------------------------
-- Dates
---------------------------------------------------------------------------

-- stylua: ignore
local WEEKDAYS = {
  sun = 0, sunday = 0, mon = 1, monday = 1, tue = 2, tues = 2, tuesday = 2, wed = 3, weds = 3,
  wednesday = 3, thu = 4, thur = 4, thurs = 4, thursday = 4, fri = 5, friday = 5, sat = 6, saturday = 6,
}
local WEEKDAY_NAME = { [0] = "sun", "mon", "tue", "wed", "thu", "fri", "sat" }
-- stylua: ignore
local MONTHS = {
  jan = true, january = true, feb = true, february = true, mar = true, march = true, apr = true,
  april = true, may = true, jun = true, june = true, jul = true, july = true, aug = true, august = true,
  sep = true, sept = true, september = true, oct = true, october = true, nov = true, november = true,
  dec = true, december = true,
}
-- stylua: ignore
local WORDS = {
  today = "today", tod = "today", tomorrow = "tomorrow", tmr = "tomorrow", tmrw = "tomorrow",
  yesterday = "yesterday", now = "now", noon = "12:00", midnight = "00:00", tonight = "today 20:00",
}
-- stylua: ignore
local UNITS = {
  h = "h", hour = "h", hours = "h", d = "d", day = "d", days = "d", w = "w", week = "w", weeks = "w",
  m = "m", month = "m", months = "m", y = "y", year = "y", years = "y",
}

-- Words that are dates only where a date is expected: they also occur in
-- titles ("Watch Friday Night Lights", "Plan the midnight release").
-- stylua: ignore
local WEAK = {
  now = true, noon = true, midnight = true, tonight = true, tod = true,
}
for w in pairs(WEEKDAYS) do
  WEAK[w] = true
end

local function is_time(w)
  return w:match("^[012]?%d:[0-5]%d$")
    or w:match("^[01]?%d:?[0-5]?%d?[ap]m$")
    or w:match("^[012]?%d:[0-5]%d%-[012]?%d:[0-5]%d$")
    or w:match("^[01]?%d:?[0-5]?%d?[ap]m%-[01]?%d:?[0-5]?%d?[ap]m$")
    or w:match("^[012]?%d:[0-5]%d%+%d:?%d*$")
end

local function is_relative(w)
  local sign, rest = w:match("^([%+%-][%+%-]?)(%d*%a*)$")
  if not sign then
    return false
  end
  local num, what = rest:match("^(%d*)(%a*)$")
  if what == "" then
    return num ~= ""
  end
  return what:match("^[hdwmy]$") ~= nil or WEEKDAYS[what] ~= nil
end

-- A dotted European date as the date prompt reads it: `15.3.` or
-- `15.3.2027`, with a real day and month (so "1.2.0" or "0.11.2", version
-- numbers, are not dates).
local function is_dotted_date(w)
  local d, m, y = w:match("^(%d%d?)%.(%d%d?)%.(%d*)$")
  if not d then
    return false
  end
  d, m = tonumber(d), tonumber(m)
  return d >= 1 and d <= 31 and m >= 1 and m <= 12 and (y == "" or y:match("^[1-9]%d%d%d$") ~= nil)
end

local function is_numeric_date(w)
  return w:match("^%d%d%d%d%-%d%d?%-%d%d?$")
    or w:match("^%d%d%d%d%-%d%d?%-%d%d?t%d%d?:%d%d$")
    or w:match("^%d%d?/%d%d?$")
    or w:match("^%d%d?/%d%d?/%d+$")
    or is_dotted_date(w)
    or w:match("^w%d%d?$")
end

--- Date word class of a plain lower-case word: "rel" (relative, goes
--- first), "date", "num" (a number, a date only next to a month name),
--- "month", or nil.
local function word_class(w)
  if is_relative(w) then
    return "rel"
  elseif WEEKDAYS[w] or WORDS[w] or is_time(w) or is_numeric_date(w) then
    return "date"
  elseif MONTHS[w] then
    return "month"
  elseif w:match("^%d%d?$") or w:match("^%d%d?st$") or w:match("^%d%d?nd$") or w:match("^%d%d?rd$") then
    return "num"
  elseif w:match("^%d%d?th$") or w:match("^%d%d%d%d$") then
    return "num"
  end
end

--- A day number next to a month name: `4`, `4th`, `21st`.
local function is_day(w)
  return w:match("^%d%d?$") ~= nil or w:match("^%d%d?[snrt][tdh]$") ~= nil
end

--- The text read_date understands for a word.
local function date_text(w)
  if WEEKDAYS[w] then
    return WEEKDAY_NAME[WEEKDAYS[w]]
  elseif WORDS[w] then
    return WORDS[w]
  elseif w == "sept" then
    return "sep"
  end
  return (w:gsub("^(%d+)[snrt][tdh]$", "%1"))
end

---------------------------------------------------------------------------
-- Parser
---------------------------------------------------------------------------

local function lower(tok)
  return tok.plain and tok.text:lower() or nil
end

--- Effort minutes of `30m`, `1h`, `1h30`, `1h30m`, `1:30`, `90`, `2d`.
---@param s string
---@return integer|nil
function M.parse_effort(s)
  s = s:lower()
  local h, m = s:match("^(%d+):(%d%d)$")
  if h then
    return tonumber(h) * 60 + tonumber(m)
  end
  if s:match("^%d+$") then
    return tonumber(s)
  end
  local d = s:match("^(%d+)d$")
  if d then
    return tonumber(d) * 1440
  end
  h, m = s:match("^(%d+)h(%d*)m?i?n?$")
  if h then
    return tonumber(h) * 60 + (tonumber(m) or 0)
  end
  h = s:match("^(%d*%.%d+)h$")
  if h then
    return math.floor(tonumber(h) * 60 + 0.5)
  end
  m = s:match("^(%d+)m$") or s:match("^(%d+)min$") or s:match("^(%d+)mins$")
  return m and tonumber(m) or nil
end

--- Parse the words after `every` from token `i`: returns the repeater,
--- weekdays (a list of 0-6), the index after the spec, or nil.
local function parse_every(tokens, i)
  local w = tokens[i] and lower(tokens[i])
  if not w then
    return nil
  end
  -- stylua: ignore
  local simple = {
    day = "d", daily = "d", week = "w", weekly = "w", month = "m", monthly = "m", year = "y",
    yearly = "y", annually = "y", hour = "h", hourly = "h",
  }
  if simple[w] then
    return { value = 1, unit = simple[w] }, nil, i + 1
  end
  if w == "weekday" or w == "weekdays" or w == "workday" or w == "workdays" then
    return nil, { 1, 2, 3, 4, 5 }, i + 1
  elseif w == "weekend" or w == "weekends" then
    return nil, { 0, 6 }, i + 1
  end
  local n, u = w:match("^(%d+)([hdwmy])$")
  if n and tonumber(n) > 0 then
    return { value = tonumber(n), unit = u }, nil, i + 1
  end
  local nxt = tokens[i + 1] and lower(tokens[i + 1])
  if (w:match("^%d+$") or w == "other") and nxt and UNITS[nxt] then
    local v = w == "other" and 2 or tonumber(w)
    if v > 0 then
      return { value = v, unit = UNITS[nxt] }, nil, i + 2
    end
  end
  -- every mon, every mon,thu, every mon, thu, every mon thu, every mon and thu
  -- The weekdays of a word ("mon", "mon,", "mon,thu"), or nil.
  local function weekdays(word)
    local list = {}
    for part in ((word or "") .. ","):gmatch("([^,]*),") do
      if part ~= "" then
        if not WEEKDAYS[part] then
          return nil
        end
        list[#list + 1] = WEEKDAYS[part]
      end
    end
    return #list > 0 and list or nil
  end
  local days, j = {}, i
  while true do
    local found = weekdays(tokens[j] and lower(tokens[j]))
    if not found then
      break
    end
    for _, d in ipairs(found) do
      if not vim.tbl_contains(days, d) then
        days[#days + 1] = d
      end
    end
    j = j + 1
    local nw = tokens[j] and lower(tokens[j])
    local after = tokens[j + 1] and lower(tokens[j + 1])
    if (nw == "and" or nw == ",") and weekdays(after) then
      j = j + 1
    elseif not weekdays(nw) then
      break
    end
  end
  if #days == 1 then
    return { value = 1, unit = "w" }, days, j
  elseif #days > 1 then
    table.sort(days)
    return nil, days, j
  end
  return nil
end

local function sexp_stamp(days, time)
  local list = table.concat(
    vim.tbl_map(function(d)
      return tostring(d)
    end, days),
    " "
  )
  local cond = string.format("(memq (calendar-day-of-week date) '(%s))", list)
  if time then
    return string.format('<%%%%(when %s "%s")>', cond, time)
  end
  return string.format("<%%%%%s>", cond)
end

local function default_opts()
  local config = require("org.config").opts
  local todo = require("org.todo_keywords").global()
  local ext = require("org.extensions").opts("quickadd") or {}
  local kw = ext.keyword
  if kw == nil then
    kw = "TODO"
  end
  return {
    keyword = kw,
    keywords = vim.tbl_map(function(k)
      return k.name
    end, todo.keywords),
    date_kind = ext.date_kind or "scheduled",
    priority_highest = config.priority_highest or "A",
    priority_lowest = config.priority_lowest or "C",
  }
end

--- Parse a quick-add line.
---@param text string
---@param now? table org.date "now" dates are read from (default: now)
---@param opts? org.QuickaddParseOpts
---@return org.QuickaddItem
function M.parse(text, now, opts)
  opts = vim.tbl_extend("keep", opts or {}, default_opts())
  local tokens = M.tokenize(text or "")
  local item = { tags = {}, planning = {} }
  local title = {}
  -- The title is built from `parts`: literal words, and date runs that
  -- are decided on at the end (a run that is not taken goes back into
  -- the title as written).
  local parts = {}
  local date_words = { scheduled = {}, deadline = {} }
  local every -- { repeater?, days?, bang }
  local kind_default = opts.date_kind == "deadline" and "deadline" or "scheduled"
  local keywords = {}
  for _, k in ipairs(opts.keywords or {}) do
    keywords[k:upper()] = k
  end
  local hi, lo = (opts.priority_highest or "A"):byte(), (opts.priority_lowest or "C"):byte()

  local function literal(tok)
    parts[#parts + 1] = { text = tok.text }
  end

  -- Read a run of date words from `i`: returns the index after the run
  -- (i when nothing was taken), the run, and whether it was introduced by
  -- "at" / "on" / "next" / "in".
  local function take_dates(i)
    local j = i
    local run = {}
    local prep = false
    while tokens[j] do
      local w = lower(tokens[j])
      if not w then
        break
      end
      local cls = word_class(w)
      local nxt = tokens[j + 1] and lower(tokens[j + 1])
      local prev = run[#run]
      if cls == "month" then
        -- a month name only counts next to a day number ("may" is a word)
        local next_num = nxt and word_class(nxt) == "num"
        local prev_num = prev and prev.cls == "num"
        if not (next_num or prev_num) then
          break
        end
      elseif cls == "num" then
        -- A month takes a day number on one side only ("chapter 3 may 4"
        -- is May 4th), and a year may follow "may 4" or "4 may".
        local year = w:match("^%d%d%d%d$") ~= nil
        local before = run[#run - 1]
        local next_month = nxt and word_class(nxt) == "month"
        local after_month = tokens[j + 2] and lower(tokens[j + 2])
        if next_month and after_month and is_day(after_month) then
          next_month = false -- the number after the month is its day
        end
        local prev_month = prev and prev.cls == "month" and (year or not (before and before.cls == "num"))
        local month_day = year
          and prev
          and prev.cls == "num"
          and is_day(prev.word or "")
          and before
          and before.cls == "month"
          and not (run[#run - 2] and run[#run - 2].cls == "num")
        if not (next_month or prev_month or month_day) then
          break
        end
      elseif not cls then
        local after = tokens[j + 2] and lower(tokens[j + 2])
        if (w == "at" or w == "on") and nxt and word_class(nxt) and word_class(nxt) ~= "num" then
          cls = "skip"
          prep = true
        elseif w == "next" and nxt and (UNITS[nxt] or WEEKDAYS[nxt]) then
          prep = true
          if WEEKDAYS[nxt] then
            run[#run + 1] = { cls = "date", text = date_text(nxt) }
          else
            run[#run + 1] = { cls = "rel", text = "+1" .. UNITS[nxt] }
          end
          j = j + 2
          goto continue
        elseif w == "in" and nxt and (nxt:match("^%d+$") or nxt == "a" or nxt == "an") and after and UNITS[after] then
          prep = true
          local n = tonumber(nxt) or 1
          run[#run + 1] = { cls = "rel", text = "+" .. n .. UNITS[after] }
          j = j + 3
          goto continue
        else
          break
        end
      end
      if cls ~= "skip" then
        run[#run + 1] = { cls = cls, text = date_text(w), word = w }
      end
      j = j + 1
      ::continue::
    end
    -- "at"/"on" can't end a run
    if #run == 0 then
      return i
    end
    return j, run, prep
  end

  local function candidate(from, to, kind, run, prep, explicit)
    local words = {}
    for k = from, to - 1 do
      words[#words + 1] = tokens[k].text
    end
    local weak = true
    for _, x in ipairs(run) do
      if not WEAK[x.word or ""] then
        weak = false
      end
    end
    parts[#parts + 1] = {
      kind = kind,
      run = run,
      text = table.concat(words, " "),
      weak = weak and not prep,
      explicit = explicit,
    }
  end

  local i = 1
  while i <= #tokens do
    local tok = tokens[i]
    local w = lower(tok)
    local body = tok.text:sub(2)
    if tok.sigil == "#" and body ~= "" and body:match("^[%w_@#%%\128-\255]+$") and body:match("[^%d]") then
      if not vim.tbl_contains(item.tags, body) then
        item.tags[#item.tags + 1] = body
      end
      i = i + 1
    elseif tok.sigil == "@" and vim.trim(body) ~= "" then
      local file, heading = body:match("^([^/]+)/(.*)$")
      item.target = { raw = body }
      if file then
        item.target.file = file
        item.target.heading = heading ~= "" and heading or nil
      else
        item.target.heading = body
      end
      i = i + 1
    elseif tok.sigil == "!" and #body == 1 and body:upper():byte() >= hi and body:upper():byte() <= lo then
      item.priority = body:upper()
      i = i + 1
    elseif tok.sigil == "!" and body:match("^%d$") and hi + tonumber(body) - 1 <= lo and tonumber(body) > 0 then
      item.priority = string.char(hi + tonumber(body) - 1)
      i = i + 1
    elseif w and w:match("^p%d$") and tonumber(w:sub(2)) > 0 and hi + tonumber(w:sub(2)) - 1 <= lo then
      item.priority = string.char(hi + tonumber(w:sub(2)) - 1)
      i = i + 1
    elseif tok.sigil == "~" and M.parse_effort(body) then
      item.effort = M.parse_effort(body)
      i = i + 1
    elseif tok.sigil == "*" and (keywords[body:upper()] or body == "-") then
      if body == "-" then
        item.todo = false
      else
        item.todo = keywords[body:upper()]
      end
      i = i + 1
    elseif w == "due" or w == "by" then
      local j, run, prep = take_dates(i + 1)
      if j == i + 1 then
        literal(tok)
        i = i + 1
      else
        candidate(i, j, "deadline", run, prep, true)
        i = j
      end
    elseif (w == "every" or w == "every!") and not every then
      local rep, days, j = parse_every(tokens, i + 1)
      if rep or days then
        every = { repeater = rep, days = days, bang = w == "every!" }
        i = j
      else
        literal(tok)
        i = i + 1
      end
    else
      local j, run, prep = i, nil, false
      if w then
        j, run, prep = take_dates(i)
      end
      if j == i then
        literal(tok)
        i = i + 1
      else
        candidate(i, j, kind_default, run, prep, false)
        i = j
      end
    end
  end

  -- Which date runs count: a run of weak words only (a weekday, "now")
  -- only at the end of the title or after "at" / "on" / "due"; then the
  -- last run of each kind, like Todoist, and the others stay text.
  local after_text = false
  local last = {}
  for k = #parts, 1, -1 do
    local part = parts[k]
    if part.run then
      local taken = part.explicit or not part.weak or not after_text
      if taken and not last[part.kind] then
        last[part.kind] = part
      else
        part.run = nil
      end
    end
    if not part.run then
      after_text = true
    end
  end

  local saved_now = date.now
  if now then
    date.now = function()
      return now:clone()
    end
  end
  local ok, err = pcall(function()
    now = date.now()
    for _, kind in ipairs({ "scheduled", "deadline" }) do
      local part = last[kind]
      if part then
        local words = {}
        for _, x in ipairs(part.run) do
          if x.cls == "rel" then
            words[#words + 1] = x.text
          end
        end
        for _, x in ipairs(part.run) do
          if x.cls ~= "rel" then
            words[#words + 1] = x.text
          end
        end
        item[kind] = date.read_date(table.concat(words, " "))
        if not item[kind] then
          -- not a date after all: the words stay in the title
          part.run = nil
        end
      end
    end
  end)
  date.now = saved_now
  if not ok then
    error(err, 0)
  end

  for _, part in ipairs(parts) do
    if part.run then
      vim.list_extend(date_words[part.kind], part.run)
    elseif part.text ~= "" then
      title[#title + 1] = part.text
    end
  end
  item.title = table.concat(title, " ")
  if item.todo == nil then
    item.todo = opts.keyword or nil
  elseif item.todo == false then
    item.todo = nil
  end

  local times_only = {}
  for _, kind in ipairs({ "scheduled", "deadline" }) do
    times_only[kind] = true
    for _, x in ipairs(date_words[kind]) do
      if not is_time(x.text) then
        times_only[kind] = false
      end
    end
  end

  if every then
    local kind = item[kind_default] and kind_default or (item.deadline and "deadline" or kind_default)
    if every.days and not every.repeater then
      -- several weekdays: a diary sexp (org has no such repeater)
      local d = item[kind]
      local time = d and d:time_string()
      item[kind] = nil
      item.planning[kind] = sexp_stamp(every.days, time)
    else
      local rep = { type = every.bang and ".+" or "+", value = every.repeater.value, unit = every.repeater.unit }
      local d = item[kind]
      if not d then
        d = date.from_days(now:days())
        if rep.unit == "h" then
          d.hour, d.min = now.hour, now.min
        end
      end
      if every.days and times_only[kind] then
        -- every mon: the next Monday (today on a Monday), at the time given
        d = d:add((every.days[1] - d:weekday() % 7 + 7) % 7, "d")
      end
      d.repeater = rep
      item[kind] = d
      item.repeater = rep
    end
  end
  for _, kind in ipairs({ "scheduled", "deadline" }) do
    if item[kind] then
      item.planning[kind] = item[kind]:to_string()
    end
  end
  return item
end

return M

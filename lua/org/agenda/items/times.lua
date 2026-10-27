---@mod org.agenda.items.times Times of day in agenda entries
---
--- The time of an agenda line (org-get-time-of-day,
--- org-plain-time-of-day-regexp, org-stamp-time-of-day-regexp), taking
--- timestamps out of a title, and `set_time`, the DOTIME part of
--- org-agenda-format-item. Part of org.agenda.items, which loads it.

-- Not compiled by the JIT, like org.agenda.items (see the comment there).
if jit then
  jit.off(true, true)
end

local date = require("org.date")
local shared = require("org.agenda.items.shared")

local M = require("org.agenda.items")

local function is_word(c)
  return c ~= nil and c ~= "" and c:match("[%w]") ~= nil
end

--- One time at byte `i` (a word start): "10:00", "9:30am", "8pm".
---@return integer|nil minutes, integer? end (exclusive)
local function match_one(s, i)
  if is_word(s:sub(i - 1, i - 1)) then
    return nil
  end
  for _, n in ipairs({ 2, 1 }) do
    local h = s:sub(i, i + n - 1)
    if #h == n and h:match(n == 2 and "^[012]%d$" or "^%d$") then
      local j = i + n
      local hour, min, ampm = tonumber(h), 0, nil
      local mm = s:match("^:([0-5]%d)", j)
      local ok = false
      if mm then
        min = tonumber(mm) or 0
        j = j + 3
        local ap = s:sub(j, j + 1):lower()
        if ap == "am" or ap == "pm" then
          -- `\>` after am/pm, else retry without it
          if not is_word(s:sub(j + 2, j + 2)) then
            ampm = ap
            j = j + 2
            ok = true
          end
        end
        if not ok and not is_word(s:sub(j, j)) then
          ok = true
        end
      else
        local ap = s:sub(j, j + 1):lower()
        if (ap == "am" or ap == "pm") and not is_word(s:sub(j + 2, j + 2)) then
          ampm = ap
          j = j + 2
          ok = true
        end
      end
      if ok then
        if ampm == "am" then
          hour = hour == 12 and 0 or hour
        elseif ampm == "pm" then
          hour = hour == 12 and 12 or hour + 12
        end
        return hour * 60 + min, j
      end
    end
  end
  return nil
end

--- First plain time or time range in `s` (org-plain-time-of-day-regexp).
---@return { start: integer, stop?: integer, s: integer, e: integer, text: string }|nil
function M.find_time(s)
  if not s then
    return nil
  end
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c:match("%d") then
      local t1, j = match_one(s, i)
      if t1 then
        local res = { start = t1, s = i, e = j - 1 }
        local dash = s:match("^%-%-?", j)
        if dash then
          local t2, k = match_one(s, j + #dash)
          if t2 then
            res.stop, res.e = t2, k - 1
          end
        end
        res.text = s:sub(res.s, res.e)
        return res
      end
    end
    i = i + 1
  end
  return nil
end

--- The first `<date day HH:MM...>` in `s` (org-stamp-time-of-day-regexp:
--- a weekday is needed), ending at `HH:MM-HH:MM` inside it, else at the
--- end of a same-day range `<date day HH:MM>--<date day HH:MM>` (the same
--- date and day, nothing after the time).
---@return { start: integer, stop?: integer, s: integer, e: integer, text: string }|nil
local function stamp_time(s)
  local init = 1
  while true do
    local p = s:find("<", init, true)
    if not p then
      return nil
    end
    local day, h, mi, j = s:match("^<(%d%d%d%d%-%d%d%-%d%d +[%w\128-\255]+ +)([012]%d):([0-5]%d)()", p)
    if day then
      local res = { start = tonumber(h) * 60 + tonumber(mi), s = p }
      local h2, m2, k = s:match("^%-([012]%d):([0-5]%d)()", j)
      if h2 then
        res.stop, j = tonumber(h2) * 60 + tonumber(m2), k
      end
      local close = s:find(">", j, true)
      if close and not s:sub(j, close - 1):find("[\r\n]") then
        res.e = close
        local h3, m3, e = s:match("^%-%-?<" .. vim.pesc(day) .. "([012]%d):([0-5]%d)>()", close + 1)
        if h3 then
          res.e = e - 1
          if not h2 then
            res.stop = tonumber(h3) * 60 + tonumber(m3)
          end
        end
        res.text = s:sub(res.s, res.e)
        return res
      end
    end
    init = p + 1
  end
end

--- The time org-agenda-format-item takes from a DOTIME string: a timestamp
--- time (org-stamp-time-of-day-regexp), else the first plain time.
function M.dotime_time(s)
  return stamp_time(s) or M.find_time(s)
end

--- Remove active and inactive timestamps from a string.
local function strip_timestamps(s)
  local out = s
  for _, m in ipairs(date.parse_all(s)) do
    out = out:gsub(vim.pesc(m.raw), "", 1)
  end
  return out
end
M.strip_timestamps = strip_timestamps

--- Remove `<...>` active timestamps (org-ts-regexp) from a title.
local function strip_active_timestamps(s)
  local out = s
  for _, m in ipairs(date.parse_all(s)) do
    if m.raw:sub(1, 1) == "<" then
      out = out:gsub(vim.pesc(m.raw), "", 1)
    end
  end
  return (out:gsub("<%%%%%b()[^>\n]*>", ""))
end

local function time_of(d)
  if d and d.hour then
    return d.hour * 60 + (d.min or 0)
  end
end

local function end_time_of(d)
  if d and d.end_hour then
    return d.end_hour * 60 + (d.end_min or 0)
  end
end

--- Set `time`/`end_time` of an item (org-agenda-format-item DOTIME).
--- `stamp` is the date the time comes from (or nil); `with_time` false =
--- no time at all (reminders, middle days of a block). Without a time in
--- the stamp, the headline is searched for one
--- (org-agenda-search-headline-for-time); a time found in the headline is
--- removed from the displayed title (org-agenda-remove-times-when-in-prefix).
--- `sexp_stamp` is the text of a `<%%(...)>` stamp, searched for a time
--- before the headline, as Emacs passes the stamp as DOTIME. `dotime` is
--- the DOTIME string Emacs passes (a date range, the text after a planning
--- time), in place of `stamp`: its time (M.dotime_time), else the
--- headline's.
local function set_time(item, stamp, acfg, remove_stamps, sexp_stamp, dotime)
  local title = item.title
  if remove_stamps then
    title = strip_active_timestamps(title)
  end
  -- Emacs searches DOTIME followed by the headline without its
  -- timestamps, so a timestamp in DOTIME can run into the headline:
  -- "10:45>--<a Sun 08:30 " before "@@html:<b>@@ x" is the time 08:30
  local in_dotime = dotime
  if dotime and acfg.search_headline_for_time ~= false then
    in_dotime = dotime .. strip_timestamps(item.title)
  end
  local found = in_dotime and M.dotime_time(in_dotime)
  if found then
    item.time, item.end_time = found.start, found.stop
    -- the entry sorts by the first time in DOTIME (org-get-time-of-day),
    -- which a timestamp's time can follow: "<a 10:00>--<a Mon 13:15>"
    -- shows 13:15 and sorts at 10:00
    local first = M.find_time(in_dotime)
    if first and first.start ~= found.start then
      item.sort_time = first.start
    end
  elseif stamp and stamp.hour and not dotime then
    item.time, item.end_time = time_of(stamp), end_time_of(stamp)
    -- the time as written, e.g. "10:30-11:45", for removal from the title
    local t = string.format("%02d:%02d", stamp.hour, stamp.min or 0)
    if stamp.end_hour then
      t = t .. "-" .. string.format("%02d:%02d", stamp.end_hour, stamp.end_min or 0)
    end
    -- a timestamp item's time comes from the stamp, which is removed
    -- from the text anyway (org-stamp-time-of-day-regexp)
    found = not remove_stamps and { text = t } or nil
  else
    found = sexp_stamp and M.find_time(sexp_stamp)
    if not found and acfg.search_headline_for_time ~= false then
      found = M.find_time(strip_timestamps(title))
    end
    if found then
      item.time, item.end_time = found.start, found.stop
    end
  end
  local rm = acfg.remove_times_when_in_prefix
  if found and rm ~= false and item.prefix_has_time ~= false then
    local s, e = title:find(vim.pesc(found.text) .. " *")
    if s and title:sub(e + 1, e + 1) ~= "]" and (rm ~= "beg" or (s == 1 and not item.todo and not item.priority)) then
      title = title:sub(1, s - 1) .. title:sub(e + 1)
    end
  end
  if item.time and not item.end_time and acfg.default_appointment_duration then
    item.end_time = item.time + acfg.default_appointment_duration
    item.end_time_default = true
  end
  if title ~= item.title then
    item.display_title = title
  end
end
M.set_time = set_time
shared.set_time = set_time

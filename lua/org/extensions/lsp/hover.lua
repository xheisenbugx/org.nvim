---@mod org.extensions.lsp.hover textDocument/hover

local date = require("org.date")
local parser = require("org.parser")
local util = require("org.extensions.lsp.util")
local targets = require("org.extensions.lsp.targets")

local M = {}

local UNITS = { h = "hour", d = "day", w = "week", m = "month", y = "year" }

local function plural(n, word)
  return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

local function unit_text(n, unit)
  return plural(n, UNITS[unit] or unit)
end

--- "today", "tomorrow", "in 3 days, Friday", "5 weeks ago, Monday"...
---@param ts table org.date timestamp
---@param today? table defaults to date.today()
function M.relative(ts, today)
  today = today or date.today()
  local d = ts:days() - today:days()
  local wd = date.DAY_NAMES_LONG[ts:weekday()]
  if d == 0 then
    if ts.hour then
      local now = date.now()
      local mins = ts:minutes() - now:minutes()
      if today:days() == date.today():days() and mins ~= 0 then
        local a = math.abs(mins)
        local span = a < 60 and plural(a, "minute")
          or (math.floor(a / 60) .. " h" .. (a % 60 > 0 and string.format(" %d min", a % 60) or ""))
        return mins > 0 and ("today, in " .. span) or ("today, " .. span .. " ago")
      end
    end
    return "today"
  elseif d == 1 then
    return "tomorrow, " .. wd
  elseif d == -1 then
    return "yesterday, " .. wd
  end
  local a = math.abs(d)
  local span
  if a < 14 then
    span = plural(a, "day")
  elseif a < 60 then
    span = plural(math.floor(a / 7 + 0.5), "week")
  elseif a < 730 then
    span = plural(math.floor(a / 30.44 + 0.5), "month")
  else
    span = plural(math.floor(a / 365.25 + 0.5), "year")
  end
  return (d > 0 and ("in " .. span) or (span .. " ago")) .. ", " .. wd
end

--- Explanation of a repeater: "Repeats every 2 weeks (+2w): ...".
function M.repeater_text(r)
  if not r or r.value == 0 then
    return nil
  end
  local every = unit_text(r.value, r.unit)
  local s
  if r.type == "+" then
    s = string.format("Repeats every %s (`%s`): marking it done moves the date %s later.", every, r.type, every)
  elseif r.type == "++" then
    s = string.format(
      "Repeats every %s (`++`): marking it done moves it by %s steps until it is in the future (catch-up).",
      every,
      every
    )
  else
    s = string.format("Repeats every %s (`.+`): marking it done sets it %s after the day it was done.", every, every)
  end
  if r.max then
    s = s .. string.format(" Habit: at most every %s.", unit_text(r.max.value, r.max.unit))
  end
  return s
end

local function long_date(ts)
  local s =
    string.format("%s, %d %s %d", date.DAY_NAMES_LONG[ts:weekday()], ts.day, date.MONTH_NAMES_LONG[ts.month], ts.year)
  local t = ts:time_string()
  return t and (s .. " " .. t) or s
end

--- Hover text of a timestamp (`label` e.g. "SCHEDULED").
function M.timestamp_text(ts, label)
  local out = {}
  local head = (ts.active and "Active" or "Inactive") .. " timestamp"
  if label then
    head = label .. " · " .. head:lower()
  end
  out[#out + 1] = string.format("**%s** — %s", long_date(ts), head)
  out[#out + 1] = ""
  out[#out + 1] = M.relative(ts)
  if ts.range_end then
    local days = ts.range_end:days() - ts:days()
    out[#out + 1] = string.format("until %s (%s)", long_date(ts.range_end), plural(days + 1, "day"))
  elseif ts.end_hour then
    local mins = (ts.end_hour * 60 + (ts.end_min or 0)) - (ts.hour * 60 + (ts.min or 0))
    out[#out + 1] = "lasts " .. date.format_duration(mins)
  end
  local rep = M.repeater_text(ts.repeater)
  if rep then
    out[#out + 1] = ""
    out[#out + 1] = rep
    local today = date.today():days()
    local nxt = date.occurrences(ts, today, today + 3660)[1]
    if nxt and nxt:days() ~= ts:days() then
      out[#out + 1] = string.format("Next occurrence: %s (%s)", long_date(nxt), M.relative(nxt))
    end
  end
  if ts.warning then
    local w = ts.warning
    out[#out + 1] = ""
    out[#out + 1] = string.format(
      "Warns %s before (`%s%d%s`)%s.",
      unit_text(w.value, w.unit),
      w.type,
      w.value,
      w.unit,
      w.type == "--" and ", only for the first occurrence of a repeater" or ""
    )
  end
  return table.concat(out, "\n")
end

local function clock_text(line)
  local c = parser.parse_clock_line(line)
  if not c then
    return nil
  end
  if not c["end"] then
    local mins = date.elapsed_minutes(c.start, date.now())
    return string.format(
      "**Running clock** — started %s (%s)\n\nelapsed %s",
      long_date(c.start),
      M.relative(c.start),
      date.format_duration(mins)
    )
  end
  local mins = c.minutes or date.elapsed_minutes(c.start, c["end"])
  local same = c.start:days() == c["end"]:days()
  return string.format(
    "**Clocked %s** (%s)\n\n%s → %s\n\n%s",
    date.format_duration(mins),
    require("org.duration").from_minutes(mins),
    long_date(c.start),
    same and (c["end"]:time_string() or "") or long_date(c["end"]),
    M.relative(c.start)
  )
end

local function fence(lines)
  return "```org\n" .. table.concat(lines, "\n") .. "\n```"
end

local function preview_lines(file, first, last)
  local n = util.opts().hover and util.opts().hover.preview_lines or 8
  local out = {}
  for i = first, math.min(last or #file.lines, first + n - 1) do
    out[#out + 1] = file.lines[i]
  end
  while #out > 0 and out[#out]:match("^%s*$") do
    out[#out] = nil
  end
  return out
end

--- Preview of a link's target.
local function link_text(doc, link)
  local head = string.format("`%s` link", link.type or "?")
  local WEB = { http = true, https = true, ftp = true, mailto = true, doi = true, news = true }
  if WEB[link.type] then
    return head .. "\n\n" .. link.type .. ":" .. link.path
  end
  local loc = targets.resolve(doc, link)
  if not loc then
    return head .. " — **target not found**\n\n" .. link.target
  end
  local file = require("org.files").get(loc.path)
  local where = vim.fn.fnamemodify(loc.path, ":~:.")
  if not file then
    return head .. " → " .. where
  end
  if loc.kind == "file" then
    return string.format("%s → **%s**\n\n%s", head, where, fence(preview_lines(file, 1)))
  end
  if loc.headline then
    local hl = loc.headline
    local olp = util.olp(hl)
    return string.format(
      "%s → **%s**%s\n\n%s",
      head,
      where,
      olp ~= "" and (" › " .. olp) or "",
      fence(preview_lines(file, hl.line, hl.end_line))
    )
  end
  return string.format(
    "%s → **%s**:%d (%s)\n\n%s",
    head,
    where,
    loc.lnum,
    loc.kind,
    fence(preview_lines(file, loc.lnum))
  )
end

local function footnote_text(doc, fn)
  local def = targets.footnote_definition(doc.lines, fn.label)
  if def then
    local lines = {}
    for i = def.start, def.stop do
      lines[#lines + 1] = doc.lines[i]
    end
    return string.format("**Footnote %s**\n\n%s", fn.label, table.concat(lines, "\n"))
  end
  return string.format("**Footnote %s** — no definition", fn.label)
end

local function heading_text(doc, hl)
  local out = {}
  local olp = util.olp(hl)
  out[#out + 1] = string.format("**%s**%s", hl:plain_title(), olp ~= "" and ("  \n" .. olp) or "")
  local facts = {}
  if hl.todo then
    facts[#facts + 1] = "`" .. hl.todo .. "`"
  end
  if hl.priority then
    facts[#facts + 1] = "priority " .. hl.priority
  end
  local tags = hl:get_tags()
  if #tags > 0 then
    facts[#facts + 1] = ":" .. table.concat(tags, ":") .. ":"
  end
  if #facts > 0 then
    out[#out + 1] = ""
    out[#out + 1] = table.concat(facts, " · ")
  end
  for _, what in ipairs({ "scheduled", "deadline", "closed" }) do
    local ts = hl.planning[what]
    if ts then
      out[#out + 1] = ""
      out[#out + 1] = string.format("%s %s (%s)", what:upper(), long_date(ts), M.relative(ts))
    end
  end
  local id, cid = hl.properties.ID, hl.properties.CUSTOM_ID
  if id or cid or util.opts().hover.backlinks_all_headings then
    local subject = targets.subject_of({
      kind = "heading",
      path = doc.path,
      lnum = hl.line,
      headline = hl,
      s = 1,
      e = 0,
    })
    local refs = subject and targets.references(subject) or {}
    local filesn = {}
    for _, r in ipairs(refs) do
      filesn[r.doc.path or ""] = true
    end
    out[#out + 1] = ""
    out[#out + 1] = string.format(
      "%s%s%s from %s",
      id and ("ID `" .. id .. "` · ") or "",
      cid and ("CUSTOM_ID `" .. cid .. "` · ") or "",
      plural(#refs, "backlink"),
      plural(vim.tbl_count(filesn), "file")
    )
  end
  return table.concat(out, "\n")
end

--- Markdown for the position, or nil.
---@param doc org.lsp.Doc
---@param lnum integer
---@param col integer 1-based byte column
---@return string|nil text, table|nil range
function M.at(doc, lnum, col)
  local line = doc.lines[lnum]
  if not line then
    return nil
  end
  -- a clock line: its duration (before the timestamps inside it)
  if line:match("^%s*CLOCK:") then
    local t = clock_text(line)
    if t then
      return t, util.range(lnum, 1, #line)
    end
  end
  local link = targets.link_at(doc, lnum, col)
  if link then
    return link_text(doc, link), util.range(lnum, link.start_col, link.end_col)
  end
  local item = date.at_col(line, col)
  if item then
    local before = line:sub(1, item.start_col - 1)
    local label = before:match("(%u+):%s*$")
    if label ~= "SCHEDULED" and label ~= "DEADLINE" and label ~= "CLOSED" then
      label = nil
    end
    return M.timestamp_text(item.date, label), util.range(lnum, item.start_col, item.end_col)
  end
  local fn = targets.footnote_at(line, col)
  if fn and not fn.definition then
    return footnote_text(doc, fn), util.range(lnum, fn.s, fn.e)
  end
  local radio = targets.radio_at(doc, lnum, col)
  if radio then
    return string.format("Radio link → `<<<%s>>>` (line %d)", radio.target.text, radio.target.lnum),
      util.range(lnum, radio.s, radio.e)
  end
  local hl = doc.file:headline_on(lnum)
  if hl then
    return heading_text(doc, hl), util.range(lnum, 1, #line)
  end
  return nil
end

return M

---@mod org.calendar Date picker
---
--- `pick(opts)` shows a floating month calendar and blocks until a date is
--- chosen. It returns:
---   * a date object when a date was selected,
---   * `{ remove = true }` when `x`/<Del> was pressed and `opts.allow_remove`,
---   * nil when cancelled.
---
--- Keys: h/l ±day, j/k ±week, H/L or </> ±month, J/K or [/] ±year,
--- `.` today, `i`/`t` type a date (org-read-date syntax, e.g. "+3d",
--- "fri 14:00", "2026-10-01"), `T` set/clear the time, <CR> select,
--- `x`/<Del> remove, q/<Esc> cancel.
---
--- The float shows the month with ISO week numbers and the neighbouring
--- months' days, today and the selection, and the chosen date in long
--- form with its distance from today. Colors are the OrgCalendar*
--- highlight groups (linked to standard groups; override them freely).

local date = require("org.date")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.calendar")

-- Highlight groups, linked to standard groups so any colorscheme works;
-- override them with nvim_set_hl (they are defined with `default`).
local HL = {
  OrgCalendarTitle = { link = "Title" },
  OrgCalendarArrow = { link = "Special" },
  OrgCalendarWeekday = { link = "Comment" },
  OrgCalendarWeekendHeader = { link = "Constant" },
  OrgCalendarDay = { link = "Normal" },
  OrgCalendarWeekend = { link = "Constant" },
  OrgCalendarOutside = { link = "NonText" },
  OrgCalendarWeekNumber = { link = "LineNr" },
  OrgCalendarToday = { bold = true, underline = true },
  OrgCalendarSelected = { link = "PmenuSel" },
  OrgCalendarDate = { link = "Function" },
  OrgCalendarTimestamp = { link = "String" },
  OrgCalendarRelative = { link = "Comment" },
  OrgCalendarSeparator = { link = "FloatBorder" },
  OrgCalendarKey = { link = "Special" },
  OrgCalendarHint = { link = "Comment" },
}

local function define_highlights()
  for name, spec in pairs(HL) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
  end
end
define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("org.calendar", { clear = true }),
  callback = define_highlights,
})

local CELL = 4 -- " 26 "
local MARGIN = 1
local WEEK = 4 -- " 39 " ISO week column
M.WIDTH = MARGIN + WEEK + 7 * CELL + MARGIN

--- ISO 8601 week number of a day number.
local function iso_week(days)
  local d = date.from_days(days)
  local thursday = days - (d:weekday() - 1) + 3
  local y = date.from_days(thursday).year
  return math.floor((thursday - date.days_from_civil(y, 1, 1)) / 7) + 1
end

--- "today", "tomorrow", "in 3 days", "2 weeks ago"...
function M.relative(days)
  if days == 0 then
    return "today"
  elseif days == 1 then
    return "tomorrow"
  elseif days == -1 then
    return "yesterday"
  end
  local n, unit = math.abs(days), "days"
  if n >= 14 and n % 7 == 0 then
    n, unit = n / 7, "weeks"
  end
  return days > 0 and string.format("in %d %s", n, unit) or string.format("%d %s ago", n, unit)
end

--- Lines and highlights of the calendar for the selected date `sel`.
--- Marks are { row, start_col, end_col, hl_group, priority } (0-based, bytes).
---@param sel table date
---@param opts? { allow_remove?: boolean, today?: table }
---@return string[] lines, table[] marks
function M.render(sel, opts)
  opts = opts or {}
  local today = opts.today or date.today()
  local lines, marks = {}, {}
  local function add(line)
    lines[#lines + 1] = line
    return #lines - 1
  end
  local function mark(row, s, e, group, prio)
    marks[#marks + 1] = { row, s, e, group, prio or 100 }
  end
  local pad = string.rep(" ", MARGIN)
  local rule = pad .. string.rep("─", M.WIDTH - 2 * MARGIN)

  -- ‹  September 2026  ›
  add("")
  local title = string.format("%s %d", date.MONTH_NAMES_LONG[sel.month], sel.year)
  local inner = M.WIDTH - 2 * MARGIN - 2
  local left = math.floor((inner - #title) / 2)
  local line = pad .. "‹" .. string.rep(" ", left) .. title .. string.rep(" ", inner - left - #title) .. "›"
  local row = add(line)
  mark(row, MARGIN, MARGIN + #"‹", "OrgCalendarArrow")
  local ts = MARGIN + #"‹" + left
  mark(row, ts, ts + #title, "OrgCalendarTitle")
  mark(row, #line - #"›", #line, "OrgCalendarArrow")
  add("")

  -- weekday header
  line = pad .. " Wk "
  local header = { "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }
  row = #lines
  local hmarks = { { MARGIN, MARGIN + WEEK, "OrgCalendarWeekNumber" } }
  for i, name in ipairs(header) do
    local s = #line + 1
    line = line .. " " .. name .. " "
    hmarks[#hmarks + 1] = { s, s + 2, i >= 6 and "OrgCalendarWeekendHeader" or "OrgCalendarWeekday" }
  end
  add(line)
  for _, m in ipairs(hmarks) do
    mark(row, m[1], m[2], m[3])
  end

  -- six weeks, starting on the Monday on or before the 1st
  local first = date.days_from_civil(sel.year, sel.month, 1)
  local start = first - (date.from_days(first):weekday() - 1)
  local sel_days, today_days = sel:days(), today:days()
  for w = 0, 5 do
    local week_start = start + 7 * w
    line = pad .. string.format(" %2d ", iso_week(week_start))
    row = #lines
    mark(row, MARGIN, MARGIN + WEEK, "OrgCalendarWeekNumber")
    for i = 0, 6 do
      local days = week_start + i
      local d = date.from_days(days)
      local s = #line
      line = line .. string.format(" %2d ", d.day)
      local group = d.month ~= sel.month and "OrgCalendarOutside"
        or (i >= 5 and "OrgCalendarWeekend" or "OrgCalendarDay")
      mark(row, s + 1, s + 3, group)
      if days == today_days then
        mark(row, s + 1, s + 3, "OrgCalendarToday", 150)
      end
      if days == sel_days then
        mark(row, s, s + CELL, "OrgCalendarSelected", 200)
      end
    end
    add(line)
  end

  -- the selected date: long form, timestamp and distance from today
  row = add(rule)
  mark(row, MARGIN, #rule, "OrgCalendarSeparator")
  local long = string.format(
    "%s, %d %s %d",
    date.DAY_NAMES_LONG[sel:weekday()],
    sel.day,
    date.MONTH_NAMES_LONG[sel.month],
    sel.year
  )
  row = add(pad .. long)
  mark(row, MARGIN, MARGIN + #long, "OrgCalendarDate")
  local stamp = sel:to_string()
  local rel = M.relative(sel_days - today_days)
  local gap = math.max(1, M.WIDTH - 2 * MARGIN - vim.fn.strdisplaywidth(stamp) - #rel)
  line = pad .. stamp .. string.rep(" ", gap) .. rel
  row = add(line)
  mark(row, MARGIN, MARGIN + #stamp, "OrgCalendarTimestamp")
  mark(row, #line - #rel, #line, "OrgCalendarRelative")
  row = add(rule)
  mark(row, MARGIN, #rule, "OrgCalendarSeparator")

  -- key hints: keys highlighted, descriptions dimmed
  local hints = {
    { { "hjkl", "day/week" }, { "HL", "month" }, { "JK", "year" } },
    { { ".", "today" }, { "i", "type" }, { "T", "time" } },
    { { "⏎", "select" }, opts.allow_remove and { "x", "remove" } or nil, { "esc", "cancel" } },
  }
  for _, group in ipairs(hints) do
    line = pad
    local hm = {}
    for _, h in pairs(group) do
      if #line > MARGIN then
        line = line .. "  "
      end
      hm[#hm + 1] = { #line, #line + #h[1], "OrgCalendarKey" }
      line = line .. h[1] .. " "
      hm[#hm + 1] = { #line, #line + #h[2], "OrgCalendarHint" }
      line = line .. h[2]
    end
    row = add(line)
    for _, m in ipairs(hm) do
      mark(row, m[1], m[2], m[3])
    end
  end
  return lines, marks
end

local K = {}
local function key(k)
  if not K[k] then
    K[k] = vim.keycode(k)
  end
  return K[k]
end

---@param opts? { default?: table, prompt?: string, with_time?: boolean, allow_remove?: boolean }
---@return table|nil
function M.pick(opts)
  opts = opts or {}
  local sel = (opts.default or date.today()):clone({ range_end = vim.NIL })
  local initial = sel:to_date_string()
  if opts.with_time and not sel.hour then
    local now = date.now()
    local r = (require("org.config").opts.time_stamp_rounding_minutes or {})[1] or 0
    if r > 1 then
      now = now:add(math.floor(now.min / r + 0.5) * r - now.min, "min")
    end
    sel.hour, sel.min = now.hour, now.min
  end
  -- one window for the whole session: redrawn in place on every key
  local buf, win
  local function draw()
    local lines, marks = M.render(sel, opts)
    if not (win and vim.api.nvim_win_is_valid(win)) then
      buf, win = require("org.ui").float(lines, { title = opts.prompt or "Date", width = M.WIDTH, enter = false })
      vim.wo[win].winhighlight = "Normal:NormalFloat"
    else
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
      vim.api.nvim_win_set_config(win, { height = #lines })
    end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, m in ipairs(marks) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4], priority = m[5] })
    end
    vim.cmd("redraw")
  end
  local function close()
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    win = nil
  end
  while true do
    draw()
    local ok, ch = pcall(vim.fn.getcharstr)
    if not ok or ch == "\27" or ch == "\3" or ch == "q" then
      close()
      return nil
    end
    if ch == "i" or ch == "t" or ch == "T" or ch == "\r" or ch == "\n" or ch == "x" or ch == key("<Del>") then
      -- prompts and results appear without the float in the way
      close()
    end
    if ch == "\r" or ch == "\n" then
      return sel
    elseif ch == "h" or ch == key("<Left>") then
      sel = sel:add(-1, "d")
    elseif ch == "l" or ch == key("<Right>") then
      sel = sel:add(1, "d")
    elseif ch == "j" or ch == key("<Down>") then
      sel = sel:add(7, "d")
    elseif ch == "k" or ch == key("<Up>") then
      sel = sel:add(-7, "d")
    elseif ch == "H" or ch == "<" then
      sel = sel:add(-1, "m", true)
    elseif ch == "L" or ch == ">" then
      sel = sel:add(1, "m", true)
    elseif ch == "K" or ch == "[" then
      sel = sel:add(-1, "y", true)
    elseif ch == "J" or ch == "]" then
      sel = sel:add(1, "y", true)
    elseif ch == "." then
      local t = date.today()
      sel = sel:clone({ year = t.year, month = t.month, day = t.day })
    elseif ch == "i" or ch == "t" then
      local ok2, text = pcall(vim.fn.input, { prompt = "Date: ", cancelreturn = vim.NIL })
      if ok2 and text ~= vim.NIL and text ~= nil then
        -- like Emacs, a date moved to in the calendar is part of the answer
        local answer = text
        if sel:to_date_string() ~= initial then
          answer = text .. " " .. sel:to_date_string()
        end
        local d = date.read_date(answer, opts.default)
        if d then
          if not d.hour and sel.hour then
            -- the time of the default date is kept (Emacs pre-fills it)
            d.hour, d.min, d.end_hour, d.end_min = sel.hour, sel.min, sel.end_hour, sel.end_min
          end
          d.repeater = d.repeater or (sel.repeater and vim.deepcopy(sel.repeater))
          d.warning = d.warning or (sel.warning and vim.deepcopy(sel.warning))
          return d
        end
        utils.warn("Cannot parse date: " .. text)
      end
    elseif ch == "T" then
      local cur = sel:time_string() or ""
      local ok2, text = pcall(vim.fn.input, { prompt = "Time (HH:MM[-HH:MM], empty clears): ", default = cur, cancelreturn = vim.NIL })
      if ok2 and text ~= vim.NIL and text ~= nil then
        text = vim.trim(text)
        if text == "" then
          sel = sel:clone({ hour = vim.NIL, min = vim.NIL, end_hour = vim.NIL, end_min = vim.NIL })
        else
          local d = date.read_date(text, sel)
          if d and d.hour then
            sel = sel:clone({ hour = d.hour, min = d.min, end_hour = d.end_hour or vim.NIL, end_min = d.end_min or vim.NIL })
          else
            utils.warn("Cannot parse time: " .. text)
          end
        end
      end
    elseif (ch == "x" or ch == key("<Del>")) and opts.allow_remove then
      return { remove = true }
    end
  end
end

return M

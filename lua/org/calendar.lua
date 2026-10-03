---@mod org.calendar Date picker
---
--- `pick(opts)` shows a floating month calendar and blocks until a date is
--- chosen. It returns:
---   * a date object when a date was selected,
---   * `{ remove = true }` when `x`/<Del> was pressed and `opts.allow_remove`,
---   * nil when cancelled.
---
--- Keys: h/l ±day, j/k ±week, H/L or </> ±month, J/K or [/] ±year,
--- C-v/M-v ±3 months, `.` today, `i`/`t` type a date (org-read-date
--- syntax, e.g. "+3d", "fri 14:00", "2026-10-01"; shown live in the
--- calendar with `read_date_display_live`), `T` set/clear the time, `!`
--- the agenda of the date, <CR> or a mouse click on a day select,
--- `x`/<Del> remove, q/<Esc> cancel (<Esc> only when `q` is a calendar key). With `read_date_popup_calendar`
--- off, only a "Date+time [default]: " prompt is shown.
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
---@param opts? { allow_remove?: boolean, today?: table, inactive?: boolean, live?: boolean, futurep?: boolean }
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
  local stamp = M.preview(sel, opts.inactive)
  local rel = M.relative(sel_days - today_days)
  if opts.live then
    -- the answer being typed, as Emacs shows it after the prompt
    -- (org-read-date-display): "=> <2026-10-01 Thu>", "(=>F)" when
    -- read_date_prefer_future moved it into the future
    stamp = "=> " .. stamp .. (opts.futurep and " (=>F)" or "")
    if vim.fn.strdisplaywidth(stamp) + #rel + 1 > M.WIDTH - 2 * MARGIN then
      rel = ""
    end
  end
  local gap = math.max(1, M.WIDTH - 2 * MARGIN - vim.fn.strdisplaywidth(stamp) - #rel)
  line = pad .. stamp .. string.rep(" ", gap) .. rel
  row = add(line)
  mark(row, MARGIN, MARGIN + #stamp, "OrgCalendarTimestamp")
  mark(row, #line - #rel, #line, "OrgCalendarRelative")
  row = add(rule)
  mark(row, MARGIN, #rule, "OrgCalendarSeparator")

  -- key hints: keys highlighted, descriptions dimmed
  local cal = opts.calendar and M.calendar_keys() or {}
  -- q cancels too, unless it is the calendar's agenda or diary key
  local q_quits = cal.agenda ~= "q" and cal.diary ~= "q"
  local hints = {
    { { "hjkl", "day/week" }, { "HL", "month" }, { "JK", "year" } },
    { { ".", "today" }, { cal.diary == "i" and "t" or "i", "type" }, { "T", "time" } },
    { { "⏎", "select" }, opts.allow_remove and { "x", "remove" } or nil, { q_quits and "q/Esc" or "Esc", "cancel" } },
  }
  if cal.agenda or cal.diary then
    -- the Emacs calendar's Org keys (org--setup-calendar-bindings)
    hints[#hints + 1] = {
      cal.agenda and { vim.fn.keytrans(cal.agenda), "agenda" } or nil,
      cal.diary and { vim.fn.keytrans(cal.diary), "diary entry" } or nil,
    }
  end
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

--- The selected date as the prompt previews it (org-read-date-display):
--- its timestamp (`[]` for an inactive prompt), or with
--- `display_custom_times` on, the date in `time_stamp_custom_formats` within
--- the brackets, like Emacs. As in Emacs, only the option counts: the
--- minibuffer doesn't see a buffer's own toggle or `#+STARTUP: customtime`.
---@param sel table date
---@param inactive? boolean
---@return string
function M.preview(sel, inactive)
  if require("org.config").opts.display_custom_times ~= true then
    return (inactive ~= nil and sel:clone({ active = not inactive }) or sel):to_string()
  end
  local txt = require("org.timestamps").custom_text(sel)
  if sel.end_hour then
    -- the end time goes right after the time, like Emacs
    local e = select(2, txt:find("%d?%d:%d%d"))
    if e then
      txt = txt:sub(1, e) .. string.format("-%02d:%02d", sel.end_hour, sel.end_min or 0) .. txt:sub(e + 1)
    end
  end
  return inactive and "[" .. txt .. "]" or "<" .. txt .. ">"
end

local K = {}
local function key(k)
  if not K[k] then
    K[k] = vim.keycode(k)
  end
  return K[k]
end

--- The date shown at the calendar's cursor when the last date prompt or
--- `goto_calendar` ended (what org-date-from-calendar reads from the
--- *Calendar* buffer), or nil when no calendar was shown yet.
---@type table|nil
M.cursor_date = nil

--- The date under the screen cell (0-based `row`, byte `col`) of the
--- calendar rendered for `sel`, or nil outside the day grid.
---@param sel table date
---@param row integer
---@param col integer
---@return table|nil
function M.date_at(sel, row, col)
  local w = row - 4 -- blank, title, blank, weekday header
  if w < 0 or w > 5 then
    return nil
  end
  local x = col - MARGIN - WEEK
  if x < 0 or x >= 7 * CELL then
    return nil
  end
  local first = date.days_from_civil(sel.year, sel.month, 1)
  local start = first - (date.from_days(first):weekday() - 1)
  local d = date.from_days(start + 7 * w + math.floor(x / CELL))
  return sel:clone({ year = d.year, month = d.month, day = d.day })
end

--- Scroll the calendar by `n` (±3) months, C-v / M-v
--- (org-calendar-scroll-three-months-left/right). Emacs shows three months
--- around the cursor; after the scroll the cursor lands on today when today
--- is among the three months shown, else on the 1st of the new middle
--- month (calendar-scroll-left).
---@param sel table date
---@param n integer
---@param today? table
---@return table
function M.scroll_months(sel, n, today)
  today = today or date.today()
  local m = sel.year * 12 + (sel.month - 1) + n
  local t = today.year * 12 + (today.month - 1)
  if math.abs(t - m) <= 1 then
    return sel:clone({ year = today.year, month = today.month, day = today.day })
  end
  return sel:clone({ year = math.floor(m / 12), month = m % 12 + 1, day = 1 })
end

--- Show the agenda entries of `d` while the date prompt waits
--- (org-calendar-view-entries: Emacs shows the diary entries of the date).
local function view_entries(d)
  local ok, err = pcall(require("org.agenda").open_day, d)
  if not ok then
    utils.warn(tostring(err))
  end
end

--- The windows before a prompt, restored after it when `!` showed entries
--- (Emacs reads the date inside save-window-excursion).
local function save_windows()
  local wins = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    wins[w] = true
  end
  return { win = vim.api.nvim_get_current_win(), buf = vim.api.nvim_get_current_buf(), wins = wins }
end

local function restore_windows(state)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if not state.wins[w] and vim.api.nvim_win_get_config(w).relative == "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  if vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    if vim.api.nvim_buf_is_valid(state.buf) and vim.api.nvim_win_get_buf(state.win) ~= state.buf then
      vim.api.nvim_win_set_buf(state.win, state.buf)
    end
  end
end

--- The Org keys of the calendar opened by `goto_calendar`
--- (org--setup-calendar-bindings): `agenda` shows the agenda of the date
--- (`calendar_to_agenda_key`, org-calendar-goto-agenda), `diary` adds a
--- diary entry for it (`calendar_insert_diary_entry_key`) when
--- `agenda.diary_entry_file` is an Org file. Keys as typed (keycodes).
---@return { agenda?: string, diary?: string }
function M.calendar_keys()
  local o = require("org.config").opts
  local out = {}
  local k = o.calendar_to_agenda_key
  if k == "default" then
    out.agenda = "c"
  elseif type(k) == "string" and k ~= "" then
    out.agenda = vim.keycode(k)
  end
  local target = (o.agenda or {}).diary_entry_file
  local d = o.calendar_insert_diary_entry_key
  if target and target ~= "diary-file" and type(d) == "string" and d ~= "" then
    out.diary = vim.keycode(d)
  end
  return out
end

--- org-calendar-goto-agenda: the agenda (default span) around day `days`.
function M.goto_agenda(days)
  local span = (require("org.config").opts.agenda or {}).span or "week"
  local anchor = require("org.agenda.render").starting_day(span, days)
  require("org.agenda").open_agenda({ anchor = anchor })
end

--- read_date_popup_calendar (or its alias popup_calendar_for_date_prompt)
local function popup_calendar()
  local o = require("org.config").opts
  return o.read_date_popup_calendar ~= false and o.popup_calendar_for_date_prompt ~= false
end

--- `opts.calendar`: the calendar of `goto_calendar`, with its Org keys
--- (`calendar_keys`).
---@param opts? { default?: table, prompt?: string, with_time?: boolean, allow_remove?: boolean, inactive?: boolean, calendar?: boolean }
---@return table|nil
function M.pick(opts)
  opts = opts or {}
  if require("org.utils").is_noninteractive() then
    return nil
  end
  local sel = (opts.default or date.today()):clone({ range_end = vim.NIL })
  local initial = sel:to_date_string()
  if opts.with_time and not sel.hour then
    local now = date.now()
    local r = (require("org.config").opts.time_stamp_rounding_minutes or {})[1] or 0
    if r > 1 then
      now = now:add(math.floor(now.min / r + 0.5) * r - now.min, "min")
    end
    if not opts.default and now.hour < (tonumber(require("org.config").opts.extend_today_until) or 0) then
      -- still yesterday (org-read-date): its last minute
      now = now:clone({ hour = 23, min = 59 })
    end
    sel.hour, sel.min = now.hour, now.min
  end

  --- The typed answer with the date moved to in the calendar (Emacs:
  --- org-ans0 plus org-ans2); nil when nothing can be read.
  local function interpret(text)
    -- like Emacs, a date moved to in the calendar is part of the answer
    local answer = text
    if sel:to_date_string() ~= initial then
      answer = text .. " " .. sel:to_date_string()
    end
    local d, futurep = date.read_date_analyze(answer, opts.default)
    if d then
      if not d.hour and sel.hour then
        -- the time of the default date is kept (Emacs pre-fills it)
        d.hour, d.min, d.end_hour, d.end_min = sel.hour, sel.min, sel.end_hour, sel.end_min
      end
      d.repeater = d.repeater or (sel.repeater and vim.deepcopy(sel.repeater))
      d.warning = d.warning or (sel.warning and vim.deepcopy(sel.warning))
    end
    return d, futurep
  end

  if not popup_calendar() then
    -- only the prompt, with the default in brackets (org-read-date's
    -- "Date+time [2026-09-28]: "); an empty answer takes the default
    local timestr = initial
    if opts.with_time and sel.hour then
      timestr = timestr .. string.format(" %02d:%02d", sel.hour, sel.min)
    end
    local prompt = (opts.prompt and (opts.prompt .. " ") or "") .. "Date+time [" .. timestr .. "]: "
    local ok, text = pcall(vim.fn.input, { prompt = prompt, cancelreturn = vim.NIL })
    if not ok or text == vim.NIL or text == nil then
      return nil
    end
    if vim.trim(text) == "" then
      return sel
    end
    local d = interpret(text)
    if not d then
      utils.warn("Cannot parse date: " .. text)
    end
    return d
  end

  local windows = save_windows()
  local viewed = false
  -- one window for the whole session: redrawn in place on every key
  local buf, win
  local function draw(live)
    local ropts, shown = opts, sel
    if live then
      ropts = vim.tbl_extend("force", opts, { live = true, futurep = live.futurep })
      shown = live.date or sel
    end
    local lines, marks = M.render(shown, ropts)
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
  local function finish(result)
    close()
    M.cursor_date = sel:clone()
    if viewed then
      restore_windows(windows)
    end
    return result
  end
  local live_display = require("org.config").opts.read_date_display_live ~= false
  local cal = opts.calendar and M.calendar_keys() or {}
  while true do
    draw()
    local ok, ch = pcall(vim.fn.getcharstr)
    if not ok or ch == "\27" or ch == "\3" or (ch == "q" and ch ~= cal.agenda and ch ~= cal.diary) then
      return finish(nil)
    end
    if ch == cal.agenda or ch == cal.diary then
      -- the calendar's Org keys: the calendar closes (it is modal here)
      local days = sel:days()
      finish(nil)
      if ch == cal.agenda then
        M.goto_agenda(days)
      else
        require("org.agenda.diary_entry").calendar_entry(days)
      end
      return nil
    end
    local typing = ch == "i" or ch == "t"
    if (typing and not live_display) or ch == "T" or ch == "x" or ch == key("<Del>") then
      -- prompts and results appear without the float in the way
      close()
    end
    if ch == "\r" or ch == "\n" then
      return finish(sel)
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
    elseif ch == key("<C-v>") then
      sel = M.scroll_months(sel, 3)
    elseif ch == key("<M-v>") then
      sel = M.scroll_months(sel, -3)
    elseif ch == "." then
      local t = date.today()
      sel = sel:clone({ year = t.year, month = t.month, day = t.day })
    elseif ch == "!" then
      viewed = true
      view_entries(sel)
    elseif ch == key("<LeftMouse>") or ch == key("<MiddleMouse>") then
      -- org-calendar-select-mouse: a click on a day picks it
      local pos = vim.fn.getmousepos()
      local d = win and pos.winid == win and M.date_at(sel, pos.line - 1, pos.column - 1)
      if d then
        sel = d
        return finish(sel)
      end
    elseif typing then
      -- read_date_display_live: the calendar shows what the answer means
      -- while it is typed (org-read-date-display)
      local au
      if live_display then
        au = vim.api.nvim_create_autocmd("CmdlineChanged", {
          pattern = "@",
          callback = function()
            local d, futurep = interpret(vim.fn.getcmdline())
            if win and vim.api.nvim_win_is_valid(win) then
              pcall(draw, { date = d, futurep = futurep })
            end
          end,
        })
      end
      local ok2, text = pcall(vim.fn.input, { prompt = "Date: ", cancelreturn = vim.NIL })
      if au then
        pcall(vim.api.nvim_del_autocmd, au)
      end
      if ok2 and text ~= vim.NIL and text ~= nil then
        local d = interpret(text)
        if d then
          sel = d
          return finish(d)
        end
        utils.warn("Cannot parse date: " .. text)
      end
    elseif ch == "T" then
      local cur = sel:time_string() or ""
      local ok2, text =
        pcall(vim.fn.input, { prompt = "Time (HH:MM[-HH:MM], empty clears): ", default = cur, cancelreturn = vim.NIL })
      if ok2 and text ~= vim.NIL and text ~= nil then
        text = vim.trim(text)
        if text == "" then
          sel = sel:clone({ hour = vim.NIL, min = vim.NIL, end_hour = vim.NIL, end_min = vim.NIL })
        else
          local d = date.read_date(text, sel)
          if d and d.hour then
            sel = sel:clone({
              hour = d.hour,
              min = d.min,
              end_hour = d.end_hour or vim.NIL,
              end_min = d.end_min or vim.NIL,
            })
          else
            utils.warn("Cannot parse time: " .. text)
          end
        end
      end
    elseif (ch == "x" or ch == key("<Del>")) and opts.allow_remove then
      return finish({ remove = true })
    end
  end
end

return M

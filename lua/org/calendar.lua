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

local date = require("org.date")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.calendar")

local function render(sel, opts)
  local today = date.today()
  local first = date.Date.new({ year = sel.year, month = sel.month, day = 1 })
  local lines = {}
  local marks = {}
  local header = string.format("%s %d", date.MONTH_NAMES_LONG[sel.month], sel.year)
  local width = 22
  lines[1] = string.rep(" ", math.floor((width - #header) / 2)) .. header
  lines[2] = " Mo Tu We Th Fr Sa Su"
  marks[#marks + 1] = { 0, 0, #lines[1], "Title" }
  marks[#marks + 1] = { 1, 0, #lines[2], "Comment" }
  local offset = first:weekday() - 1
  local dim = date.days_in_month(sel.year, sel.month)
  local row = string.rep("   ", offset)
  local col_count = offset
  for d = 1, dim do
    local cell = string.format(" %2d", d)
    local start = #row
    row = row .. cell
    local lnum = #lines
    if d == sel.day then
      marks[#marks + 1] = { lnum, start + 1, start + 3, "Visual", true }
    end
    if today.year == sel.year and today.month == sel.month and today.day == d then
      marks[#marks + 1] = { lnum, start + 1, start + 3, "Special" }
    end
    col_count = col_count + 1
    if col_count == 7 then
      lines[#lines + 1] = row
      row, col_count = "", 0
    end
  end
  if row ~= "" then
    lines[#lines + 1] = row
  end
  -- fix marks line numbers: marks were computed with lnum = index before push
  lines[#lines + 1] = ""
  lines[#lines + 1] = " " .. sel:to_string()
  marks[#marks + 1] = { #lines - 1, 0, #lines[#lines], "String" }
  lines[#lines + 1] = ""
  local help = " hjkl move  HL month  JK year  . today"
  lines[#lines + 1] = help
  lines[#lines + 1] = " i type  T time  CR ok" .. (opts.allow_remove and "  x remove" or "") .. "  Esc quit"
  marks[#marks + 1] = { #lines - 2, 0, #lines[#lines - 1], "Comment" }
  marks[#marks + 1] = { #lines - 1, 0, #lines[#lines], "Comment" }
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
  while true do
    local lines, marks = render(sel, opts)
    local buf, win = require("org.ui").float(lines, { title = opts.prompt or "Date", width = 38 })
    for _, m in ipairs(marks) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4], priority = m[5] and 200 or 100 })
    end
    vim.cmd("redraw")
    local ok, ch = pcall(vim.fn.getcharstr)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if not ok or ch == "\27" or ch == "\3" then
      return nil
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

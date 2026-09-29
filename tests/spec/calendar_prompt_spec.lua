-- The date prompt: read_date_popup_calendar, read_date_display_live, the
-- calendar's C-v / M-v, `!` and mouse keys, org-date-from-calendar and
-- edit_timestamp_down_means_later.
local calendar = require("org.calendar")
local config = require("org.config")
local date = require("org.date")

--- Run `fn` with vim.fn.getcharstr returning `keys` one by one; `on_key`
--- (optional) is called before each key with the calendar float's window.
local function with_keys(keys, fn, on_key)
  local getcharstr = vim.fn.getcharstr
  vim.fn.getcharstr = function()
    if on_key then
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then
          on_key(w)
        end
      end
    end
    return table.remove(keys, 1) or "\27"
  end
  local ok, res = pcall(fn)
  vim.fn.getcharstr = getcharstr
  assert(ok, res)
  return res
end

local function stub(tbl, name, value)
  local old = tbl[name]
  tbl[name] = value
  return function()
    tbl[name] = old
  end
end

describe("date prompt without the calendar (read_date_popup_calendar)", function()
  with_config({ read_date_popup_calendar = false })

  it("asks with the default in brackets and reads the answer", function()
    local prompts = {}
    local restore = stub(vim.fn, "input", function(o)
      prompts[#prompts + 1] = o.prompt
      return "2026-10-01"
    end)
    local getcharstr = stub(vim.fn, "getcharstr", function()
      error("the calendar must not be shown")
    end)
    local picked = calendar.pick({ default = date.parse("<2026-09-26 Sat>"), prompt = "Schedule" })
    restore()
    getcharstr()
    -- org-read-date: (concat prompt " " "Date+time [%s]: ")
    eq({ "Schedule Date+time [2026-09-26]: " }, prompts)
    eq("<2026-10-01 Thu>", picked:to_string())
  end)

  it("takes the default for an empty answer and nil when cancelled", function()
    local answer = ""
    local restore = stub(vim.fn, "input", function()
      return answer
    end)
    eq("<2026-09-26 Sat 10:30>", calendar.pick({ default = date.parse("<2026-09-26 Sat 10:30>") }):to_string())
    answer = vim.NIL
    eq(nil, calendar.pick({ default = date.parse("<2026-09-26 Sat>") }))
    restore()
  end)

  it("accepts Emacs's alias popup_calendar_for_date_prompt", function()
    config.opts.read_date_popup_calendar = true
    config.opts.popup_calendar_for_date_prompt = false
    local asked
    local restore = stub(vim.fn, "input", function(o)
      asked = o.prompt
      return "+1d"
    end)
    calendar.pick({ default = date.parse("<2026-09-26 Sat>") })
    restore()
    config.opts.popup_calendar_for_date_prompt = nil
    eq("Date+time [2026-09-26]: ", asked)
  end)
end)

describe("live date interpretation (read_date_display_live)", function()
  local function typed(text, live)
    config.opts.read_date_display_live = live
    local shown
    local win
    local restore_cmdline = stub(vim.fn, "getcmdline", function()
      return text
    end)
    local restore_input = stub(vim.fn, "input", function()
      -- what CmdlineChanged does while the answer is typed
      vim.api.nvim_exec_autocmds("CmdlineChanged", { pattern = "@" })
      if win and vim.api.nvim_win_is_valid(win) then
        shown = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
      end
      return text
    end)
    local picked = with_keys({ "i" }, function()
      return calendar.pick({ default = date.parse("<2026-09-26 Sat>") })
    end, function(w)
      win = w
    end)
    restore_cmdline()
    restore_input()
    config.opts.read_date_display_live = true
    return picked, shown and table.concat(shown, "\n") or nil
  end

  it("shows the answer's date in the calendar while typing", function()
    local picked, shown = typed("2026-10-01", true)
    eq("<2026-10-01 Thu>", picked:to_string())
    ok(shown:find("=> <2026-10-01 Thu>", 1, true))
    ok(shown:find("Thursday, 1 October 2026", 1, true))
    ok(not shown:find("(=>F)", 1, true))
  end)

  it("marks a date moved into the future with (=>F)", function()
    -- a month without a year is taken in the future (read_date_prefer_future)
    local expected = date.read_date("jan 15", date.parse("<2026-09-26 Sat>"))
    local _, shown = typed("jan 15", true)
    ok(shown:find("=> " .. expected:to_string() .. " (=>F)", 1, true))
  end)

  it("keeps the calendar out of the way when off", function()
    local picked, shown = typed("+2d", false)
    eq(nil, shown)
    eq(date.today():add(2, "d"):to_date_string(), picked:to_date_string())
  end)
end)

describe("calendar keys", function()
  it("C-v / M-v scroll three months like Emacs's calendar", function()
    -- Emacs 9.8.10 (calendar-scroll-left-three-months) with today
    -- 2026-09-28: from 09-28 C-v gives 12-01, M-v 06-01; from 01-31 C-v
    -- gives 04-01
    local today = date.parse("<2026-09-28 Mon>")
    eq("2026-12-01", calendar.scroll_months(date.parse("<2026-09-28 Mon>"), 3, today):to_date_string())
    eq("2026-06-01", calendar.scroll_months(date.parse("<2026-09-28 Mon>"), -3, today):to_date_string())
    eq("2026-04-01", calendar.scroll_months(date.parse("<2026-01-31 Sat>"), 3, today):to_date_string())
    -- today among the three months shown: the cursor goes to today
    eq("2026-09-28", calendar.scroll_months(date.parse("<2026-06-10 Wed>"), 3, today):to_date_string())
    -- the time is kept
    eq("<2026-12-01 Tue 10:00>", calendar.scroll_months(date.parse("<2026-09-28 Mon 10:00>"), 3, today):to_string())
    local picked = with_keys({ vim.keycode("<C-v>"), vim.keycode("<M-v>"), "\r" }, function()
      return calendar.pick({ default = date.parse("<2020-02-10 Mon>") })
    end)
    eq("2020-02-01", picked:to_date_string())
  end)

  it("a mouse click on a day selects it", function()
    local float
    local restore = stub(vim.fn, "getmousepos", function()
      -- September 2026 starts on a Tuesday: the second row is 7..13, its
      -- third cell the 9th
      return { winid = float, line = 6, column = 1 + 1 + 4 + 2 * 4 + 1 }
    end)
    local picked = with_keys({ vim.keycode("<LeftMouse>") }, function()
      return calendar.pick({ default = date.parse("<2026-09-26 Sat 10:00>") })
    end, function(w)
      float = w
    end)
    restore()
    eq("<2026-09-09 Wed 10:00>", picked:to_string())
    -- clicks outside the days are ignored
    eq(nil, calendar.date_at(date.parse("<2026-09-26 Sat>"), 1, 10))
    eq(nil, calendar.date_at(date.parse("<2026-09-26 Sat>"), 4, 2))
    eq("2026-08-31", calendar.date_at(date.parse("<2026-09-26 Sat>"), 4, 5):to_date_string())
  end)

  it("! shows the agenda of the date, and the windows come back afterwards", function()
    local buf = org_buffer({ "* H" }, { 1, 0 })
    local win = vim.api.nvim_get_current_win()
    local nwins = #vim.api.nvim_list_wins()
    local agenda = require("org.agenda")
    local shown
    local restore = stub(agenda, "open_day", function(d)
      shown = d:to_date_string()
      vim.cmd("new")
      vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
    end)
    local picked = with_keys({ "l", "!", "l", "\r" }, function()
      return calendar.pick({ default = date.parse("<2026-09-26 Sat>") })
    end)
    restore()
    eq("2026-09-27", shown)
    eq("2026-09-28", picked:to_date_string())
    eq(win, vim.api.nvim_get_current_win())
    eq(buf, vim.api.nvim_get_current_buf())
    eq(nwins, #vim.api.nvim_list_wins())
  end)
end)

describe("date from calendar (org-date-from-calendar)", function()
  after_each(function()
    calendar.cursor_date = nil
  end)

  it("inserts the date the calendar was left on", function()
    org_buffer({ "* H", "" }, { 2, 0 })
    with_keys({ "l", "l", "q" }, function()
      require("org.timestamps").goto_calendar()
    end)
    eq(date.today():add(2, "d"):to_date_string(), calendar.cursor_date:to_date_string())
    require("org.timestamps").insert_today()
    eq(date.today():add(2, "d"):to_string(), vim.api.nvim_get_current_line())
  end)

  it("changes only the date of the timestamp at the cursor", function()
    -- Emacs 9.8.10: calendar on 2026-10-05, C-c < on
    -- <2026-09-01 Tue 10:00 +1w> gives <2026-10-05 Mon 10:00 +1w>; on an
    -- empty line <2026-10-05 Mon>
    local buf = org_buffer({ "* H", "<2026-09-01 Tue 10:00 +1w>", "" }, { 2, 5 })
    calendar.cursor_date = date.parse("<2026-10-05 Mon>")
    require("org.timestamps").insert_today()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    require("org.timestamps").insert_today()
    eq({ "* H", "<2026-10-05 Mon 10:00 +1w>", "<2026-10-05 Mon>" }, buf_lines(buf))
  end)

  it("changes the part of a range under the cursor", function()
    local buf = org_buffer({ "<2026-09-01 Tue>--<2026-09-03 Thu>" }, { 1, 20 })
    calendar.cursor_date = date.parse("<2026-09-10 Thu>")
    require("org.timestamps").insert_today()
    eq({ "<2026-09-01 Tue>--<2026-09-10 Thu>" }, buf_lines(buf))
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    calendar.cursor_date = date.parse("<2026-08-30 Sun>")
    require("org.timestamps").insert_today()
    eq({ "<2026-08-30 Sun>--<2026-09-10 Thu>" }, buf_lines(buf))
  end)
end)

describe("edit_timestamp_down_means_later", function()
  it("swaps S-Up and S-Down on timestamps only", function()
    local buf = org_buffer({ "* [#B] H", "<2026-09-10 Thu>" }, { 2, 10 })
    local context = require("org.context")
    context.shift_up()
    eq("<2026-09-11 Fri>", buf_lines(buf)[2])
    config.opts.edit_timestamp_down_means_later = true
    context.shift_up()
    context.shift_up()
    eq("<2026-09-09 Wed>", buf_lines(buf)[2])
    context.shift_down()
    eq("<2026-09-10 Thu>", buf_lines(buf)[2])
    -- priorities keep their direction
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    context.shift_up()
    config.opts.edit_timestamp_down_means_later = false
    eq("* [#A] H", buf_lines(buf)[1])
  end)
end)

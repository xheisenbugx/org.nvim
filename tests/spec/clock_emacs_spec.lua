-- Clocking behaviour checked against Emacs Org 9.8 (org-clock.el).
local config = require("org.config")
local date = require("org.date")
local clock = require("org.clock")
local files = require("org.files")
local utils = require("org.utils")
local ui = require("org.ui")

vim.g.org_test = true

local function file_buffer(lines)
  local path = vim.fn.tempname() .. ".org"
  vim.fn.writefile(lines, path)
  vim.cmd("enew!")
  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  vim.bo.bufhidden = "hide"
  return vim.api.nvim_get_current_buf(), path
end

--- Replace fields of `tbl` while `fn` runs.
local function with(tbl, fields, fn)
  local saved = {}
  for k, v in pairs(fields) do
    saved[k] = { tbl[k] }
    tbl[k] = v
  end
  local ok, err = pcall(fn)
  for k, v in pairs(saved) do
    tbl[k] = v[1]
  end
  if not ok then
    error(err, 0)
  end
end

--- Run `fn` from a mapping so that it sees v:count = n.
local function with_count(n, fn)
  vim.keymap.set("n", "<Plug>(org-clock-test)", fn)
  vim.api.nvim_feedkeys(n .. vim.keycode("<Plug>(org-clock-test)"), "x", false)
end

local function ago(m)
  return date.now():add(-m, "min"):clone({ active = false })
end

local function ts(d)
  return d:clone({ active = false }):to_string()
end

local function line_of(buf, pat)
  for i, l in ipairs(buf_lines(buf)) do
    if l:match(pat) then
      return i
    end
  end
end

local cfg_saved = vim.deepcopy(config.opts.clock)

local function test(name, fn)
  it(name, function()
    config.opts.clock = vim.deepcopy(cfg_saved)
    config.opts.clock.persist = false
    config.opts.clock.auto_clock_resolution = false
    clock.state, clock.last, clock.history = nil, nil, {}
    clock.default_task, clock.interrupted, clock.leftover = nil, nil, nil
    local ok, err = pcall(fn)
    if clock.state then
      pcall(clock.clock_cancel)
    end
    config.opts.clock = vim.deepcopy(cfg_saved)
    if not ok then
      error(err, 0)
    end
  end)
end

describe("clock in (Emacs)", function()
  test("a numeric into_drawer collects the CLOCK lines once reached", function()
    config.opts.clock.into_drawer = 3
    local old = "CLOCK: [2026-09-20 Sun 10:00]--[2026-09-20 Sun 11:00] =>  1:00"
    local buf = file_buffer({ "* A", old })
    local start = ago(10)
    clock.clock_in(nil, { at = start })
    -- 2 clocks < 3: above the existing line, no drawer
    eq({ "* A", "CLOCK: " .. ts(start), old }, buf_lines(buf))
    clock.clock_out({ at = ago(5) })
    local l2 = buf_lines(buf)[2]
    clock.clock_in(nil, { at = ago(3) })
    eq({ "* A", ":LOGBOOK:", "CLOCK: " .. ts(ago(3)), l2, old, ":END:" }, buf_lines(buf))
  end)

  test("in_resume continues the entry's open clock", function()
    config.opts.clock.in_resume = true
    local start = ago(30)
    local buf = file_buffer({ "* A", ":LOGBOOK:", "CLOCK: " .. ts(start), ":END:" })
    clock.clock_in()
    eq(ts(start), clock.state.start)
    eq({ "* A", ":LOGBOOK:", "CLOCK: " .. ts(start), ":END:" }, buf_lines(buf))
  end)

  test("rounds clock times to rounding_minutes", function()
    config.opts.clock.rounding_minutes = 15
    config.opts.clock.out_remove_zero_time = false
    file_buffer({ "* A" })
    clock.clock_in()
    local s = date.parse(clock.state.start)
    eq(0, s.min % 15)
    ok(s:minutes() <= date.now():minutes())
    clock.clock_out()
    local c = files.get_buffer(0).headlines[1].clocks[1]
    eq(0, c["end"].min % 15)
  end)

  test("marks the default task (16), starts where the last clock stopped (64)", function()
    local buf = file_buffer({ "* A", "* B" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    with_count(16, function()
      clock.clock_in()
    end)
    eq("A", clock.default_task.title)
    eq("A", clock.state.title)
    clock.clock_out({ at = ago(7) })
    vim.api.nvim_win_set_cursor(0, { line_of(buf, "^%* B"), 0 })
    with_count(64, function()
      clock.clock_in()
    end)
    eq("B", clock.state.title)
    eq(ts(ago(7)), clock.state.start)
  end)

  test("offers default, interrupted, current and recent tasks", function()
    local buf = file_buffer({ "* A", "* B", "* C" })
    local f = function()
      return files.get_buffer(buf)
    end
    clock.clock_in({ bufnr = buf, lnum = f().headlines[1].line }, { at = ago(20) })
    clock.mark_default_task({ bufnr = buf, lnum = f().headlines[3].line })
    clock.clock_in({ bufnr = buf, lnum = f().headlines[2].line }, { at = ago(10) })
    eq("A", clock.interrupted.title)
    local keys
    with(ui, {
      menu = function(opts)
        keys = {}
        local pick
        for _, it in ipairs(opts.items) do
          if not it.heading then
            keys[#keys + 1] = it.key .. "=" .. it.label:match("(%S+)$")
            if it.key == "d" then
              pick = it.value
            end
          end
        end
        return pick
      end,
    }, function()
      clock.clock_in_select()
    end)
    eq({ "d=C", "i=A", "c=B", "1=B", "2=A" }, keys)
    eq("C", clock.state.title)
    eq("B", clock.interrupted.title)
  end)

  test("clocking in the running task keeps the clock", function()
    file_buffer({ "* A" })
    clock.clock_in(nil, { at = ago(5) })
    local start = clock.state.start
    eq(nil, clock.clock_in())
    eq(start, clock.state.start)
  end)

  test("clock_in_last and clock_goto use the history", function()
    local buf = file_buffer({ "* A", "text", "* B" })
    clock.clock_in(nil, { at = ago(5) })
    clock.clock_out()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    ok(clock.clock_in_last())
    eq("A", clock.state.title)
    clock.clock_out()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    ok(clock.goto_clock())
    eq(1, vim.api.nvim_win_get_cursor(0)[1])
    eq(buf, vim.api.nvim_get_current_buf())
  end)

  test("asks to start from subtracted (leftover) time", function()
    local buf = file_buffer({ "* A" })
    clock.leftover = ago(12):minutes()
    local asked
    with(utils, {
      confirm = function(msg)
        asked = msg
        return true
      end,
    }, function()
      clock.clock_in()
    end)
    ok(asked:match("You stopped another clock 12 mins ago"), asked)
    eq(ts(ago(12)), clock.state.start)
    eq(nil, clock.leftover)
    local _ = buf
  end)

  test("S-Up on the running clock's timestamp moves the running clock", function()
    local buf = file_buffer({ "* A" })
    clock.clock_in(nil, { at = ago(90) })
    local l = line_of(buf, "^CLOCK:")
    local line = buf_lines(buf)[l]
    -- cursor on the hour
    vim.api.nvim_win_set_cursor(0, { l, (line:find("%d%d:%d%d")) })
    require("org.timestamps").increment(1)
    eq(ts(ago(30)), clock.state.start)
    ok(clock.find_open_clock())
  end)

  test("fires User autocmds", function()
    local seen = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = { "OrgClockInPrepare", "OrgClockIn", "OrgClockOut", "OrgClockCancel" },
      callback = function(ev)
        seen[#seen + 1] = ev.match
      end,
    })
    file_buffer({ "* A" })
    clock.clock_in(nil, { at = ago(5) })
    clock.clock_out()
    clock.clock_in(nil, { at = ago(1) })
    clock.clock_cancel()
    vim.api.nvim_del_autocmd(id)
    eq({ "OrgClockInPrepare", "OrgClockIn", "OrgClockOut", "OrgClockInPrepare", "OrgClockIn", "OrgClockCancel" }, seen)
  end)
end)

describe("clock defaults (Emacs)", function()
  test("keeps 0:00 clock lines unless out_remove_zero_time", function()
    local buf = file_buffer({ "* A" })
    clock.clock_in()
    clock.clock_out()
    ok(buf_lines(buf)[3]:match("^CLOCK: .* =>  0:00$"), buf_lines(buf)[3])
  end)

  test("asks before resuming a clock after a restart", function()
    config.opts.clock.persist_query_resume = true
    local _, path = file_buffer({ "* Running", ":LOGBOOK:", "CLOCK: " .. ts(ago(30)), ":END:" })
    local saved = config.opts.agenda_files
    config.opts.agenda_files = { path }
    local asked
    with(utils, {
      confirm = function(msg)
        asked = msg
        return false
      end,
    }, function()
      clock.restore()
    end)
    eq("Resume clock (Running)?", asked)
    eq(nil, clock.state)
    with(utils, {
      confirm = function()
        return true
      end,
    }, function()
      clock.restore()
    end)
    config.opts.agenda_files = saved
    eq("Running", clock.state.title)
  end)

  test("asks to clock out and saves when quitting", function()
    config.opts.clock.ask_before_exiting = true
    local buf, path = file_buffer({ "* A" })
    clock.clock_in(nil, { at = ago(10) })
    local asked
    with(utils, {
      confirm = function(msg)
        asked = msg
        return true
      end,
    }, function()
      vim.api.nvim_exec_autocmds("VimLeavePre", { group = utils.augroup })
    end)
    eq("Clock out before exiting?", asked)
    eq(nil, clock.state)
    -- the clocked-out entry is saved
    eq(buf_lines(buf), vim.fn.readfile(path))
    ok(vim.fn.readfile(path)[3]:match("=>  0:10$"), vim.inspect(vim.fn.readfile(path)))
  end)
end)

describe("clock statusline and effort (Emacs)", function()
  local lines = {
    "* TODO Task",
    ":PROPERTIES:",
    ":Effort: 2:00",
    ":END:",
    ":LOGBOOK:",
    "CLOCK: [2026-01-05 Mon 10:00]--[2026-01-05 Mon 11:00] =>  1:00",
    ":END:",
  }

  test("counts earlier clocks, per mode_line_total", function()
    file_buffer(lines)
    clock.clock_in(nil, { at = ago(30) })
    eq("⏱ [1:30/2:00] (Task)", clock.statusline())
    eq(90, clock.active().clocked)
    eq(30, clock.active().minutes)
    clock.clock_cancel()
    config.opts.clock.mode_line_total = "current"
    clock.clock_in(nil, { at = ago(30) })
    eq("⏱ [0:30/2:00] (Task)", clock.statusline())
    clock.clock_cancel()
    config.opts.clock.mode_line_total = "auto"
    local buf = file_buffer(vim.list_extend(vim.deepcopy(lines), {}))
    vim.api.nvim_buf_set_lines(buf, 3, 3, false, { ":CLOCK_MODELINE_TOTAL: today" })
    clock.clock_in(nil, { at = ago(30) })
    eq("⏱ [0:30/2:00] (Task)", clock.statusline())
  end)

  test("repeated tasks count from LAST_REPEAT", function()
    local l = vim.deepcopy(lines)
    table.insert(l, 3, ":LAST_REPEAT: [2026-02-01 Sun 09:00]")
    file_buffer(l)
    clock.clock_in(nil, { at = ago(30) })
    eq("⏱ [0:30/2:00] (Task)", clock.statusline())
  end)

  test("string_limit, overrun text and the effort notification", function()
    file_buffer(lines)
    config.opts.clock.string_limit = 18
    clock.clock_in(nil, { at = ago(30) })
    eq("⏱ [1:30/2:00] (Ta…)", clock.statusline())
    config.opts.clock.string_limit = 12
    eq("⏱ [1:30/2:00]", clock.statusline())
    clock.clock_cancel()
    config.opts.clock.string_limit = 0
    config.opts.clock.task_overrun_text = "LATE "
    local got = {}
    config.opts.clock.notification_handler = function(msg)
      got[#got + 1] = msg
    end
    -- 1:00 earlier + 1:10 now > 2:00 effort: notified at once
    clock.clock_in(nil, { at = ago(70) })
    eq({ "Task 'Task' should be finished by now. (2:00)" }, got)
    ok(clock.active().overrun)
    eq("⏱ LATE [2:10/2:00] (Task)", clock.statusline())
    -- only once
    clock._tick()
    eq(1, #got)
  end)

  test("set_effort updates the running clock", function()
    local buf = file_buffer(lines)
    clock.clock_in(nil, { at = ago(30) })
    require("org.properties").set_effort({ bufnr = buf, lnum = 1 }, "3:00")
    eq(180, clock.state.effort)
  end)
end)

describe("resolving clocks (Emacs)", function()
  --- A running clock started 60 minutes ago, idle for the last 20.
  local function running()
    local buf = file_buffer({ "* A" })
    clock.clock_in(nil, { at = ago(60) })
    local b, l = clock.find_open_clock()
    return buf, { bufnr = b, lnum = l, start = date.parse(clock.state.start), active = true }
  end
  local function resolve(c, key, input)
    with(ui, {
      menu = function()
        return key
      end,
    }, function()
      with(utils, {
        input = function()
          return input or ""
        end,
      }, function()
        clock.resolve(c, function()
          return "Idle"
        end, date.now():minutes() - 20, { idle = true })
      end)
    end)
  end
  local function clock_lines(buf)
    return vim.tbl_filter(function(l)
      return l:match("^CLOCK:")
    end, buf_lines(buf))
  end

  test("s subtracts the idle time and clocks in again", function()
    local buf, c = running()
    resolve(c, "s")
    eq({ "CLOCK: " .. ts(date.now()), "CLOCK: " .. ts(ago(60)) .. "--" .. ts(ago(20)) .. " =>  0:40" }, clock_lines(buf))
    eq(ts(date.now()), clock.state.start)
  end)

  test("S subtracts and stays out, the next clock in offers the time", function()
    local buf, c = running()
    resolve(c, "S")
    eq({ "CLOCK: " .. ts(ago(60)) .. "--" .. ts(ago(20)) .. " =>  0:40" }, clock_lines(buf))
    eq(nil, clock.state)
    eq(ago(20):minutes(), clock.leftover)
  end)

  test("k keeps all or some minutes, K then clocks out", function()
    local buf, c = running()
    resolve(c, "k", "")
    eq({ "CLOCK: " .. ts(ago(60)) }, clock_lines(buf))
    eq(ts(ago(60)), clock.state.start)
    resolve(c, "K", "5")
    eq({ "CLOCK: " .. ts(ago(60)) .. "--" .. ts(ago(15)) .. " =>  0:45" }, clock_lines(buf))
    eq(nil, clock.state)
  end)

  test("g: got back N minutes ago", function()
    local buf, c = running()
    resolve(c, "g", "5")
    eq({ "CLOCK: " .. ts(ago(5)), "CLOCK: " .. ts(ago(60)) .. "--" .. ts(ago(20)) .. " =>  0:40" }, clock_lines(buf))
    eq(ts(ago(5)), clock.state.start)
  end)

  test("C cancels the clock", function()
    local buf, c = running()
    resolve(c, "C")
    eq({ "* A" }, buf_lines(buf))
    eq(nil, clock.state)
  end)

  test("keeping a dangling clock resumes it", function()
    local start = ago(30)
    local buf = file_buffer({ "* A", ":LOGBOOK:", "CLOCK: " .. ts(start), ":END:" })
    with(ui, {
      menu = function(opts)
        ok(opts.title:match("^Dangling clock started 30 mins ago: A"), opts.title)
        return "k"
      end,
    }, function()
      with(utils, {
        input = function()
          return ""
        end,
      }, function()
        clock.resolve_clocks(true, {})
      end)
    end)
    eq(ts(start), clock.state.start)
    eq({ "* A", ":LOGBOOK:", "CLOCK: " .. ts(start), ":END:" }, buf_lines(buf))
  end)

  test("closing a dangling clock clocks it out fully, keeping the running clock", function()
    config.opts.clock.out_switch_to_state = "DONE"
    local start = ago(30)
    local buf = file_buffer({ "* TODO A", ":LOGBOOK:", "CLOCK: " .. ts(start), ":END:", "* B" })
    clock.clock_in({ bufnr = buf, lnum = 5 }, { at = ago(5) })
    local running = clock.state.start
    with(ui, {
      menu = function()
        return "K"
      end,
    }, function()
      with(utils, {
        input = function()
          return "10"
        end,
      }, function()
        clock.resolve_clocks(true, {})
      end)
    end)
    local l = buf_lines(buf)
    eq("* DONE A", l[1])
    ok(vim.tbl_contains(l, "CLOCK: " .. ts(start) .. "--" .. ts(ago(20)) .. " =>  0:10"), vim.inspect(l))
    eq("B", clock.state.title)
    eq(running, clock.state.start)
    ok(clock.find_open_clock())
  end)

  test("clocking in resolves dangling clocks first", function()
    config.opts.clock.auto_clock_resolution = "when-no-clock-is-running"
    local buf = file_buffer({ "* A", "* B", ":LOGBOOK:", "CLOCK: " .. ts(ago(40)), ":END:" })
    local titles = {}
    with(ui, {
      menu = function(opts)
        titles[#titles + 1] = opts.title
        return opts.title:match(": B$") and "C" or "i"
      end,
    }, function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      clock.clock_in(nil, { at = ago(1) })
    end)
    ok(vim.tbl_contains(titles, "Dangling clock started 40 mins ago: B"), vim.inspect(titles))
    -- B's clock and its emptied drawer are gone; A has the new clock
    local l = buf_lines(buf)
    eq(5, #l, vim.inspect(l))
    eq("* B", l[5])
    eq("A", clock.state.title)
  end)

  test("idle time asks how to resolve the running clock", function()
    config.opts.clock.idle_time = 10
    local buf = running()
    local asked
    with(clock, {
      user_idle_seconds = function()
        return 20 * 60
      end,
    }, function()
      with(ui, {
        menu = function(opts)
          asked = opts.title
          return "S"
        end,
      }, function()
        clock._tick()
      end)
    end)
    ok(asked and asked:match("^Clocked in & idle for 20%.%d mins: A"), asked)
    eq(nil, clock.state)
    local _ = buf
  end)

  test("auto clock-out after idle seconds", function()
    config.opts.clock.auto_clockout_timer = 1
    with(clock, {
      user_idle_seconds = function()
        return 5
      end,
    }, function()
      file_buffer({ "* A" })
      clock.clock_in(nil, { at = ago(10) })
      ok(vim.wait(3000, function()
        return clock.state == nil
      end, 50))
    end)
  end)
end)

describe("clock display and tables (Emacs)", function()
  local lines = {
    "* This year",
    "CLOCK: [" .. date.today():start_of("year"):to_date_string() .. " Thu 10:00]--["
      .. date.today():start_of("year"):to_date_string()
      .. " Thu 11:30] =>  1:30",
    "* Old",
    "CLOCK: [2001-03-01 Thu 10:00]--[2001-03-01 Thu 12:00] =>  2:00",
  }

  test("display shows this year's sums; C-c C-c removes them", function()
    local buf = org_buffer(lines)
    local msg
    with(utils, {
      notify = function(m)
        msg = m
      end,
    }, function()
      clock.toggle_display(buf)
    end)
    eq("Total file time: 1:30 (1 hours and 30 minutes)", msg)
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true, type = "virt_text" })
    local texts = {}
    for _, m in ipairs(marks) do
      if m[4].virt_text then
        texts[#texts + 1] = m[2] .. ":" .. vim.trim(m[4].virt_text[2][1])
      end
    end
    eq({ "0:1:30" }, texts)
    ok(require("org.context").context_action())
    eq(0, #vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { type = "virt_text" }))
    with(utils, {
      notify = function(m)
        msg = m
      end,
    }, function()
      clock.toggle_display(buf, "untilnow")
    end)
    eq("Total file time: 3:30 (3 hours and 30 minutes)", msg)
  end)

  test("S-arrows on a clocktable line shift its :block", function()
    local cases = {
      { "today", 1, "today+1" },
      { "today", -1, "today-1" },
      { "lastweek", -1, "thisweek-2" },
      { "thisweek-1", 1, "thisweek" },
      { "2026-W53", 1, "2027-W01" },
      { "2026-Q4", 1, "2027-Q1" },
      { "2026-Q1", -1, "2025-Q4" },
      { "2026-12", 1, "2027-01" },
      { "2026-12-31", 1, "2027-01-01" },
      { "2026", -1, "2025" },
    }
    for _, c in ipairs(cases) do
      local buf = org_buffer({ "#+BEGIN: clocktable :maxlevel 1 :block " .. c[1] .. " :scope file", "#+END:", "* A" }, { 1, 0 })
      ok(clock.clocktable_shift(c[2]))
      eq("#+BEGIN: clocktable :maxlevel 1 :block " .. c[3] .. " :scope file", buf_lines(buf)[1], c[1])
      ok(buf_lines(buf)[2]:match("^#%+CAPTION: Clock summary"), buf_lines(buf)[2])
    end
    local buf = org_buffer({ "#+BEGIN: clocktable :block today", "#+END:" }, { 1, 0 })
    ok(require("org.context").shift_left())
    eq("#+BEGIN: clocktable :block today-1", buf_lines(buf)[1])
    org_buffer({ "* A" }, { 1, 0 })
    eq(false, clock.clocktable_shift(1))
  end)

  test("clock_report inserts a subtree table in an entry, a file table before it", function()
    local buf = org_buffer({ "#+TITLE: T", "* A", "text", "CLOCK: [2026-09-23 Wed 10:00]--[2026-09-23 Wed 11:00] =>  1:00" }, { 3, 0 })
    clock.clock_report()
    eq("#+BEGIN: clocktable :scope subtree :maxlevel 2", buf_lines(buf)[4])
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    clock.clock_report()
    eq("#+BEGIN: clocktable :scope file :maxlevel 2", buf_lines(buf)[2])
  end)

  test("column view CLOCKSUM and CLOCKSUM_T", function()
    local today = date.today()
    local y = today:add(-1, "d")
    local function day(d, h)
      return string.format("[%s %s %s]", d:to_date_string(), d:dayname(), h)
    end
    local buf = org_buffer({
      "* A",
      "CLOCK: " .. day(today, "00:00") .. "--" .. day(today, "01:00") .. " =>  1:00",
      "CLOCK: " .. day(y, "10:00") .. "--" .. day(y, "12:00") .. " =>  2:00",
      "** B",
      "CLOCK: [2026-01-01 Thu 10:00]--[2026-01-02 Fri 12:00] => 26:00",
    })
    local hl = files.get_buffer(buf).headlines[1]
    local columns = require("org.columns")
    eq("1d 5:00", columns.value(hl, "CLOCKSUM"))
    eq("1:00", columns.value(hl, "CLOCKSUM_T"))
  end)

  test("clocktable edge parameters", function()
    local buf = org_buffer({
      "* TODO A :x:",
      "CLOCK: [2026-09-23 Wed 10:00]--[2026-09-23 Wed 11:00] =>  1:00",
      "* B",
      "CLOCK: [2026-09-23 Wed 12:00]--[2026-09-23 Wed 12:30] =>  0:30",
    })
    local dblock = require("org.dblock")
    local p = dblock.parse_params(':match "TODO=\\"TODO\\"" :header "#+NAME: t\\n" :lang de :sort (2 . ?T)')
    eq('TODO="TODO"', p.match)
    eq("#+NAME: t\n", p.header)
    local l = clock.clocktable(p, buf)
    eq("#+NAME: t", l[1])
    eq("| Kopfzeile     | Dauer  |", l[2])
    eq("| *Gesamtdauer* | *1:00* |", l[4])
    eq("| A             | 1:00   |", l[6])
    local _, _, text = clock.special_range("2026-Q3")
    eq("3rd quarter of 2026", text)
    _, _, text = clock.special_range("2026-W39")
    eq("week 2026-W39", text)
    _, _, text = clock.special_range("2026-09-23")
    eq("Wednesday, September 23, 2026", text)
    eq(date.today():minutes() - 7 * 1440, clock.matcher_time("<-1w>"))
    eq(date.days_from_civil(2026, 9, 22) * 1440 + 600, clock.matcher_time("<2026-09-22 Tue 10:00>"))
  end)
end)

describe("S-M-arrows on clock lines (Emacs)", function()
  test("adjust the touching clock of the previous task", function()
    local buf, path = file_buffer({
      "* A",
      "CLOCK: [2026-09-23 Wed 09:00]--[2026-09-23 Wed 10:00] =>  1:00",
      "* B",
      "CLOCK: [2026-09-23 Wed 10:00]--[2026-09-23 Wed 11:00] =>  1:00",
    })
    local name = vim.api.nvim_buf_get_name(buf)
    clock.history = { { path = name, title = "B" }, { path = name, title = "A" } }
    local _ = path
    local line = buf_lines(buf)[4]
    -- on the minutes of B's clock-in; one step is time_stamp_rounding_minutes[2]
    vim.api.nvim_win_set_cursor(0, { 4, line:find("10:00") + 3 })
    ok(require("org.context").shift_meta_up())
    eq("CLOCK: [2026-09-23 Wed 10:05]--[2026-09-23 Wed 11:00] =>  0:55", buf_lines(buf)[4])
    eq("CLOCK: [2026-09-23 Wed 09:00]--[2026-09-23 Wed 10:05] =>  1:05", buf_lines(buf)[2])
    -- on A's clock-out: B's clock-in follows
    vim.api.nvim_win_set_cursor(0, { 2, buf_lines(buf)[2]:find("10:05") + 3 })
    ok(clock.timestamps_adjust_closest(-1))
    eq("CLOCK: [2026-09-23 Wed 09:00]--[2026-09-23 Wed 10:00] =>  1:00", buf_lines(buf)[2])
    eq("CLOCK: [2026-09-23 Wed 10:00]--[2026-09-23 Wed 11:00] =>  1:00", buf_lines(buf)[4])
  end)
end)

describe("capture clocking (Emacs)", function()
  local capture = require("org.capture")
  local function run(fn, ...)
    local res
    local args = { ... }
    ok(utils.run(function()
      res = { fn(unpack(args)) }
    end))
    return unpack(res or {})
  end

  test(":clock-in logs the capture time and :clock-resume restarts the interrupted task", function()
    config.opts.clock.out_remove_zero_time = false
    local buf = file_buffer({ "* Work" })
    clock.clock_in(nil, { at = ago(30) })
    local target = vim.fn.tempname() .. ".org"
    utils.writefile(target, { "* Inbox" })
    run(capture.capture, {
      target = target,
      template = "* Captured",
      immediate_finish = true,
      clock_in = true,
      clock_resume = true,
    })
    eq("Work", clock.state.title)
    eq(ts(date.now()), clock.state.start)
    local wl = buf_lines(buf)
    ok(vim.tbl_contains(wl, "CLOCK: " .. ts(ago(30)) .. "--" .. ts(date.now()) .. " =>  0:30"), vim.inspect(wl))
    local tl = vim.api.nvim_buf_get_lines(utils.find_buffer(target), 0, -1, false)
    ok(vim.tbl_contains(tl, "CLOCK: " .. ts(date.now()) .. "--" .. ts(date.now()) .. " =>  0:00"), vim.inspect(tl))
  end)

  test(":clock-keep keeps the clock on the captured entry", function()
    local target = vim.fn.tempname() .. ".org"
    utils.writefile(target, { "* Inbox" })
    run(capture.capture, {
      target = target,
      template = "* Kept",
      immediate_finish = true,
      clock_in = true,
      clock_keep = true,
    })
    eq("Kept", clock.state.title)
  end)
end)

describe("agenda clocking (Emacs)", function()
  local items = require("org.agenda.items")
  local render = require("org.agenda.render")
  local parser = require("org.parser")

  test("clock check reports gaps, overlaps, long and open clocks", function()
    local d = date.today()
    local function c(h1, h2)
      local s = string.format("[%s %s %s]", d:to_date_string(), d:dayname(), h1)
      if not h2 then
        return "CLOCK: " .. s
      end
      return "CLOCK: " .. s .. "--" .. string.format("[%s %s %s]", d:to_date_string(), d:dayname(), h2) .. " =>  0:00"
    end
    local f = parser.parse({
      "* A",
      "SCHEDULED: <" .. d:to_date_string() .. " " .. d:dayname() .. ">",
      c("08:00", "09:00"),
      "- a note",
      "* B",
      c("08:30", "09:30"),
      "* C",
      c("10:00", "11:00"),
      "* D",
      c("11:00", "22:00"),
      "* E",
      c("22:30"),
    }, "/tmp/clockcheck.org")
    local T = d:days()
    -- only the clocked entries, not A's scheduled item
    local by_day = items.agenda({ f }, T, T, { today = T, log_mode = "clockcheck" })
    eq(5, #by_day[T])
    local a
    for _, it in ipairs(by_day[T]) do
      if it.headline.title == "A" then
        a = it
      end
    end
    eq("A - a note", a.title)
    local out = {}
    local b = render.builder()
    render.agenda_block(b, { span = "day" }, {
      files = { f },
      span = "day",
      anchor = T,
      today = T,
      log_mode = "clockcheck",
      time_grid_off = true,
    })
    for _, l in ipairs(b.lines) do
      if l:match("^ Clocking") or l:match("^ No end") then
        out[#out + 1] = vim.trim(l)
      end
    end
    eq({
      "Clocking overlap: 30 minutes",
      "Clocking gap: 30 minutes",
      "Clocking interval is very long: 11:00",
    }, vim.list_slice(out, 1, 3))
    ok(out[4] and out[4]:match("^No end time: %("), vim.inspect(out))
  end)

  test("clock report mode shows a clocktable of the agenda files", function()
    local d = date.today()
    local f = parser.parse({
      "* A",
      string.format("CLOCK: [%s %s 10:00]--[%s %s 11:00] =>  1:00", d:to_date_string(), d:dayname(), d:to_date_string(), d:dayname()),
    }, "/tmp/clockreport.org")
    local b = render.builder()
    render.clock_report(b, { f }, d:days(), d:days())
    -- "ALL *Total time*" in one cell is what Emacs 9.8 writes too
    eq("| File            | Headline         | Time   |", b.lines[1])
    eq("|                 | ALL *Total time* | *1:00* |", b.lines[3])
    eq("| clockreport.org | *File time*      | *1:00* |", b.lines[5])
    eq("|                 | [[file:/tmp/clockreport.org::*A][A]]                | 1:00   |", b.lines[6])
  end)
end)

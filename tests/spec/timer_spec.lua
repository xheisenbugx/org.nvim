local timer = require("org.timer")
local utils = require("org.utils")

local function silence(fn)
  local orig = utils.notify
  local msgs = {}
  utils.notify = function(m)
    msgs[#msgs + 1] = m
  end
  local ok, err = pcall(fn)
  utils.notify = orig
  if not ok then
    error(err, 0)
  end
  return msgs
end

describe("timer", function()
  it("starts with an offset, pauses and inserts", function()
    silence(function()
      timer.start("0:10:00")
      eq(600, timer.value())
      timer.pause_or_continue()
      ok(timer.state.paused_at)
      eq("⏲ 0:10:00 (paused)", timer.statusline())
      local buf = org_buffer({ "x" }, { 1, 0 })
      timer.insert()
      eq("x0:10:00 ", buf_lines(buf)[1])
      timer.stop()
      eq("", timer.statusline())
    end)
  end)

  it("counts down from the entry's Effort and inserts the remaining time", function()
    silence(function()
      local buf = org_buffer({ "* Task", ":PROPERTIES:", ":Effort: 0:30", ":END:", "" }, { 1, 0 })
      ok(timer.countdown())
      eq(1800, timer.state.countdown)
      eq("Task", timer.state.title)
      vim.api.nvim_win_set_cursor(0, { 5, 0 })
      timer.insert()
      eq("0:30:00 ", buf_lines(buf)[5])
      -- a relative timer cannot start while counting down
      eq(nil, timer.start(""))
      timer.stop()
      eq(nil, timer.state)
    end)
  end)

  it("reads M:SS and H:MM:SS like Emacs", function()
    silence(function()
      org_buffer({ "text" }, { 1, 0 })
      timer.countdown("1:30")
      eq(90, timer.state.countdown)
      timer.stop()
      timer.countdown("1:00:00")
      eq(3600, timer.state.countdown)
      timer.stop()
    end)
  end)

  it("notifies when the countdown ends", function()
    local msgs = silence(function()
      org_buffer({ "* Tea" }, { 1, 0 })
      timer.countdown("0:00:01")
      vim.wait(3000, function()
        return timer.state == nil
      end, 50)
    end)
    eq(nil, timer.state)
    ok(vim.tbl_contains(msgs, "Tea: time out"), vim.inspect(msgs))
  end)

  it("reads offsets like org-timer-start and formats with timer.format", function()
    silence(function()
      timer.start("10")
      eq(10, timer.value())
      timer.stop()
      timer.start("1:30")
      eq(90, timer.value())
      require("org.config").opts.timer.format = "[%s] "
      local buf = org_buffer({ "- item" }, { 1, 5 })
      timer.insert()
      require("org.config").opts.timer.format = "%s "
      -- inserted at the cursor even in a list (no new item)
      eq("- item[0:01:30] ", buf_lines(buf)[1])
      timer.stop()
    end)
  end)

  it("timer_item: new timer list, next timer item, error elsewhere", function()
    local msgs = silence(function()
      timer.start("0:00:05")
      local buf = org_buffer({ "notes" }, { 1, 0 })
      timer.insert_item()
      vim.cmd("stopinsert")
      eq("- 0:00:05 :: notes", buf_lines(buf)[1])
      vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "  continued" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      timer.insert_item()
      vim.cmd("stopinsert")
      eq({ "- 0:00:05 :: notes", "  continued", "- 0:00:05 :: " }, buf_lines(buf))
      org_buffer({ "- plain item" }, { 1, 0 })
      eq(nil, timer.insert_item())
      timer.stop()
    end)
    local errs = {}
    local u = require("org.utils")
    local orig = u.error
    u.error = function(m)
      errs[#errs + 1] = m
    end
    silence(function()
      timer.start("")
      org_buffer({ "- plain item" }, { 1, 0 })
      timer.insert_item()
      timer.stop()
    end)
    u.error = orig
    eq({ "This is not a timer list" }, errs)
    local _ = msgs
  end)

  it("text typed after timer_item on an empty line goes after the separator", function()
    silence(function()
      timer.start("0:00:05")
      local buf = org_buffer({ "" }, { 1, 0 })
      vim.api.nvim_feedkeys(vim.keycode("<C-c><C-x>-Ana<Esc>"), "xt", false)
      eq("- 0:00:05 :: Ana", buf_lines(buf)[1])
      timer.stop()
    end)
  end)

  it("shifts timer values in a region", function()
    local buf = org_buffer({ "- 0:01:10 :: a", "- 0:02:00 :: b" }, { 1, 0 })
    silence(function()
      ok(timer.change_times_in_region("", 1, 2))
    end)
    eq({ "- 0:00:00 :: a", "- 0:00:50 :: b" }, buf_lines(buf))
    silence(function()
      timer.change_times_in_region("1:00", 1, 2)
    end)
    eq({ "- 0:01:00 :: a", "- 0:01:50 :: b" }, buf_lines(buf))
  end)

  it("suggests timer.default_timer and reports the remaining time", function()
    local cfg = require("org.config").opts.timer
    cfg.default_timer = "10"
    local seen
    local u = require("org.utils")
    local orig = u.input
    u.input = function(o)
      seen = o.default
      return o.default
    end
    local msgs = silence(function()
      org_buffer({ "text" }, { 1, 0 })
      timer.countdown()
      eq(600, timer.state.countdown)
      timer.show_remaining()
      timer.stop()
    end)
    u.input = orig
    cfg.default_timer = "0"
    eq("10", seen)
    ok(vim.tbl_contains(msgs, "10 minute(s) 0 seconds left before next time out"), vim.inspect(msgs))
  end)
end)

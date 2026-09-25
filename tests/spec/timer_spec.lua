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
end)

local clock = require("org.clock")
local config = require("org.config")
local date = require("org.date")
local ui = require("org.ui")
local utils = require("org.utils")

describe("clock resolution validation (Emacs)", function()
  local saved
  with_config({ clock = vim.tbl_extend("force", config.opts.clock, { persist = false, auto_clock_resolution = false }) })
  before_each(function()
    saved = { menu = ui.menu, input = utils.input }
    clock.state, clock.leftover = nil, nil
  end)
  after_each(function()
    if clock.state then
      clock.clock_cancel()
    end
    ui.menu, utils.input = saved.menu, saved.input
    clock.leftover = nil
  end)

  local function rejects(key, input)
    local start = date.from_time(os.time() - 60 * 60, true):clone({ active = false })
    local lines = { "* Work", "CLOCK: " .. start:to_string() }
    local buf = org_buffer(lines, { 1, 0 })
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".org")
    clock.state = { path = vim.api.nvim_buf_get_name(buf), title = "Work", start = start:to_string() }
    local state = vim.deepcopy(clock.state)
    ui.menu = function()
      return key
    end
    utils.input = function()
      return input
    end
    local success, err = pcall(clock.resolve, {
      bufnr = buf,
      lnum = 2,
      start = start,
      active = true,
    }, function()
      return "Idle"
    end, date.from_time(os.time() - 20 * 60, true):minutes(), { idle = true })
    eq(false, success)
    ok(tostring(err):find("must refer to a time in the past", 1, true), err)
    eq(lines, buf_lines(buf))
    eq(state, clock.state)
    eq(nil, clock.leftover)
  end

  it("rejects keeping more idle minutes than have elapsed without changing the clock", function()
    rejects("K", "60")
  end)

  it("rejects returning a negative number of minutes ago without changing the clock", function()
    rejects("g", "-10")
  end)

  it("reports a rejected dangling-clock resolution as one line instead of raising", function()
    local start = date.from_time(os.time() - 60 * 60, true):clone({ active = false })
    local lines = { "* Work", "CLOCK: " .. start:to_string() }
    local buf = org_buffer(lines, { 1, 0 })
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".org")
    ui.menu = function()
      return "K"
    end
    utils.input = function()
      return "600"
    end
    local errors = {}
    local notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.ERROR then
        errors[#errors + 1] = msg
      end
    end
    local done, result = pcall(clock.resolve_clocks, true, {})
    vim.notify = notify
    ok(done, result)
    eq(false, result)
    eq(1, #errors)
    ok(errors[1]:find("must refer to a time in the past", 1, true) and not errors[1]:find("\n"), errors[1])
    eq(lines, buf_lines(buf))
  end)

  it("rounds a resolution that clocks out now, like a plain clock out", function()
    local real_time, real_now = os.time, date.now
    local now = real_time({ year = 2026, month = 6, day = 1, hour = 10, min = 7, sec = 0 })
    os.time = function(t)
      return t and real_time(t) or now
    end
    date.now = function()
      return date.parse("[2026-06-01 Mon 10:07]")
    end
    local opts = config.opts.clock
    config.opts.clock = vim.tbl_extend("force", opts, { rounding_minutes = 15 })
    local result = {}
    for _, key in ipairs({ "K", "J" }) do
      local buf = org_buffer({ "* Task", "CLOCK: [2026-06-01 Mon 09:00]" }, { 1, 0 })
      vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".org")
      clock.state = { path = vim.api.nvim_buf_get_name(buf), title = "Task", start = "[2026-06-01 Mon 09:00]" }
      ui.menu = function()
        return key
      end
      utils.input = function()
        return ""
      end
      local success, err = pcall(clock.resolve, {
        bufnr = buf,
        lnum = 2,
        start = date.parse("[2026-06-01 Mon 09:00]"),
        active = true,
      }, function()
        return "Idle"
      end, date.parse("[2026-06-01 Mon 09:30]"):minutes(), { idle = true })
      result[key] = success and buf_lines(buf)[2] or tostring(err)
      clock.state = nil
    end
    os.time, date.now, config.opts.clock = real_time, real_now, opts
    eq("CLOCK: [2026-06-01 Mon 09:00]--[2026-06-01 Mon 10:00] =>  1:00", result.K)
    eq("CLOCK: [2026-06-01 Mon 09:00]--[2026-06-01 Mon 10:00] =>  1:00", result.J)
  end)
end)

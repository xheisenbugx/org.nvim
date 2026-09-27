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
end)

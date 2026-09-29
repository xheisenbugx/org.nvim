-- org-customize: the options buffer; org-submit-bug-report.
local config = require("org.config")
local customize = require("org.customize")

local function stub(tbl, name, value)
  local old = tbl[name]
  tbl[name] = value
  return function()
    tbl[name] = old
  end
end

local function goto_line(pattern)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:match(pattern) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return i
    end
  end
  error("no line matching " .. pattern)
end

describe("customize (org-customize)", function()
  after_each(function()
    config.opts.deadline_warning_days = config.defaults.deadline_warning_days
    config.opts.agenda.span = config.defaults.agenda.span
    if customize._buf and vim.api.nvim_buf_is_valid(customize._buf) then
      vim.api.nvim_buf_delete(customize._buf, { force = true })
    end
  end)

  it("reads the options and their documentation from config.lua", function()
    local by = {}
    for _, o in ipairs(customize.options()) do
      by[table.concat(o.path, ".")] = o
    end
    ok(by["deadline_warning_days"])
    eq("Days before a deadline it starts showing up in the agenda.", by["deadline_warning_days"].doc[1])
    eq(true, by["agenda"].section)
    ok(by["agenda.span"] and not by["agenda.span"].section)
    -- an option whose default is nil is listed too
    ok(by["todo_repeat_to_state"])
  end)

  it("lists every option with its value and marks changes", function()
    config.opts.deadline_warning_days = 3
    require("org.actions").run("customize")
    eq("orgcustomize", vim.bo.filetype)
    goto_line("^deadline_warning_days = ")
    eq("deadline_warning_days = 3  [changed]", vim.api.nvim_get_current_line())
    goto_line("^  span = ")
    eq('  span = "week"', vim.api.nvim_get_current_line())
  end)

  it("sets an option for the session and resets it", function()
    customize.open({ option = { "agenda", "span" } })
    eq('  span = "week"', vim.api.nvim_get_current_line())
    local restore = stub(require("org.utils"), "input", function(opts)
      eq('"week"', opts.default)
      return '"day"'
    end)
    customize.change()
    restore()
    eq("day", config.opts.agenda.span)
    eq('  span = "day"  [changed]', vim.api.nvim_get_current_line())
    customize.reset()
    eq("week", config.opts.agenda.span)
    eq('  span = "week"', vim.api.nvim_get_current_line())
  end)

  it("describes the option at the cursor", function()
    customize.open({ option = { "deadline_warning_days" } })
    local lines = customize.describe(customize._rows[vim.api.nvim_win_get_cursor(0)[1]])
    eq("deadline_warning_days", lines[1])
    eq("Days before a deadline it starts showing up in the agenda.", lines[2])
    eq("Default: 14", lines[#lines - 1])
    eq("Value:   14", lines[#lines])
  end)
end)

describe("bug report (org-submit-bug-report)", function()
  it("opens a prefilled issue with the versions and the changed options", function()
    config.opts.deadline_warning_days = 5
    local opened
    local r1 = stub(vim.ui, "open", function(url)
      opened = url
    end)
    local r2 = stub(require("org.utils"), "confirm", function()
      return true
    end)
    local r3 = stub(require("org.utils"), "input", function()
      return "Menus break"
    end)
    require("org.bug_report").submit()
    r1()
    r2()
    r3()
    config.opts.deadline_warning_days = config.defaults.deadline_warning_days
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local text = table.concat(lines, "\n")
    -- Emacs's subject: "[BUG] <subject> [<Org version>]"
    eq("# [BUG] Menus break [" .. require("org.version").string(false) .. "]", lines[1])
    ok(text:find("Neovim  : NVIM v", 1, true))
    ok(text:find("Package : org.nvim version", 1, true))
    ok(text:find("deadline_warning_days = 5", 1, true))
    ok(opened:find("^https://github%.com/xheisenbugx/org%.nvim/issues/new%?title=%%5BBUG%%5D%%20Menus%%20break"))
    ok(opened:find("&body=", 1, true))
    vim.cmd("bwipeout!")
  end)

  it("leaves the configuration out when told to", function()
    local r1 = stub(vim.ui, "open", function() end)
    local r2 = stub(require("org.utils"), "confirm", function()
      return false
    end)
    local r3 = stub(require("org.utils"), "input", function()
      return "x"
    end)
    require("org.bug_report").submit()
    r1()
    r2()
    r3()
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    ok(not text:find("current state:", 1, true))
    vim.cmd("bwipeout!")
  end)
end)

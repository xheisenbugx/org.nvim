-- `.` in the agenda (org-agenda-goto-today): when today is in the view the
-- cursor only moves to it; otherwise the view keeps its span and is rebuilt
-- where org-agenda-compute-starting-span starts the span holding today.
local date = require("org.date")
local config = require("org.config")
local utils = require("org.utils")
local view = require("org.agenda.view")
local agenda = require("org.agenda")

-- Saturday 3 October 2026
local T = date.days_from_civil(2026, 10, 3)
local function day(y, m, d)
  return date.days_from_civil(y, m, d)
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/t.org"

local function first_block()
  for _, inf in pairs(view.state.info) do
    return inf
  end
end

local function range()
  local inf = first_block()
  return { inf.from, inf.to }
end

local function open(spec, opts)
  utils.writefile(path, { "* TODO Task", "  SCHEDULED: <2026-10-03 Sat>" })
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
  config.setup(vim.tbl_deep_extend("force", { agenda_files = { path }, org_directory = dir }, opts or {}))
  config.opts.clock.persist = false
  agenda.open(spec)
end

describe("agenda goto today", function()
  local saved_today, saved_today_days, saved_now
  before_each(function()
    saved_today, saved_today_days, saved_now = date.today, date.today_days, date.now
    date.today_days = function()
      return T
    end
    date.today = function()
      return date.from_days(T)
    end
    date.now = function()
      return date.from_days(T, { hour = 10, min = 0 })
    end
  end)
  after_each(function()
    pcall(view.quit, true)
    date.today, date.today_days, date.now = saved_today, saved_today_days, saved_now
    config.setup({})
  end)

  it("in a month view showing today only moves the cursor to today", function()
    open({ type = "agenda", span = "week" })
    view.actions.month_view()
    eq({ day(2026, 10, 1), day(2026, 10, 31) }, range())
    local header = vim.api.nvim_buf_get_lines(0, 0, 1, false)
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
    view.actions.today()
    eq({ day(2026, 10, 1), day(2026, 10, 31) }, range())
    eq(header, vim.api.nvim_buf_get_lines(0, 0, 1, false))
    eq(T, view.day_at_cursor())
    ok(vim.api.nvim_get_current_line():match("^Saturday +3 October 2026"))
  end)

  it("a view starting on today is kept", function()
    -- Emacs starts a month span on today when nothing else asks otherwise
    open({ type = "agenda", span = "month" })
    eq({ T, T + 30 }, range())
    view.actions.today()
    eq({ T, T + 30 }, range())
    eq(T, view.day_at_cursor())
  end)

  local cases = {
    { span = "day", want = { T, T } },
    { span = "week", want = { day(2026, 9, 28), day(2026, 10, 4) } },
    { span = "fortnight", want = { day(2026, 9, 28), day(2026, 10, 11) } },
    { span = "month", want = { day(2026, 10, 1), day(2026, 10, 31) } },
    { span = "year", want = { day(2026, 1, 1), day(2026, 12, 31) } },
    { span = 10, want = { T, T + 9 } },
    { span = 7, want = { day(2026, 9, 28), day(2026, 10, 4) } },
  }
  for _, c in ipairs(cases) do
    it("away from today, a " .. tostring(c.span) .. " span comes back to the span holding today", function()
      open({ type = "agenda", span = c.span })
      view.actions.later()
      view.actions.later()
      ok(first_block().from > T)
      view.actions.today()
      eq(c.want, range())
      eq(T, view.day_at_cursor())
    end)
  end

  it("a week starts on start_on_weekday", function()
    open({ type = "agenda", span = "week" }, { agenda = { start_on_weekday = 6 } })
    view.actions.earlier()
    view.actions.today()
    eq({ T, T + 6 }, range())
    eq(T, view.day_at_cursor())
  end)

  it("works in a block agenda", function()
    open({ blocks = { { type = "todo" }, { type = "agenda", span = "month" } } })
    view.actions.later()
    ok(first_block().from > T)
    view.actions.today()
    eq({ day(2026, 10, 1), day(2026, 10, 31) }, range())
    eq(T, view.day_at_cursor())
  end)
end)

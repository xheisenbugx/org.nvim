-- Agenda commands pinned to Emacs Org 9.8.10: hour / minute date shifts,
-- remote undo, TODO changes with yesterday's time, habit toggles. The
-- expected texts came from Emacs 9.8.10 probes (org-agenda-do-date-later
-- and friends on the same entries).
local date = require("org.date")
local config = require("org.config")
local utils = require("org.utils")
local view = require("org.agenda.view")
local agenda = require("org.agenda")

local today = date.today()
local function ts(offset, extra)
  local s = today:add(offset, "d"):to_string({ brackets = false })
  return "<" .. s .. (extra and (" " .. extra) or "") .. ">"
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
dir = vim.uv.fs_realpath(dir)
local path = dir .. "/c.org"

local function open(lines, opts)
  utils.writefile(path, lines)
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
  config.setup(vim.tbl_deep_extend("force", { agenda_files = { path }, org_directory = dir }, opts or {}))
  config.opts.clock.persist = false
  agenda.open_agenda({ span = "day" })
end

local function goto_title(title)
  local lines = vim.tbl_keys(view.state.line_items)
  table.sort(lines)
  for _, l in ipairs(lines) do
    if view.state.line_items[l].title == title then
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      return l
    end
  end
  error("no line for " .. title)
end

local function source_lines()
  return vim.api.nvim_buf_get_lines(utils.find_buffer(path), 0, -1, false)
end

--- Move the cursor to the first line, as a user motion would.
local function move_away()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
end

local function press(keys)
  vim.cmd('exe "normal ' .. keys:gsub("<", "\\<") .. '"')
end

describe("agenda hour and minute date shifts", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  it("count 4 (C-u) shifts a time by one hour, 16 (C-u C-u) by 5 minutes", function()
    open({ "* A", "  " .. ts(0, "10:00") })
    goto_title("A")
    press("4<S-Right>")
    eq("  " .. ts(0, "11:00"), source_lines()[2])
    -- move away and back so the next key is not a repeat
    move_away()
    goto_title("A")
    press("16<S-Right>")
    eq("  " .. ts(0, "11:05"), source_lines()[2])
  end)

  it("shifts both ends of a time range", function()
    open({ "* C", "  " .. ts(0, "10:00-11:30") })
    goto_title("C")
    press("4<S-Right>")
    eq("  " .. ts(0, "11:00-12:30"), source_lines()[2])
    move_away()
    goto_title("C")
    press("16<S-Left>")
    eq("  " .. ts(0, "10:55-12:25"), source_lines()[2])
  end)

  it("an hour past midnight moves the day", function()
    open({ "* D", "  SCHEDULED: " .. ts(0, "23:30") })
    goto_title("D")
    press("4<S-Right>")
    eq("  SCHEDULED: " .. ts(1, "00:30"), source_lines()[2])
  end)

  it("a date without a time loses a day going one hour earlier", function()
    open({ "* B", "  " .. ts(0) })
    goto_title("B")
    press("4<S-Left>")
    eq("  " .. ts(-1), source_lines()[2])
  end)

  it("right after an hour shift, <S-Right> keeps shifting hours", function()
    open({ "* A", "  " .. ts(0, "10:00") })
    goto_title("A")
    press("4<S-Right>")
    press("<S-Right>")
    eq("  " .. ts(0, "12:00"), source_lines()[2])
    -- after moving the cursor it shifts days again
    move_away()
    goto_title("A")
    press("<S-Right>")
    eq("  " .. ts(1, "12:00"), source_lines()[2])
  end)

  it("date_later_hours / date_earlier_minutes take a count", function()
    open(
      { "* A", "  " .. ts(0, "10:00") },
      { mappings = { agenda = { date_later_hours = "gH", date_earlier_minutes = "gM" } } }
    )
    goto_title("A")
    press("3gH")
    eq("  " .. ts(0, "13:00"), source_lines()[2])
    move_away()
    goto_title("A")
    press("2gM")
    eq("  " .. ts(0, "12:50"), source_lines()[2])
  end)

  it("move_date_from_past_immediately_to_today = false shifts one day", function()
    open({ "* Past", "  " .. ts(-3) }, { agenda = { move_date_from_past_immediately_to_today = false } })
    view.quit(true)
    agenda.open_agenda({ span = "day", anchor = today:days() - 3 })
    goto_title("Past")
    view.actions.date_later()
    eq("  " .. ts(-2), source_lines()[2])
  end)
end)

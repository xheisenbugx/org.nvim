-- org-agenda-write, org-store-agenda-views, org-batch-agenda(-csv).
local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")
vim.g.org_test = true

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/r.org"
local export = require("org.agenda.export")
local view = require("org.agenda.view")

-- Fixture dated on a fixed Friday, 2026-09-25; views are opened on it.
local lines = {
  "* Multiple stamps",
  "  <2026-09-25 Fri 09:00> <2026-09-25 Fri 17:00>",
  "* Call Bob 10:00",
  "  <2026-09-25 Fri>",
  "* TODO Meeting at 14:00-15:00 about stuff",
  "  SCHEDULED: <2026-09-25 Fri>",
  "* TODO [#A] Alpha, with comma :work:",
  "  DEADLINE: <2026-09-25 Fri>",
  "** DONE Child",
}
local FRI = date.days_from_civil(2026, 9, 25)

local function setup(opts)
  utils.writefile(path, lines)
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
  config.setup(vim.tbl_extend("force", { agenda_files = { path }, org_directory = dir }, opts or {}))
  local g = config.opts.agenda.time_grid
  g.separator, g.time_string = "......", "----------------"
  config.opts.agenda.show_current_time_in_grid = false
end

local function day_view()
  require("org.agenda").open_agenda({ span = "day", anchor = FRI })
end

describe("agenda export", function()
  local real_today, real_now
  before_each(function()
    real_today, real_now = date.today, date.now
    date.today = function()
      return date.from_days(FRI)
    end
    date.now = function()
      return date.from_days(FRI, { hour = 12, min = 0 })
    end
  end)
  after_each(function()
    date.today, date.now = real_today, real_now
    pcall(view.quit, true)
  end)

  it("writes CSV records like org-batch-agenda-csv", function()
    setup()
    day_view()
    local csv = vim.tbl_filter(function(l)
      return not l:match("^,")
    end, export.csv_lines())
    -- expected records from Emacs 9.8.10 (org-batch-agenda-csv), same fixture
    eq({
      "r,Multiple stamps,timestamp,,,2026-09-25,9:00......,,,1000,2026-09-25",
      "r,Call Bob,timestamp,,,2026-09-25,10:00......,,,1000,2026-09-25",
      "r,Meeting at about stuff,scheduled,TODO,,2026-09-25,14:00-15:00,Scheduled:,,1000,2026-09-25",
      "r,Multiple stamps,timestamp,,,2026-09-25,17:00......,,,1000,2026-09-25",
      "r,Alpha; with comma,deadline,TODO,work,2026-09-25,,Deadline:,A,2000,2026-09-25",
    }, csv)
    -- time grid lines have an empty category
    local grid = vim.tbl_filter(function(l)
      return l:match("^,")
    end, export.csv_lines())
    eq(",----------------,,,,,8:00......,,,,2026-09-25", grid[1])
  end)

  it("writes the TODO list as CSV without dates", function()
    setup()
    require("org.agenda").open_todo()
    -- Emacs: urgency order, and the time found in the headline
    eq({
      "r,Alpha; with comma,todo,TODO,work,,,,A,2000,",
      "r,Meeting at 14:00-15:00 about stuff,todo,TODO,,,14:00-15:00,,,1000,",
    }, export.csv_lines())
  end)

  it("writes text, org, html and ics files", function()
    setup()
    day_view()
    local txt = dir .. "/a.txt"
    ok(export.write(txt))
    eq(vim.api.nvim_buf_get_lines(view.state.buf, 0, -1, false), utils.readfile(txt))
    local org = dir .. "/a.org"
    ok(export.write(org))
    eq({
      "* Multiple stamps",
      "  <2026-09-25 Fri 09:00> <2026-09-25 Fri 17:00>",
      "* Call Bob 10:00",
      "  <2026-09-25 Fri>",
      "* TODO Meeting at 14:00-15:00 about stuff",
      "  SCHEDULED: <2026-09-25 Fri>",
      "* TODO [#A] Alpha, with comma :work:",
      "  DEADLINE: <2026-09-25 Fri>",
      "** DONE Child",
    }, utils.readfile(org))
    local html = dir .. "/a.html"
    ok(export.write(html))
    local h = table.concat(utils.readfile(html), "\n")
    ok(h:find("<pre>", 1, true) and h:find('class="org%-orgagendaheader">Day%-agenda'), h)
    local ics = dir .. "/a.ics"
    ok(export.write(ics))
    local fd = io.open(ics, "rb")
    local c = fd:read("*a")
    fd:close()
    -- CRLF line ends, like Emacs's iCalendar exporter
    ok(c:find("^BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"), c)
    ok(c:find("DTSTART:20260925T090000\r\nDTEND:20260925T110000\r\nSUMMARY:Multiple stamps", 1, true), c)
    ok(c:find("BEGIN:VTODO\r\nUID:TODO-", 1, true))
    ok(c:find("DUE;VALUE=DATE:20260925", 1, true))
    ok(c:find("PRIORITY:1\r", 1, true), c)
    -- PDF / PostScript need Emacs's ps-print
    local orig = utils.error
    local msg
    utils.error = function(m)
      msg = m
    end
    ok(not export.write(dir .. "/a.pdf"))
    utils.error = orig
    ok(msg:find("not supported"))
  end)

  it("stores views of custom commands with export files", function()
    setup({
      agenda = {
        custom_commands = {
          x = { description = "todo", type = "todo", export_files = { dir .. "/x.txt", dir .. "/x.org" } },
          y = { description = "no files", type = "todo" },
        },
      },
    })
    eq(2, export.store_views())
    ok(utils.readfile(dir .. "/x.txt")[1]:find("Global list of TODO items"))
    eq("* TODO [#A] Alpha, with comma :work:", utils.readfile(dir .. "/x.org")[1])
  end)

  it("prints a batch agenda to stdout", function()
    setup()
    local written
    local orig = io.stdout
    io.stdout = {
      write = function(_, s)
        written = s
      end,
    }
    local ok_, res = pcall(export.batch, "t")
    io.stdout = orig
    ok(ok_, res)
    ok(written:find("^Global list of TODO items of type: ALL"), written)
  end)
end)

local ical = require("org.export.icalendar")
local config = require("org.config")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local dir = root .. "/fixtures/export/icalendar"

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n") .. "\n"
end

--- DTSTAMP is the export time and entries without an ID get a generated UID.
local function normalize(s)
  s = s:gsub("\r\n", "\n")
  s = s:gsub("\nDTSTAMP:[^\n]*", "\nDTSTAMP:X")
  s = s:gsub("\nUID:(%a*%d*%-?)%x%x%x%x%x%x%x%x%-[%x%-]+\n", "\nUID:%1GEN\n")
  return s
end

local function export(name, opts)
  local path = dir .. "/" .. name .. ".org"
  return ical.to_string(vim.fn.readfile(path), vim.tbl_extend("force", { filename = path }, opts or {}))
end

local saved
describe("export icalendar", function()
  before_each(function()
    saved = saved or vim.deepcopy(config.opts.export.icalendar)
    config.opts.babel.evaluate_on_export = false
    config.opts.export.author = "Test User"
    config.opts.export.icalendar = { timezone = "UTC" }
  end)

  it("matches Emacs for events (org-icalendar defaults)", function()
    eq(normalize(read(dir .. "/basic.emacs.ics")), normalize(export("basic")))
  end)

  it("matches Emacs for tasks with include_todo = 'all'", function()
    config.opts.export.icalendar.include_todo = "all"
    eq(normalize(read(dir .. "/todo.emacs.ics")), normalize(export("todo")))
  end)

  it("does not export VTODO components by default", function()
    local out = export("todo")
    ok(not out:find("BEGIN:VTODO", 1, true), out)
    -- the TODO keyword of a deadline event is kept in the summary
    ok(out:find("SUMMARY:DL: TODO Repeat with until", 1, true) == nil)
  end)

  it("cleans and folds strings", function()
    eq("a\\,b\\;c\\\\d\\ne", ical.cleanup_string("a,b;c\\d\ne"))
    local folded = ical.fold_string(string.rep("x", 160))
    local lines = vim.split((folded:gsub("\n$", "")), "\n", { plain = true })
    eq(75, #lines[1])
    eq(" " .. string.rep("x", 74), lines[2])
    eq(" " .. string.rep("x", 11), lines[3])
  end)

  it("converts timestamps like org-icalendar-convert-timestamp", function()
    local p = require("org.export.element").new({})
    local ts = p:parse_timestamp("<2026-09-23 Wed 10:00>", 1)
    eq("DTSTART:20260923T100000", ical.convert_timestamp(ts, "DTSTART"))
    eq("DTEND:20260923T120000", ical.convert_timestamp(ts, "DTEND", true))
    local day = p:parse_timestamp("<2026-12-31 Thu>", 1)
    eq("DTEND;VALUE=DATE:20270101", ical.convert_timestamp(day, "DTEND", true))
    eq("DTSTART;TZID=Europe/Paris:20260923T100000", ical.convert_timestamp(ts, "DTSTART", nil, "Europe/Paris"))
  end)

  it("honours alarm_time, summary prefixes and categories", function()
    config.opts.export.icalendar = {
      timezone = "UTC",
      alarm_time = 10,
      deadline_summary_prefix = "Due: ",
      categories = { "todo-state", "all-tags" },
    }
    local out = ical.to_string({
      "#+FILETAGS: :f:",
      "* Parent :p:",
      "** Deadline :c:",
      "DEADLINE: <2026-10-01 Thu 17:00>",
    })
    ok(out:find("SUMMARY:Due: Deadline", 1, true), out)
    ok(out:find("TRIGGER:-P0DT0H10M0S", 1, true), out)
    ok(out:find("CATEGORIES:f,p,c\n", 1, true), out)
  end)

  it("writes .ics files with CRLF line endings", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    vim.fn.writefile({ "* Event", "<2026-09-23 Wed>" }, tmp .. "/cal.org")
    local out = ical.export_file(tmp .. "/cal.org")
    eq(tmp .. "/cal.ics", out)
    local fd = io.open(out, "rb")
    local content = fd:read("*a")
    fd:close()
    ok(content:find("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n", 1, true), content)
    ok(content:find("X-WR-CALNAME:cal\r\n", 1, true), content)

    config.opts.export.icalendar.combined_agenda_file = tmp .. "/all.ics"
    vim.fn.writefile({ "* Other", "<2026-09-24 Thu>" }, tmp .. "/other.org")
    local combined = ical.combine_agenda_files({ files = { tmp .. "/cal.org", tmp .. "/other.org" } })
    eq(tmp .. "/all.ics", combined)
    local text = read(combined)
    ok(text:find("X-WR-CALNAME:OrgMode", 1, true), text)
    ok(text:find("SUMMARY:Event", 1, true) and text:find("SUMMARY:Other", 1, true), text)
    local _, n = text:gsub("BEGIN:VCALENDAR", "")
    eq(1, n)
    local files = ical.export_agenda_files({ files = { tmp .. "/other.org" } })
    eq({ tmp .. "/other.ics" }, files)
    config.opts.export.icalendar = saved
  end)
end)

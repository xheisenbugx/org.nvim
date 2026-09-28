-- Agenda display options pinned to Emacs Org 9.8.10: entry text, written
-- agendas, hooks, line format options. Expected texts come from Emacs
-- 9.8.10 probes on the same files (noted per test).
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

local dir = vim.uv.fs_realpath((function()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end)())
local path = dir .. "/etext.org"

local function open(lines, opts, spec)
  utils.writefile(path, lines)
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
  config.setup(vim.tbl_deep_extend("force", { agenda_files = { path }, org_directory = dir }, opts or {}))
  config.opts.clock.persist = false
  if spec then
    agenda.open(spec)
  else
    agenda.open_agenda({ span = "day" })
  end
end

local function buf_text()
  return vim.api.nvim_buf_get_lines(view.state.buf, 0, -1, false)
end

--- Lines of the agenda buffer from the first one starting with `prefix`.
local function lines_from(prefix, n)
  local lines = buf_text()
  for i, l in ipairs(lines) do
    if l:sub(1, #prefix) == prefix then
      return vim.list_slice(lines, i, i + n - 1)
    end
  end
  error("no line starting with " .. prefix)
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

local function quiet(fn)
  local notify = utils.notify
  local msgs = {}
  utils.notify = function(m)
    msgs[#msgs + 1] = m
  end
  local ok, err = pcall(fn, msgs)
  utils.notify = notify
  if not ok then
    error(err, 0)
  end
end

local ETEXT = {
  "* TODO Write report",
  "  SCHEDULED: " .. ts(0),
  "  :PROPERTIES:",
  "  :X: 1",
  "  :END:",
  "    First body line with [[https://example.com][a link]]",
  "  Second body line SECRET here",
  "  CLOCK: [2026-09-27 Sun 10:00]--[2026-09-27 Sun 11:00] =>  1:00",
  "",
  "  Third [[file:x.org]]",
  "",
  "** Child",
  "   child text",
}

describe("agenda entry text", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  -- Emacs 9.8.10, org-agenda-entry-text-maxlines 2:
  --   "    >   First body line with [[https://example.com][a link]]"
  --   "    > Second body line SECRET here"
  it("E shows the body without drawers and CLOCK lines, at most maxlines", function()
    open(ETEXT, { agenda = { entry_text_maxlines = 2 } })
    quiet(function(msgs)
      press("E")
      eq("Entry text mode is on (maximum number of lines is 2)", msgs[#msgs])
    end)
    eq({
      "  etext:      Scheduled:  TODO Write report",
      "    >   First body line with [[https://example.com][a link]]",
      "    > Second body line SECRET here",
    }, lines_from("  etext:", 3))
  end)

  -- Emacs 9.8.10, leaders "  | " and exclude regexps ("SECRET *"):
  --   "  |   First body line with [[https://example.com][a link]]"
  --   "  | Second body line here"
  --   "  | "
  --   "  | Third [[file:x.org]]"
  it("uses entry_text_leaders and entry_text_exclude_regexps", function()
    open(ETEXT, {
      agenda = { entry_text_maxlines = 10, entry_text_leaders = "  | ", entry_text_exclude_regexps = { "SECRET *" } },
    })
    quiet(function()
      press("E")
    end)
    eq({
      "  etext:      Scheduled:  TODO Write report",
      "  |   First body line with [[https://example.com][a link]]",
      "  | Second body line here",
      "  | ",
      "  | Third [[file:x.org]]",
    }, lines_from("  etext:", 5))
  end)

  it("E with a count shows that many lines", function()
    open(ETEXT)
    quiet(function(msgs)
      press("1E")
      eq("Entry text mode is on (maximum number of lines is 1)", msgs[#msgs])
    end)
    eq({
      "  etext:      Scheduled:  TODO Write report",
      "    >   First body line with [[https://example.com][a link]]",
    }, lines_from("  etext:", 2))
  end)
end)

describe("written agendas", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  -- Emacs 9.8.10, org-agenda-add-entry-text-maxlines 3, written after E
  -- was turned on (its text is not written):
  --   Day-agenda (W40):
  --   Monday     28 September 2026 W40
  --     etext:      Scheduled:  TODO Write report
  --       >   First body line with [[https://example.com][a link]]
  --       > Second body line here
  --       >
  it("add entry text lines with add_entry_text_maxlines", function()
    open(ETEXT, { agenda = { add_entry_text_maxlines = 3, entry_text_exclude_regexps = { "SECRET *" } } })
    quiet(function()
      press("E")
    end)
    local out = dir .. "/out.txt"
    quiet(function()
      require("org.agenda.export").write(out)
    end)
    local lines = vim.fn.readfile(out)
    eq({
      "  etext:      Scheduled:  TODO Write report",
      "    >   First body line with [[https://example.com][a link]]",
      "    > Second body line here",
      "    > ",
    }, vim.list_slice(lines, 3, 6))
    eq(6, #lines)
  end)

  it("before_write_hook changes the written lines; OrgAgendaBeforeWrite fires", function()
    open(ETEXT, {
      agenda = {
        before_write_hook = function(lines, p)
          table.insert(lines, 1, "Written " .. vim.fn.fnamemodify(p, ":t"))
        end,
      },
    })
    local seen
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "OrgAgendaBeforeWrite",
      callback = function(ev)
        seen = ev.data.lines[1]
      end,
    })
    local out = dir .. "/out2.txt"
    quiet(function()
      require("org.agenda.export").write(out)
    end)
    vim.api.nvim_del_autocmd(id)
    eq("Written out2.txt", vim.fn.readfile(out)[1])
    eq("Written out2.txt", seen)
  end)

  it("export_html_style replaces the style section", function()
    open(ETEXT, { agenda = { export_html_style = '<link rel="stylesheet" href="agenda.css">' } })
    local out = dir .. "/out.html"
    quiet(function()
      require("org.agenda.export").write(out)
    end)
    local html = table.concat(vim.fn.readfile(out), "\n")
    ok(html:find('<link rel="stylesheet" href="agenda.css">', 1, true))
    ok(not html:find("<style", 1, true))
  end)
end)

describe("agenda hooks", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  it("OrgAgendaFinalize after a build, OrgAgendaFilter after filtering", function()
    local events = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = { "OrgAgendaFinalize", "OrgAgendaFilter" },
      callback = function(ev)
        events[#events + 1] = ev.match .. ":" .. ev.data.filter
      end,
    })
    open(ETEXT)
    view.state.filters.category = { "+etext" }
    view.redo()
    view.run_action("redo")
    vim.api.nvim_del_autocmd(id)
    eq({ "OrgAgendaFinalize:", "OrgAgendaFilter:Cat:+etext", "OrgAgendaFinalize:Cat:+etext" }, events)
  end)
end)

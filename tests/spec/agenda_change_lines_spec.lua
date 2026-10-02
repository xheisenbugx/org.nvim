-- After an edit from the agenda, only the lines of the edited entry change
-- (org-agenda-change-all-lines); a date change shows the new date on the
-- line without moving it (org-agenda-show-new-time). `r` rebuilds.
local date = require("org.date")
local config = require("org.config")
local utils = require("org.utils")
local render = require("org.agenda.render")
local view = require("org.agenda.view")
local agenda = require("org.agenda")

local today = date.today()
local function ts(offset, extra)
  local s = today:add(offset, "d"):to_string({ brackets = false })
  return "<" .. s .. (extra and (" " .. extra) or "") .. ">"
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/c.org"

local builds = 0
local orig_view = render.view
render.view = function(...)
  builds = builds + 1
  return orig_view(...)
end

local function open(lines, spec, opts)
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
  builds = 0
end

--- Agenda lines showing `title`, in order.
local function lines_of(title)
  local out = {}
  for l, it in pairs(view.state.line_items) do
    if it.title == title then
      out[#out + 1] = l
    end
  end
  table.sort(out)
  return out
end

local function text(l)
  return vim.api.nvim_buf_get_lines(view.state.buf, l - 1, l, false)[1]
end

local function goto_line(l)
  vim.api.nvim_win_set_cursor(0, { l, 0 })
end

local function source_lines()
  return vim.api.nvim_buf_get_lines(utils.find_buffer(path), 0, -1, false)
end

local function groups(l)
  local out = {}
  for _, h in ipairs(view.state.line_parts[l] or {}) do
    out[h[3]] = true
  end
  return out
end

describe("agenda line updates (org-agenda-change-all-lines)", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  it("t changes every line of the entry, without a rebuild", function()
    open({
      "* TODO Both",
      "  DEADLINE: " .. ts(3) .. " SCHEDULED: " .. ts(0),
      "* TODO Other",
      "  SCHEDULED: " .. ts(0),
    })
    local before = vim.api.nvim_buf_get_lines(view.state.buf, 0, -1, false)
    local both = lines_of("Both")
    eq(2, #both) -- the deadline warning and the scheduled line
    local other = lines_of("Other")[1]
    goto_line(both[2])
    view.actions.todo()
    eq(0, builds)
    ok(source_lines()[1]:find("^%* DONE Both"))
    -- the lines stay where they are, both show the new state
    eq(both, lines_of("Both"))
    for _, l in ipairs(both) do
      ok(text(l):find("DONE Both", 1, true), text(l))
      eq(before[l]:gsub("TODO", "DONE"), text(l))
      ok(groups(l).OrgAgendaDone, "done face")
      ok(groups(l).OrgAgendaDoneKeyword)
      eq("DONE", view.state.line_items[l].todo)
      eq(1, view.state.line_items[l].lnum)
    end
    eq(before[other], text(other))
    eq(#before, vim.api.nvim_buf_line_count(view.state.buf))
    eq(both[2], vim.api.nvim_win_get_cursor(0)[1])
    -- `r` rebuilds: the done deadline reminder is gone
    view.run_action("redo")
    eq(1, builds)
    eq(1, #lines_of("Both"))
  end)

  it("fires OrgAgendaFinalize with the changed lines", function()
    open({ "* TODO Hook", "  SCHEDULED: " .. ts(0) })
    local got
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "OrgAgendaFinalize",
      callback = function(ev)
        got = ev.data
      end,
    })
    local l = lines_of("Hook")[1]
    goto_line(l)
    view.actions.priority_up()
    vim.api.nvim_del_autocmd(id)
    eq({ l }, got and got.lines)
    eq(view.state.buf, got.buf)
  end)

  it("draws the highlights of the visible lines, also after a change", function()
    open({ "* TODO Seen", "  SCHEDULED: " .. ts(0) })
    local l = lines_of("Seen")[1]
    local function attr(word)
      vim.cmd("redraw!")
      local col = text(l):find(word, 1, true)
      local pos = vim.fn.screenpos(view.state.win, l, col)
      return vim.fn.screenattr(pos.row, pos.col)
    end
    local plain = vim.fn.screenattr(vim.fn.screenpos(view.state.win, l, 1).row, 1)
    ok(attr("TODO") ~= plain, "TODO keyword highlighted on screen")
    goto_line(l)
    view.actions.todo()
    ok(attr("DONE") ~= plain, "DONE keyword highlighted on screen")
  end)

  it("t again on the changed line acts on the entry", function()
    open({ "* TODO Task", "  SCHEDULED: " .. ts(0) })
    goto_line(lines_of("Task")[1])
    view.actions.todo()
    view.actions.todo()
    eq("* Task", source_lines()[1])
    ok(not text(lines_of("Task")[1]):find("DONE", 1, true))
    eq(0, builds)
  end)

  it("priority up re-formats the line and its priority highlight", function()
    open({ "* TODO Prio", "  SCHEDULED: " .. ts(0), "* TODO Next", "  SCHEDULED: " .. ts(0) })
    local l = lines_of("Prio")[1]
    goto_line(l)
    view.actions.priority_up()
    eq(0, builds)
    eq("* TODO [#B] Prio", source_lines()[1])
    ok(text(l):find("TODO [#B] Prio", 1, true), text(l))
    local has
    for g in pairs(groups(l)) do
      has = has or g:find("Priority") ~= nil
    end
    ok(has, "priority highlighted")
    -- the line maps follow (the item of the line is the new one)
    eq("B", view.state.line_items[l].priority)
  end)

  it("keeps a DONE entry in the TODO list, with the done face", function()
    open({ "* TODO One", "* TODO Two", "* TODO Three" }, { type = "todo" })
    local l = lines_of("Two")[1]
    local n = vim.api.nvim_buf_line_count(view.state.buf)
    goto_line(l)
    view.actions.todo()
    eq(0, builds)
    eq(l, lines_of("Two")[1])
    ok(text(l):find("DONE Two", 1, true), text(l))
    ok(groups(l).OrgAgendaDone)
    eq(n, vim.api.nvim_buf_line_count(view.state.buf))
  end)

  it("changes the tags of the lines in a tags view", function()
    open({ "* TODO A :work:", "* TODO B :work:" }, { type = "tags", match = "work" })
    local l = lines_of("A")[1]
    goto_line(l)
    local tags = require("org.tags")
    local set_tags = tags.set_tags
    tags.set_tags = function(t)
      return set_tags(t, { "work", "urgent" })
    end
    local ok_, err = pcall(view.actions.set_tags)
    tags.set_tags = set_tags
    ok(ok_, err)
    eq(0, builds)
    ok(text(l):find(":work:urgent:%s*$"), text(l))
    eq({ "work", "urgent" }, view.state.line_items[l].tags)
  end)

  it("removes a line the filter now hides and shifts the others", function()
    open({
      "* TODO A :work:",
      "  SCHEDULED: " .. ts(0),
      "* TODO B :work:",
      "  SCHEDULED: " .. ts(0),
    })
    view.set_tag_filter({ "+work" })
    builds = 0
    local a, b = lines_of("A")[1], lines_of("B")[1]
    ok(a < b)
    local n = vim.api.nvim_buf_line_count(view.state.buf)
    goto_line(a)
    local tags = require("org.tags")
    local set_tags = tags.set_tags
    tags.set_tags = function(t)
      return set_tags(t, { "home" })
    end
    local ok_, err = pcall(view.actions.set_tags)
    tags.set_tags = set_tags
    ok(ok_, err)
    eq(0, builds)
    eq({}, lines_of("A"))
    eq(n - 1, vim.api.nvim_buf_line_count(view.state.buf))
    eq({ b - 1 }, lines_of("B"))
    ok(text(b - 1):find("TODO B", 1, true))
    ok(groups(b - 1).OrgAgendaTodoKeyword)
  end)

  it("a repeating entry done today shows DONE on the line at point", function()
    open({ "* TODO Water", "  SCHEDULED: " .. ts(0, "+1d") })
    local l = lines_of("Water")[1]
    goto_line(l)
    view.actions.todo()
    eq(0, builds)
    eq("* TODO Water", source_lines()[1])
    ok(source_lines()[2]:find(ts(1, "+1d"), 1, true), source_lines()[2])
    ok(text(l):find("DONE Water", 1, true), text(l))
  end)

  it("S-Right shows the new date on the line and keeps it in place", function()
    open({ "* TODO Move", "  SCHEDULED: " .. ts(0), "* TODO Stay", "  SCHEDULED: " .. ts(0) })
    local before = vim.api.nvim_buf_get_lines(view.state.buf, 0, -1, false)
    local l = lines_of("Move")[1]
    goto_line(l)
    view.actions.date_later()
    eq(0, builds)
    eq("  SCHEDULED: " .. ts(1), source_lines()[2])
    eq(before, vim.api.nvim_buf_get_lines(view.state.buf, 0, -1, false))
    eq(" => " .. ts(1) .. " ", view.new_time_at(l))
    eq(nil, view.new_time_at(lines_of("Stay")[1]))
    -- shifting again starts from the new date
    view.actions.date_later()
    eq("  SCHEDULED: " .. ts(2), source_lines()[2])
    eq(" => " .. ts(2) .. " ", view.new_time_at(l))
    -- `r` moves it
    view.run_action("redo")
    eq({}, lines_of("Move"))
  end)

  it("schedule from the TODO list shows ' S => <date>'", function()
    open({ "* TODO Plan" }, { type = "todo" })
    local l = lines_of("Plan")[1]
    goto_line(l)
    local cal = require("org.calendar")
    local pick = cal.pick
    cal.pick = function()
      return today:add(2, "d")
    end
    local ok_, err = pcall(view.actions.schedule)
    cal.pick = pick
    ok(ok_, err)
    eq(0, builds)
    eq("SCHEDULED: " .. ts(2), vim.trim(source_lines()[2]))
    eq(" S => " .. ts(2) .. " ", view.new_time_at(l))
  end)

  it("clock in and out move the clocking highlight", function()
    open({ "* TODO One", "  SCHEDULED: " .. ts(0), "* TODO Two", "  SCHEDULED: " .. ts(0) })
    local one, two = lines_of("One")[1], lines_of("Two")[1]
    goto_line(one)
    view.actions.clock_in()
    eq("OrgAgendaClocking", view.state.line_hl_groups[one])
    goto_line(two)
    view.actions.clock_in()
    eq(nil, view.state.line_hl_groups[one])
    eq("OrgAgendaClocking", view.state.line_hl_groups[two])
    -- the line highlight is drawn, and goes with a plain redraw
    local function attr(l)
      vim.cmd("redraw")
      local pos = vim.fn.screenpos(view.state.win, l, 1)
      return vim.fn.screenattr(pos.row, pos.col)
    end
    vim.wo[view.state.win].cursorline = false
    local plain = attr(one)
    ok(attr(two) ~= plain, "clocking line highlighted")
    view.actions.clock_out()
    eq(nil, view.state.line_hl_groups[two])
    eq(plain, attr(two))
    eq(0, builds)
    ok(text(two):find("TODO Two", 1, true))
  end)
end)

-- How the agenda draws its lines: links, faces, dimming, entry text, tag
-- alignment, the clock report and the column view.
local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")
vim.g.org_test = true

local today = date.today()
local function d(offset)
  return today:add(offset or 0, "d"):to_string({ brackets = false })
end

describe("agenda rendering", function()
  local view = require("org.agenda.view")
  local render = require("org.agenda.render")
  local dir = utils.realpath((function()
    local t = vim.fn.tempname()
    vim.fn.mkdir(t, "p")
    return t
  end)())
  local path = dir .. "/r.org"

  local function open(lines, opts)
    utils.writefile(path, lines)
    local b = utils.find_buffer(path)
    if b then
      vim.api.nvim_buf_delete(b, { force = true })
    end
    config.setup(vim.tbl_deep_extend("force", { agenda_files = { path }, org_directory = dir }, opts or {}))
    config.opts.clock.persist = false
    vim.o.columns = 100
    require("org.agenda").open_agenda({ span = "day" })
  end

  local function lines()
    return vim.api.nvim_buf_get_lines(view.state.buf, 0, -1, false)
  end

  local function find(s)
    for i, l in ipairs(lines()) do
      if l:find(s, 1, true) then
        return i, l
      end
    end
  end

  --- The group drawn on top at the start of `s` in agenda line `i`.
  local function group_at(i, l, s)
    local col = l:find(s, 1, true) - 1
    local best, bp
    for _, h in ipairs(view.state.line_parts[i] or {}) do
      local p = h[4] or 110
      if col >= h[1] and col < h[2] and (bp == nil or p >= bp) then
        best, bp = h[3], p
      end
    end
    return best
  end

  it("reduces the clock report's links to their description and highlights the table", function()
    open({
      "* Project",
      "** TODO Clocked task",
      "  :LOGBOOK:",
      "  CLOCK: [" .. d() .. " 08:00]--[" .. d() .. " 09:00] =>  1:00",
      "  :END:",
    }, { agenda = { start_with_clockreport_mode = true } })
    local widths = {}
    for _, l in ipairs(lines()) do
      if l:match("^|") then
        ok(not l:find("[[", 1, true), l)
        widths[vim.fn.strdisplaywidth(l)] = true
      end
    end
    eq(1, vim.tbl_count(widths))
    local i, l = find("Clocked task")
    ok(l:find("| \\_  Clocked task |", 1, true), l)
    eq("OrgLink", group_at(i, l, "Clocked task"))
    eq("OrgTableSeparator", group_at(i, l, "|"))
    i, l = find("*Total time*")
    eq("OrgBold", group_at(i, l, "*Total time*"))
  end)

  it("uses ui.todo_keyword_faces and ui.tag_faces", function()
    open({
      "#+TODO: TODO WAIT | DONE",
      "* WAIT Waiting thing :urgent:other:",
      "  SCHEDULED: <" .. d() .. ">",
      "* TODO Plain :other:",
      "  SCHEDULED: <" .. d() .. ">",
    }, { ui = { todo_keyword_faces = { WAIT = ":foreground orange" }, tag_faces = { urgent = ":foreground red" } } })
    local hls = require("org.highlights")
    local i, l = find("Waiting thing")
    eq("orgTodoKw_WAIT", group_at(i, l, "WAIT"))
    eq(hls.face_group("orgTagFace_", "urgent"), group_at(i, l, "urgent"))
    eq("OrgAgendaTag", group_at(i, l, "other"))
    eq("OrgAgendaTag", group_at(i, l, ":urgent"))
    ok(next(vim.api.nvim_get_hl(0, { name = "orgTodoKw_WAIT" })) ~= nil)
    i, l = find("Plain")
    eq("OrgAgendaTodoKeyword", group_at(i, l, "TODO"))
    eq("OrgAgendaTag", group_at(i, l, "other"))
  end)

  it("shows the description of a link with brackets in it or an escaped target", function()
    eq("Read Paper [v2] notes today", render.display_title("Read [[https://x.com][Paper [v2] notes]] today"))
    eq("Escaped desc", render.display_title("Escaped [[file:a\\]b.org][desc]]"))
    eq("x a y c", render.display_title("x [[a]] y [[b][c]]"))
    open({
      "* TODO Read [[https://x.com][Paper [v2] notes]] today :a:",
      "  SCHEDULED: <" .. d() .. ">",
    })
    local _, l = find("Paper")
    ok(l:find("TODO Read Paper [v2] notes today", 1, true), l)
  end)

  it("shows link descriptions in the column view's ITEM", function()
    open({
      "#+COLUMNS: %25ITEM %TODO",
      "* TODO Task with [[https://x.com][a link]] :work:",
      "  SCHEDULED: <" .. d() .. ">",
    })
    local cols = require("org.agenda.columns")
    ok(cols.toggle())
    local i = find("Task with")
    eq({ "Task with a link", "TODO" }, cols.cells(i))
    cols.toggle()
  end)

  it("dims the whole line of a blocked task, priority cookie and category included", function()
    open({
      "* TODO [#A] Parent blocked :p:",
      "  SCHEDULED: <" .. d() .. ">",
      "** TODO Child",
    }, { enforce_todo_dependencies = true, agenda = { dim_blocked = true, fontify_priorities = true } })
    local i, l = find("Parent blocked")
    for _, s in ipairs({ "r:", "TODO", "[#A]", "Parent", ":p:" }) do
      eq("OrgAgendaDimmed", group_at(i, l, s), s)
    end
  end)

  it("expands tabs in entry text to the next tab stop", function()
    eq("ab      c", render.untabify("ab\tc"))
    eq("        x", render.untabify("\tx"))
    eq("日本    x", render.untabify("日本\tx"))
    open({
      "* TODO Entry with body",
      "  SCHEDULED: <" .. d() .. ">",
      "  Body line",
      "  \tTabbed line",
    }, { agenda = { start_with_entry_text_mode = true } })
    local _, l = find("Tabbed line")
    eq("    >       Tabbed line", l)
  end)

  it("puts tags one space after the title with tags_column = 0", function()
    open({ "* TODO Short task :work:", "  SCHEDULED: <" .. d() .. ">" }, { agenda = { tags_column = 0 } })
    local _, l = find("Short task")
    ok(l:find("TODO Short task :work:$"), l)
  end)

  it("computes the derived groups again when 'background' changes", function()
    local bg = vim.o.background
    local ah = require("org.agenda.highlights")
    vim.o.background = "dark"
    ah.setup()
    ah.define()
    vim.o.background = "light"
    local habit = vim.api.nvim_get_hl(0, { name = "OrgAgendaHabitClear", link = false })
    eq(0x8270f9, habit.bg)
    local fn = vim.api.nvim_get_hl(0, { name = "Function", link = false })
    eq(fn.fg, vim.api.nvim_get_hl(0, { name = "OrgAgendaDateToday", link = false }).fg)
    -- a group the user defined is left alone
    vim.api.nvim_set_hl(0, "OrgAgendaHabitReady", { bg = "#123456" })
    vim.o.background = "dark"
    eq(0x123456, vim.api.nvim_get_hl(0, { name = "OrgAgendaHabitReady", link = false }).bg)
    eq(0x0e3a8a, vim.api.nvim_get_hl(0, { name = "OrgAgendaHabitClear", link = false }).bg)
    vim.o.background = bg
  end)
end)

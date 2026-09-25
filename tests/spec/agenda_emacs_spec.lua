-- Emacs agenda-buffer commands: view modes, filters, marks, kill, queries.
local date = require("org.date")
local config = require("org.config")
local items = require("org.agenda.items")
local render = require("org.agenda.render")
local parser = require("org.parser")
local utils = require("org.utils")
vim.g.org_test = true

local today = date.today()
local T = today:days()
local function ts(offset, extra, inactive)
  local s = today:add(offset, "d"):to_string({ brackets = false })
  if extra then
    s = s .. " " .. extra
  end
  return inactive and ("[" .. s .. "]") or ("<" .. s .. ">")
end

local lines = {
  "* Project",
  "** TODO Write report",
  "   SCHEDULED: " .. ts(0),
  "   :PROPERTIES:",
  "   :Effort: 1:30",
  "   :END:",
  "   First body line with [[https://example.com][a link]]",
  "   :LOGBOOK:",
  '   - State "TODO"       from              ' .. ts(0, "Mon 08:00", true),
  "   :END:",
  "   Second body line",
  "** TODO Quick call",
  "   SCHEDULED: " .. ts(0),
  "   :PROPERTIES:",
  "   :Effort: 0:15",
  "   :END:",
  "* Other",
  "** TODO Unrelated",
  "   SCHEDULED: " .. ts(0),
  "** Met Bob " .. ts(0, "10:00", true),
  "* Old stuff :ARCHIVE:",
  "** TODO Archived task",
  "   SCHEDULED: " .. ts(0),
}

local function titles(list)
  local out = {}
  for _, it in ipairs(list or {}) do
    out[#out + 1] = it.title
  end
  table.sort(out)
  return out
end

describe("agenda modes (items)", function()
  local file = parser.parse(lines, "/tmp/agenda_emacs.org")
  it("includes inactive timestamps only when asked", function()
    local by_day = items.agenda({ file }, T, T, { today = T })
    ok(not vim.tbl_contains(titles(by_day[T]), "Met Bob " .. ts(0, "10:00", true)))
    by_day = items.agenda({ file }, T, T, { today = T, inactive = true })
    local found
    for _, it in ipairs(by_day[T]) do
      if it.inactive then
        found = it
      end
    end
    ok(found, "inactive item")
    eq(600, found.time)
    -- the state-change note in the logbook counts too, the planning line does not
    local n = 0
    for _, it in ipairs(by_day[T]) do
      if it.inactive then
        n = n + 1
      end
    end
    eq(2, n)
  end)
  it("includes archived trees in archives mode", function()
    local by_day = items.agenda({ file }, T, T, { today = T })
    ok(not vim.tbl_contains(titles(by_day[T]), "Archived task"))
    by_day = items.agenda({ file }, T, T, { today = T, archives = "trees" })
    ok(vim.tbl_contains(titles(by_day[T]), "Archived task"))
    ok(vim.tbl_contains(titles(items.todo({ file }, nil, { archives = true })), "Archived task"))
  end)
  it("log mode 'all' includes state changes", function()
    local by_day = items.agenda({ file }, T, T, { today = T, log_mode = true })
    for _, it in ipairs(by_day[T]) do
      ok(it.type ~= "state")
    end
    by_day = items.agenda({ file }, T, T, { today = T, log_mode = "all" })
    local states = vim.tbl_filter(function(it)
      return it.type == "state"
    end, by_day[T])
    eq(1, #states)
  end)
  it("extracts entry text without drawers", function()
    local hl = file:find_by_title("Write report")
    eq({ "First body line with [[https://example.com][a link]]", "Second body line" }, render.entry_text(hl, 5))
    eq({ "First body line with [[https://example.com][a link]]", "..." }, render.entry_text(hl, 1))
  end)
end)

describe("agenda buffer commands", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/e.org"
  local view = require("org.agenda.view")

  local function open_day()
    utils.writefile(path, lines)
    local b = utils.find_buffer(path)
    if b then
      vim.api.nvim_buf_delete(b, { force = true })
    end
    config.setup({ agenda_files = { path }, org_directory = dir })
    require("org.agenda").open_agenda({ span = "day" })
  end
  local function goto_title(title)
    for l, it in pairs(view.state.line_items) do
      if it.title == title then
        vim.api.nvim_win_set_cursor(0, { l, 0 })
        return l
      end
    end
    error("no line for " .. title)
  end
  local function shown()
    local out = {}
    for _, it in pairs(view.state.line_items) do
      out[#out + 1] = it.title
    end
    table.sort(out)
    return out
  end

  it("toggles entry text, time grid and archives modes", function()
    open_day()
    view.actions.entry_text_mode()
    local text = table.concat(buf_lines(), "\n")
    ok(text:find("\n    > First body line", 1, false), text)
    view.actions.entry_text_mode()
    ok(not table.concat(buf_lines(), "\n"):find("    > First"))
    ok(not vim.tbl_contains(shown(), "Archived task"))
    view.actions.archives_mode()
    ok(vim.tbl_contains(shown(), "Archived task"))
    view.actions.archives_mode()
    ok(not vim.tbl_contains(shown(), "Archived task"))
    view.actions.inactive_mode()
    ok(vim.tbl_contains(shown(), "Met Bob " .. ts(0, "10:00", true)))
    view.actions.inactive_mode()
    -- time grid lines disappear
    local function grid_lines()
      local n = 0
      for _, l in ipairs(buf_lines()) do
        if l:find("┄┄┄┄┄", 1, true) then
          n = n + 1
        end
      end
      return n
    end
    view.actions.inactive_mode()
    ok(grid_lines() > 0)
    view.actions.time_grid()
    eq(0, grid_lines())
    view.actions.time_grid()
    view.quit(true)
  end)

  it("includes archive files in archives files mode", function()
    utils.writefile(path .. "_archive", { "* TODO From archive file", "  SCHEDULED: " .. ts(0) })
    open_day()
    ok(not vim.tbl_contains(shown(), "From archive file"))
    view.actions.archives_files_mode()
    ok(vim.tbl_contains(shown(), "From archive file"))
    ok(vim.tbl_contains(shown(), "Archived task"))
    view.quit(true)
    vim.fn.delete(path .. "_archive")
  end)

  it("filters by effort and top headline", function()
    open_day()
    view.set_effort_filter("<1:00")
    eq({ "Quick call" }, shown())
    view.set_effort_filter(">30")
    eq({ "Unrelated", "Write report" }, shown())
    ok(buf_lines()[1]:find("Effort>0:30", 1, true), buf_lines()[1])
    view.set_effort_filter("")
    goto_title("Quick call")
    view.actions.filter_top_headline()
    eq({ "Quick call", "Write report" }, shown())
    view.actions.filter_top_headline()
    eq(3, #shown())
    view.quit(true)
  end)

  it("marks all, toggles and marks by regexp", function()
    open_day()
    view.actions.mark_all()
    eq(3, vim.tbl_count(view.state.marks))
    view.actions.toggle_mark_all()
    eq(0, vim.tbl_count(view.state.marks))
    eq(1, view.mark_regexp("call"))
    goto_title("Quick call")
    view.actions.toggle_mark()
    eq(0, vim.tbl_count(view.state.marks))
    view.quit(true)
  end)

  it("kills an entry and its source", function()
    open_day()
    goto_title("Unrelated")
    local orig = utils.confirm
    local asked
    utils.confirm = function(msg)
      asked = msg
      return true
    end
    view.actions.kill()
    utils.confirm = orig
    ok(asked and asked:find("2 lines"), asked)
    ok(not vim.tbl_contains(shown(), "Unrelated"))
    ok(not table.concat(utils.readfile(path), "\n"):find("Unrelated"))
    view.quit(true)
  end)

  it("moves between date lines and blocks", function()
    utils.writefile(path, lines)
    config.setup({ agenda_files = { path }, org_directory = dir })
    require("org.agenda").open({ blocks = { { type = "agenda", span = 2 }, { type = "todo" } } })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    view.actions.next_date_line()
    local l1 = vim.api.nvim_win_get_cursor(0)[1]
    ok(view.state.day_lines[l1])
    view.actions.next_date_line()
    local l2 = vim.api.nvim_win_get_cursor(0)[1]
    ok(l2 > l1 and view.state.day_lines[l2])
    view.actions.prev_date_line()
    eq(l1, vim.api.nvim_win_get_cursor(0)[1])
    view.actions.forward_block()
    ok(buf_lines()[vim.api.nvim_win_get_cursor(0)[1]]:find("Global list of TODO"))
    view.actions.backward_block()
    eq(1, vim.api.nvim_win_get_cursor(0)[1])
    view.quit(true)
  end)

  it("manipulates a search query", function()
    utils.writefile(path, lines)
    config.setup({ agenda_files = { path }, org_directory = dir })
    require("org.agenda").open_search("TODO")
    local before = #shown()
    view.manipulate_query("-", false, "call")
    eq(before - 1, #shown())
    eq("+TODO -call", view.state.view.blocks[1].match)
    view.quit(true)
    require("org.agenda").open_tags("+ARCHIVE/TODO")
    view.manipulate_query("-", false, "work")
    eq("+ARCHIVE-work/TODO", view.state.view.blocks[1].match)
    view.quit(true)
  end)

  it("captures with the date at point", function()
    open_day()
    goto_title("Quick call")
    local capture = require("org.capture")
    local orig = capture.prompt
    local got
    capture.prompt = function(opts)
      got = opts
    end
    view.actions.capture()
    capture.prompt = orig
    eq(T, got.date:days())
    view.quit(true)
  end)

  it("finds links of the entry", function()
    open_day()
    goto_title("Write report")
    local t = view.resolve_target(view.item_at_cursor())
    local links = view.entry_links(t)
    eq(1, #links)
    eq("https://example.com", links[1].target)
    view.quit(true)
  end)

  it("restriction lock limits agenda commands to a subtree", function()
    open_day()
    view.quit(true)
    vim.cmd("edit! " .. path)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local agenda = require("org.agenda")
    agenda.set_restriction_lock()
    require("org.agenda").open_agenda({ span = "day" })
    eq({ "Quick call", "Write report" }, shown())
    -- the lock follows edits above the subtree
    view.quit(false)
    vim.cmd("buffer " .. vim.fn.bufnr(path))
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "#+TITLE: x", "" })
    agenda.dispatch("t")
    eq({ "Quick call", "Write report" }, shown())
    agenda.remove_restriction_lock()
    agenda.dispatch("t")
    eq(3, #shown())
    view.quit(true)
    vim.cmd("bwipeout! " .. vim.fn.bufnr(path))
  end)

  it("n shows the agenda and all TODOs, S searches TODO entries only", function()
    open_day()
    view.quit(true)
    local agenda = require("org.agenda")
    agenda.dispatch("n")
    eq(2, #view.state.view.blocks)
    eq("agenda", view.state.view.blocks[1].type)
    eq("todo", view.state.view.blocks[2].type)
    view.quit(true)
    agenda.open_search("Bob", nil, true)
    eq({}, shown())
    agenda.open_search("Bob")
    eq(1, #shown())
    view.quit(true)
  end)

  it("occur fills the quickfix list and cycling visits agenda files", function()
    open_day()
    view.quit(true)
    local agenda = require("org.agenda")
    eq(2, agenda.occur("Effort"))
    eq(2, #vim.fn.getqflist())
    vim.cmd("cclose")
    local other = dir .. "/f.org"
    utils.writefile(other, { "* x" })
    config.setup({ agenda_files = { path, other }, org_directory = dir })
    vim.cmd("edit! " .. path)
    agenda.cycle_files()
    eq(vim.uv.fs_realpath(other), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))
    agenda.cycle_files()
    eq(vim.uv.fs_realpath(path), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))
  end)

  it("E toggles entry text and * marks all (keymaps)", function()
    open_day()
    vim.api.nvim_feedkeys("E", "xt", false)
    ok(view.state.entry_text)
    vim.api.nvim_feedkeys("*", "xt", false)
    eq(3, vim.tbl_count(view.state.marks))
    vim.api.nvim_feedkeys(vim.keycode("<M-*>"), "xt", false)
    eq(0, vim.tbl_count(view.state.marks))
    view.quit(true)
  end)
end)

describe("agenda skip helpers, deadlines and blocked tasks", function()
  local agenda = require("org.agenda")
  local file = parser.parse({
    "* TODO Sched",
    "  SCHEDULED: " .. ts(0),
    "* TODO Dead",
    "  DEADLINE: " .. ts(2),
    "* DONE Done",
    "* TODO Plain",
    "  mentions waiting here",
    "* Parent :p:",
    "** TODO Child",
  }, "/tmp/skip.org")

  it("skip_entry_if and skip_subtree_if", function()
    local function kept(skip)
      local out = {}
      for _, it in ipairs(items.todo({ file }, { "TODO", "DONE" }, { skip = skip })) do
        out[#out + 1] = it.title
      end
      table.sort(out)
      return out
    end
    eq({ "Child", "Done", "Plain" }, kept(agenda.skip_entry_if("scheduled", "deadline")))
    eq({ "Child", "Dead", "Done", "Sched" }, kept(agenda.skip_entry_if("regexp", "waiting")))
    eq({ "Done" }, kept(agenda.skip_entry_if("todo", "todo")))
    eq({ "Child", "Dead", "Plain", "Sched" }, kept(agenda.skip_entry_if("todo", { "DONE" })))
    eq({ "Dead", "Sched" }, kept(agenda.skip_entry_if("nottimestamp")))
    eq({ "Dead", "Done", "Plain", "Sched" }, kept(agenda.skip_subtree_if("regexp", ":p:")))
  end)

  it("hides deadlines and dims blocked tasks", function()
    local by_day = items.agenda({ file }, T, T + 3, { today = T, no_deadlines = true })
    for _, list in pairs(by_day) do
      for _, it in ipairs(list) do
        ok(it.type ~= "deadline")
      end
    end
    config.opts.enforce_todo_dependencies = true
    local blocked = parser.parse({ "* TODO Parent", "** TODO Kid" }, "/tmp/blocked.org")
    local list = items.todo({ blocked })
    local b = render.builder()
    for _, it in ipairs(list) do
      render.add_item(b, it, { width = 80, today = T, dim_blocked = true })
    end
    local dimmed = {}
    for _, h in ipairs(b.hls) do
      if h[4] == "OrgAgendaDimmed" then
        dimmed[h[1] + 1] = true
      end
    end
    eq(2, #b.lines)
    ok(b.lines[1]:find("Parent") and dimmed[1])
    ok(not dimmed[2])
    b = render.builder()
    for _, it in ipairs(list) do
      render.add_item(b, it, { width = 80, today = T, dim_blocked = "invisible" })
    end
    eq(1, #b.lines)
    config.opts.enforce_todo_dependencies = false
  end)
end)

describe("agenda config", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/c.org"
  local view = require("org.agenda.view")
  local clock = require("org.clock")
  local function stamp(offset)
    return "<" .. date.today():add(offset, "d"):to_string({ brackets = false }) .. ">"
  end
  local function open(opts, lines)
    utils.writefile(path, lines)
    local b = utils.find_buffer(path)
    if b then
      vim.api.nvim_buf_delete(b, { force = true })
    end
    config.setup(vim.tbl_extend("force", { agenda_files = { path }, org_directory = dir }, opts))
    config.opts.clock.persist = false
  end
  local function line_of(title)
    for l, it in pairs(view.state.line_items) do
      if it.title == title then
        return l
      end
    end
  end
  before_each(function()
    clock.state = nil
    pcall(view.quit, true)
  end)

  it("honours a top-level agenda.start_day", function()
    open({ agenda = { start_day = "-3d" } }, { "* Past event", "  " .. stamp(-3) })
    require("org.agenda").open_agenda({ span = "day" })
    ok(line_of("Past event"), "event 3 days ago not shown")
  end)

  it("highlights the entry being clocked", function()
    open({}, { "* TODO Clocked task", "  SCHEDULED: " .. stamp(0), "* TODO Other task", "  SCHEDULED: " .. stamp(0) })
    vim.cmd("edit! " .. vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    clock.clock_in()
    require("org.agenda").open_agenda({ span = "day" })
    local ns = vim.api.nvim_create_namespace("org.agenda")
    local function line_hl(l)
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, { l - 1, 0 }, { l - 1, -1 }, { details = true })) do
        if m[4].line_hl_group == "OrgAgendaClocking" then
          return true
        end
      end
      return false
    end
    ok(line_hl(line_of("Clocked task")), "clocked entry not highlighted")
    ok(not line_hl(line_of("Other task")), "other entry highlighted")
  end)
end)

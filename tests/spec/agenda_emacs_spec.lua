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
    -- Emacs 9.8.10 cuts the text at the maximum without a "..." line
    -- (org-agenda-get-some-entry-text)
    eq({ "First body line with [[https://example.com][a link]]" }, render.entry_text(hl, 1))
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
        if l:find("┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄", 1, true) then
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
    -- like the Emacs mode line, the filter is shown in the window bar
    ok(view.filter_desc():find("Effort:+>30", 1, true), view.filter_desc())
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
    -- like Emacs, the source buffer is left modified, not saved
    ok(not table.concat(vim.api.nvim_buf_get_lines(utils.find_buffer(path), 0, -1, false), "\n"):find("Unrelated"))
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
    eq(require("org.utils").realpath(other), require("org.utils").realpath(vim.api.nvim_buf_get_name(0)))
    agenda.cycle_files()
    eq(require("org.utils").realpath(path), require("org.utils").realpath(vim.api.nvim_buf_get_name(0)))
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
    -- "Parent :p:" is no TODO entry, so Emacs never asks about it and
    -- its child stays
    eq({ "Child", "Dead", "Done", "Plain", "Sched" }, kept(agenda.skip_subtree_if("regexp", ":p:")))
  end)

  -- Emacs 9.8.10 org-todo-list with org-agenda-skip-function set to
  -- org-agenda-skip-subtree-if / -entry-if on the same file.
  describe("skip_subtree_if looks at the whole subtree of the entries the view matches", function()
    local tree = parser.parse({
      "* TODO Sched",
      "  SCHEDULED: " .. ts(4),
      "* Parent :p:",
      "** TODO Child",
      "* Work",
      "** TODO a",
      "   SCHEDULED: " .. ts(4),
      "** TODO b",
      "* TODO Parent with done kid",
      "** DONE Done kid",
      "** TODO Open kid",
      "* TODO Proj",
      "** TODO Kid :someday:",
      "* TODO Inact",
      "  SCHEDULED: " .. ts(4, nil, true),
      "* TODO InactDl",
      "  DEADLINE: " .. ts(2, nil, true),
    }, "/tmp/skip_subtree.org")
    local function todos(skip)
      local out = {}
      for _, it in ipairs(items.todo({ tree }, nil, { skip = skip })) do
        out[#out + 1] = it.title
      end
      return table.concat(out, ", ")
    end

    it("subtree conditions", function()
      eq(
        "Sched, Child, a, b, Parent with done kid, Open kid, Inact, InactDl",
        todos(agenda.skip_subtree_if("regexp", ":someday:"))
      )
      eq(
        "Child, b, Parent with done kid, Open kid, Proj, Kid, Inact, InactDl",
        todos(agenda.skip_subtree_if("scheduled"))
      )
      eq("Sched, Child, a, b, Proj, Kid, Inact, InactDl", todos(agenda.skip_subtree_if("todo", "done")))
      eq("Parent with done kid", todos(agenda.skip_subtree_if("nottodo", "done")))
    end)

    it("inactive SCHEDULED/DEADLINE stamps are no dates", function()
      eq(
        "Child, b, Parent with done kid, Open kid, Proj, Kid, Inact, InactDl",
        todos(agenda.skip_entry_if("scheduled"))
      )
      eq(
        "Sched, Child, a, b, Parent with done kid, Open kid, Proj, Kid, Inact, InactDl",
        todos(agenda.skip_entry_if("deadline"))
      )
      eq(
        "Child, b, Parent with done kid, Open kid, Proj, Kid, Inact, InactDl",
        todos(agenda.skip_entry_if("timestamp"))
      )
    end)

    it("asks a tags view about the entries its match selects", function()
      local out = {}
      local pred = require("org.agenda.search").compile("LEVEL=2")
      for _, it in ipairs(items.tags({ tree }, pred, false, { skip = agenda.skip_subtree_if("scheduled") })) do
        out[#out + 1] = it.title
      end
      eq("Child, b, Done kid, Open kid, Kid", table.concat(out, ", "))
    end)

    it("todo_ignore_scheduled/deadlines only look at active stamps", function()
      config.opts.agenda.todo_ignore_scheduled = "future"
      config.opts.agenda.todo_ignore_deadlines = "near"
      local out = {}
      for _, it in ipairs(items.todo({ tree })) do
        out[#out + 1] = it.title
      end
      config.opts.agenda.todo_ignore_scheduled = false
      config.opts.agenda.todo_ignore_deadlines = false
      eq("Child, b, Parent with done kid, Open kid, Proj, Kid, Inact, InactDl", table.concat(out, ", "))
    end)
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
    local function line_hl(l)
      return require("org.agenda.view").state.line_hl_groups[l] == "OrgAgendaClocking"
    end
    ok(line_hl(line_of("Clocked task")), "clocked entry not highlighted")
    ok(not line_hl(line_of("Other task")), "other entry highlighted")
  end)
end)

describe("agenda blocks from planning date ranges (org-agenda-get-blocks)", function()
  local A = date.days_from_civil(2026, 9, 28)
  local function day_entries(lines, d)
    local file = parser.parse(lines, "/tmp/agenda_blocks.org")
    local out = {}
    for _, it in ipairs(items.agenda({ file }, A, A + 2, { today = A })[d] or {}) do
      if it.type == "range" then
        out[#out + 1] = (it.extra or "") .. it.title
      end
    end
    table.sort(out)
    return out
  end

  it("a SCHEDULED or DEADLINE range also gives a block entry on each day", function()
    local lines = {
      "* TODO s",
      "SCHEDULED: <2026-09-28 Mon>--<2026-09-30 Wed>",
      "* TODO d",
      "DEADLINE: <2026-09-28 Mon>--<2026-09-30 Wed>",
    }
    eq({ "(1/3): d", "(1/3): s" }, day_entries(lines, A))
    eq({ "(2/3): d", "(2/3): s" }, day_entries(lines, A + 1))
  end)

  it("a one-day range gets no (n/m) and keeps its time (difftest seed 5792810)", function()
    local file =
      parser.parse({ "* TODO b", "SCHEDULED: <2026-09-30 18:45>--<2026-09-30 Wed>" }, "/tmp/agenda_blocks.org")
    local list = items.agenda({ file }, A + 2, A + 2, { today = A + 2 })[A + 2]
    local block
    for _, it in ipairs(list) do
      if it.type == "range" then
        block = it
      end
    end
    ok(block, "no block entry")
    eq("", block.extra)
    eq("scheduled", block.planning_kind)
    eq(18 * 60 + 45, block.time)
  end)

  it("a SCHEDULED range's time is searched on into the headline (difftest seed 8395844)", function()
    -- org-agenda-format-item looks for a time in DOTIME ("10:45>--<b 08:30")
    -- followed by the headline: "<2026-10-11 Sun 08:30 @@html:<b>" reads
    -- as a timestamp at 08:30, and the entry still sorts at 10:45
    local file = parser.parse(
      { "* @@html:<b>@@ x", "SCHEDULED: <2026-09-28 10:45>--<2026-10-11 Sun 08:30>" },
      "/tmp/agenda_sched_range.org"
    )
    local list = items.agenda({ file }, A, A, { today = A })[A]
    local sched
    for _, it in ipairs(list) do
      if it.type == "scheduled" then
        sched = it
      end
    end
    ok(sched, "no scheduled entry")
    eq(8 * 60 + 30, sched.time)
    eq(10 * 60 + 45, sched.sort_time)
  end)

  it("a range after another stamp on its line starts at that stamp", function()
    -- org-tr-regexp's `<date .*?>` runs over the first stamp's `>`
    eq({}, day_entries({ "* TODO x", "SCHEDULED: <2026-10-12 Mon> DEADLINE: <2026-09-28 Mon>--<2026-09-29 Tue>" }, A))
    eq({}, day_entries({ "* TODO a", "<2026-10-12 Mon> <2026-09-28 Mon>--<2026-09-29 Tue>" }, A))
    local y = { "* TODO y", "SCHEDULED: <2026-09-25 Fri> DEADLINE: <2026-09-28 Mon>--<2026-09-29 Tue>" }
    eq({ "(4/5): y" }, day_entries(y, A))
    eq({ "(5/5): y" }, day_entries(y, A + 1))
  end)
end)

describe("agenda blocks that org-tr-regexp finds (difftest #243)", function()
  local A = date.days_from_civil(2026, 9, 28)
  local function blocks(lines, d)
    local file = parser.parse(lines, "/tmp/agenda_blocks.org")
    local out = {}
    for _, it in ipairs(items.agenda({ file }, d, d, { today = d })[d] or {}) do
      if it.type == "range" then
        out[#out + 1] = it
      end
    end
    return out
  end

  it("a range in a comment or example block counts, not in a src block (seeds 2521020, 2521177)", function()
    for _, block in ipairs({ "comment", "example" }) do
      local list = blocks({
        "* x alpha",
        "#+begin_" .. block,
        "<2025-08-21 Thu>--<2026-10-07 Wed>",
        "#+end_" .. block,
      }, A)
      eq(1, #list, block)
      eq("(404/413): ", list[1].extra)
      ok(list[1].block_range, "an editable block")
    end
    eq(1, #blocks({ "* y", ": <2026-09-01 Tue>--<2026-10-10 12:15>" }, A))
    eq(0, #blocks({ "* z", "#+begin_src sh", "<2025-08-21 Thu>--<2026-10-07 Wed>", "#+end_src" }, A))
    eq(0, #blocks({ "* z", "# <2025-08-21 Thu>--<2026-10-07 Wed>" }, A))
  end)

  it("a range whose start runs over a > takes its time from it (seed 2521173)", function()
    local d = date.days_from_civil(2026, 10, 4)
    local list = blocks({ "* 日本語 delta", "SCHEDULED: <2026-10-04 Sun> 07:15>--<2026-11-20 Fri>" }, d)
    eq(1, #list)
    eq("scheduled", list[1].planning_kind)
    eq(7 * 60 + 15, list[1].time)
    eq("(1/48): ", list[1].extra)
    -- the first time range counts (seed 81)
    d = date.days_from_civil(2026, 9, 30)
    list = blocks({ "* t", "SCHEDULED: <2026-09-30 15:30-16:30 .+2y> 08:00>--<2026-10-15 06:15>" }, d)
    eq(1, #list)
    eq(15 * 60 + 30, list[1].time)
    eq(16 * 60 + 30, list[1].end_time)
  end)
end)

describe("agenda times of date ranges, as Emacs reads them (difftest seeds 765, 8954028)", function()
  local A = date.days_from_civil(2026, 9, 28)
  --- "type time[-end][/sort]" of each entry on day `d` (today Thursday
  --- 2026-10-01, as in Emacs' run), sorted
  local function entries(lines, d)
    local file = parser.parse(lines, "/tmp/agenda_range_times.org")
    local out = {}
    local function hm(m)
      return m and string.format("%d:%02d", math.floor(m / 60), m % 60) or "-"
    end
    for _, it in ipairs(items.agenda({ file }, d, d, { today = A + 3 })[d] or {}) do
      local s = it.type .. " " .. hm(it.time)
      if it.end_time then
        s = s .. "-" .. hm(it.end_time)
      end
      if it.sort_time then
        s = s .. "/" .. hm(it.sort_time)
      end
      out[#out + 1] = s
    end
    table.sort(out)
    return out
  end

  -- org-agenda-get-blocks passes the range as written ("<a>--<b>" on a
  -- day it starts and ends, "<a>" on its first day, "<b>" on its last) to
  -- org-agenda-format-item, which takes a timestamp's time
  -- (org-stamp-time-of-day-regexp: a weekday is needed, and a same-day
  -- end only with the same date and day) or else the first plain time
  it("a one-day range takes the first time in it", function()
    eq({ "range 13:15" }, entries({ "** DONE", "<2026-09-28 Mon>--<2026-09-28 13:15>" }, A))
    eq({ "range 10:00-13:15" }, entries({ "* a", "<2026-09-28 Mon 10:00>--<2026-09-28 Mon 13:15>" }, A))
    eq({ "range 10:00" }, entries({ "* b", "<2026-09-28 Mon 10:00>--<2026-09-28 13:15>" }, A))
    -- the end's time is shown, the entry sorts by the first time
    eq({ "range 13:15/10:00" }, entries({ "* c", "<2026-09-28 10:00>--<2026-09-28 Mon 13:15>" }, A))
  end)

  it("a range's first and last days take their own stamp's time, else the headline's", function()
    local lines = { "* g 8:30 meet", "<2026-09-30 Wed>--<2026-10-01 Thu>" }
    eq({ "range 8:30" }, entries(lines, A + 2))
    eq({ "range 8:30" }, entries(lines, A + 3))
  end)

  -- org-agenda-get-scheduled and -deadlines pass the planning value from
  -- its first " H:MM" on (no closing >)
  it("a SCHEDULED or DEADLINE range takes the first time in it", function()
    local d = { "* d", "SCHEDULED: <2026-09-28 Mon>--<2026-09-30 Wed 11:15>" }
    eq({ "range -", "scheduled 11:15" }, entries(d, A))
    eq({ "range 11:15" }, entries(d, A + 2))
    local e = { "* e", "SCHEDULED: <2026-09-29 Tue 10:00>--<2026-09-29 Tue 13:15>" }
    eq({ "range 10:00-13:15", "scheduled 10:00" }, entries(e, A + 1))
    local i = { "* i", "DEADLINE: <2026-10-03 Sat>--<2026-10-03 Sat 9:15-10:00>" }
    eq({ "deadline 9:15-10:00", "range 9:15-10:00" }, entries(i, A + 5))
  end)

  -- org-tr-regexp's start runs over a `>`: these are one range for Emacs,
  -- and their timestamps no plain timestamp entries (org-at-date-range-p)
  it("a range whose start runs over a > is one entry, at the start's time", function()
    local y = { "* y", "SCHEDULED: <2026-10-02 Fri 06:00> DEADLINE: <2026-09-28 Mon>--<2026-10-02 Fri 09:45>" }
    eq({ "range 6:00", "scheduled 6:00" }, entries(y, A + 4))
    eq({ "deadline 9:45" }, entries(y, A))
    eq({ "range 6:00" }, entries({ "* z", "<2026-10-02 06:00> Mon>--<2026-10-02 09:45>" }, A + 4))
    eq(
      { "range 6:00" },
      entries({ "* x", "<2026-10-02 Fri 06:00> text <2026-09-30 Wed>--<2026-10-02 Fri 09:45>" }, A + 4)
    )
  end)
end)

describe("agenda repeats of a plain timestamp", function()
  -- org-agenda-get-timestamps finds repeats with a regexp whose repeater
  -- ends the stamp ("+1w>"): with a warning delay or a habit's "/2w"
  -- after it, the stamp shows on its own date only (as Emacs shows it)
  local A = date.days_from_civil(2026, 9, 28)
  local function days(stamp)
    local file = parser.parse({ "* x", stamp }, "/tmp/agenda_repeats.org")
    local by_day = items.agenda({ file }, A, A + 6, { today = A + 3 })
    local out = {}
    for d = A, A + 6 do
      if by_day[d] and #by_day[d] > 0 then
        out[#out + 1] = d - A
      end
    end
    return out
  end

  it("repeats only when the repeater ends the stamp", function()
    eq({}, days("<2026-09-24 Thu +1w -4d>"))
    eq({ 3 }, days("<2026-09-24 Thu -4d +1w>"))
    eq({}, days("<2026-09-24 Thu .+1w/2w>"))
    eq({ 0 }, days("<2026-09-28 Mon +1d -1d>"))
    eq({ 0, 1, 2, 3, 4, 5, 6 }, days("<2026-09-28 Mon ++1d>"))
    eq({ 1, 3, 5 }, days("<2026-09-29 Tue 10:00 +2d>"))
  end)
end)

describe("agenda lines of a headline with no title", function()
  -- Emacs trims the headline text: "** TODO" is "TODO", with no space after
  -- the keyword or priority (lines from Emacs' TODO list and tags match)
  local files = require("org.files")
  local path

  local function lines(open)
    vim.fn.writefile({
      "* TODO",
      "* TODO [#A]",
      "* TODO :work:",
      "* TODO [#B] :work:",
      "* DONE",
      "SCHEDULED: <2026-10-01 Thu>",
    }, path)
    files.invalidate(path)
    open(require("org.agenda"))
    local name = vim.fn.fnamemodify(path, ":t:r")
    local got = {}
    for _, l in ipairs(require("org.agenda.view").build(80).lines) do
      if l:find(name .. ":", 1, true) then
        got[#got + 1] = (l:gsub("^%s*[^:]+:%s*", ""))
      end
    end
    vim.cmd("silent! %bwipeout!")
    return got
  end

  before_each(function()
    path = vim.fn.tempname() .. ".org"
    config.setup({ agenda_files = { path } })
  end)

  after_each(function()
    files.invalidate()
    os.remove(path)
  end)

  it("ends the line at the keyword or priority", function()
    local todo = lines(function(a)
      a.open_todo()
    end)
    eq({ "TODO [#A]", "TODO", "TODO [#B]" }, { todo[1], todo[2], todo[4]:match("^(.-)%s+:work:$") })
    eq("TODO", todo[3]:match("^(%S+)%s+:work:$"))
    local day = lines(function(a)
      a.open_day(date.days_from_civil(2026, 10, 1))
    end)
    eq({ "Scheduled:  DONE" }, day)
  end)
end)

describe("agenda lines of a headline that is only tags", function()
  -- "* :work:": Emacs removes the tags from the agenda text only after a
  -- blank (org-agenda-fix-displayed-tags), so they are the title too
  -- (lines from Emacs' week agenda and tags match, whitespace squashed)
  local files = require("org.files")
  local path

  local function lines(open)
    vim.fn.writefile({
      "* :work:",
      "SCHEDULED: <2026-10-01 Thu>",
      "* TODO :home:",
      "* [#A] :work:home:",
      "<2026-10-02 Fri>",
    }, path)
    files.invalidate(path)
    open(require("org.agenda"))
    local name = vim.fn.fnamemodify(path, ":t:r")
    local got = {}
    for _, l in ipairs(require("org.agenda.view").build(80).lines) do
      if l:find(name .. ":", 1, true) then
        got[#got + 1] = vim.trim((l:gsub("^%s*[^:]+:%s*", ""):gsub("%s+", " ")))
      end
    end
    vim.cmd("silent! %bwipeout!")
    return got
  end

  before_each(function()
    path = vim.fn.tempname() .. ".org"
    config.setup({ agenda_files = { path } })
  end)

  after_each(function()
    files.invalidate()
    os.remove(path)
  end)

  it("shows the tags as the title", function()
    eq(
      { "Scheduled: :work: :work:", "[#A] :work:home:" },
      lines(function(a)
        a.open_agenda({ span = "week", anchor = date.days_from_civil(2026, 9, 28) })
      end)
    )
    eq(
      { "[#A] :work:home:", ":work: :work:" },
      lines(function(a)
        a.open_tags("work", false)
      end)
    )
  end)
end)

describe("agenda todo-state sorting across files (:h org-differences)", function()
  -- each entry ranks by its own file's sequence (Emacs ranks both by the
  -- first one's file, an order that depends on the comparisons made)
  it("ranks each entry by the keyword sequence of its file", function()
    local a = parser.parse({ "#+TODO: TODO NEXT | DONE", "* NEXT a-next", "* TODO a-todo" }, "/tmp/sort_a.org")
    local b = parser.parse({ "#+TODO: WAIT TODO | DONE", "* TODO b-todo", "* WAIT b-wait" }, "/tmp/sort_b.org")
    local list = {}
    for _, f in ipairs({ a, b }) do
      for _, hl in ipairs(f.headlines) do
        list[#list + 1] = items.new_item(hl)
      end
    end
    local out = {}
    for _, it in ipairs(items.sort(list, { "todo-state-up" })) do
      out[#out + 1] = it.title
    end
    -- position from the end of each sequence: a-todo, b-wait 3rd; a-next, b-todo 2nd
    eq({ "a-todo", "b-wait", "a-next", "b-todo" }, out)
  end)
end)

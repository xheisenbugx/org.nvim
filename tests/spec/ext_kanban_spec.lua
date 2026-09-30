local date = require("org.date")
local utils = require("org.utils")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function ts(offset, extra)
  local s = date.today():add(offset, "d"):to_string({ brackets = false })
  return "<" .. s .. (extra and (" " .. extra) or "") .. ">"
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/board.org"

local LINES = {
  "#+CATEGORY: board",
  "* TODO Low task :home:",
  "* TODO [#A] Urgent task :work:",
  "  DEADLINE: " .. ts(-1),
  "* NEXT Ship it :work:oss:",
  "  DEADLINE: " .. ts(3),
  "  :PROPERTIES:",
  "  :Effort: 2:30",
  "  :END:",
  "* WAITING Feedback",
  "* DONE Finished",
  "* Project",
  "** TODO Child one",
  "** NEXT Child two :work:",
  "* TODO Water plants",
  "  SCHEDULED: " .. ts(0, "+1d"),
}

local function write(lines)
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
  utils.writefile(path, lines or LINES)
  require("org.files").invalidate(path)
end

local function setup(ext, extra)
  require("org").setup(vim.tbl_extend("force", {
    org_directory = dir,
    agenda_files = { path },
    todo_keywords = { "TODO NEXT WAITING | DONE CANCELLED" },
    extensions = ext ~= nil and { kanban = ext } or nil,
  }, extra or {}))
end

local function restore()
  require("org").setup({
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
  })
end

local kanban = require("org.extensions.kanban")

local function names(col)
  return vim.tbl_map(function(c)
    return c.title
  end, col.cards)
end

local function col_names(st)
  return vim.tbl_map(function(c)
    return c.name
  end, st.cols)
end

local function column(st, name)
  for _, c in ipairs(st.cols) do
    if c.name == name then
      return c
    end
  end
end

local function file_lines()
  local b = utils.find_buffer(path)
  return b and buf_lines(b) or utils.readfile(path)
end

describe("kanban extension", function()
  after_each(function()
    kanban.close()
    restore()
  end)

  it("is off by default", function()
    setup(nil)
    eq(nil, require("org.actions").list.kanban_open)
    eq(nil, require("org.commands").extra.kanban)
    eq(nil, require("org.config").opts.mappings.global.kanban_open)
  end)

  it("registers its actions, command and key when enabled", function()
    setup({})
    ok(require("org.actions").list.kanban_open)
    ok(require("org.actions").list.kanban_buffer)
    ok(require("org.actions").list.kanban_subtree)
    ok(require("org.commands").extra.kanban)
    eq("<prefix>Vk", require("org.config").opts.mappings.global.kanban_open)
  end)
end)

describe("kanban board", function()
  before_each(function()
    write()
    setup({}, { log_done = "time" })
  end)
  after_each(function()
    kanban.close()
    restore()
  end)

  it("has a column per TODO keyword by default", function()
    local st = kanban.open()
    eq({ "TODO", "NEXT", "WAITING", "DONE", "CANCELLED" }, col_names(st))
    eq(4, #column(st, "TODO").cards)
    eq({ "Ship it", "Child two" }, names(column(st, "NEXT")))
    eq({ "Finished" }, names(column(st, "DONE")))
  end)

  it("sorts cards by priority, then deadline", function()
    local st = kanban.open()
    eq({ "Urgent task", "Low task", "Child one", "Water plants" }, names(column(st, "TODO")))
  end)

  it("keeps file order with sort = file", function()
    setup({ sort = "file" })
    local st = kanban.open()
    eq({ "Low task", "Urgent task", "Child one", "Water plants" }, names(column(st, "TODO")))
  end)

  it("groups keywords into named columns with WIP limits and hides DONE columns", function()
    setup({ columns = { "TODO", { "NEXT", "WAITING", name = "Doing", wip = 2 }, "DONE" }, show_done = false })
    local st = kanban.open()
    eq({ "TODO", "Doing" }, col_names(st))
    local doing = column(st, "Doing")
    eq(3, #doing.cards)
    eq(2, doing.wip)
    local lines = buf_lines(st.buf)
    ok(table.concat(lines, "\n"):find("Doing  3/2 !", 1, true), "WIP header")
    -- the over-limit count is in the error group
    local found = false
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, -1, 0, -1, { details = true })) do
      if m[4].hl_group == "OrgKanbanWipExceeded" then
        found = true
      end
    end
    ok(found, "WIP exceeded highlight")
  end)

  it("takes WIP limits from the wip option", function()
    setup({ wip = { NEXT = 5 } })
    local st = kanban.open()
    eq(5, column(st, "NEXT").wip)
    ok(table.concat(buf_lines(st.buf), "\n"):find("NEXT  2/5", 1, true))
  end)

  it("shows priority, deadline countdown, effort and tags on cards", function()
    local st = kanban.open()
    local text = table.concat(buf_lines(st.buf), "\n")
    ok(text:find("[#A] Urgent task", 1, true))
    ok(text:find("◆ yesterday", 1, true))
    ok(text:find("◆ in 3d", 1, true))
    ok(text:find("◷ 2:30", 1, true))
    ok(text:find(":work:oss:", 1, true))
    ok(text:find("╭", 1, true) and text:find("╯", 1, true))
  end)

  it("uses the TODO keyword faces for column headers", function()
    setup({}, { ui = { todo_keyword_faces = { NEXT = ":foreground blue" } } })
    local st = kanban.open()
    local groups = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, -1, 0, -1, { details = true })) do
      groups[m[4].hl_group] = true
    end
    ok(groups.orgTodoKw_NEXT)
    ok(groups.OrgTodo)
    ok(groups.OrgDone)
  end)

  it("filters by tag, tags match and org-ql query", function()
    local st = kanban.open({ tag = "work" })
    eq({ "Urgent task" }, names(column(st, "TODO")))
    eq({ "Ship it", "Child two" }, names(column(st, "NEXT")))
    st = kanban.open({ filter = "work-oss" })
    eq({ "Child two" }, names(column(st, "NEXT")))
    st = kanban.open({ filter = '(priority "A")' })
    eq({ "Urgent task" }, names(column(st, "TODO")))
    eq({}, names(column(st, "NEXT")))
    st = kanban.open({ query = "tags:home" })
    eq({ "Low task" }, names(column(st, "TODO")))
  end)

  it("sets a filter with / (empty clears it)", function()
    local st = kanban.open()
    local input = vim.ui.input
    vim.ui.input = function(_, cb)
      cb("oss")
    end
    utils.run(kanban.ask_filter)
    vim.wait(1000, function()
      return st.filter == "oss"
    end)
    eq("oss", st.filter)
    eq({ "Ship it" }, names(column(st, "NEXT")))
    vim.ui.input = function(_, cb)
      cb("")
    end
    utils.run(kanban.ask_filter)
    vim.wait(1000, function()
      return st.filter == nil
    end)
    vim.ui.input = input
    eq(nil, st.filter)
    eq(2, #column(st, "NEXT").cards)
  end)

  it("moves the selection between cards and columns", function()
    local st = kanban.open()
    eq({ col = 1, row = 1 }, st.sel)
    kanban.move(1, 0)
    eq("Low task", kanban.selected().title)
    kanban.move(10, 0)
    eq("Water plants", kanban.selected().title)
    kanban.move(0, 1)
    eq(2, st.sel.col)
    ok(kanban.selected())
    kanban.move(0, 10)
    eq(#st.cols, st.sel.col)
    eq(0, st.sel.row) -- CANCELLED is empty
    eq(nil, kanban.selected())
    kanban.move(0, -1)
    eq("Finished", kanban.selected().title)
  end)

  it("puts the cursor on the selected card", function()
    local st = kanban.open()
    kanban.move(1, 0)
    local lnum = vim.api.nvim_win_get_cursor(st.win)[1]
    ok(buf_lines(st.buf)[lnum]:find("Low task", 1, true))
  end)

  it("selects the card under the cursor", function()
    local st = kanban.open()
    local lines = buf_lines(st.buf)
    for i, l in ipairs(lines) do
      local s = l:find("Feedback", 1, true)
      if s then
        vim.api.nvim_win_set_cursor(st.win, { i, s - 1 })
        break
      end
    end
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = st.buf })
    eq("Feedback", kanban.selected().title)
  end)

  it("moves a card to the next and previous state with the todo code", function()
    local st = kanban.open()
    eq("Urgent task", kanban.selected().title)
    kanban.move_card(1)
    local lines = file_lines()
    ok(lines[3]:match("^%* NEXT %[#A%] Urgent task%s+:work:$"), lines[3])
    eq("Urgent task", kanban.selected().title)
    eq(2, st.sel.col)
    eq(3, #column(st, "NEXT").cards)
    kanban.move_card(-1)
    ok(file_lines()[3]:match("^%* TODO %[#A%] Urgent task%s+:work:$"))
    eq(1, st.sel.col)
  end)

  it("adds CLOSED when a card reaches a DONE column", function()
    local st = kanban.open()
    kanban.move(0, 2) -- WAITING
    eq("Feedback", kanban.selected().title)
    kanban.move_card(1)
    local lines = file_lines()
    eq("* DONE Feedback", lines[10])
    ok(lines[11]:match("^%s*CLOSED: %["), lines[11])
    eq("Feedback", kanban.selected().title)
    eq(4, st.sel.col)
  end)

  it("repeats a repeating task moved to DONE", function()
    local st = kanban.open()
    kanban.move(3, 0)
    eq("Water plants", kanban.selected().title)
    kanban.move_card(1) -- NEXT
    kanban.move_card(1) -- WAITING
    kanban.move_card(1) -- DONE: repeats back to TODO
    local text = table.concat(file_lines(), "\n")
    ok(text:find("* TODO Water plants", 1, true))
    ok(text:find("SCHEDULED: " .. ts(1, "+1d"), 1, true), text)
    eq(4, #column(st, "TODO").cards)
  end)

  it("saves after a move with save = true", function()
    setup({ save = true })
    kanban.open()
    kanban.move_card(1)
    ok(utils.readfile(path)[3]:match("^%* NEXT %[#A%] Urgent task%s+:work:$"))
    eq(false, vim.bo[utils.find_buffer(path)].modified)
  end)

  it("jumps to the heading and closes the float", function()
    local st = kanban.open()
    kanban.move(1, 0)
    kanban.jump()
    ok(not vim.api.nvim_win_is_valid(st.win))
    eq(vim.uv.fs_realpath(path), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))
    eq(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("builds a board of the current buffer or subtree", function()
    local buf = org_buffer({
      "* TODO Outside",
      "* Project",
      "** TODO Inside one",
      "** DONE Inside two",
      "* NEXT Also outside",
    }, { 2, 0 })
    local st = kanban.open({ source = "subtree" })
    eq({ "Inside one" }, names(column(st, "TODO")))
    eq({}, names(column(st, "NEXT")))
    -- the subtree is followed when lines are added above it
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "* TODO New outside" })
    kanban.refresh()
    eq({ "Inside one" }, names(column(st, "TODO")))
    kanban.close()
    vim.api.nvim_set_current_buf(buf)
    st = kanban.open({ source = "buffer" })
    eq({ "New outside", "Outside", "Inside one" }, names(column(st, "TODO")))
    kanban.close()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("re-renders when an org file is written", function()
    local st = kanban.open()
    local b = utils.load_buffer(path)
    vim.api.nvim_buf_set_lines(b, -1, -1, false, { "* WAITING Brand new card" })
    vim.api.nvim_buf_call(b, function()
      vim.cmd("silent write")
    end)
    ok(vim.wait(2000, function()
      return table.concat(buf_lines(st.buf), "\n"):find("Brand new card", 1, true) ~= nil
    end))
  end)

  it("maps its keys in the board buffer", function()
    local st = kanban.open()
    for _, lhs in ipairs({ "h", "l", "j", "k", "H", "L", "<CR>", "r", "/", "<Esc>" }) do
      local m = vim.fn.maparg(lhs, "n", false, true)
      ok(m.buffer == 1, lhs)
    end
    vim.api.nvim_feedkeys("l", "x", false)
    ok(file_lines()[3]:match("^%* NEXT %[#A%] Urgent task%s+:work:$"))
    eq(true, vim.api.nvim_buf_is_valid(st.buf))
    eq("", vim.fn.maparg("q", "n"))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    eq(nil, kanban.state)
  end)

  it("fits columns into the window, within the width limits", function()
    local o = { min_column_width = 20, max_column_width = 40 }
    eq(40, kanban.column_width(2, 200, o))
    eq(24, kanban.column_width(4, 99, o))
    eq(20, kanban.column_width(9, 100, o))
  end)

  it("parses :Org kanban arguments", function()
    eq({}, kanban.parse_args(""))
    eq({ source = "buffer" }, kanban.parse_args("buffer"))
    eq({ source = "subtree", filter = "work-home" }, kanban.parse_args("subtree work-home"))
    eq({ filter = '(todo "NEXT")' }, kanban.parse_args('(todo "NEXT")'))
    eq({ source = vim.fn.expand("~/x.org"), filter = "a" }, kanban.parse_args("~/x.org a"))
  end)

  it("reports an invalid filter instead of opening", function()
    local errors = {}
    local notify = vim.notify
    vim.notify = function(msg)
      errors[#errors + 1] = msg
    end
    kanban.command("(nosuchpredicate")
    vim.notify = notify
    eq(nil, kanban.state)
    ok(#errors > 0)
  end)

  it("is closed by a setup() that turns it off", function()
    local st = kanban.open()
    setup(nil)
    eq(nil, kanban.state)
    ok(not vim.api.nvim_buf_is_valid(st.buf))
  end)
end)

describe("kanban board edges", function()
  before_each(function()
    write()
    setup({}, { log_done = "time" })
  end)
  after_each(function()
    kanban.close()
    restore()
  end)

  local function count_builds()
    local build = kanban.build
    local n = { 0 }
    kanban.build = function(...)
      n[1] = n[1] + 1
      return build(...)
    end
    return n, function()
      kanban.build = build
    end
  end

  local function quiet()
    local notify = vim.notify
    local msgs = {}
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    return msgs, function()
      vim.notify = notify
    end
  end

  it("moves the selection without rebuilding the board", function()
    local st = kanban.open()
    local n, undo = count_builds()
    kanban.move(1, 0)
    kanban.move(0, 1)
    kanban.move(-1, 0)
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = st.buf })
    undo()
    eq(0, n[1])
    -- the selected card's border is highlighted
    local sel_ns = vim.api.nvim_create_namespace("org_kanban_selection")
    local marks = vim.api.nvim_buf_get_extmarks(st.buf, sel_ns, 0, -1, { details = true })
    ok(#marks > 0)
    eq("OrgKanbanSelected", marks[1][4].hl_group)
    local top = buf_lines(st.buf)[marks[1][2] + 1]
    ok(top:sub(marks[1][3] + 1):find("^╭"), top)
    local title_line = buf_lines(st.buf)[marks[1][2] + 2]
    ok(title_line:find(kanban.selected().title, 1, true), title_line)
  end)

  it("skips columns whose keywords the card's file does not have", function()
    local p2 = dir .. "/own.org"
    utils.writefile(p2, { "#+TODO: TODO DOING | FINISHED", "* TODO Own sequence" })
    require("org.files").invalidate(p2)
    setup({}, { agenda_files = { path, p2 } })
    local st = kanban.open()
    eq({ "TODO", "NEXT", "WAITING", "DONE", "CANCELLED", "DOING", "FINISHED" }, col_names(st))
    for i, c in ipairs(column(st, "TODO").cards) do
      if c.title == "Own sequence" then
        st.sel = { col = 1, row = i }
      end
    end
    eq("Own sequence", kanban.selected().title)
    kanban.move_card(1)
    local b = utils.find_buffer(p2)
    eq("* DOING Own sequence", buf_lines(b)[2])
    eq("DOING", st.cols[st.sel.col].name)
    eq("Own sequence", kanban.selected().title)
    kanban.move_card(-1)
    eq("* TODO Own sequence", buf_lines(b)[2])
    eq("TODO", st.cols[st.sel.col].name)
    vim.api.nvim_buf_delete(b, { force = true })
  end)

  it("takes the first keyword of a grouped column, or asks with choose_keyword", function()
    local cols = { "TODO", { "NEXT", "WAITING", name = "Doing" }, "DONE" }
    setup({ columns = cols })
    kanban.open()
    kanban.move_card(1)
    ok(file_lines()[3]:match("^%* NEXT %[#A%] Urgent task"), file_lines()[3])
    kanban.move_card(-1)
    setup({ columns = cols, choose_keyword = true })
    kanban.open()
    local select = vim.ui.select
    local offered
    vim.ui.select = function(items, _, cb)
      offered = items
      cb("WAITING")
    end
    utils.run(kanban.move_card, 1)
    vim.wait(1000, function()
      return file_lines()[3]:match("WAITING") ~= nil
    end)
    vim.ui.select = select
    eq({ "NEXT", "WAITING" }, offered)
    ok(file_lines()[3]:match("^%* WAITING %[#A%] Urgent task"), file_lines()[3])
  end)

  it("reorders sibling cards with J and K when sorted by file", function()
    setup({ sort = "file" })
    local st = kanban.open()
    eq({ "Low task", "Urgent task", "Child one", "Water plants" }, names(column(st, "TODO")))
    kanban.move(1, 0)
    eq("Urgent task", kanban.selected().title)
    kanban.move_order(-1)
    local lines = file_lines()
    ok(lines[2]:find("Urgent task", 1, true), lines[2])
    eq("  DEADLINE: " .. ts(-1), lines[3])
    ok(lines[4]:find("Low task", 1, true), lines[4])
    eq({ "Urgent task", "Low task", "Child one", "Water plants" }, names(column(st, "TODO")))
    eq("Urgent task", kanban.selected().title)
    kanban.move_order(1)
    eq({ "Low task", "Urgent task", "Child one", "Water plants" }, names(column(st, "TODO")))
    eq("Urgent task", kanban.selected().title)
    ok(file_lines()[2]:find("Low task", 1, true))
    for _, lhs in ipairs({ "J", "K" }) do
      ok(vim.fn.maparg(lhs, "n", false, true).buffer == 1, lhs)
    end
  end)

  it("reorders only siblings, and only when sorted by file", function()
    setup({ sort = "file" })
    kanban.open()
    kanban.move(2, 0)
    eq("Child one", kanban.selected().title)
    local before = file_lines()
    local msgs, undo = quiet()
    kanban.move_order(1) -- Water plants is not under Project
    eq(before, file_lines())
    setup({})
    kanban.open()
    kanban.move_order(1)
    undo()
    eq(before, file_lines())
    eq(2, #msgs)
  end)

  it("ignores text changes of org buffers that are not on the board", function()
    kanban.open()
    local n, undo = count_builds()
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(other, 0, -1, false, { "* TODO Elsewhere" })
    vim.bo[other].filetype = "org"
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = other })
    vim.wait(400)
    eq(0, n[1])
    local fb = utils.load_buffer(path)
    vim.api.nvim_buf_set_lines(fb, -1, -1, false, { "* TODO Late addition" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = fb })
    ok(vim.wait(1000, function()
      return n[1] > 0
    end))
    undo()
    vim.api.nvim_buf_delete(other, { force = true })
  end)

  it("redraws without rebuilding when the editor is resized", function()
    local st = kanban.open()
    local n, undo = count_builds()
    local columns = vim.o.columns
    vim.o.columns = columns - 10
    vim.api.nvim_exec_autocmds("VimResized", {})
    vim.o.columns = columns
    undo()
    eq(0, n[1])
    ok(vim.api.nvim_win_get_width(st.win) <= columns - 12)
  end)

  it("keeps the card borders aligned with wide characters", function()
    local buf = org_buffer({
      "* TODO 日本語のとても長いタイトルがここにあります 🎉 and more words :タグ:",
      "* TODO Café ☕ naïve",
      "* NEXT short",
    })
    vim.bo[buf].bufhidden = "hide"
    local st = kanban.open({ source = "buffer" })
    for _, r in ipairs(st.rects) do
      for _, sp in ipairs(r.spans) do
        local line = buf_lines(st.buf)[sp[1]]
        local seg = line:sub(sp[2] + 1, sp[3])
        eq(st.col_width, vim.fn.strdisplaywidth(seg), seg)
      end
    end
    kanban.close()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("opens in a tiny editor", function()
    local columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 20, 6
    local st = kanban.open()
    vim.o.columns, vim.o.lines = columns, lines
    ok(st and vim.api.nvim_win_is_valid(st.win))
  end)

  it("parses a TODO match with a slash as a filter, and completes arguments", function()
    eq({ filter = "work/NEXT" }, kanban.parse_args("work/NEXT"))
    local c = require("org.commands").complete("", "Org kanban ")
    ok(vim.tbl_contains(c, "subtree"), vim.inspect(c))
    c = require("org.commands").complete("wo", "Org kanban agenda wo")
    ok(vim.tbl_contains(c, "work"), vim.inspect(c))
  end)
end)

describe("kanban wrapping", function()
  it("wraps titles to the given lines and cuts the rest", function()
    eq({ "one two", "three" }, kanban._wrap("one two three", 8, 2))
    eq({ "one two", "three f…" }, kanban._wrap("one two three four five", 8, 2))
    eq({ "abcdefg…" }, kanban._wrap("abcdefghijkl", 8, 1))
    eq({ "" }, kanban._wrap("", 8, 2))
  end)
end)

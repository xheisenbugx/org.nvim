-- :Org tutor: the lessons open as a writable copy in an org buffer, and
-- each exercise shows ✗ until its check passes, then ✓.
local tutor = require("org.tutor")
local config = require("org.config")
local utils = require("org.utils")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function real(path)
  return vim.uv.fs_realpath(path) or path
end

local function read(path)
  return table.concat(vim.fn.readfile(path, "b"), "\n")
end

--- The exercise headline `id` of `buf`.
local function exercise(buf, id)
  for _, hl in ipairs(require("org.files").get_buffer(buf).headlines) do
    if tutor.exercise_id(hl) == id then
      return hl
    end
  end
  error("no exercise " .. id)
end

--- The mark shown on exercise `id`: { text, hl_group } or nil.
local function mark(buf, id)
  local row = exercise(buf, id).line - 1
  local marks = vim.api.nvim_buf_get_extmarks(buf, tutor.ns, { row, 0 }, { row, -1 }, { details = true })
  local m = marks[1]
  return m and { m[4].virt_text[1][1], m[4].virt_text[1][2] } or nil
end

local DONE = { " ✓", "OrgTutorDone" }
local TODO = { " ✗", "OrgTutorTodo" }

--- Put the cursor on the first line of `buf` that is `text` (or starts
--- with it when `prefix`).
local function cursor_to(buf, text, col)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line == text then
      vim.api.nvim_win_set_cursor(0, { i, col or 0 })
      return i
    end
  end
  error("no line " .. text)
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

--- Run `fn` in a coroutine and wait for it to finish.
local function run(fn)
  local done = false
  utils.run(function()
    fn()
    done = true
  end)
  ok(
    vim.wait(2000, function()
      return done
    end),
    "coroutine did not finish"
  )
end

local function cleanup()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.b[b].org_tutor then
      vim.cmd("bwipeout! " .. b)
    end
  end
  vim.fn.delete(vim.fn.stdpath("data") .. "/org/tutor", "rf")
end

describe("tutor", function()
  before_each(cleanup)
  after_each(cleanup)

  it("opens a writable copy of the lesson in an org buffer, never the shipped file", function()
    local shipped = root .. "/tutor/org/basics.org"
    local before = read(shipped)
    local buf = assert(tutor.open("basics"))
    eq(buf, vim.api.nvim_get_current_buf())
    eq("org", vim.bo[buf].filetype)
    eq("", vim.bo[buf].buftype)
    eq(real(tutor.copy_path("basics")), real(vim.api.nvim_buf_get_name(buf)))
    ok(vim.startswith(tutor.copy_path("basics"), vim.fs.normalize(vim.fn.stdpath("data"))))
    eq({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
    -- the keys are filled in
    local text = table.concat(buf_lines(buf), "\n")
    ok(not text:find("{{", 1, true), "placeholders left")
    ok(text:find("=cit=", 1, true))
    -- doing exercises and saving changes only the copy
    cursor_to(buf, "*** TODO Buy milk")
    feed("cit")
    vim.cmd("silent write")
    eq(before, read(shipped))
    ok(read(tutor.copy_path("basics")):find("*** DONE Buy milk", 1, true))
    eq(before, read(root .. "/tutor/org/basics.org"))
  end)

  it("shows ✗ until an exercise is done with its key, then ✓", function()
    local buf = assert(tutor.open("basics"))
    eq(TODO, mark(buf, "2.1"))
    cursor_to(buf, "*** TODO Buy milk")
    feed("cit")
    eq("*** DONE Buy milk", vim.api.nvim_get_current_line())
    -- updated on its own, after the debounce
    ok(vim.wait(2000, function()
      return vim.deep_equal(mark(buf, "2.1"), DONE)
    end))
    -- undoing it brings the ✗ back
    feed("u")
    ok(vim.wait(2000, function()
      return vim.deep_equal(mark(buf, "2.1"), TODO)
    end))
    -- exercises without a check have no mark
    eq(nil, mark(buf, "1.1"))
  end)

  it("counts the exercises done on the first line", function()
    local buf = assert(tutor.open("basics"))
    local function progress()
      local m = vim.api.nvim_buf_get_extmarks(buf, tutor.ns, { 0, 0 }, { 0, -1 }, { details = true })[1]
      return m[4].virt_text[1][1]
    end
    local n = vim.tbl_count(tutor.checks("basics"))
    eq((" ✓ 0/%d"):format(n), progress())
    cursor_to(buf, "*** TODO Buy milk")
    feed("cit")
    tutor.refresh(buf)
    eq((" ✓ 1/%d"):format(n), progress())
  end)

  it("checks the outline, list and table exercises done with their keys", function()
    local buf = assert(tutor.open("basics"))
    for _, id in ipairs({ "1.2", "1.3", "1.4", "2.2", "5.1", "5.2", "6.1", "6.2" }) do
      eq(TODO, mark(buf, id), id)
    end
    -- 1.2: M-RET on Apples, then type
    cursor_to(buf, "**** Apples", 5)
    feed("<M-CR>Pears<Esc>")
    -- 1.3: demote Carrot, promote Spoon
    cursor_to(buf, "*** Carrot")
    feed(">>")
    cursor_to(buf, "***** Spoon")
    feed("<<")
    -- 1.4: Monday up
    cursor_to(buf, "*** Monday")
    feed("<M-k>")
    -- 2.2
    cursor_to(buf, "*** Write a letter")
    feed("cit")
    -- 5.1: a new item
    cursor_to(buf, "- Bread", 3)
    feed("<M-CR>Butter<Esc>")
    -- 5.2: C-c C-c on the checkbox
    cursor_to(buf, "  - [ ] Eggs", 8)
    feed("<C-c><C-c>")
    -- 6.1: C-c C-c in the table aligns it
    cursor_to(buf, "| Apple | 3 |", 3)
    feed("<C-c><C-c>")
    -- 6.2: <Tab> in Insert mode past the last field opens a row
    cursor_to(buf, "| Lemon |     2 |")
    feed("A<Tab>Kiwi<Tab>5<Esc>")
    tutor.refresh(buf)
    for _, id in ipairs({ "1.2", "1.3", "1.4", "2.2", "5.1", "5.2", "6.1", "6.2" }) do
      eq(DONE, mark(buf, id), id)
    end
  end)

  it("checks the exercises that prompt", function()
    local buf = assert(tutor.open("basics"))
    for _, id in ipairs({ "2.3", "3.1", "4.1", "4.2", "7.1" }) do
      eq(TODO, mark(buf, id), id)
    end
    cursor_to(buf, "*** TODO Pay rent")
    run(function()
      require("org.priority").set(nil, "A")
    end)
    cursor_to(buf, "*** TODO Prepare slides")
    run(function()
      require("org.tags").set_tags(nil, { "work" })
    end)
    -- the date prompt: <CR> takes today
    local orig_pick = require("org.calendar").pick
    require("org.calendar").pick = function()
      return require("org.date").today()
    end
    cursor_to(buf, "*** TODO Water the plants")
    run(function()
      require("org.timestamps").schedule()
    end)
    cursor_to(buf, "*** TODO File the tax return")
    run(function()
      require("org.timestamps").deadline()
    end)
    require("org.calendar").pick = orig_pick
    -- the link prompts
    local orig_input = vim.fn.input
    vim.fn.input = function(o)
      return o.prompt:find("Description") and "the treasure" or "*Treasure chest"
    end
    cursor_to(buf, "Map:", 3)
    run(function()
      require("org.links").insert_link()
    end)
    vim.fn.input = orig_input
    ok(table.concat(buf_lines(buf), "\n"):find("Map:[[*Treasure chest][the treasure]]", 1, true))
    tutor.refresh(buf)
    for _, id in ipairs({ "2.3", "3.1", "4.1", "4.2", "7.1" }) do
      eq(DONE, mark(buf, id), id)
    end
  end)

  it("checks the capture, agenda and clock exercises of the workflow lesson", function()
    local buf = assert(tutor.open("workflow"))
    for _, id in ipairs({ "1.1", "2.1", "2.2", "3.1", "3.2" }) do
      eq(TODO, mark(buf, id), id)
    end
    -- 1.1: capture at the cursor
    cursor_to(buf, "*** Inbox")
    run(function()
      require("org.capture").capture({ template = "* TODO Call Bob", immediate_finish = true }, { here = true })
    end)
    -- 2.1: t in the agenda's TODO list, restricted to this file
    local file = require("org.files").get_buffer(buf)
    require("org.agenda").open_todo(nil, { bufnr = buf, filename = file.filename })
    eq("orgagenda", vim.bo.filetype)
    local found
    for i, line in ipairs(buf_lines(0)) do
      if line:find("TODO Call the dentist", 1, true) then
        found = i
      end
    end
    ok(found, "the agenda lists the tutor's tasks")
    vim.api.nvim_win_set_cursor(0, { found, 0 })
    feed("t")
    feed("q")
    eq(buf, vim.api.nvim_get_current_buf())
    -- 2.2: schedule
    local orig_pick = require("org.calendar").pick
    require("org.calendar").pick = function()
      return require("org.date").today()
    end
    cursor_to(buf, "*** TODO Water the plants")
    run(function()
      require("org.timestamps").schedule()
    end)
    require("org.calendar").pick = orig_pick
    -- 3.1: clock in and out with their keys
    cursor_to(buf, "*** TODO Write the report")
    feed(" oxi")
    feed(" oxo")
    -- 3.2: the clock report
    cursor_to(buf, "*** Time spent")
    feed(" oxr")
    tutor.refresh(buf)
    for _, id in ipairs({ "1.1", "2.1", "2.2", "3.1", "3.2" }) do
      eq(DONE, mark(buf, id), id)
    end
  end)

  it("resumes the copy; reset starts the lesson over", function()
    local buf = assert(tutor.open("basics"))
    cursor_to(buf, "*** TODO Buy milk")
    feed("cit")
    vim.cmd("silent write")
    vim.cmd("enew")
    vim.cmd("bwipeout! " .. buf)
    local msgs = {}
    local orig = utils.notify
    utils.notify = function(msg)
      msgs[#msgs + 1] = msg
    end
    buf = assert(tutor.open("basics"))
    utils.notify = orig
    ok(vim.tbl_contains(buf_lines(buf), "*** DONE Buy milk"), "progress kept")
    eq(DONE, mark(buf, "2.1"))
    ok(msgs[1] and msgs[1]:find("reset"), "says how to start over")
    -- reset, with the copy loaded: the buffer is kept and written
    vim.cmd("Org tutor basics reset")
    eq(buf, vim.api.nvim_get_current_buf())
    ok(vim.tbl_contains(buf_lines(buf), "*** TODO Buy milk"))
    eq(false, vim.bo[buf].modified)
    eq(TODO, mark(buf, "2.1"))
    ok(read(tutor.copy_path("basics")):find("*** TODO Buy milk", 1, true))
  end)

  it("shows the keys of the user's mappings", function()
    local org = config.opts.mappings.org
    local saved_next, saved_cycle = org.todo_next, org.cycle
    org.todo_next, org.cycle = "<prefix>T", false
    local ok_, err = pcall(function()
      local buf = assert(tutor.open("basics"))
      local text = table.concat(buf_lines(buf), "\n")
      ok(text:find("=<leader>oT=", 1, true), "remapped key")
      ok(text:find("=:Org cycle=", 1, true), "disabled key")
    end)
    org.todo_next, org.cycle = saved_next, saved_cycle
    assert(ok_, err)
  end)

  it("uses ui.tutor_marks", function()
    local saved = config.opts.ui.tutor_marks
    config.opts.ui.tutor_marks = { done = "OK", todo = "--" }
    local ok_, err = pcall(function()
      local buf = assert(tutor.open("basics"))
      eq({ " --", "OrgTutorTodo" }, mark(buf, "2.1"))
    end)
    config.opts.ui.tutor_marks = saved
    assert(ok_, err)
  end)

  it(":Org tutor opens a lesson by name and completes the lessons", function()
    vim.cmd("Org tutor workflow")
    eq("workflow", vim.b.org_tutor)
    eq(real(tutor.copy_path("workflow")), real(vim.api.nvim_buf_get_name(0)))
    vim.cmd("Org tutor")
    eq("basics", vim.b.org_tutor)
    eq(
      { "basics", "reset", "workflow" },
      (function()
        local c = require("org.commands").complete("", "Org tutor ")
        table.sort(c)
        return c
      end)()
    )
    eq({ "workflow" }, require("org.commands").complete("w", "Org tutor w"))
    ok(vim.tbl_contains(require("org.commands").complete("tu", "Org tu"), "tutor"))
    local errs = {}
    local orig = utils.error
    utils.error = function(msg)
      errs[#errs + 1] = msg
    end
    vim.cmd("Org tutor nosuchlesson")
    utils.error = orig
    ok(errs[1] and errs[1]:find("nosuchlesson"))
  end)
end)

describe("tutor lessons", function()
  local lessons = tutor.lessons()

  it("ships the basics and workflow lessons", function()
    eq({ "basics", "workflow" }, tutor.lesson_names())
  end)

  -- the guard against lessons drifting from the default keys
  it("every key named in a lesson is a default mapping of an existing action", function()
    local defaults = config.defaults.mappings
    local actions = require("org.actions").list
    for name, path in pairs(lessons) do
      local text = read(path)
      for ref in text:gmatch("{{([^}]*)}}") do
        if not vim.tbl_contains({ "leader", "examples", "done", "todo" }, ref) then
          local section, action = ref:match("^([%w_]+)%.([%w_]+)$")
          ok(section, ("%s: bad placeholder {{%s}}"):format(name, ref))
          local value = defaults[section] and defaults[section][action]
          ok(value, ("%s: {{%s}} has no default key"):format(name, ref))
          if section == "org" or section == "global" or section == "org_insert" then
            ok(actions[action], ("%s: {{%s}} is not an action"):format(name, ref))
          end
        end
      end
      -- keys are written as placeholders, never literally (but for the
      -- intro's =<M-x>= / =<S-x>= / =<C-x>= notation)
      for line in text:gsub("=<[MSC]%-x>=", ""):gsub("=<leader>=", ""):gmatch("[^\n]+") do
        for _, literal in ipairs({ "<leader>", "<prefix>", "<C-", "<M-", "<S-", "<Tab>", "<C-Space>" }) do
          ok(not line:find(literal, 1, true), ("%s: literal %s in %q"):format(name, literal, line))
        end
      end
    end
  end)

  it("every check belongs to an exercise of its lesson", function()
    for name, path in pairs(lessons) do
      local file = require("org.parser").parse(vim.fn.readfile(path))
      local ids = {}
      for _, hl in ipairs(file.headlines) do
        local id = tutor.exercise_id(hl)
        if id then
          ok(not ids[id], ("%s: exercise %s twice"):format(name, id))
          ids[id] = true
        end
      end
      for id in pairs(tutor.checks(name)) do
        ok(ids[id], ("%s: check %s has no exercise"):format(name, id))
      end
    end
  end)
end)

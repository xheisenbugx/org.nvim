local config = require("org.config")
local date = require("org.date")
local todo = require("org.todo")
local priority = require("org.priority")
local utils = require("org.utils")

local function with_opts(overrides, fn)
  local saved = {}
  for k, v in pairs(overrides) do
    saved[k] = config.opts[k]
    config.opts[k] = v
  end
  local ok, err = pcall(fn)
  for k, v in pairs(saved) do
    config.opts[k] = v
  end
  if not ok then
    error(err, 0)
  end
end

local today = date.today()
local now_prefix = "[" .. today:to_date_string()

describe("todo", function()
  before_each(function()
    utils.input = function()
      return "a note"
    end
  end)

  it("cycles keywords and adds CLOSED", function()
    local buf = org_buffer({ "* Task", "body" }, { 1, 0 })
    todo.cycle_next()
    eq("* TODO Task", buf_lines(buf)[1])
    todo.cycle_next()
    eq("* NEXT Task", buf_lines(buf)[1])
    todo.cycle_next()
    eq("* DONE Task", buf_lines(buf)[1])
    ok(buf_lines(buf)[2]:find("^CLOSED: " .. vim.pesc(now_prefix)), buf_lines(buf)[2])
    todo.cycle_next()
    eq({ "* Task", "body" }, buf_lines(buf))
    todo.cycle_prev()
    eq("* DONE Task", buf_lines(buf)[1])
  end)

  it("respects log_done=false and STARTUP", function()
    with_opts({ log_done = false }, function()
      local buf = org_buffer({ "* TODO Task" }, { 1, 0 })
      todo.change_state(nil, "DONE")
      eq({ "* DONE Task" }, buf_lines(buf))
    end)
    local buf = org_buffer({ "#+STARTUP: nologdone", "* TODO Task" }, { 2, 0 })
    todo.change_state(nil, "DONE")
    eq({ "#+STARTUP: nologdone", "* DONE Task" }, buf_lines(buf))
  end)

  it("logs note with log_done=note", function()
    with_opts({ log_done = "note" }, function()
      local buf = org_buffer({ "* TODO Task" }, { 1, 0 })
      todo.change_state(nil, "DONE")
      local l = buf_lines(buf)
      eq("* DONE Task", l[1])
      ok(l[2]:match("^CLOSED:"))
      eq(":LOGBOOK:", l[3])
      ok(l[4]:match("^%- CLOSING NOTE %[.*%] \\\\$"), l[4])
      eq("  a note", l[5])
      eq(":END:", l[6])
    end)
  end)

  it("logs keyword flags from per-file #+TODO", function()
    local buf = org_buffer({ "#+TODO: TODO WAIT(w@/!) | DONE(d!)", "* TODO Task" }, { 2, 0 })
    todo.change_state(nil, "WAIT")
    local l = buf_lines(buf)
    eq("* WAIT Task", l[2])
    eq(":LOGBOOK:", l[3])
    ok(l[4]:match('^%- State "WAIT"       from "TODO"       %[.*%] \\\\$'), l[4])
    todo.change_state(nil, "DONE")
    l = buf_lines(buf)
    ok(l[3]:match("^CLOSED:"))
    ok(l[5]:match('^%- State "DONE"       from "WAIT"'), l[5])
  end)

  it("handles repeaters", function()
    local buf = org_buffer({ "* TODO Water plants", "SCHEDULED: <2026-09-01 Tue +1w>" }, { 1, 0 })
    local res = todo.change_state(nil, "DONE")
    ok(res.repeated)
    eq("TODO", res.new)
    local l = buf_lines(buf)
    eq("* TODO Water plants", l[1])
    eq("SCHEDULED: <2026-09-08 Tue +1w>", l[2])
    eq(":PROPERTIES:", l[3])
    ok(l[4]:match("^:LAST_REPEAT: %["))
    eq(":LOGBOOK:", l[6])
    ok(l[7]:match('^%- State "DONE"       from "TODO"'))
  end)

  it("shifts ++ and .+ repeaters and body timestamps", function()
    local buf = org_buffer({ "* NEXT Gym", "DEADLINE: <2020-01-01 Wed .+2d>", "Meeting <2020-01-01 Wed ++1d>" }, { 1, 0 })
    with_opts({ log_repeat = false }, function()
      todo.change_state(nil, "DONE")
    end)
    local l = buf_lines(buf)
    -- Emacs: back to the first keyword of the sequence
    eq("* TODO Gym", l[1])
    eq("DEADLINE: " .. today:add(2, "d"):clone({ repeater = { type = ".+", value = 2, unit = "d" } }):to_string(), l[2])
    local meeting = vim.tbl_filter(function(x)
      return x:match("^Meeting")
    end, l)[1]
    ok(meeting:find(today:add(1, "d"):to_date_string(), 1, true), meeting)
  end)

  it("repeat target state: todo_repeat_to_state, REPEAT_TO_STATE", function()
    with_opts({ todo_repeat_to_state = true }, function()
      local buf = org_buffer({ "* NEXT Gym", "SCHEDULED: <2020-01-01 Wed +1d>" }, { 1, 0 })
      todo.change_state(nil, "DONE")
      eq("* NEXT Gym", buf_lines(buf)[1])
    end)
    local buf = org_buffer({
      "* TODO Gym",
      "SCHEDULED: <2020-01-01 Wed +1d>",
      ":PROPERTIES:",
      ":REPEAT_TO_STATE: NEXT",
      ":END:",
    }, { 1, 0 })
    todo.change_state(nil, "DONE")
    eq("* NEXT Gym", buf_lines(buf)[1])
  end)

  it("repeating: removes plain SCHEDULED, LAST_REPEAT only when logging or clocked", function()
    with_opts({ log_repeat = false }, function()
      local buf = org_buffer({ "* TODO Pay", "DEADLINE: <2020-01-10 Fri +1m> SCHEDULED: <2020-01-05 Sun>" }, { 1, 0 })
      todo.change_state(nil, "DONE")
      eq({ "* TODO Pay", "DEADLINE: <2020-02-10 Mon +1m>" }, buf_lines(buf))
      buf = org_buffer({
        "* TODO Pay",
        "DEADLINE: <2020-01-10 Fri +1m>",
        ":LOGBOOK:",
        "CLOCK: [2020-01-01 Wed 10:00]--[2020-01-01 Wed 11:00] =>  1:00",
        ":END:",
      }, { 1, 0 })
      todo.change_state(nil, "DONE")
      ok(buf_lines(buf)[4]:match("^:LAST_REPEAT: %["), buf_lines(buf)[4])
    end)
  end)

  it("honours the LOGGING property", function()
    local buf = org_buffer({ "* Project", ":PROPERTIES:", ":LOGGING: nil", ":END:", "** TODO Task" }, { 5, 0 })
    todo.change_state(nil, "DONE")
    eq("** DONE Task", buf_lines(buf)[5])
    eq(nil, buf_lines(buf)[6])
    buf = org_buffer({ "* TODO Task", ":PROPERTIES:", ":LOGGING: NEXT(!) lognotedone", ":END:" }, { 1, 0 })
    todo.change_state(nil, "NEXT")
    local l = buf_lines(buf)
    eq(":LOGBOOK:", l[5])
    ok(l[6]:match('^%- State "NEXT"'), l[6])
    todo.change_state(nil, "DONE")
    l = buf_lines(buf)
    ok(l[2]:match("^CLOSED:"), l[2])
    ok(vim.tbl_contains(l, "  a note"))
  end)

  it("honours LOG_INTO_DRAWER and #+STARTUP: nologdrawer", function()
    local buf = org_buffer(
      { "#+TODO: TODO(!) | DONE(!)", "* TODO Task", ":PROPERTIES:", ":LOG_INTO_DRAWER: NOTES", ":END:" },
      { 2, 0 }
    )
    todo.change_state(nil, "DONE")
    local l = buf_lines(buf)
    ok(vim.tbl_contains(l, ":NOTES:"), vim.inspect(l))
    buf = org_buffer({ "#+STARTUP: nologdrawer", "#+TODO: TODO | DONE(!)", "* TODO Task" }, { 3, 0 })
    todo.change_state(nil, "DONE")
    l = buf_lines(buf)
    ok(l[4]:match("^CLOSED:"), l[4])
    ok(l[5]:match('^%- State "DONE"'), l[5])
  end)

  it("applies todo_state_tags_triggers", function()
    local triggers = { WAIT = { waiting = true }, done = { waiting = false }, [""] = { waiting = false } }
    with_opts({ todo_state_tags_triggers = triggers }, function()
      local buf = org_buffer({ "#+TODO: TODO WAIT | DONE", "* TODO Task :work:" }, { 2, 0 })
      todo.change_state(nil, "WAIT")
      ok(buf_lines(buf)[2]:match(":work:waiting:$"), buf_lines(buf)[2])
      todo.change_state(nil, "DONE")
      ok(buf_lines(buf)[2]:match("^%* DONE Task%s+:work:$"), buf_lines(buf)[2])
    end)
  end)

  it("NOBLOCKING and blocked ancestors", function()
    with_opts({ enforce_todo_dependencies = true }, function()
      local orig = utils.warn
      utils.warn = function() end
      local buf = org_buffer({ "* TODO P", ":PROPERTIES:", ":NOBLOCKING: t", ":END:", "** TODO C" }, { 1, 0 })
      ok(todo.change_state(nil, "DONE"))
      buf = org_buffer({
        "* Root",
        ":PROPERTIES:",
        ":ORDERED: t",
        ":END:",
        "** TODO First",
        "** TODO Second",
        "*** TODO Sub",
      }, { 7, 0 })
      eq(nil, todo.change_state(nil, "DONE"))
      eq("*** TODO Sub", buf_lines(buf)[7])
      utils.warn = orig
    end)
  end)

  it("enforces dependencies", function()
    with_opts({ enforce_todo_dependencies = true, enforce_todo_checkbox_dependencies = true }, function()
      local warned
      local orig = utils.warn
      utils.warn = function(m)
        warned = m
      end
      local buf = org_buffer({ "* TODO Parent", "** TODO Child" }, { 1, 0 })
      eq(nil, todo.change_state(nil, "DONE"))
      ok(warned)
      eq("* TODO Parent", buf_lines(buf)[1])
      buf = org_buffer({ "* TODO Parent", "- [ ] item" }, { 1, 0 })
      eq(nil, todo.change_state(nil, "DONE"))
      buf = org_buffer({ "* Parent", ":PROPERTIES:", ":ORDERED: t", ":END:", "** TODO A", "** TODO B" }, { 6, 0 })
      eq(nil, todo.change_state(nil, "DONE"))
      utils.warn = orig
      ok(todo.change_state({ bufnr = buf, lnum = 5 }, "DONE"))
    end)
  end)

  it("works on non-current buffers via target", function()
    local other = org_buffer({ "* TODO Remote" })
    vim.bo[other].bufhidden = "hide"
    vim.cmd("enew!")
    todo.change_state({ bufnr = other, lnum = 1 }, "NEXT")
    eq("* NEXT Remote", vim.api.nvim_buf_get_lines(other, 0, 1, false)[1])
  end)
end)

describe("priority", function()
  it("shifts and wraps", function()
    local buf = org_buffer({ "* TODO Task" }, { 1, 0 })
    priority.shift(nil, 1)
    eq("* TODO [#B] Task", buf_lines(buf)[1])
    priority.shift(nil, 1)
    eq("* TODO [#A] Task", buf_lines(buf)[1])
    priority.shift(nil, 1)
    eq("* TODO Task", buf_lines(buf)[1])
    priority.shift(nil, -1)
    priority.shift(nil, -1)
    eq("* TODO [#C] Task", buf_lines(buf)[1])
    priority.set(nil, "a")
    eq("* TODO [#A] Task", buf_lines(buf)[1])
    priority.set(nil, " ")
    eq("* TODO Task", buf_lines(buf)[1])
  end)
  it("honours #+PRIORITIES", function()
    local buf = org_buffer({ "#+PRIORITIES: 1 5 3", "* Task" }, { 2, 0 })
    priority.shift(nil, 1)
    eq("* [#3] Task", buf_lines(buf)[2])
    priority.shift(nil, -1)
    eq("* [#4] Task", buf_lines(buf)[2])
  end)
end)

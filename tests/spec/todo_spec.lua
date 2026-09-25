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
  -- written for this setup rather than the Emacs defaults
  with_config({ todo_keywords = { "TODO(t) NEXT(n) | DONE(d)" }, log_done = "time", log_into_drawer = "LOGBOOK" })
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

-- Emacs Org 9.8 parity (expectations checked against Emacs in batch mode)
describe("todo: Emacs org-todo parity", function()
  local function keys(k)
    vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
  end
  local function hl1(buf, l)
    return buf_lines(buf)[l or 1]
  end
  local SETS = { "#+TODO: TODO | DONE", "#+TODO: WAIT | CANC" }
  local input = utils.input
  before_each(function()
    utils.input = function()
      return "a note"
    end
  end)
  after_each(function()
    utils.input = input
  end)
  local function seq(buf, lnum, fn, n)
    local out = {}
    for _ = 1, n do
      fn()
      out[#out + 1] = (hl1(buf, lnum):match("^%* (%u+) X$")) or "-"
    end
    return table.concat(out, " ")
  end

  it("S-Right / S-Left walk the keywords of every set", function()
    local buf = org_buffer(vim.list_extend(vim.deepcopy(SETS), { "* CANC X" }), { 3, 0 })
    eq("- TODO DONE WAIT", seq(buf, 3, todo.cycle_next, 4))
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "* X" })
    eq("CANC WAIT DONE TODO -", seq(buf, 3, todo.cycle_prev, 5))
  end)

  it("C-c C-t cycles within the set and comes back to it from no keyword", function()
    local buf = org_buffer(vim.list_extend(vim.deepcopy(SETS), { "* WAIT X" }), { 3, 0 })
    eq("CANC - WAIT CANC", seq(buf, 3, function()
      todo.select_or_cycle(nil, nil)
    end, 4))
    -- without a remembered set: the first keyword
    local b2 = org_buffer({ "#+TODO: A B C", "* X" }, { 2, 0 })
    eq("A B C -", seq(b2, 2, function()
      todo.select_or_cycle()
    end, 4))
  end)

  it("switches keyword sets without logging, from no keyword to the first / last set", function()
    local buf = org_buffer(vim.list_extend(vim.deepcopy(SETS), { "* DONE X" }), { 3, 0 })
    with_opts({ log_done = "time" }, function()
      eq("WAIT TODO WAIT", seq(buf, 3, function()
        todo.next_sequence(nil, 1)
      end, 3))
    end)
    eq(3, #buf_lines(buf))
    buf = org_buffer(vim.list_extend(vim.deepcopy(SETS), { "* X" }), { 3, 0 })
    eq("WAIT TODO WAIT", seq(buf, 3, function()
      todo.next_sequence(nil, -1)
    end, 3))
  end)

  it("prefix arguments: 4 forces a note, 16 next set, 64 ignores blocking, N the Nth keyword", function()
    local buf = org_buffer({ "* TODO X" }, { 1, 0 })
    todo.select_or_cycle(nil, 4)
    eq("* DONE X", hl1(buf))
    ok(hl1(buf, 2):match('^%- State "DONE"       from "TODO"       %[.*%] \\\\$'), hl1(buf, 2))
    eq("  a note", hl1(buf, 3))

    buf = org_buffer(vim.list_extend(vim.deepcopy(SETS), { "* TODO X" }), { 3, 0 })
    todo.select_or_cycle(nil, 16)
    eq("* WAIT X", hl1(buf, 3))
    todo.select_or_cycle(nil, 3)
    eq("* WAIT X", hl1(buf, 3))
    todo.select_or_cycle(nil, 2)
    eq("* DONE X", hl1(buf, 3))

    with_opts({ enforce_todo_dependencies = true }, function()
      buf = org_buffer({ "* TODO P", "** TODO C" }, { 1, 0 })
      todo.select_or_cycle(nil, 2)
      eq("* TODO P", hl1(buf))
      todo.change_state(nil, "DONE", { force = true })
      eq("* DONE P", hl1(buf))
      todo.change_state(nil, "TODO")
      todo.select_or_cycle(nil, 64)
      eq("* DONE P", hl1(buf))
    end)
  end)

  it("C-0: notes become timestamps; C-- 1: repeaters are cancelled", function()
    local buf = org_buffer({ "#+TODO: TODO WAIT(w@) | DONE", "* TODO X" }, { 2, 0 })
    utils.input = function()
      error("no note expected")
    end
    todo.change_state(nil, "WAIT", { inhibit_note = true })
    eq("* WAIT X", hl1(buf, 2))
    ok(hl1(buf, 3):match('^%- State "WAIT"       from "TODO"       %[.*%]$'), hl1(buf, 3))

    buf = org_buffer({ "* TODO X", "SCHEDULED: <2026-09-01 Tue +1w>" }, { 1, 0 })
    todo.todo_cancel_repeaters()
    eq("* DONE X", hl1(buf))
    eq("SCHEDULED: <2026-09-01 Tue +0w>", hl1(buf, 2))
  end)

  it("logs and touches CLOSED only when logging is set up", function()
    local buf = org_buffer({ "* DONE X", "CLOSED: [2026-09-01 Tue 10:00]" }, { 1, 0 })
    todo.change_state(nil, "TODO")
    eq({ "* TODO X", "CLOSED: [2026-09-01 Tue 10:00]" }, buf_lines(buf))
    with_opts({ log_done = "time" }, function()
      todo.change_state(nil, "DONE")
      todo.change_state(nil, nil)
    end)
    eq({ "* X" }, buf_lines(buf))
  end)

  it("uses log_note_headings", function()
    local buf = org_buffer({ "#+TODO: TODO WAIT(w!) | DONE", "* TODO X" }, { 2, 0 })
    with_opts({ log_note_headings = { done = "Closed by %u %d", state = "%s <- %S" } }, function()
      todo.change_state(nil, "WAIT")
      eq('- "WAIT" <- "TODO"', hl1(buf, 3))
      with_opts({ log_done = "note" }, function()
        todo.change_state(nil, "DONE")
      end)
    end)
    local found = false
    for _, l in ipairs(buf_lines(buf)) do
      found = found or l:match("^%- Closed by .* %[%d+%-%d+%-%d+ %a+%] \\\\$") ~= nil
    end
    ok(found, vim.inspect(buf_lines(buf)))
  end)

  it("records the effective time before extend_today_until", function()
    local real = date.now
    date.now = function()
      return date.parse("<2026-09-25 Fri 02:30>")
    end
    local ok_, err = pcall(with_opts, { use_effective_time = true, extend_today_until = 4, log_done = "time" }, function()
      local buf = org_buffer({ "* TODO X" }, { 1, 0 })
      todo.change_state(nil, "DONE")
      eq("CLOSED: [2026-09-24 Thu 23:59]", hl1(buf, 2))
    end)
    date.now = real
    assert(ok_, err)
  end)

  it("fires OrgTodoStateChange / OrgTodoRepeat and honours todo_blockers", function()
    local events = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = { "OrgTodoStateChange", "OrgTodoRepeat" },
      callback = function(ev)
        events[#events + 1] = ev.match .. ":" .. tostring(ev.data.from) .. ">" .. tostring(ev.data.to)
      end,
    })
    local buf = org_buffer({ "* TODO X", "SCHEDULED: <2026-09-01 Tue +1w>", "* TODO Y" }, { 1, 0 })
    todo.change_state(nil, "DONE")
    local target = { bufnr = buf, lnum = #buf_lines(buf) }
    with_opts({
      todo_blockers = {
        function(change)
          return change.to ~= "DONE"
        end,
      },
    }, function()
      eq(nil, todo.change_state(target, "DONE"))
    end)
    vim.api.nvim_del_autocmd(id)
    eq({ "OrgTodoRepeat:TODO>TODO", "OrgTodoStateChange:TODO>TODO" }, events)
  end)

  it("checkbox blocking: counters, partial boxes, not inside blocks", function()
    with_opts({ enforce_todo_checkbox_dependencies = true }, function()
      org_buffer({ "* TODO P", "1. [@3] [ ] a" }, { 1, 0 })
      eq(nil, todo.change_state(nil, "DONE"))
      org_buffer({ "* TODO P", "- [-] a", "  - [X] b" }, { 1, 0 })
      eq(nil, todo.change_state(nil, "DONE"))
      local buf = org_buffer({ "* TODO P", "#+begin_example", "- [ ] a", "#+end_example" }, { 1, 0 })
      ok(todo.change_state(nil, "DONE"))
      eq("* DONE P", hl1(buf))
    end)
  end)

  it("statistics options: provide_todo_statistics, hierarchical_todo_statistics", function()
    local buf = org_buffer({ "* P [/]", "** TODO A", "*** TODO deep", "** B" }, { 3, 0 })
    with_opts({ hierarchical_todo_statistics = false }, function()
      todo.change_state(nil, "DONE")
    end)
    eq("* P [1/2]", hl1(buf))
    buf = org_buffer({ "* P [/]", "** TODO A", "** B" }, { 2, 0 })
    with_opts({ provide_todo_statistics = "all-headlines" }, function()
      todo.change_state(nil, "DONE")
    end)
    eq("* P [1/2]", hl1(buf))
    buf = org_buffer({ "#+TODO: TODO NEXT | DONE", "* P [/]", "** NEXT A", "** TODO B" }, { 4, 0 })
    with_opts({ provide_todo_statistics = { "TODO" } }, function()
      todo.change_state(nil, "DONE")
    end)
    eq("* P [1/1]", hl1(buf, 2))
    -- a parent counting checkboxes is left alone
    buf = org_buffer({ "* P [/]", ":PROPERTIES:", ":COOKIE_DATA: checkbox", ":END:", "- [X] x", "** TODO A" }, { 6, 0 })
    todo.change_state(nil, "DONE")
    eq("* P [/]", hl1(buf))
  end)

  it("Visual C-c C-t changes every headline of the selection", function()
    local buf = org_buffer({ "* A", "text", "* TODO B", "* C" }, { 1, 0 })
    keys("Vjj<C-c><C-t>")
    eq({ "* TODO A", "text", "* DONE B", "* C" }, buf_lines(buf))
  end)
end)

describe("priority: Emacs parity", function()
  it("numeric priorities", function()
    local buf = org_buffer({ "#+PRIORITIES: 1 10 5", "* TODO [#10] X" }, { 2, 0 })
    priority.up()
    eq("* TODO [#9] X", buf_lines(buf)[2])
    priority.down()
    priority.down()
    eq("* TODO X", buf_lines(buf)[2])
    buf = org_buffer({ "#+PRIORITIES: 1 10 5", "* TODO X" }, { 2, 0 })
    priority.up()
    eq("* TODO [#5] X", buf_lines(buf)[2])
    eq("5", require("org.files").get_buffer(buf).headlines[1].priority)
    priority.set(nil, "10")
    eq("* TODO [#10] X", buf_lines(buf)[2])
    eq(nil, priority.set(nil, "11"))
    eq(0, priority.show())
  end)

  it("wraps around after a removal", function()
    local buf = org_buffer({ "* TODO [#A] X" }, { 1, 0 })
    priority.up()
    eq("* TODO X", buf_lines(buf)[1])
    priority.up()
    eq("* TODO [#C] X", buf_lines(buf)[1])
    buf = org_buffer({ "* TODO [#C] X" }, { 1, 0 })
    priority.down()
    priority.down()
    eq("* TODO [#A] X", buf_lines(buf)[1])
    eq(2000, priority.show())
  end)

  it("[#a] and [#65] are not priority cookies", function()
    local p = require("org.parser")
    eq(nil, p.parse_headline_line("* [#a] X").priority)
    eq(nil, p.parse_headline_line("* [#65] X").priority)
    eq("64", p.parse_headline_line("* [#64] X").priority)
  end)
end)

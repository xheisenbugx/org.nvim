-- TODO, logging, priority, tag and property options, checked against
-- Emacs Org 9.8.10 (`emacs -Q --batch` probes; expected buffers below come
-- from those runs, with the dates of the run replaced by computed ones).
local config = require("org.config")
local date = require("org.date")
local todo = require("org.todo")
local tags = require("org.tags")
local priority = require("org.priority")
local properties = require("org.properties")
local utils = require("org.utils")

local function inactive(d)
  return d:clone({ active = false }):to_string()
end

local function yesterday_2359()
  local y = date.now():clone({ hour = vim.NIL, min = vim.NIL }):add(-1, "d")
  return y:clone({ hour = 23, min = 59, active = false })
end

--- A state log line as Emacs writes it (`State %-12s from %-12S %t`).
local function state_line(new, old, ts)
  return string.format("- State %-12s from %-12s %s", '"' .. new .. '"', old and ('"' .. old .. '"') or "", ts)
end

--- Collect User autocmds of `pattern` fired while running `fn`.
local function capture_events(pattern, fn)
  local seen = {}
  local id = vim.api.nvim_create_autocmd("User", {
    pattern = pattern,
    callback = function(ev)
      seen[#seen + 1] = ev.data
    end,
  })
  local ok_run, err = pcall(fn)
  vim.api.nvim_del_autocmd(id)
  ok(ok_run, err)
  return seen
end

describe("org-todo-yesterday", function()
  with_config({ todo_keywords = { "TODO | DONE(!)" }, log_done = "time" })

  it("records CLOSED as 23:59 yesterday", function()
    local buf = org_buffer({ "* TODO A" }, { 1, 0 })
    todo.todo_yesterday(nil, nil)
    local ts = inactive(yesterday_2359())
    eq({ "* DONE A", "CLOSED: " .. ts, state_line("DONE", "TODO", ts) }, buf_lines(buf))
  end)

  it("shifts a .+ repeater from yesterday and logs yesterday", function()
    -- Emacs: SCHEDULED: <today .+1d>, LAST_REPEAT and the note at yesterday 23:59
    local buf = org_buffer({ "* TODO A", "SCHEDULED: <2026-01-01 Thu .+1d>" }, { 1, 0 })
    todo.todo_yesterday({ bufnr = buf, lnum = 1 }, nil)
    local ts = inactive(yesterday_2359())
    local today = date.now():clone({ hour = vim.NIL, min = vim.NIL })
    eq({
      "* TODO A",
      "SCHEDULED: <" .. today:to_string():sub(2, -2) .. " .+1d>",
      ":PROPERTIES:",
      ":LAST_REPEAT: " .. ts,
      ":END:",
      state_line("DONE", "TODO", ts),
    }, buf_lines(buf))
  end)
end)

describe("logging options", function()
  with_config({ todo_keywords = { "TODO(!) WAIT | DONE(!)" }, log_done = false })

  it("log_done_with_time = false records the date only", function()
    config.opts.todo_keywords = { "TODO | DONE" }
    config.opts.log_done = "time"
    local buf = org_buffer({ "* TODO A" }, { 1, 0 })
    config.opts.log_done_with_time = false
    todo.change_state(nil, "DONE")
    config.opts.log_done_with_time = true
    eq({ "* DONE A", "CLOSED: [" .. date.today():to_string():sub(2, -2) .. "]" }, buf_lines(buf))
  end)

  it("uses the last clock-out time as effective time", function()
    config.opts.todo_keywords = { "TODO | DONE" }
    config.opts.log_done = "time"
    config.opts.use_last_clock_out_time_as_effective_time = true
    local buf = org_buffer({
      "* TODO A",
      ":LOGBOOK:",
      "CLOCK: [2026-01-05 Mon 10:00]--[2026-01-05 Mon 11:30] =>  1:30",
      "CLOCK: [2026-01-04 Sun 10:00]--[2026-01-04 Sun 11:00] =>  1:00",
      ":END:",
    }, { 1, 0 })
    todo.change_state(nil, "DONE")
    eq("CLOSED: [2026-01-05 Mon 11:30]", buf_lines(buf)[2])
    -- a child's clock counts too; the note heading uses it
    config.opts.log_done = "note"
    buf = org_buffer(
      { "* TODO A", "** Child", "CLOCK: [2026-01-05 Mon 10:00]--[2026-01-05 Mon 11:30] =>  1:30" },
      { 1, 0 }
    )
    todo.change_state(nil, "DONE", { note = "the note" })
    config.opts.use_last_clock_out_time_as_effective_time = false
    eq({
      "* DONE A",
      "CLOSED: [2026-01-05 Mon 11:30]",
      "- CLOSING NOTE [2026-01-05 Mon 11:30] \\\\",
      "  the note",
      "** Child",
      "CLOCK: [2026-01-05 Mon 10:00]--[2026-01-05 Mon 11:30] =>  1:30",
    }, buf_lines(buf))
  end)

  local entry = {
    "* TODO A",
    "SCHEDULED: <2026-01-01 Thu>",
    ":PROPERTIES:",
    ":X: 1",
    ":END:",
    "CLOCK: [2026-01-01 Thu 10:00]--[2026-01-01 Thu 11:00] =>  1:00",
    "",
    ":FOO:",
    "bar",
    ":END:",
    "",
    "Text",
  }

  it("inserts notes after drawers with log_state_notes_insert_after_drawers", function()
    config.opts.log_state_notes_insert_after_drawers = true
    local buf = org_buffer(entry, { 1, 0 })
    todo.change_state(nil, "DONE")
    config.opts.log_state_notes_insert_after_drawers = false
    local lines = buf_lines(buf)
    local note = lines[12]
    ok(note:find('^%- State "DONE"%s+from "TODO"%s+%['), note)
    eq("", lines[11])
    eq("Text", lines[13])
    eq("SCHEDULED: <2026-01-01 Thu>", lines[2])
  end)

  it("inserts notes right after the property drawer by default", function()
    local buf = org_buffer(entry, { 1, 0 })
    todo.change_state(nil, "DONE")
    local lines = buf_lines(buf)
    eq(":END:", lines[5])
    ok(lines[6]:find('^%- State "DONE"'), lines[6])
    eq("CLOCK: [2026-01-01 Thu 10:00]--[2026-01-01 Thu 11:00] =>  1:00", lines[7])
  end)

  it("places notes like org-log-beginning around blank lines and old notes", function()
    local old = '- State "TODO"       from              [2026-01-01 Thu 10:00]'
    -- reversed (default): past the blank lines
    local buf = org_buffer({ "* TODO A", "", "Text" }, { 1, 0 })
    todo.change_state(nil, "DONE")
    local l = buf_lines(buf)
    eq({ "* DONE A", "", "Text" }, { l[1], l[2], l[4] })
    ok(l[3]:find('^%- State "DONE"'), l[3])
    -- oldest first: the blank line is taken by the note
    config.opts.log_states_order_reversed = false
    buf = org_buffer({ "* TODO A", "", "Text" }, { 1, 0 })
    todo.change_state(nil, "DONE")
    l = buf_lines(buf)
    eq(3, #l)
    ok(l[2]:find('^%- State "DONE"'), l[2])
    -- oldest first: after the existing state notes and their bodies
    buf = org_buffer({ "* TODO A", "", old, "  more", "", "Text" }, { 1, 0 })
    todo.change_state(nil, "DONE")
    l = buf_lines(buf)
    eq({ "* DONE A", "", old, "  more" }, vim.list_slice(l, 1, 4))
    ok(l[5]:find('^%- State "DONE"'), l[5])
    eq("Text", l[6])
    eq(6, #l)
    buf = org_buffer({ "* TODO A", old, "- other item" }, { 1, 0 })
    todo.change_state(nil, "DONE")
    l = buf_lines(buf)
    eq(old, l[2])
    ok(l[3]:find('^%- State "DONE"'), l[3])
    eq("- other item", l[4])
    config.opts.log_states_order_reversed = true
  end)

  it("fires OrgNoteStored after a note is stored", function()
    local buf = org_buffer({ "* TODO A" }, { 1, 0 })
    local seen = capture_events("OrgNoteStored", function()
      todo.change_state(nil, "DONE")
    end)
    eq(1, #seen)
    eq(buf, seen[1].bufnr)
    eq(1, seen[1].headline)
    ok(buf_lines(buf)[seen[1].lnum]:find("^%- State"))
  end)

  it("fires OrgLogBufferSetup when the *Org Note* buffer opens", function()
    config.opts.todo_keywords = { "TODO | DONE(@)" }
    local buf = org_buffer({ "* TODO A" }, { 1, 0 })
    local list_uis = vim.api.nvim_list_uis
    vim.api.nvim_list_uis = function()
      return { {} }
    end
    local seen = capture_events("OrgLogBufferSetup", function()
      utils.run(function()
        todo.change_state({ bufnr = buf, lnum = 1 }, "DONE")
      end)
    end)
    vim.api.nvim_list_uis = list_uis
    eq(1, #seen)
    eq('state change from "TODO" to "DONE"', seen[1].purpose)
    ok(vim.api.nvim_buf_get_name(seen[1].bufnr):match("%*Org Note%*$"))
    vim.cmd("stopinsert")
    local map = vim.api.nvim_buf_call(seen[1].bufnr, function()
      return vim.fn.maparg("<C-C><C-K>", "n", false, true)
    end)
    map.callback()
    vim.wait(50)
  end)
end)

describe("S-cursor and insert-todo-heading state changes", function()
  with_config({
    todo_keywords = { "TODO(!) WAIT(@) | DONE(!)" },
    log_done = "time",
    enforce_todo_dependencies = true,
  })

  it("S-Right without state change: no logging, no CLOSED change, no blocking", function()
    config.opts.treat_S_cursor_todo_selection_as_state_change = false
    local buf = org_buffer({ "* TODO A", "CLOSED: [2026-01-01 Thu 10:00]" }, { 1, 0 })
    todo.cycle_next()
    eq({ "* WAIT A", "CLOSED: [2026-01-01 Thu 10:00]" }, buf_lines(buf))
    buf = org_buffer({ "* WAIT A", "** TODO child" }, { 1, 0 })
    todo.cycle_next()
    eq({ "* DONE A", "** TODO child" }, buf_lines(buf))
    buf = org_buffer({ "* DONE A", "CLOSED: [2026-01-01 Thu 10:00]" }, { 1, 0 })
    todo.cycle_prev()
    eq({ "* WAIT A", "CLOSED: [2026-01-01 Thu 10:00]" }, buf_lines(buf))
    -- a repeating task still logs the repeat (org-auto-repeat-maybe)
    local rts = config.opts.todo_repeat_to_state
    config.opts.todo_repeat_to_state = nil
    buf = org_buffer({ "* WAIT A", "SCHEDULED: <2026-01-01 Thu +1d>" }, { 1, 0 })
    todo.cycle_next()
    config.opts.todo_repeat_to_state = rts
    config.opts.treat_S_cursor_todo_selection_as_state_change = true
    local l = buf_lines(buf)
    eq({ "* TODO A", "SCHEDULED: <2026-01-02 Fri +1d>", ":PROPERTIES:" }, vim.list_slice(l, 1, 3))
    ok(l[4]:find("^:LAST_REPEAT: %["), l[4])
    ok(l[6]:find('^%- State "DONE"%s+from "WAIT"'), l[6])
  end)

  it("inserts a TODO heading as a logged state change", function()
    config.opts.treat_insert_todo_heading_as_state_change = true
    local buf = org_buffer({ "* TODO A" }, { 1, 8 })
    require("org.structure").meta_return_heading({ todo = true, pos = { 1, 8 } })
    config.opts.treat_insert_todo_heading_as_state_change = false
    local l = buf_lines(buf)
    eq({ "* TODO A", "* TODO " }, { l[1], l[2] })
    ok(l[3]:find('^%- State "TODO"%s+from%s+%['), l[3])
    eq(3, #l)
    -- default: no logging
    buf = org_buffer({ "* TODO A" }, { 1, 8 })
    require("org.structure").meta_return_heading({ todo = true, pos = { 1, 8 } })
    eq({ "* TODO A", "* TODO " }, buf_lines(buf))
  end)
end)

describe("priority options", function()
  it("disables the priority commands", function()
    config.opts.priority_enable_commands = false
    local buf = org_buffer({ "* TODO A" }, { 1, 0 })
    local warned
    local warn = utils.warn
    utils.warn = function(msg)
      warned = msg
    end
    eq(nil, priority.set(nil, "A"))
    eq(nil, priority.shift(nil, 1))
    utils.warn = warn
    -- S-Up falls back to Vim when the commands are off
    eq(false, require("org.context").shift_up())
    config.opts.priority_enable_commands = true
    eq("Priority commands are disabled", warned)
    eq({ "* TODO A" }, buf_lines(buf))
  end)

  it("starts cycling one step past the default", function()
    config.opts.priority_start_cycle_with_default = false
    local buf = org_buffer({ "* A" }, { 1, 0 })
    priority.shift(nil, 1)
    eq("* [#A] A", buf_lines(buf)[1])
    buf = org_buffer({ "* A" }, { 1, 0 })
    priority.shift(nil, -1)
    config.opts.priority_start_cycle_with_default = true
    eq("* [#C] A", buf_lines(buf)[1])
  end)

  it("computes priorities with priority_get_priority_function", function()
    config.opts.priority_get_priority_function = function(s)
      return s:find("urgent") and 5000 or 0
    end
    org_buffer({ "* TODO urgent thing", "* TODO other" }, { 1, 0 })
    local notify = utils.notify
    utils.notify = function() end
    eq(5000, priority.show())
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq(0, priority.show())
    local file = require("org.files").get_buffer(0)
    eq(5000, require("org.agenda.items").priority_value(file.headlines[1]))
    utils.notify = notify
    config.opts.priority_get_priority_function = nil
    eq(1000, priority.show())
  end)
end)

describe("tag options", function()
  after_each(function()
    config.opts.tags_persistent = {}
    config.opts.tags_sort_function = nil
    config.opts.auto_align_tags = true
    config.opts.track_ordered_property_with_tag = false
    config.opts.use_fast_tag_selection = "auto"
    config.opts.fast_tag_selection_maximum_tags = 56
  end)

  it("adds tags_persistent before #+TAGS, unless noptag", function()
    config.opts.tags_persistent = { "@home(h) work" }
    org_buffer({ "#+TAGS: work(w) misc", "* A" }, { 2, 0 })
    local names = vim.tbl_map(function(d)
      return d.name or d.group
    end, require("org.files").get_buffer(0):tag_definitions())
    eq({ "@home", "work", "misc" }, names)
    org_buffer({ "#+STARTUP: noptag", "#+TAGS: work(w)", "* A" }, { 3, 0 })
    eq({ "work" }, tags.all_tags())
    org_buffer({ "* A :x:" }, { 1, 0 })
    eq({ "@home", "work" }, tags.all_tags())
  end)

  it("sorts tags with tags_sort_function", function()
    -- Emacs: (org-set-tags '("zz" "aa" "Mm")) gives :Mm:aa:zz: with
    -- org-string<, and keeps the order without a sort function
    local buf = org_buffer({ "* H" }, { 1, 0 })
    tags.set_tags(nil, { "zz", "aa", "Mm" })
    ok(buf_lines(buf)[1]:match(":zz:aa:Mm:$"))
    config.opts.tags_sort_function = function(a, b)
      return a < b
    end
    tags.set_tags(nil, { "zz", "aa", "Mm" })
    ok(buf_lines(buf)[1]:match(":Mm:aa:zz:$"))
    -- a list: the next function breaks ties
    config.opts.tags_sort_function = {
      function(a, b)
        return #a < #b
      end,
      function(a, b)
        return a > b
      end,
    }
    tags.set_tags(nil, { "a", "bb", "c", "aa" })
    ok(buf_lines(buf)[1]:match(":c:a:bb:aa:$"), buf_lines(buf)[1])
  end)

  -- Emacs 9.8.10 (#+TAGS: [ GTD : Control Persp ] [ Control : Context
  -- Task ], org-set-tags on :Task:Persp:Control:zzz:aaa:GTD:Context:)
  it("sorts by the tag hierarchy (org-tags-sort-hierarchy)", function()
    local function sorted(fn, group_tags)
      config.opts.tags_sort_function = fn
      config.opts.group_tags = group_tags
      local buf = org_buffer({ "#+TAGS: [ GTD : Control Persp ] [ Control : Context Task ]", "* H" }, { 2, 0 })
      tags.set_tags(nil, { "Task", "Persp", "Control", "zzz", "aaa", "GTD", "Context" })
      return buf_lines(buf)[2]:match("(:%S+:)$")
    end
    local okr, err = pcall(function()
      eq(":GTD:Control:Context:Task:Persp:aaa:zzz:", sorted("hierarchy", true))
      eq(":Context:Control:GTD:Persp:Task:aaa:zzz:", sorted("hierarchy", false))
      eq(":zzz:aaa:GTD:Persp:Control:Task:Context:", sorted({ "hierarchy", "string>" }, true))
      eq(":zzz:aaa:Task:Persp:GTD:Control:Context:", sorted({ "hierarchy", "string>" }, false))
      eq(":zzz:aaa:GTD:Persp:Control:Task:Context:", sorted({ tags.sort_hierarchy, "string>" }, true))
    end)
    config.opts.group_tags = true
    assert(okr, err)
  end)

  it("keeps the tag position with auto_align_tags = false", function()
    -- Emacs 9.8.10 with org-auto-align-tags nil
    config.opts.auto_align_tags = false
    local buf = org_buffer({ "* TODO Head   :a:", "* Two" }, { 1, 0 })
    todo.change_state(nil, "DONE")
    priority.set(nil, "A")
    require("org.structure").demote_subtree()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    tags.set_tags(nil, { "x", "y" })
    eq({ "** DONE [#A] Head   :a:", "* Two :x:y:" }, buf_lines(buf))
  end)

  it("toggles an ORDERED tag with track_ordered_property_with_tag", function()
    config.opts.track_ordered_property_with_tag = true
    local buf = org_buffer({ "* H :x:" }, { 1, 0 })
    properties.toggle_ordered()
    local l = buf_lines(buf)
    ok(l[1]:match("^%* H%s+:x:ORDERED:$"), l[1])
    eq({ ":PROPERTIES:", ":ORDERED:  t", ":END:" }, vim.list_slice(l, 2, 4))
    properties.toggle_ordered()
    ok(buf_lines(buf)[1]:match("^%* H%s+:x:$"))
    eq(1, #buf_lines(buf))
    config.opts.track_ordered_property_with_tag = "SEQ"
    buf = org_buffer({ "* H" }, { 1, 0 })
    properties.toggle_ordered()
    ok(buf_lines(buf)[1]:match("^%* H%s+:SEQ:$"))
  end)

  it("follows use_fast_tag_selection", function()
    local fast_select = tags.fast_select
    local input_complete = utils.input_complete
    local used
    tags.fast_select = function()
      used = "fast"
      return { "x" }
    end
    utils.input_complete = function()
      used = "typed"
      return ":y:"
    end
    org_buffer({ "#+TAGS: work(w) home", "* A" }, { 2, 0 })
    tags.set_tags()
    eq("fast", used)
    config.opts.use_fast_tag_selection = false
    tags.set_tags()
    eq("typed", used)
    org_buffer({ "* A :k:" }, { 1, 0 })
    config.opts.use_fast_tag_selection = "auto"
    tags.set_tags()
    eq("typed", used)
    config.opts.use_fast_tag_selection = true
    tags.set_tags()
    eq("fast", used)
    tags.fast_select = fast_select
    utils.input_complete = input_complete
  end)

  it("shows at most fast_tag_selection_maximum_tags tags", function()
    local defs = {
      { name = "a1" },
      { name = "b1", key = "z" },
      { group = "{" },
      { name = "g1" },
      { name = "g2" },
      { group = "}" },
      { name = "c1" },
      { name = "d1" },
      { name = "e1" },
    }
    config.opts.fast_tag_selection_maximum_tags = 6
    -- 6 - (1 keyed + 2 grouped) = 3 left: two unkeyed tags are shown
    local entries = tags._fast_table(defs)
    local names = {}
    for _, e in ipairs(entries) do
      if e.name then
        names[#names + 1] = e.name
      end
    end
    eq({ "a1", "b1", "g1", "g2", "c1" }, names)
  end)
end)

describe("property options", function()
  after_each(function()
    config.opts.properties_postprocess = {}
    config.opts.property_separators = {}
  end)

  it("post-processes set values by property name", function()
    -- Emacs: ("Foo" . upcase) applies to "foo" too
    config.opts.properties_postprocess = {
      Foo = function(v)
        return v:upper()
      end,
    }
    local buf = org_buffer({ "* H" }, { 1, 0 })
    properties.set_property(nil, "foo", "bar")
    properties.set_property(nil, "Other", "baz")
    eq({ "* H", ":PROPERTIES:", ":foo:      BAR", ":Other:    baz", ":END:" }, buf_lines(buf))
  end)

  it("joins PROP+ values with property_separators", function()
    -- Emacs 9.8.10: A="p, c1, c2", REX="r1|r2", B="b1 b2", K="k1 k2, k3"
    config.opts.property_separators = { { { "A", "K" }, ", " }, { "^RE", "|" } }
    config.opts.use_property_inheritance = true
    org_buffer({
      "#+PROPERTY: K k1",
      "#+PROPERTY: K+ k2",
      "* P",
      ":PROPERTIES:",
      ":A: p",
      ":REX: r1",
      ":END:",
      "** C",
      ":PROPERTIES:",
      ":A+: c1",
      ":A+: c2",
      ":REX+: r2",
      ":B: b1",
      ":B+: b2",
      ":K+: k3",
      ":END:",
    }, { 8, 0 })
    local hl = require("org.files").get_buffer(0):headline_at(8)
    eq("p, c1, c2", hl:get_property("A", true))
    eq("r1|r2", hl:get_property("REX", true))
    eq("b1 b2", hl:get_property("B", false))
    eq("k1 k2, k3", hl:get_property("K", true))
    config.opts.use_property_inheritance = false
  end)
end)

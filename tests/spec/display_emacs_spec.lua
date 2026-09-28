-- Display and visibility options of Emacs Org 9.8.10: cycling options and
-- hooks, fold commands, context detail, invisible edits and sparse-tree
-- searches. Expected states and messages come from Emacs 9.8.10 probes
-- (org-cycle with the option let-bound in a temp buffer).

local fold = require("org.fold")
local config = require("org.config")

local function closed(lnum)
  return vim.fn.foldclosed(lnum) ~= -1
end

--- Run `fn` capturing the messages of nvim_echo.
local function echoed(fn)
  local msgs = {}
  local orig = vim.api.nvim_echo
  vim.api.nvim_echo = function(chunks, ...)
    msgs[#msgs + 1] = chunks[1][1]
    return orig(chunks, ...)
  end
  local ok, err = pcall(fn)
  vim.api.nvim_echo = orig
  assert(ok, err)
  return msgs
end

--- Collect the User autocmd `pattern` states while `fn` runs.
local function hooked(pattern, fn)
  local states = {}
  local id = vim.api.nvim_create_autocmd("User", {
    pattern = pattern,
    callback = function(ev)
      states[#states + 1] = ev.data.state
    end,
  })
  local ok, err = pcall(fn)
  vim.api.nvim_del_autocmd(id)
  assert(ok, err)
  return states
end

local function visible()
  local out = {}
  for l = 1, vim.api.nvim_buf_line_count(0) do
    if fold.line_visible(l) then
      out[#out + 1] = vim.fn.getline(l)
    end
  end
  return out
end

describe("cycle options (Emacs 9.8.10)", function()
  with_config({
    cycle_skip_children_state_if_no_children = true,
    cycle_global_at_bob = false,
    cycle_max_level = nil,
  })

  it("cycle_skip_children_state_if_no_children = false shows CHILDREN first", function()
    config.opts.cycle_skip_children_state_if_no_children = false
    local buf = org_buffer({ "* A", "body", "* B" }, { 1, 0 })
    fold.setup_buffer(buf)
    fold.overview()
    -- Emacs: CHILDREN, SUBTREE, FOLDED
    local msgs = echoed(function()
      fold.cycle()
      fold.cycle()
      fold.cycle()
    end)
    eq({ "CHILDREN", "SUBTREE", "FOLDED" }, msgs)
    eq(true, closed(1))
  end)

  it("skips CHILDREN by default", function()
    local buf = org_buffer({ "* A", "body", "* B" }, { 1, 0 })
    fold.setup_buffer(buf)
    fold.overview()
    eq({ "SUBTREE (NO CHILDREN)" }, echoed(fold.cycle))
  end)

  it("runs OrgCyclePre and OrgCycle around local cycling", function()
    local buf = org_buffer({ "* A", "body", "** B", "b", "* E" }, { 1, 0 })
    fold.setup_buffer(buf)
    fold.overview()
    local pre
    local post = hooked("OrgCycle", function()
      pre = hooked("OrgCyclePre", function()
        echoed(function()
          fold.cycle()
          fold.cycle()
          fold.cycle()
        end)
      end)
    end)
    -- Emacs: org-cycle-hook and org-cycle-pre-hook get children subtree folded
    eq({ "children", "subtree", "folded" }, post)
    eq({ "children", "subtree", "folded" }, pre)
  end)

  it("cycle_global_at_bob cycles globally at the start of the buffer", function()
    config.opts.cycle_global_at_bob = true
    local buf = org_buffer({ "#+TITLE: x", "* A", "body", "** B", "b" }, { 1, 0 })
    fold.setup_buffer(buf)
    fold.show_all()
    local msgs, states
    states = hooked("OrgCycle", function()
      msgs = echoed(function()
        fold.cycle()
        eq({ "#+TITLE: x", "* A" }, visible())
        fold.cycle()
        fold.cycle()
      end)
    end)
    -- Emacs: OVERVIEW, CONTENTS, SHOW ALL; hooks get overview contents all
    eq({ "OVERVIEW", "CONTENTS", "SHOW ALL" }, msgs)
    eq({ "overview", "contents", "all" }, states)
    eq({ "#+TITLE: x", "* A", "body", "** B", "b" }, visible())
  end)

  it("cycle_max_level makes deeper headlines text for TAB", function()
    config.opts.cycle_max_level = 1
    local buf = org_buffer({ "* A", "text", "** B", "b body", "* C" }, { 1, 0 })
    fold.setup_buffer(buf)
    fold.overview()
    -- Emacs: CHILDREN shows everything (** B is text), then SUBTREE
    eq({ "CHILDREN" }, echoed(fold.cycle))
    eq({ "* A", "text", "** B", "b body", "* C" }, visible())
    eq({ "SUBTREE" }, echoed(fold.cycle))
    -- TAB on ** B indents like text (nothing to indent on a headline)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local msgs = echoed(fold.cycle)
    config.opts.cycle_max_level = nil
    eq({}, msgs)
    eq("** B", vim.fn.getline(3))
    eq(false, closed(3))
  end)

  it("cycle_max_level must be a positive integer", function()
    config.opts.cycle_max_level = 0
    org_buffer({ "* A", "b" }, { 1, 0 })
    local done, err = pcall(fold.cycle)
    config.opts.cycle_max_level = nil
    eq(false, done)
    ok(tostring(err):find("positive integer"))
  end)
end)

describe("fold commands (Emacs 9.8.10)", function()
  it("hide_entry hides the text of the entry, not its children", function()
    if not fold.conceal_supported then
      return
    end
    local buf = org_buffer({ "* A", "body", "more", "** B", "b" }, { 2, 0 })
    fold.setup_buffer(buf)
    fold.show_all()
    fold.hide_entry()
    -- Emacs: ("* A" "** B" "b")
    eq({ "* A", "** B", "b" }, visible())
    eq(1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("hide_entry closes an entry without children", function()
    local buf = org_buffer({ "* A", "body", "* B" }, { 1, 0 })
    fold.setup_buffer(buf)
    fold.show_all()
    fold.hide_entry()
    eq(true, closed(1))
    eq(false, closed(3))
  end)

  local lines = {
    "* A",
    ":PROPERTIES:",
    ":X: 1",
    ":END:",
    "#+begin_src sh",
    "echo",
    "#+end_src",
    "#+BEGIN: clocktable",
    "x",
    "#+END:",
    ":LOGBOOK:",
    "- n",
    ":END:",
  }

  it("hide_block_all folds every block, dynamic blocks too", function()
    local buf = org_buffer(lines, { 1, 0 })
    fold.setup_buffer(buf)
    fold.show_all()
    fold.hide_block_all()
    -- Emacs: the src and clocktable blocks hidden, drawers shown
    eq({ "* A", ":PROPERTIES:", ":X: 1", ":END:", "#+begin_src sh", "#+BEGIN: clocktable", ":LOGBOOK:", "- n", ":END:" }, visible())
  end)

  it("hide_drawer_all folds every drawer", function()
    local buf = org_buffer(lines, { 1, 0 })
    fold.setup_buffer(buf)
    fold.show_all()
    fold.hide_drawer_all()
    -- Emacs: the property drawer and the logbook hidden
    eq({ "* A", ":PROPERTIES:", "#+begin_src sh", "echo", "#+end_src", "#+BEGIN: clocktable", "x", "#+END:", ":LOGBOOK:" }, visible())
  end)

  it("are actions", function()
    local actions = require("org.actions").list
    ok(actions.hide_entry and actions.hide_block_all and actions.hide_drawer_all)
  end)
end)

describe("fold_show_context_detail", function()
  with_config({
    fold_show_context_detail = {
      agenda = "local",
      ["bookmark-jump"] = "lineage",
      isearch = "lineage",
      default = "ancestors",
    },
  })

  it("resolves a context like org-fold-show-context", function()
    eq("local", fold.context_detail("agenda"))
    eq("ancestors", fold.context_detail("occur-tree"))
    config.opts.fold_show_context_detail = "tree"
    eq("tree", fold.context_detail("agenda"))
    config.opts.fold_show_context_detail = true
    eq("canonical", fold.context_detail("agenda"))
    config.opts.fold_show_context_detail = false
    eq("minimal", fold.context_detail("agenda"))
  end)

  it("local shows the entry and the next headline; ancestors-full the subtree", function()
    if not fold.conceal_supported then
      return
    end
    local buf = org_buffer({ "* A", "a", "** B", "b", "*** C", "c", "** D", "d", "* E" }, { 3, 0 })
    fold.setup_buffer(buf)
    fold.overview()
    fold.show_context(3, "local")
    eq({ "* A", "** B", "b", "*** C", "* E" }, visible())
    fold.overview()
    fold.show_context(3, "ancestors-full")
    eq({ "* A", "** B", "b", "*** C", "c", "* E" }, visible())
  end)
end)

describe("catch_invisible_edits", function()
  with_config({ catch_invisible_edits = "smart" })

  it("smart: typing at the end of a headline with hidden text shows it", function()
    if not fold.conceal_supported then
      return
    end
    local buf = org_buffer({ "* A", "body", "** B", "b" }, { 1, 2 })
    fold.setup_buffer(buf)
    fold.show_all()
    fold.hide_entry()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    -- insert at the border: shown, and allowed
    vim.api.nvim_feedkeys(vim.keycode("Ax<Esc>"), "xt", false)
    eq({ "* Ax", "body", "** B", "b" }, buf_lines(buf))
    eq(true, fold.line_visible(2))
    fold.hide_entry()
    -- delete at the border (over the hidden newline): shown, refused
    if vim.fn.has("nvim-0.11") == 1 then
      vim.api.nvim_feedkeys(vim.keycode("A<Del><Esc>"), "xt", false)
      eq({ "* Ax", "body", "** B", "b" }, buf_lines(buf))
      eq(true, fold.line_visible(2))
    end
  end)

  it("<BS> after hidden lines is refused, then allowed once visible", function()
    if not fold.conceal_supported or vim.fn.has("nvim-0.11") == 0 then
      return
    end
    local buf = org_buffer({ "* A", "body", "** B", "b" }, { 1, 0 })
    fold.setup_buffer(buf)
    fold.show_all()
    fold.hide_entry()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.api.nvim_feedkeys(vim.keycode("i<BS><Esc>"), "xt", false)
    eq({ "* A", "body", "** B", "b" }, buf_lines(buf))
    eq(true, fold.line_visible(2))
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.api.nvim_feedkeys(vim.keycode("i<BS><Esc>"), "xt", false)
    eq({ "* A", "body** B", "b" }, buf_lines(buf))
  end)

  it("catch_invisible_edits_commands false turns a check off", function()
    if not fold.conceal_supported then
      return
    end
    local saved = config.opts.catch_invisible_edits_commands.meta_return
    config.opts.catch_invisible_edits_commands.meta_return = false
    local buf = org_buffer({ "* A", "body" }, { 1, 0 })
    fold.setup_buffer(buf)
    local ok_run = fold.check_invisible_edit_command("meta_return")
    config.opts.catch_invisible_edits_commands.meta_return = saved
    eq(true, ok_run)
  end)
end)

describe("sparse tree searches", function()
  with_config({ occur_case_fold_search = true, remove_highlights_with_change = true })
  local sparse = require("org.agenda.sparse")

  it("ignore case by default, like org-occur-case-fold-search", function()
    local buf = org_buffer({ "* A", "Foo here", "* B", "nothing" }, { 1, 0 })
    fold.setup_buffer(buf)
    eq(1, #sparse.regexp("foo"))
    config.opts.occur_case_fold_search = false
    eq(0, #sparse.regexp("foo"))
    config.opts.occur_case_fold_search = "smart"
    eq(1, #sparse.regexp("foo"))
    eq(0, #sparse.regexp("FOO"))
    -- \W is a class, not an upper case letter
    eq(1, #sparse.regexp("foo\\W"))
  end)

  it("runs OrgOccur after a search, not after a tags match", function()
    local buf = org_buffer({ "* A :x:", "foo", "* B" }, { 1, 0 })
    fold.setup_buffer(buf)
    local n = 0
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "OrgOccur",
      callback = function()
        n = n + 1
      end,
    })
    sparse.regexp("foo")
    sparse.match("x")
    vim.api.nvim_del_autocmd(id)
    eq(1, n)
  end)

  it("remove_highlights_with_change = false keeps the highlights", function()
    config.opts.remove_highlights_with_change = false
    local buf = org_buffer({ "* A", "foo", "* B" }, { 1, 0 })
    fold.setup_buffer(buf)
    sparse.regexp("foo")
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "* C" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    eq(true, sparse.has_highlights(buf))
    config.opts.remove_highlights_with_change = true
    sparse.regexp("foo")
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "* D" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    eq(false, sparse.has_highlights(buf))
  end)
end)

describe("toggle_custom_properties_visibility", function()
  with_config({ custom_properties = { "X" } })

  it("hides the custom properties of every drawer, case-insensitively", function()
    if not fold.conceal_supported then
      return
    end
    local buf = org_buffer({
      ":PROPERTIES:",
      ":x: top",
      ":END:",
      "* A",
      ":PROPERTIES:",
      ":X: 1",
      ":Y: 2",
      ":x: 3",
      ":END:",
      "body :X: no",
      ":X: text",
      "* B",
      ":PROPERTIES:",
      ":ID: b",
      ":END:",
    }, { 4, 0 })
    fold.setup_buffer(buf)
    fold.show_everything()
    local props = require("org.properties")
    props.toggle_custom_properties_visibility()
    -- Emacs 9.8.10 (org-custom-properties '("X"))
    eq({
      ":PROPERTIES:",
      ":END:",
      "* A",
      ":PROPERTIES:",
      ":Y: 2",
      ":END:",
      "body :X: no",
      ":X: text",
      "* B",
      ":PROPERTIES:",
      ":ID: b",
      ":END:",
    }, visible())
    eq(true, props.custom_properties_hidden(buf))
    props.toggle_custom_properties_visibility()
    eq(15, #visible())
    eq(false, props.custom_properties_hidden(buf))
  end)
end)

describe("entities_user and entities_help", function()
  local entities = require("org.entities")
  local user = {
    { "snowman", "\\diamond", true, "&#9731;", "[snowman]", "[snowman]", "☃" },
    { "alpha", "A", false, "&A;", "A", "A", "Ⓐ" },
  }
  after_each(function()
    config.opts.entities_user = {}
    entities.apply_user()
  end)

  it("lists the entities like org-entities-help", function()
    config.opts.entities_user = user
    entities.apply_user()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
    -- the *Org Entity Help* buffer of Emacs 9.8.10 with these user entities
    local expected = vim.fn.readfile(root .. "/fixtures/entities_help_emacs.txt")
    eq(expected, entities.help_lines())
    local buf = entities.help()
    eq(expected, buf_lines(buf))
    eq("org", vim.bo[buf].filetype)
    vim.cmd("close")
  end)

  it("uses user entities for export, display and completion", function()
    config.opts.entities_user = user
    entities.apply_user()
    local ox = require("org.export.ox")
    local lines = { "\\snowman{} and \\alpha" }
    -- Emacs 9.8.10: "<p>\n&#9731; and &A;\n</p>\n" and "☃ and Ⓐ\n"
    ok(ox.export_as("html", lines, { body_only = true }):find("&#9731; and &A;", 1, true))
    eq("☃ and Ⓐ\n", ox.export_as("ascii", lines, { body_only = true, ext = { ascii_charset = "utf-8" } }))
    eq("☃", entities.utf8("snowman"))
    eq("Ⓐ", entities.utf8("alpha"))
    ok(require("org.export.ast").ENTITIES.snowman)
    -- removing them restores the built-in entity
    config.opts.entities_user = {}
    entities.apply_user()
    eq("α", entities.utf8("alpha"))
    eq(nil, entities.utf8("snowman"))
    eq(nil, require("org.export.ast").ENTITIES.snowman)
  end)
end)

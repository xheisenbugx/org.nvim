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

  -- Emacs 9.8.10 (org-cycle-max-level 2, everything shown, TAB on
  -- "*** B"): with #+STARTUP: odd the limit is 3 stars, so B folds
  -- ("FOLDED", its lines hidden); without it B is text
  it("cycle_max_level counts odd levels with #+STARTUP: odd", function()
    config.opts.cycle_max_level = 2
    local buf = org_buffer({ "#+STARTUP: odd", "* A", "*** B", "b", "***** C", "c" }, { 3, 0 })
    fold.setup_buffer(buf)
    vim.cmd("normal! zR")
    local msgs = echoed(fold.cycle)
    config.opts.cycle_max_level = nil
    eq({ "FOLDED" }, msgs)
    eq({ "#+STARTUP: odd", "* A", "*** B" }, visible())
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
    eq(
      { "* A", ":PROPERTIES:", ":X: 1", ":END:", "#+begin_src sh", "#+BEGIN: clocktable", ":LOGBOOK:", "- n", ":END:" },
      visible()
    )
  end)

  it("hide_drawer_all folds every drawer", function()
    local buf = org_buffer(lines, { 1, 0 })
    fold.setup_buffer(buf)
    fold.show_all()
    fold.hide_drawer_all()
    -- Emacs: the property drawer and the logbook hidden
    eq({
      "* A",
      ":PROPERTIES:",
      "#+begin_src sh",
      "echo",
      "#+end_src",
      "#+BEGIN: clocktable",
      "x",
      "#+END:",
      ":LOGBOOK:",
    }, visible())
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
    vim.api.nvim_feedkeys(vim.keycode("A<Del><Esc>"), "xt", false)
    eq({ "* Ax", "body", "** B", "b" }, buf_lines(buf))
    eq(true, fold.line_visible(2))
  end)

  it("<BS> after hidden lines is refused, then allowed once visible", function()
    if not fold.conceal_supported then
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
    local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
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

describe("indent mode and inline tasks", function()
  local deco = require("org.ui.decorations")
  local saved_ui
  before_each(function()
    saved_ui = vim.deepcopy(config.opts.ui)
  end)
  after_each(function()
    config.opts.ui = saved_ui
    config.opts.adapt_indentation = false
    config.opts.inlinetask_min_level = false
    config.opts.inlinetask_show_first_star = false
  end)

  --- Width of the inline prefix of each row.
  local function prefixes(buf)
    local rows = deco.compute(buf)
    local out = {}
    for row = 0, vim.api.nvim_buf_line_count(buf) - 1 do
      local w = 0
      for _, m in ipairs(rows[row] or {}) do
        if m[2].virt_text_pos == "inline" and m[1] == 0 then
          for _, chunk in ipairs(m[2].virt_text) do
            w = w + vim.fn.strdisplaywidth(chunk[1])
          end
        end
      end
      out[#out + 1] = w
    end
    return out
  end

  local lines = { "* A", "text", "** B", "b text", "*** C", "c" }

  it("indents by indent_indentation_per_level columns per level", function()
    config.opts.ui.indent_mode = true
    -- Emacs 9.8.10 line-prefix lengths (org-indent-indentation-per-level 2, 3, 0)
    eq({ 0, 2, 1, 4, 2, 6 }, prefixes(org_buffer(lines)))
    config.opts.ui.indent_indentation_per_level = 3
    eq({ 0, 2, 2, 5, 4, 8 }, prefixes(org_buffer(lines)))
    config.opts.ui.indent_indentation_per_level = 0
    eq({ 0, 0, 0, 0, 0, 0 }, prefixes(org_buffer(lines)))
  end)

  it("indent_mode toggles in the buffer and runs OrgIndentMode", function()
    local buf = org_buffer(lines)
    local states = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "OrgIndentMode",
      callback = function(ev)
        states[#states + 1] = ev.data.enabled
      end,
    })
    deco.toggle_indent_mode()
    eq({ 0, 2, 1, 4, 2, 6 }, prefixes(buf))
    eq(true, deco.ui_options(buf).hide_leading_stars)
    deco.toggle_indent_mode()
    eq({ 0, 0, 0, 0, 0, 0 }, prefixes(buf))
    vim.api.nvim_del_autocmd(id)
    eq({ true, false }, states)
  end)

  it("num_mode runs OrgNumMode", function()
    org_buffer(lines)
    local states = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "OrgNumMode",
      callback = function(ev)
        states[#states + 1] = ev.data.enabled
      end,
    })
    deco.toggle_num_mode()
    deco.toggle_num_mode()
    vim.api.nvim_del_autocmd(id)
    eq({ true, false }, states)
  end)

  it("indent mode turns adapt_indentation off in its buffer", function()
    config.opts.adapt_indentation = true
    local buf = org_buffer(lines)
    eq(true, deco.adapt_indentation(buf))
    vim.b[buf].org_indent_mode = true
    -- Emacs: org-adapt-indentation is nil once org-indent-mode is on
    eq(false, deco.adapt_indentation(buf))
    eq("", require("org.edit").body_indent(1))
    config.opts.ui.indent_mode_turns_off_adapt_indentation = false
    eq(true, deco.adapt_indentation(buf))
  end)

  it("inlinetask_show_first_star shows the first star as a marker", function()
    config.opts.inlinetask_min_level = 5
    config.opts.inlinetask_show_first_star = true
    local buf = org_buffer({ "* A", "***** TODO inline" })
    -- Emacs 9.8.10 faces: org-warning, org-hide, org-hide, then org-inlinetask
    local rows = deco.compute(buf)
    local overlay
    for _, m in ipairs(rows[1]) do
      if m[2].virt_text_pos == "overlay" then
        overlay = m[2].virt_text
      end
    end
    eq({ { "*", "OrgInlinetaskFirstStar" }, { "  ", "OrgHiddenStars" } }, overlay)
    -- in indent mode the prefix carries the star: "*" + 3 columns
    config.opts.ui.indent_mode = true
    rows = deco.compute(buf)
    local inline
    for _, m in ipairs(rows[1]) do
      if m[2].virt_text_pos == "inline" then
        inline = m[2].virt_text
      elseif m[2].virt_text_pos == "overlay" then
        overlay = m[2].virt_text
      end
    end
    eq({ { "*", "OrgInlinetaskFirstStar" }, { "   ", "OrgHiddenStars" } }, inline)
    eq({ { "   ", "OrgHiddenStars" } }, overlay)
  end)
end)

-- Faces and invisible text from font-lock-ensure in Emacs 9.8.10 with
-- each option let-bound (see the comments for what Emacs showed).
describe("font-lock options", function()
  local saved_ui
  before_each(function()
    saved_ui = vim.deepcopy(config.opts.ui)
  end)
  after_each(function()
    config.opts.ui = saved_ui
  end)

  --- Syntax group (lower case: group names ignore case) at column `c`.
  local function syn(l, c)
    return vim.fn.synIDattr(vim.fn.synID(l, c, 1), "name"):lower()
  end

  --- Highlight group (after links) at each column of line `l`.
  local function groups(l)
    local out = {}
    for c = 1, #vim.fn.getline(l) do
      out[#out + 1] = vim.fn.synIDattr(vim.fn.synIDtrans(vim.fn.synID(l, c, 1)), "name")
    end
    return out
  end

  --- The line as shown with 'conceallevel' 2.
  local function shown(l)
    local s, line = "", vim.fn.getline(l)
    for c = 1, #line do
      if vim.fn.synconcealed(l, c)[1] == 0 then
        s = s .. line:sub(c, c)
      end
    end
    return s
  end

  it("hidden_keywords hides #+TITLE: and the like", function()
    config.opts.ui.hidden_keywords = { "title", "author" }
    org_buffer({ "#+TITLE: Hello", "#+AUTHOR: Me", "#+DATE: today" })
    -- Emacs: "#+TITLE:" invisible, the space and the title shown
    eq(" Hello", shown(1))
    eq(" Me", shown(2))
    eq("#+DATE: today", shown(3))
  end)

  it("hide_macro_markers hides the braces of macros", function()
    config.opts.ui.hide_macro_markers = true
    org_buffer({ "a {{{m(1)}}} b" })
    -- Emacs: {{{ and }}} invisible, all of it org-macro
    eq("a m(1) b", shown(1))
    eq("orgmacro", syn(1, 6))
    config.opts.ui.hide_macro_markers = false
    org_buffer({ "a {{{m(1)}}} b" })
    eq("a {{{m(1)}}} b", shown(1))
  end)

  it("level_color_stars_only colors only the stars", function()
    config.opts.ui.level_color_stars_only = true
    org_buffer({ "** TODO Head :t:" })
    local g = groups(1)
    local level = vim.fn.synIDattr(vim.fn.synIDtrans(vim.fn.hlID("OrgHeadlineLevel2")), "name")
    -- Emacs: "** " org-level-2, TODO org-todo, "Head" no face, the tag org-tag
    eq({ level, level, level }, { g[1], g[2], g[3] })
    eq("orgtodo", syn(1, 4))
    ok(g[9] ~= level, "the title has no level color")
  end)

  it("fontify_todo_headline highlights the text after a TODO keyword", function()
    config.opts.ui.fontify_todo_headline = true
    org_buffer({ "* TODO Head x", "* DONE y" })
    -- Emacs: org-headline-todo from "H" to the end, not on DONE headlines
    eq("orgheadlinetodo", syn(1, 8))
    eq("orgheadlinetodo", syn(1, 13))
    ok(syn(1, 3) ~= "orgheadlinetodo")
    ok(syn(2, 8) ~= "orgheadlinetodo")
  end)

  -- Emacs 9.8.10 (org-fontify-todo-headline, font-lock-ensure): on
  -- "* TODO [#A] Head [1/2] x :tag:" org-headline-todo covers the priority
  -- cookie, the text, the statistics cookie and the tags (with their own
  -- faces), and a link right after the keyword
  it("fontify_todo_headline covers the priority, cookies, tags and links", function()
    config.opts.ui.fontify_todo_headline = true
    org_buffer({ "* TODO [#A] Head [1/2] x :tag:", "* TODO [[l]] y" })
    local function in_todo(l, c)
      for _, id in ipairs(vim.fn.synstack(l, c)) do
        if vim.fn.synIDattr(id, "name"):lower() == "orgheadlinetodo" then
          return true
        end
      end
      return false
    end
    for _, c in ipairs({ 8, 11, 13, 18, 22, 24, 26, 30 }) do
      ok(in_todo(1, c), "column " .. c)
    end
    ok(not in_todo(1, 3), "the keyword")
    eq("orgpriority", (syn(1, 8):gsub("[abc]$", "")))
    eq("orgtags", syn(1, 27))
    ok(in_todo(2, 8) and in_todo(2, 13))
  end)

  it("highlight_latex_and_related picks what is highlighted", function()
    local text = { "x $a+b$ \\alpha, y_1" }
    local function names()
      local out = {}
      for c = 1, #text[1] do
        out[c] = syn(1, c)
      end
      return out
    end
    -- Emacs: nothing by default
    config.opts.ui.highlight_latex_and_related = {}
    org_buffer(text)
    for _, n in ipairs(names()) do
      ok(not n:match("^orglatex"), n)
    end
    -- latex: $a+b$
    config.opts.ui.highlight_latex_and_related = { "latex" }
    org_buffer(text)
    local n = names()
    eq({ "orglatex", "orglatex", "", "" }, { n[3], n[7], n[9], n[18] })
    -- entities: \alpha and the comma after it
    config.opts.ui.highlight_latex_and_related = { "entities" }
    org_buffer(text)
    n = names()
    eq({ "", "orglatexentity", "orglatexentity", "" }, { n[3], n[9], n[15], n[16] })
    -- script: _1
    config.opts.ui.highlight_latex_and_related = { "script" }
    org_buffer(text)
    n = names()
    eq({ "", "orglatexscript", "orglatexscript" }, { n[17], n[18], n[19] })
  end)

  it("highlight_latex_and_related native uses the tex syntax inside fragments", function()
    config.opts.ui.highlight_latex_and_related = { "native" }
    org_buffer({ "see \\(\\frac{a}{b}\\) here" })
    local stack = vim.tbl_map(function(id)
      return vim.fn.synIDattr(id, "name"):lower()
    end, vim.fn.synstack(1, 8))
    ok(vim.tbl_contains(stack, "orglatex"), vim.inspect(stack))
    ok(#stack > 1 and stack[#stack]:match("^tex"), vim.inspect(stack))
  end)
end)

describe("speed_command_hook", function()
  with_config({
    use_speed_commands = true,
    speed_command_hook = { "org-speed-command-activate", "org-babel-speed-command-activate" },
  })
  local speed = require("org.speed")
  local lines = {
    "* A",
    "#+begin_src sh",
    "echo 1",
    "#+end_src",
    "text",
    "#+begin_src sh",
    "echo 2",
    "#+end_src",
  }

  it("runs the Babel keys at the start of a src block", function()
    local buf = org_buffer(lines, { 2, 0 })
    speed.attach(buf)
    -- n: org-babel-next-src-block
    vim.api.nvim_feedkeys(vim.keycode("in"), "xt", false)
    vim.wait(100, function()
      return vim.api.nvim_win_get_cursor(0)[1] == 6
    end)
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
    eq(lines, buf_lines(buf))
    eq(6, vim.api.nvim_win_get_cursor(0)[1])
    -- not on the #+begin_src line: typed
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    eq(nil, speed.lookup("n"))
  end)

  it("tries the hook functions in order", function()
    org_buffer(lines, { 5, 0 })
    local seen
    config.opts.speed_command_hook = {
      function(key)
        seen = key
        if key == "q" then
          return "next_heading"
        end
      end,
      "org-speed-command-activate",
    }
    ok(speed.lookup("q"))
    eq("q", seen)
    eq(nil, speed.lookup("x"))
    -- without the Babel function, the src block keys are plain letters
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq(nil, speed.lookup("n"))
    config.opts.speed_command_hook = { "org-babel-speed-command-activate" }
    ok(speed.lookup("n"))
    -- nor the headline ones
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    eq(nil, speed.lookup("n"))
  end)
end)

-- org-src edit buffers, Babel commands and options, and link commands.
-- Expected buffer text, tangled files and export output come from Emacs
-- Org 9.8.10 probes (emacs -Q --batch) unless a comment says otherwise.

local babel = require("org.babel")
local special = require("org.special")
local config = require("org.config")

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function capture_messages(fn)
  local msgs = {}
  local notify = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  local ok_, err = pcall(fn)
  vim.notify = notify
  if not ok_ then
    error(err, 0)
  end
  return msgs
end

local function close_edits()
  for ebuf in pairs(special.edits) do
    if vim.api.nvim_buf_is_valid(ebuf) then
      vim.bo[ebuf].modified = false
      pcall(vim.api.nvim_buf_delete, ebuf, { force = true })
    end
  end
  pcall(vim.cmd, "silent! only!")
end

describe("org-escape-code-in-region / org-unescape-code-in-region", function()
  local input = { "* a", "  #+b", ",* c", "  ,#+d", "text * e", ",,* f", "#x" }

  it("escapes and unescapes like Emacs", function()
    local escaped = special.escape_lines(input)
    eq({ ",* a", "  ,#+b", ",,* c", "  ,,#+d", "text * e", ",,,* f", "#x" }, escaped)
    local once = special.unescape_lines(escaped)
    eq(input, once)
    eq({ "* a", "  #+b", "* c", "  #+d", "text * e", ",* f", "#x" }, special.unescape_lines(once))
  end)

  it("acts on the lines of the selection", function()
    local buf = org_buffer({ "* a", "* b", "* c" }, { 1, 0 })
    vim.fn.setpos("'<", { buf, 2, 1, 0 })
    vim.fn.setpos("'>", { buf, 3, 1, 0 })
    require("org.actions").run("escape_code_in_region")
    eq({ "* a", ",* b", ",* c" }, buf_lines(buf))
    vim.fn.setpos("'<", { buf, 2, 1, 0 })
    vim.fn.setpos("'>", { buf, 3, 1, 0 })
    require("org.actions").run("unescape_code_in_region")
    eq({ "* a", "* b", "* c" }, buf_lines(buf))
  end)
end)

describe("org-babel-remove-inline-result", function()
  local function remove(line_or_lines, pat)
    local lines = type(line_or_lines) == "table" and line_or_lines or { line_or_lines }
    local buf = org_buffer(lines, { 1, (lines[1]:find(pat, 1, true)) - 1 })
    babel.remove_inline_result()
    return buf_lines(buf)
  end

  it("removes the results macro and the white space before it", function()
    eq({ "Text src_sh{echo 1} after" }, remove("Text src_sh{echo 1}   {{{results(=1=)}}} after", "src_sh"))
    eq({ "Text src_sh{echo 1}" }, remove("Text src_sh{echo 1} {{{results(=1=)}}}", "echo"))
    eq({ "Text call_foo() x" }, remove("Text call_foo() {{{results(=1=)}}} x", "call_"))
    eq({ "Text src_sh[:results raw]{echo 1}" }, remove("Text src_sh[:results raw]{echo 1} {{{results(1)}}}", "src_"))
  end)

  it("removes a macro on the next line of the paragraph", function()
    eq({ "Text src_sh{echo 1} x" }, remove({ "Text src_sh{echo 1}", "{{{results(=1=)}}} x" }, "src_"))
  end)

  it("leaves a macro that does not follow the block", function()
    eq({ "Text src_sh{echo 1} x {{{results(=1=)}}}" }, remove("Text src_sh{echo 1} x {{{results(=1=)}}}", "src_"))
  end)

  it("is not applicable outside inline blocks", function()
    org_buffer({ "Just text {{{results(=1=)}}}" }, { 1, 0 })
    eq(false, babel.remove_inline_result())
  end)
end)

describe("org-babel-hash-at-point", function()
  it("C-c C-c on a results hash copies it and shows it", function()
    local hash = "4e1243bd22c66e76c2ba9eddc1f91394e57f9f83"
    org_buffer(
      { "#+begin_src sh :cache yes", "echo 1", "#+end_src", "", "#+RESULTS[" .. hash .. "]:", ": 1" },
      { 5, 12 }
    )
    vim.fn.setreg('"', "")
    require("org.context").context_action()
    eq(hash, vim.fn.getreg('"'))
    -- not on the hash: not applicable
    vim.api.nvim_win_set_cursor(0, { 5, 2 })
    eq(false, babel.hash_at_point())
  end)

  it("finds the hash after a time stamp (babel.hash_show_time)", function()
    local line = "#+RESULTS[(2024-01-02 10:00:00) abc123]:"
    eq("abc123", babel.hash_at(line, #"#+RESULTS[(2024-01-02 10:00:00) a"))
    eq(nil, babel.hash_at(line, 12))
  end)
end)

describe("babel options", function()
  local saved
  before_each(function()
    saved = vim.deepcopy(config.opts.babel)
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(function()
    config.opts.babel = saved
  end)

  it("uppercase_example_markers writes #+BEGIN_EXAMPLE", function()
    config.opts.babel.uppercase_example_markers = true
    local buf = org_buffer({
      "#+begin_src sh :results output",
      'for i in $(seq 12); do echo "a $i"; done',
      "#+end_src",
    }, { 1, 0 })
    babel.execute({ bufnr = buf, lnum = 1, sync = true })
    local lines = buf_lines(buf)
    eq("#+BEGIN_EXAMPLE", lines[6])
    eq("a 1", lines[7])
    eq("#+END_EXAMPLE", lines[#lines])
  end)

  local ox = require("org.export.ox")

  it("exp_code_template fills the block's fields and header arguments", function()
    config.opts.babel.exp_code_template =
      "#+begin_src %lang :name %name :var %var :exports %exports :noweb %noweb%switches%header-args\n%body\n#+end_src"
    local out = ox.babel_process({
      "#+name: foo",
      "#+begin_src sh -n :exports code :var x=1",
      "echo $x",
      ",* a",
      "#+end_src",
      "",
      "after",
    }, {})
    eq({
      "#+name: foo",
      '#+begin_src sh :name foo :var (x . 1) :exports "code" :noweb "no" -n :exports code :var x=1',
      "echo $x",
      ",* a",
      "#+end_src",
      "",
      "after",
    }, out)
  end)

  it("exp_inline_code_template", function()
    config.opts.babel.exp_inline_code_template = "=%lang: %body= (%exports) [%header-args] {%switches}"
    eq(
      { 'Text =sh: echo 1= ("code") [ :exports code] {} after {{{results(=3=)}}} x' },
      ox.babel_process({ "Text src_sh[:exports code]{echo 1} after src_sh{echo 3} {{{results(=3=)}}} x" }, {})
    )
  end)

  -- Emacs 9.8.10 (org-babel-exp-process-buffer with these templates): a
  -- block without :flags gets "" for %flags, a field that isn't a header
  -- stays literal, and %results lists the words in org-babel-merge-params'
  -- order without an implied "value".
  it("exp_code_template %flags and %results like org-babel-exp-code", function()
    config.opts.babel.exp_code_template =
      "#+begin_src %lang :flags %flags R=%results E=%exports X=%nosuch\n%body\n#+end_src"
    config.opts.babel.exp_inline_code_template = "src_%lang[%switches%flags]{%body} R=%results"
    local function exp(block)
      return ox.babel_process(vim.split(block, "\n", { plain = true }), {})
    end
    local cases = {
      { "#+begin_src sh", 'R="replace"' },
      { "#+begin_src sh :results output", 'R="output replace"' },
      { "#+begin_src sh :results output silent :exports code", 'R="silent output"' },
    }
    for _, c in ipairs(cases) do
      eq(
        { "#+begin_src sh :flags  " .. c[2] .. ' E="code" X=%nosuch', "echo hi", "#+end_src" },
        exp(c[1] .. "\necho hi\n#+end_src")
      )
    end
    eq(
      { '#+begin_src sh :flags  -r R="replace" E="code" X=%nosuch', "echo hi", "#+end_src" },
      exp("#+begin_src sh -n :flags -r\necho hi\n#+end_src")
    )
    eq({ 'Text src_sh[]{echo hi} R="raw replace" end' }, exp("Text src_sh[:results raw :exports code]{echo hi} end"))
    eq({ 'Text src_sh[]{echo hi} R="replace" end' }, exp("Text src_sh[:exports code]{echo hi} end"))
  end)

  it("exp_call_line_template replaces #+CALL lines and call_ objects", function()
    config.opts.babel.exp_call_line_template = "\n: call: %line"
    eq(
      { "", ": call: foo()", "", "#+RESULTS:", ": 1", "", "next" },
      ox.babel_process({
        "#+name: foo",
        "#+begin_src sh :exports none",
        "echo 1",
        "#+end_src",
        "",
        "#+call: foo()",
        "",
        "#+RESULTS:",
        ": 1",
        "",
        "next",
      }, {})
    )
    config.opts.babel.exp_call_line_template = "CALLED[%line]"
    eq(
      { "Inline CALLED[call_foo()] {{{results(=1=)}}} here.", "", "CALLED[foo()]", "", "#+RESULTS:", ": 1" },
      ox.babel_process({
        "Inline call_foo() {{{results(=1=)}}} here.",
        "",
        "#+call: foo()",
        "",
        "#+RESULTS:",
        ": 1",
      }, {})
    )
  end)

  local function tangle(lines)
    local dir = tmpdir()
    local buf = org_buffer(lines, { 1, 0 })
    vim.api.nvim_buf_set_name(buf, dir .. "/t.org")
    babel.tangle({ bufnr = buf, silent = true })
    vim.bo[buf].modified = false
    return dir, buf
  end

  it("process_comment_text processes :comments org text", function()
    config.opts.babel.process_comment_text = function(s)
      return s:upper()
    end
    local dir = tangle({
      "* Section",
      "  Some prose",
      "  text.",
      "",
      "#+begin_src sh :tangle out.sh :comments org",
      "echo two",
      "#+end_src",
    })
    eq({ "# SECTION", "#   SOME PROSE", "#   TEXT.", "", "", "echo two" }, vim.fn.readfile(dir .. "/out.sh"))
  end)

  it("tangle_remove_file_before_write keeps or replaces a symlinked target", function()
    local lines = { "#+begin_src sh :tangle out.sh", "echo two", "#+end_src" }
    for _, case in ipairs({ { false, true }, { "auto", true }, { true, false } }) do
      config.opts.babel.tangle_remove_file_before_write = case[1]
      local dir = tmpdir()
      vim.fn.writefile({ "old" }, dir .. "/real.sh")
      vim.uv.fs_symlink(dir .. "/real.sh", dir .. "/out.sh")
      local buf = org_buffer(lines, { 1, 0 })
      vim.api.nvim_buf_set_name(buf, dir .. "/t.org")
      babel.tangle({ bufnr = buf, silent = true })
      vim.bo[buf].modified = false
      local link = vim.uv.fs_lstat(dir .. "/out.sh")
      eq(case[2], link.type == "link", vim.inspect(case))
      eq(case[2] and { "echo two" } or { "old" }, vim.fn.readfile(dir .. "/real.sh"), vim.inspect(case))
      eq({ "echo two" }, vim.fn.readfile(dir .. "/out.sh"))
    end
  end)
end)

describe("coderef_label_format", function()
  with_config({ coderef_label_format = "<<%s>>" })

  it("finds and exports labels in the configured format", function()
    local lines = { "#+begin_src sh", "echo a", "echo b  <<two>>", "#+end_src", "", "See [[(two)]]." }
    org_buffer(lines, { 6, 7 })
    require("org.links").open_at_point()
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
    config.opts.babel.evaluate_on_export = false
    local h = require("org.export").to_string("html", { lines = lines, body_only = true })
    config.opts.babel.evaluate_on_export = true
    ok(h:find('<span id="coderef-two" class="coderef-off">echo b (two)</span>', 1, true), h)
  end)
end)

describe("org-src edit buffers", function()
  local confirm
  before_each(function()
    confirm = vim.fn.confirm
    config.opts.win_split_mode = "split"
  end)
  after_each(function()
    vim.fn.confirm = confirm
    config.opts.win_split_mode = config.defaults.win_split_mode
    close_edits()
  end)

  local block = { "* H", "#+begin_src python", "x = 1", "#+end_src", "after" }

  it("shows how to exit or abort in the winbar", function()
    org_buffer(block, { 3, 0 })
    babel.edit_special()
    eq("Edit, then exit with ‘<C-c>'’ or abort with ‘<C-c><C-k>’", vim.wo.winbar)
  end)

  it("edit_src_persistent_message = false shows nothing", function()
    config.opts.edit_src_persistent_message = false
    org_buffer(block, { 3, 0 })
    babel.edit_special()
    config.opts.edit_src_persistent_message = true
    eq("", vim.wo.winbar)
  end)

  it("returns to the existing edit buffer after asking", function()
    local src = org_buffer(block, { 3, 0 })
    local first = babel.edit_special()
    vim.api.nvim_buf_set_lines(first, 0, -1, false, { "x = 2" })
    local asked
    vim.fn.confirm = function(msg)
      asked = msg
      return 1
    end
    vim.cmd("wincmd p")
    eq(src, vim.api.nvim_get_current_buf())
    eq(first, babel.edit_special())
    eq("Return to existing edit buffer ([n] will revert changes)? ", asked)
    eq(first, vim.api.nvim_get_current_buf())
    eq({ "x = 2" }, buf_lines(first))
  end)

  it("answering no discards the old edit buffer", function()
    org_buffer(block, { 3, 0 })
    local first = babel.edit_special()
    vim.api.nvim_buf_set_lines(first, 0, -1, false, { "x = 2" })
    vim.fn.confirm = function()
      return 2
    end
    vim.cmd("wincmd p")
    local second = babel.edit_special()
    ok(second ~= first)
    ok(not vim.api.nvim_buf_is_valid(first))
    eq({ "x = 1" }, buf_lines(second))
  end)

  it("src_ask_before_returning_to_edit_buffer = false goes back at once", function()
    config.opts.src_ask_before_returning_to_edit_buffer = false
    vim.fn.confirm = function()
      error("asked")
    end
    org_buffer(block, { 3, 0 })
    local first = babel.edit_special()
    vim.cmd("wincmd p")
    local again = babel.edit_special()
    config.opts.src_ask_before_returning_to_edit_buffer = true
    eq(first, again)
  end)

  it("edit_src_continue goes back to the edit buffer of the region at the cursor", function()
    local src = org_buffer(block, { 3, 0 })
    local ebuf = babel.edit_special()
    vim.cmd("wincmd p")
    eq(src, vim.api.nvim_get_current_buf())
    special.continue_at_point()
    eq(ebuf, vim.api.nvim_get_current_buf())
    vim.cmd("wincmd p")
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    local msgs = capture_messages(function()
      special.continue_at_point()
    end)
    eq(src, vim.api.nvim_get_current_buf())
    ok(vim.tbl_contains(msgs, "No sub-editing buffer for area at point"), vim.inspect(msgs))
  end)

  it("edit_src_auto_save_idle_delay writes the edit buffer back after a pause", function()
    config.opts.edit_src_auto_save_idle_delay = 0.05
    local src = org_buffer(block, { 3, 0 })
    local ebuf = babel.edit_special()
    config.opts.edit_src_auto_save_idle_delay = 0
    vim.api.nvim_buf_set_lines(ebuf, 0, -1, false, { "x = 3" })
    ok(
      vim.wait(2000, function()
        return buf_lines(src)[3] == "  x = 3"
      end, 10),
      vim.inspect(buf_lines(src))
    )
    ok(not vim.bo[ebuf].modified)
    ok(vim.api.nvim_buf_is_valid(ebuf))
  end)

  it("edit_src_turn_on_auto_save saves the contents to a file next to the Org file", function()
    config.opts.edit_src_turn_on_auto_save = true
    local dir = tmpdir()
    local src = org_buffer(block, { 3, 0 })
    vim.api.nvim_buf_set_name(src, dir .. "/a.org")
    local ebuf = babel.edit_special()
    config.opts.edit_src_turn_on_auto_save = false
    vim.api.nvim_buf_set_lines(ebuf, 0, -1, false, { "x = 4" })
    vim.api.nvim_exec_autocmds("CursorHold", { buffer = ebuf })
    local files = vim.fn.glob(dir .. "/org-src-*.txt", false, true)
    eq(1, #files)
    local suffix = vim.pesc(os.date("-%Y-%d-%m") .. ".txt")
    ok(vim.fs.basename(files[1]):match("^org%-src%-%w%w%w%w%w%w" .. suffix .. "$"), files[1])
    eq({ "x = 4" }, vim.fn.readfile(files[1]))
    vim.bo[src].modified = false
  end)

  it("edit_fixed_width_region_mode sets the filetype of fixed-width edits", function()
    config.opts.edit_fixed_width_region_mode = "text"
    org_buffer({ ": a", ": b" }, { 1, 0 })
    require("org.context").edit_special()
    config.opts.edit_fixed_width_region_mode = nil
    eq("text", vim.bo.filetype)
    eq({ "a", "b" }, buf_lines(0))
  end)

  it("src_lang_modes chooses the filetype of the edit buffer", function()
    org_buffer({ "#+begin_src C", "int x;", "#+end_src" }, { 2, 0 })
    babel.edit_special()
    eq("c", vim.bo.filetype)
    close_edits()
    config.opts.src_lang_modes.mylang = "python"
    org_buffer({ "#+begin_src mylang", "x = 1", "#+end_src" }, { 2, 0 })
    babel.edit_special()
    config.opts.src_lang_modes.mylang = nil
    eq("python", vim.bo.filetype)
  end)

  it("associates the edit buffer with the block's session", function()
    config.opts.babel.confirm_evaluate = false
    require("org.babel.session").kill_all()
    -- no filetype: the lua ftplugin needs a treesitter parser
    config.opts.src_lang_modes.lua = ""
    org_buffer({ "#+begin_src lua :session assoc", "assoc_value = 41", "#+end_src" }, { 2, 0 })
    local ebuf = babel.edit_special()
    eq("assoc", vim.b[ebuf].org_babel_session)
    local sess = babel.send_to_associated_session(ebuf)
    ok(sess)
    ok(vim.wait(2000, function()
      return sess.env and sess.env.assoc_value == 41
    end, 10))
    require("org.babel.session").kill_all()
    config.opts.babel.confirm_evaluate = true
    -- a block without a session is not associated
    close_edits()
    org_buffer({ "#+begin_src lua", "x = 1", "#+end_src" }, { 2, 0 })
    ebuf = babel.edit_special()
    config.opts.src_lang_modes.lua = nil
    eq(nil, vim.b[ebuf].org_babel_session)
  end)
end)

describe("src_tab_acts_natively", function()
  -- Emacs indents with the language's major mode; Neovim with the
  -- filetype's indentexpr, so only the normalisation of the body to the
  -- content indentation is compared with Emacs.
  local function tab(lines, lnum, col)
    local buf = org_buffer(lines, { lnum, col or 0 })
    vim.bo[buf].shiftwidth = 2
    require("org.element").indent_line(lnum)
    return buf_lines(buf), vim.api.nvim_win_get_cursor(0)
  end

  it("indents the line with the language's indentation", function()
    local lines = tab({ "* h", "#+begin_src c", "int f() {", "return 1;", "}", "#+end_src" }, 4)
    eq({ "* h", "#+begin_src c", "  int f() {", "    return 1;", "  }", "#+end_src" }, lines)
    local l2, cursor = tab({ "* h", "#+begin_src c", "int f() {", "return 1;", "}", "#+end_src" }, 4, 3)
    eq("    return 1;", l2[4])
    eq({ 4, 7 }, cursor)
  end)

  it("keeps -i blocks as written apart from the line", function()
    local lines = tab({ "* h", "#+begin_src c -i", "int f() {", "return 1;", "}", "#+end_src" }, 4)
    eq({ "* h", "#+begin_src c -i", "int f() {", "  return 1;", "}", "#+end_src" }, lines)
  end)

  it("indents like the previous line without an indent function (Emacs 9.8.10)", function()
    local lines = tab({ "* h", "#+begin_src unknownlang", "a", "    b", "#+end_src" }, 4)
    eq({ "* h", "#+begin_src unknownlang", "  a", "  b", "#+end_src" }, lines)
  end)

  it("does nothing when off", function()
    config.opts.src_tab_acts_natively = false
    local lines = tab({ "* h", "#+begin_src c", "int f() {", "return 1;", "}", "#+end_src" }, 4)
    config.opts.src_tab_acts_natively = true
    eq({ "* h", "#+begin_src c", "int f() {", "return 1;", "}", "#+end_src" }, lines)
  end)
end)

describe("src_block_faces", function()
  it("gives the body of src blocks their language's face", function()
    config.opts.ui.src_block_faces = { python = { bg = "#e5ffb8" }, [""] = "CursorLine" }
    local buf = org_buffer({ "#+begin_src python", "x = 1", "#+end_src", "#+begin_src", "y", "#+end_src", "text" })
    local deco = require("org.ui.decorations")
    local rows = deco.compute(buf, 0, 6, deco.ui_options(buf))
    config.opts.ui.src_block_faces = {}
    local hl = require("org.highlights")
    local function group(row)
      for _, m in ipairs(rows[row] or {}) do
        if m[2].hl_group then
          return m[2].hl_group
        end
      end
    end
    eq(hl.face_group("orgSrcBlockFace_", "python"), group(1))
    eq(hl.face_group("orgSrcBlockFace_", ""), group(4))
    eq(nil, group(0))
    eq(nil, group(6))
    eq("#e5ffb8", string.format("#%06x", vim.api.nvim_get_hl(0, { name = group(1) }).bg))
  end)
end)

describe("org-link-open-from-string", function()
  it("opens the link of a string", function()
    org_buffer({ "* One", "* Target", "text" }, { 1, 0 })
    require("org.links").open_from_string("[[*Target]]  ")
    eq(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("rejects strings that are not just a link", function()
    org_buffer({ "* One" }, { 1, 0 })
    local links = require("org.links")
    local msgs = capture_messages(function()
      links.open_from_string("foo")
      links.open_from_string("[[foo]] bar")
      links.open_from_string(" https://x.org")
      links.open_from_string("<https://x.org> y")
    end)
    eq({
      'No valid link in "foo"',
      'Garbage after link in "[[foo]] bar" ("bar")',
      'No valid link in " https://x.org"',
      'Garbage after link in "<https://x.org> y" ("y")',
    }, msgs)
  end)
end)

describe("links.info_other_documents", function()
  it("maps info: manuals to their URL in HTML export", function()
    config.opts.links.info_other_documents.foo = "https://ex.org/foo.html"
    local h = require("org.export").to_string("html", { lines = { "See [[info:foo#Node X][d]]." }, body_only = true })
    config.opts.links.info_other_documents.foo = nil
    ok(h:find('<a href="https://ex.org/foo.html#Node-X">d</a>', 1, true), h)
  end)
end)

describe("export: spaces after dropped objects (org-export--keep-spaces)", function()
  it("keeps no spaces after an object that follows another object", function()
    local ox = require("org.export.ox")
    local function ascii(s)
      return (ox.export_as("ascii", { s }, { body_only = true, ext = { ascii_charset = "utf-8" } }))
    end
    -- Emacs 9.8.10: "Text c" and "Foo. Bar"
    eq("Text c", vim.trim(ascii("Text @@html:a@@@@html:b@@ c")))
    eq("Foo. Bar", vim.trim(ascii("Foo.@@html:a@@ Bar")))
  end)
end)

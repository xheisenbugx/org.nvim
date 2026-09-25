local babel = require("org.babel")
local langs = require("org.babel.langs")
local config = require("org.config")

local function tmpdir()
  local dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  return dir
end

local function has(exe)
  return vim.fn.executable(exe) == 1
end

--- Resolve `raw` as the :var value of the block at `lnum`.
local function var(buf, lnum, raw)
  local b = babel.at_block(buf, lnum)
  return babel.resolve_var(buf, raw, b.args, {}, { skip_confirm = true })
end

describe("babel :var (Emacs references)", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
    config.opts.babel.evaluate_on_export = false
    babel.library = {}
  end)

  it("evaluates a referenced block, with arguments and an index", function()
    local buf = org_buffer({
      "#+NAME: square",
      "#+begin_src lua :var n=2",
      "return n * n",
      "#+end_src",
      "",
      "#+NAME: rows",
      "#+begin_src lua",
      "return {{1, 2}, {3, 4}}",
      "#+end_src",
      "",
      "#+begin_src lua :var a=square :var b=square(n=5) :var c=rows[1,0]",
      "return a + b + c",
      "#+end_src",
    }, { 12, 0 })
    eq(4, var(buf, 12, "square"))
    eq(25, var(buf, 12, "square(n=5)"))
    eq(3, var(buf, 12, "rows[1,0]"))
    eq({ 3, 4 }, var(buf, 12, "rows(  )[-1]"))
    -- no #+RESULTS needed: the referenced blocks are evaluated
    babel.execute({ bufnr = buf, lnum = 12, sync = true })
    ok(vim.tbl_contains(buf_lines(buf), ": 32"), vim.inspect(buf_lines(buf)))
    eq(nil, (function()
      for _, l in ipairs(buf_lines(buf)) do
        if l == "#+RESULTS: square" then
          return true
        end
      end
    end)(), "referenced block results must not be inserted")
  end)

  it("name[] is the body; a named #+CALL; header args in a reference", function()
    local buf = org_buffer({
      "#+NAME: code",
      "#+begin_src sh :results output",
      "echo from-sh",
      "#+end_src",
      "",
      "#+NAME: dbl",
      "#+begin_src lua :var n=1",
      "return n * 2",
      "#+end_src",
      "",
      "#+NAME: twenty",
      "#+CALL: dbl(n=10)",
      "",
      "#+begin_src lua",
      "return 1",
      "#+end_src",
    }, { 15, 0 })
    eq("echo from-sh", var(buf, 15, "code[]"))
    eq(20, var(buf, 15, "twenty"))
    eq(14, var(buf, 15, "dbl[:var n=3](n=7)"))
  end)

  it("reads named lists, fixed-width text and examples", function()
    local buf = org_buffer({
      "#+NAME: fruits",
      "- apple",
      "- banana",
      "  - nested",
      "- 3",
      "",
      "#+NAME: fixed",
      ": 12",
      "",
      "#+NAME: ex",
      "#+begin_example",
      "line one",
      "#+end_example",
      "",
      "#+begin_src lua",
      "return 1",
      "#+end_src",
    }, { 16, 0 })
    eq({ "apple", "banana", 3 }, var(buf, 16, "fruits"))
    eq(12, var(buf, 16, "fixed"))
    eq("line one", var(buf, 16, "ex"))
  end)

  it("Emacs Lisp values, IDs, other files and missing references", function()
    local dir = tmpdir()
    vim.fn.writefile({ "#+NAME: remote", "| a | 1 |", "| b | 2 |" }, dir .. "/other.org")
    local buf = org_buffer({
      "* Notes",
      "  :PROPERTIES:",
      "  :ID: notes-id",
      "  :END:",
      "Some text.",
      "* Code",
      "#+begin_src lua",
      "return 1",
      "#+end_src",
    }, { 8, 0 })
    vim.api.nvim_buf_set_name(buf, dir .. "/main.org")
    eq({ 1, 2, 3 }, var(buf, 8, "'(1 2 3)"))
    eq(3, var(buf, 8, "(+ 1 2)"))
    eq({ { "a", 1 }, { "b", 2 } }, var(buf, 8, "other.org:remote"))
    eq("Some text.", var(buf, 8, "notes-id"))
    local okv, err = pcall(var, buf, 8, "nothing_here")
    ok(not okv and tostring(err):find("not found"), tostring(err))
    vim.bo[buf].modified = false
  end)

  it(":hlines yes keeps horizontal lines; bash arrays; :separator", function()
    local buf = org_buffer({
      "#+NAME: t",
      "| k | v |",
      "|---+---|",
      "| x | 1 |",
      "|---+---|",
      "| y | 2 |",
      "",
      "#+begin_src lua :var t=t :hlines yes :colnames no",
      "return #t",
      "#+end_src",
    }, { 9, 0 })
    local b = babel.at_block(buf, 9)
    local t = babel.resolve_var(buf, "t", b.args, {}, {})
    eq({ { "k", "v" }, "hline", { "x", 1 }, "hline", { "y", 2 } }, t)
    local rows = { { "x", 1, "p" }, { "y", 2, "q" } }
    eq(
      { "unset t", "declare -A t", "t['x']='1\np'", "t['y']='2\nq'" },
      langs.var_lines("bash", { { name = "t", value = rows } })
    )
    eq({ "unset l", "declare -a l=( 'a' 'b' )" }, langs.var_lines("bash", { { name = "l", value = { "a", "b" } } }))
    eq({ "t='x,1,p\ny,2,q'" }, langs.var_lines("sh", { { name = "t", value = rows } }, { separator = "," }))
    eq({ 'x = [["a"],None]' }, langs.var_lines("python", { { name = "x", value = { { "a" }, "hline" } } }))
    eq({ "my $x = [['a', 1], undef];" }, langs.var_lines("perl", { { name = "x", value = { { "a", 1 }, "hline" } } }))
  end)

  it("bash receives tables as associative arrays", function()
    if not has("bash") then
      return
    end
    local buf = org_buffer({
      "#+NAME: ages",
      "| ann | 31 |",
      "| bob | 40 |",
      "",
      "#+begin_src bash :var a=ages :results output",
      'echo "${a[bob]}"',
      "#+end_src",
    }, { 6, 0 })
    babel.execute({ bufnr = buf, lnum = 5, sync = true })
    ok(vim.tbl_contains(buf_lines(buf), ": 40"), vim.inspect(buf_lines(buf)))
  end)

  it("shell :results value is the exit status; :stdin feeds a reference", function()
    local buf = org_buffer({
      "#+NAME: input",
      "| 3 |",
      "| 1 |",
      "| 2 |",
      "",
      "#+begin_src sh :results value",
      "(exit 3)",
      "#+end_src",
    }, { 7, 0 })
    babel.execute({ bufnr = buf, lnum = 6, sync = true })
    ok(vim.tbl_contains(buf_lines(buf), ": 3"), vim.inspect(buf_lines(buf)))
    local buf2 = org_buffer({
      "#+NAME: input",
      "| 3 |",
      "| 1 |",
      "| 2 |",
      "",
      "#+begin_src sh :stdin input :results output",
      "sort | paste -sd ' ' -",
      "#+end_src",
    }, { 7, 0 })
    babel.execute({ bufnr = buf2, lnum = 6, sync = true })
    ok(vim.tbl_contains(buf_lines(buf2), ": 1 2 3"), vim.inspect(buf_lines(buf2)))
  end)

  it("sqlite replaces $var with values and tables with a CSV file", function()
    if not has("sqlite3") then
      return
    end
    local buf = org_buffer({
      "#+NAME: nums",
      "| 1 | one |",
      "| 2 | two |",
      "",
      "#+begin_src sqlite :var n=2 :var t=nums :results output",
      ".mode csv",
      "create table x(a, b);",
      ".import $t x",
      "select b from x where a = '$n';",
      "#+end_src",
    }, { 6, 0 })
    babel.execute({ bufnr = buf, lnum = 5, sync = true })
    ok(vim.tbl_contains(buf_lines(buf), ": two"), vim.inspect(buf_lines(buf)))
  end)

  it("noweb <<name(args)>> inserts the evaluated result", function()
    local buf = org_buffer({
      "#+NAME: answer",
      "#+begin_src lua :var n=1",
      "return n * 21",
      "#+end_src",
      "",
      "#+begin_src lua :noweb yes",
      "return <<answer(n=2)>>",
      "#+end_src",
    }, { 7, 0 })
    babel.execute({ bufnr = buf, lnum = 6, sync = true })
    ok(vim.tbl_contains(buf_lines(buf), ": 42"), vim.inspect(buf_lines(buf)))
  end)

  it("lua :epilogue runs after the body; :results file links the value", function()
    local buf = org_buffer({
      "#+begin_src lua :epilogue \"print('after')\" :results output",
      "print('body')",
      "#+end_src",
    }, { 2, 0 })
    babel.execute({ bufnr = buf, lnum = 1, sync = true })
    eq({ ": body", ": after" }, vim.list_slice(buf_lines(buf), 6, 7))
    local buf2 = org_buffer({ "#+begin_src lua :results file", "return 'img/plot.png'", "#+end_src" }, { 2, 0 })
    babel.execute({ bufnr = buf2, lnum = 1, sync = true })
    ok(vim.tbl_contains(buf_lines(buf2), "[[file:img/plot.png]]"), vim.inspect(buf_lines(buf2)))
  end)

  it("evaluates inline calls call_name(args)", function()
    local buf = org_buffer({
      "#+NAME: inc",
      "#+begin_src lua :var x=0",
      "return x + 1",
      "#+end_src",
      "",
      "Next: call_inc(x=41) here.",
    }, { 6, 9 })
    babel.execute_block()
    ok(vim.wait(5000, function()
      return buf_lines(buf)[6]:find("{{{results", 1, true) ~= nil
    end, 20), vim.inspect(buf_lines(buf)))
    eq("Next: call_inc(x=41) {{{results(=42=)}}} here.", buf_lines(buf)[6])
    local ib = babel.inline_at("a call_f[:results raw](y=1)[:exports both] b", 4)
    eq({ "f", ":results raw", "y=1", ":exports both" }, { ib.target, ib.inside, ib.call_args, ib.params })
  end)

  it("evaluates code for export without touching the buffer", function()
    local buf = org_buffer({
      "#+begin_src lua :exports results",
      "return 6 * 7",
      "#+end_src",
      "",
      "#+begin_src lua :exports code",
      "return 'never'",
      "#+end_src",
      "",
      "#+begin_src lua :exports both :eval never-export",
      "return 'skipped'",
      "#+end_src",
      "",
      "Inline src_lua{return 1 + 1} value.",
    })
    local before = buf_lines(buf)
    local out = babel.export_evaluate(buf)
    eq(before, buf_lines(buf))
    ok(vim.tbl_contains(out, ": 42"), vim.inspect(out))
    ok(not vim.tbl_contains(out, ": never"), vim.inspect(out))
    ok(not vim.tbl_contains(out, ": skipped"), vim.inspect(out))
    ok(vim.tbl_contains(out, "Inline src_lua{return 1 + 1} {{{results(=2=)}}} value."), vim.inspect(out))
    config.opts.babel.evaluate_on_export = true
    local html = require("org.export").export("html", { bufnr = buf, to_buffer = true })
    eq("buffer", html)
    local text = table.concat(buf_lines(0), "\n")
    vim.cmd("bwipeout!")
    ok(text:find("42", 1, true), text)
  end)

  it("hash, bindings list, mark block and keys in the edit buffer", function()
    local buf = org_buffer({ "#+begin_src sh :cache yes", "echo 1", "#+end_src" }, { 2, 0 })
    local hash = babel.sha1_hash()
    babel.execute({ bufnr = buf, lnum = 1, sync = true })
    eq("#+RESULTS[" .. hash .. "]:", buf_lines(buf)[5])
    babel.describe_bindings()
    local shown = table.concat(buf_lines(0), "\n")
    vim.cmd("close")
    ok(shown:find("Load src block into its session", 1, true), shown)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    babel.mark_block()
    eq("V", vim.fn.mode())
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    babel.do_key_sequence_in_edit_buffer("A # one<Esc>")
    -- written back indented by org-src-content-indentation (2), like Emacs
    eq("  echo 1 # one", buf_lines(buf)[2])
    eq(buf, vim.api.nvim_get_current_buf())
  end)
end)

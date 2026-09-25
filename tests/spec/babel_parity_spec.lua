-- Babel behaviour checked against Emacs Org 9.8.10 (org-babel-execute-buffer
-- and org-babel-tangle in `emacs --batch`): the expected lines below are
-- what Emacs produced for the same input.
local babel = require("org.babel")
local blocks = require("org.babel.blocks")
local lisp = require("org.babel.lisp")
local config = require("org.config")

local function has(exe)
  return vim.fn.executable(exe) == 1
end

local function tmpdir()
  local dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Execute the whole buffer (org-babel-execute-buffer) and return its lines.
local function run(lines, name)
  local dir = tmpdir()
  local buf = org_buffer(lines, { 1, 0 })
  vim.api.nvim_buf_set_name(buf, dir .. "/" .. (name or "t.org"))
  babel.execute_buffer({ bufnr = buf, skip_confirm = true, sync = true })
  vim.bo[buf].modified = false
  return buf_lines(buf), dir, buf
end

--- The result lines of the block whose first line is `head` in `out`.
local function result_of(out, head)
  for i, l in ipairs(out) do
    if l == head then
      local k = i + 1
      while out[k] and not out[k]:match("^#%+[Rr][Ee][Ss][Uu][Ll][Tt][Ss]") do
        k = k + 1
      end
      local res = {}
      k = k + 1
      while out[k] and out[k] ~= "" and not out[k]:match("^#%+begin_src") and not out[k]:match("^#%+CALL") do
        res[#res + 1] = out[k]
        k = k + 1
      end
      return res
    end
  end
end

describe("babel parity: header arguments", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)

  it("keeps property names with colons (:header-args:python:)", function()
    local f = require("org.parser").parse({
      "* H",
      ":PROPERTIES:",
      ":header-args:python: :var P=1",
      ":header-args: :var Q=2",
      ":header-args:sh+: :var R=3",
      ":URL: http://example.com/a:b",
      ":END:",
    })
    local props = f.headlines[1].properties
    eq(":var P=1", props["HEADER-ARGS:PYTHON"])
    eq(":var Q=2", props["HEADER-ARGS"])
    eq(":var R=3", props["HEADER-ARGS:SH"])
    eq("http://example.com/a:b", props.URL)
    eq(true, f.headlines[1].properties_extend["HEADER-ARGS:SH"])
  end)

  it("inherits header-args like org-entry-get: nearest wins, + accumulates", function()
    -- Emacs: X= Y=1 (the headline's header-args hides #+PROPERTY), then
    -- X= Y=1 Z=2 (header-args+ adds to the inherited value)
    local out = run({
      "#+PROPERTY: header-args :results output",
      "#+PROPERTY: header-args+ :var X=7",
      "",
      "* H1",
      ":PROPERTIES:",
      ":header-args: :var Y=1",
      ":END:",
      "#+begin_src sh",
      'echo "X=$X Y=$Y"',
      "#+end_src",
      "** H2",
      ":PROPERTIES:",
      ":header-args+: :var Z=2",
      ":END:",
      "#+begin_src sh :results output",
      'echo "X=$X Y=$Y Z=$Z"',
      "#+end_src",
    })
    eq({ ": X= Y=1" }, result_of(out, "#+begin_src sh"))
    eq({ ": X= Y=1 Z=2" }, result_of(out, "#+begin_src sh :results output"))
  end)

  it("#+HEADER lines override the #+begin_src line", function()
    local out = run({
      "#+HEADER: :var a=1",
      "#+HEADER: :var a=2",
      "#+begin_src sh :var a=3 :results output",
      "echo $a",
      "#+end_src",
    })
    eq({ ": 2" }, result_of(out, "#+begin_src sh :var a=3 :results output"))
  end)

  it("maps positional call arguments onto the variables in order", function()
    if not has("python3") then
      return
    end
    local out = run({
      "#+NAME: add",
      "#+begin_src python :var a=1 b=2",
      "return a + b",
      "#+end_src",
      "",
      "#+CALL: add(10)",
      "",
      "#+CALL: add(10, 20)",
      "",
      "#+CALL: add(b=5)",
      "",
      "#+CALL: add(1, b=7)",
      "",
      "Inline: call_add(4, 4).",
      "",
      "#+begin_src sh :noweb yes :results output",
      'echo "<<add(a=3, b=4)>>"',
      'echo "<<add(5)>>"',
      "#+end_src",
    })
    local text = table.concat(out, "\n")
    ok(text:find("#%+CALL: add%(10%)\n\n#%+RESULTS:\n: 12"), text)
    ok(text:find("#%+CALL: add%(10, 20%)\n\n#%+RESULTS:\n: 30"), text)
    ok(text:find("#%+CALL: add%(b=5%)\n\n#%+RESULTS:\n: 6"), text)
    ok(text:find("#%+CALL: add%(1, b=7%)\n\n#%+RESULTS:\n: 8"), text)
    ok(text:find("call_add(4, 4) {{{results(=8=)}}}.", 1, true), text)
    ok(text:find("#+RESULTS:\n: 7\n: 7", 1, true), text)
  end)

  it("finds noweb references with spaces", function()
    eq({ 1, 11, "a(b, c)" }, { babel.find_noweb("<<a(b, c)>>", 1) })
    eq(nil, babel.find_noweb("<< a>>", 1))
    eq({ 3, 7, "x" }, { babel.find_noweb("a <<x>> <<y>>", 1) })
  end)

  it("uses per-language and inline default header args", function()
    local saved = config.opts.babel.languages.sh
    config.opts.babel.languages.sh = { cmd = "sh", default_header_args = { results = "output" } }
    local buf = org_buffer({ "#+begin_src sh", "echo a; echo b", "#+end_src", "", "Inline src_sh{echo c}." })
    local b = babel.at_block(buf, 2)
    eq("output", b.args.results_spec.collection)
    local src, args = babel.inline_info(buf, 5, babel.inline_all("Inline src_sh{echo c}.")[1], nil)
    eq("yes", args.hlines)
    eq("results", args.exports)
    ok(src.inline)
    config.opts.babel.languages.sh = saved
  end)

  it("indexes :var tables counting the header and hlines (org-babel-ref-index-list)", function()
    local t = { { "name", "n" }, "hline", { "a", 1 }, { "b", 2 } }
    eq("hline", babel.index_value(t, "1,0"))
    eq({ "hline", { "a", 1 } }, babel.index_value(t, "1:2"))
    eq({ "n", "hline", 1, 2 }, babel.index_value(t, ",1"))
    eq(2, babel.index_value(t, "-1,-1"))
  end)

  it("disassembles tables like org-babel-disassemble-tables", function()
    local vars = { { name = "t", value = { { "name", "n" }, "hline", { "a", 1 }, { "b", 2 } } } }
    local _, meta = babel.disassemble(vars, { hlines = "no" }, {})
    eq({ { "a", 1 }, { "b", 2 } }, vars[1].value)
    eq({ { "t", { "name", "n" } } }, meta.colnames)
    -- without :colnames the names are not put back (Emacs 9.8)
    eq({ { "a", 1 } }, babel.reassemble({ { "a", 1 } }, {}, meta))
    eq({ { "name", "n" }, "hline", { "a", 1 } }, babel.reassemble({ { "a", 1 } }, { colnames = "yes" }, meta))
    eq({ { "x", "y" }, "hline", { "a", 1 } }, babel.reassemble({ { "a", 1 } }, { colnames = "'(x y)" }, meta))
  end)
end)

describe("babel parity: results", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)

  it("reads multi-line shell output as a table like Emacs", function()
    local out = run({
      "#+begin_src sh",
      "echo hello",
      "echo world",
      "#+end_src",
      "",
      "#+begin_src sh :results output",
      "echo hello",
      "#+end_src",
      "",
      "#+begin_src sh :results value",
      "echo x; exit 3",
      "#+end_src",
      "",
      "#+begin_src sh :results output table",
      'echo "1,2"',
      'echo "3,4"',
      "#+end_src",
      "",
      "#+begin_src sh :results output list",
      "printf 'a\\nb\\n'",
      "#+end_src",
      "",
      "#+begin_src sh :results drawer",
      'echo "x"',
      "#+end_src",
    })
    eq({ "| hello |", "| world |" }, result_of(out, "#+begin_src sh"))
    eq({ ": hello" }, result_of(out, "#+begin_src sh :results output"))
    eq({ ": x" }, result_of(out, "#+begin_src sh :results value"))
    eq({ "| 1 | 2 |", "| 3 | 4 |" }, result_of(out, "#+begin_src sh :results output table"))
    eq({ ": - a", ": - b" }, result_of(out, "#+begin_src sh :results output list"))
    eq({ ":results:", "x", ":end:" }, result_of(out, "#+begin_src sh :results drawer"))
  end)

  it("writes empty output lines as ': ' and lets an example block take the blank line", function()
    local out = run({
      "#+begin_src sh :results output",
      "printf 'a\\n\\nb\\n'",
      "#+end_src",
      "",
      "#+begin_src sh :results output",
      "seq 1 10",
      "#+end_src",
      "",
      "#+begin_src sh :results output",
      "echo after",
      "#+end_src",
    })
    local text = table.concat(out, "\n")
    ok(text:find("#+RESULTS:\n: a\n: \n: b\n", 1, true), text)
    ok(text:find("10\n#+end_example\n#+begin_src sh :results output\necho after", 1, true), text)
  end)

  it("keeps a paragraph after #+RESULTS: (org-babel-result-end)", function()
    local out = run({
      "#+begin_src sh :results output",
      "echo new",
      "#+end_src",
      "#+RESULTS:",
      "Old paragraph",
      "",
      "Next.",
    })
    eq({ "#+begin_src sh :results output", "echo new", "#+end_src", "#+RESULTS:", ": new", "Old paragraph", "", "Next." }, out)
  end)

  it("converts Python values like ob-python", function()
    if not has("python3") then
      return
    end
    local out = run({
      "#+begin_src python",
      "return [[1,2],None,[3,4]]",
      "#+end_src",
      "",
      "#+begin_src python :results pp",
      'return {"a": [1,2]}',
      "#+end_src",
      "",
      "#+begin_src python :results verbatim",
      "return [1,2]",
      "#+end_src",
      "",
      "#+begin_src python :results list",
      "return [1,[2,3]]",
      "#+end_src",
      "",
      "#+begin_src python :results table",
      'return {"a": 1, "b": 2}',
      "#+end_src",
      "",
      "#+begin_src python",
      "return 10**20",
      "#+end_src",
      "",
      "#+begin_src python :var x=5",
      'return {"a": x}',
      "#+end_src",
      "",
      "#+begin_src python :var y=1",
      "return 1.0 * y",
      "#+end_src",
      "",
      "#+begin_src python :var z=0",
      "return [1.5, 'a b', None, z == 0]",
      "#+end_src",
      "",
      "#+begin_src python :results value :return w",
      "w = 9",
      "#+end_src",
    })
    eq({ "| 1 | 2 |", "|---+---|", "| 3 | 4 |" }, result_of(out, "#+begin_src python"))
    eq({ ": {'a': [1, 2]}" }, result_of(out, "#+begin_src python :results pp"))
    eq({ ": [1, 2]" }, result_of(out, "#+begin_src python :results verbatim"))
    eq({ "- 1", "- 2", "  3" }, result_of(out, "#+begin_src python :results list"))
    eq({ "| a | 1 |", "| b | 2 |" }, result_of(out, "#+begin_src python :results table"))
    ok(vim.tbl_contains(out, ": 100000000000000000000"), vim.inspect(out))
    eq({ ": {'a': 5}" }, result_of(out, "#+begin_src python :var x=5"))
    eq({ ": 1.0" }, result_of(out, "#+begin_src python :var y=1"))
    eq({ "| 1.5 | a b | hline | True |" }, result_of(out, "#+begin_src python :var z=0"))
    eq({ ": 9" }, result_of(out, "#+begin_src python :results value :return w"))
  end)

  it("converts JavaScript and Ruby values like ob-js / ob-ruby", function()
    if has("node") then
      local out = run({
        "#+begin_src js",
        'return "abc";',
        "#+end_src",
        "",
        "#+begin_src js :results value",
        "return {a: 1};",
        "#+end_src",
        "",
        "#+begin_src js :var t='((1 2) (3 4))",
        "return [[1, \"a b\"], t[1]];",
        "#+end_src",
      })
      eq({ ": abc" }, result_of(out, "#+begin_src js"))
      eq({ ": { a: 1 }" }, result_of(out, "#+begin_src js :results value"))
      eq({ "| 1 | a b |", "| 3 |   4 |" }, result_of(out, "#+begin_src js :var t='((1 2) (3 4))"))
    end
    if has("ruby") then
      local out = run({
        "#+begin_src ruby",
        "[[1, 2], nil, [3, 4]]",
        "#+end_src",
        "",
        "#+begin_src ruby :results value",
        "nil",
        "#+end_src",
      })
      eq({ "| 1 | 2 |", "|---+---|", "| 3 | 4 |" }, result_of(out, "#+begin_src ruby"))
      eq({ ": nil" }, result_of(out, "#+begin_src ruby :results value"))
    end
  end)

  it("runs sqlite like ob-sqlite", function()
    if not has("sqlite3") then
      return
    end
    local out = run({
      "#+begin_src sqlite :db t.db",
      "create table if not exists t(n int, s text);",
      "delete from t;",
      "insert into t values (1, 'a b'), (2, 'c');",
      "select * from t;",
      "#+end_src",
      "",
      "#+begin_src sqlite :db t.db :colnames yes",
      "select n, s from t;",
      "#+end_src",
      "",
      "#+begin_src sqlite :db t.db :list",
      "select n, s from t;",
      "#+end_src",
      "",
      "#+begin_src sqlite :db t.db",
      "select count(*) from t;",
      "#+end_src",
    })
    eq({ "| 1 | a b |", "| 2 | c   |" }, result_of(out, "#+begin_src sqlite :db t.db"))
    eq({ "| n | s   |", "|---+-----|", "| 1 | a b |", "| 2 | c   |" }, result_of(out, "#+begin_src sqlite :db t.db :colnames yes"))
    eq({ "| 1 | a | b |", "| 2 | c |   |" }, result_of(out, "#+begin_src sqlite :db t.db :list"))
    ok(vim.tbl_contains(out, ": 2"), vim.inspect(out))
  end)

  it("sends stderr to *Org-Babel Error Output* and keeps stdout as the result", function()
    local out = run({
      "#+begin_src sh :results output",
      "echo out; echo err >&2; exit 2",
      "#+end_src",
    })
    eq({ ": out" }, result_of(out, "#+begin_src sh :results output"))
    local eb = vim.fn.bufnr("*Org-Babel Error Output*")
    ok(eb > 0)
    local text = table.concat(vim.api.nvim_buf_get_lines(eb, 0, -1, false), "\n")
    ok(text:find("err\n[ Babel evaluation exited with code 2 ]", 1, true), text)
  end)

  it("computes :cache hashes like org-babel-sha1-hash", function()
    local out = run({
      "#+NAME: cached",
      "#+begin_src sh :cache yes :results output",
      "echo c",
      "#+end_src",
    })
    -- the hash Emacs 9.8 writes for this block
    eq("#+RESULTS[b79b99b250091d6c835b7624bc56eaad70a335e6]: cached", out[6])
    eq(": c", out[7])
    eq("a9993e364706816aba3e25717850c26c9cd0d89d", require("org.babel.sha1").hex("abc"))
  end)

  it("writes :results file relative to :dir and links it from the Org file", function()
    local out, dir = run({
      "#+begin_src sh :dir sub :mkdirp yes :results file :file o.txt :file-desc",
      "echo in-sub",
      "#+end_src",
      "",
      "#+begin_src sh :results output :file d.txt",
      "echo d",
      "#+end_src",
      "",
      "#+begin_src sh :results file :file o3.txt :file-desc []",
      "echo x",
      "#+end_src",
    })
    eq({ "[[file:sub/o.txt][o.txt]]" }, result_of(out, "#+begin_src sh :dir sub :mkdirp yes :results file :file o.txt :file-desc"))
    eq({ "in-sub" }, vim.fn.readfile(dir .. "/sub/o.txt"))
    -- without `file` in :results nothing is written (Emacs 9.8)
    eq({ ": d" }, result_of(out, "#+begin_src sh :results output :file d.txt"))
    eq(0, vim.fn.filereadable(dir .. "/d.txt"))
    eq({ "[[file:o3.txt]]" }, result_of(out, "#+begin_src sh :results file :file o3.txt :file-desc []"))
  end)

  it("gives :post the result with its final newline", function()
    local out = run({
      "#+NAME: up",
      '#+begin_src sh :var x="" :results output',
      'echo "$x" | tr a-z A-Z',
      "#+end_src",
      "",
      "#+begin_src sh :results output :post up(x=*this*)",
      "echo hello",
      "#+end_src",
    })
    eq({ ": HELLO", ": " }, result_of(out, "#+begin_src sh :results output :post up(x=*this*)"))
  end)

  it("inserts inline results like Emacs, raw ones bare", function()
    local out = run({ "A src_sh[:results raw]{printf '*b*'} and src_sh{echo 1} and src_sh{echo 2} end." })
    eq({ "A src_sh[:results raw]{printf '*b*'} *b* and src_sh{echo 1} {{{results(=1=)}}} and src_sh{echo 2} {{{results(=2=)}}} end." }, out)
    -- a list result stops the execution: "Inline error: list result cannot be used"
    out = run({ "A src_sh{printf 'a\\nb'} and src_sh{echo 3} end." })
    eq({ "A src_sh{printf 'a\\nb'} and src_sh{echo 3} end." }, out)
  end)

  it("joins several Lua return values with ', ' like ob-lua", function()
    local out = run({
      "#+begin_src lua",
      'return "a", "b"',
      "#+end_src",
      "",
      "#+begin_src lua :results output",
      "print('x')",
      "#+end_src",
    })
    eq({ ": a, b" }, result_of(out, "#+begin_src lua"))
    eq({ ": x" }, result_of(out, "#+begin_src lua :results output"))
  end)

  it("reads Lisp data from printed values", function()
    eq({ 1, "two" }, lisp.script_escape("(1, 'two')"))
    eq("{'a': 1}", require("org.babel.langs").python_table_or_string("{'a': 1}"))
    eq({ { 1, 2 }, "hline", { 3, 4 } }, require("org.babel.langs").python_table_or_string("[[1, 2], None, [3, 4]]"))
    eq("1.0", lisp.prin1(lisp.read("1.0")))
    eq("100000000000000000000", lisp.prin1(lisp.read("100000000000000000000")))
    eq({ { "a", "b" }, { "c", "d" } }, lisp.import_table("a\tb\nc\td\n"))
    eq("one line", lisp.import_table("one line\n"))
    eq({ { 1.5, 2 }, { "q", "x" } }, (function()
      local t = lisp.import_table('1.50 2\n"q" x\n')
      return { { lisp.tonumber(t[1][1]), t[1][2] }, t[2] }
    end)())
  end)
end)

describe("babel parity: evaluation", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(function()
    config.opts.babel.confirm_evaluate = false
    config.opts.babel.no_eval_on_ctrl_c_ctrl_c = false
  end)

  it("executes inline elements with the buffer and asks for :eval query", function()
    local asked = 0
    local confirm = require("org.utils").confirm
    require("org.utils").confirm = function()
      asked = asked + 1
      return true
    end
    local out = run({
      "#+begin_src sh :eval query :results output",
      "echo q",
      "#+end_src",
      "",
      "Inline src_sh{echo 5}.",
    })
    require("org.utils").confirm = confirm
    eq(1, asked)
    ok(vim.tbl_contains(out, "Inline src_sh{echo 5} {{{results(=5=)}}}."), vim.inspect(out))
  end)

  it("asks with a confirm_evaluate function", function()
    local seen
    config.opts.babel.confirm_evaluate = function(lang, body)
      seen = { lang, body }
      return false
    end
    local buf = org_buffer({ "#+begin_src sh :results output", "echo f", "#+end_src" }, { 2, 0 })
    babel.execute({ bufnr = buf, lnum = 2, sync = true })
    eq({ "sh", "echo f" }, seen)
    eq(": f", buf_lines(buf)[6])
  end)

  it("fires OrgBabelAfterExecute", function()
    local got
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "OrgBabelAfterExecute",
      callback = function(ev)
        got = ev.data
      end,
    })
    local buf = org_buffer({ "#+begin_src sh :results output", "echo h", "#+end_src" }, { 2, 0 })
    babel.execute({ bufnr = buf, lnum = 2, sync = true, skip_confirm = true })
    vim.api.nvim_del_autocmd(id)
    eq("sh", got.lang)
    eq("h\n", got.result)
  end)

  it("does not evaluate on C-c C-c with no_eval_on_ctrl_c_ctrl_c", function()
    config.opts.babel.no_eval_on_ctrl_c_ctrl_c = true
    local buf = org_buffer({ "#+begin_src lua", "return 1", "#+end_src" }, { 2, 0 })
    require("org.context").context_action()
    vim.wait(100)
    eq(3, #buf_lines(buf))
  end)

  it("writes the date before hashes with hash_show_time", function()
    config.opts.babel.hash_show_time = true
    local buf = org_buffer({ "#+begin_src lua :cache yes", "return 2", "#+end_src" }, { 2, 0 })
    babel.execute({ bufnr = buf, lnum = 2, sync = true, skip_confirm = true })
    config.opts.babel.hash_show_time = false
    local l = buf_lines(buf)[5]
    ok(l:match("^#%+RESULTS%[%(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%) %x+%]:$"), l)
    local name, hash = blocks.match_results(l)
    eq("", name)
    ok(hash:match("^%x+$"), hash)
  end)
end)

describe("babel parity: C and SQL", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)

  it("compiles and runs C and C++ blocks like ob-C", function()
    if not has("gcc") or not has("g++") then
      return
    end
    local out = run({
      "#+NAME: ctbl",
      "| a | 1 |",
      "| b | 2 |",
      "",
      "#+begin_src C :includes <stdio.h> :var t=ctbl",
      'printf("%s %s\\n", t[0][0], t[1][1]);',
      'printf("%d %d\\n", t_rows, t_cols);',
      "#+end_src",
      "",
      "#+begin_src C++ :includes <iostream> :namespaces std",
      'cout << "cpp " << 42 << endl;',
      "#+end_src",
      "",
      "#+begin_src cpp :includes <iostream> :defines N 5",
      "std::cout << N * 2 << std::endl;",
      "#+end_src",
    })
    eq({ "| a | 2 |", "| 2 | 2 |" }, result_of(out, "#+begin_src C :includes <stdio.h> :var t=ctbl"))
    eq({ ": cpp 42" }, result_of(out, "#+begin_src C++ :includes <iostream> :namespaces std"))
    eq({ ": 10" }, result_of(out, "#+begin_src cpp :includes <iostream> :defines N 5"))
  end)

  it("builds the client command of an SQL :engine like ob-sql", function()
    local langs = require("org.babel.langs")
    local args = blocks.header_args({
      params = ":engine postgresql :dbhost h :dbuser u :database d :dbport 5433",
      header_lines = {},
      start = 1,
      lang = "sql",
    }, nil)
    local spec = langs.prepare("sql", { "select 1;" }, args, {}, { cmd = {}, ext = "sql" })
    local cmd = spec.steps[1].cmd
    ok(cmd:find("^psql %-%-set=\"ON_ERROR_STOP=1\"  %-A %-P footer=off %-F \"\t\"  %-h'h' %-p5433 %-U'u' %-d'd' %-f "), cmd)
    args = blocks.header_args({ params = ":engine mysql :database d", header_lines = {}, start = 1, lang = "sql" }, nil)
    cmd = langs.prepare("sql", { "select 1;" }, args, {}, { cmd = {}, ext = "sql" }).steps[1].cmd
    ok(cmd:find("^mysql %-D'd'  +< "), cmd)
  end)

  it("evaluates org-sbe in table formulas", function()
    local buf = org_buffer({
      "#+NAME: square",
      "#+begin_src lua :var x=0",
      "return x * x",
      "#+end_src",
      "",
      "| n | sq |",
      "|---+----|",
      "| 2 |    |",
      "| 3 |    |",
      "#+TBLFM: $2='(org-sbe \"square\" (x $1))",
    }, { 8, 1 })
    require("org.table").recalc()
    eq({ "| n | sq |", "|---+----|", "| 2 |  4 |", "| 3 |  9 |" }, vim.list_slice(buf_lines(buf), 6, 9))
  end)
end)

describe("babel parity: tangling", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)

  local function tangle(lines)
    local dir = tmpdir()
    local buf = org_buffer(lines, { 1, 0 })
    vim.api.nvim_buf_set_name(buf, dir .. "/t.org")
    babel.tangle({ bufnr = buf, silent = true })
    vim.bo[buf].modified = false
    return dir, buf
  end

  it("writes link, org and noweb comments exactly like ob-tangle", function()
    local dir = tangle({
      "#+begin_src sh :tangle first.sh :comments link",
      "echo before-heading",
      "#+end_src",
      "",
      "* Section One",
      "Some prose text for org comments.",
      "",
      "#+begin_src sh :tangle out.sh :comments link",
      "echo one",
      "#+end_src",
      "",
      "Text between blocks.",
      "",
      "#+begin_src sh :tangle out.sh :comments org",
      "echo two",
      "#+end_src",
      "",
      "#+NAME: named-block",
      "#+begin_src sh :tangle out.sh :comments both",
      "echo three",
      "#+end_src",
      "",
      "** Sub heading",
      "  #+begin_src python :tangle sub/py.py :comments link :mkdirp yes",
      "    def f():",
      "        return 1",
      "  #+end_src",
      "",
      "* Archived stuff :ARCHIVE:",
      "#+begin_src sh :tangle out.sh",
      "echo archived",
      "#+end_src",
      "",
      "* Noweb",
      "#+NAME: helper",
      "#+begin_src sh",
      "echo helper",
      "#+end_src",
      "",
      "#+begin_src sh :tangle nw.sh :noweb yes :comments noweb",
      "<<helper>>",
      "echo main",
      "#+end_src",
    })
    eq({
      "# [[file:t.org::+begin_src sh :tangle first.sh :comments link][No heading:1]]",
      "echo before-heading",
      "# No heading:1 ends here",
    }, vim.fn.readfile(dir .. "/first.sh"))
    eq({
      "# [[file:t.org::*Section One][Section One:1]]",
      "echo one",
      "# Section One:1 ends here",
      "",
      "",
      "",
      "# Text between blocks.",
      "",
      "",
      "echo two",
      "",
      "",
      "",
      "# #+NAME: named-block",
      "",
      "# [[file:t.org::named-block][named-block]]",
      "echo three",
      "# named-block ends here",
    }, vim.fn.readfile(dir .. "/out.sh"))
    eq({
      "# [[file:../t.org::*Sub heading][Sub heading:1]]",
      "def f():",
      "    return 1",
      "# Sub heading:1 ends here",
    }, vim.fn.readfile(dir .. "/sub/py.py"))
    eq({
      "# [[file:t.org::*Noweb][Noweb:2]]",
      "# [[file:t.org::helper][helper]]",
      "echo helper",
      "# helper ends here",
      "",
      "echo main",
      "# Noweb:2 ends here",
    }, vim.fn.readfile(dir .. "/nw.sh"))
  end)

  it("interprets :tangle-mode like org-babel-interpret-file-mode", function()
    local dir = tangle({
      "#+begin_src sh :tangle m1.sh :tangle-mode rwxr-xr-x",
      "echo m1",
      "#+end_src",
      "#+begin_src sh :tangle m2.sh :tangle-mode u+x",
      "echo m2",
      "#+end_src",
      "#+begin_src sh :tangle m3.sh :tangle-mode o700",
      "echo m3",
      "#+end_src",
      "#+begin_src sh :tangle m4.sh :tangle-mode (identity #o640)",
      "echo m4",
      "#+end_src",
    })
    eq("rwxr-xr-x", vim.fn.getfperm(dir .. "/m1.sh"))
    eq("rwxr--r--", vim.fn.getfperm(dir .. "/m2.sh"))
    eq("rwx------", vim.fn.getfperm(dir .. "/m3.sh"))
    eq("rw-r-----", vim.fn.getfperm(dir .. "/m4.sh"))
    eq(nil, (babel.file_mode("755")))
  end)

  it("detangles edits back into the Org blocks (org-babel-detangle)", function()
    local dir, buf = tangle({
      "* Section One",
      "#+begin_src sh :tangle out.sh :comments link",
      "echo one",
      "#+end_src",
      "",
      "#+NAME: nb",
      "#+begin_src sh :tangle out.sh :comments link",
      "echo two",
      "#+end_src",
    })
    local lines = vim.fn.readfile(dir .. "/out.sh")
    eq("echo one", lines[2])
    lines[2] = "echo ONE"
    table.insert(lines, 3, "echo extra")
    lines[#lines - 1] = "echo TWO"
    vim.fn.writefile(lines, dir .. "/out.sh")
    local n = babel.detangle(dir .. "/out.sh")
    eq(2, n)
    -- the body is re-indented by edit_src_content_indentation (2), as Emacs
    eq({ "  echo ONE", "  echo extra" }, vim.list_slice(buf_lines(buf), 3, 4))
    eq("  echo TWO", buf_lines(buf)[9])
    vim.bo[buf].modified = false
  end)

  it("jumps from a tangled file to the block (org-babel-tangle-jump-to-org)", function()
    local dir, buf = tangle({
      "* A",
      "#+begin_src sh :tangle j.sh :comments link",
      "echo a1",
      "echo a2",
      "#+end_src",
    })
    local org_name = vim.api.nvim_buf_get_name(buf)
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/j.sh"))
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local body = babel.jump_to_org()
    eq("echo a1\necho a2", body)
    eq(org_name, vim.api.nvim_buf_get_name(0))
    eq(4, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("removes tangle comments (tangle_clean) and tangles Lua to load it (load_file)", function()
    local dir = tangle({
      "* A",
      "#+begin_src sh :tangle c.sh :comments link",
      "echo c",
      "#+end_src",
    })
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/c.sh"))
    eq(2, babel.tangle_clean())
    eq({ "echo c" }, buf_lines(0))
    vim.cmd("bwipeout!")
    vim.fn.writefile({ "* Init", "#+begin_src lua", "return 40 + 2", "#+end_src" }, dir .. "/init.org")
    eq(42, babel.load_file(dir .. "/init.org"))
    eq(1, vim.fn.filereadable(dir .. "/init.lua"))
  end)

  it("fires the tangle hooks", function()
    local seen = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = { "OrgBabelTanglePre", "OrgBabelTanglePost", "OrgBabelTangleFinished", "OrgBabelTangleBody" },
      callback = function(ev)
        seen[#seen + 1] = ev.match
        if ev.match == "OrgBabelTangleBody" then
          require("org.babel.tangle").body = "echo hooked"
        end
      end,
    })
    local dir = tangle({ "#+begin_src sh :tangle h.sh", "echo h", "#+end_src" })
    vim.api.nvim_del_autocmd(id)
    eq({ "OrgBabelTanglePre", "OrgBabelTangleBody", "OrgBabelTanglePost", "OrgBabelTangleFinished" }, seen)
    eq({ "echo hooked" }, vim.fn.readfile(dir .. "/h.sh"))
  end)
end)

describe("babel parity: edit special", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(function()
    config.opts.src_preserve_indentation = false
    pcall(vim.cmd, "silent! only")
  end)

  local function write_back()
    local keys = vim.keycode("<C-c>'")
    vim.api.nvim_feedkeys(keys, "x", false)
  end

  it("edits the body of an inline src block", function()
    local buf = org_buffer({ "Text src_python[:results raw]{x = 1} end." }, { 1, 32 })
    require("org.context").edit_special()
    eq({ "x = 1" }, buf_lines(0))
    eq("inline-src", vim.b.org_special_kind)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "y = 2", "  + 3" })
    write_back()
    eq({ "Text src_python[:results raw]{y = 2 + 3} end." }, buf_lines(buf))
  end)

  it("edits a footnote definition from its reference", function()
    local buf = org_buffer({ "Text[fn:1] here.", "", "[fn:1] The note", "second line." }, { 1, 6 })
    require("org.context").edit_special()
    eq({ "The note", "second line." }, buf_lines(0))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "New note." })
    write_back()
    eq({ "Text[fn:1] here.", "", "[fn:1] New note." }, buf_lines(buf))
  end)

  it("edits a LaTeX fragment", function()
    local buf = org_buffer({ "Euler: $e^{i\\pi}$ ok" }, { 1, 10 })
    require("org.context").edit_special()
    eq({ "e^{i\\pi}" }, buf_lines(0))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x^2" })
    write_back()
    eq({ "Euler: $x^2$ ok" }, buf_lines(buf))
  end)

  it("visits the file of an INCLUDE keyword and reports nothing to edit elsewhere", function()
    local dir = tmpdir()
    vim.fn.writefile({ "* Included" }, dir .. "/inc.org")
    local buf = org_buffer({ '#+INCLUDE: "inc.org"', "", "plain text" }, { 1, 0 })
    vim.bo[buf].bufhidden = "hide"
    vim.api.nvim_buf_set_name(buf, dir .. "/main.org")
    require("org.context").edit_special()
    eq(dir .. "/inc.org", vim.api.nvim_buf_get_name(0))
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local msgs = {}
    local notify = vim.notify
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    require("org.context").edit_special()
    vim.notify = notify
    ok(table.concat(msgs, "\n"):find("No special environment to edit here", 1, true), vim.inspect(msgs))
    vim.bo[buf].modified = false
  end)

  it("keeps indentation with src_preserve_indentation", function()
    config.opts.src_preserve_indentation = true
    local buf = org_buffer({ "#+begin_src python", "    x = 1", "#+end_src" }, { 2, 0 })
    eq({ "    x = 1" }, babel.at_block(buf, 2).body)
    config.opts.src_preserve_indentation = false
    eq({ "x = 1" }, babel.at_block(buf, 2).body)
  end)

  it("folds a result with its #+RESULTS keyword (TAB)", function()
    local lines = { "#+begin_src sh", "echo", "#+end_src", "", "#+RESULTS:", "| a |", "| b |", "", "after" }
    local _, regions = require("org.fold").compute(lines)
    local found
    for _, r in ipairs(regions) do
      if r.kind == "results" then
        found = r
      end
    end
    eq({ start = 5, ["end"] = 7, kind = "results" }, found)
  end)
end)

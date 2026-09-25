local babel = require("org.babel")
local blocks = require("org.babel.blocks")
local config = require("org.config")

local function wait_for(buf, pred)
  return vim.wait(5000, function()
    return pred(buf_lines(buf))
  end, 20)
end

describe("babel", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)

  it("parses header args", function()
    local p = blocks.parse_header_string(':results output table :var x=1 y="a b" :tangle "f.sh"')
    eq("results", p[1].key)
    eq("output table", p[1].value)
    local args = blocks.merge({}, p)
    eq("output", args.results_spec.collection)
    eq("table", args.results_spec.type)
    eq({ { name = "x", value = "1" }, { name = "y", value = '"a b"' } }, args.vars)
    eq('"f.sh"', args.tangle)
  end)

  it("parses blocks with names, headers and results", function()
    local lines = {
      "#+NAME: hello",
      "#+HEADER: :var n=2",
      "#+begin_src sh :results output",
      "  echo hi",
      "  ,* not a heading",
      "#+end_src",
      "",
      "#+RESULTS: hello",
      ": hi",
      "",
      "#+CALL: hello(n=3)",
    }
    local list = blocks.parse_blocks(lines)
    eq(2, #list)
    local b = list[1]
    eq("hello", b.name)
    eq("sh", b.lang)
    -- like org-babel--normalize-body, the common indentation is removed
    eq({ "echo hi", "* not a heading" }, b.body)
    eq({ "  echo hi", "  * not a heading" }, b.body_raw)
    eq({ start = 8, finish = 9, name = "hello" }, b.results)
    local args = blocks.header_args(b, nil)
    eq("output", args.results_spec.collection)
    eq("2", args.vars[1].value)
    ok(list[2].call)
    eq("hello", list[2].target)
    eq("n=3", list[2].call_args)
  end)

  it("header-args inheritance from #+PROPERTY and headline", function()
    local buf = org_buffer({
      "#+PROPERTY: header-args :results output",
      "#+PROPERTY: header-args:sh :dir /tmp",
      "* H",
      "  :PROPERTIES:",
      "  :header-args:sh: :var z=9",
      "  :END:",
      "#+begin_src sh :results silent",
      "echo",
      "#+end_src",
    }, { 8, 0 })
    local b = babel.at_block(buf, 8)
    eq("output", b.args.results_spec.collection)
    eq("silent", b.args.results_spec.handling)
    -- the headline's header-args:sh wins over #+PROPERTY (org-entry-get
    -- with inheritance stops at the nearest value)
    eq(nil, b.args.dir)
    eq("9", b.args.vars[1].value)
  end)

  it("executes lua in-process", function()
    local buf = org_buffer({ "#+begin_src lua", "return 1 + 2", "#+end_src" }, { 2, 0 })
    babel.execute_block()
    ok(wait_for(buf, function(l)
      return l[6] == ": 3"
    end), vim.inspect(buf_lines(buf)))
    eq({ "#+begin_src lua", "return 1 + 2", "#+end_src", "", "#+RESULTS:", ": 3" }, buf_lines(buf))
    -- re-executing replaces
    babel.execute_block()
    vim.wait(200)
    eq(6, #buf_lines(buf))
  end)

  it("lua tables become org tables and output mode captures print", function()
    local buf = org_buffer({
      "#+begin_src lua",
      "return {{'a', 1}, {'b', 2}}",
      "#+end_src",
      "#+begin_src lua :results output",
      "print('x')",
      "print('y')",
      "#+end_src",
    }, { 1, 0 })
    babel.execute({ bufnr = buf, lnum = 1 })
    ok(wait_for(buf, function(l)
      return l[7] == "| b | 2 |"
    end), vim.inspect(buf_lines(buf)))
    babel.execute({ bufnr = buf, lnum = 9 })
    ok(wait_for(buf, function(l)
      return vim.tbl_contains(l, ": y")
    end), vim.inspect(buf_lines(buf)))
  end)

  it("executes shell with vars from named table", function()
    local buf = org_buffer({
      "#+NAME: tbl",
      "| 1 | 2 |",
      "| 3 | 4 |",
      "",
      "#+NAME: shblock",
      "#+begin_src sh :var x=5 :var t=tbl :results output",
      'echo "x=$x"',
      'echo "$t" | head -1',
      "#+end_src",
    }, { 7, 0 })
    babel.execute_block()
    ok(wait_for(buf, function(l)
      return vim.tbl_contains(l, ": 1\t2")
    end), vim.inspect(buf_lines(buf)))
    eq("#+RESULTS: shblock", buf_lines(buf)[11])
    eq(": x=5", buf_lines(buf)[12])
  end)

  it("output as table, list and drawer", function()
    local buf = org_buffer({
      "#+begin_src sh :results output table",
      "printf 'a b\\nc d\\n'",
      "#+end_src",
    }, { 1, 0 })
    babel.execute_block()
    ok(wait_for(buf, function(l)
      return l[7] == "| c | d |"
    end), vim.inspect(buf_lines(buf)))
    local buf2 = org_buffer({ "#+begin_src sh :results output drawer", "echo hi", "#+end_src" }, { 1, 0 })
    babel.execute_block()
    ok(wait_for(buf2, function(l)
      return l[7] == "hi" and l[8] == ":end:"
    end), vim.inspect(buf_lines(buf2)))
  end)

  it("python value mode", function()
    if vim.fn.executable("python3") == 0 then
      return
    end
    local buf = org_buffer({ "#+begin_src python :var x=4", "return [[x, x*2]]", "#+end_src" }, { 1, 0 })
    babel.execute_block()
    ok(wait_for(buf, function(l)
      return l[6] == "| 4 | 8 |" or l[6] == "| 4 | 8 |"
    end), vim.inspect(buf_lines(buf)))
  end)

  it("noweb expansion and #+CALL", function()
    local buf = org_buffer({
      "#+NAME: greet",
      "#+begin_src lua",
      "local g = 'hello'",
      "#+end_src",
      "",
      "#+begin_src lua :noweb yes",
      "<<greet>>",
      "return g .. '!'",
      "#+end_src",
    }, { 7, 0 })
    babel.execute_block()
    ok(wait_for(buf, function(l)
      return vim.tbl_contains(l, ": hello!")
    end), vim.inspect(buf_lines(buf)))

    local buf2 = org_buffer({
      "#+NAME: dbl",
      "#+begin_src lua :var n=1",
      "return n * 2",
      "#+end_src",
      "",
      "#+CALL: dbl(n=21)",
    }, { 6, 0 })
    babel.execute_block()
    ok(wait_for(buf2, function(l)
      return l[9] == ": 42"
    end), vim.inspect(buf_lines(buf2)))
  end)

  it("remove result", function()
    local buf = org_buffer({ "#+begin_src lua", "return 1", "#+end_src", "", "#+RESULTS:", ": 1", "after" }, { 2, 0 })
    babel.remove_result()
    eq({ "#+begin_src lua", "return 1", "#+end_src", "after" }, buf_lines(buf))
  end)

  it("tangles files", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local buf = org_buffer({
      "#+PROPERTY: header-args:sh :tangle out/script.sh :mkdirp yes",
      "#+begin_src sh :shebang #!/bin/sh",
      "echo one",
      "#+end_src",
      "#+begin_src sh",
      "echo two",
      "#+end_src",
      "#+begin_src lua :tangle no",
      "x",
      "#+end_src",
      "#+begin_src python :tangle yes",
      "  print(1)",
      "#+end_src",
    })
    vim.api.nvim_buf_set_name(buf, dir .. "/doc.org")
    local written = babel.tangle({ bufnr = buf, silent = true })
    eq(2, #written)
    eq({ "#!/bin/sh", "echo one", "", "echo two" }, vim.fn.readfile(dir .. "/out/script.sh"))
    eq({ "print(1)" }, vim.fn.readfile(dir .. "/doc.py"))
    ok(vim.fn.getfperm(dir .. "/out/script.sh"):match("x"))
    vim.bo[buf].modified = false
  end)
end)

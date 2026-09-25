local babel = require("org.babel")
local config = require("org.config")

local function wait_for(buf, pred)
  return vim.wait(5000, function()
    return pred(buf_lines(buf))
  end, 20)
end

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

describe("babel (Emacs header args)", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
    babel.library = {}
  end)

  it(":wrap wraps results in a block", function()
    local buf = org_buffer({ "#+begin_src lua :wrap src python", "return 'x = 1'", "#+end_src" }, { 2, 0 })
    babel.execute_block()
    ok(wait_for(buf, function(l)
      return l[8] == "#+end_src"
    end), vim.inspect(buf_lines(buf)))
    eq({ "#+RESULTS:", "#+begin_src python", "x = 1", "#+end_src" }, vim.list_slice(buf_lines(buf), 5, 8))
    local buf2 = org_buffer({ "#+begin_src lua :wrap", "return 'hi'", "#+end_src" }, { 2, 0 })
    babel.execute_block()
    ok(wait_for(buf2, function(l)
      return l[8] == "#+end_results"
    end), vim.inspect(buf_lines(buf2)))
  end)

  it("expands several noweb references on one line and joins :noweb-ref blocks", function()
    local buf = org_buffer({
      "#+NAME: a",
      "#+begin_src lua",
      "'A'",
      "#+end_src",
      "#+begin_src lua :noweb-ref parts",
      "local x = 1",
      "#+end_src",
      "#+begin_src lua :noweb-ref parts",
      "local y = 2",
      "#+end_src",
      "#+begin_src lua :noweb yes",
      "-- <<parts>>",
      "return <<a>> .. <<a>>",
      "#+end_src",
    }, { 12, 0 })
    local b = babel.at_block(buf, 12)
    local body = babel.expand_noweb(buf, b.body, 0, nil, b.args, "eval")
    eq({ "-- local x = 1", "-- local y = 2", "return 'A' .. 'A'" }, body)
    b.args["noweb-prefix"] = "no"
    body = babel.expand_noweb(buf, b.body, 0, nil, b.args, "eval")
    eq({ "-- local x = 1", "local y = 2", "return 'A' .. 'A'" }, body)
  end)

  it("skips blocks in COMMENT subtrees for noweb and tangling", function()
    local dir = tmpdir()
    local buf = org_buffer({
      "* Code",
      "#+begin_src sh :tangle out.sh :noweb-ref r",
      "echo live",
      "#+end_src",
      "* COMMENT Old",
      "#+begin_src sh :tangle out.sh :noweb-ref r",
      "echo dead",
      "#+end_src",
    })
    vim.api.nvim_buf_set_name(buf, dir .. "/c.org")
    babel.tangle({ bufnr = buf, silent = true })
    eq({ "echo live" }, vim.fn.readfile(dir .. "/out.sh"))
    vim.bo[buf].modified = false
  end)

  it("tangles :var assignments and strips coderefs with -r", function()
    local dir = tmpdir()
    local buf = org_buffer({
      "#+begin_src sh -r :tangle v.sh :var n=3",
      'echo "$n" (ref:show)',
      "#+end_src",
    })
    vim.api.nvim_buf_set_name(buf, dir .. "/v.org")
    babel.tangle({ bufnr = buf, silent = true })
    eq({ "n='3'", 'echo "$n"' }, vim.fn.readfile(dir .. "/v.sh"))
    vim.bo[buf].modified = false
  end)

  it("tangles only the block at point with a count", function()
    local dir = tmpdir()
    local buf = org_buffer({
      "#+begin_src sh :tangle one.sh",
      "echo 1",
      "#+end_src",
      "#+begin_src sh :tangle one.sh",
      "echo 2",
      "#+end_src",
    }, { 5, 0 })
    vim.api.nvim_buf_set_name(buf, dir .. "/t.org")
    babel.tangle({ bufnr = buf, silent = true, only_line = 4 })
    eq({ "echo 2" }, vim.fn.readfile(dir .. "/one.sh"))
    vim.bo[buf].modified = false
  end)

  it(":colnames re-attaches the header of a table variable", function()
    local buf = org_buffer({
      "#+NAME: tbl",
      "| name | n |",
      "|------+---|",
      "| a    | 1 |",
      "| b    | 2 |",
      "",
      "#+begin_src lua :var t=tbl",
      "for _, r in ipairs(t) do r[2] = r[2] * 10 end",
      "return t",
      "#+end_src",
    }, { 8, 0 })
    babel.execute_block()
    ok(wait_for(buf, function(l)
      return l[16] ~= nil
    end), vim.inspect(buf_lines(buf)))
    eq({ "| name |  n |", "|------+----|", "| a    | 10 |", "| b    | 20 |" }, vim.list_slice(buf_lines(buf), 13, 16))
  end)

  it(":colnames no keeps the header row as data; :rownames yes", function()
    local buf = org_buffer({
      "#+NAME: tbl",
      "| x | 1 |",
      "|---+---|",
      "| y | 2 |",
      "",
      "#+begin_src lua :var t=tbl :colnames no :rownames yes",
      "return #t .. ':' .. #t[1]",
      "#+end_src",
    }, { 7, 0 })
    babel.execute_block()
    ok(wait_for(buf, function(l)
      return vim.tbl_contains(l, ": 2:1")
    end), vim.inspect(buf_lines(buf)))
  end)

  it("indexes table variables with ranges and negative indices", function()
    local t = { { 1, 2, 3 }, { 4, 5, 6 }, { 7, 8, 9 } }
    eq({ 7, 8, 9 }, babel.index_value(t, "-1"))
    eq(6, babel.index_value(t, "1,-1"))
    eq({ { 4, 5, 6 }, { 7, 8, 9 } }, babel.index_value(t, "1:2"))
    eq({ 2, 5, 8 }, babel.index_value(t, ",1"))
    eq({ { 2, 3 }, { 5, 6 } }, babel.index_value(t, "0:1,1:2"))
  end)

  it(":cache yes stores a hash and skips unchanged blocks", function()
    local buf = org_buffer({ "#+begin_src lua :cache yes", "return os.clock()", "#+end_src" }, { 2, 0 })
    babel.execute_block()
    ok(wait_for(buf, function(l)
      return l[5] and l[5]:match("^#%+RESULTS%[%x+%]:") ~= nil
    end), vim.inspect(buf_lines(buf)))
    local before = buf_lines(buf)
    babel.execute_block()
    vim.wait(200)
    eq(before, buf_lines(buf))
  end)

  it(":file writes the result to the file and links it", function()
    local dir = tmpdir()
    local buf = org_buffer({ "#+NAME: gen", "#+begin_src lua :output-dir out :file-ext txt", "return 'hello'", "#+end_src" }, { 3, 0 })
    vim.api.nvim_buf_set_name(buf, dir .. "/f.org")
    babel.execute_block()
    ok(wait_for(buf, function(l)
      return l[7] == "[[file:out/gen.txt]]"
    end), vim.inspect(buf_lines(buf)))
    eq({ "hello" }, vim.fn.readfile(dir .. "/out/gen.txt"))
    vim.bo[buf].modified = false
  end)

  it("expands a block body with variables", function()
    local buf = org_buffer({ "#+begin_src sh :var x=2 :prologue \"set -e\"", "echo $x", "#+end_src" }, { 2, 0 })
    local b = babel.at_block(buf, 2)
    eq({ "x='2'", "set -e", "echo $x" }, babel.expand_body(buf, b, b.args, "eval"))
  end)

  it("demarcates (splits) a block at the cursor", function()
    local buf = org_buffer({ "#+begin_src sh :results output", "echo 1", "echo 2", "#+end_src" }, { 3, 0 })
    babel.demarcate_block()
    eq({
      "#+begin_src sh :results output",
      "echo 1",
      "#+end_src",
      "",
      "#+begin_src sh :results output",
      "echo 2",
      "#+end_src",
    }, buf_lines(buf))
    eq(6, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("removes all results", function()
    local buf = org_buffer({
      "#+begin_src lua",
      "return 1",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": 1",
      "#+begin_src lua",
      "return 2",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": 2",
    })
    eq(2, babel.remove_all_results(buf))
    eq({ "#+begin_src lua", "return 1", "#+end_src", "#+begin_src lua", "return 2", "#+end_src" }, buf_lines(buf))
  end)

  it("ingests blocks into the Library of Babel for #+CALL", function()
    local dir = tmpdir()
    vim.fn.writefile({ "#+NAME: triple", "#+begin_src lua :var n=1", "return n * 3", "#+end_src" }, dir .. "/lib.org")
    eq(1, babel.lob_ingest(dir .. "/lib.org"))
    local buf = org_buffer({ "#+CALL: triple(n=5)" }, { 1, 0 })
    babel.execute_block()
    ok(wait_for(buf, function(l)
      return l[4] == ": 15"
    end), vim.inspect(buf_lines(buf)))
  end)

  it("evaluates inline src blocks and replaces their results", function()
    local buf = org_buffer({ "Two: src_lua{return 1 + 1} and more." }, { 1, 8 })
    babel.execute_block()
    ok(wait_for(buf, function(l)
      return l[1]:find("{{{results", 1, true) ~= nil
    end), vim.inspect(buf_lines(buf)))
    eq("Two: src_lua{return 1 + 1} {{{results(=2=)}}} and more.", buf_lines(buf)[1])
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Two: src_lua[:results raw]{return 3} {{{results(=2=)}}} end" })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    require("org.context").context_action()
    ok(wait_for(buf, function(l)
      return l[1]:find("results(3)", 1, true) ~= nil
    end), vim.inspect(buf_lines(buf)))
    eq("Two: src_lua[:results raw]{return 3} {{{results(3)}}} end", buf_lines(buf)[1])
  end)

  it("goes to named blocks and results; inserts header args", function()
    local buf = org_buffer({
      "* H",
      "#+NAME: foo",
      "#+begin_src sh",
      "echo",
      "#+end_src",
      "",
      "#+RESULTS: foo",
      ": x",
    }, { 1, 0 })
    babel.goto_named_block("foo")
    eq(2, vim.api.nvim_win_get_cursor(0)[1])
    babel.goto_named_result("foo")
    eq(7, vim.api.nvim_win_get_cursor(0)[1])
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    babel.goto_block_head()
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
    babel.insert_header_arg("results", "output")
    eq("#+begin_src sh :results output", buf_lines(buf)[3])
    eq({ ":bogus" }, (function()
      babel.insert_header_arg("bogus", "1")
      return babel.check_block()
    end)())
  end)
end)

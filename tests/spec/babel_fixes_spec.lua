local babel = require("org.babel")
local blocks = require("org.babel.blocks")
local config = require("org.config")

describe("babel block switches", function()
  it("keeps the header arguments after a -l format containing a colon", function()
    local b =
      blocks.parse_blocks({ '#+begin_src sh -n 10 -r -l "(ref:%s)" :results output', "echo hi", "#+end_src" })[1]
    eq('-n 10 -r -l "(ref:%s)"', b.switches)
    eq(":results output", b.params)
    eq("output", blocks.header_args(b, nil).results_spec.collection)
    eq("(ref:%s)", blocks.coderef_format(b.switches))
  end)

  it("splits switches like the org-element src-block parser", function()
    eq({ "", ":var x=1" }, { blocks.split_switches(":var x=1") })
    eq({ "-i +n", ":tangle yes" }, { blocks.split_switches("-i +n :tangle yes") })
    eq({ "", "-x :tangle yes" }, { blocks.split_switches("-x :tangle yes") })
    eq({ "-k", "" }, { blocks.split_switches("-k") })
  end)
end)

describe("babel sql engines", function()
  it("passes mssql/sqsh connection values as single shell words", function()
    local langs = require("org.babel.langs")
    for _, engine in ipairs({ "mssql", "sqsh" }) do
      local args = blocks.header_args({
        params = ":engine " .. engine .. ' :dbhost my-host :dbuser u :dbpassword "p w" :database d',
        header_lines = {},
        start = 1,
        lang = "sql",
      }, nil)
      local cmd = langs.prepare("sql", { "select 1;" }, args, {}, { cmd = {}, ext = "sql" }).steps[1].cmd
      local q = vim.fn.shellescape
      ok(cmd:find(("-S %s -U %s -P %s -"):format(q("my-host"), q("u"), q("p w")), 1, true), cmd)
      ok(not cmd:find("\"'", 1, true), cmd)
    end
  end)
end)

describe("babel :dir", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)

  it("does not run a block whose :dir is missing in another directory", function()
    local missing = vim.fn.tempname() .. "/nope"
    local buf = org_buffer({ "#+begin_src sh :results output :dir " .. missing, "pwd", "#+end_src" })
    local done
    babel.execute({
      bufnr = buf,
      lnum = 1,
      sync = true,
      on_done = function(okd)
        done = okd
      end,
    })
    eq(false, done)
    eq(3, #buf_lines(buf))
  end)

  it("creates :dir with any :mkdirp value but no and nil", function()
    local base = vim.fn.tempname()
    local buf = org_buffer({ "#+begin_src sh :results output :mkdirp t :dir " .. base .. "/a/b", "pwd", "#+end_src" })
    babel.execute({ bufnr = buf, lnum = 1, sync = true })
    eq(1, vim.fn.isdirectory(base .. "/a/b"))
    ok(buf_lines(buf)[6]:find("/a/b$"), buf_lines(buf)[6])
    vim.fn.delete(base, "rf")
  end)
end)

describe("babel tangle modes", function()
  it("gives the file the mode of its first block, like Emacs", function()
    skip_on_windows("Windows has no Unix file modes")
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local target = dir .. "/out.sh"
    local buf = org_buffer({
      "#+begin_src sh :tangle " .. target .. " :tangle-mode o600",
      "echo 1",
      "#+end_src",
      "#+begin_src sh :tangle " .. target .. " :tangle-mode o644",
      "echo 2",
      "#+end_src",
    })
    require("org.babel.tangle").tangle({ bufnr = buf, silent = true })
    eq("rw-------", vim.fn.getfperm(target))
    vim.fn.delete(dir, "rf")
  end)
end)

describe("babel fish variables", function()
  it("escapes backslashes and quotes inside fish single quotes", function()
    local langs = require("org.babel.langs")
    eq(
      { [[set x 'C:\\dir\\']], [[set y 'it\'s']] },
      langs.var_lines("fish", {
        { name = "x", value = [[C:\dir\]] },
        { name = "y", value = "it's" },
      })
    )
    -- POSIX shells keep the usual quoting
    eq({ [[x='it'"'"'s\']] }, langs.var_lines("sh", { { name = "x", value = [[it's\]] } }))
  end)
end)

describe("babel noweb cache", function()
  it("sees edits made between and during cached expansions", function()
    local buf = org_buffer({
      "#+NAME: foo",
      "#+begin_src sh",
      "echo one",
      "#+end_src",
    })
    eq({ "echo one" }, babel.expand_noweb(buf, { "<<foo>>" }))
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "echo two" })
    eq({ "echo two" }, babel.expand_noweb(buf, { "<<foo>>" }))
    babel.with_noweb_cache(function()
      eq({ "echo two" }, babel.expand_noweb(buf, { "<<foo>>" }))
      vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "echo three" })
      eq({ "echo three" }, babel.expand_noweb(buf, { "<<foo>>" }))
    end)
  end)

  it("finds the named results of every block in one parse", function()
    local lines = {}
    for i = 1, 3 do
      vim.list_extend(lines, { "#+NAME: b" .. i, "#+begin_src sh", "echo", "#+end_src", "text" })
    end
    vim.list_extend(lines, { "#+RESULTS: b3", ": 3", "#+RESULTS: b1", ": 1", "#+results: b1", ": dup" })
    local list = blocks.parse_blocks(lines)
    eq(18, list[1].results.start)
    eq(nil, list[2].results)
    eq(16, list[3].results.start)
  end)
end)

describe("babel noweb strip-tangle", function()
  local function tangled(lines)
    local buf = org_buffer(lines)
    local groups, order = require("org.babel.tangle").collect(buf, {})
    return groups[order[1]][1].body
  end

  it("removes the reference but keeps its line, like Emacs", function()
    eq(
      "echo a\n\necho b",
      tangled({
        "#+NAME: foo",
        "#+begin_src sh",
        "echo foo",
        "#+end_src",
        "",
        "#+begin_src sh :tangle /tmp/org-strip.sh :noweb strip-tangle",
        "echo a",
        "<<foo>>",
        "echo b",
        "#+end_src",
      })
    )
  end)

  it("expands the references of a strip-tangle block included by another", function()
    eq(
      "echo in\necho foo",
      tangled({
        "#+NAME: foo",
        "#+begin_src sh",
        "echo foo",
        "#+end_src",
        "#+NAME: inner",
        "#+begin_src sh :noweb strip-tangle",
        "echo in",
        "<<foo>>",
        "#+end_src",
        "#+begin_src sh :tangle /tmp/org-strip.sh :noweb yes",
        "<<inner>>",
        "#+end_src",
      })
    )
  end)
end)

-- Edge cases of the code extension: code: link paths with `::` in the
-- symbol, TODO comments in odd places, symbol names with pattern
-- characters, UTF-16 columns, paths that only share a prefix, and src
-- blocks of code that holds Org syntax.
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))

local link = require("org.extensions.code.link")
local todos = require("org.extensions.code.todos")
local symbols = require("org.extensions.code.symbols")
local git = require("org.extensions.code.git")
local context = require("org.extensions.code.context")
local branch = require("org.extensions.code.branch")

local O = {
  keywords = { "TODO", "FIXME", "HACK", "XXX", "BUG" },
  require_comment = true,
  link_pattern = "^org:%s*(.-)%s*$",
}

describe("code edge cases", function()
  before_each(function()
    require("org").setup({ extensions = { code = {} } })
  end)
  after_each(function()
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = { root .. "/tests/fixtures/*.org" },
    })
  end)

  it("splits a code: path at the first ::, keeping C++ and Rust paths in the symbol", function()
    eq({ "src/a.cpp", "ns::Class::method" }, { link.split("src/a.cpp::ns::Class::method") })
    eq({ "src/a.lua", nil }, { link.split("src/a.lua::") })
    eq({ "src/a.lua", nil }, { link.split("src/a.lua::   ") })
    eq({ "", "sym" }, { link.split("::sym") })
    eq({ "plain.lua", nil }, { link.split("plain.lua") })
    eq({ "C:\\code\\a.rs", "crate::f" }, { link.split("C:\\code\\a.rs::crate::f") })
  end)

  it("finds TODO comments only in comments, as whole words", function()
    local cases = {
      { "-- TODO: fix", "TODO", "fix" },
      { "# FIXME handle it", "FIXME", "handle it" },
      { "/* XXX: c style */", "XXX", "c style" },
      { "<!-- HACK: html -->", "HACK", "html" },
      { "  ; BUG lisp", "BUG", "lisp" },
      { " * TODO: inside a doc comment", "TODO", "inside a doc comment" },
      { "// TODO", "TODO", "" },
      { "% TODO: latex", "TODO", "latex" },
      { "-- TODO: café ✓ 日本", "TODO", "café ✓ 日本" },
    }
    for _, c in ipairs(cases) do
      local t = todos.parse(c[1], O)
      ok(t, c[1])
      eq({ c[2], c[3] }, { t.keyword, t.text }, c[1])
    end
    for _, line in ipairs({
      'local s = "TODO: in a string"',
      "TODOS are words",
      "-- MyTODO: not a word",
      "-- TODO_list",
      "x = y -- TODOx",
      "",
    }) do
      eq(nil, todos.parse(line, O), line)
    end
  end)

  it("reads the argument and org: ID of a TODO, unbalanced parentheses too", function()
    local t = todos.parse("// TODO(org: abc-123): linked", O)
    eq({ "org: abc-123", "abc-123", "linked" }, { t.arg, t.id, t.text })
    t = todos.parse("// TODO(alice): owned", O)
    eq({ "alice", nil, "owned" }, { t.arg, t.id, t.text })
    t = todos.parse("// TODO(unclosed: text", O)
    eq(nil, t.arg)
    t = todos.parse("// TODO(org:): empty id", O)
    eq(nil, t.id)
  end)

  it("takes the first keyword on a line with several", function()
    local t = todos.parse("-- FIXME: first TODO: second", O)
    eq("FIXME", t.keyword)
  end)

  it("finds symbols whose names hold pattern characters", function()
    local lines = {
      "local M = {}",
      "function M.run_100%()",
      "end",
      "M['a.b'] = 1",
      "function M.go(x) end",
    }
    eq(nil, symbols.text_find(lines, ""))
    eq(nil, symbols.text_find(lines, "nothing_here"))
    eq(5, symbols.text_find(lines, "M.go").lnum)
    eq(5, symbols.text_find(lines, "go").lnum)
    ok(pcall(symbols.text_find, lines, "run_100%"))
    ok(pcall(symbols.text_find, lines, "a[b"))
    ok(pcall(symbols.text_find, lines, "(x)"))
  end)

  it("turns UTF-16 columns past an emoji into byte columns", function()
    local line = "a😀b"
    -- the emoji is 2 UTF-16 units and 4 bytes
    eq(5, symbols.byte_col(line, 3, "utf-16"))
    eq(5, symbols.byte_col(line, 2, "utf-32"))
    eq(2, symbols.byte_col(line, 2, "utf-8"))
    eq(0, symbols.byte_col(line, -1, "utf-16"))
    eq(#line, symbols.byte_col(line, 99, "utf-8"))
    ok(symbols.byte_col(line, 99, "utf-16") <= #line)
  end)

  it("doesn't take a sibling directory sharing a prefix for the root", function()
    local base = require("org.utils").realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(base .. "/repo", "p")
    vim.fn.mkdir(base .. "/repo-other", "p")
    vim.fn.writefile({}, base .. "/repo-other/x.lua")
    eq(nil, git.relpath(base .. "/repo", base .. "/repo-other/x.lua"))
    eq("x.lua", git.relpath(base .. "/repo-other", base .. "/repo-other/x.lua"))
    eq(nil, git.relpath(base .. "/repo", base .. "/repo"))
    vim.fn.delete(base, "rf")
  end)

  it("has no root outside a repository", function()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    -- the temp dir could sit in a repository on some machines
    if not vim.fs.find(".git", { path = d, upward = true, limit = 1 })[1] then
      eq(nil, git.root(d))
    end
    eq(nil, git.relpath(d, "/elsewhere/file"))
    vim.fn.delete(d, "rf")
  end)

  it("escapes Org syntax inside captured code and trims trailing blank lines", function()
    local block = context.block({
      lang = "org",
      lines = { "    * a heading", "    #+end_src", "    ,* escaped", "    ,plain comma", "", "   " },
    })
    eq(
      table.concat(
        { "#+begin_src org", ",* a heading", ",#+end_src", ",,* escaped", ",plain comma", "#+end_src" },
        "\n"
      ),
      block
    )
    eq("", context.block({ lang = "lua", lines = {} }))
    eq("#+begin_src\nx\n#+end_src", context.block({ lang = "", lines = { "x" } }))
  end)

  it("reads a ticket from a branch name, by pattern or function, or none", function()
    eq("ABC-12", branch.ticket("feature/ABC-12-login"))
    eq(nil, branch.ticket("main"))
    require("org").setup({ extensions = { code = { branch_ticket_pattern = "" } } })
    eq(nil, branch.ticket("feature/ABC-12"))
    require("org").setup({
      extensions = {
        code = {
          branch_ticket_pattern = function(b)
            return b:match("#(%d+)")
          end,
        },
      },
    })
    eq("42", branch.ticket("fix/#42-typo"))
  end)

  it("maps unknown and empty filetypes to themselves or nothing", function()
    eq("", context.lang(""))
    eq("someweirdft", context.lang("someweirdft"))
  end)
end)

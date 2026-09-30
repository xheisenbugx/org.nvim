local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local utils = require("org.utils")

local repo -- temp git repository of each test
local saved = {}

local function stub(mod, name, fn)
  saved[#saved + 1] = { mod, name, mod[name] }
  mod[name] = fn
end

local function write(rel, lines)
  local path = repo .. "/" .. rel
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
  return path
end

local function read(path)
  return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
end

local function git(args)
  local cmd = { "git", "-C", repo, "-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false" }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { text = true }):wait()
  assert(res.code == 0, table.concat(cmd, " ") .. ": " .. (res.stderr or ""))
  return vim.trim(res.stdout or "")
end

-- the agenda text once it holds `want` (the code TODOs are scanned in the
-- background)
local function agenda_text(want)
  local buf = require("org.agenda.view").state.buf
  local text
  vim.wait(5000, function()
    text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    return text:find(want, 1, true) ~= nil
  end, 10)
  ok(text:find(want, 1, true), text)
  return text
end

local function setup(code, extra)
  require("org").setup(vim.tbl_extend("force", {
    org_directory = repo .. "/notes",
    agenda_files = { repo .. "/.org/*.org" },
    default_notes_file = repo .. "/notes/inbox.org",
    extensions = { code = code or {} },
  }, extra or {}))
end

local APP = {
  "local M = {}",
  "",
  "-- TODO: handle errors",
  "function M.setup(opts)",
  "  local x = opts or {}",
  "  return x",
  "end",
  "",
  "local function helper()",
  "  return 1 -- FIXME(bob): wrong value",
  "end",
  "",
  "return M",
}

local PY = {
  "import os",
  "",
  "def greet(name):",
  "    # TODO(org:task-1): greet in French",
  "    return 'hi ' + name",
  "",
  "class Greeter:",
  "    pass",
}

local has_git = vim.fn.executable("git") == 1

-- the parsers bundled with Neovim (lib/nvim/parser), which the minimal
-- runtimepath leaves out: Lua's ftplugin starts treesitter on 0.12+
local parser_dir = vim.fs.normalize(vim.env.VIMRUNTIME .. "/../../../lib/nvim")
local saved_rtp

local function has_ts_lua()
  return pcall(vim.treesitter.language.add, "lua")
end

describe("code extension", function()
  before_each(function()
    saved_rtp = vim.o.runtimepath
    if vim.uv.fs_stat(parser_dir .. "/parser") then
      vim.opt.runtimepath:append(parser_dir)
    end
    repo = vim.fn.tempname() .. "/myrepo"
    vim.fn.mkdir(repo, "p")
    repo = vim.uv.fs_realpath(repo)
    write("src/app.lua", APP)
    write("tools/greet.py", PY)
    if has_git then
      git({ "init", "-q", "-b", "main" })
      git({ "add", "." })
      git({ "commit", "-q", "-m", "init" })
    else
      vim.fn.mkdir(repo .. "/.git", "p")
      vim.fn.writefile({ "ref: refs/heads/main" }, repo .. "/.git/HEAD")
    end
    setup()
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      local s = saved[i]
      s[1][s[2]] = s[3]
    end
    saved = {}
    vim.o.runtimepath = saved_rtp
    pcall(require("org.clock").clock_out, { quiet = true })
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(vim.fs.dirname(repo), "rf")
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = { root .. "/tests/fixtures/*.org" },
    })
  end)

  it("reports in :checkhealth", function()
    local out = {}
    local h = {}
    for _, k in ipairs({ "start", "ok", "info", "warn", "error" }) do
      h[k] = function(msg)
        out[#out + 1] = k .. ": " .. msg
      end
    end
    setup({ branch_clock = true })
    require("org.extensions").check(h)
    ok(vim.tbl_contains(out, "ok: enabled: code"), vim.inspect(out))
    ok(vim.tbl_contains(out, "info: branch clocking is on"), vim.inspect(out))
    for _, l in ipairs(out) do
      ok(not l:find("^error"), l)
    end
  end)

  describe("git", function()
    it("finds the root, branch, repo name and relative path", function()
      local g = require("org.extensions.code.git")
      eq(repo, g.root(repo .. "/src/app.lua"))
      eq("main", g.branch(repo))
      eq("myrepo", g.repo_name(repo))
      eq("src/app.lua", g.relpath(repo, repo .. "/src/app.lua"))
      eq(nil, g.root(vim.fs.dirname(repo)))
    end)

    it("reads the branch of a worktree's .git file", function()
      local g = require("org.extensions.code.git")
      local wt = vim.fs.dirname(repo) .. "/wt"
      local gd = vim.fs.dirname(repo) .. "/gitdir"
      vim.fn.mkdir(wt, "p")
      vim.fn.mkdir(gd, "p")
      vim.fn.writefile({ "gitdir: " .. gd }, wt .. "/.git")
      vim.fn.writefile({ "ref: refs/heads/feature/x" }, gd .. "/HEAD")
      eq("feature/x", g.branch(g.root(wt)))
      vim.fn.writefile({ "0123456789abcdef" }, gd .. "/HEAD")
      eq(nil, g.branch(g.root(wt)))
    end)

    it("follows a gitdir path with spaces, and a relative one (submodules)", function()
      local g = require("org.extensions.code.git")
      local base = vim.fs.dirname(repo)
      local wt = base .. "/my work tree"
      local gd = base .. "/git dirs/wt ü"
      vim.fn.mkdir(wt, "p")
      vim.fn.mkdir(gd, "p")
      vim.fn.writefile({ "gitdir: " .. gd .. "  " }, wt .. "/.git")
      vim.fn.writefile({ "ref: refs/heads/spaced" }, gd .. "/HEAD")
      eq(gd, g.git_dir(wt))
      eq("spaced", g.branch(g.root(wt .. "/x.lua")))
      vim.fn.writefile({ "gitdir: ../git dirs/wt ü" }, wt .. "/.git")
      eq("spaced", g.branch(wt))
    end)

    it("gives the short commit when git is installed", function()
      if not has_git then
        return
      end
      local g = require("org.extensions.code.git")
      eq(git({ "rev-parse", "--short", "HEAD" }), g.commit(repo))
    end)
  end)

  describe("off", function()
    it("registers nothing when disabled, and removes it all again", function()
      require("org").setup({ org_directory = root .. "/tests/fixtures" })
      local capture = require("org.capture")
      local render = require("org.agenda.render")
      eq({}, capture.expansions)
      eq(nil, render.sources.code_todos)
      eq(nil, require("org.config").opts.links.types.code)
      eq(nil, require("org.actions").list.code_capture)
      eq({}, vim.api.nvim_get_autocmds({ group = "org.code" }))
      setup({ branch_clock = true })
      ok(capture.expansions["code-block"])
      ok(render.sources.code_todos)
      ok(require("org.config").opts.links.types.code)
      ok(require("org.actions").list.code_capture)
      ok(#vim.api.nvim_get_autocmds({ group = "org.code" }) > 0)
      require("org").setup({ org_directory = root .. "/tests/fixtures" })
      eq({}, capture.expansions)
      eq(nil, render.sources.code_todos)
      eq(nil, require("org.actions").list.code_capture)
      eq({}, vim.api.nvim_get_autocmds({ group = "org.code" }))
    end)

    it("leaves %(name) templates to Lua/Lisp when no expansion has the name", function()
      require("org").setup({ org_directory = root .. "/tests/fixtures" })
      local capture = require("org.capture")
      eq("3", capture.eval_sexp("1 + 2", {}))
      capture.expansions.demo = function(ctx)
        return "demo:" .. tostring(ctx.initial)
      end
      eq("demo:x", capture.eval_sexp(" demo ", { initial = "x" }))
      capture.expansions.demo = nil
    end)
  end)

  describe("capture", function()
    it("maps filetypes to Babel languages", function()
      local c = require("org.extensions.code.context")
      eq("lua", c.lang("lua"))
      eq("js", c.lang("javascript"))
      eq("C++", c.lang("cpp"))
      eq("python", c.lang("python"))
      setup({ languages = { python = "py3" } })
      eq("py3", c.lang("python"))
    end)

    it("makes an escaped, dedented src block of a selection", function()
      local c = require("org.extensions.code.context")
      eq(
        "#+begin_src lua\n,* a\n,#+x\n  b\n#+end_src",
        c.block({ lang = "lua", lines = { "    * a", "    #+x", "      b", "" } })
      )
      eq("", c.block({ lang = "lua" }))
    end)

    it("captures a Visual selection into the project file", function()
      vim.cmd("edit " .. repo .. "/src/app.lua")
      vim.keymap.set("x", "<F7>", function()
        require("org.actions").run("code_capture")
      end, { buffer = true })
      vim.api.nvim_feedkeys(vim.keycode("4GVjj<F7>"), "x", false)
      local cbuf = vim.api.nvim_get_current_buf()
      ok(require("org.capture").sessions[cbuf], "a capture buffer")
      local text = table.concat(buf_lines(cbuf), "\n")
      local target = has_ts_lua() and "M.setup][M.setup (app.lua)]]" or "4][app.lua:4]]"
      ok(text:find("[[code:" .. vim.fn.fnamemodify(repo, ":~") .. "/src/app.lua::" .. target, 1, true), text)
      local block = "#+begin_src lua\nfunction M.setup(opts)\n  local x = opts or {}\n  return x\n#+end_src"
      ok(text:find(block, 1, true), text)
      ok(text:find("myrepo on main", 1, true), text)
      vim.cmd("stopinsert")
      utils.run(require("org.capture").finalize, cbuf)
      local lines = read(repo .. "/.org/tasks.org")
      eq("#+title: myrepo", lines[1])
      local all = table.concat(lines, "\n")
      ok(all:find("\n* Tasks\n", 1, true), all)
      ok(all:find("\n** \n", 1, true), all)
      ok(all:find("#+begin_src lua", 1, true), all)
    end)

    it("links to the line and leaves the block out in Normal mode", function()
      setup({
        capture_template = {
          template = "* %?\n%(code-link)|%(code-file-link)|%(code-block)|%(code-line)",
          target = "project",
          immediate_finish = true,
        },
      })
      vim.cmd("edit " .. repo .. "/tools/greet.py")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      require("org.actions").run("code_capture")
      local all = table.concat(read(repo .. "/.org/tasks.org"), "\n")
      local path = vim.fn.fnamemodify(repo, ":~") .. "/tools/greet.py"
      ok(all:find("[[code:" .. path .. "::1][greet.py:1]]|[[file:" .. path .. "::1][greet.py:1]]||1", 1, true), all)
    end)

    it("fills %(git-branch) and friends in menu templates started from code", function()
      setup({}, {
        capture = {
          templates = {
            x = {
              description = "x",
              template = "* note\n%(git-repo)/%(git-branch)/%(code-file)/%(code-lang)/%(code-symbol)",
              target = repo .. "/notes/x.org",
              immediate_finish = true,
            },
          },
        },
      })
      vim.fn.mkdir(repo .. "/notes", "p")
      vim.cmd("edit " .. repo .. "/src/app.lua")
      vim.api.nvim_win_set_cursor(0, { 5, 2 })
      utils.run(require("org.capture").capture, "x")
      local sym = has_ts_lua() and "M.setup" or ""
      eq({ "* note", "myrepo/main/src/app.lua/lua/" .. sym }, read(repo .. "/notes/x.org"))
    end)

    it("adds its template to the capture menu, keeping the default one", function()
      local templates = require("org.config").opts.capture.templates
      ok(templates.k)
      ok(templates.t, "the default template stays")
      setup({ template_key = false })
      eq(nil, require("org.config").opts.capture.templates.k)
    end)

    it("keeps a multibyte last character of a characterwise selection", function()
      setup({ capture_template = { template = "* x\n%(code-block)", target = "project", immediate_finish = true } })
      vim.cmd("edit " .. write("src/u.lua", { "x = 'é' .. 'ü'" }))
      vim.keymap.set("x", "<F7>", function()
        require("org.actions").run("code_capture")
      end, { buffer = true })
      vim.api.nvim_feedkeys(vim.keycode("0v5l<F7>"), "x", false)
      local all = table.concat(read(repo .. "/.org/tasks.org"), "\n")
      ok(all:find("#+begin_src lua\nx = 'é\n#+end_src", 1, true), all)
    end)

    it("gathers the code context once per capture", function()
      local g = require("org.extensions.code.git")
      local calls = 0
      local commit = g.commit
      stub(g, "commit", function(r)
        calls = calls + 1
        return commit(r)
      end)
      setup({}, {
        capture = {
          templates = {
            x = {
              description = "x",
              template = "* %(code-symbol)\n%(code-link)\n%(git-info)\n%(git-commit)\n%(code-file)",
              target = repo .. "/notes/x.org",
              immediate_finish = true,
            },
          },
        },
      })
      vim.fn.mkdir(repo .. "/notes", "p")
      vim.cmd("edit " .. repo .. "/src/app.lua")
      utils.run(require("org.capture").capture, "x")
      eq(1, calls)
      eq(5, #read(repo .. "/notes/x.org"))
    end)

    it("files code captures outside a repository in fallback_target, without the project headline", function()
      local outside = vim.fs.dirname(repo) .. "/loose"
      vim.fn.mkdir(outside, "p")
      vim.fn.mkdir(repo .. "/notes", "p")
      vim.fn.writefile({ "print(1)" }, outside .. "/script.lua")
      setup({
        capture_template = { template = "* note %(code-line)", target = "project", immediate_finish = true },
      })
      vim.cmd("edit " .. outside .. "/script.lua")
      -- code_capture and the menu template: the default notes file, at its end
      require("org.actions").run("code_capture")
      utils.run(require("org.capture").capture, "k")
      eq({ "* note 1", "* note 1" }, read(repo .. "/notes/inbox.org"))
      setup({
        capture_template = { template = "* note %(code-line)", target = "project", immediate_finish = true },
        fallback_target = repo .. "/notes/loose.org",
        fallback_headline = "Loose code",
      })
      require("org.actions").run("code_capture")
      utils.run(require("org.capture").capture, "k")
      eq({ "* Loose code", "** note 1", "** note 1" }, read(repo .. "/notes/loose.org"))
      -- in a repository the menu template still uses the project headline
      vim.cmd("edit " .. repo .. "/src/app.lua")
      utils.run(require("org.capture").capture, "k")
      ok(vim.tbl_contains(read(repo .. "/.org/tasks.org"), "* Tasks"))
    end)

    it("refuses org buffers", function()
      local msgs = {}
      stub(utils, "warn", function(m)
        msgs[#msgs + 1] = m
      end)
      org_buffer({ "* A" })
      require("org.extensions.code.context").capture()
      ok(msgs[1] and msgs[1]:find("code buffers"))
    end)
  end)

  describe("code: links", function()
    it("follows a symbol with treesitter or a text search, and a line", function()
      local link = require("org.extensions.code.link")
      org_buffer({ "x" })
      ok(link.follow(repo .. "/src/app.lua::M.setup"))
      eq(repo .. "/src/app.lua", vim.api.nvim_buf_get_name(0))
      eq(4, vim.api.nvim_win_get_cursor(0)[1])
      ok(link.follow(repo .. "/src/app.lua::helper"))
      eq(9, vim.api.nvim_win_get_cursor(0)[1])
      ok(link.follow(repo .. "/tools/greet.py::Greeter"))
      eq({ 7, 6 }, vim.api.nvim_win_get_cursor(0))
      ok(link.follow(repo .. "/tools/greet.py::greet"))
      eq(3, vim.api.nvim_win_get_cursor(0)[1])
      ok(link.follow(repo .. "/tools/greet.py::5"))
      eq(5, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("resolves relative paths from the git root of the org file", function()
      vim.cmd("edit " .. write(".org/notes.org", { "[[code:src/app.lua::M.setup]]" }))
      vim.api.nvim_win_set_cursor(0, { 1, 3 })
      require("org.links").open_at_point()
      eq(repo .. "/src/app.lua", vim.api.nvim_buf_get_name(0))
      eq(4, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("uses the language server's document symbols", function()
      local buf = vim.fn.bufadd(repo .. "/tools/greet.py")
      vim.fn.bufload(buf)
      local client = {
        supports_method = function()
          return true
        end,
        config = { filetypes = { "python" } },
      }
      stub(vim.lsp, "get_clients", function()
        return { client }
      end)
      stub(vim.lsp, "buf_request_sync", function(_, method)
        eq("textDocument/documentSymbol", method)
        return {
          [1] = {
            result = {
              {
                name = "Greeter",
                kind = 5,
                range = { start = { line = 6, character = 0 }, ["end"] = { line = 7, character = 8 } },
                selectionRange = { start = { line = 6, character = 6 }, ["end"] = { line = 6, character = 13 } },
                children = {
                  {
                    name = "hello",
                    kind = 6,
                    range = { start = { line = 7, character = 4 }, ["end"] = { line = 7, character = 8 } },
                    selectionRange = { start = { line = 7, character = 4 }, ["end"] = { line = 7, character = 8 } },
                  },
                },
              },
            },
          },
        }
      end)
      local symbols = require("org.extensions.code.symbols")
      eq({ lnum = 8, col = 4, via = "lsp" }, symbols.find(buf, "Greeter.hello"))
      eq({ lnum = 8, col = 4, via = "lsp" }, symbols.find(buf, "hello"))
      -- a method is named with its class, so the link is not ambiguous
      eq("Greeter.hello", symbols.at(buf, 8, 5))
      eq("Greeter", symbols.at(buf, 7, 0))
    end)

    it("asks only the language servers that answer documentSymbol (0.10 and 0.11+ clients)", function()
      local symbols = require("org.extensions.code.symbols")
      local method = "textDocument/documentSymbol"
      -- Neovim 0.10: a field; called with a table (a colon call) it says yes
      local old_yes = {
        supports_method = function(m)
          return type(m) ~= "string" or m == method
        end,
      }
      local old_no = {
        supports_method = function(m)
          return type(m) ~= "string"
        end,
      }
      -- Neovim 0.11+: a method of the client class
      local Client = {}
      Client.__index = Client
      function Client:supports_method(m)
        return self.caps[m] == true
      end
      local new_yes = setmetatable({ caps = { [method] = true } }, Client)
      local new_no = setmetatable({ caps = {} }, Client)
      eq(true, symbols.supports_symbols(old_yes))
      eq(false, symbols.supports_symbols(old_no))
      eq(true, symbols.supports_symbols(new_yes))
      eq(false, symbols.supports_symbols(new_no))
      eq(true, symbols.supports_symbols({ server_capabilities = { documentSymbolProvider = true } }))
    end)

    it("waits for a language server that is still starting for the buffer", function()
      local buf = vim.fn.bufadd(repo .. "/tools/greet.py")
      vim.fn.bufload(buf)
      local client = { id = 7, offset_encoding = "utf-16", server_capabilities = { documentSymbolProvider = true } }
      local ready = false
      vim.defer_fn(function()
        ready = true
      end, 50)
      stub(vim.lsp, "get_clients", function(filter)
        if filter and filter._uninitialized then
          return { client }
        end
        -- no running client serves python: only the starting one counts
        return ready and filter and filter.bufnr and { client } or {}
      end)
      stub(vim.lsp, "buf_request_sync", function()
        local r = { start = { line = 2, character = 4 }, ["end"] = { line = 2, character = 9 } }
        return { [7] = { result = { { name = "greet", kind = 12, range = r, selectionRange = r } } } }
      end)
      eq({ lnum = 3, col = 4, via = "lsp" }, require("org.extensions.code.symbols").find(buf, "greet"))
    end)

    it("reads LSP columns in the server's position encoding", function()
      local symbols = require("org.extensions.code.symbols")
      local line = "local s = '😀😀' function M.setup(opts)"
      eq(30, symbols.byte_col(line, 26, "utf-16"))
      eq(30, symbols.byte_col(line, 24, "utf-32"))
      eq(30, symbols.byte_col(line, 30, "utf-8"))
      eq(#line, symbols.byte_col(line, 999, "utf-8"))
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line, "end" })
      local client = { id = 3, offset_encoding = "utf-32", server_capabilities = { documentSymbolProvider = true } }
      stub(vim.lsp, "get_clients", function()
        return { client }
      end)
      stub(vim.lsp, "get_client_by_id", function(id)
        return id == 3 and client or nil
      end)
      stub(vim.lsp, "buf_request_sync", function()
        local r = { start = { line = 0, character = 24 }, ["end"] = { line = 1, character = 3 } }
        return { [3] = { result = { { name = "M.setup", kind = 12, range = r, selectionRange = r } } } }
      end)
      eq({ lnum = 1, col = 30, via = "lsp" }, symbols.find(buf, "M.setup"))
    end)

    it("finds treesitter definitions bound to names and C declarators", function()
      local symbols = require("org.extensions.code.symbols")
      local function buffer(ft, lines)
        local b = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
        vim.bo[b].filetype = ft
        return b
      end
      if has_ts_lua() then
        local b = buffer("lua", {
          "local M = {}",
          "-- value is used before: M.value()",
          "M.value = function()",
          "  return 1",
          "end",
          "local t = { build = function() end }",
          "return M",
        })
        eq({ lnum = 3, col = 0, via = "treesitter" }, symbols.find(b, "M.value"))
        eq({ lnum = 6, col = 12, via = "treesitter" }, symbols.find(b, "build"))
        eq("M.value", symbols.at(b, 4, 2))
      end
      if pcall(vim.treesitter.language.add, "c") then
        local b = buffer("c", {
          "struct point p;",
          "static int *make_point(int x);",
          "struct point { int x; };",
          "static int *make_point(int x) {",
          "  return 0;",
          "}",
        })
        eq({ lnum = 4, col = 12, via = "treesitter" }, symbols.find(b, "make_point"))
        eq({ lnum = 3, col = 7, via = "treesitter" }, symbols.find(b, "point"))
        eq("make_point", symbols.at(b, 5, 2))
      end
    end)

    it("finds definitions by text", function()
      local symbols = require("org.extensions.code.symbols")
      local lines = { "x = foo()", "const foo = 1", "fn foo() {}" }
      eq({ lnum = 2, col = 6 }, symbols.text_find(lines, "foo"))
      eq({ lnum = 2, col = 4 }, symbols.text_find({ "a", "b = foo" }, "foo"))
      eq(nil, symbols.text_find({ "nothing" }, "foo"))
    end)

    it("stores a link to the symbol at the cursor, or the line", function()
      vim.cmd("edit " .. repo .. "/src/app.lua")
      vim.api.nvim_win_set_cursor(0, { 6, 2 })
      require("org.links").store_link()
      local path = vim.fn.fnamemodify(repo, ":~") .. "/src/app.lua"
      local want = { link = "code:" .. path .. "::M.setup", desc = "M.setup (app.lua)" }
      if not has_ts_lua() then
        want = { link = "code:" .. path .. "::6", desc = "app.lua:6" }
      end
      eq(want, {
        link = require("org.links").stored[1].link,
        desc = require("org.links").stored[1].desc,
      })
      setup({ link_path = "relative" })
      vim.api.nvim_win_set_cursor(0, { 13, 0 })
      local l = require("org.extensions.code").store_link()
      eq("code:src/app.lua::13", l.link)
    end)

    it("does not store code: links in org buffers", function()
      org_buffer({ "* A" })
      eq(nil, require("org.extensions.code.link").store())
    end)

    it("locates a link's target without opening the file", function()
      local link = require("org.extensions.code.link")
      local org = write(".org/notes.org", { "* x" })
      local loc = link.type.locate("src/app.lua::M.setup", org)
      eq(repo .. "/src/app.lua", loc.path)
      eq(4, loc.lnum)
      if has_ts_lua() then
        eq({ 9, 7, 4, 7 }, { loc.col, loc.len, loc.first, loc.last })
      end
      eq(10, link.type.locate("src/app.lua::10", org).lnum)
      eq(nil, link.type.locate("src/nope.lua::x", org))
      eq(-1, vim.fn.bufnr(repo .. "/src/app.lua"), "no buffer was loaded")
    end)

    it("goes to a code: link's definition from the org language server", function()
      setup({}, { extensions = { code = {}, lsp = {} } })
      vim.cmd("edit " .. write(".org/notes.org", { "See [[code:src/app.lua::helper]]." }))
      local util = require("org.extensions.lsp.util")
      local targets = require("org.extensions.lsp.targets")
      local doc = util.doc_from_buf(0)
      local l = targets.link_at(doc, 1, 10)
      local loc = targets.resolve(doc, l)
      eq(repo .. "/src/app.lua", loc.path)
      eq(9, loc.lnum)
    end)

    it("transcludes the definition a code: link names", function()
      setup({}, { extensions = { code = {}, transclusion = {} } })
      local org = write(".org/notes.org", { "#+transclude: [[code:src/app.lua::helper]]" })
      local spec = require("org.extensions.transclusion.keyword").parse("[[code:src/app.lua::helper]]")
      local res, err = require("org.extensions.transclusion.source").resolve(spec, { filename = org })
      ok(res, err)
      local want = has_ts_lua() and { "local function helper()", "  return 1 -- FIXME(bob): wrong value", "end" }
        or { "local function helper()" }
      eq(want, res.raw)
      eq("#+begin_src lua", res.lines[1])
    end)

    it("exports as code text", function()
      local links = require("org.links")
      eq("<code>src/app.lua:3</code>", links.export_link("code:src/app.lua::3", nil, "html"))
      eq("`setup`", links.export_link("code:src/app.lua::M.setup", "setup", "md"))
    end)
  end)

  describe("projects", function()
    it("resolves project_file patterns", function()
      local project = require("org.extensions.code.project")
      eq(repo .. "/.org/tasks.org", project.file(repo))
      setup({ project_file = "<org_directory>/projects/${repo}.org" })
      eq(repo .. "/notes/projects/myrepo.org", project.file(repo))
      setup({
        project_file = function(r, name)
          return r .. "/" .. name .. ".org"
        end,
      })
      eq(repo .. "/myrepo.org", project.file(repo))
    end)

    it("opens the project file, creating it", function()
      vim.cmd("edit " .. repo .. "/src/app.lua")
      require("org.actions").run("project_open")
      eq(repo .. "/.org/tasks.org", vim.api.nvim_buf_get_name(0))
      eq({ "#+title: myrepo", "" }, buf_lines(0))
    end)

    it("warns when project_file names no file", function()
      local msgs = {}
      stub(utils, "warn", function(m)
        msgs[#msgs + 1] = m
      end)
      setup({
        project_file = function()
          return nil
        end,
      })
      vim.cmd("edit " .. repo .. "/src/app.lua")
      for _, a in ipairs({ "project_open", "project_capture", "project_agenda" }) do
        msgs = {}
        eq(true, (pcall(require("org.actions").run, a)), a)
        ok(msgs[1] and msgs[1]:find("No project file", 1, true), a .. ": " .. vim.inspect(msgs))
      end
    end)

    it("captures into the project file", function()
      setup({ project_template = { template = "* TODO Ship it", immediate_finish = true } })
      vim.cmd("edit " .. repo .. "/src/app.lua")
      require("org.actions").run("project_capture")
      eq({ "#+title: myrepo", "", "* Tasks", "", "** TODO Ship it" }, read(repo .. "/.org/tasks.org"))
    end)

    it("shows the project agenda with the code TODOs, grouped by ID", function()
      write(".org/tasks.org", {
        "#+title: myrepo",
        "* Tasks",
        "** TODO Translate greetings",
        ":PROPERTIES:",
        ":ID: task-1",
        ":END:",
      })
      vim.cmd("edit " .. repo .. "/src/app.lua")
      require("org.actions").run("project_agenda")
      eq("orgagenda", vim.bo.filetype)
      local text = agenda_text("TODOs in myrepo  (3)")
      ok(text:find("Code TODOs in myrepo", 1, true), text)
      ok(text:find("TODO Translate greetings", 1, true), text)
      ok(text:find("↳ greet: +TODO greet in French  %(tools/greet.py:4%)"), text)
      ok(text:find("TODO handle errors  (src/app.lua:3)", 1, true), text)
      ok(text:find("FIXME wrong value  (src/app.lua:10)", 1, true), text)
      -- the heading's item comes before its code TODO
      ok(text:find("Translate greetings", 1, true) < text:find("greet in French", 1, true))
      -- <CR> on a code TODO opens the line
      local lines = buf_lines(0)
      for i, l in ipairs(lines) do
        if l:find("wrong value", 1, true) then
          vim.api.nvim_win_set_cursor(0, { i, 0 })
          break
        end
      end
      require("org.agenda.view").switch_to()
      eq(repo .. "/src/app.lua", vim.api.nvim_buf_get_name(0))
      eq(10, vim.api.nvim_win_get_cursor(0)[1])
    end)
  end)

  describe("code TODOs", function()
    it("parses comment keywords", function()
      local t = require("org.extensions.code.todos")
      local p = t.parse("  -- TODO(org:abc-1): do it")
      eq({ "TODO", "org:abc-1", "abc-1", "do it" }, { p.keyword, p.arg, p.id, p.text })
      p = t.parse("/* FIXME: leak */")
      eq({ "FIXME", "leak" }, { p.keyword, p.text })
      p = t.parse("# HACK")
      eq({ "HACK", "" }, { p.keyword, p.text })
      eq(nil, t.parse('local s = "TODO: not a comment"'))
      eq(nil, t.parse("-- TODOS are fine"))
      eq(nil, t.parse("-- nothing to do"))
      setup({ todo_require_comment = false })
      ok(t.parse('local s = "TODO: now it counts"'))
    end)

    it("scans with the Lua walker and skips org files", function()
      setup({ todo_scanner = "lua" })
      write(".org/tasks.org", { "* TODO Not code" })
      local found = require("org.extensions.code.todos").scan(repo)
      eq({ "src/app.lua:3", "src/app.lua:10", "tools/greet.py:4" }, vim.tbl_map(function(t)
        return t.rel .. ":" .. t.lnum
      end, found))
    end)

    it("scans with git grep, including untracked files", function()
      if not has_git then
        return
      end
      setup({ todo_scanner = "git" })
      write("new.sh", { "# XXX: untracked" })
      local found = require("org.extensions.code.todos").scan(repo)
      eq(4, #found)
      eq("new.sh", found[1].rel)
      eq("XXX", found[1].keyword)
    end)

    it("is an agenda block type", function()
      require("org.agenda").open({ type = "code_todos", root = repo, title = "Mine" })
      agenda_text("Mine  (3)")
    end)

    it("reads paths with non-ASCII bytes, spaces and colons from git grep and rg", function()
      write("docs/ünï côde.lua", { "-- TODO: unicode" })
      write("a:1:b.lua", { "-- FIXME: colons" })
      for _, how in ipairs({ "git", "rg" }) do
        if vim.fn.executable(how) == 1 and (how ~= "git" or has_git) then
          setup({ todo_scanner = how })
          local rels = {}
          for _, t in ipairs(require("org.extensions.code.todos").scan(repo)) do
            rels[#rels + 1] = t.rel .. ":" .. t.lnum
            ok(vim.uv.fs_stat(t.file), how .. ": " .. t.file)
          end
          ok(vim.tbl_contains(rels, "docs/ünï côde.lua:1"), how .. ": " .. vim.inspect(rels))
          ok(vim.tbl_contains(rels, "a:1:b.lua:1"), how .. ": " .. vim.inspect(rels))
        end
      end
    end)

    it("scans in the background and redraws the agenda when done", function()
      local todos = require("org.extensions.code.todos")
      local done
      local real = todos.scan_async
      stub(todos, "scan_async", function(root, cb)
        real(root, function(list, truncated)
          done = true
          cb(list, truncated)
        end)
      end)
      require("org.agenda").open({ type = "code_todos", root = repo, title = "Mine" })
      if not done then
        -- the view was drawn without waiting for the scan
        ok(table.concat(buf_lines(0), "\n"):find("Mine  (scanning...)", 1, true))
      end
      agenda_text("Mine  (3)")
      ok(agenda_text("handle errors"))
      -- drawn again later: the old list at once, then scanned again
      write("new.lua", { "-- BUG: new one" })
      todos.cache[repo].time = 0
      require("org.agenda.view").redo()
      agenda_text("Mine  (4)")
    end)

    it("stops at todo_max_items", function()
      for _, how in ipairs({ "lua", has_git and "git" or "lua" }) do
        setup({ todo_scanner = how, todo_max_items = 2 })
        local list, truncated = require("org.extensions.code.todos").scan(repo)
        eq(2, #list)
        eq(true, truncated)
        require("org.extensions.code.todos").cache = {}
        require("org.agenda").open({ type = "code_todos", root = repo, title = "Mine" })
        agenda_text("Mine  (2+)")
      end
    end)

    it("says that agenda commands on org entries don't apply to a code TODO", function()
      local msgs = {}
      stub(utils, "warn", function(m)
        msgs[#msgs + 1] = m
      end)
      stub(utils, "error", function(m)
        msgs[#msgs + 1] = "error: " .. m
      end)
      require("org.agenda").open({ type = "code_todos", root = repo, title = "Mine" })
      agenda_text("Mine  (3)")
      for i, l in ipairs(buf_lines(0)) do
        if l:find("handle errors", 1, true) then
          vim.api.nvim_win_set_cursor(0, { i, 0 })
        end
      end
      for _, name in ipairs({ "todo", "schedule", "priority_up", "set_tags", "clock_in", "archive", "refile" }) do
        msgs = {}
        require("org.agenda.view").run_action(name)
        eq(1, #msgs, name)
        ok(msgs[1]:find("TODO comment in code", 1, true), msgs[1])
      end
      eq(APP, read(repo .. "/src/app.lua"), "the code is left alone")
    end)
  end)

  describe("branch clocking", function()
    local function org_file()
      return write(".org/tasks.org", {
        "* Tasks",
        "** TODO Login page",
        ":PROPERTIES:",
        ":BRANCH: feature/login",
        ":END:",
        "** TODO Fix crash",
        ":PROPERTIES:",
        ":TICKET: BUG-42",
        ":END:",
      })
    end

    local function switch(branch)
      vim.fn.writefile({ "ref: refs/heads/" .. branch }, repo .. "/.git/HEAD")
    end

    it("clocks into the heading of a branch when it changes", function()
      org_file()
      setup({ branch_clock = true })
      local branch = require("org.extensions.code.branch")
      local clock = require("org.clock")
      local buf = vim.fn.bufadd(repo .. "/tools/greet.py")
      vim.fn.bufload(buf)
      branch.check(buf)
      eq(nil, clock.state, "no clock for the branch found at start")
      switch("feature/login")
      branch.check(buf)
      eq("Login page", clock.state and clock.state.title)
      switch("fix/BUG-42-crash")
      branch.check(buf)
      eq("Fix crash", clock.state and clock.state.title)
      switch("nothing")
      branch.check(buf)
      eq("Fix crash", clock.state and clock.state.title)
    end)

    it("clocks in on start with branch_clock_on_start", function()
      org_file()
      switch("feature/login")
      setup({ branch_clock = true, branch_clock_on_start = true })
      local buf = vim.fn.bufadd(repo .. "/tools/greet.py")
      vim.fn.bufload(buf)
      require("org.extensions.code.branch").check(buf)
      eq("Login page", require("org.clock").state.title)
    end)

    it("matches a ticket in a title as a whole word", function()
      write(".org/tasks.org", { "* TODO Crash on save BUG-42" })
      setup({ branch_clock = true })
      local branch = require("org.extensions.code.branch")
      eq(nil, branch.find_heading("fix/BUG-4", repo))
      eq("Crash on save BUG-42", branch.find_heading("fix/BUG-42-save", repo).title)
    end)

    it("never raises from the BufEnter check, and warns once", function()
      org_file()
      local msgs = {}
      stub(utils, "warn", function(m)
        msgs[#msgs + 1] = m
      end)
      setup({
        branch_clock = true,
        project_file = function()
          error("boom")
        end,
      })
      local branch = require("org.extensions.code.branch")
      local buf = vim.fn.bufadd(repo .. "/tools/greet.py")
      vim.fn.bufload(buf)
      branch.check(buf)
      for _, b in ipairs({ "feature/login", "fix/BUG-42-crash", "feature/login" }) do
        switch(b)
        eq(true, (pcall(branch.check, buf)))
      end
      eq(1, #msgs, vim.inspect(msgs))
      ok(msgs[1]:find("boom", 1, true), msgs[1])
    end)

    it("links the current branch to the heading at point", function()
      switch("feature/signup")
      vim.cmd("edit " .. org_file())
      vim.api.nvim_win_set_cursor(0, { 6, 0 })
      require("org.actions").run("code_link_branch")
      eq(":BRANCH:   feature/signup", buf_lines(0)[9])
    end)
  end)
end)

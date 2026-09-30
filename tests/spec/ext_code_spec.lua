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
      eq("hello", symbols.at(buf, 8, 5))
      eq("Greeter", symbols.at(buf, 7, 0))
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
      local text = table.concat(buf_lines(0), "\n")
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
      local text = table.concat(buf_lines(0), "\n")
      ok(text:find("Mine  (3)", 1, true), text)
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

    it("links the current branch to the heading at point", function()
      switch("feature/signup")
      vim.cmd("edit " .. org_file())
      vim.api.nvim_win_set_cursor(0, { 6, 0 })
      require("org.actions").run("code_link_branch")
      eq(":BRANCH:   feature/signup", buf_lines(0)[9])
    end)
  end)
end)

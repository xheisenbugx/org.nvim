local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local utils = require("org.utils")

local dir
local saved = {}

-- the parsers bundled with Neovim, which the minimal runtimepath leaves
-- out: Lua's ftplugin starts treesitter on 0.12+
local parser_dir = vim.fs.normalize(vim.env.VIMRUNTIME .. "/../../../lib/nvim")
local saved_rtp

local function stub(mod, name, fn)
  saved[#saved + 1] = { mod, name, mod[name] }
  mod[name] = fn
end

-- files of the temp dir are detected (allow) without asking (confirm)
local function setup(lit, extra)
  require("org").setup(vim.tbl_extend("force", {
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
    extensions = {
      literate = vim.tbl_extend("force", { files = {}, notify = false, allow = { dir }, confirm = false }, lit or {}),
    },
  }, extra or {}))
end

local INIT = {
  "#+title: My config",
  "#+PROPERTY: header-args:lua :tangle init_org.lua",
  "",
  "* Options",
  "#+begin_src lua",
  "vim.g.lit_a = (vim.g.lit_a or 0) + 1",
  "#+end_src",
  "* Keys",
  "#+begin_src lua",
  "vim.g.lit_b = 1",
  "#+end_src",
  "* Not tangled",
  "#+begin_src lua :tangle no",
  "vim.g.lit_c = 1",
  "#+end_src",
}

local function write_init(lines)
  local path = dir .. "/init.org"
  vim.fn.writefile(lines or INIT, path)
  return path
end

-- edit the org file and replace line `lnum` (then write)
local function change(lnum, text)
  vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { text })
  vim.cmd("silent write")
end

local function diags(buf)
  return vim.tbl_map(function(d)
    return { d.lnum + 1, d.message }
  end, vim.diagnostic.get(buf or 0, { namespace = require("org.extensions.literate").ns }))
end

describe("literate extension", function()
  before_each(function()
    saved_rtp = vim.o.runtimepath
    if vim.uv.fs_stat(parser_dir .. "/parser") then
      vim.opt.runtimepath:append(parser_dir)
    end
    dir = vim.fn.tempname() .. "/nvim"
    vim.fn.mkdir(dir, "p")
    dir = vim.uv.fs_realpath(dir)
    vim.g.lit_a, vim.g.lit_b, vim.g.lit_c = nil, nil, nil
    stub(utils, "notify", function() end)
    setup()
  end)

  after_each(function()
    for i = #saved, 1, -1 do
      local s = saved[i]
      s[1][s[2]] = s[3]
    end
    saved = {}
    vim.o.runtimepath = saved_rtp
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(vim.fs.dirname(dir), "rf")
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = { root .. "/tests/fixtures/*.org" },
    })
  end)

  it("is off unless enabled", function()
    require("org").setup({ org_directory = root .. "/tests/fixtures" })
    eq({}, vim.api.nvim_get_autocmds({ group = "org.literate" }))
    eq(nil, require("org.actions").list.literate_reload)
    vim.cmd("edit " .. write_init())
    vim.cmd("silent write")
    eq(nil, vim.uv.fs_stat(dir .. "/init_org.lua"), "no tangle on save")
    eq(nil, vim.g.lit_a)
  end)

  it("knows literate files: configured ones and header-args:lua :tangle", function()
    local lit = require("org.extensions.literate")
    vim.cmd("edit " .. write_init())
    ok(lit.is_literate(0))
    local other = dir .. "/plain.org"
    vim.fn.writefile({ "* A", "#+begin_src lua", "x = 1", "#+end_src" }, other)
    vim.cmd("edit " .. other)
    eq(false, lit.is_literate(0))
    setup({ files = { dir .. "/plain.org" } })
    ok(lit.is_literate(0))
    setup({ files = { dir .. "/*.org" }, detect = false })
    ok(lit.is_literate(0))
    setup({ detect = false })
    vim.cmd("edit " .. dir .. "/init.org")
    eq(false, lit.is_literate(0))
  end)

  describe("trust", function()
    before_each(function()
      vim.fn.delete(require("org.extensions.literate").trust_file())
    end)

    it("leaves detected files outside `allow` alone", function()
      setup({ allow = { dir .. "/elsewhere" } })
      vim.cmd("edit " .. write_init())
      eq(false, require("org.extensions.literate").is_literate(0))
      change(10, "vim.g.lit_b = 2")
      eq(nil, vim.uv.fs_stat(dir .. "/init_org.lua"), "not tangled")
      eq(nil, vim.g.lit_b, "not run")
      -- a file listed in `files` needs no `allow`
      setup({ allow = {}, files = { dir .. "/init.org" } })
      change(10, "vim.g.lit_b = 3")
      eq(3, vim.g.lit_b)
    end)

    it("asks once before tangling and running a detected file", function()
      local asked = 0
      local answer = false
      stub(utils, "confirm", function()
        asked = asked + 1
        return answer
      end)
      setup({ confirm = true })
      vim.cmd("edit " .. write_init())
      change(10, "vim.g.lit_b = 2")
      eq(1, asked)
      eq(nil, vim.g.lit_b)
      eq(nil, vim.uv.fs_stat(dir .. "/init_org.lua"))
      change(10, "vim.g.lit_b = 3")
      eq(1, asked, "the answer is remembered")
      eq(nil, vim.g.lit_b)
      -- remembered across sessions (setup again reads the file)
      setup({ confirm = true })
      change(10, "vim.g.lit_b = 4")
      eq(1, asked)
      eq(nil, vim.g.lit_b)
      -- yes for another file
      vim.fn.delete(require("org.extensions.literate").trust_file())
      setup({ confirm = true })
      answer = true
      change(10, "vim.g.lit_b = 5")
      eq(2, asked)
      eq(5, vim.g.lit_b)
      change(10, "vim.g.lit_b = 6")
      eq(2, asked)
      eq(6, vim.g.lit_b)
    end)

    it("evaluates nothing when a file is opened", function()
      local marker = dir .. "/evaluated"
      stub(utils, "confirm", function()
        return true
      end)
      setup({}, { babel = { confirm_evaluate = false } })
      vim.cmd("edit " .. write_init({
        "#+PROPERTY: header-args:lua :tangle init_org.lua",
        "#+name: side",
        "#+begin_src lua :tangle no",
        "vim.fn.writefile({}, " .. string.format("%q", marker) .. ")",
        "return 1",
        "#+end_src",
        "#+begin_src lua :var x=side()",
        "vim.g.lit_a = x",
        "#+end_src",
      }))
      eq(nil, vim.uv.fs_stat(marker))
      eq(nil, vim.g.lit_a)
    end)
  end)

  it("goes back only to trusted org files, reading nothing else", function()
    local other = vim.fs.dirname(dir) .. "/downloads"
    vim.fn.mkdir(other, "p")
    local marker = other .. "/evaluated"
    setup({}, { babel = { confirm_evaluate = false } })
    vim.fn.writefile({
      "#+PROPERTY: header-args:lua :tangle x.lua",
      "#+name: side",
      "#+begin_src lua :tangle no",
      "vim.fn.writefile({}, " .. string.format("%q", marker) .. ")",
      "return 1",
      "#+end_src",
      "#+begin_src lua :var v=side()",
      "vim.g.lit_a = v",
      "#+end_src",
    }, other .. "/x.org")
    vim.fn.writefile({ "vim.g.lit_a = v" }, other .. "/x.lua")
    local msgs = {}
    stub(utils, "warn", function(m)
      msgs[#msgs + 1] = m
    end)
    vim.cmd("edit " .. other .. "/x.lua")
    eq(nil, require("org.extensions.literate").goto_org())
    eq(nil, vim.uv.fs_stat(marker))
    ok(msgs[1] and msgs[1]:find("No org block", 1, true), vim.inspect(msgs))
  end)

  it("reruns a block when a block it includes with noweb changes", function()
    vim.cmd("edit " .. write_init({
      "#+PROPERTY: header-args:lua :tangle init_org.lua :noweb yes",
      "#+name: value",
      "#+begin_src lua :tangle no",
      "1",
      "#+end_src",
      "#+begin_src lua",
      "vim.g.lit_a = <<value>>",
      "#+end_src",
    }))
    change(4, "2")
    eq(2, vim.g.lit_a)
    change(4, "3")
    eq(3, vim.g.lit_a)
  end)

  it("reports a failing tangle once, without raising from the autocmd", function()
    local msgs = {}
    stub(utils, "warn", function(m)
      msgs[#msgs + 1] = m
    end)
    stub(require("org.babel.tangle"), "tangle", function()
      error("disk full")
    end)
    vim.cmd("edit " .. write_init())
    eq(true, (pcall(change, 10, "vim.g.lit_b = 2")))
    eq(1, #msgs)
    ok(msgs[1]:find("disk full", 1, true), msgs[1])
  end)

  it("tangles on save and runs only the changed blocks", function()
    vim.cmd("edit " .. write_init())
    eq(nil, vim.g.lit_a, "nothing runs when the file is opened")
    change(10, "vim.g.lit_b = 2")
    eq({ "vim.g.lit_a = (vim.g.lit_a or 0) + 1", "", "vim.g.lit_b = 2" }, vim.fn.readfile(dir .. "/init_org.lua"))
    eq(nil, vim.g.lit_a, "an unchanged block does not run")
    eq(2, vim.g.lit_b)
    eq(nil, vim.g.lit_c, "a block that does not tangle does not run")
    change(6, "vim.g.lit_a = 10")
    eq(10, vim.g.lit_a)
    eq({}, diags())
  end)

  it("changes a keymap live", function()
    vim.cmd("edit " .. write_init())
    change(10, 'vim.keymap.set("n", "<F9>", "<Cmd>let g:lit_key = 1<CR>")')
    eq("<Cmd>let g:lit_key = 1<CR>", vim.fn.maparg("<F9>", "n"))
    change(10, 'vim.keymap.set("n", "<F9>", "<Cmd>let g:lit_key = 2<CR>")')
    eq("<Cmd>let g:lit_key = 2<CR>", vim.fn.maparg("<F9>", "n"))
    pcall(vim.keymap.del, "n", "<F9>")
  end)

  it("shows errors as diagnostics on the org line and runs a failed block again", function()
    setup({ quickfix = true })
    vim.cmd("edit " .. write_init())
    vim.api.nvim_buf_set_lines(0, 9, 10, false, { "vim.g.lit_b = 3", "error('boom')" })
    vim.cmd("silent write")
    local d = diags()
    eq(1, #d)
    eq(11, d[1][1])
    ok(d[1][2]:find("boom", 1, true), d[1][2])
    eq(3, vim.g.lit_b)
    eq(11, vim.fn.getqflist()[1].lnum)
    -- a syntax error
    change(6, "vim.g.lit_a = = 1")
    d = diags()
    eq(2, #d)
    eq(6, d[1][1])
    ok(d[1][2]:find("unexpected symbol", 1, true) or d[1][2]:find("'='", 1, true), d[1][2])
    -- the first fixed: its diagnostic goes, and the unchanged block that
    -- failed runs (and fails) again
    vim.g.lit_b = nil
    change(6, "vim.g.lit_a = 5")
    eq(5, vim.g.lit_a)
    eq(3, vim.g.lit_b)
    eq({ 11 }, vim.tbl_map(function(x)
      return x[1]
    end, diags()))
    change(11, "vim.g.lit_b = 4")
    eq({}, diags())
    eq(4, vim.g.lit_b)
  end)

  it("puts an error raised in a called function on the block's line that called it", function()
    vim.cmd("edit " .. write_init())
    vim.api.nvim_buf_set_lines(0, 9, 10, false, { "vim.g.lit_b = 1", "vim.o.no_such_option_xyz = true" })
    vim.cmd("silent write")
    local d = diags()
    eq(11, d[1][1])
    ok(d[1][2]:find("no_such_option_xyz", 1, true), d[1][2])
    ok(not d[1][2]:find("[string", 1, true), d[1][2])
  end)

  it("says what it tangled and ran after the write", function()
    local msgs = {}
    stub(utils, "notify", function(m)
      msgs[#msgs + 1] = m
    end)
    setup({ notify = true })
    vim.cmd("edit " .. write_init())
    change(10, "error('x')")
    vim.wait(500, function()
      return #msgs > 0
    end)
    eq({ "Tangled init_org.lua; reloaded 1 changed Lua block, 1 error (line 10)" }, msgs)
  end)

  it("does not reload with reload = false", function()
    setup({ reload = false })
    vim.cmd("edit " .. write_init())
    change(10, "vim.g.lit_b = 9")
    eq(nil, vim.g.lit_b)
    ok(vim.uv.fs_stat(dir .. "/init_org.lua"))
  end)

  it("reloads the block at point, or every tangled block", function()
    vim.cmd("edit " .. write_init())
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    require("org.actions").run("literate_reload")
    eq(1, vim.g.lit_a)
    eq(nil, vim.g.lit_b)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    require("org.actions").run("literate_reload")
    eq(2, vim.g.lit_a)
    eq(1, vim.g.lit_b)
    eq(nil, vim.g.lit_c)
  end)

  it("runs the Lua block at point and shows its value", function()
    local msgs = {}
    stub(utils, "notify", function(m)
      msgs[#msgs + 1] = m
    end)
    local lines = { "* A", "#+begin_src lua", "return 1 + 2", "#+end_src", "#+begin_src lua", "x(", "#+end_src" }
    vim.cmd("edit " .. write_init(lines))
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local okr, v = require("org.extensions.literate").run_block()
    eq({ true, 3 }, { okr, v })
    eq("=> 3", msgs[#msgs])
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    okr = require("org.extensions.literate").run_block()
    eq(false, okr)
    eq(6, diags()[1][1])
  end)

  it("checks that every Lua block compiles", function()
    vim.cmd("edit " .. write_init({
      "* A",
      "#+begin_src lua",
      "local x = 1",
      "#+end_src",
      "#+begin_src lua :tangle no",
      "local y =",
      "#+end_src",
      "#+begin_src python",
      "not lua(",
      "#+end_src",
    }))
    local errors = require("org.extensions.literate").health_check()
    eq(1, #errors)
    eq(6, diags()[1][1])
  end)

  it("writes a bootstrap init.lua that tangles a newer org file", function()
    local lines = vim.deepcopy(INIT)
    lines[2] = "#+PROPERTY: header-args:lua :tangle lua/config.lua :mkdirp yes"
    vim.cmd("edit " .. write_init(lines))
    local path = require("org.extensions.literate").bootstrap()
    eq(dir .. "/init.lua", path)
    local text = table.concat(vim.fn.readfile(path), "\n")
    ok(text:find(dir .. "/lua/config.lua", 1, true), text)
    -- no tangled file yet: the stub tangles and loads it
    eq(nil, vim.uv.fs_stat(dir .. "/lua/config.lua"))
    dofile(path)
    eq(1, vim.g.lit_a)
    eq(1, vim.g.lit_b)
    eq(nil, vim.g.lit_c, ":tangle no blocks are left out")
    -- up to date: loaded as is
    vim.fn.writefile({ "vim.g.lit_a = 42" }, dir .. "/lua/config.lua")
    dofile(path)
    eq(42, vim.g.lit_a)
    -- asks before overwriting
    stub(utils, "confirm", function()
      return false
    end)
    eq(nil, require("org.extensions.literate").bootstrap())
  end)

  it("bootstraps with the blocks the full tangle writes (headings' properties, other targets, noweb)", function()
    local lines = {
      "#+PROPERTY: header-args:lua :tangle lua/config.lua :mkdirp yes",
      "#+PROPERTY: header-args :noweb yes",
      "* Options",
      "#+begin_src lua",
      "vim.g.lit_a = 1",
      "#+end_src",
      "* Drafts",
      ":PROPERTIES:",
      ":header-args:lua: :tangle no",
      ":END:",
      "#+begin_src lua",
      "vim.g.lit_c = 'draft'",
      "#+end_src",
      "** But this one",
      "#+begin_src lua :tangle lua/config.lua",
      "vim.g.lit_d = 1",
      "#+end_src",
      "* Other file",
      "#+begin_src lua :tangle lua/other.lua",
      "vim.g.lit_c = 'other'",
      "#+end_src",
      "* Shared",
      "#+name: greeting",
      "#+begin_src lua :tangle no",
      "'hi'",
      "#+end_src",
      "#+begin_src lua",
      "vim.g.lit_b = <<greeting>>",
      "#+end_src",
      "#+begin_src luap",
      "not lua",
      "#+end_src",
      "* Escaped",
      "#+begin_src lua",
      "local s = [[",
      ",* not a heading",
      "]]",
      "vim.g.lit_e = s",
      "#+end_src",
    }
    vim.cmd("edit " .. write_init(lines))
    local path = require("org.extensions.literate").bootstrap()
    vim.cmd("silent write")
    local full = vim.fn.readfile(dir .. "/lua/config.lua")
    vim.fn.delete(dir .. "/lua/config.lua")
    vim.g.lit_a, vim.g.lit_b, vim.g.lit_c, vim.g.lit_d, vim.g.lit_e = nil, nil, nil, nil, nil
    dofile(path)
    eq(full, vim.fn.readfile(dir .. "/lua/config.lua"))
    eq({ 1, "hi", nil, 1, "* not a heading\n" }, { vim.g.lit_a, vim.g.lit_b, vim.g.lit_c, vim.g.lit_d, vim.g.lit_e })
  end)

  it("keeps loading the tangled file when the startup tangle fails", function()
    local lines = vim.deepcopy(INIT)
    lines[2] = "#+PROPERTY: header-args:lua :tangle lua/config.lua :mkdirp yes"
    vim.cmd("edit " .. write_init(lines))
    vim.cmd("silent write")
    local path = require("org.extensions.literate").bootstrap()
    -- the org file can't be read: the old tangled file still loads
    vim.fn.writefile({ "vim.g.lit_a = 'old'" }, dir .. "/lua/config.lua")
    vim.uv.fs_utime(dir .. "/init.org", os.time() + 5, os.time() + 5)
    local notified
    stub(vim, "notify", function(m)
      notified = m
    end)
    local io_lines = io.lines
    stub(io, "lines", function()
      error("unreadable")
    end)
    local ok_run = pcall(dofile, path)
    io.lines = io_lines
    ok(ok_run)
    eq("old", vim.g.lit_a)
    ok(notified and notified:find("unreadable", 1, true), notified)
  end)

  it("refuses to bootstrap when the blocks tangle to init.lua itself", function()
    local lines = vim.deepcopy(INIT)
    lines[2] = "#+PROPERTY: header-args:lua :tangle init.lua"
    vim.cmd("edit " .. write_init(lines))
    eq(nil, require("org.extensions.literate").bootstrap())
    eq(nil, vim.uv.fs_stat(dir .. "/init.lua"))
  end)

  it("jumps from a tangled line back to its org block", function()
    vim.cmd("edit " .. write_init())
    vim.cmd("silent write")
    vim.cmd("edit " .. dir .. "/init_org.lua")
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    require("org.actions").run("literate_goto_org")
    eq(dir .. "/init.org", vim.api.nvim_buf_get_name(0))
    eq(10, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("jumps back by link comments with :comments link", function()
    local lines = vim.deepcopy(INIT)
    lines[2] = "#+PROPERTY: header-args:lua :tangle init_org.lua :comments link"
    vim.cmd("edit " .. write_init(lines))
    vim.cmd("silent write")
    vim.cmd("edit " .. dir .. "/init_org.lua")
    local tangled = buf_lines(0)
    local at
    for i, l in ipairs(tangled) do
      if l == "vim.g.lit_b = 1" then
        at = i
      end
    end
    vim.api.nvim_win_set_cursor(0, { at, 0 })
    require("org.actions").run("literate_goto_org")
    eq(dir .. "/init.org", vim.api.nvim_buf_get_name(0))
    eq(10, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("jumps back to the block a noweb reference brought the line from", function()
    vim.cmd("edit " .. write_init({
      "#+PROPERTY: header-args:lua :tangle init_org.lua :noweb yes",
      "#+name: helper",
      "#+begin_src lua :tangle no",
      "vim.g.lit_helper = 1",
      "#+end_src",
      "#+begin_src lua",
      "<<helper>>",
      "vim.g.lit_a = 1",
      "#+end_src",
    }))
    vim.cmd("silent write")
    vim.cmd("edit " .. dir .. "/init_org.lua")
    eq("vim.g.lit_helper = 1", buf_lines(0)[1])
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    require("org.actions").run("literate_goto_org")
    eq(dir .. "/init.org", vim.api.nvim_buf_get_name(0))
    eq(4, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("completes the path of :Org literate_bootstrap", function()
    local commands = require("org.commands")
    write_init()
    local found = commands.complete(dir .. "/ini", "Org literate_bootstrap " .. dir .. "/ini")
    ok(vim.tbl_contains(found, dir .. "/init.org"), vim.inspect(found))
    local all = commands.complete("", "Org literate_bootstrap ")
    ok(all[1]:find("init.lua$"), vim.inspect(all))
  end)

  it("reports in :checkhealth", function()
    local out = {}
    local h = {}
    for _, k in ipairs({ "start", "ok", "info", "warn", "error" }) do
      h[k] = function(msg)
        out[#out + 1] = k .. ": " .. msg
      end
    end
    setup({ files = { write_init() } })
    require("org.extensions").check(h)
    ok(vim.tbl_contains(out, "ok: enabled: literate"), vim.inspect(out))
    ok(table.concat(out, "\n"):find("literate file: ", 1, true), vim.inspect(out))
  end)

  it("removes the diagnostics of any buffer when turned off", function()
    local plain = vim.fs.dirname(dir) .. "/plain.org"
    vim.fn.writefile({ "* A", "#+begin_src lua", "error('x')", "#+end_src" }, plain)
    vim.cmd("edit " .. plain)
    eq(false, require("org.extensions.literate").is_literate(0))
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    require("org.extensions.literate").run_block()
    eq({ { 3, "x" } }, diags(), "the message without the chunk's name")
    require("org").setup({ org_directory = root .. "/tests/fixtures" })
    eq({}, diags())
  end)

  it("removes its autocmds and diagnostics when turned off", function()
    vim.cmd("edit " .. write_init())
    change(6, "error('x')")
    eq(1, #diags())
    require("org").setup({ org_directory = root .. "/tests/fixtures" })
    eq({}, vim.api.nvim_get_autocmds({ group = "org.literate" }))
    eq({}, diags())
  end)
end)

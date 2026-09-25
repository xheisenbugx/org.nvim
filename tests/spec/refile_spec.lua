local refile = require("org.refile")
local config = require("org.config")
local utils = require("org.utils")
vim.g.org_test = true
local root = vim.fn.getcwd()

local function setup_files(a, b)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  utils.writefile(dir .. "/a.org", a)
  utils.writefile(dir .. "/b.org", b)
  config.setup({ org_directory = dir, agenda_files = { dir } })
  return dir
end

local function lines_of(path)
  local b = utils.find_buffer(path)
  return b and vim.api.nvim_buf_get_lines(b, 0, -1, false) or utils.readfile(path)
end

describe("refile", function()
  -- written for this setup rather than the Emacs defaults
  with_config({ todo_keywords = { "TODO(t) NEXT(n) | DONE(d)" }, log_done = "time", log_into_drawer = "LOGBOOK" })
  it("lists targets with outline paths", function()
    local dir = setup_files({ "* A1", "** A2", "*** A3", "**** A4" }, { "* B1" })
    vim.cmd("edit! " .. dir .. "/a.org")
    local labels = vim.tbl_map(function(t)
      return t.label
    end, refile.targets())
    ok(vim.tbl_contains(labels, "a.org/A1/A2/A3"))
    ok(not vim.tbl_contains(labels, "a.org/A1/A2/A3/A4"))
    ok(vim.tbl_contains(labels, "b.org/"))
    ok(vim.tbl_contains(labels, "b.org/B1"))
  end)

  it("moves within the same buffer (down and up)", function()
    local dir = setup_files({ "* One", "body", "* Two", "** Child", "* Three" }, { "* B" })
    vim.cmd("edit! " .. dir .. "/a.org")
    local buf = vim.api.nvim_get_current_buf()
    refile.move({ bufnr = buf, lnum = 1 }, { bufnr = buf, lnum = 3 })
    eq({ "* Two", "** Child", "** One", "body", "* Three" }, buf_lines(buf))
    refile.move({ bufnr = buf, lnum = 5 }, { bufnr = buf, lnum = 1 })
    eq({ "* Two", "** Child", "** One", "body", "** Three" }, buf_lines(buf))
    refile.move({ bufnr = buf, lnum = 3 }, { bufnr = buf, lnum = nil })
    eq({ "* Two", "** Child", "** Three", "* One", "body" }, buf_lines(buf))
    local okk = pcall(refile.move, { bufnr = buf, lnum = 1 }, { bufnr = buf, lnum = 2 })
    eq(false, okk)
  end)

  it("refiles to another file and saves it", function()
    local dir = setup_files({ "* Move me", "text", "* Stay" }, { "* Target", "** Existing" })
    vim.cmd("edit! " .. dir .. "/a.org")
    local targets = refile.targets()
    local dest
    for _, t in ipairs(targets) do
      if t.label == "b.org/Target" then
        dest = t
      end
    end
    refile.refile({ lnum = 1 }, { dest = dest })
    eq({ "* Stay" }, buf_lines())
    eq({ "* Target", "** Existing", "** Move me", "text" }, utils.readfile(dir .. "/b.org"))
  end)

  local function target(label)
    for _, t in ipairs(refile.targets()) do
      if t.label == label then
        return t
      end
    end
    error("no target " .. label)
  end

  it("copies a subtree, logs and honours reverse note order", function()
    local dir = setup_files({ "* Copy me", "text" }, { "* Target", "** Existing" })
    config.opts.refile.reverse_note_order = true
    config.opts.refile.log = "time"
    config.opts.log_into_drawer = "LOGBOOK"
    vim.cmd("edit! " .. dir .. "/a.org")
    refile.refile_copy({ lnum = 1 }, { dest = target("b.org/Target") })
    eq({ "* Copy me", "text" }, buf_lines())
    local b = lines_of(dir .. "/b.org")
    eq("* Target", b[1])
    eq("** Copy me", b[2])
    ok(b[3]:match("^:LOGBOOK:"), b[3])
    ok(b[4]:match("^%- Refiled on %[%d%d%d%d%-%d%d%-%d%d %a+ %d%d:%d%d%]$"), b[4])
    eq("** Existing", b[#b])
    -- goto last stored jumps to the copy
    vim.cmd("enew!")
    refile.goto_last_stored()
    eq("** Copy me", vim.api.nvim_get_current_line())
    config.setup({})
  end)

  it("uses refile.targets specs and the verify function", function()
    local dir = setup_files({ "* A :proj:", "** A2 :proj:", "* B", "** TODO B2" }, { "* C :proj:" })
    config.opts.refile.targets = {
      { files = "agenda", tag = "proj", max_level = 1 },
      { files = "current", todo = "TODO" },
    }
    vim.cmd("edit! " .. dir .. "/a.org")
    local labels = vim.tbl_map(function(t)
      return t.label
    end, refile.targets())
    ok(vim.tbl_contains(labels, "a.org/A"))
    ok(vim.tbl_contains(labels, "b.org/C"))
    ok(vim.tbl_contains(labels, "a.org/B/B2"))
    ok(not vim.tbl_contains(labels, "a.org/A/A2"))
    ok(not vim.tbl_contains(labels, "a.org/B"))
    config.opts.refile.verify = function(hl)
      return hl.todo == nil
    end
    labels = vim.tbl_map(function(t)
      return t.label
    end, refile.targets())
    ok(not vim.tbl_contains(labels, "a.org/B/B2"))
    config.setup({})
  end)

  it("creates parent nodes", function()
    local dir = setup_files({ "* X" }, { "* Top" })
    local t = { filename = dir .. "/b.org", lnum = 1, olp = { "Top" }, label = "b.org/Top" }
    local new = refile.create_nodes(t, { "New", "Deeper" })
    eq(3, new.lnum)
    eq({ "* Top", "** New", "*** Deeper" }, lines_of(dir .. "/b.org"))
  end)
end)

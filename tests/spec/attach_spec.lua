local attach = require("org.attach")
local config = require("org.config")
local utils = require("org.utils")
local links = require("org.links")
vim.g.org_test = true

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return vim.uv.fs_realpath(dir)
end

local function setup(dir, extra)
  config.setup(vim.tbl_deep_extend("force", {
    org_directory = dir,
    agenda_files = { dir .. "/*.org" },
    id = { locations_file = dir .. "/ids.json" },
    tags_column = 0,
  }, extra or {}))
  require("org.id")._reset()
end

local function file_buffer(dir, lines)
  local p = dir .. "/a.org"
  utils.writefile(p, lines)
  vim.cmd("edit! " .. p)
  return vim.api.nvim_get_current_buf()
end

describe("org-attach", function()
  after_each(function()
    config.setup({})
  end)

  it("attaches with cp, mv, ln (hard link) and lns (symbolic link)", function()
    local dir = tmpdir()
    setup(dir)
    local buf = file_buffer(dir, { "* Task", ":PROPERTIES:", ":ID: abcdef", ":END:" })
    local t = { bufnr = buf, lnum = 1 }
    for _, name in ipairs({ "c.txt", "m.txt", "l.txt", "s.txt" }) do
      utils.writefile(dir .. "/" .. name, { name })
    end
    local c = attach.attach_file(dir .. "/c.txt", "cp", t)
    eq(dir .. "/data/ab/cdef/c.txt", c)
    eq({ "c.txt" }, utils.readfile(c))
    ok(utils.exists(dir .. "/c.txt"))
    local m = attach.attach_file(dir .. "/m.txt", "mv", t)
    eq({ "m.txt" }, utils.readfile(m))
    eq(false, utils.exists(dir .. "/m.txt"))
    local l = attach.attach_file(dir .. "/l.txt", "ln", t)
    eq("file", vim.uv.fs_lstat(l).type)
    eq(vim.uv.fs_stat(dir .. "/l.txt").ino, vim.uv.fs_stat(l).ino)
    local s = attach.attach_file(dir .. "/s.txt", "lns", t)
    eq("link", vim.uv.fs_lstat(s).type)
    eq(dir .. "/s.txt", vim.uv.fs_readlink(s))
    eq("* Task :ATTACH:", buf_lines(buf)[1])
    eq({ "c.txt", "l.txt", "m.txt", "s.txt" }, attach.list(t))
  end)

  it("copies a directory", function()
    local dir = tmpdir()
    setup(dir)
    local buf = file_buffer(dir, { "* Task", ":PROPERTIES:", ":ID: abcdef", ":END:" })
    vim.fn.mkdir(dir .. "/folder/sub", "p")
    utils.writefile(dir .. "/folder/sub/x.txt", { "x" })
    local dest = attach.attach_file(dir .. "/folder", "cp", { bufnr = buf, lnum = 1 })
    eq({ "x" }, utils.readfile(dest .. "/sub/x.txt"))
  end)

  it("stores the link org-attach-store-link-p asks for", function()
    local dir = tmpdir()
    local buf
    for _, case in ipairs({
      { "attached", "attachment:f.txt" },
      { "file", "file:" .. dir .. "/data/ab/cdef/f.txt" },
      { true, "file:" .. dir .. "/f.txt" },
    }) do
      setup(dir, { attach = { store_link = case[1] } })
      buf = file_buffer(dir, { "* Task", ":PROPERTIES:", ":ID: abcdef", ":END:" })
      utils.writefile(dir .. "/f.txt", { "f" })
      links.stored = {}
      vim.fn.delete(dir .. "/data", "rf")
      attach.attach_file(dir .. "/f.txt", "cp", { bufnr = buf, lnum = 1 })
      eq(case[2], links.stored[1] and links.stored[1].link)
    end
    setup(dir, { attach = { store_link = false } })
    vim.fn.delete(dir .. "/data", "rf")
    links.stored = {}
    attach.attach_file(dir .. "/f.txt", "cp", { bufnr = buf, lnum = 1 })
    eq(nil, links.stored[1])
  end)

  it("inherits the directory only as org-attach-use-inheritance says", function()
    local dir = tmpdir()
    setup(dir)
    local buf = file_buffer(dir, { "* Parent", ":PROPERTIES:", ":ID: abcdef", ":END:", "** Child" })
    local child = { bufnr = buf, lnum = 5 }
    -- "selective" with use_property_inheritance = false: no inheritance
    eq(nil, (attach.dir_for(child)))
    config.opts.use_property_inheritance = { "ID" }
    eq(dir .. "/data/ab/cdef", (attach.dir_for(child)))
    config.opts.use_property_inheritance = false
    config.opts.attach.use_inheritance = true
    eq(dir .. "/data/ab/cdef", (attach.dir_for(child)))
    -- sync on the child: no directory of its own, so no tag
    config.opts.attach.use_inheritance = "selective"
    vim.fn.mkdir(dir .. "/data/ab/cdef", "p")
    utils.writefile(dir .. "/data/ab/cdef/p.txt", { "p" })
    vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "** Child :ATTACH:" })
    attach.sync(child)
    eq("** Child", buf_lines(buf)[5])
  end)

  it("uses DIR, the old ATTACH_DIR and relative DIR values", function()
    local dir = tmpdir()
    setup(dir)
    local buf = file_buffer(dir, { "* A", ":PROPERTIES:", ":DIR: stuff", ":END:", "* B", ":PROPERTIES:", ":ATTACH_DIR: /tmp/x", ":END:" })
    eq(dir .. "/stuff", (attach.dir_for({ bufnr = buf, lnum = 1 })))
    eq("/tmp/x", (attach.dir_for({ bufnr = buf, lnum = 5 })))
    setup(dir, { attach = { dir_relative = true } })
    local nb = file_buffer(dir, { "* C" })
    attach.set_directory({ bufnr = nb, lnum = 1 }, dir .. "/rel/here")
    eq(":DIR: rel/here", buf_lines(nb)[3])
    eq(dir .. "/rel/here", (attach.dir_for({ bufnr = nb, lnum = 1 })))
  end)

  it("maps IDs to folders with id_to_path, preferring existing ones", function()
    local dir = tmpdir()
    setup(dir)
    local buf = file_buffer(dir, { "* A", ":PROPERTIES:", ":ID: 20260925T120000.000000", ":END:", "* B", ":PROPERTIES:", ":ID: x", ":END:" })
    local a, b = { bufnr = buf, lnum = 1 }, { bufnr = buf, lnum = 5 }
    eq(dir .. "/data/20/260925T120000.000000", (attach.dir_for(a)))
    vim.fn.mkdir(dir .. "/data/202609/25T120000.000000", "p")
    eq(dir .. "/data/202609/25T120000.000000", (attach.dir_for(a)))
    eq(dir .. "/data/__/x/x", (attach.dir_for(b)))
    setup(dir, { attach = { dir = "att/" } })
    eq(dir .. "/att/__/x/x", (attach.dir_for(b)))
    vim.fn.mkdir(dir .. "/data/__/x/x", "p")
    eq(dir .. "/data/__/x/x", (attach.dir_for(b)))
    setup(dir, {
      attach = {
        id_to_path = {
          function(id)
            return "custom/" .. id
          end,
        },
      },
    })
    eq(dir .. "/data/custom/x", (attach.dir_for(b)))
  end)

  it("follows preferred_new_method for entries without a directory", function()
    local dir = tmpdir()
    setup(dir, { attach = { preferred_new_method = false } })
    local buf = file_buffer(dir, { "* A" })
    local orig = utils.error
    utils.error = function() end
    eq(nil, (attach.dir_for({ bufnr = buf, lnum = 1 }, true)))
    utils.error = orig
    eq({ "* A" }, buf_lines(buf))
    config.opts.attach.preferred_new_method = "dir"
    local oi = vim.fn.input
    vim.fn.input = function()
      return "chosen"
    end
    local d = attach.dir_for({ bufnr = buf, lnum = 1 }, true)
    vim.fn.input = oi
    eq(dir .. "/chosen", d)
    eq(":DIR: " .. dir .. "/chosen", buf_lines(buf)[3])
  end)

  it("syncs the tag, deletes empty directories and supports another auto tag", function()
    local dir = tmpdir()
    setup(dir, { attach = { sync_delete_empty_dir = true, auto_tag = "FILES" } })
    local buf = file_buffer(dir, { "* A", ":PROPERTIES:", ":ID: abcdef", ":END:" })
    local t = { bufnr = buf, lnum = 1 }
    vim.fn.mkdir(dir .. "/data/ab/cdef", "p")
    utils.writefile(dir .. "/data/ab/cdef/f.txt", { "f" })
    eq(true, attach.sync(t))
    eq("* A :FILES:", buf_lines(buf)[1])
    vim.fn.delete(dir .. "/data/ab/cdef/f.txt")
    eq(false, attach.sync(t))
    eq("* A", buf_lines(buf)[1])
    eq(false, utils.is_dir(dir .. "/data/ab/cdef"))
    utils.writefile(dir .. "/g.txt", { "g" })
    attach.attach_file(dir .. "/g.txt", "cp", t)
    ok(attach.delete_all(t, true))
    eq(false, utils.is_dir(dir .. "/data/ab/cdef"))
    eq("* A", buf_lines(buf)[1])
  end)
end)

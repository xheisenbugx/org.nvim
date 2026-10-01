-- org-attach-commands, org-attach-expert and org-attach-dired-to-subtree
-- (attach from netrw / oil).
local attach = require("org.attach")
local config = require("org.config")
local utils = require("org.utils")
local ui = require("org.ui")
vim.g.org_test = true

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return require("org.utils").realpath(dir)
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

describe("attach.commands (org-attach-commands)", function()
  after_each(function()
    config.setup({})
  end)

  it("adds, replaces and removes dispatcher commands", function()
    local called
    setup(tmpdir(), {
      attach = {
        commands = {
          x = {
            desc = "Custom",
            fn = function(target)
              called = target
            end,
          },
          D = false,
        },
      },
    })
    local keys = vim.tbl_map(function(c)
      return c[1]
    end, attach.commands())
    eq({ "a", "c", "m", "l", "y", "u", "b", "n", "z", "o", "O", "f", "F", "d", "s", "S", "x" }, keys)
    local buf = org_buffer({ "* Task", "body" }, { 2, 0 })
    local orig = ui.menu
    local labels
    ui.menu = function(opts)
      labels = opts.items
      return "x"
    end
    attach.menu()
    ui.menu = orig
    eq({ bufnr = buf, lnum = 1 }, called)
    eq("Custom", labels[#labels].label)
  end)

  it("asks at a prompt with attach.expert", function()
    local called
    setup(tmpdir(), {
      attach = {
        expert = true,
        commands = {
          x = {
            fn = function()
              called = true
            end,
          },
        },
      },
    })
    org_buffer({ "* Task" }, { 1, 0 })
    local orig_menu, orig_getchar = ui.menu, utils.getchar
    local prompt, menu_called
    ui.menu = function()
      menu_called = true
    end
    utils.getchar = function(p)
      prompt = p
      return "x"
    end
    attach.menu()
    ui.menu, utils.getchar = orig_menu, orig_getchar
    eq(nil, menu_called)
    eq(true, called)
    eq("Select command: [acmlyubnzoOfFdDsSxq]", prompt)
  end)
end)

describe("attach_from_file_manager (org-attach-dired-to-subtree)", function()
  after_each(function()
    package.loaded.oil = nil
    vim.cmd("silent! only!")
    config.setup({})
  end)

  local function org_window(dir)
    local p = dir .. "/a.org"
    utils.writefile(p, { "* Task", ":PROPERTIES:", ":ID: abcdef", ":END:", "* Other" })
    vim.cmd("silent! only!")
    vim.cmd("edit! " .. p)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local obuf = vim.api.nvim_get_current_buf()
    vim.cmd("vnew")
    return obuf
  end

  it("attaches netrw's marked files, else the file under the cursor", function()
    local dir = tmpdir()
    setup(dir)
    utils.writefile(dir .. "/one.txt", { "1" })
    utils.writefile(dir .. "/two.txt", { "2" })
    local obuf = org_window(dir)
    vim.bo.filetype = "netrw"
    vim.b.netrw_curdir = dir
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "../", "one.txt", "two.txt*" })
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local orig = vim.fn["netrw#Expose"]
    vim.fn["netrw#Expose"] = function()
      return {}
    end
    local done = attach.attach_from_file_manager()
    eq({ dir .. "/data/ab/cdef/two.txt" }, done)
    vim.fn["netrw#Expose"] = function()
      return { dir .. "/one.txt", dir .. "/two.txt" }
    end
    done = attach.attach_from_file_manager()
    vim.fn["netrw#Expose"] = orig
    eq({ dir .. "/data/ab/cdef/one.txt", dir .. "/data/ab/cdef/two.txt" }, done)
    ok(vim.api.nvim_buf_get_lines(obuf, 0, 1, false)[1]:match(":ATTACH:$"))
  end)

  it("attaches oil's entry under the cursor", function()
    local dir = tmpdir()
    setup(dir)
    utils.writefile(dir .. "/three.txt", { "3" })
    org_window(dir)
    vim.bo.filetype = "oil"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "three.txt" })
    package.loaded.oil = {
      get_current_dir = function()
        return dir .. "/"
      end,
      get_entry_on_line = function(_, l)
        return l == 1 and { name = "three.txt" } or nil
      end,
    }
    eq({ dir .. "/data/ab/cdef/three.txt" }, attach.attach_from_file_manager())
  end)

  it("needs a file manager buffer and an Org window", function()
    setup(tmpdir())
    vim.cmd("silent! only!")
    vim.cmd("enew")
    local orig = utils.error
    local msg
    utils.error = function(m)
      msg = m
    end
    attach.attach_from_file_manager()
    eq("This command must be triggered in a netrw or oil buffer", msg)
    attach.attach_from_file_manager({ "/tmp/x" })
    utils.error = orig
    eq("Can't attach to subtree.  No window displaying an Org buffer", msg)
  end)
end)

-- org-id-completion-targets (id: links completed by heading) and
-- org-id-include-domain.
local config = require("org.config")
local utils = require("org.utils")
local idm = require("org.id")
vim.g.org_test = true

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return require("org.utils").realpath(dir)
end

local function setup(dir, extra)
  config.setup(vim.tbl_deep_extend("force", {
    org_directory = dir,
    agenda_files = {},
    id = { locations_file = dir .. "/ids.json" },
    refile = { outline_path_complete_in_steps = false },
  }, extra or {}))
  idm._reset()
end

describe("id.completion_targets (org-id-completion-targets)", function()
  after_each(function()
    config.setup({})
    idm._reset()
  end)

  it("offers the headings of the buffer and of the ID files, creating the ID", function()
    local dir = tmpdir()
    setup(dir)
    utils.writefile(dir .. "/other.org", { "* Elsewhere", ":PROPERTIES:", ":ID: known-1", ":END:", "* Plain" })
    idm.register("known-1", dir .. "/other.org")
    local p = dir .. "/main.org"
    utils.writefile(p, { "* A", "** B", "* C" })
    vim.cmd("edit! " .. p)
    local buf = vim.api.nvim_get_current_buf()
    local labels
    local orig = utils.select
    utils.select = function(items, opts)
      labels = vim.tbl_map(opts.format_item, items)
      for _, it in ipairs(items) do
        if opts.format_item(it) == "A/B/" then
          return it
        end
      end
    end
    local link
    ok(utils.run(function()
      link = require("org.links").complete_id(buf)
    end))
    utils.select = orig
    eq({ "A/", "A/B/", "C/", "Elsewhere/ (other.org)", "Plain/ (other.org)" }, labels)
    local id = buf_lines(buf)[4]:match("^:ID:%s+(%S+)$")
    ok(id, vim.inspect(buf_lines(buf)))
    eq("id:" .. id, link)
    eq("** B", buf_lines(buf)[2])
  end)

  it("follows the configured targets and asks for the link without any", function()
    local dir = tmpdir()
    setup(dir, { id = { completion_targets = { { files = "current", level = 1 } } } })
    local buf = org_buffer({ "* Top", ":PROPERTIES:", ":ID: top-id", ":END:", "** Sub" })
    vim.api.nvim_buf_set_name(buf, dir .. "/x.org")
    local orig_select, orig_input = utils.select, utils.input
    local labels
    utils.select = function(items, opts)
      labels = vim.tbl_map(opts.format_item, items)
      return items[1]
    end
    local link
    utils.run(function()
      link = require("org.links").complete_id(buf)
    end)
    eq({ "Top/" }, labels)
    eq("id:top-id", link)
    -- a buffer without a file drops the "current" targets: nothing is left
    local nofile = org_buffer({ "* Top" })
    local prompt
    utils.input = function(opts)
      prompt = opts
      return "id:typed"
    end
    utils.run(function()
      link = require("org.links").complete_id(nofile)
    end)
    utils.select, utils.input = orig_select, orig_input
    eq("Link: ", prompt.prompt)
    eq("id:", prompt.default)
    eq("id:typed", link)
  end)
end)

describe("id.include_domain (org-id-include-domain)", function()
  after_each(function()
    config.setup({})
  end)

  it("adds @host to ts and org IDs, never to UUIDs", function()
    local dir = tmpdir()
    setup(dir, { id = { method = "ts", include_domain = true } })
    local fqdn = idm.fqdn()
    ok(fqdn:find(".", 1, true))
    local id = idm.new_id()
    eq("@" .. fqdn, id:sub(-#fqdn - 1))
    config.opts.id.method = "org"
    id = idm.new_id()
    eq("@" .. fqdn, id:sub(-#fqdn - 1))
    config.opts.id.method = "uuid"
    ok(not idm.new_id():find("@", 1, true))
    config.opts.id.include_domain = false
    config.opts.id.method = "ts"
    ok(not idm.new_id():find("@", 1, true))
  end)
end)

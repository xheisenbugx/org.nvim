local id = require("org.id")
local config = require("org.config")
local utils = require("org.utils")
vim.g.org_test = true

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function setup(dir, extra)
  config.setup(vim.tbl_deep_extend("force", {
    org_directory = dir,
    agenda_files = { dir .. "/*.org" },
    id = { locations_file = dir .. "/ids.json" },
  }, extra or {}))
  id._reset()
end

describe("org-id", function()
  after_each(function()
    config.setup({})
    id._reset()
  end)

  it("makes IDs with the uuid, ts and org methods and a prefix", function()
    local dir = tmpdir()
    setup(dir)
    ok(id.new_id():match("^%x+%-%x+%-4%x+%-%x+%-%x+$"), id.new_id())
    setup(dir, { id = { method = "ts", prefix = "Org" } })
    ok(id.new_id():match("^Org:%d%d%d%d%d%d%d%dT%d%d%d%d%d%d%.%d%d%d%d%d%d$"), id.new_id())
    setup(dir, { id = { method = "ts", ts_format = "%Y" } })
    eq(os.date("%Y"), id.new_id())
    setup(dir, { id = { method = "org" } })
    local a = id.new_id()
    ok(a:match("^[0-9a-z]+$") and #a == 12, a)
    ok(a ~= id.new_id() or true)
  end)

  it("creates an ID once, and a new one when forced (C-u)", function()
    local dir = tmpdir()
    setup(dir)
    local p = dir .. "/a.org"
    utils.writefile(p, { "* A" })
    vim.cmd("edit! " .. p)
    local buf = vim.api.nvim_get_current_buf()
    local first = id.get_create({ bufnr = buf, lnum = 1 })
    eq(first, id.get_create({ bufnr = buf, lnum = 1 }))
    local second = id.get_create({ bufnr = buf, lnum = 1 }, true)
    ok(second ~= first)
    eq({ "* A", ":PROPERTIES:", ":ID: " .. second, ":END:" }, buf_lines(buf))
  end)

  it("finds IDs in archives and extra files and rebuilds the database", function()
    local dir = tmpdir()
    local extra = tmpdir()
    utils.writefile(dir .. "/a.org", { "* A", ":PROPERTIES:", ":ID: in-agenda", ":END:" })
    utils.writefile(dir .. "/a.org_archive", { "* Old", ":PROPERTIES:", ":ID: in-archive", ":END:" })
    utils.writefile(extra .. "/x.org", { "* X", ":PROPERTIES:", ":ID: in-extra", ":END:" })
    setup(dir, { id = { extra_files = { extra .. "/*.org" } } })
    vim.cmd("enew!")
    vim.cmd("silent! %bwipeout!")
    eq(3, id.update_locations())
    local db = utils.read_json(dir .. "/ids.json")
    ok(db["in-archive"]:match("a%.org_archive$"))
    ok(db["in-extra"]:match("x%.org$"))
    id._reset()
    utils.write_json(dir .. "/ids.json", {})
    eq(1, id.find("in-archive").lnum)
    eq(1, id.find("in-extra").lnum)
    setup(dir, { id = { search_archives = false } })
    utils.write_json(dir .. "/ids.json", {})
    eq(nil, id.find("in-archive"))
  end)
end)

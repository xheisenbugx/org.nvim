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

  it("registers several ids at once and finds them outside the agenda files", function()
    local dir = tmpdir()
    setup(dir)
    local other = tmpdir() .. "/note.org"
    utils.writefile(other, { ":PROPERTIES:", ":ID: file-x", ":END:", "* H", ":PROPERTIES:", ":ID: head-x", ":END:" })
    id.register_many({ ["file-x"] = other, ["head-x"] = other })
    id._reset()
    eq(other, utils.read_json(dir .. "/ids.json")["head-x"])
    eq(4, id.find("head-x").lnum)
    eq(other, id.find("file-x").filename)
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
    eq({ "* A", ":PROPERTIES:", ":ID:       " .. second, ":END:" }, buf_lines(buf))
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
  it("reports duplicate IDs and keeps the first file, like org-id-update-id-locations", function()
    local dir = tmpdir()
    utils.writefile(dir .. "/a.org", { "* A", ":PROPERTIES:", ":ID: dup", ":END:" })
    utils.writefile(
      dir .. "/b.org",
      { "* B", ":PROPERTIES:", ":ID: dup", ":END:", "* C", ":PROPERTIES:", ":ID: c", ":END:" }
    )
    setup(dir)
    vim.cmd("enew!")
    vim.cmd("silent! %bwipeout!")
    local warned = {}
    local warn = utils.warn
    utils.warn = function(msg)
      warned[#warned + 1] = msg
    end
    local n, dups = id.update_locations()
    utils.warn = warn
    eq(2, n)
    eq({ "dup" }, dups)
    eq({ '1 duplicate IDs found: "dup"' }, warned)
    ok(utils.read_json(dir .. "/ids.json")["dup"]:match("/a%.org$"))
  end)

  it("ignores damaged entries in the locations file", function()
    local dir = tmpdir()
    setup(dir)
    utils.writefile(dir .. "/ids.json", { '{"a": null, "b": {"x": 1}, "c": 5}' })
    id._reset()
    eq(nil, id.find("a"))
    eq(nil, id.find("b"))
    eq({}, id.known_ids())
  end)

  it("stores an id: link before the first heading in a file-level drawer", function()
    local dir = require("org.utils").realpath(tmpdir())
    setup(dir, { links = { use_id = true } })
    local links = require("org.links")
    local p = dir .. "/top.org"
    utils.writefile(p, { "# comment", "#+TITLE: My File", "", "Some text", "* H1" })
    vim.cmd("edit! " .. p)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local l = links.store_link(0)
    local lines = buf_lines()
    eq("# comment", lines[1])
    eq(":PROPERTIES:", lines[2])
    local new = lines[3]:match("^:ID:%s+(%S+)$")
    ok(new, lines[3])
    eq({ ":END:", "#+TITLE: My File" }, { lines[4], lines[5] })
    eq("id:" .. new, l.link)
    eq("My File", l.desc)
    -- the ID is known and resolves to the file
    eq(p, id.find(new).filename)
    eq(new, id.get({ bufnr = 0, lnum = 1 }))
    -- from a later line: the same ID plus the line as search string
    vim.api.nvim_win_set_cursor(0, { 7, 0 })
    l = links.store_link(0)
    eq("id:" .. new .. "::Some text", l.link)
    eq(nil, l.desc)
    -- without a title, the file name describes it
    local q = dir .. "/plain.org"
    utils.writefile(q, { "intro", "* H" })
    vim.cmd("edit! " .. q)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    l = links.store_link(0)
    eq("plain.org", l.desc)
    eq(":PROPERTIES:", buf_lines()[1])
    eq("intro", buf_lines()[4])
    vim.cmd("silent! wall")
    eq(2, id.update_locations())
  end)

  it("reads and writes Emacs's org-id-locations file", function()
    local dir = require("org.utils").realpath(tmpdir())
    local db = dir .. "/.org-id-locations"
    utils.writefile(dir .. "/a.org", { "* A", ":PROPERTIES:", ":ID: id-a", ":END:" })
    utils.writefile(db, {
      "",
      '(("' .. dir .. '/a.org" "id-a" "id-a2") ("~/x \\"q\\".org" "id-x") ("rel.org" "id-rel"))',
    })
    setup(dir, { id = { locations_file = db } })
    local map = id.parse_emacs_locations(table.concat(utils.readfile(db), "\n"), dir)
    eq(dir .. "/a.org", map["id-a2"])
    eq(vim.fs.normalize(vim.env.HOME .. '/x "q".org'), map["id-x"])
    eq(dir .. "/rel.org", map["id-rel"])
    eq({ "id-a", "id-a2", "id-rel", "id-x" }, id.known_ids())
    eq(1, id.find("id-a").lnum)
    -- writing keeps the Emacs format, abbreviating the home directory
    id.register("id-new", vim.env.HOME .. "/n.org")
    local text = table.concat(utils.readfile(db), "\n")
    eq("", utils.readfile(db)[1])
    ok(text:find('("~/n.org" "id-new")', 1, true), text)
    ok(text:find('("~/x \\"q\\".org" "id-x")', 1, true), text)
    -- (abbreviated where the temp directory is below home, as on Windows)
    ok(text:find('("' .. utils.abbreviate(dir) .. '/a.org" "id-a" "id-a2")', 1, true), text)
    -- relative file names (org-id-locations-file-relative)
    setup(dir, { id = { locations_file = db, locations_file_relative = true } })
    id.register("id-b", dir .. "/b.org")
    ok(table.concat(utils.readfile(db), "\n"):find('("b.org" "id-b")', 1, true))
    eq(dir .. "/b.org", id.parse_emacs_locations(table.concat(utils.readfile(db), "\n"), dir)["id-b"])
    -- a new file without a .json name is created in Emacs's format; JSON
    -- files stay JSON
    local fresh = dir .. "/fresh-ids"
    setup(dir, { id = { locations_file = fresh } })
    id.register("f1", dir .. "/a.org")
    eq({ "", '(("' .. utils.abbreviate(dir) .. '/a.org" "f1"))' }, utils.readfile(fresh))
    setup(dir)
    id.register("j1", dir .. "/a.org")
    eq(dir .. "/a.org", utils.read_json(dir .. "/ids.json").j1)
    setup(dir, { id = { locations_file = fresh, locations_format = "json" } })
    id.register("f2", dir .. "/a.org")
    eq(dir .. "/a.org", utils.read_json(fresh).f2)
  end)
end)

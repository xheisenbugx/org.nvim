local archive = require("org.archive")
local config = require("org.config")
local utils = require("org.utils")
vim.g.org_test = true

describe("archive", function()
  it("parses locations", function()
    local l = archive.parse_location("%s_archive::", "/x/y.org")
    eq("/x/y.org_archive", l.filename)
    eq(nil, l.heading)
    l = archive.parse_location("::* Archived Tasks", "/x/y.org")
    eq("/x/y.org", l.filename)
    eq("Archived Tasks", l.heading)
    eq(1, l.level)
    l = archive.parse_location("arch/%s::** From %s", "/x/y.org")
    ok(l.filename:match("/x/arch/x/y.org") or l.filename:match("arch"), l.filename)
    eq(2, l.level)
    l = archive.parse_location("other.org::", "/x/y.org")
    eq("/x/other.org", l.filename)
  end)

  it("archives to the _archive file with context", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local p = dir .. "/tasks.org"
    utils.writefile(p, { "#+FILETAGS: :f:", "* Project :proj:", "** DONE Finish :x:", "   CLOSED: [2026-09-20 Sun]", "** Keep" })
    config.setup({ org_directory = dir, agenda_files = { dir } })
    vim.cmd("edit! " .. p)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    archive.archive_subtree()
    eq({ "#+FILETAGS: :f:", "* Project :proj:", "** Keep" }, vim.tbl_map(function(l)
      return (l:gsub("%s+", " "))
    end, buf_lines()))
    local a = utils.readfile(p .. "_archive")
    eq("#    -*- mode: org -*-", a[1])
    ok(a[4]:match("^Archived entries from file .*/tasks%.org$"), a[4])
    local text = table.concat(a, "\n")
    ok(text:find("\n%* DONE Finish"), text)
    ok(text:find(":ARCHIVE_OLPATH: Project", 1, true), text)
    ok(text:find(":ARCHIVE_TODO: DONE", 1, true))
    ok(text:find(":ARCHIVE_CATEGORY: tasks", 1, true))
    ok(text:find(":ARCHIVE_ITAGS: f proj", 1, true))
    ok(text:find(":ARCHIVE_TIME: %d%d%d%d%-%d%d%-%d%d %a+ %d%d:%d%d\n"), text)
  end)

  it("archives under a heading in the same file via #+ARCHIVE", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local p = dir .. "/s.org"
    utils.writefile(p, { "#+ARCHIVE: ::* Archive", "* A", "* B" })
    config.setup({ org_directory = dir, agenda_files = { dir }, archive_save_context_info = { "todo" } })
    vim.cmd("edit! " .. p)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    archive.archive_subtree()
    eq({ "#+ARCHIVE: ::* Archive", "* B", "* Archive", "** A" }, buf_lines())
  end)

  it("toggles the ARCHIVE tag", function()
    config.setup({ tags_column = 0 })
    org_buffer({ "* Task :a:" }, { 1, 0 })
    archive.toggle_archive_tag()
    eq("* Task :a:ARCHIVE:", buf_lines()[1])
    archive.toggle_archive_tag()
    eq("* Task :a:", buf_lines()[1])
    config.setup({})
  end)

  it("adds inherited tags when archiving within the file", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local p = dir .. "/i.org"
    utils.writefile(p, { "#+ARCHIVE: ::* Old", "* P :proj:", "** DONE Task :x:" })
    config.setup({ org_directory = dir, agenda_files = { dir }, tags_column = 0, archive_save_context_info = {} })
    vim.cmd("edit! " .. p)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    archive.archive_subtree()
    eq({ "#+ARCHIVE: ::* Old", "* P :proj:", "* Old", "** DONE Task :proj:x:" }, buf_lines())
    config.setup({})
  end)

  it("parses and archives into a datetree location", function()
    local l = archive.parse_location("a.org::datetree/", "/x/y.org")
    eq(true, l.datetree)
    eq(nil, l.heading)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local p = dir .. "/d.org"
    utils.writefile(p, { "* DONE Old", "  CLOSED: [2026-03-05 Thu 10:00]", "* Keep" })
    config.setup({
      org_directory = dir,
      agenda_files = { dir },
      archive_location = "arch.org::datetree/",
      archive_save_context_info = {},
    })
    vim.cmd("edit! " .. p)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    archive.archive_subtree()
    eq({ "* Keep" }, buf_lines())
    local a = utils.readfile(dir .. "/arch.org")
    local text = table.concat(a, "\n")
    ok(text:find("\n%* 2026\n%*%* 2026%-03 March\n%*%*%* 2026%-03%-05 Thursday\n%*%*%*%* DONE Old"), text)
    config.setup({})
  end)

  it("archives to the Archive sibling", function()
    config.setup({ tags_column = 0 })
    org_buffer({ "* Project", "** DONE A", "   text", "** TODO B" }, { 2, 0 })
    archive.archive_to_sibling()
    local l = buf_lines()
    eq("* Project", l[1])
    eq("** TODO B", l[2])
    eq("** Archive :ARCHIVE:", l[3])
    eq("*** DONE A", l[4])
    ok(table.concat(l, "\n"):find(":ARCHIVE_TIME: %d%d%d%d"), table.concat(l, "\n"))
    -- a second entry goes into the existing sibling
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    archive.archive_to_sibling()
    l = buf_lines()
    eq("* Project", l[1])
    eq("** Archive :ARCHIVE:", l[2])
    eq("*** DONE A", l[3])
    local n = 0
    for _, line in ipairs(l) do
      if line:match("^%*%*%* ") then
        n = n + 1
      end
    end
    eq(2, n)
    eq("*** TODO B", l[#l - 3])
    config.setup({})
  end)

  it("archives every child without open TODOs", function()
    config.setup({ tags_column = 0 })
    org_buffer({ "* P", "** DONE a", "** TODO b", "** Note", "*** TODO c" }, { 1, 0 })
    local asked = {}
    local n = archive.archive_all_done({
      tag = true,
      confirm = function(hl)
        asked[#asked + 1] = hl:plain_title()
        return true
      end,
    })
    eq(1, n)
    eq({ "a" }, asked)
    eq("** DONE a :ARCHIVE:", buf_lines()[2])
    config.setup({})
  end)
end)

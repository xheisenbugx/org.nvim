local archive = require("org.archive")
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
    agenda_files = { dir },
    archive_save_context_info = {},
    id = { locations_file = dir .. "/ids.json" },
  }, extra or {}))
  require("org.id")._reset()
end

local function lines_of(path)
  local b = utils.find_buffer(path)
  return b and vim.api.nvim_buf_get_lines(b, 0, -1, false) or utils.readfile(path)
end

--- Archive the headlines `srcs` (in order) of a file with `content`;
--- returns the source lines and the archive file lines ("(same)" when
--- archiving in the same file). The header's file name is replaced by FILE.
local function ar(content, srcs, loc, extra, acontent)
  local dir = tmpdir()
  setup(dir, vim.tbl_extend("force", { archive_location = loc }, extra or {}))
  local p = dir .. "/s.org"
  utils.writefile(p, vim.split(content, "\n"))
  if acontent then
    utils.writefile(dir .. "/arch.org", vim.split(acontent, "\n"))
  end
  vim.cmd("edit! " .. p)
  for _, src in ipairs(srcs) do
    local n = vim.fn.index(buf_lines(), src) + 1
    ok(n > 0, src)
    vim.api.nvim_win_set_cursor(0, { n, 0 })
    archive.archive_subtree()
  end
  local target = archive.parse_location(loc, vim.fs.normalize(p)).filename
  local a = target == vim.fs.normalize(p) and { "(same)" } or lines_of(target) or {}
  a = vim.tbl_map(function(l)
    return (l:gsub("^Archived entries from file .*s%.org$", "Archived entries from file FILE"))
  end, a)
  return buf_lines(), a
end

describe("archive locations", function()
  it("parses locations", function()
    local l = archive.parse_location("%s_archive::", "/x/y.org")
    eq("/x/y.org_archive", l.filename)
    eq(nil, l.heading)
    l = archive.parse_location("::* Archived Tasks", "/x/y.org")
    eq("/x/y.org", l.filename)
    eq("Archived Tasks", l.heading)
    eq(1, l.level)
    l = archive.parse_location("arch/%s::** From %s", "/x/y.org")
    ok(l.filename:match("arch"), l.filename)
    eq(2, l.level)
    eq("** From y.org", l.stars)
    l = archive.parse_location("other.org::", "/x/y.org")
    eq("/x/other.org", l.filename)
    l = archive.parse_location("a.org::datetree/", "/x/y.org")
    eq(true, l.datetree)
    eq(nil, l.heading)
    l = archive.parse_location("a.org::datetree/* Sub", "/x/y.org")
    eq("**** Sub", l.stars)
  end)
end)

describe("archive_subtree (Emacs parity)", function()
  after_each(function()
    config.setup({})
  end)

  local H = { "", "Archived entries from file FILE", "", "" }
  local function with_header(t)
    return vim.list_extend(vim.deepcopy(H), t)
  end

  it("writes Emacs's header to a new archive file, with a mode line for non-.org names", function()
    local src, a = ar("* A\n* B", { "* A" }, "%s_archive::")
    eq({ "* B" }, src)
    eq({ "#    -*- mode: org -*-", "", "", "Archived entries from file FILE", "", "", "* A" }, a)
    src, a = ar("* A\n* B", { "* A" }, "arch.org::")
    eq(with_header({ "* A" }), a)
    _, a = ar("* A\n* B", { "* A" }, "arch.org::", { archive_file_header_format = false })
    eq({ "", "* A" }, a)
    _, a = ar("* A\n* B", { "* A" }, "arch.org::", { archive_file_header_format = "Old stuff of %s" })
    ok(a[1]:match("^Old stuff of .*s%.org$"), a[1])
    eq("* A", a[2])
  end)

  it("keeps the subtree's blank lines and separates entries with one", function()
    local src, a = ar("* A\nbody\n\n* B\n* C", { "* A", "* B" }, "arch.org::")
    eq({ "* C" }, src)
    eq(with_header({ "* A", "body", "", "", "* B" }), a)
    _, a = ar("* A\n* B", { "* A" }, "arch.org::", nil, "* X")
    eq({ "* X", "", "* A" }, a)
    _, a = ar("* A\n* B", { "* A" }, "arch.org::", nil, "* X\n\n")
    eq({ "* X", "", "", "", "* A" }, a)
  end)

  it("archives under a heading, creating it when missing", function()
    local _, a = ar("* A\n* B", { "* A", "* B" }, "arch.org::* Old")
    eq(with_header({ "* Old", "", "** A", "", "** B" }), a)
    _, a = ar("* A\n* B", { "* A" }, "arch.org::* Old", nil, "* Old :t:\n** x\n\n\n* Next")
    eq({ "* Old :t:", "** x", "", "** A", "* Next" }, a)
    _, a = ar("* A\n* B", { "* A" }, "arch.org::** Deep")
    eq(with_header({ "** Deep", "", "*** A" }), a)
    local src = ar("* A\n* B\n* Old\n** x\n", { "* A" }, "::* Old")
    eq({ "* B", "* Old", "** x", "", "** A" }, src)
    src = ar("#+ARCHIVE: ::* Archive\n* A\n* B", { "* A" }, "%s_archive::")
    eq({ "#+ARCHIVE: ::* Archive", "* B", "", "* Archive", "", "** A" }, src)
  end)

  it("archives into a date tree for the CLOSED date", function()
    local dt = { "* 2026", "** 2026-03 March", "*** 2026-03-05 Thursday" }
    local _, a = ar(
      "* DONE A\nCLOSED: [2026-03-05 Thu 10:00]\n* DONE B\nCLOSED: [2026-03-05 Thu 11:00]",
      { "* DONE A", "* DONE B" },
      "arch.org::datetree/"
    )
    local want = { "", "Archived entries from file FILE" }
    vim.list_extend(want, dt)
    vim.list_extend(want, { "**** DONE A", "CLOSED: [2026-03-05 Thu 10:00]", "**** DONE B", "CLOSED: [2026-03-05 Thu 11:00]" })
    eq(want, a)
    _, a = ar("* DONE A\nCLOSED: [2026-03-05 Thu 10:00]\n* B", { "* DONE A" }, "arch.org::datetree/* Sub")
    want = { "", "Archived entries from file FILE" }
    vim.list_extend(want, dt)
    vim.list_extend(want, { "**** Sub", "***** DONE A", "CLOSED: [2026-03-05 Thu 10:00]" })
    eq(want, a)
  end)

  it("honours archive_reversed_order", function()
    local _, a = ar("* A\n* B", { "* A", "* B" }, "arch.org::", { archive_reversed_order = true })
    eq({ "", "Archived entries from file FILE", "", "* B", "* A" }, a)
    local src = ar("* A\n* B\n\n* Old\n** x", { "* A" }, "::* Old", { archive_reversed_order = true })
    eq({ "* B", "", "* Old", "", "** A", "** x" }, src)
  end)

  it("marks archived entries done with archive_mark_done", function()
    local dir = tmpdir()
    local _, a = ar("* TODO A\n* B", { "* TODO A" }, "arch.org::", { archive_mark_done = true })
    eq(with_header({ "* DONE A" }), a)
    _, a = ar("* A\n* B", { "* A" }, "arch.org::", { archive_mark_done = true })
    eq(with_header({ "* DONE A" }), a)
    _, a = ar("* DONE A\n* B", { "* DONE A" }, "arch.org::", {
      archive_mark_done = "CANCELLED",
      todo_keywords = { "TODO | DONE CANCELLED" },
    })
    eq(with_header({ "* DONE A" }), a)
    _, a = ar("* TODO A\n* B", { "* TODO A" }, "arch.org::", {
      archive_mark_done = "CANCELLED",
      todo_keywords = { "TODO | DONE CANCELLED" },
    })
    eq(with_header({ "* CANCELLED A" }), a)
    vim.fn.delete(dir, "rf")
  end)
end)

describe("archive", function()
  after_each(function()
    config.setup({})
  end)

  it("archives to the _archive file with context", function()
    local dir = tmpdir()
    local p = dir .. "/tasks.org"
    utils.writefile(p, { "#+FILETAGS: :f:", "* Project :proj:", "** DONE Finish :x:", "   CLOSED: [2026-09-20 Sun]", "** Keep" })
    config.setup({ org_directory = dir, agenda_files = { dir }, id = { locations_file = dir .. "/ids.json" } })
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

  it("adds inherited tags when archiving within the file", function()
    local dir = tmpdir()
    local p = dir .. "/i.org"
    utils.writefile(p, { "#+ARCHIVE: ::* Old", "* P :proj:", "** DONE Task :x:" })
    setup(dir, { tags_column = 0 })
    vim.cmd("edit! " .. p)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    archive.archive_subtree()
    eq({ "#+ARCHIVE: ::* Old", "* P :proj:", "", "* Old", "", "** DONE Task :proj:x:" }, buf_lines())
  end)

  it("fires OrgArchive and OrgArchiveFinalize, registers IDs and deletes attachments", function()
    local dir = tmpdir()
    local p = dir .. "/h.org"
    utils.writefile(p, { "* A", ":PROPERTIES:", ":ID: arch-id-1", ":DIR: att", ":END:", "* B" })
    vim.fn.mkdir(dir .. "/att", "p")
    utils.writefile(dir .. "/att/f.txt", { "x" })
    setup(dir, { archive_location = "arch.org::", attach = { archive_delete = true } })
    local seen = {}
    local group = vim.api.nvim_create_augroup("archive_spec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = { "OrgArchive", "OrgArchiveFinalize" },
      callback = function(ev)
        seen[#seen + 1] = ev.match .. ":" .. ev.data.title
      end,
    })
    vim.cmd("edit! " .. p)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    archive.archive_subtree()
    vim.api.nvim_del_augroup_by_id(group)
    eq({ "OrgArchiveFinalize:A", "OrgArchive:A" }, seen)
    eq(false, utils.is_dir(dir .. "/att"))
    local where = utils.read_json(dir .. "/ids.json")["arch-id-1"]
    eq(vim.uv.fs_realpath(dir .. "/arch.org"), vim.uv.fs_realpath(where))
    -- ids in archive files are found (org-id-search-archives)
    require("org.id")._reset()
    utils.write_json(dir .. "/ids.json", {})
    vim.cmd("enew!")
    local loc = require("org.id").find("arch-id-1")
    eq(vim.uv.fs_realpath(dir .. "/arch.org"), vim.uv.fs_realpath(loc.filename))
  end)

  it("toggles the ARCHIVE tag", function()
    config.setup({ tags_column = 0 })
    org_buffer({ "* Task :a:" }, { 1, 0 })
    archive.toggle_archive_tag()
    eq("* Task :a:ARCHIVE:", buf_lines()[1])
    archive.toggle_archive_tag()
    eq("* Task :a:", buf_lines()[1])
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
  end)

  it("archives every child without open TODOs, or tags them", function()
    config.setup({ tags_column = 0 })
    org_buffer({ "* P", "** DONE a", "** TODO b", "** Note", "*** TODO c" }, { 1, 0 })
    local asked = {}
    local n = archive.archive_all_done({
      tag = true,
      confirm = function(hl, reason)
        asked[#asked + 1] = hl:plain_title() .. ":" .. reason
        return true
      end,
    })
    eq(1, n)
    eq({ "a:no open TODO items" }, asked)
    eq("** DONE a :ARCHIVE:", buf_lines()[2])
  end)

  it("archives children whose first time stamp is old (archive_all_old)", function()
    config.setup({ tags_column = 0 })
    org_buffer({
      "* P",
      "** Old",
      "   <2020-01-01 Wed>",
      "** Range",
      "   <2020-01-01 Wed>--<2999-01-01 Tue>",
      "** New",
      "   <2999-01-01 Tue>",
      "** None",
    }, { 1, 0 })
    local asked = {}
    archive.archive_all_old({
      tag = true,
      confirm = function(hl, reason)
        asked[#asked + 1] = hl:plain_title() .. ":" .. reason
        return true
      end,
    })
    eq({ "Old:old timestamp <2020-01-01 Wed>" }, asked)
    eq("** Old :ARCHIVE:", buf_lines()[2])
  end)
end)

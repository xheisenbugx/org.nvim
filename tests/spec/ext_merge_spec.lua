local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local fixtures = root .. "/tests/fixtures/merge"
local driver = root .. "/lua/org/extensions/merge/driver.lua"

local function merge(base, ours, theirs, opts)
  return require("org.extensions.merge.merge").merge(base, ours, theirs, opts)
end

local function has_markers(lines)
  for _, l in ipairs(lines) do
    if l:match("^<<<<<<<") or l:match("^=======$") or l:match("^>>>>>>>") then
      return true
    end
  end
  return false
end

-- the lines between the first conflict's markers
local function conflict_sides(lines)
  local o, t, where = {}, {}, nil
  for _, l in ipairs(lines) do
    if l:match("^<<<<<<<") then
      where = o
    elseif l == "=======" and where then
      where = t
    elseif l:match("^>>>>>>>") and where then
      return o, t
    elseif where then
      where[#where + 1] = l
    end
  end
  return o, t
end

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

local function run(cmd, cwd)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  return res.code, res.stdout, res.stderr
end

describe("merge extension: diff3", function()
  local diff3 = require("org.extensions.merge.diff3")

  it("takes the changed side", function()
    local out, n = diff3.merge({ "a", "b", "c" }, { "a", "B", "c" }, { "a", "b", "c" })
    eq({ "a", "B", "c" }, out)
    eq(0, n)
  end)

  it("merges changes to separate lines", function()
    local out, n = diff3.merge({ "a", "b", "c", "d", "e" }, { "A", "b", "c", "d", "e" }, { "a", "b", "c", "d", "E" })
    eq({ "A", "b", "c", "d", "E" }, out)
    eq(0, n)
  end)

  it("takes an identical change once", function()
    local out, n = diff3.merge({ "a", "b" }, { "a", "x", "b" }, { "a", "x", "b" })
    eq({ "a", "x", "b" }, out)
    eq(0, n)
  end)

  it("conflicts on overlapping changes, only around them", function()
    local out, n = diff3.merge({ "a", "b", "c", "d", "e" }, { "a", "b", "C1", "d", "e" }, { "a", "b", "C2", "d", "e" })
    eq(1, n)
    eq({ "a", "b", "<<<<<<< ours", "C1", "=======", "C2", ">>>>>>> theirs", "d", "e" }, out)
  end)

  it("honours marker size, labels and the diff3 style", function()
    local out = diff3.merge({ "x" }, { "o" }, { "t" }, {
      marker_size = 3,
      ours_label = "HEAD",
      theirs_label = "topic",
      style = "diff3",
    })
    eq({ "<<< HEAD", "o", "||| base", "x", "===", "t", ">>> topic" }, out)
  end)

  it("keeps deletions and insertions at different places", function()
    local out, n = diff3.merge({ "a", "b", "c", "d" }, { "a", "c", "d" }, { "a", "b", "c", "d", "e" })
    eq({ "a", "c", "d", "e" }, out)
    eq(0, n)
  end)
end)

describe("merge extension: structural merge", function()
  it("merges independent changes to different entries", function()
    local base = { "* TODO A", "text a", "* TODO B", "text b" }
    local ours = { "* DONE A", "text a", "* TODO B", "text b" }
    local theirs = { "* TODO A", "text a", "* TODO B", "text b changed" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    eq({ "* DONE A", "text a", "* TODO B", "text b changed" }, res.lines)
  end)

  it("keeps headlines added at the end by both sides", function()
    local base = { "* A" }
    local res = merge(base, { "* A", "* From ours" }, { "* A", "* From theirs" })
    eq(0, res.conflicts)
    eq({ "* A", "* From ours", "* From theirs" }, res.lines)
  end)

  it("merges changes to adjacent entries that a line merge would conflict on", function()
    local base = { "* A", "* B" }
    local ours = { "* A", "a body", "* B" }
    local theirs = { "* A", "* B", "b body" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    eq({ "* A", "a body", "* B", "b body" }, res.lines)
  end)

  it("scopes a TODO conflict to the one entry's headline", function()
    local base = { "* TODO A", "body", "* TODO B" }
    local ours = { "* DONE A", "body", "* TODO B" }
    local theirs = { "* WAIT A", "body", "* DONE B" }
    local res = merge({ "#+TODO: TODO WAIT | DONE", unpack(base) }, { "#+TODO: TODO WAIT | DONE", unpack(ours) }, {
      "#+TODO: TODO WAIT | DONE",
      unpack(theirs),
    })
    eq(1, res.conflicts)
    eq({
      "#+TODO: TODO WAIT | DONE",
      "<<<<<<< ours",
      "* DONE A",
      "=======",
      "* WAIT A",
      ">>>>>>> theirs",
      "body",
      "* DONE B",
    }, res.lines)
  end)

  it("puts conflicting planning in the headline conflict", function()
    local base = { "* TODO A", "SCHEDULED: <2026-10-01 Thu>" }
    local ours = { "* TODO A", "SCHEDULED: <2026-10-02 Fri>" }
    local theirs = { "* TODO A", "SCHEDULED: <2026-10-05 Mon>" }
    local res = merge(base, ours, theirs)
    eq(1, res.conflicts)
    local o, t = conflict_sides(res.lines)
    eq({ "* TODO A", "SCHEDULED: <2026-10-02 Fri>" }, o)
    eq({ "* TODO A", "SCHEDULED: <2026-10-05 Mon>" }, t)
  end)

  it("keeps CLOSED with the TODO keyword of its side", function()
    local all = function(l)
      return { "#+TODO: TODO WAIT | DONE", unpack(l) }
    end
    local base = all({ "* TODO A", "text" })
    local ours = all({ "* WAIT A", "text" })
    local theirs = all({ "* DONE A", "CLOSED: [2026-09-29 Tue 18:10]", "text" })
    local res = merge(base, ours, theirs)
    eq(1, res.conflicts)
    local o, t = conflict_sides(res.lines)
    eq({ "* WAIT A" }, o)
    eq({ "* DONE A", "CLOSED: [2026-09-29 Tue 18:10]" }, t)
    res = merge(base, ours, theirs, { prefer = "ours" })
    eq(all({ "* WAIT A", "text" }), res.lines)
    res = merge(base, ours, theirs, { prefer = "theirs" })
    eq(theirs, res.lines)
  end)

  it("merges planning keywords one by one", function()
    local base = { "* TODO A", "SCHEDULED: <2026-10-01 Thu>" }
    local ours = { "* DONE A", "CLOSED: [2026-10-01 Thu 09:00] SCHEDULED: <2026-10-01 Thu>" }
    local theirs = { "* TODO A", "DEADLINE: <2026-10-09 Fri> SCHEDULED: <2026-10-01 Thu>" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    -- the existing order is kept, a new keyword goes last
    eq(
      { "* DONE A", "CLOSED: [2026-10-01 Thu 09:00] SCHEDULED: <2026-10-01 Thu> DEADLINE: <2026-10-09 Fri>" },
      res.lines
    )
  end)

  it("prefers a side when asked", function()
    local base = { "* TODO A", "SCHEDULED: <2026-10-01 Thu>", "* B" }
    local ours = { "* DONE A", "SCHEDULED: <2026-10-02 Fri>", "* B" }
    local theirs = { "* NEXT A", "SCHEDULED: <2026-10-05 Mon>", "* B" }
    local all = function(l)
      return { "#+TODO: TODO NEXT | DONE", unpack(l) }
    end
    local res = merge(all(base), all(ours), all(theirs), { prefer = "theirs" })
    eq(0, res.conflicts)
    eq(all(theirs), res.lines)
    res = merge(all(base), all(ours), all(theirs), { prefer = "ours" })
    eq(0, res.conflicts)
    eq(all(ours), res.lines)
  end)

  it("unions tags added on both sides and keeps removals", function()
    local base = { "* A :x:y:" }
    local ours = { "* A :x:y:o:" }
    local theirs = { "* A :y:t:" }
    local res = merge(base, ours, theirs, {})
    eq(0, res.conflicts)
    local hl = require("org.parser").parse_headline_line(res.lines[1])
    eq({ "y", "o", "t" }, hl.tags)
    eq("A", hl.title)
  end)

  it("merges the property drawer key by key", function()
    local base = { "* A", ":PROPERTIES:", ":ID: 1", ":EFFORT: 1:00", ":OLD: x", ":END:" }
    local ours = { "* A", ":PROPERTIES:", ":ID: 1", ":EFFORT: 2:00", ":OLD: x", ":END:" }
    local theirs = { "* A", ":PROPERTIES:", ":ID: 1", ":EFFORT: 1:00", ":OWNER: me", ":END:" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    eq({ "* A", ":PROPERTIES:", ":ID: 1", ":EFFORT: 2:00", ":OWNER: me", ":END:" }, res.lines)
  end)

  it("scopes a property conflict to the property line", function()
    local base = { "* A", ":PROPERTIES:", ":EFFORT: 1:00", ":END:", "text" }
    local ours = { "* A", ":PROPERTIES:", ":EFFORT: 2:00", ":END:", "text" }
    local theirs = { "* A", ":PROPERTIES:", ":EFFORT: 3:00", ":END:", "text more" }
    local res = merge(base, ours, theirs)
    eq(1, res.conflicts)
    eq({
      "* A",
      ":PROPERTIES:",
      "<<<<<<< ours",
      ":EFFORT: 2:00",
      "=======",
      ":EFFORT: 3:00",
      ">>>>>>> theirs",
      ":END:",
      "text more",
    }, res.lines)
    res = merge(base, ours, theirs, { prefer = "ours" })
    eq(0, res.conflicts)
    eq(":EFFORT: 2:00", res.lines[3])
  end)

  it("unions LOGBOOK clocks and sorts them newest first", function()
    local c1 = "CLOCK: [2026-09-20 Sun 10:00]--[2026-09-20 Sun 11:00] =>  1:00"
    local c2 = "CLOCK: [2026-09-22 Tue 10:00]--[2026-09-22 Tue 11:00] =>  1:00"
    local c3 = "CLOCK: [2026-09-24 Thu 10:00]--[2026-09-24 Thu 11:00] =>  1:00"
    local note = { '- State "DONE"       from "TODO"       [2026-09-23 Wed 12:00] \\', "  finally" }
    local base = { "* A", ":LOGBOOK:", c1, ":END:" }
    local ours = { "* A", ":LOGBOOK:", c3, c1, ":END:" }
    local theirs = { "* A", ":LOGBOOK:", note[1], note[2], c2, c1, ":END:" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    eq({ "* A", ":LOGBOOK:", c3, note[1], note[2], c2, c1, ":END:" }, res.lines)
    res = merge(base, ours, theirs, { sort_logbook = false })
    eq({ "* A", ":LOGBOOK:", c3, c1, note[1], note[2], c2, ":END:" }, res.lines)
  end)

  it("keeps a LOGBOOK line removed on one side removed", function()
    local c1 = "CLOCK: [2026-09-20 Sun 10:00]--[2026-09-20 Sun 11:00] =>  1:00"
    local c2 = "CLOCK: [2026-09-22 Tue 10:00]--[2026-09-22 Tue 11:00] =>  1:00"
    local c3 = "CLOCK: [2026-09-24 Thu 10:00]--[2026-09-24 Thu 11:00] =>  1:00"
    local res = merge({ "* A", ":LOGBOOK:", c2, c1, ":END:" }, { "* A", ":LOGBOOK:", c1, ":END:" }, {
      "* A",
      ":LOGBOOK:",
      c3,
      c2,
      c1,
      ":END:",
    })
    eq({ "* A", ":LOGBOOK:", c3, c1, ":END:" }, res.lines)
  end)

  it("merges body changes line by line inside the entry", function()
    local base = { "* A", "one", "two", "three", "four", "* B", "b" }
    local ours = { "* A", "ONE", "two", "three", "four", "* B", "b" }
    local theirs = { "* A", "one", "two", "three", "FOUR", "* B", "b" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    eq({ "* A", "ONE", "two", "three", "FOUR", "* B", "b" }, res.lines)
  end)

  it("keeps body conflict markers inside the entry", function()
    local base = { "* A", "one", "* B", "b" }
    local ours = { "* A", "uno", "* B", "b" }
    local theirs = { "* A", "eins", "* B", "b" }
    local res = merge(base, ours, theirs)
    eq(1, res.conflicts)
    eq({ "* A", "<<<<<<< ours", "uno", "=======", "eins", ">>>>>>> theirs", "* B", "b" }, res.lines)
  end)

  it("follows an entry refiled by ID to another parent", function()
    local base = { "* Inbox", "** TODO Task", ":PROPERTIES:", ":ID: t1", ":END:", "note", "* Work" }
    local ours = { "* Inbox", "* Work", "** TODO Task", ":PROPERTIES:", ":ID: t1", ":END:", "note" }
    local theirs = { "* Inbox", "** DONE Task", ":PROPERTIES:", ":ID: t1", ":END:", "note, done", "* Work" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    eq({ "* Inbox", "* Work", "** DONE Task", ":PROPERTIES:", ":ID: t1", ":END:", "note, done" }, res.lines)
  end)

  it("adjusts the level of a refiled subtree", function()
    local base = { "* Task", ":PROPERTIES:", ":ID: t1", ":END:", "** Sub", "* Area", "** Project" }
    local ours = { "* Area", "** Project", "*** Task", ":PROPERTIES:", ":ID: t1", ":END:", "**** Sub" }
    local theirs =
      { "* Task", ":PROPERTIES:", ":ID: t1", ":END:", "more", "** Sub", "sub text", "* Area", "** Project" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    eq({
      "* Area",
      "** Project",
      "*** Task",
      ":PROPERTIES:",
      ":ID: t1",
      ":END:",
      "more",
      "**** Sub",
      "sub text",
    }, res.lines)
  end)

  it("follows a subtree moved without an ID when the other side left it alone", function()
    local base = { "* A", "** Child", "c", "* B" }
    local ours = { "* A", "* B", "** Child", "c" }
    local theirs = { "* A", "** Child", "c", "* B", "b" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    eq({ "* A", "* B", "b", "** Child", "c" }, res.lines)
  end)

  it("follows a reordering of siblings", function()
    local base = { "* A", "* B", "* C" }
    local ours = { "* C", "* A", "* B" }
    local theirs = { "* A", "a", "* B", "* C", "* D" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    -- D stays after C, where theirs put it
    eq({ "* C", "* D", "* A", "a", "* B" }, res.lines)
  end)

  it("matches an entry renamed on one side by its content", function()
    local base = { "* Old title", "same body", "* B" }
    local ours = { "* New title", "same body", "* B" }
    local theirs = { "* Old title", "same body", "* B", "b" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    eq({ "* New title", "same body", "* B", "b" }, res.lines)
  end)

  it("deletes an entry the other side did not change", function()
    local base = { "* A", "** Sub", "* B" }
    local ours = { "* B" }
    local theirs = { "* A", "** Sub", "* B", "b" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    eq({ "* B", "b" }, res.lines)
  end)

  it("conflicts on an entry deleted on one side and changed on the other", function()
    local base = { "* A", "** Sub", "s", "* B" }
    local ours = { "* B" }
    local theirs = { "* A", "** Sub", "s changed", "* B" }
    local res = merge(base, ours, theirs)
    eq(1, res.conflicts)
    eq({ "<<<<<<< ours", "=======", "* A", "** Sub", "s changed", ">>>>>>> theirs", "* B" }, res.lines)
  end)

  it("puts a changed entry deleted by theirs on the ours side of the conflict", function()
    local base = { "* A", "a", "* B" }
    local ours = { "* A", "a changed", "* B" }
    local theirs = { "* B" }
    local res = merge(base, ours, theirs)
    eq(1, res.conflicts)
    eq({ "<<<<<<< ours", "* A", "a changed", "=======", ">>>>>>> theirs", "* B" }, res.lines)
  end)

  it("keeps a parent deleted on one side while the other added a child to it", function()
    local base = { "* A", "* B" }
    local ours = { "* B" }
    local theirs = { "* A", "** New child", "* B" }
    local res = merge(base, ours, theirs)
    eq(1, res.conflicts)
    eq({ "<<<<<<< ours", "=======", "* A", "** New child", ">>>>>>> theirs", "* B" }, res.lines)
  end)

  it("keeps inline tasks in the entry text", function()
    local base = { "* A", "text", "*************** TODO inline", "*************** END", "* B" }
    local ours = { "* A", "text", "*************** DONE inline", "*************** END", "* B" }
    local theirs = { "* A", "text", "*************** TODO inline", "*************** END", "* B", "b" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    eq({ "* A", "text", "*************** DONE inline", "*************** END", "* B", "b" }, res.lines)
  end)

  it("conflicts on the same headline added with different text", function()
    local res = merge({ "* A" }, { "* A", "* New", "mine" }, { "* A", "* New", "yours" })
    eq(1, res.conflicts)
    eq({ "* A", "* New", "<<<<<<< ours", "mine", "=======", "yours", ">>>>>>> theirs" }, res.lines)
  end)

  it("merges the text before the first headline", function()
    local base = { "#+TITLE: T", "", "intro", "* A" }
    local ours = { "#+TITLE: Title", "", "intro", "* A" }
    local theirs = { "#+TITLE: T", "", "intro more", "* A" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    eq({ "#+TITLE: Title", "", "intro more", "* A" }, res.lines)
  end)

  it("reads the files' #+TODO keywords", function()
    local base = { "#+TODO: NEXT | DONE", "* NEXT A" }
    local ours = { "#+TODO: NEXT | DONE", "* DONE A" }
    local theirs = { "#+TODO: NEXT | DONE", "* NEXT A", "text" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    eq({ "#+TODO: NEXT | DONE", "* DONE A", "text" }, res.lines)
  end)

  it("keeps several headlines with the same title apart", function()
    local base = { "* Note", "one", "* Note", "two" }
    local ours = { "* Note", "ONE", "* Note", "two" }
    local theirs = { "* Note", "one", "* Note", "TWO" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    eq({ "* Note", "ONE", "* Note", "TWO" }, res.lines)
  end)

  it("merges the refile fixture with one conflict scoped to the entry body", function()
    local rf = require("org.extensions.merge.merge").read_file
    local d = fixtures .. "/refile/"
    local res = merge((rf(d .. "base.org")), (rf(d .. "ours.org")), (rf(d .. "theirs.org")))
    eq(1, res.conflicts)
    eq((rf(d .. "expected.org")), res.lines)
  end)

  it("merges the clean fixture without conflicts", function()
    local rf = require("org.extensions.merge.merge").read_file
    local d = fixtures .. "/clean/"
    local res = merge((rf(d .. "base.org")), (rf(d .. "ours.org")), (rf(d .. "theirs.org")))
    eq(0, res.conflicts)
    eq((rf(d .. "expected.org")), res.lines)
  end)
end)

describe("merge extension: driver", function()
  local function copy(src, dst)
    vim.fn.writefile(vim.fn.readfile(src, "b"), dst, "b")
  end

  it("writes the result over ours and exits 0 when clean", function()
    local dir = tmpdir()
    copy(fixtures .. "/clean/ours.org", dir .. "/ours.org")
    local code = run({
      vim.v.progpath,
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "-l",
      driver,
      fixtures .. "/clean/base.org",
      dir .. "/ours.org",
      fixtures .. "/clean/theirs.org",
      "tasks.org",
    })
    eq(0, code)
    eq(vim.fn.readfile(fixtures .. "/clean/expected.org", "b"), vim.fn.readfile(dir .. "/ours.org", "b"))
    vim.fn.delete(dir, "rf")
  end)

  it("exits 1 with markers, using the marker size", function()
    local dir = tmpdir()
    copy(fixtures .. "/refile/ours.org", dir .. "/ours.org")
    local code = run({
      vim.v.progpath,
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "-l",
      driver,
      "--marker-size=9",
      fixtures .. "/refile/base.org",
      dir .. "/ours.org",
      fixtures .. "/refile/theirs.org",
      "tasks.org",
    })
    eq(1, code)
    local lines = vim.fn.readfile(dir .. "/ours.org")
    ok(vim.tbl_contains(lines, "<<<<<<<<< ours"))
    ok(vim.tbl_contains(lines, "========="))
    vim.fn.delete(dir, "rf")
  end)

  it("reads TODO keywords from --todo", function()
    local dir = tmpdir()
    vim.fn.writefile({ "* NEXT A" }, dir .. "/base.org")
    vim.fn.writefile({ "* DONE A" }, dir .. "/ours.org")
    vim.fn.writefile({ "* NEXT A", "text" }, dir .. "/theirs.org")
    local code = run({
      vim.v.progpath,
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "-l",
      driver,
      "--todo=TODO NEXT | DONE",
      dir .. "/base.org",
      dir .. "/ours.org",
      dir .. "/theirs.org",
    })
    eq(0, code)
    eq({ "* DONE A", "text" }, vim.fn.readfile(dir .. "/ours.org"))
    vim.fn.delete(dir, "rf")
  end)

  it("keeps a missing final newline", function()
    local m = require("org.extensions.merge.merge")
    local dir = tmpdir()
    local function write(name, text)
      local fh = assert(io.open(dir .. "/" .. name, "wb"))
      fh:write(text)
      fh:close()
    end
    write("base.org", "* A\n* B")
    write("ours.org", "* A\na\n* B")
    write("theirs.org", "* A\n* B\nb")
    eq(0, m.merge_files(dir .. "/base.org", dir .. "/ours.org", dir .. "/theirs.org"))
    local fh = assert(io.open(dir .. "/ours.org", "rb"))
    eq("* A\na\n* B\nb", fh:read("*a"))
    fh:close()
    vim.fn.delete(dir, "rf")
  end)
end)

describe("merge extension: setup", function()
  after_each(function()
    require("org.config").opts.extensions.merge = nil
    require("org.extensions").setup()
  end)

  it("registers nothing while off", function()
    require("org.config").opts.extensions.merge = nil
    require("org.extensions").setup()
    eq(nil, require("org.actions").list.merge_install)
    eq(false, require("org.extensions").enabled("merge"))
  end)

  it("registers its actions when on", function()
    require("org.config").opts.extensions.merge = { prefer = "ours" }
    require("org.extensions").setup()
    ok(require("org.actions").list.merge_install)
    ok(require("org.actions").list.merge_uninstall)
    eq("ours", require("org.extensions").opts("merge").prefer)
    eq("org", require("org.extensions").opts("merge").driver_name)
  end)

  it("builds the driver command without the options, which go to the git config", function()
    local ext = require("org.extensions.merge")
    local o = vim.tbl_extend("force", ext.defaults, { prefer = "theirs", sort_logbook = false })
    local cmd = ext.driver_command(o)
    ok(cmd:find("driver.lua", 1, true))
    ok(not cmd:find("--prefer", 1, true))
    ok(cmd:find("--name=org", 1, true))
    ok(cmd:find("--marker-size=%L --base-label=%S --ours-label=%X --theirs-label=%Y %O %A %B %P", 1, true))
    local values = {}
    for _, kv in ipairs(ext.config_values(o)) do
      values[kv[1]] = kv[2]
    end
    eq({ "theirs" }, values.prefer)
    eq({ "false" }, values.sortLogbook)
  end)

  it("passes custom TODO keywords to the driver", function()
    local ext = require("org.extensions.merge")
    local config = require("org.config").opts
    local saved = config.todo_keywords
    config.todo_keywords = { "TODO NEXT | DONE" }
    local values = ext.config_values(ext.defaults)
    config.todo_keywords = saved
    local todo
    for _, kv in ipairs(values) do
      if kv[1] == "todo" then
        todo = kv[2]
      end
    end
    eq({ "TODO NEXT | DONE" }, todo)
  end)
end)

describe("merge extension: git", function()
  if vim.fn.executable("git") == 0 then
    return
  end
  local ext = require("org.extensions.merge")

  local function git(dir, ...)
    local cmd = {
      "git",
      "-c",
      "user.name=T",
      "-c",
      "user.email=t@example.com",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "merge.conflictStyle=merge",
    }
    return run(vim.list_extend(cmd, { ... }), dir)
  end

  local function repo()
    local dir = tmpdir()
    git(dir, "init", "-q", "-b", "main")
    return dir
  end

  it("installs and uninstalls through merge_install, asking where", function()
    local dir = repo()
    local select, notify = vim.ui.select, vim.notify
    local asked, msg
    vim.ui.select = function(items, _, cb)
      asked = #items
      cb(items[1])
    end
    vim.notify = function(m)
      msg = m
    end
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, dir .. "/notes.org")
    vim.api.nvim_set_current_buf(buf)
    local okc, err = pcall(ext.install)
    vim.ui.select, vim.notify = select, notify
    ok(okc, err)
    eq(2, asked)
    ok(msg:find("installed", 1, true))
    eq({ "*.org merge=org" }, vim.fn.readfile(dir .. "/.gitattributes"))
    local _, drv = git(dir, "config", "--get", "merge.org.driver")
    ok(drv:find("driver.lua", 1, true))
    -- a second install does not add the line again
    ext.install_at(dir, "gitattributes", ext.defaults)
    eq({ "*.org merge=org" }, vim.fn.readfile(dir .. "/.gitattributes"))
    ext.uninstall_at(dir, ext.defaults)
    eq({}, vim.fn.readfile(dir .. "/.gitattributes"))
    local code = git(dir, "config", "--get", "merge.org.driver")
    eq(1, code)
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(dir, "rf")
  end)

  it("does nothing when the choice is cancelled", function()
    local dir = repo()
    local select = vim.ui.select
    vim.ui.select = function(_, _, cb)
      cb(nil)
    end
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, dir .. "/notes.org")
    vim.api.nvim_set_current_buf(buf)
    pcall(ext.install)
    vim.ui.select = select
    eq(0, vim.fn.filereadable(dir .. "/.gitattributes"))
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(dir, "rf")
  end)

  it("installs into .git/info/attributes", function()
    local dir = repo()
    local okc = ext.install_at(dir, "info", ext.defaults)
    ok(okc)
    eq(0, vim.fn.filereadable(dir .. "/.gitattributes"))
    eq({ "*.org merge=org" }, vim.fn.readfile(dir .. "/.git/info/attributes"))
    vim.fn.delete(dir, "rf")
  end)

  it("is used by git merge", function()
    local dir = repo()
    local d = fixtures .. "/clean/"
    vim.fn.writefile(vim.fn.readfile(d .. "base.org", "b"), dir .. "/tasks.org", "b")
    ok(ext.install_at(dir, "info", ext.defaults))
    git(dir, "add", "tasks.org")
    git(dir, "commit", "-q", "-m", "base")
    git(dir, "checkout", "-q", "-b", "topic")
    vim.fn.writefile(vim.fn.readfile(d .. "theirs.org", "b"), dir .. "/tasks.org", "b")
    git(dir, "commit", "-q", "-am", "theirs")
    git(dir, "checkout", "-q", "main")
    vim.fn.writefile(vim.fn.readfile(d .. "ours.org", "b"), dir .. "/tasks.org", "b")
    git(dir, "commit", "-q", "-am", "ours")
    local code, out, err = git(dir, "merge", "--no-edit", "topic")
    eq(0, code, out .. err)
    eq(vim.fn.readfile(d .. "expected.org", "b"), vim.fn.readfile(dir .. "/tasks.org", "b"))
    vim.fn.delete(dir, "rf")
  end)

  it("leaves one scoped conflict for git to report", function()
    local dir = repo()
    local d = fixtures .. "/refile/"
    vim.fn.writefile(vim.fn.readfile(d .. "base.org", "b"), dir .. "/tasks.org", "b")
    ok(ext.install_at(dir, "info", ext.defaults))
    git(dir, "add", "tasks.org")
    git(dir, "commit", "-q", "-m", "base")
    git(dir, "checkout", "-q", "-b", "topic")
    vim.fn.writefile(vim.fn.readfile(d .. "theirs.org", "b"), dir .. "/tasks.org", "b")
    git(dir, "commit", "-q", "-am", "theirs")
    git(dir, "checkout", "-q", "main")
    vim.fn.writefile(vim.fn.readfile(d .. "ours.org", "b"), dir .. "/tasks.org", "b")
    git(dir, "commit", "-q", "-am", "ours")
    local code = git(dir, "merge", "--no-edit", "topic")
    eq(1, code)
    local lines = vim.fn.readfile(dir .. "/tasks.org")
    ok(has_markers(lines))
    -- git passes the branch names as labels (%X, %Y) since 2.44
    local expected = vim.fn.readfile(d .. "expected.org")
    if vim.tbl_contains(lines, "<<<<<<< HEAD") then
      expected = vim.tbl_map(function(l)
        return l == "<<<<<<< ours" and "<<<<<<< HEAD" or l == ">>>>>>> theirs" and ">>>>>>> topic" or l
      end, expected)
    end
    eq(expected, lines)
    local _, status = git(dir, "status", "--porcelain")
    ok(status:find("UU tasks.org", 1, true))
    vim.fn.delete(dir, "rf")
  end)
end)

-- org.marks (positions that follow edits) and the capture, refile and
-- archive code that tracks entries with it.
local marks = require("org.marks")
local config = require("org.config")
local utils = require("org.utils")
vim.g.org_test = true

local function set(buf, s, e, lines)
  vim.api.nvim_buf_set_lines(buf, s, e, false, lines)
end

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function run(fn, ...)
  local res
  local args = { ... }
  ok(
    utils.run(function()
      res = { fn(unpack(args)) }
    end),
    "coroutine did not finish"
  )
  return unpack(res or {})
end

local function line(buf, lnum)
  return vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
end

describe("org.marks", function()
  it("follows a line through insertions above, below and rewrites of the line", function()
    local buf = org_buffer({ "* A", "* B", "* C" })
    local m = marks.set(buf, 2)
    set(buf, 1, 1, { "x", "y" }) -- right above
    eq(4, m:lnum())
    set(buf, 4, 4, { "z" }) -- right below
    eq(4, m:lnum())
    set(buf, 3, 4, { "* B rewritten" }) -- the line itself
    eq(4, m:lnum())
    set(buf, 0, 2, {})
    eq(2, m:lnum())
    eq("* B rewritten", line(buf, m:lnum()))
    m:del()
    m:del()
    eq(nil, m:lnum())
  end)

  it("follows an empty line too", function()
    local buf = org_buffer({ "a", "", "b" })
    local m = marks.set(buf, 2)
    set(buf, 1, 1, { "x" })
    eq(3, m:lnum())
    m:del()
  end)

  it("keeps a column with the chosen gravity, and can turn invalid", function()
    local buf = org_buffer({ "abcdef" })
    local left = marks.set(buf, 1, 3)
    local right = marks.set(buf, 1, 3, { gravity = "right" })
    vim.api.nvim_buf_set_text(buf, 0, 3, 0, 3, { "XX" })
    eq({ 1, 3, false }, { left:pos() })
    eq({ 1, 5, false }, { right:pos() })
    local inv = marks.set(buf, 1, nil, { invalidate = true })
    set(buf, 0, 1, { "other" })
    eq(nil, inv:lnum())
    local _, _, invalid = inv:pos()
    eq(true, invalid)
    marks.del(left, right, inv)
  end)

  it("follows a range of lines; lines next to it stay outside unless it grows", function()
    local buf = org_buffer({ "* A", "* S", "  body", "* C" })
    local r = marks.range(buf, 2, 3)
    local g = marks.range(buf, 2, 3, { grow = true })
    set(buf, 1, 1, { "above" })
    eq({ 3, 4 }, { r:rows() })
    eq({ 2, 4 }, { g:rows() })
    set(buf, 4, 4, { "below" })
    eq({ 3, 4 }, { r:rows() })
    eq({ 2, 5 }, { g:rows() })
    set(buf, 3, 3, { "inside" })
    eq({ 3, 5 }, { r:rows() })
    eq({ "* S", "inside", "  body" }, r:lines())
    set(buf, 2, 5, {})
    eq(nil, r:rows())
    marks.del(r, g)
  end)

  it("reaches the end of the buffer", function()
    local buf = org_buffer({ "* A", "* S", "  last" })
    local r = marks.range(buf, 2, 3)
    set(buf, 3, 3, { "appended" })
    eq({ 2, 3 }, { r:rows() })
    r:del()
  end)

  it("reports positions that don't exist and gone buffers", function()
    local buf = org_buffer({ "* A" })
    local m, err = marks.set(buf, 5)
    eq(nil, m)
    ok(err:match("outside"), err)
    eq(nil, (marks.set(-1, 1)))
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "a", "b" })
    m = marks.set(scratch, 2)
    vim.api.nvim_buf_delete(scratch, { force = true })
    eq(nil, m:lnum())
    m:del()
  end)

  it("loads a file that has no buffer yet", function()
    local p = vim.fn.tempname() .. ".org"
    utils.writefile(p, { "* A", "* B" })
    eq(nil, utils.find_buffer(p))
    local m = assert(marks.in_file(p, 2))
    eq(utils.find_buffer(p), m.bufnr)
    eq("* B", line(m.bufnr, m:lnum()))
    m:del()
  end)

  it("deletes the marks of a `with` block, also when it fails", function()
    local buf = org_buffer({ "a", "b" })
    local kept
    eq(
      2,
      marks.with(function(track)
        kept = { track(buf, 2), track.range(buf, 1, 2) }
        return kept[1]:lnum()
      end)
    )
    eq(nil, kept[1]:lnum())
    eq(nil, kept[2]:rows())
    local okc, err = pcall(marks.with, function(track)
      kept = track(buf, 1)
      error("boom", 0)
    end)
    eq(false, okc)
    eq("boom", err)
    eq(nil, kept:lnum())
    eq({}, vim.api.nvim_buf_get_extmarks(buf, marks.ns, 0, -1, {}))
  end)

  it("restores saved marks after a whole-buffer restore", function()
    local buf = org_buffer({ "a", "b", "c" })
    local m = marks.set(buf, 3)
    local saved = { m:save() }
    local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    set(buf, 0, -1, { "x" })
    utils.restore_buffer(buf, before, false)
    marks.restore(saved)
    eq(3, m:lnum())
    m:del()
  end)
end)

describe("refile in the same file", function()
  after_each(function()
    config.setup({})
  end)

  local function setup(content)
    local dir = tmpdir()
    local p = dir .. "/a.org"
    utils.writefile(p, content)
    config.setup({ org_directory = dir, agenda_files = { dir }, id = { locations_file = dir .. "/ids.json" } })
    vim.cmd("edit! " .. p)
    return vim.api.nvim_get_current_buf(), p
  end

  it("moves the entry to a target right above it", function()
    local refile = require("org.refile")
    local buf, p = setup({ "* A", "** A1", "* S", "  body", "* C" })
    local dbuf, dline = run(
      refile.refile,
      { bufnr = buf, lnum = 3 },
      { dest = { filename = p, bufnr = buf, lnum = 1, label = "A" } }
    )
    eq({ "* A", "** A1", "** S", "  body", "* C" }, buf_lines(buf))
    eq(buf, dbuf)
    eq(3, dline)
    eq(3, refile.last_stored.last_refile.lnum)
  end)

  it("moves the entry to a target after it", function()
    local refile = require("org.refile")
    local buf, p = setup({ "* S", "  body", "* A", "** A1", "* C" })
    local _, dline = run(
      refile.refile,
      { bufnr = buf, lnum = 1 },
      { dest = { filename = p, bufnr = buf, lnum = 3, label = "A" } }
    )
    eq({ "* A", "** A1", "** S", "  body", "* C" }, buf_lines(buf))
    eq(3, dline)
    eq("** S", line(buf, refile.last_stored.last_refile.lnum))
  end)

  it("moves the entry to the top of the file (prepend), above itself", function()
    local refile = require("org.refile")
    local buf, p = setup({ "#+TITLE: t", "", "* A", "* S", "  body" })
    local _, dline = run(
      refile.refile,
      { bufnr = buf, lnum = 4 },
      { dest = { filename = p, bufnr = buf, prepend = true, label = "a.org" } }
    )
    eq({ "#+TITLE: t", "", "* S", "  body", "* A" }, buf_lines(buf))
    eq(3, dline)
  end)

  it("follows the entry when creating the new parent moves it", function()
    local refile = require("org.refile")
    local buf = setup({ "* S", "  body", "* A" })
    -- a target picker that adds lines above the source, like creating a
    -- parent node at the top would
    local orig = refile.pick_target
    refile.pick_target = function()
      set(buf, 0, 0, { "* New" })
      return { filename = vim.api.nvim_buf_get_name(buf), bufnr = buf, lnum = 1, label = "New" }
    end
    local _, dline = run(refile.refile, { bufnr = buf, lnum = 1 })
    refile.pick_target = orig
    eq({ "* New", "** S", "  body", "* A" }, buf_lines(buf))
    eq(2, dline)
  end)
end)

describe("archive in the same file", function()
  after_each(function()
    config.setup({})
  end)

  it("archives to a sibling above the entry", function()
    local archive = require("org.archive")
    config.setup({ tags_column = 0 })
    local buf = org_buffer({ "* P", "** Archive :ARCHIVE:", "*** Old", "** DONE A", "   text", "** B" }, { 4, 0 })
    local sib = archive.archive_to_sibling()
    local l = buf_lines(buf)
    eq(2, sib)
    eq("** Archive :ARCHIVE:", l[sib])
    eq("*** DONE A", l[4])
    eq("** B", l[#l])
    eq(0, #vim.tbl_filter(function(x)
      return x:match("^%*%* DONE A") ~= nil
    end, l))
    -- the cursor is where the entry was
    eq("** B", line(buf, vim.fn.line(".")))
  end)

  it("archives to a sibling below the entry", function()
    local archive = require("org.archive")
    config.setup({ tags_column = 0 })
    local buf = org_buffer({ "* P", "** DONE A", "   text", "** Archive :ARCHIVE:", "*** Old", "** B" }, { 2, 0 })
    local sib = archive.archive_to_sibling()
    local l = buf_lines(buf)
    eq(2, sib)
    eq("** Archive :ARCHIVE:", l[2])
    eq("*** Old", l[3])
    eq("*** DONE A", l[4])
    eq("** B", l[#l])
  end)

  local function archive_in_file(content, src, extra)
    local archive = require("org.archive")
    local dir = tmpdir()
    config.setup(vim.tbl_extend("force", {
      org_directory = dir,
      agenda_files = { dir },
      archive_location = "::* Archived",
      archive_save_context_info = {},
      id = { locations_file = dir .. "/ids.json" },
    }, extra or {}))
    local p = dir .. "/s.org"
    utils.writefile(p, content)
    vim.cmd("edit! " .. p)
    vim.api.nvim_win_set_cursor(0, { src, 0 })
    archive.archive_subtree()
    return buf_lines()
  end

  it("archives under a heading above the entry", function()
    local l = archive_in_file({ "* Archived", "* DONE S", "  body", "* T" }, 2)
    eq({ "* Archived", "", "** DONE S", "  body", "* T" }, l)
  end)

  it("archives under a heading below the entry", function()
    local l = archive_in_file({ "* DONE S", "  body", "* T", "* Archived" }, 1)
    eq({ "* T", "* Archived", "", "** DONE S", "  body" }, l)
  end)

  it("asks about the candidates in buffer order and follows them while archiving", function()
    local archive = require("org.archive")
    local dir = tmpdir()
    config.setup({
      org_directory = dir,
      agenda_files = { dir },
      archive_location = "::* Archived",
      archive_reversed_order = true,
      archive_save_context_info = {},
      id = { locations_file = dir .. "/ids.json" },
    })
    local p = dir .. "/s.org"
    utils.writefile(p, { "* P", "** DONE x", "** TODO y", "** DONE x", "   second", "* Archived" })
    vim.cmd("edit! " .. p)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local asked = {}
    local n = archive.archive_all_done({
      confirm = function(hl)
        asked[#asked + 1] = hl.line
        return true
      end,
    })
    eq(2, n)
    eq({ 2, 3 }, asked)
    -- reversed order: the later entry ends up first
    eq({ "* P", "** TODO y", "* Archived", "", "** DONE x", "   second", "** DONE x" }, buf_lines())
  end)
end)

describe("capture into an open, modified buffer", function()
  after_each(function()
    config.setup({})
  end)

  it("stores where the entry is after the hooks edited the target", function()
    local capture = require("org.capture")
    local refile = require("org.refile")
    config.setup({})
    local p = vim.fn.tempname() .. ".org"
    utils.writefile(p, { "* Inbox", "** Old" })
    vim.cmd("edit! " .. p)
    local tbuf = vim.api.nvim_get_current_buf()
    -- unsaved edits above the target
    set(tbuf, 0, 0, { "#+TITLE: t", "" })
    ok(vim.bo[tbuf].modified)
    local dbuf, dline = run(capture.capture, {
      target = p,
      headline = "Inbox",
      template = "* New",
      immediate_finish = true,
      before_finalize = function(b)
        set(b, 0, 0, { "# added by a hook" })
      end,
    })
    eq(tbuf, dbuf)
    eq({ "# added by a hook", "#+TITLE: t", "", "* Inbox", "** Old", "** New" }, buf_lines(tbuf))
    eq(6, dline)
    eq(6, refile.last_stored.last_capture.lnum)
    eq(buf_lines(tbuf), utils.readfile(p))
  end)

  it("follows the capture text when the target is edited during the capture", function()
    local capture = require("org.capture")
    config.setup({})
    local p = vim.fn.tempname() .. ".org"
    utils.writefile(p, { "* A", "* Inbox", "** Old" })
    vim.cmd("edit! " .. p)
    local tbuf = vim.api.nvim_get_current_buf()
    local cbuf = run(capture.capture, { target = p, headline = "Inbox", template = "* %?" })
    set(cbuf, 0, -1, { "* Captured" })
    -- the target buffer gets edits while the capture buffer is open
    set(tbuf, 1, 1, { "** under A", "** and more" })
    set(tbuf, 0, 1, { "* A edited" })
    local _, dline = run(capture.finalize, cbuf, { jump = false })
    eq({ "* A edited", "** under A", "** and more", "* Inbox", "** Old", "** Captured" }, buf_lines(tbuf))
    eq(6, dline)
  end)

  it("reports the line of a non-entry capture after clocking moved it", function()
    local capture = require("org.capture")
    local clock = require("org.clock")
    config.setup({})
    local p = vim.fn.tempname() .. ".org"
    utils.writefile(p, { "* Inbox", "first note" })
    local dbuf, dline = run(capture.capture, {
      target = p,
      headline = "Inbox",
      type = "plain",
      template = "clocked note",
      clock_in = true,
      immediate_finish = true,
    })
    pcall(clock.clock_cancel)
    eq("clocked note", line(dbuf, dline))
    eq("clocked note", line(dbuf, require("org.refile").last_stored.last_capture.lnum))
  end)
end)

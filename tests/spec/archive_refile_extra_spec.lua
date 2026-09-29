-- org-archive-default-command, org-archive-subtree-save-file-p and
-- org-refile-reverse.
local archive = require("org.archive")
local refile = require("org.refile")
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
end

describe("archive_default_command (org-archive-default-command)", function()
  it("archives the subtree by default", function()
    local dir = tmpdir()
    setup(dir)
    local p = dir .. "/s.org"
    utils.writefile(p, { "* A", "* B" })
    vim.cmd("edit! " .. p)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    archive.archive_subtree_default()
    eq({ "* B" }, buf_lines())
  end)

  it("sets the ARCHIVE tag with set_tag, without toggling it off", function()
    setup(tmpdir(), { archive_default_command = "set_tag" })
    local buf = org_buffer({ "* A", "* B" }, { 1, 0 })
    archive.archive_subtree_default()
    ok(buf_lines(buf)[1]:match("^%* A%s+:ARCHIVE:$"))
    archive.archive_subtree_default()
    ok(buf_lines(buf)[1]:match("^%* A%s+:ARCHIVE:$"))
  end)

  it("moves to the archive sibling with archive_to_sibling", function()
    setup(tmpdir(), { archive_default_command = "archive_to_sibling" })
    local buf = org_buffer({ "* P", "** A", "** B" }, { 2, 0 })
    archive.archive_subtree_default()
    local l = buf_lines(buf)
    eq("** B", l[2])
    ok(l[3]:match("^%*%* Archive%s+:ARCHIVE:$"))
    eq("*** A", l[4])
  end)

  it("calls a function", function()
    local got
    setup(tmpdir(), {
      archive_default_command = function(target)
        got = target == nil and "cursor" or target
      end,
    })
    org_buffer({ "* A" }, { 1, 0 })
    archive.archive_subtree_default()
    eq("cursor", got)
  end)
end)

describe("archive_subtree_save_file (org-archive-subtree-save-file-p)", function()
  local function run_case(value, from_agenda)
    local dir = vim.uv.fs_realpath(tmpdir())
    setup(dir, { archive_subtree_save_file = value, archive_location = "arch.org::" })
    local p = dir .. "/s.org"
    utils.writefile(p, { "* A", "* B" })
    vim.cmd("edit! " .. p)
    archive.archive_subtree({ bufnr = vim.api.nvim_get_current_buf(), lnum = 1 }, { from_agenda = from_agenda })
    local apath = archive.parse_location("arch.org::", vim.fs.normalize(p)).filename
    local abuf = utils.find_buffer(apath)
    ok(abuf)
    eq("* A", vim.api.nvim_buf_get_lines(abuf, -2, -1, false)[1])
    return vim.fn.filereadable(apath) == 1 and not vim.bo[abuf].modified
  end

  it("saves from Org buffers but not from the agenda by default", function()
    eq(true, run_case(nil, false))
    eq(false, run_case(nil, true))
  end)

  it("follows true, false and from_agenda", function()
    eq(true, run_case(true, true))
    eq(false, run_case(false, false))
    eq(false, run_case("from_agenda", false))
    eq(true, run_case("from_agenda", true))
  end)
end)

describe("refile_reverse (org-refile-reverse)", function()
  -- expected buffers from Emacs 9.8.10 (org-refile-reverse with rfloc "A")
  local function run_case(reversed)
    local dir = tmpdir()
    setup(dir, { refile = { reverse_note_order = reversed } })
    local p = dir .. "/r.org"
    utils.writefile(p, { "* A", "** a1", "** a2", "* B", "body" })
    vim.cmd("edit! " .. p)
    local buf = vim.api.nvim_get_current_buf()
    refile.refile_reverse(
      { bufnr = buf, lnum = 4 },
      { dest = { filename = vim.fs.normalize(p), bufnr = buf, lnum = 1, olp = { "A" }, label = "A" } }
    )
    return buf_lines(buf)
  end

  it("prepends when reverse_note_order is off", function()
    eq({ "* A", "** B", "body", "** a1", "** a2" }, run_case(false))
  end)

  it("appends when reverse_note_order is on", function()
    eq({ "* A", "** a1", "** a2", "** B", "body" }, run_case(true))
  end)
end)

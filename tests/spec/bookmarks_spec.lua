-- Bookmarks set by capture and refile (org-bookmark-names-plist), which
-- survive the session like Emacs's bookmark file.
local config = require("org.config")
local utils = require("org.utils")
local bookmarks = require("org.bookmarks")
local refile = require("org.refile")
vim.g.org_test = true

local json = vim.fn.stdpath("data") .. "/org/bookmarks.json"

describe("bookmarks", function()
  local dir, file
  before_each(function()
    dir = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname()))
    vim.fn.mkdir(dir, "p")
    file = dir .. "/t.org"
    vim.fn.writefile({ "* A", "* B", "* C" }, file)
    vim.fn.delete(json)
  end)
  after_each(function()
    vim.cmd("silent! enew!")
    refile.last_stored = nil
    config.opts.bookmark_names = {
      last_capture = "org-capture-last-stored",
      last_refile = "org-refile-last-stored",
      last_capture_marker = "org-capture-last-stored-marker",
    }
    vim.fn.delete(json)
    vim.fn.delete(dir, "rf")
  end)

  it("refile and capture locations are saved under their names", function()
    vim.cmd("silent edit! " .. vim.fn.fnameescape(file))
    local buf = vim.api.nvim_get_current_buf()
    refile.remember(buf, 2, "last_refile")
    refile.remember(buf, 3, "last_capture")
    local data = vim.json.decode(table.concat(vim.fn.readfile(json), "\n"))
    eq({ filename = file, lnum = 2, raw = "* B" }, data["org-refile-last-stored"])
    eq({ filename = file, lnum = 3, raw = "* C" }, data["org-capture-last-stored"])
  end)

  it("goto_last_stored uses them in a new session", function()
    vim.cmd("silent edit! " .. vim.fn.fnameescape(file))
    local buf = vim.api.nvim_get_current_buf()
    refile.remember(buf, 2, "last_refile")
    refile.remember(buf, 3, "last_capture")
    vim.cmd("silent bwipeout!")
    vim.cmd("silent enew!")
    refile.last_stored = nil -- a new session
    refile.goto_last_stored()
    eq(file, vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
    eq(2, vim.api.nvim_win_get_cursor(0)[1])
    require("org.capture").goto_last_stored()
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("follows the entry when it moved", function()
    vim.cmd("silent edit! " .. vim.fn.fnameescape(file))
    local buf = vim.api.nvim_get_current_buf()
    refile.remember(buf, 2, "last_refile")
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "#+TITLE: x" })
    vim.cmd("silent write")
    refile.last_stored = nil
    vim.cmd("silent enew!")
    refile.goto_last_stored()
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("a name set to false sets no bookmark", function()
    config.opts.bookmark_names.last_refile = false
    vim.cmd("silent edit! " .. vim.fn.fnameescape(file))
    refile.remember(vim.api.nvim_get_current_buf(), 2, "last_refile")
    eq(0, vim.fn.filereadable(json))
  end)

  it("bookmark_jump picks one", function()
    vim.cmd("silent edit! " .. vim.fn.fnameescape(file))
    local buf = vim.api.nvim_get_current_buf()
    bookmarks.set("last_refile", buf, 3)
    vim.cmd("silent enew!")
    local seen
    local orig = utils.select
    utils.select = function(items, opts)
      seen = vim.tbl_map(opts.format_item, items)
      return items[1]
    end
    local ok_, err = pcall(bookmarks.jump)
    utils.select = orig
    assert(ok_, err)
    eq(1, #seen)
    ok(seen[1]:find("^org%-refile%-last%-stored  "), seen[1])
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
  end)
end)

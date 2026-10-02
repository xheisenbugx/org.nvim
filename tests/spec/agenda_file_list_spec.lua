-- Saved changes of the agenda file list: org-agenda-file-to-front,
-- org-remove-file and org-edit-agenda-file-list (Emacs Org 9.8.10 rewrites
-- the list file, or saves org-agenda-files with Customize).
local config = require("org.config")
local files = require("org.files")
vim.g.org_test = true

local saved_json = vim.fn.stdpath("data") .. "/org/agenda-files.json"

local function quiet(body)
  local msgs = {}
  local orig = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = m
  end
  local ok_, err = pcall(body)
  vim.notify = orig
  if not ok_ then
    error(err, 0)
  end
  return msgs
end

describe("agenda file list", function()
  local dir, a, b, c, saved
  before_each(function()
    saved = config.opts.agenda_files
    dir = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname()))
    vim.fn.mkdir(dir, "p")
    a, b, c = dir .. "/a.org", dir .. "/b.org", dir .. "/c.org"
    for _, f in ipairs({ a, b, c }) do
      vim.fn.writefile({ "* x" }, f)
    end
  end)
  after_each(function()
    vim.cmd("silent! enew!")
    config.opts.agenda_files = saved
    files._configured = nil
    vim.fn.delete(saved_json)
    vim.fn.delete(dir, "rf")
  end)

  local function visit(path)
    vim.cmd("silent edit! " .. vim.fn.fnameescape(path))
  end

  it("rewrites a list file, keeping its entries as written", function()
    local list = dir .. "/agenda-list"
    vim.fn.writefile({ a, b }, list)
    config.opts.agenda_files = list
    visit(c)
    -- messages and file contents: Emacs 9.8.10
    local msgs = quiet(function()
      files.agenda_file_to_front()
    end)
    eq("File added to front of agenda file list", msgs[1])
    eq({ require("org.utils").abbreviate(c), a, b }, vim.fn.readfile(list))
    msgs = quiet(function()
      files.remove_file()
    end)
    eq("Removed from Org Agenda list: " .. require("org.utils").abbreviate(c), msgs[1])
    eq({ a, b }, vim.fn.readfile(list))
    msgs = quiet(function()
      files.remove_file()
    end)
    eq("File was not in list: " .. require("org.utils").abbreviate(c) .. " (not removed)", msgs[1])
  end)

  it("expands a directory and saves the list", function()
    config.opts.agenda_files = { dir }
    files._configured = { dir }
    visit(b)
    quiet(function()
      files.remove_file()
    end)
    eq(
      vim.tbl_map(require("org.utils").abbreviate, { a, c }),
      vim.tbl_map(require("org.utils").abbreviate, config.opts.agenda_files)
    )
    quiet(function()
      files.agenda_file_to_front()
    end)
    -- Emacs 9.8.10: ("b.org" "a.org" "c.org")
    eq(
      vim.tbl_map(require("org.utils").abbreviate, { b, a, c }),
      vim.tbl_map(require("org.utils").abbreviate, config.opts.agenda_files)
    )
    local json = vim.json.decode(table.concat(vim.fn.readfile(saved_json), "\n"))
    eq(
      vim.tbl_map(require("org.utils").abbreviate, { b, a, c }),
      vim.tbl_map(require("org.utils").abbreviate, json.files)
    )
    eq({ dir }, json.configured)
    -- setup() with the same configured value restores the saved list
    config.opts.agenda_files = { dir }
    files.load_saved_agenda_files()
    eq(
      vim.tbl_map(require("org.utils").abbreviate, { b, a, c }),
      vim.tbl_map(require("org.utils").abbreviate, config.opts.agenda_files)
    )
    -- a changed configuration wins
    config.opts.agenda_files = { a }
    files.load_saved_agenda_files()
    eq({ a }, config.opts.agenda_files)
  end)

  it("moves to the end with a count", function()
    config.opts.agenda_files = { a, b, c }
    visit(a)
    local msgs = quiet(function()
      -- C-u C-c [
      vim.api.nvim_feedkeys(vim.keycode("4<C-c>["), "xt", false)
    end)
    eq({ b, c, a }, config.opts.agenda_files)
    ok(vim.tbl_contains(msgs, "File moved to end of agenda file list"))
  end)

  it("edit_agenda_file_list edits the list file; :w installs it", function()
    local list = dir .. "/agenda-list"
    vim.fn.writefile({ a }, list)
    config.opts.agenda_files = list
    visit(c)
    quiet(function()
      files.edit_agenda_file_list()
    end)
    eq(list, vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { a, b })
    local msgs = quiet(function()
      vim.cmd("silent write")
      vim.wait(100, function()
        return vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == c
      end)
    end)
    eq(c, vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
    ok(vim.tbl_contains(msgs, "New agenda file list installed"))
    eq({ a, b }, files.agenda_file_paths())
  end)

  it("edit_agenda_file_list edits a configured list in a scratch buffer", function()
    config.opts.agenda_files = { a }
    visit(c)
    quiet(function()
      files.edit_agenda_file_list()
    end)
    eq({ a }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { b, "", c })
    quiet(function()
      vim.cmd("silent write")
      vim.wait(100, function()
        return vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == c
      end)
    end)
    eq({ b, c }, config.opts.agenda_files)
    eq(c, vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
  end)
end)

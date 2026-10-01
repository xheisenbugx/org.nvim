---@mod org.bookmarks Named bookmarks set by capture and refile
---
--- Like Emacs's bookmarks named by org-bookmark-names-plist: the last
--- capture ("org-capture-last-stored") and the last refile
--- ("org-refile-last-stored") are saved in stdpath("data")/org/bookmarks.json,
--- so capture_goto_last / refile_goto_last (C-u C-u C-c c / C-c C-w) work
--- in a later session and `bookmark_jump` jumps to any of them.

local config = require("org.config")
local utils = require("org.utils")

local M = {}

local function path()
  return vim.fn.stdpath("data") .. "/org/bookmarks.json"
end

---@return table<string, { filename: string, lnum: integer, raw: string }>
local function read()
  local data = utils.read_json(path())
  return type(data) == "table" and data or {}
end

--- The bookmark name for `key` ("last_capture", "last_refile",
--- "last_capture_marker"), or nil when it is not set.
function M.name(key)
  local names = config.opts.bookmark_names or {}
  local n = names[key]
  return type(n) == "string" and n ~= "" and n or nil
end

--- Set the bookmark `key` to line `lnum` of `bufnr` (bookmark-set).
function M.set(key, bufnr, lnum)
  local name = M.name(key)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if not name or file == "" then
    return
  end
  local data = read()
  data[name] = {
    filename = vim.fs.normalize(file),
    lnum = lnum,
    raw = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or "",
  }
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(path(), ":h"), "p")
  pcall(utils.write_json, path(), data)
end

--- The bookmark named `name`.
function M.get(name)
  return name and read()[name] or nil
end

--- Go to a location { bufnr?, filename?, lnum, raw }: the line with the
--- same text when it moved.
function M.goto_location(l)
  local bufnr = l.bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    bufnr = l.filename and utils.load_buffer(l.filename) or nil
  end
  if not bufnr then
    utils.warn("The last stored location is gone")
    return false
  end
  local lnum = l.lnum
  if vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] ~= l.raw then
    for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if line == l.raw then
        lnum = i
        break
      end
    end
  end
  vim.cmd("normal! m'")
  if vim.api.nvim_buf_get_name(bufnr) ~= "" then
    utils.open_file(vim.api.nvim_buf_get_name(bufnr), lnum)
  else
    vim.api.nvim_set_current_buf(bufnr)
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
  end
  return true
end

--- bookmark-jump for the org bookmarks.
function M.jump()
  local data = read()
  local names = vim.tbl_keys(data)
  table.sort(names)
  if #names == 0 then
    utils.warn("No bookmarks")
    return
  end
  local name = utils.select(names, {
    prompt = "Jump to bookmark",
    format_item = function(n)
      return n .. "  " .. utils.abbreviate(data[n].filename) .. ":" .. data[n].lnum
    end,
  })
  if name then
    M.goto_location(data[name])
  end
end

return M

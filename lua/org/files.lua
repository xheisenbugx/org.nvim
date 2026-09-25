---@mod org.files Loading and caching org files
---
--- Files are parsed from their loaded buffer when one exists (so unsaved
--- edits are visible to the agenda), otherwise from disk. Results are cached
--- by buffer changedtick / file mtime.

local parser = require("org.parser")
local utils = require("org.utils")

local M = {}

local disk_cache = {} -- path -> { mtime, file }
local buf_cache = {} -- bufnr -> { tick, file, todo_spec }

--- Parse a buffer (cached by changedtick).
---@param bufnr? integer
---@return org.File
function M.get_buffer(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local spec = require("org.config").opts.todo_keywords
  local c = buf_cache[bufnr]
  if c and c.tick == tick and c.todo_spec == spec then
    return c.file
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local file = parser.parse(lines, name ~= "" and vim.fs.normalize(name) or nil)
  file.bufnr = bufnr
  buf_cache[bufnr] = { tick = tick, file = file, todo_spec = spec }
  return file
end

--- Parse a file by path, preferring its loaded buffer.
---@param path string
---@return org.File|nil
function M.get(path)
  path = utils.expand(path)
  local b = utils.find_buffer(path)
  if b then
    return M.get_buffer(b)
  end
  local mtime = utils.mtime(path)
  if not mtime then
    return nil
  end
  local spec = require("org.config").opts.todo_keywords
  local c = disk_cache[path]
  if c and c.mtime == mtime and c.todo_spec == spec then
    return c.file
  end
  local lines = utils.readfile(path)
  if not lines then
    return nil
  end
  local file = parser.parse(lines, path)
  disk_cache[path] = { mtime = mtime, file = file, todo_spec = spec }
  return file
end

function M.invalidate(path)
  if path then
    disk_cache[vim.fs.normalize(path)] = nil
  else
    disk_cache = {}
  end
end

--- Files removed from the agenda for this session (`remove_file`), even
--- when a directory or glob in `agenda_files` still matches them.
---@type table<string, boolean>
M.removed = {}

--- Absolute paths of all agenda files.
---@param extra? string[] additional patterns
---@return string[]
function M.agenda_file_paths(extra)
  local cfg = require("org.config").opts
  local patterns = vim.deepcopy(cfg.agenda_files or {})
  if type(patterns) == "string" then
    patterns = { patterns }
  end
  for _, p in ipairs(extra or {}) do
    patterns[#patterns + 1] = p
  end
  local paths = utils.glob_org_files(patterns)
  if next(M.removed) then
    paths = vim.tbl_filter(function(p)
      return not M.removed[p]
    end, paths)
  end
  return paths
end

local function current_path()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or not utils.is_org() then
    utils.warn("Buffer is not visiting an org file")
    return nil
  end
  return vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
end

local function pattern_list()
  local cfg = require("org.config").opts
  local list = cfg.agenda_files or {}
  if type(list) == "string" then
    list = { list }
  end
  cfg.agenda_files = list
  return list
end

local function same_path(pattern, path)
  return type(pattern) == "string" and vim.fs.normalize(utils.expand(pattern)) == path
end

--- Add the current file to the front of the agenda files, or move it there
--- (org-agenda-file-to-front). Only affects this session.
function M.agenda_file_to_front()
  local path = current_path()
  if not path then
    return nil
  end
  local list = pattern_list()
  local moved = false
  for i = #list, 1, -1 do
    if same_path(list[i], path) then
      table.remove(list, i)
      moved = true
    end
  end
  moved = moved or (not M.removed[path] and vim.tbl_contains(M.agenda_file_paths(), path))
  M.removed[path] = nil
  table.insert(list, 1, path)
  utils.notify((moved and "Moved " or "Added ") .. vim.fn.fnamemodify(path, ":~") .. " to front of agenda file list")
  return true
end

--- Remove the current file from the agenda files (org-remove-file). Only
--- affects this session.
function M.remove_file()
  local path = current_path()
  if not path then
    return nil
  end
  if not vim.tbl_contains(M.agenda_file_paths(), path) then
    utils.notify("File was not in list: " .. vim.fn.fnamemodify(path, ":~") .. " (not removed)")
    return true
  end
  local list = pattern_list()
  for i = #list, 1, -1 do
    if same_path(list[i], path) then
      table.remove(list, i)
    end
  end
  M.removed[path] = true
  utils.notify("Removed from Org Agenda list: " .. vim.fn.fnamemodify(path, ":~"))
  return true
end

--- Parsed agenda files (`agenda_files` config plus `extra` patterns).
---
--- ```lua
--- for _, file in ipairs(require("org.files").agenda_files()) do
---   print(file.filename, #file.headlines)
--- end
--- ```
---@param extra? string[] additional file paths / glob patterns
---@return org.File[]
function M.agenda_files(extra)
  local out = {}
  for _, path in ipairs(M.agenda_file_paths(extra)) do
    local f = M.get(path)
    if f then
      out[#out + 1] = f
    end
  end
  return out
end

--- Agenda files plus the current buffer if it is an org file.
function M.agenda_files_with_current()
  local files = M.agenda_files()
  if utils.is_org() then
    local cur = M.get_buffer(0)
    local found = false
    for _, f in ipairs(files) do
      if f.filename and cur.filename and f.filename == cur.filename then
        found = true
      end
    end
    if not found then
      table.insert(files, 1, cur)
    end
  end
  return files
end

vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
  group = utils.augroup,
  pattern = { "*.org", "*.org_archive" },
  callback = function(ev)
    M.invalidate(vim.api.nvim_buf_get_name(ev.buf))
  end,
})

vim.api.nvim_create_autocmd("BufWipeout", {
  group = utils.augroup,
  callback = function(ev)
    buf_cache[ev.buf] = nil
  end,
})

return M

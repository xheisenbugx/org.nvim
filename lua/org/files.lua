---@mod org.files Loading and caching org files
---
--- Files are parsed from their loaded buffer when one exists (so unsaved
--- edits are visible to the agenda), otherwise from disk. Results are cached
--- by buffer changedtick / file mtime.

local parser = require("org.parser")
local keywords = require("org.keywords")
local utils = require("org.utils")

local M = {}

local disk_cache = {} -- path -> { mtime, file }
local buf_cache = {} -- bufnr -> { tick, name, cwd, file, todo_spec }

--- Parse a buffer (cached by changedtick).
---@param bufnr? integer
---@return org.File
function M.get_buffer(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local cwd = name == "" and vim.fn.getcwd() or nil
  local spec = require("org.config").opts.todo_keywords
  local c = buf_cache[bufnr]
  -- :file / :saveas and the first :write can rename a buffer without
  -- changing its text. File-relative links and agenda locations must
  -- immediately use the new filename.
  if
    c
    and c.tick == tick
    and c.name == name
    and c.cwd == cwd
    and c.todo_spec == spec
    and keywords.dependencies_valid(c.file.setup_dependencies)
  then
    return c.file
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local file = parser.parse(lines, name ~= "" and vim.fs.normalize(name) or nil)
  file.bufnr = bufnr
  buf_cache[bufnr] = { tick = tick, name = name, cwd = cwd, file = file, todo_spec = spec }
  return file
end

--- The parse of a buffer if one for its current text is cached, without
--- parsing (for redraw-time code that must stay cheap in large files).
---@param bufnr integer
---@return org.File|nil
function M.cached_buffer(bufnr)
  local c = buf_cache[bufnr]
  if c and c.tick == vim.api.nvim_buf_get_changedtick(bufnr) then
    return c.file
  end
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
  if c and c.mtime == mtime and c.todo_spec == spec and keywords.dependencies_valid(c.file.setup_dependencies) then
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

--- A readable file listing the agenda files, one per line, when
--- `agenda_files` is its name (not an org file, a glob or a directory).
---@return string|nil
local function list_file()
  local cfg = require("org.config").opts
  if type(cfg.agenda_files) ~= "string" then
    return nil
  end
  local path = utils.expand(cfg.agenda_files)
  if not path:match("%.org$") and not path:find("[%*%?%[]") and vim.fn.filereadable(path) == 1 then
    return path
  end
end

--- Entries of the agenda list file (org-read-agenda-file-list).
local function read_list_file(path)
  return vim.tbl_filter(function(l)
    return l:match("%S") ~= nil and not l:match("^%s*#")
  end, vim.fn.readfile(path))
end

--- Absolute paths of all agenda files.
---@param extra? string[] additional patterns
---@return string[]
function M.agenda_file_paths(extra)
  local cfg = require("org.config").opts
  local patterns = vim.deepcopy(cfg.agenda_files or {})
  if type(patterns) == "string" then
    local path = list_file()
    if path then
      -- like Emacs, a file that lists the agenda files, one per line
      patterns = read_list_file(path)
    else
      patterns = { patterns }
    end
  end
  for _, p in ipairs(extra or {}) do
    patterns[#patterns + 1] = p
  end
  return utils.glob_org_files(patterns)
end

---------------------------------------------------------------------------
-- Changing the agenda file list (org-agenda-file-to-front, org-remove-file,
-- org-edit-agenda-file-list). Like Emacs, changes are saved: into the list
-- file when `agenda_files` names one, else in stdpath("data") (the
-- counterpart of Customize), where they replace the configured list for
-- as long as the configuration keeps the value they were made from.
---------------------------------------------------------------------------

local function saved_list_path()
  return vim.fn.stdpath("data") .. "/org/agenda-files.json"
end

--- The configured list the saved one replaces (org-agenda-files as set in
--- setup()).
M._configured = nil

--- Replace the configured agenda file list by the saved one, if it was
--- saved from the same configured value (called by setup()).
function M.load_saved_agenda_files()
  local cfg = require("org.config").opts
  M._configured = vim.deepcopy(cfg.agenda_files)
  if list_file() then
    return
  end
  local saved = utils.read_json(saved_list_path())
  if type(saved) == "table" and type(saved.files) == "table" then
    local configured = saved.configured
    if configured == vim.NIL then
      configured = nil
    end
    if vim.deep_equal(configured, M._configured) then
      cfg.agenda_files = saved.files
    end
  end
end

--- Set and save a new agenda file list (org-store-new-agenda-file-list).
---@param list string[] file names
function M.store_agenda_file_list(list)
  local cfg = require("org.config").opts
  local path = list_file()
  if path then
    -- keep the entries as written in the file
    local written = {}
    for _, l in ipairs(read_list_file(path)) do
      written[vim.fs.normalize(utils.expand(vim.trim(l)))] = vim.trim(l)
    end
    local lines = {}
    for _, f in ipairs(list) do
      lines[#lines + 1] = written[vim.fs.normalize(utils.expand(f))] or f
    end
    local b = utils.find_buffer(path)
    if b then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    vim.fn.writefile(lines, path)
    return
  end
  if M._configured == nil then
    M._configured = vim.deepcopy(cfg.agenda_files)
  end
  cfg.agenda_files = vim.deepcopy(list)
  vim.fn.mkdir(vim.fn.fnamemodify(saved_list_path(), ":h"), "p")
  utils.write_json(saved_list_path(), { configured = M._configured or vim.NIL, files = list })
end

--- The agenda files as { path, entry } pairs: the resolved file and the
--- name to write back (org-agenda-files with directories expanded).
local function file_alist()
  local cfg = require("org.config").opts
  local entries = cfg.agenda_files or {}
  local path = list_file()
  if path then
    entries = read_list_file(path)
  elseif type(entries) == "string" then
    entries = { entries }
  end
  local out, seen = {}, {}
  for _, e in ipairs(entries) do
    local expanded = utils.expand(vim.trim(e))
    local single = not utils.is_dir(expanded) and not expanded:find("[%*%?%[]")
    for _, p in ipairs(single and { expanded } or utils.glob_org_files({ e })) do
      local key = vim.fs.normalize(vim.fn.resolve(p))
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = { key, single and e or p }
      end
    end
  end
  return out
end

local function current_path()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or vim.bo.buftype ~= "" then
    return nil
  end
  return vim.fs.normalize(vim.fn.resolve(vim.fn.fnamemodify(name, ":p")))
end

--- Add the current file to the front of the agenda files, or move it there
--- (org-agenda-file-to-front); with a count (C-u) to the end. Saved.
function M.agenda_file_to_front()
  local path = current_path()
  if not path then
    utils.warn("Please save the current buffer to a file")
    return nil
  end
  local to_end = vim.v.count > 0
  local alist = file_alist()
  local had
  for i, x in ipairs(alist) do
    if x[1] == path then
      had = table.remove(alist, i)
      break
    end
  end
  local x = had or { path, vim.fn.fnamemodify(path, ":~") }
  if to_end then
    table.insert(alist, x)
  else
    table.insert(alist, 1, x)
  end
  M.store_agenda_file_list(vim.tbl_map(function(e)
    return e[2]
  end, alist))
  utils.notify(
    string.format("File %s to %s of agenda file list", had and "moved" or "added", to_end and "end" or "front")
  )
  return true
end

--- Remove the current file from the agenda files (org-remove-file). Saved.
function M.remove_file()
  local path = current_path()
  if not path then
    utils.warn("Current buffer does not visit a file")
    return nil
  end
  local short = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":~")
  local alist = file_alist()
  local kept = vim.tbl_filter(function(x)
    return x[1] ~= path
  end, alist)
  if #kept == #alist then
    utils.notify("File was not in list: " .. short .. " (not removed)")
    return true
  end
  M.store_agenda_file_list(vim.tbl_map(function(e)
    return e[2]
  end, kept))
  utils.notify("Removed from Org Agenda list: " .. short)
  return true
end

--- Edit the agenda file list (org-edit-agenda-file-list): the list file
--- when `agenda_files` names one, else the list in a scratch buffer (Emacs
--- opens Customize). Writing the buffer (`:w`) installs the new list,
--- closes the buffer and returns to the previous one.
function M.edit_agenda_file_list()
  local prev = vim.api.nvim_get_current_buf()
  local function finish(buf)
    if vim.api.nvim_buf_is_valid(prev) then
      vim.api.nvim_set_current_buf(prev)
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    utils.notify("New agenda file list installed")
  end
  local path = list_file()
  if path then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_create_autocmd("BufWritePost", {
      buffer = buf,
      once = true,
      callback = function()
        vim.schedule(function()
          finish(buf)
        end)
      end,
    })
  else
    local cfg = require("org.config").opts
    local entries = type(cfg.agenda_files) == "string" and { cfg.agenda_files } or cfg.agenda_files or {}
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "wipe"
    pcall(vim.api.nvim_buf_set_name, buf, "org://agenda-files")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.deepcopy(entries))
    vim.bo[buf].modified = false
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      callback = function()
        local list = vim.tbl_filter(function(l)
          return l:match("%S") ~= nil
        end, vim.tbl_map(vim.trim, vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
        M.store_agenda_file_list(list)
        vim.bo[buf].modified = false
        vim.schedule(function()
          finish(buf)
        end)
      end,
    })
  end
  utils.notify("Edit list and finish with :w")
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

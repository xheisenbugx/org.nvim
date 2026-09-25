---@mod org.id Entry IDs (org-id)
---
--- IDs are stored in the `:ID:` property. A JSON database
--- (`config.id.locations_file`) maps ids to files so `id:` links resolve
--- quickly; it is rebuilt from the agenda files, their archives
--- (`id.search_archives`), `id.extra_files`, the loaded org buffers and the
--- files already known when an id is not found (org-id-update-id-locations).

local config = require("org.config")
local edit = require("org.edit")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

local db = nil

local function db_path()
  local id = config.opts.id or {}
  return id.locations_file or (vim.fn.stdpath("data") .. "/org/id-locations.json")
end

local function load_db()
  if not db then
    db = utils.read_json(db_path()) or {}
    if type(db) ~= "table" then
      db = {}
    end
  end
  return db
end

local function save_db()
  pcall(utils.write_json, db_path(), db or {})
end

--- Record `id` as living in `filename`.
function M.register(id, filename)
  if not id or not filename then
    return
  end
  local d = load_db()
  if d[id] ~= filename then
    d[id] = filename
    save_db()
  end
end

--- Record every `:ID:` property found in `lines` as living in `filename`
--- (org-id-paste-tracker: refiled and archived entries keep resolving).
function M.register_lines(lines, filename)
  if not filename or filename == "" then
    return
  end
  local d, changed = load_db(), false
  for _, l in ipairs(lines) do
    local id = l:match("^%s*:ID:%s+(%S+)")
    if id and d[id] ~= filename then
      d[id] = filename
      changed = true
    end
  end
  if changed then
    save_db()
  end
end

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"

local function b36(n, len)
  local s = ""
  while n > 0 do
    local r = n % 36
    s = B36:sub(r + 1, r + 1) .. s
    n = math.floor(n / 36)
  end
  if #s < len then
    s = string.rep("0", len - #s) .. s
  end
  return s
end

--- Generate a new id according to `id.method` and `id.prefix`
--- (org-id-new).
function M.new_id()
  local cfg = config.opts.id or {}
  local method = cfg.method or "uuid"
  local unique
  if method == "ts" then
    local sec, usec = vim.uv.gettimeofday()
    local fmt = (cfg.ts_format or "%Y%m%dT%H%M%S.%6N"):gsub("%%6N", string.format("%06d", usec))
    unique = os.date(fmt, sec)
  elseif method == "org" then
    -- the time (HI LO USEC) in base 36, reversed
    local sec, usec = vim.uv.gettimeofday()
    unique = (b36(math.floor(sec / 65536), 4) .. b36(sec % 65536, 4) .. b36(usec, 4)):reverse()
  else
    unique = utils.uuid()
  end
  local prefix = cfg.prefix
  if prefix and prefix ~= "" then
    return prefix .. ":" .. unique
  end
  return unique
end

--- Return the ID of the headline at target, creating one if missing
--- (org-id-get-create). With `force` (a count: C-u), a new ID replaces
--- the existing one.
---@param target? org.Target
---@param force? boolean
---@return string|nil
function M.get_create(target, force)
  if force == nil and target == nil then
    force = vim.v.count > 0
  end
  local bufnr, file, hl = edit.resolve_headline(target)
  if not hl then
    return nil
  end
  local id = hl.properties.ID
  if force or not id or not id:match("%S") then
    id = M.new_id()
    edit.set_property(bufnr, hl.line, "ID", id)
  end
  if file.filename then
    M.register(id, file.filename)
  end
  if not target then
    utils.notify("ID: " .. id)
  end
  return id
end

--- Only get an existing ID (nil if none).
function M.get(target)
  local _, _, hl = edit.resolve(target)
  return hl and hl.properties.ID or nil
end

local function search_file(path, id)
  local f = files.get(path)
  if not f then
    return nil
  end
  local hl = f:find_by_id(id)
  if hl then
    return { filename = f.filename or path, lnum = hl.line, headline = hl }
  end
end

--- Files scanned for IDs: the agenda files, their archives
--- (`id.search_archives`), `id.extra_files`, the files known to hold IDs
--- and the loaded org buffers.
function M.files()
  local cfg = config.opts.id or {}
  local out, seen = {}, {}
  local function add(p)
    if type(p) == "string" and p ~= "" then
      p = vim.fs.normalize(p)
      if not seen[p] and utils.exists(p) then
        seen[p] = true
        out[#out + 1] = p
      end
    end
  end
  for _, p in ipairs(files.agenda_file_paths()) do
    add(p)
  end
  if cfg.search_archives ~= false then
    local ok, view = pcall(require, "org.agenda.view")
    if ok and view.archive_files then
      for _, f in ipairs(view.archive_files(files.agenda_files())) do
        add(f.filename)
      end
    end
  end
  local extra = cfg.extra_files or {}
  if type(extra) == "string" then
    extra = { extra }
  end
  for _, p in ipairs(utils.glob_org_files(extra)) do
    add(p)
  end
  for _, p in pairs(load_db()) do
    add(p)
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" and vim.bo[b].buftype == "" then
      add(vim.api.nvim_buf_get_name(b))
    end
  end
  return out
end

--- Rebuild the id database (org-id-update-id-locations). Returns the
--- number of IDs found.
function M.update_locations()
  local new = {}
  local count = 0
  for _, p in ipairs(M.files()) do
    local f = files.get(p)
    if f then
      for _, hl in ipairs(f.headlines) do
        local id = hl.properties.ID
        if id then
          if not new[id] then
            count = count + 1
          end
          new[id] = f.filename or p
        end
      end
    end
  end
  db = new
  save_db()
  utils.notify(string.format("%d IDs found", count))
  return count
end

--- Locate an id. Returns { filename, lnum, headline } or nil.
function M.find(id)
  if not id or id == "" then
    return nil
  end
  -- current buffer first
  if utils.is_org() then
    local f = files.get_buffer(0)
    local hl = f:find_by_id(id)
    if hl then
      return { filename = f.filename, lnum = hl.line, headline = hl, bufnr = vim.api.nvim_get_current_buf() }
    end
  end
  local path = load_db()[id]
  if path and utils.exists(path) then
    local r = search_file(path, id)
    if r then
      return r
    end
  end
  -- not where the database says: rescan every file
  for _, p in ipairs(M.files()) do
    if p ~= path then
      local r = search_file(p, id)
      if r then
        M.register(id, r.filename)
        return r
      end
    end
  end
  return nil
end

--- Prompt for an ID and go to its entry (org-id-goto).
---@param id? string
function M.goto(id)
  if not id then
    local known = vim.tbl_keys(load_db())
    table.sort(known)
    id = utils.input_complete("ID: ", known)
    if not id or vim.trim(id) == "" then
      return
    end
    id = vim.trim(id)
  end
  local loc = M.find(id)
  if not loc then
    utils.warn("Cannot find entry with ID: " .. id)
    return false
  end
  vim.cmd("normal! m'")
  utils.open_file(loc.filename, loc.headline and loc.headline.line or loc.lnum)
  return true
end

--- Copy the entry's ID (created if needed) to the unnamed and `+`
--- registers (org-id-copy).
function M.copy()
  local id = M.get_create({ bufnr = vim.api.nvim_get_current_buf(), lnum = vim.api.nvim_win_get_cursor(0)[1] })
  if not id then
    return
  end
  vim.fn.setreg('"', id)
  pcall(vim.fn.setreg, "+", id)
  utils.notify("Copied ID: " .. id)
  return id
end

--- Store an `id:` link to the entry, creating the ID (org-id-store-link).
function M.store_link()
  local bufnr = vim.api.nvim_get_current_buf()
  local _, _, hl = edit.resolve_headline({ bufnr = bufnr, lnum = vim.api.nvim_win_get_cursor(0)[1] })
  if not hl then
    return
  end
  local id = M.get_create({ bufnr = bufnr, lnum = hl.line })
  local stored = require("org.links").store("id:" .. id, hl:plain_title())
  utils.notify("Stored: " .. hl:plain_title())
  return stored
end

--- For tests.
function M._reset()
  db = nil
end

return M

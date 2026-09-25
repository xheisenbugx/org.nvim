---@mod org.id Entry IDs (org-id)
---
--- IDs are stored in the `:ID:` property. A JSON database
--- (`config.id.locations_file`) maps ids to files so `id:` links resolve
--- quickly; it is rebuilt from agenda files when an id is not found.

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
  load_db()[id] = filename
  save_db()
end

--- Generate a new id according to `config.id.method`.
function M.new_id()
  local method = (config.opts.id or {}).method or "uuid"
  if method == "ts" then
    return os.date("%Y%m%dT%H%M%S") .. "." .. string.format("%06d", math.random(0, 999999))
  end
  return utils.uuid()
end

--- Return the ID of the headline at target, creating one if missing.
---@param target? org.Target
---@return string|nil
function M.get_create(target)
  local bufnr, file, hl = edit.resolve_headline(target)
  if not hl then
    return nil
  end
  local id = hl.properties.ID
  if not id or id == "" then
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

--- Rebuild the id database from agenda files (plus files already known).
function M.update_locations()
  local new = {}
  local paths = files.agenda_file_paths()
  local seen = {}
  for _, p in ipairs(paths) do
    seen[p] = true
  end
  for _, p in pairs(load_db()) do
    if type(p) == "string" and not seen[p] and utils.exists(p) then
      seen[p] = true
      paths[#paths + 1] = p
    end
  end
  local count = 0
  for _, p in ipairs(paths) do
    local f = files.get(p)
    if f then
      for _, hl in ipairs(f.headlines) do
        if hl.properties.ID then
          new[hl.properties.ID] = f.filename or p
          count = count + 1
        end
      end
    end
  end
  db = new
  save_db()
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
  for _, p in ipairs(files.agenda_file_paths()) do
    local r = search_file(p, id)
    if r then
      M.register(id, r.filename)
      return r
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

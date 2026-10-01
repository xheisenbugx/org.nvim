---@mod org.id Entry IDs (org-id)
---
--- IDs are stored in the `:ID:` property. A database
--- (`config.id.locations_file`, JSON or Emacs's org-id-locations format)
--- maps ids to files so `id:` links resolve
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
  return vim.fs.normalize(id.locations_file or (vim.fn.stdpath("data") .. "/org/id-locations.json"))
end

--- Format of the database file: `id.locations_format` ("json" or "emacs"),
--- or with "auto" (the default) what the file holds, else JSON for a
--- `.json` file name and Emacs's format for any other.
local function db_format(path, text)
  local fmt = (config.opts.id or {}).locations_format
  if fmt == "json" or fmt == "emacs" then
    return fmt
  end
  local first = text and text:match("^%s*(%S)")
  if first == "{" or first == "[" then
    return "json"
  elseif first then
    return "emacs"
  end
  return path:match("%.json$") and "json" or "emacs"
end

local function read_text(path)
  local lines = utils.readfile(path)
  return lines and table.concat(lines, "\n") or nil
end

--- Read the Lisp string whose opening quote is at `i`; returns it and the
--- index after the closing quote.
local function read_lisp_string(text, i)
  local out = {}
  local j = i + 1
  while j <= #text do
    local c = text:sub(j, j)
    if c == '"' then
      return table.concat(out), j + 1
    elseif c == "\\" then
      local n = text:sub(j + 1, j + 1)
      if n == "n" then
        out[#out + 1] = "\n"
      elseif n == "t" then
        out[#out + 1] = "\t"
      elseif n ~= "\n" then
        -- \" and \\ stand for the character; an escaped newline is dropped
        out[#out + 1] = n
      end
      j = j + 2
    else
      out[#out + 1] = c
      j = j + 1
    end
  end
  error("unterminated string")
end

--- Parse Emacs's `org-id-locations-file`: an alist printed with `print`,
--- `(("~/org/a.org" "id1" "id2") ...)`. `~` is expanded and relative file
--- names are relative to `base` (the database's directory), as in
--- org-id-locations-load. Returns id -> file.
---@param text string
---@param base? string
---@return table<string, string>
function M.parse_emacs_locations(text, base)
  local out = {}
  local depth, entry = 0, nil
  local i = 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == "(" then
      depth = depth + 1
      entry = depth == 2 and {} or entry
      i = i + 1
    elseif c == ")" then
      if depth == 2 and entry and entry[1] then
        local file = entry[1]:gsub("^~", utils.home)
        if base and not utils.is_absolute(file) then
          file = base .. "/" .. file
        end
        file = vim.fs.normalize(file)
        for k = 2, #entry do
          out[entry[k]] = file
        end
      end
      depth = depth - 1
      i = i + 1
    elseif c == '"' then
      local str
      str, i = read_lisp_string(text, i)
      if depth == 2 and entry then
        entry[#entry + 1] = str
      end
    elseif c == ";" then
      i = (text:find("\n", i, true) or #text) + 1
    else
      i = i + 1
    end
  end
  return out
end

local function lisp_string(str)
  return '"' .. str:gsub('[\\"]', "\\%0") .. '"'
end

--- Print id -> file like org-id-locations-save: one `("file" "id" ...)`
--- per file, file names abbreviated with `~` (abbreviate-file-name) or,
--- with `id.locations_file_relative`, relative to `base`.
---@param map table<string, string>
---@param base? string
---@return string
function M.format_emacs_locations(map, base)
  local by_file, names = {}, {}
  for id, file in pairs(map) do
    if not by_file[file] then
      by_file[file] = {}
      names[#names + 1] = file
    end
    table.insert(by_file[file], id)
  end
  table.sort(names)
  local home = vim.fs.normalize(utils.home())
  local relative = (config.opts.id or {}).locations_file_relative
  local items = {}
  for _, file in ipairs(names) do
    local ids = by_file[file]
    table.sort(ids)
    local name = file
    if relative and base and name:sub(1, #base + 1) == base .. "/" then
      name = name:sub(#base + 2)
    elseif home and name:sub(1, #home + 1) == home .. "/" then
      name = "~" .. name:sub(#home + 1)
    end
    local item = { lisp_string(name) }
    for _, id in ipairs(ids) do
      item[#item + 1] = lisp_string(id)
    end
    items[#items + 1] = "(" .. table.concat(item, " ") .. ")"
  end
  return "(" .. table.concat(items, " ") .. ")"
end

local function load_db()
  if not db then
    local path = db_path()
    local text = read_text(path)
    if text and db_format(path, text) == "emacs" then
      local ok, parsed = pcall(M.parse_emacs_locations, text, vim.fs.dirname(path))
      db = ok and parsed or {}
    else
      local ok, parsed = pcall(vim.json.decode, text or "")
      db = ok and parsed or {}
    end
    if type(db) ~= "table" then
      db = {}
    end
  end
  return db
end

local function save_db()
  local path = db_path()
  if db_format(path, read_text(path)) == "emacs" then
    -- `print` puts a newline before and after the object
    pcall(utils.writefile, path, { "", M.format_emacs_locations(db or {}, vim.fs.dirname(path)) })
  else
    pcall(utils.write_json, path, db or {})
  end
end

--- Record `id` as living in `filename`.
function M.register(id, filename)
  if not id or not filename then
    return
  end
  -- one spelling per file (buffer names have \ on Windows)
  filename = vim.fs.normalize(filename)
  local d = load_db()
  if d[id] ~= filename then
    d[id] = filename
    save_db()
  end
end

--- Forget `id` (it was renamed or removed).
function M.forget(id)
  local d = load_db()
  if id and d[id] then
    d[id] = nil
    save_db()
  end
end

--- Record several ids at once: `map` is id -> filename. Writes the
--- database once, and only when something changed.
---@param map table<string, string>
function M.register_many(map)
  local d, changed = load_db(), false
  for id, filename in pairs(map) do
    filename = vim.fs.normalize(filename)
    if d[id] ~= filename then
      d[id] = filename
      changed = true
    end
  end
  if changed then
    save_db()
  end
end

--- Record every `:ID:` property found in `lines` as living in `filename`
--- (org-id-paste-tracker: refiled and archived entries keep resolving).
function M.register_lines(lines, filename)
  if not filename or filename == "" then
    return
  end
  filename = vim.fs.normalize(filename)
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
  if cfg.include_domain and (method == "ts" or method == "org") then
    -- org-id-include-domain (never for UUIDs)
    unique = unique .. "@" .. M.fqdn()
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
  local bufnr, file, hl = edit.resolve(target)
  -- before the first headline: the file-level property drawer, like
  -- org-id-get at point-min
  local props = hl and hl.properties or file.properties
  local id = props.ID
  if force or not id or not id:match("%S") then
    id = M.new_id()
    edit.set_property(bufnr, hl and hl.line or 1, "ID", id)
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
  local _, file, hl = edit.resolve(target)
  return (hl and hl.properties or file.properties).ID
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
  if f.properties and f.properties.ID == id then
    return { filename = f.filename or path, lnum = 1 }
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
      local fid = f.properties and f.properties.ID
      if fid and fid ~= "" then
        count = count + (new[fid] and 0 or 1)
        new[fid] = f.filename or p
      end
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
    if f.properties.ID == id then
      return { filename = f.filename, lnum = 1, bufnr = vim.api.nvim_get_current_buf() }
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
M["goto"] = function(id)
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
--- With `id.link_use_context`, a named element or selection below the
--- heading adds a search string (`id:ID::name`).
function M.store_link()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local _, file, hl = edit.resolve({ bufnr = bufnr, lnum = lnum })
  if vim.api.nvim_buf_get_name(bufnr) == "" then
    local id = M.get_create({ bufnr = bufnr, lnum = hl and hl.line or lnum })
    return require("org.links").store("id:" .. id, hl and hl.title or file.settings.title)
  end
  return require("org.links").store_id_link()
end

--- The files holding known IDs (org-id-files), sorted.
---@return string[]
function M.id_files()
  local seen, out = {}, {}
  for _, p in pairs(load_db()) do
    if type(p) == "string" and not seen[p] and utils.exists(p) then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  table.sort(out)
  return out
end

--- The host's fully qualified name for `id.include_domain`, like Emacs's
--- message-make-fqdn: the host name when it has a dot, else
--- "<host>.mail-host-address-is-not-set".
---@return string
function M.fqdn()
  local host = vim.uv.os_gethostname() or "localhost"
  if host:find(".", 1, true) then
    return host
  end
  return host .. ".mail-host-address-is-not-set"
end

--- Known IDs (from the locations file), sorted.
function M.known_ids()
  local known = vim.tbl_keys(load_db())
  table.sort(known)
  return known
end

--- For tests.
function M._reset()
  db = nil
end

return M

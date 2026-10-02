---@mod org.extensions.lsp.util Documents, positions and workspace files
---
--- The server runs inside Neovim, so a document is read from its loaded
--- buffer when there is one (unsaved text included) and from disk
--- otherwise, through `org.files` (cached by changedtick / mtime).

local files = require("org.files")
local utils = require("org.utils")

local M = {}

local real_cache = {}

--- A file name with symlinks resolved (so `/var/x` and `/private/var/x`
--- are one file), normalized; the name itself when the file is missing.
---@param path string
---@return string
function M.canon(path)
  path = vim.fs.normalize(path)
  local r = real_cache[path]
  if not r then
    r = utils.realpath(path)
    if not r then
      return path
    end
    r = vim.fs.normalize(r)
    real_cache[path] = r
  end
  return r
end

-- Lookups made while answering one request (one event-loop tick):
-- loaded buffers by resolved name and parsed files by name. Dropped on
-- the next tick, or when a buffer is added, renamed or deleted.
local scope

local function current()
  if not scope then
    scope = { files = {} }
    vim.schedule(function()
      scope = nil
    end)
  end
  return scope
end

--- Forget the lookups of the current request.
function M.reset_scope()
  scope = nil
end

--- A table kept for the current request under `key`.
---@param key string
---@return table
function M.scoped(key)
  local sc = current()
  sc[key] = sc[key] or {}
  return sc[key]
end

--- The loaded buffer of a file, comparing names with symlinks resolved
--- (a buffer opened as /tmp/x.org is the buffer of /private/tmp/x.org).
---@param path string
---@return integer|nil
function M.buffer_of(path)
  local sc = current()
  if not sc.bufs then
    sc.bufs = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= "" then
          local k = M.canon(name)
          sc.bufs[k] = sc.bufs[k] or b
        end
      end
    end
  end
  local b = sc.bufs[M.canon(path)]
  if b and vim.api.nvim_buf_is_loaded(b) then
    return b
  end
end

--- The parsed file of a name: its buffer's text when it is loaded, else
--- the file on disk (`org.files`, cached by mtime).
---@param path string
---@return org.File|nil
function M.file(path)
  path = M.canon(path)
  local b = M.buffer_of(path)
  if b then
    return files.get_buffer(b)
  end
  local sc = current()
  local f = sc.files[path]
  if f == nil then
    f = files.get(path) or false
    sc.files[path] = f
  end
  return f or nil
end

--- URI of a file: its buffer's when it is loaded (Neovim then edits that
--- buffer, whatever name it was opened under), else the file's.
---@param path string
function M.uri(path)
  local b = M.buffer_of(path)
  return b and vim.uri_from_bufnr(b) or vim.uri_from_fname(path)
end

--- Whether a file name is an Org file (parsed as Org by the server).
---@param path string
function M.is_org(path)
  return path:match("%.org$") ~= nil or path:match("%.org_archive$") ~= nil
end

--- Options of the extension (defaults when it is off, for direct calls).
---@return table
function M.opts()
  return require("org.extensions").opts("lsp") or require("org.extensions.lsp").defaults
end

--- Lines of a buffer that hold text the `transclusion` extension
--- inserted (a set of 1-based line numbers), or nil when there is none.
--- That text belongs to another file: symbols, references, rename and
--- diagnostics leave it out.
---@param bufnr integer|nil
---@return table<integer, true>|nil
function M.foreign(bufnr)
  if not bufnr or not require("org.extensions").loaded.transclusion then
    return nil
  end
  local ok, regs = pcall(function()
    return require("org.extensions.transclusion").regions(bufnr)
  end)
  if not ok or type(regs) ~= "table" or #regs == 0 then
    return nil
  end
  local set = {}
  for _, r in ipairs(regs) do
    -- rows are 0-based: the keyword is on 1-based line r.s, the text below
    for row = r.s, r.e do
      set[row + 1] = true
    end
  end
  return next(set) and set or nil
end

---@class org.lsp.Doc
---@field path string|nil normalized file name
---@field uri string
---@field bufnr integer|nil loaded buffer
---@field file org.File
---@field lines string[]
---@field foreign table<integer, true>|nil lines inserted by `transclusion`

local function make(path, bufnr)
  path = path and M.canon(path)
  local file
  if bufnr then
    file = files.get_buffer(bufnr)
  elseif path then
    file = M.file(path)
  end
  if not file then
    return nil
  end
  return {
    path = path,
    uri = bufnr and vim.uri_from_bufnr(bufnr) or vim.uri_from_fname(path),
    bufnr = bufnr,
    file = file,
    lines = file.lines,
    foreign = M.foreign(bufnr),
  }
end

--- Document of a URI, or nil when it is neither loaded nor readable.
---@param uri string
---@return org.lsp.Doc|nil
function M.doc(uri)
  if not uri or not uri:match("^file:") then
    return nil
  end
  local path = vim.fs.normalize(vim.uri_to_fname(uri))
  return make(path, M.buffer_of(path))
end

--- Document of a file name.
---@param path string
---@return org.lsp.Doc|nil
function M.doc_from_path(path)
  return make(path, M.buffer_of(path))
end

--- Document of a buffer.
---@param bufnr integer
---@return org.lsp.Doc|nil
function M.doc_from_buf(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return make(name ~= "" and vim.fs.normalize(name) or nil, bufnr)
end

---------------------------------------------------------------------------
-- Positions (the server speaks UTF-8 offsets: byte columns)
---------------------------------------------------------------------------

--- LSP position -> 1-based line and 1-based byte column.
---@return integer lnum, integer col
function M.from_pos(pos)
  return pos.line + 1, pos.character + 1
end

--- 1-based line and 1-based byte column -> LSP position.
function M.pos(lnum, col)
  return { line = lnum - 1, character = math.max(0, (col or 1) - 1) }
end

--- Range over the 1-based inclusive columns `s`..`e` of line `lnum`
--- (`e` may be on `end_lnum`).
function M.range(lnum, s, e, end_lnum)
  return { start = M.pos(lnum, s), ["end"] = M.pos(end_lnum or lnum, e + 1) }
end

--- Range of whole lines `first`..`last`.
function M.line_range(lines, first, last)
  last = math.max(first, last or first)
  return { start = M.pos(first, 1), ["end"] = M.pos(last, #(lines[last] or "") + 1) }
end

function M.location(path, lnum, s, e)
  return { uri = M.uri(path), range = M.range(lnum, s or 1, e or 0) }
end

---------------------------------------------------------------------------
-- Headlines
---------------------------------------------------------------------------

--- Byte span (1-based, inclusive) of a headline's title in its line; an
--- empty title gives e = s - 1.
---@param hl org.Headline
---@return integer s, integer e
function M.title_span(hl)
  local raw = hl.raw
  local pos = (raw:find("[^%*]") or #raw + 1)
  pos = raw:find("%S", pos) or #raw + 1
  if hl.todo and raw:sub(pos, pos + #hl.todo - 1) == hl.todo then
    pos = raw:find("%S", pos + #hl.todo) or #raw + 1
  end
  if hl.priority then
    local p = raw:find("[#" .. hl.priority .. "]", pos, true)
    if p == pos then
      pos = raw:find("%S", pos + #hl.priority + 3) or #raw + 1
    end
  end
  if hl.commented and raw:sub(pos, pos + 6) == "COMMENT" then
    pos = raw:find("%S", pos + 7) or #raw + 1
  end
  local title = hl.title or ""
  if title == "" then
    return pos, pos - 1
  end
  local s = raw:find(title, pos, true) or pos
  return s, s + #title - 1
end

--- Headline titles from the root to `hl`, joined with "/".
function M.olp(hl, with_self)
  local parts = hl:outline_path()
  if with_self then
    parts[#parts + 1] = hl:plain_title()
  end
  return table.concat(parts, "/")
end

---------------------------------------------------------------------------
-- Workspace
---------------------------------------------------------------------------

local function add_dir(add, dir, recursive)
  local pat = recursive and "**/*.org" or "*.org"
  for _, f in ipairs(vim.fn.globpath(dir, pat, false, true)) do
    if not f:find("/%.") then
      add(f)
    end
  end
end

-- the configured files (globbing a large org_directory takes a while),
-- reused for `CACHE_MS` or until an org file is written or created
local listed = { at = 0, list = nil }
local CACHE_MS = 3000

-- link path and directory -> resolved file name
local resolved = {}

--- Forget the cached workspace file list and resolved link paths (a file
--- was written, created or deleted; the options changed).
function M.invalidate()
  listed.list = nil
  resolved = {}
end

--- File name of a link path relative to `base` (`~` and environment
--- variables expanded, symlinks resolved), remembered.
---@param p string
---@param base string
---@return string
function M.resolve(p, base)
  local k = base .. "\0" .. p
  local r = resolved[k]
  if not r then
    r = M.canon(utils.expand(p, base))
    resolved[k] = r
  end
  return r
end

local function configured_files()
  local now = vim.uv.now()
  if listed.list and now - listed.at < CACHE_MS then
    return listed.list
  end
  local w = M.opts().workspace or {}
  local out = {}
  local function add(p)
    if type(p) == "string" and p ~= "" then
      out[#out + 1] = p
    end
  end
  local custom = w.files
  if type(custom) == "function" then
    custom = custom()
  end
  if type(custom) == "table" then
    for _, p in ipairs(utils.glob_org_files(custom)) do
      add(p)
    end
  else
    if w.agenda_files ~= false then
      for _, p in ipairs(files.agenda_file_paths()) do
        add(p)
      end
    end
    if w.org_directory ~= false then
      local dir = utils.expand(require("org.config").opts.org_directory, vim.fn.getcwd())
      if dir and utils.is_dir(dir) then
        add_dir(add, dir, w.recursive ~= false)
      end
    end
    for _, p in ipairs(utils.glob_org_files(w.extra or {})) do
      add(p)
    end
  end
  listed.at, listed.list = now, out
  return out
end

--- Files the workspace requests (workspace symbols, references, rename)
--- look at: the agenda files, the `.org` files under `org_directory`
--- (`workspace.org_directory`), `workspace.extra` and every loaded org
--- buffer. `workspace.files` (a list or a function) replaces all that.
---@return string[]
function M.workspace_files()
  local w = M.opts().workspace or {}
  local out, seen = {}, {}
  local function add(p)
    if type(p) ~= "string" or p == "" then
      return
    end
    p = M.canon(p)
    if not seen[p] then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  for _, p in ipairs(configured_files()) do
    add(p)
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" and vim.bo[b].buftype == "" then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        add(name)
      end
    end
  end
  local max = w.max_files or 2000
  while #out > max do
    table.remove(out)
  end
  return out
end

--- Documents of the workspace files, `first` (a doc) first.
---@param first? org.lsp.Doc
---@return org.lsp.Doc[]
function M.workspace_docs(first)
  local out = {}
  if first then
    out[1] = first
  end
  for _, p in ipairs(M.workspace_files()) do
    if not (first and first.path == p) then
      local d = M.doc_from_path(p)
      if d then
        out[#out + 1] = d
      end
    end
  end
  return out
end

return M

---@mod org.links.insert Inserting links (org-insert-link)
---
--- Link completion, formatting a link for a buffer (format,
--- format_for_buffer, file path styles) and the insert commands.
--- Part of org.links, which loads it.

local config = require("org.config")
local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.links.shared")

local M = require("org.links")

local base_dir = shared.base_dir
local expand_text = shared.expand_text
local lopts = shared.lopts
local unescape = shared.unescape
local visual_region = shared.visual_region

local ZWSP = "\226\128\139" -- U+200B ZERO WIDTH SPACE

---------------------------------------------------------------------------
-- Inserting
---------------------------------------------------------------------------

local PREFIXES = {
  "file:",
  "id:",
  "https://",
  "http://",
  "mailto:",
  "shell:",
  "help:",
  "man:",
  "attachment:",
  "doi:",
  "file+sys:",
}

--- File name completion relative to the directory of buffer `bufnr`.
local function complete_files(lead, bufnr)
  local expanded = vim.fs.normalize(expand_text(lead))
  if utils.is_absolute(expanded) or lead:match("^~") then
    return utils.complete_path(lead, "file")
  end
  local base = vim.fs.normalize(base_dir(bufnr)) .. "/"
  local out = {}
  for _, f in ipairs(utils.complete_path(base .. lead, "file")) do
    local head = f:sub(1, #base)
    local inside = head == base or (vim.fn.has("win32") == 1 and head:lower() == base:lower())
    out[#out + 1] = inside and f:sub(#base + 1) or f
  end
  return out
end

M._complete_bufnr = nil

function M._complete(arglead, _, _)
  local bufnr = M._complete_bufnr or 0
  local out = {}
  local ftarget = arglead:match("^file:(.*)$")
  if ftarget then
    for _, f in ipairs(complete_files(ftarget, bufnr)) do
      out[#out + 1] = "file:" .. f
    end
    return out
  end
  if arglead:match("^[%./~]") then
    return complete_files(arglead, bufnr)
  end
  local candidates = {}
  for _, s in ipairs(M.stored) do
    candidates[#candidates + 1] = s.link
  end
  for _, s in ipairs(M.stored) do
    if s.desc then
      candidates[#candidates + 1] = s.desc
    end
  end
  for _, p in ipairs(PREFIXES) do
    candidates[#candidates + 1] = p
  end
  for name in pairs(lopts().abbreviations or {}) do
    candidates[#candidates + 1] = name .. ":"
  end
  for name in pairs(lopts().types or {}) do
    candidates[#candidates + 1] = name .. ":"
  end
  if vim.api.nvim_buf_is_valid(bufnr) and utils.is_org(bufnr) then
    for name in pairs(files.get_buffer(bufnr).settings.link_abbrevs) do
      candidates[#candidates + 1] = name .. ":"
    end
    for _, hl in ipairs(files.get_buffer(bufnr).headlines) do
      candidates[#candidates + 1] = "*" .. hl:plain_title()
    end
  end
  local seen = {}
  for _, c in ipairs(candidates) do
    if not seen[c] and c:lower():find(arglead:lower(), 1, true) == 1 then
      seen[c] = true
      out[#out + 1] = c
    end
  end
  return out
end

function M._complete_file(arglead, _, _)
  return complete_files(arglead, M._complete_bufnr or 0)
end

--- Build a bracket link string (org-link-make-string). A description
--- containing `]]` or ending with `]` gets a zero width space so the link
--- stays valid.
function M.format(target, desc)
  if desc then
    desc = vim.trim(desc)
    if desc == "" then
      desc = nil
    end
  end
  if desc then
    desc = desc:gsub("%]$", "]" .. ZWSP)
    desc = desc:gsub("%]%]", "]" .. ZWSP .. "]")
    return "[[" .. M.escape(target) .. "][" .. desc .. "]]"
  end
  return "[[" .. M.escape(target) .. "]]"
end

--- Write `path` as `links.file_path_type` asks, relative to the directory
--- `dir` (org-link--normalize-filename).
function M.normalize_file_path(path, method, dir)
  method = method or lopts().file_path_type or "adaptive"
  if type(method) == "function" then
    return method(path)
  end
  -- the file and the directory made absolute alike: expand() and
  -- fnamemodify() give \ on Windows, and may or may not add a drive to /x
  local function absolute(p, base)
    p = vim.fs.normalize(expand_text(p))
    if not utils.is_absolute(p) then
      p = base and (base .. "/" .. p) or vim.fn.fnamemodify(p, ":p")
    end
    return vim.fs.normalize(p)
  end
  local full = absolute(path, dir)
  if path:sub(-1) == "/" and full:sub(-1) ~= "/" then
    full = full .. "/"
  end
  if method == "absolute" then
    return utils.abbreviate(full)
  elseif method == "noabbrev" then
    return full
  end
  dir = absolute(dir):gsub("/$", "") .. "/"
  if method == "relative" then
    local a = vim.split(dir:gsub("/$", ""), "/", { plain = true })
    local b = vim.split(full, "/", { plain = true })
    local k = 1
    while k <= #a and k <= #b and a[k] == b[k] do
      k = k + 1
    end
    local parts = {}
    for _ = k, #a do
      parts[#parts + 1] = ".."
    end
    for j = k, #b do
      parts[#parts + 1] = b[j]
    end
    local rel = table.concat(parts, "/")
    return rel == "" and "." or rel
  end
  local head = full:sub(1, #dir)
  if head == dir or (vim.fn.has("win32") == 1 and head:lower() == dir:lower()) then
    return full:sub(#dir + 1)
  end
  return utils.abbreviate(full)
end

--- Default description of a link: the type's `insert_description`, else
--- `links.make_description` (org-link-get-description).
local function default_description(link, desc)
  local scheme = link:match("^([%a][%w+%-]*):")
  local t = M.link_type(scheme)
  if t and t.insert_description ~= nil then
    local d = t.insert_description
    if type(d) == "function" then
      local ok, r = pcall(d, link, desc)
      return ok and r or nil
    end
    return d
  end
  local fn = lopts().make_description
  if type(fn) == "function" then
    local ok, r = pcall(fn, link, desc)
    return ok and r or nil
  end
  return desc
end

--- Format `link` for the current buffer (org-link-make-string-for-buffer):
--- strip <> of plain links, shorten links to this file to their search
--- option and write file paths per `links.file_path_type`.
function M.format_for_buffer(link, desc, fopts)
  fopts = fopts or {}
  local bufnr = fopts.bufnr or vim.api.nvim_get_current_buf()
  if link:match("^<[%a][%w+%-]*:.*>$") then
    link = link:sub(2, -2)
  end
  local cur = vim.api.nvim_buf_get_name(bufnr)
  if cur ~= "" then
    local p, s = link:match("^file:(.-)::(.*)$")
    if p and p ~= "" then
      local a = utils.realpath(M.resolve_path(p, bufnr)) or M.resolve_path(p, bufnr)
      local b = utils.realpath(cur) or vim.fs.normalize(cur)
      if a == b then
        link = s
      end
    end
  end
  local ftype, rest = link:match("^(file):(.*)$")
  if not ftype then
    ftype, rest = link:match("^(docview):(.*)$")
  end
  if ftype then
    local path, search = rest, nil
    local p, s = rest:match("^(.-)::(.*)$")
    if p then
      path, search = p, s
    end
    local orig = path
    if path == "" then
      path = cur
    end
    if path ~= "" then
      path = M.normalize_file_path(path, fopts.path_type, base_dir(bufnr))
    end
    link = ftype .. ":" .. path .. (search and ("::" .. search) or "")
    if desc == orig then
      desc = path
    end
  end
  if desc == nil then
    desc = default_description(link, nil)
  end
  if fopts.interactive then
    desc = utils.input({ prompt = "Description: ", default = desc or "" })
    if desc == nil then
      return nil
    end
  end
  if desc and not desc:match("%S") then
    desc = nil
  end
  return M.format(link, desc)
end

--- Insert `text` (may contain newlines) after the cursor character, or
--- replace the range { srow, scol, erow, ecol } (1-based, inclusive).
local function put_text(text, range)
  local parts = vim.split(text, "\n", { plain = true })
  local srow, scol0, erow, ecol0
  if range then
    srow, scol0, erow, ecol0 = range[1], range[2] - 1, range[3], range[4]
  else
    local row, col0 = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    local at = line == "" and 0 or math.min(col0 + 1, #line)
    srow, scol0, erow, ecol0 = row, at, row, at
  end
  vim.api.nvim_buf_set_text(0, srow - 1, scol0, erow - 1, ecol0, parts)
  local last_row = srow + #parts - 1
  local last_col = (#parts == 1 and scol0 or 0) + #parts[#parts]
  vim.api.nvim_win_set_cursor(0, { last_row, math.max(0, last_col - 1) })
end

--- Read a file name and make a file link (org-link-complete-file). With
--- `absolute`, the path is absolute; otherwise relative when the file is
--- below the buffer's directory.
local function complete_file_link(bufnr, absolute)
  M._complete_bufnr = bufnr
  local ok, file = pcall(vim.fn.input, {
    prompt = "File: ",
    completion = "customlist,v:lua.require'org.links'._complete_file",
    cancelreturn = vim.NIL,
  })
  M._complete_bufnr = nil
  if not ok or file == vim.NIL or vim.trim(file) == "" then
    return nil
  end
  file = vim.trim(file)
  local full = M.resolve_path(file, bufnr)
  if absolute then
    return "file:" .. utils.abbreviate(full)
  end
  local dir = base_dir(bufnr) .. "/"
  if full:sub(1, #dir) == dir then
    return "file:" .. full:sub(#dir + 1)
  end
  return "file:" .. file
end

--- Complete an id: link by heading (org-id-complete): choose a heading
--- among `id.completion_targets` (refile target specs; in a buffer without
--- a file, the "current" ones are dropped) and link to its ID, creating
--- one when needed. With no targets, ask for the link text.
---@param bufnr integer
---@return string|nil
function M.complete_id(bufnr)
  local idcfg = config.opts.id or {}
  local specs = idcfg.completion_targets or { { files = "current" }, { files = "id" } }
  if vim.api.nvim_buf_get_name(bufnr) == "" then
    specs = vim.tbl_filter(function(s)
      return s.files ~= nil and s.files ~= "current"
    end, specs)
  end
  local rcfg = config.opts.refile
  local saved = { rcfg.use_outline_path, rcfg.verify, rcfg.use_cache }
  -- org-id-get-with-outline-path-completion: outline paths (with the file
  -- when the first spec names files), no verify function
  local first = specs[1]
  rcfg.use_outline_path = (first and first.files ~= nil and first.files ~= "current") and "file" or true
  rcfg.verify, rcfg.use_cache = nil, false
  local refile = require("org.refile")
  local ok, found, dest = pcall(function()
    local any = #specs > 0 and #refile.targets({ targets = specs, bufnr = bufnr }) > 0
    return any, any and refile.pick_target({ prompt = "Entry", targets = specs, bufnr = bufnr }) or nil
  end)
  rcfg.use_outline_path, rcfg.verify, rcfg.use_cache = saved[1], saved[2], saved[3]
  if not ok then
    error(found, 0)
  end
  if not found then
    return utils.input({ prompt = "Link: ", default = "id:" })
  elseif not dest then
    return nil
  end
  local tbuf = dest.bufnr or utils.load_buffer(dest.filename)
  local id = require("org.id").get_create({ bufnr = tbuf, lnum = dest.lnum or 1 }, false)
  return id and ("id:" .. id) or nil
end

--- Completion for a link type entered alone (org-link--try-special-completion).
local function special_completion(scheme, bufnr)
  local t = M.link_type(scheme)
  if t and t.complete then
    return t.complete()
  end
  if scheme == "file" then
    return complete_file_link(bufnr)
  elseif scheme == "id" then
    return M.complete_id(bufnr)
  elseif scheme == "attachment" then
    local list = require("org.attach").list({ bufnr = bufnr, lnum = vim.api.nvim_win_get_cursor(0)[1] })
    local names = vim.tbl_map(function(p)
      return vim.fn.fnamemodify(p, ":t")
    end, list or {})
    local name = utils.input_complete("Attachment: ", names)
    return name and vim.trim(name) ~= "" and ("attachment:" .. vim.trim(name)) or nil
  end
  local v = utils.input({ prompt = "Link (no completion): ", default = scheme .. ":" })
  return v
end

local function all_prefixes(bufnr)
  local out = {}
  for name in pairs(M.URL_SCHEMES) do
    out[name] = true
  end
  for name in pairs(lopts().types or {}) do
    out[name] = true
  end
  for name in pairs(lopts().abbreviations or {}) do
    out[name] = true
  end
  if utils.is_org(bufnr) then
    for name in pairs(files.get_buffer(bufnr).settings.link_abbrevs) do
      out[name] = true
    end
  end
  return out
end

local function remove_stored(link)
  for i, s in ipairs(M.stored) do
    if s.link == link then
      table.remove(M.stored, i)
      return
    end
  end
end

--- Insert (or edit) a link (org-insert-link). In Visual mode the selection
--- becomes the description. On a link, edit it; a plain or angle link
--- becomes a bracket link. An empty answer inserts the last stored link.
--- A count stands for the prefix argument: 4 (C-u) prompts for a file, 16
--- (C-u C-u) the same with an absolute path, 64 keeps (or removes) the
--- inserted stored link against `links.keep_stored_after_insertion`.
function M.insert_link(arg)
  arg = arg or vim.v.count
  local bufnr = vim.api.nvim_get_current_buf()
  local region = visual_region()
  local desc, link, range
  if region then
    local parts = vim.api.nvim_buf_get_text(0, region[1] - 1, region[2] - 1, region[3] - 1, region[4], {})
    desc = table.concat(parts, "\n")
    range = region
  else
    local existing = M.link_at_cursor()
    if existing and existing.type ~= "radio" then
      range = { existing.lnum, existing.start_col, existing.end_lnum or existing.lnum, existing.end_col }
      -- a bracket link keeps its description; a plain or angle link
      -- becomes a bracket link
      local default = existing.target
      if existing.raw_target then
        default = unescape(existing.raw_target)
        desc = existing.desc
      end
      local ok, v = pcall(vim.fn.input, { prompt = "Link: ", default = default, cancelreturn = vim.NIL })
      if not ok or v == vim.NIL then
        return
      end
      link = v
    end
  end
  if not link and arg > 0 and arg < 64 then
    link = complete_file_link(bufnr, arg >= 16)
    if not link then
      return
    end
  end
  if not link then
    M._complete_bufnr = bufnr
    local last = M.stored[1] and M.stored[1].link
    local ok, v = pcall(vim.fn.input, {
      prompt = last and ("Insert link (default " .. last .. "): ") or "Insert link: ",
      completion = "customlist,v:lua.require'org.links'._complete",
      cancelreturn = vim.NIL,
    })
    M._complete_bufnr = nil
    if not ok or v == vim.NIL then
      return
    end
    v = vim.trim(v)
    if v == "" then
      v = last
    end
    if not v or v == "" then
      utils.warn("No link selected")
      return
    end
    -- a stored link's description selects that link
    for _, s in ipairs(M.stored) do
      if s.desc and s.desc == v and s.link ~= v then
        v = s.link
        break
      end
    end
    local prefixes = all_prefixes(bufnr)
    local bare = v:match("^([%a][%w+%-]*):$") or v:match("^([%a][%w+%-]*)$")
    if bare and prefixes[bare] then
      v = special_completion(bare, bufnr)
      if not v or v == "" then
        return
      end
    end
    link = v
    for _, s in ipairs(M.stored) do
      if s.link == link then
        desc = desc or s.desc
        break
      end
    end
  end
  local keep = lopts().keep_stored_after_insertion and true or false
  if arg >= 64 then
    keep = not keep
  end
  local text = M.format_for_buffer(link, desc, {
    bufnr = bufnr,
    interactive = true,
    path_type = arg >= 16 and arg < 64 and "absolute" or nil,
  })
  if not text then
    return
  end
  if not keep then
    remove_stored(link)
  end
  put_text(text, range)
end

--- Insert stored links at the cursor (org-insert-all-links): each link is
--- `pre .. link .. post`. `n` inserts (and forgets) the last `n` links;
--- otherwise every link, forgotten unless `keep`.
local function insert_stored(n, keep, pre, post)
  if #M.stored == 0 then
    utils.notify("No link to insert")
    return
  end
  local chunks = {}
  local list
  if n then
    list = {}
    for _ = 1, n do
      local l = table.remove(M.stored, 1)
      if not l then
        break
      end
      list[#list + 1] = l
    end
  else
    list = vim.list_slice(M.stored, 1, #M.stored)
  end
  for _, s in ipairs(list) do
    chunks[#chunks + 1] = pre .. M.format_for_buffer(s.link, s.desc or "<no description>") .. post
    if not n and not keep then
      remove_stored(s.link)
    end
  end
  put_text(table.concat(chunks))
end

--- Insert the most recently stored link followed by a newline and forget
--- it (org-insert-last-stored-link). A count inserts that many links.
function M.insert_last_stored_link(arg)
  arg = arg or vim.v.count
  insert_stored(math.max(arg, 1), false, "", "\n")
end

--- Insert every stored link as a `- ` item and forget them
--- (org-insert-all-links). A count of 4 (C-u) keeps them.
function M.insert_all_links(arg)
  arg = arg or vim.v.count
  insert_stored(nil, arg == 4, "- ", "\n")
end

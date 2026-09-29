---@mod org.extensions.roam.db The org-roam node index
---
--- A pure Lua replacement for org-roam's SQLite database. Every `.org` file
--- under `extensions.roam.directory` is parsed into nodes (the file itself
--- when it has a file-level `:ID:`, and every headline with an `:ID:`),
--- the links and citations found in them, and each node's `ROAM_REFS`. The
--- result is cached as JSON (`index_file`) with each file's mtime, so a
--- sync only re-parses files that changed.

local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")

local M = {}

local VERSION = 1

---@class org.roam.Node
---@field id string
---@field file string absolute path
---@field level integer 0 for a file node
---@field lnum integer line of the headline (1 for a file node)
---@field title string
---@field aliases string[]
---@field refs string[] raw `ROAM_REFS` entries
---@field tags string[]
---@field olp string[] outline path of the parents
---@field todo? string
---@field priority? string

---@class org.roam.Link
---@field source string id of the node containing the link
---@field type string link type ("id", "https", "cite", ...)
---@field path string link path (an id, "//example.com", a cite key)
---@field lnum integer
---@field col integer

---@class org.roam.FileEntry
---@field sec integer mtime seconds
---@field nsec integer mtime nanoseconds
---@field nodes org.roam.Node[]
---@field links org.roam.Link[]

---@type { version: integer, directory: string, files: table<string, org.roam.FileEntry> }|nil
local index = nil
-- derived lookup tables, rebuilt lazily after a change
local lookup = nil

local function opts()
  return require("org.extensions").opts("roam") or require("org.extensions.roam").defaults
end

-- the resolved directory, cached for the option value it came from
local dir_cache = { from = nil, dir = nil }

--- The roam directory, absolute and without a trailing slash.
---@return string
function M.directory()
  local from = opts().directory
  if dir_cache.from == from and dir_cache.dir then
    return dir_cache.dir
  end
  local dir = vim.fs.normalize(utils.expand(from))
  -- buffers are named by the resolved path when the directory is a symlink
  local real = vim.uv.fs_realpath(dir)
  dir = (real or dir):gsub("/$", "")
  -- a directory that doesn't exist yet is resolved again next time
  dir_cache = { from = real and from or nil, dir = real and dir or nil }
  return dir
end

local function index_path()
  local p = opts().index_file
  if p and p ~= "" then
    return vim.fs.normalize(utils.expand(p))
  end
  return vim.fn.stdpath("data") .. "/org/roam-index.json"
end

--- Path of `path` relative to the roam directory, or nil when outside it.
---@param path string
---@return string|nil
function M.relative(path)
  local dir = M.directory() .. "/"
  path = vim.fs.normalize(path)
  if path:sub(1, #dir) ~= dir then
    local real = vim.uv.fs_realpath(path) or vim.uv.fs_realpath(vim.fs.dirname(path))
    if real and not vim.uv.fs_realpath(path) then
      real = real .. "/" .. vim.fs.basename(path)
    end
    path = real or path
  end
  if path:sub(1, #dir) == dir then
    return path:sub(#dir + 1)
  end
end

-- compiled `exclude` entries, cached for the option table they came from
local exclude_cache = { from = nil, list = {} }

local function excludes()
  local ex = opts().exclude
  if exclude_cache.from == ex then
    return exclude_cache.list
  end
  local list = {}
  for _, e in ipairs(type(ex) == "table" and ex or { ex }) do
    if type(e) == "function" then
      list[#list + 1] = e
    elseif type(e) == "string" and e ~= "" then
      local ok, re = pcall(vim.regex, require("org.agenda.search").emacs_regexp(e))
      if ok then
        list[#list + 1] = function(rel)
          return re:match_str(rel) ~= nil
        end
      else
        utils.warn("org-roam: invalid exclude regexp " .. e)
      end
    end
  end
  exclude_cache = { from = ex, list = list }
  return list
end

--- Whether `path` is an org file indexed by roam (org-roam-file-p): below
--- the directory, not hidden and not matching `exclude`.
---@param path string
---@return boolean
function M.is_roam_file(path)
  if not path or path == "" or not path:match("%.org$") then
    return false
  end
  local rel = M.relative(path)
  if not rel then
    return false
  end
  for part in rel:gmatch("[^/]+") do
    if part:sub(1, 1) == "." then
      return false
    end
  end
  for _, fn in ipairs(excludes()) do
    if fn(rel, path) then
      return false
    end
  end
  return true
end

--- Every roam file on disk, sorted.
---@return string[]
function M.list_files()
  local dir = M.directory()
  if not utils.is_dir(dir) then
    return {}
  end
  local out = {}
  local walk = vim.fs.dir(dir, {
    depth = math.huge,
    -- hidden directories (.git, ...) are never roam files: don't enter them
    skip = function(name)
      return not vim.fs.basename(name):match("^%.")
    end,
  })
  for name, kind in walk do
    if name:match("%.org$") then
      local p = dir .. "/" .. name
      if kind == "link" then
        local st = vim.uv.fs_stat(p)
        kind = st and st.type or kind
      end
      if kind == "file" and M.is_roam_file(p) then
        out[#out + 1] = p
      end
    end
  end
  table.sort(out)
  return out
end

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------

--- Split a property value like Emacs split-string-and-unquote: words
--- separated by whitespace, double-quoted strings kept together.
---@param s string|nil
---@return string[]
function M.split_quoted(s)
  local out = {}
  if not s then
    return out
  end
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c == '"' then
      local buf = {}
      local j = i + 1
      while j <= n do
        local d = s:sub(j, j)
        if d == "\\" and j < n then
          buf[#buf + 1] = s:sub(j + 1, j + 1)
          j = j + 2
        elseif d == '"' then
          break
        else
          buf[#buf + 1] = d
          j = j + 1
        end
      end
      out[#out + 1] = table.concat(buf)
      i = j + 1
    else
      local j = s:find("%s", i) or (n + 1)
      out[#out + 1] = s:sub(i, j - 1)
      i = j
    end
  end
  return out
end

--- Join strings like Emacs combine-and-quote-strings: strings with
--- whitespace or quotes are quoted.
---@param list string[]
---@return string
function M.join_quoted(list)
  local parts = {}
  for _, s in ipairs(list) do
    if s:find('[%s"]') or s == "" then
      parts[#parts + 1] = '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
    else
      parts[#parts + 1] = s
    end
  end
  return table.concat(parts, " ")
end

--- The (type, path) pairs a `ROAM_REFS` entry stands for: `@key` and
--- `[cite:@key]` are citation keys, anything else a link (org-roam-db-insert-refs).
---@param ref string
---@return { type: string, path: string }[]
function M.parse_ref(ref)
  if ref:sub(1, 1) == "@" then
    return { { type = "cite", path = ref:sub(2) } }
  end
  if ref:match("^%[cite[/%w%-]*:") then
    local out = {}
    for key in ref:gmatch("@([^%s;%]]+)") do
      out[#out + 1] = { type = "cite", path = key }
    end
    return out
  end
  local target = ref:match("^%[%[(.-)%]%[.-%]%]$") or ref:match("^%[%[(.-)%]%]$") or ref
  local t, p = target:match("^([%a][%w+%-]*):(.*)$")
  if t then
    return { { type = t:lower(), path = p } }
  end
  return {}
end

local function display_title(s)
  return vim.trim(require("org.links").display_format(s or ""))
end

--- The id of the innermost node containing `hl` (a heading node, else the
--- file node), like org-roam-id-at-point.
local function source_id(hl, file_node, node_of)
  local h = hl
  while h do
    if node_of[h] then
      return node_of[h].id
    end
    h = h.parent
  end
  return file_node and file_node.id or nil
end

local function excluded(props)
  local v = props.ROAM_EXCLUDE
  return v ~= nil and v ~= "" and v ~= "nil"
end

-- links in these property drawer keys are not indexed
-- (org-roam-db-extra-links-exclude-keys)
local EXCLUDED_PROPERTY_LINKS = { ROAM_REFS = true }
-- and in these keywords (`#+transclude:`)
local EXCLUDED_KEYWORD_LINKS = { transclude = true }

--- Whether links on `line` are not indexed: comment and fixed-width lines
--- hold no links for Org, and some properties and keywords are excluded.
local function skip_links(line)
  if line:match("^%s*#%s") or line:match("^%s*#$") or line:match("^%s*:%s") or line:match("^%s*:$") then
    return true
  end
  local key = line:match("^%s*:([^:%s]+):")
  if key and EXCLUDED_PROPERTY_LINKS[key:upper()] then
    return true
  end
  local kw = line:match("^%s*#%+([^:%s]+):")
  return kw ~= nil and EXCLUDED_KEYWORD_LINKS[kw:lower()] == true
end

-- links within the file, which never point at a node
local LOCAL_TYPES = { fuzzy = true, heading = true, ["custom-id"] = true, coderef = true, radio = true }

--- Parse one file into nodes and links.
---@param path string
---@param file? org.File a parse to use instead of loading `path`
---@return org.roam.Node[] nodes, org.roam.Link[] links
function M.parse_file(path, file)
  file = file or files.get(path)
  local nodes, links = {}, {}
  if not file then
    return nodes, links
  end
  local node_of = {}
  local file_node
  local fid = file.properties and file.properties.ID
  if fid and fid ~= "" and not excluded(file.properties) then
    local rel = M.relative(path) or vim.fn.fnamemodify(path, ":t")
    file_node = {
      id = fid,
      file = path,
      level = 0,
      lnum = 1,
      title = display_title(file.settings.title or rel:gsub("%.org$", "")),
      aliases = M.split_quoted(file.properties.ROAM_ALIASES),
      refs = M.split_quoted(file.properties.ROAM_REFS),
      tags = vim.deepcopy(file.settings.filetags or {}),
      olp = {},
    }
    nodes[#nodes + 1] = file_node
  end
  for _, hl in ipairs(file.headlines) do
    local id = hl.properties.ID
    if id and id ~= "" and not excluded(hl.properties) and not hl.inlinetask then
      local title = display_title(hl.title)
      if title ~= "" then
        local node = {
          id = id,
          file = path,
          level = hl.level,
          lnum = hl.line,
          title = title,
          aliases = M.split_quoted(hl.properties.ROAM_ALIASES),
          refs = M.split_quoted(hl.properties.ROAM_REFS),
          tags = hl:get_tags(),
          olp = hl:outline_path(),
          todo = hl.todo,
          priority = hl.priority,
        }
        node_of[hl] = node
        nodes[#nodes + 1] = node
      end
    end
  end
  -- links and citations, skipping verbatim blocks, comments and ROAM_REFS
  -- values
  local lk = require("org.links")
  local lines = file.lines
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local block_end = parser.verbatim_block_end(lines, i, #lines)
    if block_end then
      i = block_end + 1
    else
      if line:find(":", 1, true) and not skip_links(line) then
        local src = source_id(file:headline_at(i), file_node, node_of)
        if src then
          for _, l in ipairs(lk.real_links(line)) do
            local cites = l.type == "fuzzy" and l.path:match("^cite[%w]*:(.+)$")
            if cites then
              -- org-ref style cite:key1,key2
              for k in cites:gmatch("[^,%s]+") do
                local key = k:gsub("^&", "")
                links[#links + 1] = { source = src, type = "cite", path = key, lnum = i, col = l.start_col }
              end
            elseif l.type and l.path and not LOCAL_TYPES[l.type] then
              local p = l.path:gsub("::.*$", "")
              links[#links + 1] = { source = src, type = l.type, path = p, lnum = i, col = l.start_col }
            end
          end
          for body, s in line:gmatch("%[cite[/%w%-]*:([^%]]*)%]()") do
            for k in body:gmatch("@([^%s;%]]+)") do
              links[#links + 1] = { source = src, type = "cite", path = k, lnum = i, col = s }
            end
          end
        end
      end
      i = i + 1
    end
  end
  return nodes, links
end

---------------------------------------------------------------------------
-- The index
---------------------------------------------------------------------------

local function empty()
  return { version = VERSION, directory = M.directory(), files = {} }
end

local function load()
  if index and index.directory == M.directory() then
    return index
  end
  lookup = nil
  local data = utils.read_json(index_path())
  if type(data) == "table" and data.version == VERSION and data.directory == M.directory() then
    index = data
    index.files = type(index.files) == "table" and index.files or {}
  else
    index = empty()
  end
  return index
end

-- a write of the index waiting in `save_later`: { timer, path, data }
local pending = nil

local function write(path, data)
  local ok, err = pcall(utils.write_json, path, data)
  if not ok then
    utils.warn("org-roam: cannot write the index: " .. tostring(err))
  end
end

--- Write a pending index change now (on exit, before a reset).
function M.flush()
  local p = pending
  if not p then
    return
  end
  pending = nil
  p.timer:stop()
  p.timer:close()
  -- a roam directory that is gone has nothing left to cache
  if utils.is_dir(p.data.directory) then
    write(p.path, p.data)
  end
end

local function save()
  if pending then
    pending.timer:stop()
    pending.timer:close()
    pending = nil
  end
  write(index_path(), index)
end

-- The index of a large directory takes tens of milliseconds to encode:
-- after a single file changed (each save of a note), write it a second
-- after the first save, once for every save in between. The index in
-- memory is current; `flush` writes it early (on exit, before a reset).
local SAVE_DELAY = 1000

local function save_later()
  if pending then
    pending.path, pending.data = index_path(), index
    return
  end
  local timer = assert(vim.uv.new_timer())
  pending = { timer = timer, path = index_path(), data = index }
  timer:start(SAVE_DELAY, 0, vim.schedule_wrap(M.flush))
end

local function stat(path)
  local st = vim.uv.fs_stat(path)
  return st and st.mtime.sec, st and st.mtime.nsec
end

local function register_ids(entries)
  local map = {}
  for _, e in ipairs(entries) do
    for _, n in ipairs(e.nodes) do
      local indexed = M.node(n.id)
      map[n.id] = indexed and indexed.file or n.file
    end
  end
  if next(map) then
    require("org.id").register_many(map)
  end
end

--- The parse of `path`: its buffer's, else read from disk now. Not
--- through org.files' cache: that would keep every note of a large
--- directory in memory, and trust an mtime that a quick rewrite leaves
--- unchanged.
---@param path string
---@return org.File|nil
local function fresh_parse(path)
  files.invalidate(path)
  local b = utils.find_buffer(path)
  if b then
    return files.get_buffer(b)
  end
  local lines = utils.readfile(path)
  return lines and parser.parse(lines, path) or nil
end

--- Index one file now (after a save), or drop it when it is gone or no
--- longer a roam file. Returns true when the index changed.
---@param path string
---@param file? org.File
---@return boolean
function M.update_file(path, file)
  path = vim.fs.normalize(path)
  local idx = load()
  if not M.is_roam_file(path) or not utils.exists(path) then
    if idx.files[path] then
      idx.files[path] = nil
      lookup = nil
      save_later()
      return true
    end
    return false
  end
  local sec, nsec = stat(path)
  local nodes, links = M.parse_file(path, file or fresh_parse(path))
  local entry = { sec = sec, nsec = nsec, nodes = nodes, links = links }
  idx.files[path] = entry
  lookup = nil
  save_later()
  register_ids({ entry })
  return true
end

--- Bring the index up to date with the directory (org-roam-db-sync):
--- parse new and changed files, drop deleted ones. With `force`, re-parse
--- everything. Returns the number of files parsed and removed.
---@param force? boolean
---@return integer parsed, integer removed
function M.sync(force)
  local idx = load()
  if force then
    idx = empty()
    index = idx
  end
  local seen, parsed, removed = {}, 0, 0
  local changed = {}
  for _, path in ipairs(M.list_files()) do
    seen[path] = true
    local sec, nsec = stat(path)
    local e = idx.files[path]
    if not e or e.sec ~= sec or e.nsec ~= nsec then
      local nodes, links = M.parse_file(path, fresh_parse(path))
      e = { sec = sec, nsec = nsec, nodes = nodes, links = links }
      idx.files[path] = e
      changed[#changed + 1] = e
      parsed = parsed + 1
    end
  end
  for path in pairs(idx.files) do
    if not seen[path] then
      idx.files[path] = nil
      removed = removed + 1
    end
  end
  if parsed > 0 or removed > 0 or force then
    lookup = nil
    save()
    register_ids(changed)
  end
  return parsed, removed
end

--- `:Org roam_db_sync` (a count or `force` rebuilds everything).
---@param arg? string
function M.sync_command(arg)
  local force = (arg and arg:match("force")) or vim.v.count > 0
  local parsed, removed = M.sync(force and true or false)
  local n = #M.nodes()
  utils.notify(string.format("org-roam: %d nodes (%d files parsed, %d removed)", n, parsed, removed))
end

local function build()
  if lookup then
    return lookup
  end
  local idx = load()
  lookup = { nodes = {}, by_id = {}, backlinks = {}, reflinks = {}, duplicates = {} }
  local paths = vim.tbl_keys(idx.files)
  table.sort(paths)
  for _, path in ipairs(paths) do
    local e = idx.files[path]
    for _, n in ipairs(e.nodes or {}) do
      local first = lookup.by_id[n.id]
      if first then
        -- org-roam's database refuses a second node with the same id
        local d = lookup.duplicates[n.id] or { first }
        d[#d + 1] = n
        lookup.duplicates[n.id] = d
      else
        lookup.nodes[#lookup.nodes + 1] = n
        lookup.by_id[n.id] = n
      end
    end
    for _, l in ipairs(e.links or {}) do
      l.file = path
      if l.type == "id" then
        local t = lookup.backlinks[l.path] or {}
        t[#t + 1] = l
        lookup.backlinks[l.path] = t
      else
        local t = lookup.reflinks[l.path] or {}
        t[#t + 1] = l
        lookup.reflinks[l.path] = t
      end
    end
  end
  return lookup
end

--- Drop the in-memory index (tests; a changed directory).
function M.reset()
  M.flush()
  index = nil
  lookup = nil
  dir_cache = { from = nil, dir = nil }
  exclude_cache = { from = nil, list = {} }
end

--- Ids used by more than one node: id -> the nodes, the indexed one first.
--- Only the first node (in path order) of a duplicated id is indexed.
---@return table<string, org.roam.Node[]>
function M.duplicates()
  return build().duplicates
end

--- All nodes, in file order.
---@return org.roam.Node[]
function M.nodes()
  return build().nodes
end

--- Every indexed link, in file order.
---@return org.roam.Link[]
function M.links()
  local idx = load()
  local paths = vim.tbl_keys(idx.files)
  table.sort(paths)
  local out = {}
  for _, path in ipairs(paths) do
    for _, l in ipairs(idx.files[path].links or {}) do
      l.file = path
      out[#out + 1] = l
    end
  end
  return out
end

--- The node with `id`.
---@param id string
---@return org.roam.Node|nil
function M.node(id)
  return id and build().by_id[id] or nil
end

--- The node whose title or alias is `name` (org-roam-node-from-title-or-alias).
---@param name string
---@return org.roam.Node|nil
function M.by_title(name)
  for _, n in ipairs(build().nodes) do
    if n.title == name then
      return n
    end
  end
  for _, n in ipairs(build().nodes) do
    for _, a in ipairs(n.aliases) do
      if a == name then
        return n
      end
    end
  end
end

--- The node with a ref matching `ref` (org-roam-node-from-ref).
---@param ref string
---@return org.roam.Node|nil
function M.by_ref(ref)
  local want = M.parse_ref(ref)[1]
  if not want then
    return nil
  end
  for _, n in ipairs(build().nodes) do
    for _, r in ipairs(n.refs) do
      for _, p in ipairs(M.parse_ref(r)) do
        if p.path == want.path then
          return n
        end
      end
    end
  end
end

--- `id:` links to `id` (org-roam-backlinks-get), each with its source node.
---@param id string
---@return { link: org.roam.Link, source: org.roam.Node }[]
function M.backlinks(id)
  local out = {}
  local by_id = build().by_id
  for _, l in ipairs(build().backlinks[id] or {}) do
    local src = by_id[l.source]
    if src then
      out[#out + 1] = { link = l, source = src }
    end
  end
  return out
end

--- Links and citations to one of the node's refs from other nodes
--- (org-roam-reflinks-get).
---@param node org.roam.Node
---@return { link: org.roam.Link, source: org.roam.Node, ref: string }[]
function M.reflinks(node)
  local out, seen = {}, {}
  local l = build()
  for _, r in ipairs(node.refs) do
    for _, p in ipairs(M.parse_ref(r)) do
      for _, link in ipairs(l.reflinks[p.path] or {}) do
        local src = l.by_id[link.source]
        local key = link.file .. ":" .. link.lnum .. ":" .. link.col
        if src and src.id ~= node.id and not seen[key] then
          seen[key] = true
          out[#out + 1] = { link = link, source = src, ref = r }
        end
      end
    end
  end
  return out
end

-- lines of roam files by path, kept while the mtime is unchanged
local line_cache = {}

local function file_lines(path)
  local b = utils.find_buffer(path)
  if b and vim.bo[b].modified then
    return vim.api.nvim_buf_get_lines(b, 0, -1, false)
  end
  local sec, nsec = stat(path)
  local c = line_cache[path]
  if c and c.sec == sec and c.nsec == nsec then
    return c.lines
  end
  local lines = utils.readfile(path) or {}
  line_cache[path] = { sec = sec, nsec = nsec, lines = lines }
  return lines
end

-- `line` with every bracketed [...] (links, cookies, citations) blanked,
-- balanced like org-roam's `\[([^[]]++|(?R))*\]`
local function mask_brackets(line)
  if not line:find("[", 1, true) then
    return line
  end
  local out, depth, start = {}, 0, nil
  local i = 1
  local n = #line
  while i <= n do
    local c = line:sub(i, i)
    if c == "[" then
      if depth == 0 then
        start = i
      end
      depth = depth + 1
    elseif c == "]" and depth > 0 then
      depth = depth - 1
      if depth == 0 then
        out[#out + 1] = string.rep(" ", i - start + 1)
        start = nil
      end
    elseif depth == 0 then
      out[#out + 1] = c
    end
    i = i + 1
  end
  if start then
    -- an unclosed [ is plain text
    out[#out + 1] = line:sub(start)
  end
  return table.concat(out)
end

local function lower(s)
  return s:find("[\128-\255]") and vim.fn.tolower(s) or s:lower()
end

local function word_char(c)
  return c ~= "" and c:match("[%w_]") ~= nil
end

--- Mentions of the node's title or aliases that are not links, in other
--- roam files (org-roam-unlinked-references-section): whole words,
--- ignoring case, outside brackets.
---@param node org.roam.Node
---@return { file: string, lnum: integer, col: integer, text: string, match: string }[]
function M.unlinked_references(node)
  local names = {}
  for _, t in ipairs(vim.list_extend({ node.title }, node.aliases or {})) do
    if t and vim.trim(t) ~= "" then
      names[#names + 1] = lower(t)
    end
  end
  local out = {}
  if #names == 0 then
    return out
  end
  local own = vim.fs.normalize(node.file)
  local paths = vim.tbl_keys(load().files)
  table.sort(paths)
  for _, path in ipairs(paths) do
    if path ~= own then
      for lnum, line in ipairs(file_lines(path)) do
        local masked = lower(mask_brackets(line))
        -- every match, like rg --only-matching; a title and an alias
        -- starting at the same place count once
        local hits = {}
        for _, name in ipairs(names) do
          local init = 1
          while true do
            local s, e = masked:find(name, init, true)
            if not s then
              break
            end
            if not word_char(masked:sub(s - 1, s - 1)) and not word_char(masked:sub(e + 1, e + 1)) then
              if not hits[s] or e > hits[s] then
                hits[s] = e
              end
            end
            init = s + 1
          end
        end
        local cols = vim.tbl_keys(hits)
        table.sort(cols)
        for _, s in ipairs(cols) do
          out[#out + 1] = { file = path, lnum = lnum, col = s, text = line, match = line:sub(s, hits[s]) }
        end
      end
    end
  end
  return out
end

--- Counts for `:checkhealth`.
---@return { files: integer, nodes: integer, links: integer, path: string }
function M.stats()
  local idx = load()
  local nfiles, nlinks = 0, 0
  for _, e in pairs(idx.files) do
    nfiles = nfiles + 1
    nlinks = nlinks + #(e.links or {})
  end
  return { files = nfiles, nodes = #M.nodes(), links = nlinks, path = index_path() }
end

return M

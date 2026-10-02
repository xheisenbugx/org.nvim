---@mod org.extensions.lsp.targets Links, what they point at, and back
---
--- Resolves links without moving the cursor (for definition, hover and
--- document links), finds the thing at a position that links can point at
--- (a headline, a CUSTOM_ID or ID, a `<<target>>`, a `#+NAME:`, a radio
--- target, a footnote or a file) and every link pointing at it across the
--- workspace (references, rename, backlink counts).
---
--- Internal links resolve like `org.links.search_in_buffer`: `#id` is a
--- CUSTOM_ID, `*Title` a headline, anything else a dedicated target, then
--- a `#+NAME:`, then a headline title (case and blanks ignored).

local links = require("org.links")
local util = require("org.extensions.lsp.util")

local M = {}

---------------------------------------------------------------------------
-- Per-file indexes (weak on the parsed file, which changes with the text)
---------------------------------------------------------------------------

local link_cache = setmetatable({}, { __mode = "k" })
local index_cache = setmetatable({}, { __mode = "k" })

--- Normalized key of a fuzzy search or a title: words, upper-cased.
function M.key(s)
  local words = vim.split(vim.trim(s or ""), "%s+", { trimempty = true })
  return table.concat(words, " "):upper()
end

local function heading_key(hl)
  return M.key(links.normalize_string(hl.title or ""))
end

--- Lines that hold no links, targets or radio targets (blocks, comments,
--- drawers, keywords), cached per file.
local function ignored(file)
  local c = link_cache[file]
  if c and c.ignored then
    return c.ignored
  end
  c = c or {}
  c.ignored = links.ignored_lines(file.lines)
  link_cache[file] = c
  return c.ignored
end

--- `<<target>>` and `<<<radio>>>` spans of a line: { s, e, text, radio, ts, te }
--- where ts..te is the text inside the brackets.
function M.line_targets(line)
  local out = {}
  local init = 1
  while true do
    local s = line:find("<<", init, true)
    if not s then
      break
    end
    local radio = line:sub(s + 2, s + 2) == "<"
    local open = radio and 3 or 2
    local close = radio and ">>>" or ">>"
    local ce = line:find(close, s + open, true)
    local text = ce and line:sub(s + open, ce - 1)
    if
      text
      and text ~= ""
      and not text:find("[<>\n]")
      and not text:match("^%s")
      and not text:match("%s$")
      and line:sub(s - 1, s - 1) ~= "<"
      and line:sub(ce + #close, ce + #close) ~= ">"
    then
      out[#out + 1] = {
        s = s,
        e = ce + #close - 1,
        ts = s + open,
        te = ce - 1,
        text = text,
        radio = radio,
      }
      init = ce + #close
    else
      init = s + 2
    end
  end
  return out
end

--- Index of a file: headlines by title key, CUSTOM_ID (lower-cased) and
--- ID, targets and names by key, radio targets.
function M.index(file)
  local idx = index_cache[file]
  if idx then
    return idx
  end
  idx = { headings = {}, custom_ids = {}, ids = {}, targets = {}, names = {}, radios = {} }
  -- a file-level ID (an org-roam file node)
  idx.file_id = file.properties and file.properties.ID
  for _, hl in ipairs(file.headlines) do
    local k = heading_key(hl)
    if k ~= "" and not idx.headings[k] then
      idx.headings[k] = hl
    end
    local cid = hl.properties.CUSTOM_ID
    if cid and not idx.custom_ids[cid:lower()] then
      idx.custom_ids[cid:lower()] = hl
    end
    local id = hl.properties.ID
    if id and not idx.ids[id] then
      idx.ids[id] = hl
    end
  end
  local skip = ignored(file)
  for lnum, line in ipairs(file.lines) do
    -- the value's column: the name may also spell the keyword (#+name: name)
    local s, name = line:match("^[ \t]*#%+[Nn][Aa][Mm][Ee]:[ \t]+()(.-)[ \t]*$")
    if name and name ~= "" then
      local k = M.key(name)
      if not idx.names[k] then
        idx.names[k] = { lnum = lnum, s = s, e = s + #name - 1, text = name }
      end
    elseif not skip[lnum] and line:find("<<", 1, true) then
      for _, t in ipairs(M.line_targets(line)) do
        local item = { lnum = lnum, s = t.ts, e = t.te, text = t.text, span = { t.s, t.e } }
        if t.radio then
          idx.radios[#idx.radios + 1] = item
        end
        -- a radio target is also a target (org-link-search finds <<<x>>>
        -- through <<x>>)
        local k = M.key(t.text)
        if not idx.targets[k] then
          idx.targets[k] = item
        end
      end
    end
  end
  index_cache[file] = idx
  return idx
end

--- Most lines a bracket link may span (Org allows line breaks in a
--- link's path and description, within a paragraph).
M.MAX_LINK_LINES = 5

--- Line and column of a 1-based offset into a link's text (links that
--- span lines are parsed from their lines joined with "\n").
---@param link org.Link
---@param off integer
---@return integer lnum, integer col
function M.link_pos(link, off)
  local starts = link.starts
  if not starts then
    return link.lnum, off
  end
  local k = 1
  while starts[k + 1] and starts[k + 1] <= off do
    k = k + 1
  end
  return link.lnum + k - 1, off - starts[k] + 1
end

--- LSP range of a link (which may span lines).
---@param link org.Link
function M.link_range(link)
  if link.end_lnum then
    local el, ec = M.link_pos(link, link.end_col)
    return util.range(link.lnum, link.start_col, ec, el)
  end
  return util.range(link.lnum, link.start_col, link.end_col)
end

-- Bracket links that start on line `lnum` (at a "[[" no link of the line
-- covers) and end on a later line of the same paragraph.
local function spanning_links(lines, lnum, singles, skip)
  local line = lines[lnum]
  local first
  local init = 1
  while true do
    local p = line:find("[[", init, true)
    if not p then
      break
    end
    local inside = false
    for _, l in ipairs(singles) do
      if p >= l.start_col and p <= l.end_col then
        inside = true
        break
      end
    end
    if not inside then
      first = p
      break
    end
    init = p + 2
  end
  if not first then
    return nil
  end
  local parts, starts = { line }, { 1 }
  local pos = #line + 2
  for k = lnum + 1, math.min(#lines, lnum + M.MAX_LINK_LINES - 1) do
    local l = lines[k]
    if skip[k] or l:match("^%s*$") or l:match("^%*+%s") then
      break
    end
    parts[#parts + 1] = l
    starts[#starts + 1] = pos
    pos = pos + #l + 1
  end
  if #parts == 1 then
    return nil
  end
  local out
  local verbatim = links.verbatim_spans(line)
  for _, l in ipairs(links.parse_links(table.concat(parts, "\n"), { bracket_only = true })) do
    if l.start_col >= first and l.start_col <= #line and l.end_col > #line then
      local in_verbatim = false
      for _, sp in ipairs(verbatim) do
        if l.start_col >= sp[1] and l.start_col <= sp[2] then
          in_verbatim = true
        end
      end
      if not in_verbatim then
        l.lnum, l.starts = lnum, starts
        l.end_lnum = M.link_pos(l, l.end_col)
        out = out or {}
        out[#out + 1] = l
      end
    end
  end
  return out
end

--- Links of a document: { lnum, link } for every line that can hold one
--- (links spanning lines included, on their first line). Links in text
--- the transclusion extension inserted are left out.
---@param doc org.lsp.Doc
---@return { lnum: integer, link: org.Link }[]
function M.doc_links(doc)
  local file = doc.file
  local c = link_cache[file] or {}
  link_cache[file] = c
  if not c.links then
    local skip = ignored(file)
    local out, multi = {}, {}
    local lines = file.lines
    for lnum, line in ipairs(lines) do
      if not skip[lnum] and (line:find("[[", 1, true) or line:find(":", 1, true)) then
        local singles = links.real_links(line)
        for _, l in ipairs(singles) do
          l.lnum = lnum
          out[#out + 1] = { lnum = lnum, link = l }
        end
        local span = line:find("[[", 1, true) and spanning_links(lines, lnum, singles, skip)
        for _, l in ipairs(span or {}) do
          out[#out + 1] = { lnum = lnum, link = l }
          multi[#multi + 1] = l
        end
      end
    end
    c.links, c.multi = out, multi
  end
  if doc.foreign then
    return vim.tbl_filter(function(item)
      return not doc.foreign[item.lnum]
    end, c.links)
  end
  return c.links
end

--- Link at a 1-based line and byte column, or nil.
function M.link_at(doc, lnum, col)
  if ignored(doc.file)[lnum] then
    return nil
  end
  for _, l in ipairs(links.real_links(doc.lines[lnum] or "")) do
    if col >= l.start_col and col <= l.end_col then
      l.lnum = lnum
      return l
    end
  end
  M.doc_links(doc)
  for _, l in ipairs(link_cache[doc.file].multi) do
    if lnum >= l.lnum and lnum <= l.end_lnum then
      local el, ec = M.link_pos(l, l.end_col)
      if (lnum > l.lnum or col >= l.start_col) and (lnum < el or col <= ec) then
        return l
      end
    end
  end
end

---------------------------------------------------------------------------
-- Resolving
---------------------------------------------------------------------------

local FILE_TYPES = { file = true, ["file+sys"] = true, ["file+emacs"] = true }
local INTERNAL = { ["custom-id"] = true, heading = true, fuzzy = true }

--- What a link names: `{ kind = "id", id, search }`, `{ kind = "file",
--- path, search }` (internal links are "file" links to their own file), or
--- nil for other link types.
---@param doc org.lsp.Doc
---@param link org.Link
function M.split(doc, link)
  local t = link.type
  if t == "id" then
    local id, search = link.path:match("^(.-)::(.*)$")
    return { kind = "id", id = vim.trim(id or link.path), search = search }
  elseif FILE_TYPES[t] then
    local p, search = link.path:match("^(.-)::(.*)$")
    p = p or link.path
    local path
    if p == "" then
      path = doc.path
    else
      local base = doc.path and vim.fs.dirname(doc.path) or vim.fn.getcwd()
      path = util.resolve(p, base)
    end
    return path and { kind = "file", path = path, search = search ~= "" and search or nil } or nil
  elseif INTERNAL[t] and doc.path then
    return { kind = "file", path = doc.path, search = link.target, internal = true }
  end
end

--- `split` of a link of a cached document link list, remembered on the
--- link (for the document's file name).
local function split_cached(doc, link)
  local key = doc.path or ""
  if link._split_key ~= key then
    link._split_key = key
    link._split = M.split(doc, link) or false
  end
  return link._split or nil
end

--- Form of a search option: "custom_id", "heading", "fuzzy", "line" or
--- "other" (coderefs and regexps).
function M.search_form(search)
  if not search then
    return nil
  end
  local s = vim.trim(search)
  if s:sub(1, 1) == "#" then
    return "custom_id"
  elseif s:sub(1, 1) == "*" then
    return "heading"
  elseif s:match("^%d+$") then
    return "line"
  elseif s:match("^%(.*%)$") or s:match("^/.*/$") then
    return "other"
  end
  return "fuzzy"
end

local function heading_loc(path, hl)
  local s, e = util.title_span(hl)
  return { path = path, lnum = hl.line, s = s, e = e, kind = "heading", headline = hl }
end

--- Location of a search in a file: `{ path, lnum, s, e, kind, headline? }`
--- with kind "file", "line", "heading", "target", "radio" or "name".
---@param path string
---@param search? string
---@return table|nil
function M.locate(path, search)
  if not util.is_org(path) then
    -- another kind of file: only its start or a line number (it is not
    -- parsed as Org)
    if not vim.uv.fs_stat(path) and not util.buffer_of(path) then
      return nil
    end
    local n = search and tonumber(vim.trim(search))
    return { path = path, lnum = n or 1, s = 1, e = 0, kind = n and "line" or "file" }
  end
  local file = util.file(path)
  if not file then
    return nil
  end
  if not search or vim.trim(search) == "" then
    return { path = path, lnum = 1, s = 1, e = 0, kind = "file" }
  end
  local form = M.search_form(search)
  local s = vim.trim(search)
  local idx = M.index(file)
  if form == "custom_id" then
    local hl = idx.custom_ids[s:sub(2):lower()]
    return hl and heading_loc(path, hl) or nil
  elseif form == "heading" then
    local hl = idx.headings[M.key(links.normalize_string(s:sub(2)))]
    return hl and heading_loc(path, hl) or nil
  elseif form == "line" then
    local n = tonumber(s)
    return n <= #file.lines and { path = path, lnum = n, s = 1, e = 0, kind = "line" } or nil
  elseif form == "fuzzy" then
    local k = M.key(s)
    local t = idx.targets[k]
    if t then
      local radio = t.span and file.lines[t.lnum]:sub(t.span[1], t.span[1] + 2) == "<<<"
      return { path = path, lnum = t.lnum, s = t.s, e = t.e, kind = radio and "radio" or "target", text = t.text }
    end
    local n = idx.names[k]
    if n then
      return { path = path, lnum = n.lnum, s = n.s, e = n.e, kind = "name", text = n.text }
    end
    local hl = idx.headings[k]
    return hl and heading_loc(path, hl) or nil
  end
end

--- Where the entry with an ID lives: the workspace documents first, then
--- the ID database (org.id).
---@param id string
---@param docs? org.lsp.Doc[] documents already loaded
function M.locate_id(id, docs)
  local function file_loc(path)
    return { path = path, lnum = 1, s = 1, e = 0, kind = "file", file_id = id }
  end
  for _, d in ipairs(docs or {}) do
    local idx = M.index(d.file)
    local hl = idx.ids[id]
    if hl and d.path then
      return heading_loc(d.path, hl)
    elseif idx.file_id == id and d.path then
      return file_loc(d.path)
    end
  end
  -- after a miss, the rest of the request looks IDs up in one index of
  -- the workspace instead of rescanning the ID files for each
  local miss = util.scoped("ids")
  if miss.all then
    if miss.all[id] or not miss.known[id] then
      return miss.all[id]
    end
  end
  local ok, r = pcall(require("org.id").find, id)
  if ok and r and r.filename then
    local path = util.canon(r.filename)
    local file = util.file(path)
    local idx = file and M.index(file)
    if idx and idx.ids[id] then
      return heading_loc(path, idx.ids[id])
    elseif idx and idx.file_id == id then
      return file_loc(path)
    end
    return { path = path, lnum = r.lnum or 1, s = 1, e = 0, kind = "file" }
  end
  if miss.all then
    return nil
  end
  -- not in the ID files: the workspace (an org-roam directory as
  -- org_directory, say)
  local all = {}
  for _, path in ipairs(util.workspace_files()) do
    local file = util.file(path)
    local idx = file and M.index(file)
    if idx then
      for k, hl in pairs(idx.ids) do
        all[k] = all[k] or heading_loc(path, hl)
      end
      local fid = idx.file_id
      if fid and not all[fid] then
        all[fid] = { path = path, lnum = 1, s = 1, e = 0, kind = "file", file_id = fid }
      end
    end
  end
  miss.all, miss.known = all, {}
  local okk, known = pcall(require("org.id").known_ids)
  for _, k in ipairs(okk and known or {}) do
    miss.known[k] = true
  end
  return all[id]
end

--- Resolve a link of `doc` to a location, or nil.
---@param doc org.lsp.Doc
---@param link org.Link
-- A `code:` link of the code extension: its file, and the line of its
-- symbol found by a text search (no buffer is loaded, no LSP asked).
local function resolve_code(doc, link)
  if not require("org.extensions").loaded.code then
    return nil
  end
  local ok, loc = pcall(function()
    local cl = require("org.extensions.code.link")
    local file, target = cl.split(link.path)
    local path = cl.resolve(file, doc.bufnr or vim.api.nvim_get_current_buf())
    if not path then
      return nil
    end
    path = util.canon(path)
    if not target or target:match("^%d+$") then
      return M.locate(path, target)
    end
    local b = util.buffer_of(path)
    local lines = b and vim.api.nvim_buf_get_lines(b, 0, -1, false) or require("org.utils").readfile(path)
    local found = lines and require("org.extensions.code.symbols").text_find(lines, target)
    if not found then
      return { path = path, lnum = 1, s = 1, e = 0, kind = "file" }
    end
    local word = target:match("[%w_]+$") or target
    return { path = path, lnum = found.lnum, s = found.col + 1, e = found.col + #word, kind = "code" }
  end)
  return ok and loc or nil
end

function M.resolve(doc, link)
  if link.type == "code" then
    return resolve_code(doc, link)
  end
  local sp = M.split(doc, link)
  if not sp then
    if link.type == "radio" then
      return M.locate(doc.path, link.path)
    end
    -- a link type that can say where it points (the code extension's code:)
    local lt = (require("org.config").opts.links.types or {})[link.type]
    if type(lt) == "table" and type(lt.locate) == "function" then
      local ok, loc = pcall(lt.locate, link.path, doc.path or doc.bufnr)
      if ok and type(loc) == "table" and loc.path then
        local s = (loc.col or 0) + 1
        return { path = loc.path, lnum = loc.lnum or 1, s = s, e = s + (loc.len or 0) - 1, kind = "file" }
      end
    end
    return nil
  end
  if sp.kind == "id" then
    local loc = M.locate_id(sp.id, { doc })
    if loc and sp.search then
      return M.locate(loc.path, sp.search) or loc
    end
    return loc
  end
  return M.locate(sp.path, sp.search)
end

---------------------------------------------------------------------------
-- Radio links and footnotes
---------------------------------------------------------------------------

local function word_byte(c)
  return c ~= "" and (c:match("[%w_]") ~= nil or c:byte() >= 128)
end

--- Occurrences of a radio target's text in a line: { s, e }.
function M.radio_occurrences(line, text)
  local out = {}
  local pat = table.concat(vim.tbl_map(vim.pesc, vim.split(text:lower(), "%s+", { trimempty = true })), "%s+")
  if pat == "" then
    return out
  end
  local lower = line:lower()
  local init = 1
  while true do
    local s, e = lower:find(pat, init)
    if not s then
      break
    end
    if
      not word_byte(line:sub(s - 1, s - 1))
      and not word_byte(line:sub(e + 1, e + 1))
      and line:sub(s - 3, s - 1) ~= "<<<"
      and line:sub(s - 2, s - 1) ~= "<<"
    then
      out[#out + 1] = { s = s, e = e }
    end
    init = e + 1
  end
  return out
end

--- Radio link at a position: { s, e, target } or nil.
function M.radio_at(doc, lnum, col)
  if ignored(doc.file)[lnum] then
    return nil
  end
  local radios = M.index(doc.file).radios
  if #radios == 0 then
    return nil
  end
  local line = doc.lines[lnum] or ""
  for _, r in ipairs(radios) do
    for _, o in ipairs(M.radio_occurrences(line, r.text)) do
      if col >= o.s and col <= o.e then
        return { s = o.s, e = o.e, target = r }
      end
    end
  end
end

--- Footnote reference or definition label at a position:
--- { label, s, e, ls, le, definition } (ls..le spans the label).
function M.footnote_at(line, col)
  local init = 1
  while true do
    local s = line:find("[fn:", init, true)
    if not s then
      return nil
    end
    local label = line:match("^([^%]:%s]+)", s + 4)
    local ls, le = s + 4, s + 3 + #(label or "")
    local close = line:find("]", s, true)
    if label and close and col >= s and col <= close then
      return { label = label, s = s, e = close, ls = ls, le = le, definition = s == 1 }
    end
    init = s + 4
  end
end

--- Footnote definitions and references with a label in `lines`:
--- { lnum, ls, le, definition }.
function M.footnote_uses(lines, label)
  local out = {}
  local pat = "[fn:" .. label
  for lnum, line in ipairs(lines) do
    local init = 1
    while true do
      local s = line:find(pat, init, true)
      if not s then
        break
      end
      local after = line:sub(s + #pat, s + #pat)
      if after == "]" or after == ":" then
        out[#out + 1] = { lnum = lnum, ls = s + 4, le = s + 3 + #label, definition = s == 1 }
      end
      init = s + #pat
    end
  end
  return out
end

--- Definition of a footnote: { lnum, stop, text } or nil.
function M.footnote_definition(lines, label)
  for _, d in ipairs(require("org.footnotes").collect_definitions(lines)) do
    if d.label == label then
      return d
    end
  end
end

---------------------------------------------------------------------------
-- The thing at a position
---------------------------------------------------------------------------

---@class org.lsp.Subject
---@field kind "heading"|"custom_id"|"id"|"target"|"radio"|"name"|"footnote"|"file"
---@field path string file of the declaration
---@field lnum integer line of the declaration (the headline for heading kinds)
---@field s integer name span in the declaration line (1-based, inclusive)
---@field e integer
---@field name string current name (title, id, target text, label)
---@field headline? org.Headline
---@field decl_lnum? integer line holding the span when not `lnum` (property lines)

local function prop_span(file, hl, key)
  local r = hl.properties_range
  if not r then
    return nil
  end
  for lnum = r[1], r[2] do
    local line = file.lines[lnum]
    local k, vs, v = line:match("^%s*:([^:%s]+):()%s*(.-)%s*$")
    if k and k:upper() == key and v ~= "" then
      local s = line:find(v, vs, true)
      return lnum, s, s + #v - 1, v
    end
  end
end

--- Subject for a location (the target of a link) in a form: the link
--- form decides whether a heading is renamed by its title, its CUSTOM_ID
--- or its ID.
---@param loc table from `locate`
---@param form? "heading"|"custom_id"|"id"
---@return org.lsp.Subject|nil
function M.subject_of(loc, form)
  if not loc then
    return nil
  end
  if loc.kind == "heading" then
    local hl = loc.headline
    local file = util.file(loc.path)
    if (form == "custom_id" or form == "id") and file then
      local key = form == "id" and "ID" or "CUSTOM_ID"
      local lnum, s, e, v = prop_span(file, hl, key)
      if lnum then
        return { kind = form, path = loc.path, lnum = hl.line, decl_lnum = lnum, s = s, e = e, name = v, headline = hl }
      end
    end
    return { kind = "heading", path = loc.path, lnum = hl.line, s = loc.s, e = loc.e, name = hl.title, headline = hl }
  elseif loc.kind == "target" or loc.kind == "radio" or loc.kind == "name" then
    return { kind = loc.kind, path = loc.path, lnum = loc.lnum, s = loc.s, e = loc.e, name = loc.text }
  elseif loc.kind == "file" then
    local file = form == "id" and loc.file_id and util.file(loc.path)
    if file and file.properties_range then
      -- the file-level ID (an org-roam file node)
      local lnum, s, e, v = prop_span(file, file, "ID")
      if lnum then
        return {
          kind = "id",
          path = loc.path,
          lnum = lnum,
          decl_lnum = lnum,
          s = s,
          e = e,
          name = v,
          file_level = true,
        }
      end
    end
    return { kind = "file", path = loc.path, lnum = 1, s = 1, e = 0, name = vim.fs.basename(loc.path) }
  end
end

--- The subject at a position: a link's target, a footnote, a target, a
--- `#+NAME:`, a CUSTOM_ID or ID property, a headline or `#+TITLE:`.
---@param doc org.lsp.Doc
---@param lnum integer
---@param col integer 1-based byte column
---@return org.lsp.Subject|nil subject, org.Link|nil link the position was on
function M.subject_at(doc, lnum, col)
  local line = doc.lines[lnum]
  if not line or not doc.path then
    return nil
  end
  local link = M.link_at(doc, lnum, col)
  if link then
    local sp = M.split(doc, link)
    if not sp then
      return nil, link
    end
    if sp.kind == "id" then
      local loc = M.locate_id(sp.id, { doc })
      return M.subject_of(loc, sp.search and nil or "id"), link
    end
    local form = M.search_form(sp.search)
    return M.subject_of(M.locate(sp.path, sp.search), form), link
  end
  local fn = M.footnote_at(line, col)
  if fn then
    return { kind = "footnote", path = doc.path, lnum = lnum, s = fn.ls, e = fn.le, name = fn.label }
  end
  for _, t in ipairs(M.line_targets(line)) do
    if col >= t.s and col <= t.e then
      return { kind = t.radio and "radio" or "target", path = doc.path, lnum = lnum, s = t.ts, e = t.te, name = t.text }
    end
  end
  local radio = M.radio_at(doc, lnum, col)
  if radio then
    local r = radio.target
    return { kind = "radio", path = doc.path, lnum = r.lnum, s = r.s, e = r.e, name = r.text }
  end
  local s, name = line:match("^[ \t]*#%+[Nn][Aa][Mm][Ee]:[ \t]+()(.-)[ \t]*$")
  if name and name ~= "" then
    return { kind = "name", path = doc.path, lnum = lnum, s = s, e = s + #name - 1, name = name }
  end
  local hl = doc.file:headline_at(lnum)
  local fr = doc.file.properties_range
  if not hl and fr and lnum >= fr[1] and lnum <= fr[2] then
    local k = line:match("^%s*:([^:%s]+):")
    if k and k:upper() == "ID" and M.index(doc.file).file_id then
      return M.subject_of({ kind = "file", path = doc.path, file_id = M.index(doc.file).file_id }, "id")
    end
  end
  if hl then
    local r = hl.properties_range
    if r and lnum >= r[1] and lnum <= r[2] then
      local k = line:match("^%s*:([^:%s]+):")
      k = k and k:upper()
      if k == "CUSTOM_ID" or k == "ID" then
        return M.subject_of(heading_loc(doc.path, hl), k == "ID" and "id" or "custom_id")
      end
    end
    if hl.line == lnum then
      return M.subject_of(heading_loc(doc.path, hl))
    end
  end
  if line:match("^%s*#%+[Tt][Ii][Tt][Ll][Ee]:") then
    return M.subject_of({ kind = "file", path = doc.path })
  end
  return nil
end

---------------------------------------------------------------------------
-- References
---------------------------------------------------------------------------

---@class org.lsp.Reference
---@field doc org.lsp.Doc
---@field lnum integer
---@field s integer
---@field e integer
---@field link? org.Link
---@field form? string "id", "custom_id", "heading", "fuzzy", "file", "line"
---@field split? table

local HEADING_KINDS = { heading = true, custom_id = true, id = true }

-- the location kind a link must land on to refer to a subject kind
local function lands_on(subject, loc)
  if HEADING_KINDS[subject.kind] then
    return loc.kind == "heading"
  elseif subject.kind == "target" or subject.kind == "radio" then
    return loc.kind == "target" or loc.kind == "radio"
  end
  return loc.kind == subject.kind
end

--- Every place that refers to the subject: links across the workspace
--- (radio links and footnote references in its own file).
---@param subject org.lsp.Subject
---@param docs? org.lsp.Doc[] default: the workspace, the subject's file first
---@return org.lsp.Reference[]
function M.references(subject, docs)
  local out = {}
  local home = util.doc_from_path(subject.path)
  if not home then
    return out
  end
  if subject.kind == "footnote" then
    for _, u in ipairs(M.footnote_uses(home.lines, subject.name)) do
      if not u.definition and not (home.foreign and home.foreign[u.lnum]) then
        out[#out + 1] = { doc = home, lnum = u.lnum, s = u.ls - 4, e = u.le + 1, form = "footnote" }
      end
    end
    return out
  end
  if subject.kind == "radio" then
    local skip = ignored(home.file)
    for lnum, line in ipairs(home.lines) do
      if not skip[lnum] and not (home.foreign and home.foreign[lnum]) then
        for _, o in ipairs(M.radio_occurrences(line, subject.name)) do
          out[#out + 1] = { doc = home, lnum = lnum, s = o.s, e = o.e, form = "radio" }
        end
      end
    end
    -- links to the radio target by name count too (fall through)
  end
  docs = docs or util.workspace_docs(home)
  -- id links count for an ID, a headline with one and a file with one
  local id
  if subject.kind == "id" then
    id = subject.name
  elseif HEADING_KINDS[subject.kind] and subject.headline then
    id = subject.headline.properties.ID
  elseif subject.kind == "file" then
    id = M.index(home.file).file_id
  end
  local memo = {}
  local function locate(path, search)
    local k = path .. "\0" .. (search or "")
    if memo[k] == nil then
      memo[k] = M.locate(path, search) or false
    end
    return memo[k] or nil
  end
  for _, d in ipairs(docs) do
    for _, item in ipairs(M.doc_links(d)) do
      local l = item.link
      local sp = split_cached(d, l)
      local form
      if sp and sp.kind == "id" then
        if id and sp.id == id and not sp.search then
          form = "id"
        end
      elseif sp and sp.path == subject.path then
        if subject.kind == "file" then
          form = "file"
        elseif sp.search then
          local loc = locate(sp.path, sp.search)
          if loc and loc.lnum == subject.lnum and lands_on(subject, loc) then
            form = M.search_form(sp.search)
          end
        end
      end
      if form then
        out[#out + 1] = { doc = d, lnum = item.lnum, s = l.start_col, e = l.end_col, link = l, form = form, split = sp }
        if l.end_lnum then
          local el, ec = M.link_pos(l, l.end_col)
          out[#out].end_lnum, out[#out].e = el, ec
        end
      end
    end
  end
  return out
end

--- Location of the subject's declaration (its name span).
function M.declaration(subject)
  local lnum = subject.decl_lnum or subject.lnum
  return util.location(subject.path, lnum, subject.s, subject.e)
end

return M

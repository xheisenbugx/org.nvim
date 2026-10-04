---@mod org.export.element.document Export parser: document and tree helpers
---
--- Parsing a document (org.export.element.parse) and walking the tree:
--- map, lineage, extract, position, siblings.
---
--- Part of org.export.element, which loads it.

local shared = require("org.export.element.shared")

local M = require("org.export.element")

local is_comment_line = shared.is_comment_line
local is_end_line = shared.is_end_line
local P = shared.P
local skip_blank = shared.skip_blank

---------------------------------------------------------------------------
-- Document
---------------------------------------------------------------------------

--- Fill paragraphs with objects (after the element tree is complete, so
--- that "first paragraph of an item" normalisation is known).
function P:fill(node)
  if node.type == "paragraph" and node.raw_lines then
    self:fill_paragraph(node, node.ignore_first_indent)
    return
  end
  for _, c in ipairs(node.contents or {}) do
    if c.type ~= "plain-text" and M.ELEMENTS[c.type] then
      self:fill(c)
    end
  end
end

--- Parse a whole document.
---@param lines string[]
---@return table org-data node
function P:parse(lines)
  local data = M.node("org-data", { post_blank = 0 })
  local L = lines
  local s = skip_blank(L, 1, #L)
  data.pre_blank = s - 1
  local kids = {}
  local i = s
  local mode = "first-section"
  -- top-level property drawer
  data.props = {}
  do
    local k = s
    while k <= #L and is_comment_line(L[k]) do
      k = k + 1
    end
    if L[k] and L[k]:match("^[ \t]*:[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Ii][Ee][Ss]:[ \t]*$") then
      local j = k + 1
      while j <= #L and not is_end_line(L[j]) do
        local key, value = L[j]:match("^[ \t]*:(%S+):[ \t]*(.-)[ \t]*$")
        if key then
          data.props[key:upper()] = value
        end
        j = j + 1
      end
    end
  end
  while i <= #L do
    if self:is_headline(L[i]) then
      local h, nxt = self:headline(L, i, #L)
      h.parent = data
      kids[#kids + 1] = h
      i = nxt
    elseif mode == "first-section" then
      local sec, nxt = self:section(L, i, #L, "first-section")
      sec.parent = data
      kids[#kids + 1] = sec
      i = nxt
    else
      i = i + 1
    end
    mode = nil
  end
  data.contents = kids
  return data
end

--- Convenience: parse lines with options.
function M.parse(lines, opts)
  return M.new(opts):parse(lines)
end

--- Parse objects of a string (secondary string).
function M.parse_secondary(s, restriction, opts, parent)
  return M.new(opts):secondary(s, restriction, parent)
end

--- Map `fn` over nodes of `types` (set or "*") in `data` (org-element-map).
---@param data table node or list of nodes
---@param types table|string
---@param fn fun(node: table): any
---@param opts? { first_match?: boolean, no_recursion?: table, ignore?: table, with_affiliated?: boolean }
function M.map(data, types, fn, opts)
  opts = opts or {}
  local want = types == "*" and true or (type(types) == "string" and { [types] = true } or types)
  local results = {}
  local done = false
  local ignore = opts.ignore or {}
  local function walk(d)
    if done or d == nil then
      return
    end
    if d.type == nil then
      for _, x in ipairs(d) do
        walk(x)
        if done then
          return
        end
      end
      return
    end
    if ignore[d] then
      return
    end
    if want == true or want[d.type] then
      local r = fn(d)
      if r ~= nil and r ~= false then
        if opts.first_match then
          results = r
          done = true
          return
        end
        results[#results + 1] = r
      end
    end
    if opts.no_recursion and opts.no_recursion[d.type] then
      return
    end
    if opts.with_affiliated and d.caption then
      for _, cap in ipairs(d.caption) do
        walk(cap[1])
        walk(cap[2])
      end
    end
    local sec = M.SECONDARY[d.type]
    if sec then
      for _, key in ipairs(sec) do
        if d[key] and d.type ~= "headline" and d.type ~= "inlinetask" and d.type ~= "item" then
          walk(d[key])
        end
      end
    end
    if d.type == "headline" or d.type == "inlinetask" then
      walk(d.title)
    elseif d.type == "item" and d.tag then
      walk(d.tag)
    elseif d.type == "citation-reference" then
      walk(d.prefix)
      walk(d.suffix)
    end
    for _, c in ipairs(d.contents or {}) do
      walk(c)
      if done then
        return
      end
    end
  end
  walk(data)
  if opts.first_match then
    return done and results or nil
  end
  return results
end

--- Ancestors of a node matching `types` (org-element-lineage).
function M.lineage(node, types, with_self)
  local want = type(types) == "string" and { [types] = true } or types
  local n = with_self and node or node.parent
  while n do
    if not want or want[n.type] then
      return n
    end
    n = n.parent
  end
end

--- Nearest enclosing element (org-element-parent-element).
function M.parent_element(node)
  local n = node.parent
  while n and not M.ELEMENTS[n.type] do
    n = n.parent
  end
  return n
end

--- Remove `node` from its parent's contents (org-element-extract).
function M.extract(node)
  local p = node.parent
  if not p then
    return node
  end
  for _, key in ipairs({ "contents", "title", "tag", "prefix", "suffix" }) do
    local list = p[key]
    if type(list) == "table" then
      for i, c in ipairs(list) do
        if c == node then
          table.remove(list, i)
          return node
        end
      end
    end
  end
  return node
end

local SIBLING_KEYS = { "contents", "title", "tag", "prefix", "suffix" }

-- node -> where it is among its parent's lists: index * 8 + the number of
-- the list's key in SIBLING_KEYS. Asked for each object of a paragraph, a
-- search of the list made the transcoders that look at neighbours
-- (footnote references, ...) quadratic in its length. An entry is checked
-- against the list before it is used, and the parent's lists are indexed
-- again when it is stale. The values are numbers: a weak table whose
-- values reach their keys (a list's nodes reach the list through
-- `.parent`) never lets them go, as LuaJIT has no ephemerons, and kept
-- every exported tree alive.
local positions = setmetatable({}, { __mode = "k" })

--- Index the nodes of `p`'s lists: the first list and the first index of
--- a node win, as a search would find them.
local function index_lists(p)
  for k = #SIBLING_KEYS, 1, -1 do
    local list = p[SIBLING_KEYS[k]]
    if type(list) == "table" then
      local n = 0
      while list[n + 1] ~= nil do
        n = n + 1
      end
      for i = n, 1, -1 do
        local c = list[i]
        if type(c) == "table" then
          positions[c] = i * 8 + k
        end
      end
    end
  end
end

--- The list of `p` holding `node` and its index there, from `positions`.
local function lookup(node, p)
  local code = positions[node]
  if code then
    local k = code % 8
    local list = p[SIBLING_KEYS[k]]
    local i = (code - k) / 8
    if type(list) == "table" and list[i] == node then
      return list, i
    end
  end
end

--- The list containing `node` among its parent's (contents, title, ...)
--- and its index there.
---@return table|nil list, integer|nil index
function M.position(node)
  local p = node.parent
  if not p then
    return nil
  end
  local list, i = lookup(node, p)
  if list then
    return list, i
  end
  index_lists(p)
  return lookup(node, p)
end

--- Siblings list containing node.
function M.siblings(node)
  return (M.position(node))
end

---@mod org.export.ox.transcode Tree topology, attributes and captions, transcoding with `data`
---
--- Part of org.export.ox, which loads it: the functions are fields of
--- that module.

local element = require("org.export.element")
local M = require("org.export.ox")

local trim = M.trim

---------------------------------------------------------------------------
-- Tree helpers (topology)
---------------------------------------------------------------------------

M.map = element.map
M.lineage = element.lineage
M.parent_element = element.parent_element

function M.get_previous_element(blob, info, n)
  local siblings = element.siblings(blob)
  if not siblings then
    return nil
  end
  local idx
  for i, x in ipairs(siblings) do
    if x == blob then
      idx = i
      break
    end
  end
  local ignore = info and info.ignore or {}
  local prev = {}
  for i = idx - 1, 1, -1 do
    local obj = siblings[i]
    if not ignore[obj] then
      if n == nil then
        return obj
      end
      table.insert(prev, 1, obj)
      if type(n) == "number" and #prev >= n then
        return prev
      end
    end
  end
  if n == nil then
    return nil
  end
  return prev
end

function M.get_next_element(blob, info, n)
  local siblings = element.siblings(blob)
  if not siblings then
    return nil
  end
  local idx
  for i, x in ipairs(siblings) do
    if x == blob then
      idx = i
      break
    end
  end
  local ignore = info and info.ignore or {}
  local nxt = {}
  for i = idx + 1, #siblings do
    local obj = siblings[i]
    if not ignore[obj] then
      if n == nil then
        return obj
      end
      nxt[#nxt + 1] = obj
      if type(n) == "number" and #nxt >= n then
        return nxt
      end
    end
  end
  if n == nil then
    return nil
  end
  return nxt
end

function M.first_sibling_p(blob, info)
  local p = M.get_previous_element(blob, info)
  return p == nil or p.type == "section"
end

function M.last_sibling_p(datum, info)
  local nxt = M.get_next_element(datum, info)
  return nxt == nil or (datum.type == "headline" and nxt.level and datum.level > nxt.level)
end

---------------------------------------------------------------------------
-- Attributes, captions
---------------------------------------------------------------------------

--- org-export-read-attribute: attributes of `attr_name` (e.g. "attr_html")
--- as a table { key = value } (plus an ordered `_keys` list).
function M.read_attribute(attr_name, el, property)
  local value = el[attr_name]
  if not value then
    if property then
      return nil
    end
    return { _keys = {} }
  end
  local s = table.concat(value, " ")
  local out = { _keys = {} }
  local function prep(v)
    v = trim(v)
    if v == "" or v == "nil" then
      return nil
    end
    local q = v:match('^"("*)"$')
    if q then
      return q
    end
    return v
  end
  -- split on :keywords preceded by start or blanks
  local keys = {}
  local pos = 1
  local cur_key
  local cur_start
  while true do
    local a, b, k = s:find("%f[^ \t%z]:([%-%w_]+)", pos)
    local valid = false
    while a do
      local after_c = s:sub(b + 1, b + 1)
      local before_c = a > 1 and s:sub(a - 1, a - 1) or " "
      if (after_c == "" or after_c:match("[ \t]")) and before_c:match("[ \t]") then
        valid = true
        break
      end
      a, b, k = s:find("%f[^ \t%z]:([%-%w_]+)", b + 1)
    end
    if not valid then
      break
    end
    if cur_key then
      keys[#keys + 1] = { cur_key, s:sub(cur_start, a - 1) }
    end
    cur_key = k
    cur_start = b + 1
    pos = b + 1
  end
  if cur_key then
    keys[#keys + 1] = { cur_key, s:sub(cur_start) }
  end
  for _, kv in ipairs(keys) do
    local k = kv[1]
    if out[k] == nil and not vim.tbl_contains(out._keys, k) then
      out._keys[#out._keys + 1] = k
    end
    out[k] = prep(kv[2])
  end
  if property then
    return out[property]
  end
  return out
end

--- Caption of `el` as a secondary string (org-export-get-caption).
function M.get_caption(el, short)
  local full = el.caption
  if not full then
    return nil
  end
  local caption
  for _, line in ipairs(full) do
    local c
    if short then
      c = line[2]
    else
      c = line[1]
    end
    if c and #c > 0 then
      if caption then
        caption[#caption + 1] = element.text(" ", nil)
        vim.list_extend(caption, c)
      else
        caption = vim.list_slice(c)
      end
    end
  end
  return caption
end

---------------------------------------------------------------------------
-- Transcoding
---------------------------------------------------------------------------

local BrokenLink = {}
BrokenLink.__index = BrokenLink

--- Signal a broken link (caught by `data` per :with-broken-links).
function M.broken_link(path)
  error(setmetatable({ broken_link = path }, BrokenLink), 0)
end

---@return (fun(data: table, contents: string|nil, info: table): string|nil)|nil
function M.transcoder(blob, info)
  if blob.type == "org-data" then
    return function(_, contents)
      return contents
    end
  end
  local t = info.translate[blob.type]
  return t
end

local function keep_spaces(data, info)
  local pb = data.post_blank
  if not pb or pb == 0 or element.ELEMENTS[data.type] then
    return nil
  end
  local prev = M.get_previous_element(data, info)
  if not prev then
    return nil
  end
  if prev.type == "plain-text" then
    if prev.value:match("[ \t\r\n]$") then
      return nil
    end
  elseif prev.post_blank ~= nil then
    -- In Emacs any :post-blank of an object is non-nil, 0 included, so
    -- spaces are never kept after another object.
    return nil
  end
  return string.rep(" ", pb)
end
M.keep_spaces = keep_spaces

local function apply_filters(filters, value, info)
  for _, f in ipairs(filters or {}) do
    local ok, r = pcall(f, value, info.back_end and info.back_end.name, info)
    if ok and r ~= nil then
      value = r
    elseif not ok then
      error(r, 0)
    end
  end
  return value
end
M.apply_filters = apply_filters

--- Transcode `data` (node, secondary string or string) with the current
--- back-end (org-export-data).
function M.data(data, info)
  if data == nil then
    return ""
  end
  if type(data) == "string" then
    local t = info.translate["plain-text"]
    local r = t and t(data, info, nil) or data
    return apply_filters(info.filters["plain-text"], r, info)
  end
  local cache = info.exported_data
  if data.type ~= nil and cache[data] ~= nil then
    return cache[data]
  end
  if data.type == nil then
    local out = {}
    for _, obj in ipairs(data) do
      out[#out + 1] = M.data(obj, info)
    end
    return table.concat(out)
  end
  local t = data.type
  local results
  local ok, err = pcall(function()
    if info.ignore[data] then
      results = nil
    elseif t == "raw" then
      results = data.value
    elseif t == "plain-text" then
      local tr = info.translate["plain-text"]
      results = apply_filters(info.filters["plain-text"], tr and tr(data.value, info, data) or data.value, info)
    elseif #data.contents == 0 or (t == "headline" and info.with_archived_trees == "headline" and data.archivedp) then
      local tr = M.transcoder(data, info)
      if tr then
        results = tr(data, nil, info)
      end
    else
      local tr = M.transcoder(data, info)
      if tr then
        local greater = element.GREATER[t]
        local parts = {}
        for _, c in ipairs(data.contents) do
          parts[#parts + 1] = M.data(c, info)
        end
        local contents = table.concat(parts)
        if greater then
          contents = M.normalize_string(contents)
        end
        results = tr(data, contents, info)
      end
    end
  end)
  if not ok then
    if type(err) == "table" and err.broken_link then
      local mode = info.with_broken_links
      if mode == "mark" then
        results = M.data("[BROKEN LINK: " .. err.broken_link .. "]", info)
      elseif mode == true or mode == "t" then
        results = nil
      else
        error(
          string.format(
            "Org export aborted.  Unable to resolve link: %q\nSee export.with_broken_links (org-export-with-broken-links)",
            err.broken_link
          ),
          0
        )
      end
    else
      error(err, 0)
    end
  end
  local final
  if results == nil then
    final = keep_spaces(data, info) or ""
  elseif t == "org-data" or t == "plain-text" or t == "raw" then
    final = results
  else
    local blank = data.post_blank or 0
    local v
    if element.ELEMENTS[t] then
      v = M.normalize_string(results) .. string.rep("\n", blank)
    else
      v = results .. string.rep(" ", blank)
    end
    final = apply_filters(info.filters[t], v, info)
  end
  cache[data] = final
  return final
end

--- Transcode with another back-end's full translation table.
function M.data_with_backend(data, backend, info)
  backend = M.get_backend(backend)
  local new = setmetatable({
    back_end = backend,
    translate = M.all_transcoders(backend),
    exported_data = {},
  }, { __index = info })
  return M.data(data, new)
end

--- Call a single transcoder of another back-end (org-export-with-backend).
function M.with_backend(backend, data, contents, info)
  backend = M.get_backend(backend)
  local all = M.all_transcoders(backend)
  local t = data.type
  local tr = all[t]
  if not tr then
    error("No foreign transcoder available")
  end
  local new = setmetatable({ back_end = backend, translate = all, exported_data = {} }, { __index = info })
  if t == "plain-text" then
    return tr(data.value, new, data)
  end
  return tr(data, contents, new)
end

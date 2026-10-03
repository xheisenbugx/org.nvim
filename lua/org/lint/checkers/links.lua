---@mod org.lint.checkers.links org-lint checkers: links
---
--- Checker functions by name: `C[name](doc)` returns `{ lnum, col,
--- message }` reports. lua/org/lint/init.lua registers them
--- (`M.checkers`) and runs them.

local util = require("org.lint.util")
local helpers = require("org.lint.helpers")

local lisp_str = util.lisp_str
local map_type = helpers.map_type
local at_obj = helpers.at_obj
local file_exists = helpers.file_exists
local is_remote = helpers.is_remote
local headline_properties = helpers.headline_properties
local resolve_fuzzy = helpers.resolve_fuzzy
local local_ids = helpers.local_ids
local coderef_resolves = helpers.coderef_resolves
local links = helpers.links

local C = {}

C["invalid-coderef-link"] = function(doc)
  local out = {}
  for _, o in ipairs(links(doc, "coderef")) do
    if not coderef_resolves(doc, o.path) then
      out[#out + 1] = at_obj(o, string.format('Unknown coderef "%s"', o.path))
    end
  end
  return out
end

C["invalid-custom-id-link"] = function(doc)
  local out = {}
  for _, o in ipairs(links(doc, "custom-id")) do
    if not local_ids(doc)[o.path] then
      out[#out + 1] = at_obj(o, string.format('Unknown custom ID "%s"', o.path))
    end
  end
  return out
end

C["invalid-fuzzy-link"] = function(doc)
  local out = {}
  for _, o in ipairs(links(doc, "fuzzy")) do
    if not resolve_fuzzy(doc, o.path) then
      local p = o.path:sub(1, 1) == "*" and o.path:sub(2) or o.path
      out[#out + 1] = at_obj(o, string.format('Unknown fuzzy location "%s"', p))
    end
  end
  return out
end

C["invalid-id-link"] = function(doc)
  local out = {}
  local list = links(doc, "id")
  if #list == 0 then
    return out
  end
  -- the document's own IDs once, not per link; for the others, the IDs of
  -- every file org.id.find would look in, gathered once (org.id.find
  -- rescans all of them for each ID it misses)
  local here, elsewhere, memo = {}, nil, {}
  local fid = doc.file and doc.file.properties and doc.file.properties.ID
  if fid then
    here[fid] = true
  end
  for _, h in ipairs(map_type(doc, "headline")) do
    local id = headline_properties(doc, h).ID
    if id then
      here[id] = true
    end
  end
  local function exists(path)
    if here[path] then
      return true
    end
    if elsewhere then
      return elsewhere[path] == true
    end
    elsewhere = {}
    local ok, id = pcall(require, "org.id")
    local okl, paths = false, nil
    if ok then
      okl, paths = pcall(id.files)
    end
    for _, p in ipairs(okl and paths or {}) do
      local okg, f = pcall(require("org.files").get, p)
      if okg and f then
        if f.properties and f.properties.ID then
          elsewhere[f.properties.ID] = true
        end
        for _, hl in ipairs(f.headlines) do
          if hl.properties.ID then
            elsewhere[hl.properties.ID] = true
          end
        end
      end
    end
    return elsewhere[path] == true
  end
  for _, o in ipairs(list) do
    local found = memo[o.path]
    if found == nil then
      found = exists(o.path)
      memo[o.path] = found
    end
    if not found then
      out[#out + 1] = at_obj(o, string.format('Unknown ID "%s"', o.path))
    end
  end
  return out
end

C["trailing-bracket-after-link"] = function(doc)
  local out = {}
  for _, o in ipairs(links(doc)) do
    if o.s:sub(o.e, o.e) == "]" then
      out[#out + 1] = at_obj(o, "Trailing ']' after link end")
    end
  end
  return out
end

C["unclosed-brackets-in-link-description"] = function(doc)
  local out = {}
  for _, o in ipairs(links(doc)) do
    if o.cb then
      local desc = o.s:sub(o.cb, o.ce - 1)
      local count = 0
      for ch in desc:gmatch("[%[%]]") do
        count = count + (ch == "[" and 1 or -1)
      end
      if count > 0 then
        out[#out + 1] = at_obj(o, "No closing ']' matches '[' in link description: " .. desc)
      end
    end
  end
  return out
end

local function in_link(o)
  local p = o.parent
  while p do
    if p.type == "link" then
      return true
    end
    p = p.parent
  end
  return false
end

--- `substitute-env-in-file-name`
local function substitute_env(s)
  s = s:gsub("%$%$", "\0")
  s = s:gsub("%${([%w_]+)}", function(v)
    return os.getenv(v) or ("${" .. v .. "}")
  end)
  s = s:gsub("%$([%w_]+)", function(v)
    return os.getenv(v) or ("$" .. v)
  end)
  return (s:gsub("%z", "$"))
end

C["link-to-local-file"] = function(doc)
  local out = {}
  for _, o in ipairs(doc.objects) do
    if o.type == "link" and (o.link_type == "file" or o.link_type == "attachment") then
      local path = o.path
      local file = path
      if o.link_type == "attachment" then
        path = path:match("^(.-)::.*$") or path
        local dir
        local ok, attach = pcall(require, "org.attach")
        if ok and doc.bufnr then
          local okd, d = pcall(attach.dir_for, { bufnr = doc.bufnr, lnum = o.lnum })
          dir = okd and d or nil
        end
        file = dir and (dir .. "/" .. path) or path
      end
      file = substitute_env(file)
      if not is_remote(file) and not file_exists(doc, file) then
        local fmt = in_link(o) and "Link to non-existent image file %s in description"
          or "Link to non-existent local file %s"
        out[#out + 1] = at_obj(o, string.format(fmt, lisp_str(file)))
      end
    end
  end
  return out
end

return C

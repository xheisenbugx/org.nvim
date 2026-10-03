---@mod org.export.ox.footnotes Footnote definitions, references and numbers
---
--- Part of org.export.ox, which loads it: the functions are fields of
--- that module.

local element = require("org.export.element")
local M = require("org.export.ox")

---------------------------------------------------------------------------
-- Footnotes
---------------------------------------------------------------------------

function M.get_footnote_definition(ref, info)
  local label = ref.label
  if not label then
    return ref.contents
  end
  local cache = info.footnote_definition_cache
  if not cache then
    cache = { defs = {}, resolved = {} }
    element.map(info.parse_tree, { ["footnote-definition"] = true, ["footnote-reference"] = true }, function(f)
      if f.fn_type ~= "standard" and f.label and not cache.defs[f.label] then
        cache.defs[f.label] = f
      end
    end, { ignore = info.ignore })
    info.footnote_definition_cache = cache
  end
  local d = cache.defs[label]
  if not d then
    error("Definition not found for footnote " .. label, 0)
  end
  return d.contents
end

--- Apply fn on every footnote reference in data (org-export--footnote-reference-map).
function M.footnote_reference_map(fn, data, info, body_first)
  local definitions = {}
  local seen = {}
  local function search(d, delayp)
    element.map(d, "footnote-reference", function(f)
      fn(f)
      local label = f.label
      if not (label and seen[label]) then
        if label then
          seen[label] = true
        end
        if delayp then
          definitions[#definitions + 1] = M.get_footnote_definition(f, info)
        elseif f.fn_type == "inline" then
          -- inline definitions are traversed at the right time
        else
          search(M.get_footnote_definition(f, info), false)
        end
      end
    end, {
      ignore = info.ignore,
      no_recursion = delayp and { ["footnote-definition"] = true, ["footnote-reference"] = true }
        or { ["footnote-definition"] = true },
    })
  end
  search(data, body_first)
  for _, d in ipairs(definitions) do
    search(d, false)
  end
end

function M.collect_footnote_definitions(info, data, body_first)
  local n = 0
  local labels = {}
  local out = {}
  M.footnote_reference_map(function(f)
    local l = f.label
    if not (l and labels[l]) then
      n = n + 1
      out[#out + 1] = { n, l, M.get_footnote_definition(f, info) }
    end
    if l then
      labels[l] = true
    end
  end, data or info.parse_tree, info, body_first)
  return out
end

function M.footnote_first_reference_p(ref, info, data, body_first)
  local label = ref.label
  if not label then
    return true
  end
  local result
  local done = false
  local ok, err = pcall(M.footnote_reference_map, function(f)
    if not done and f.label == label then
      result = f == ref
      done = true
      error("__stop__", 0)
    end
  end, data or info.parse_tree, info, body_first)
  if not ok and err ~= "__stop__" then
    error(err, 0)
  end
  return result
end

function M.get_footnote_number(footnote, info, data, body_first)
  local count = 0
  local seen = {}
  local label = footnote.label
  local result
  local ok, err = pcall(M.footnote_reference_map, function(f)
    local l = f.label
    if not l and not label and f == footnote then
      result = count + 1
      error("__stop__", 0)
    elseif label and l == label then
      result = count + 1
      error("__stop__", 0)
    elseif not l then
      count = count + 1
    elseif not seen[l] then
      seen[l] = true
      count = count + 1
    end
  end, data or info.parse_tree, info, body_first)
  if not ok and err ~= "__stop__" then
    error(err, 0)
  end
  return result
end

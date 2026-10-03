---@mod org.lint.checkers.structure org-lint checkers: headings, duplicates, affiliated keywords
---
--- Checker functions by name: `C[name](doc)` returns `{ lnum, col,
--- message }` reports. lua/org/lint/init.lua registers them
--- (`M.checkers`) and runs them.

local util = require("org.lint.util")
local data = require("org.lint.data")
local helpers = require("org.lint.helpers")

local contains = util.contains
local AFFILIATED = data.AFFILIATED
local TRANSLATION = data.TRANSLATION
local map_type = helpers.map_type
local map_objects = helpers.map_objects
local aff_value = helpers.aff_value
local at_begin = helpers.at_begin
local at_post = helpers.at_post
local collect_duplicates = helpers.collect_duplicates

local C = {}

C["misplaced-heading"] = function(doc)
  local out = {}
  for lnum, l in ipairs(doc.lines) do
    local init = 1
    while true do
      local s, e = l:find("[^%*\r ,]%*%*+ ", init)
      if not s then
        break
      end
      local el = doc:element_at(lnum, e + 1)
      if el and (el.type == "paragraph" or el.type == "headline") then
        table.insert(out, 1, { lnum, s, "Possibly misplaced heading line" })
      end
      init = e + 1
    end
  end
  return out
end

C["duplicate-custom-id"] = function(doc)
  return collect_duplicates(map_type(doc, "node-property"), function(p)
    return p.key and p.key:upper() == "CUSTOM_ID" and p.value or nil
  end, function(p)
    return { p.begin, 1 }
  end, function(k)
    return string.format('Duplicate CUSTOM_ID property "%s"', k)
  end)
end

C["duplicate-name"] = function(doc)
  local L = doc.lines
  return collect_duplicates(doc.elements, function(el)
    local a = aff_value(el, "NAME")
    return a and a.value or nil
  end, function(el, name)
    for k = el.begin, #L do
      local v = L[k]:match("^[ \t]*#%+[A-Za-z]+:[ \t]*(.-)[ \t]*$")
      if v == name then
        return { k, 1 }
      end
    end
    return { el.begin, 1 }
  end, function(k)
    return string.format('Duplicate NAME "%s"', k)
  end)
end

C["duplicate-target"] = function(doc)
  return collect_duplicates(map_objects(doc, "target"), function(o)
    local w = {}
    for x in o.value:gmatch("%S+") do
      w[#w + 1] = x
    end
    return w
  end, function(o)
    return { o.lnum, o.col }
  end, function(k)
    return string.format("Duplicate target <<%s>>", table.concat(k, " "))
  end)
end

C["duplicate-footnote-definition"] = function(doc)
  return collect_duplicates(map_type(doc, "footnote-definition"), function(el)
    return el.label
  end, function(el)
    return { el.post, 1 }
  end, function(k)
    return string.format('Duplicate footnote definition "%s"', k)
  end)
end

C["orphaned-affiliated-keywords"] = function(doc)
  local out = {}
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.key:match("^ATTR_[%-_A-Za-z0-9]+$") or (AFFILIATED[k.key] and k.key ~= "RESULT" and k.key ~= "RESULTS") then
      out[#out + 1] = at_post(k, string.format('Orphaned affiliated keyword: "%s"', k.key))
    end
  end
  return out
end

C["combining-keywords-with-affiliated"] = function(doc)
  local out = {}
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.post_blank == 0 and k.last + 1 <= #doc.lines then
      local nxt = doc:element_at(k.last + 1, 1)
      if nxt and nxt ~= k and nxt.begin ~= k.begin and nxt.begin < nxt.post then
        out[#out + 1] =
          at_begin(k, string.format("Independent keyword %s may be confused with affiliated keywords below", k.key))
      end
    end
  end
  return out
end

C["obsolete-affiliated-keywords"] = function(doc)
  local out = {}
  local repl = { HEADERS = "HEADER", RESULT = "RESULTS" }
  for lnum, l in ipairs(doc.lines) do
    local key, e = l:match("^[ \t]*#%+([%a]+):()")
    local up = key and key:upper()
    if up and TRANSLATION[up] then
      local el = doc:element_at(lnum, e)
      if el and el.post > lnum then
        table.insert(out, 1, {
          lnum,
          1,
          string.format('Obsolete affiliated keyword: "%s".  Use "%s" instead', up, repl[up] or "NAME"),
        })
      end
    end
  end
  return out
end

C["deprecated-export-blocks"] = function(doc)
  local dep = { "ASCII", "BEAMER", "HTML", "LATEX", "MAN", "MARKDOWN", "MD", "ODT", "ORG", "TEXINFO" }
  local out = {}
  for _, b in ipairs(map_type(doc, "special-block")) do
    if contains(dep, b.block_type:upper()) then
      out[#out + 1] =
        at_post(b, string.format('Deprecated syntax for export block.  Use "BEGIN_EXPORT %s" instead', b.block_type))
    end
  end
  return out
end

return C

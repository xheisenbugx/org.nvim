---@mod org.lint.checkers.citations org-lint checkers: citations and bibliographies
---
--- Checker functions by name: `C[name](doc)` returns `{ lnum, col,
--- message }` reports. lua/org/lint/init.lua registers them
--- (`M.checkers`) and runs them.

local util = require("org.lint.util")
local data = require("org.lint.data")
local helpers = require("org.lint.helpers")

local lisp_str = util.lisp_str
local CITE_PROCESSORS = data.CITE_PROCESSORS
local map_type = helpers.map_type
local map_objects = helpers.map_objects
local at_begin = helpers.at_begin
local file_exists = helpers.file_exists
local is_remote = helpers.is_remote
local strip_quotes = helpers.strip_quotes

local C = {}

C["non-existent-bibliography"] = function(doc)
  local out = {}
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.key == "BIBLIOGRAPHY" then
      local file = strip_quotes(k.value)
      if not is_remote(file) and not file_exists(doc, file) then
        out[#out + 1] = at_begin(k, string.format("Non-existent bibliography %s", lisp_str(file)))
      end
    end
  end
  return out
end

C["missing-print-bibliography"] = function(doc)
  if #map_objects(doc, "citation") == 0 then
    return {}
  end
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.key == "PRINT_BIBLIOGRAPHY" then
      return {}
    end
  end
  local n = #doc.lines
  local lnum = doc.eol == false and math.max(n, 1) or n + 1
  local col = doc.eol == false and #(doc.lines[n] or "") + 1 or 1
  return { { lnum, col, 'Possibly missing "PRINT_BIBLIOGRAPHY" keyword' } }
end

C["invalid-cite-export-declaration"] = function(doc)
  local out = {}
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.key == "CITE_EXPORT" then
      local v = k.value
      if v == "" then
        out[#out + 1] = at_begin(k, "Missing export processor name")
      else
        local tokens = {}
        local p = 1
        local bad = false
        while p <= #v do
          p = p + #v:match("^[ \t]*", p)
          if p > #v then
            break
          end
          if v:sub(p, p) == '"' then
            local c = v:find('"', p + 1, true)
            if not c then
              bad = true
              break
            end
            tokens[#tokens + 1] = { quoted = true, text = v:sub(p + 1, c - 1) }
            p = c + 1
          else
            local t = v:match("^[^ \t]+", p)
            tokens[#tokens + 1] = { text = t }
            p = p + #t
          end
        end
        local name = tokens[1]
        if bad or #tokens > 3 or name.quoted or tonumber(name.text) or name.text:match("[%(%)%[%]\"';`,#]") then
          out[#out + 1] = at_begin(k, "Invalid cite export processor declaration")
        elseif not CITE_PROCESSORS[name.text] then
          out[#out + 1] = at_begin(k, string.format("Unknown cite export processor %s", name.text))
        end
      end
    end
  end
  return out
end

C["incomplete-citation"] = function(doc)
  local out = {}
  for _, o in ipairs(doc.objects) do
    if o.type == "plain-text" and (o.value:find("%[cite:") or o.value:find("%[cite/[%w/_%-]+:")) then
      local parent = o.parent
      if parent and parent.cb then
        -- contents-begin of the enclosing object
        local lnum, col = parent.pos(parent.cb)
        out[#out + 1] = { lnum, col, "Possibly incomplete citation markup" }
      else
        local el = o.element
        if el.type == "headline" then
          local cb = el.cbegin or el.begin
          out[#out + 1] = { cb, 1, "Possibly incomplete citation markup" }
        elseif el.type == "paragraph" then
          out[#out + 1] = { el.cbegin, el.ccol, "Possibly incomplete citation markup" }
        else
          out[#out + 1] = { o.lnum, o.col, "Possibly incomplete citation markup" }
        end
      end
    end
  end
  return out
end

return C

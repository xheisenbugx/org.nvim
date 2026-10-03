---@mod org.lint.checkers.elements org-lint checkers: keywords syntax, blocks, planning, drawers and other elements
---
--- Checker functions by name: `C[name](doc)` returns `{ lnum, col,
--- message }` reports. lua/org/lint/init.lua registers them
--- (`M.checkers`) and runs them.

local util = require("org.lint.util")
local element = require("org.lint.element")
local helpers = require("org.lint.helpers")

local trim = util.trim
local lisp_str = util.lisp_str
local contains = util.contains
local match_drawer = element.match_drawer
local map_type = helpers.map_type
local aff_values = helpers.aff_values
local at_begin = helpers.at_begin
local at_obj = helpers.at_obj
local links = helpers.links

local C = {}

C["invalid-keyword-syntax"] = function(doc)
  local out = {}
  for lnum, l in ipairs(doc.lines) do
    local name = l:match("^[ \t]*#%+([^%s:]*) ") or l:match("^[ \t]*#%+([^%s:]*)$")
    if name then
      local up = name:upper()
      local exception = l:match("^[ \t]*#%+[Cc][Aa][Pp][Tt][Ii][Oo][Nn]%[.*%]:")
        or l:match("^[ \t]*#%+[Rr][Ee][Ss][Uu][Ll][Tt][Ss]%[.*%]:")
      if exception then
        local after = l:match("%]:(.*)$")
        exception = after == "" or after:match("^ ") ~= nil
      end
      if up:sub(1, 5) ~= "BEGIN" and up:sub(1, 3) ~= "END" and not exception then
        table.insert(out, 1, { lnum, 1, string.format('Possible missing colon in keyword "%s"', name) })
      end
    end
  end
  return out
end

C["invalid-image-alignment"] = function(doc)
  local out = {}
  for _, p in ipairs(map_type(doc, "paragraph")) do
    local vals = aff_values(p, "ATTR_ORG")
    local ks = vals[1]
    if ks then
      local reports = {}
      local align = ks:match(":align%s+(%S+)")
      if align and not contains({ "left", "center", "right" }, align) then
        table.insert(
          reports,
          1,
          at_begin(p, string.format('"%s" not a supported value for #+ATTR_ORG keyword attribute ":align".', align))
        )
      end
      local center = ks:match(":center%s+(%S+)")
      if center and center ~= "t" then
        table.insert(
          reports,
          1,
          at_begin(p, string.format('"%s" not a supported value for #+ATTR_ORG keyword attribute ":center".', center))
        )
      end
      vim.list_extend(out, reports)
    end
  end
  return out
end

local BLOCK_TYPES = {
  ["center-block"] = true,
  ["comment-block"] = true,
  ["dynamic-block"] = true,
  ["example-block"] = true,
  ["export-block"] = true,
  ["quote-block"] = true,
  ["special-block"] = true,
  ["src-block"] = true,
  ["verse-block"] = true,
}

C["invalid-block"] = function(doc)
  local out = {}
  for lnum, l in ipairs(doc.lines) do
    local pre, kw = l:match("^([ \t]*#%+)(%a+)")
    local upkw = kw and kw:upper() or ""
    local which = (upkw:sub(1, 5) == "BEGIN" and "BEGIN") or (upkw:sub(1, 3) == "END" and "END") or nil
    if which then
      local p = #pre + #which + 1
      local c = l:sub(p, p)
      if c == ":" then
        p = p + 1
      elseif c == "_" then
        p = p + #l:match("^_[^%s]*", p)
      end
      p = p + #l:match("^[ \t]*", p)
      local name = trim(l)
      if which == "END" and p <= #l then
        table.insert(out, 1, { lnum, 1, string.format('Invalid block closing line "%s"', name) })
      else
        local el = doc:element_at(lnum, p)
        if not (el and BLOCK_TYPES[el.type]) then
          table.insert(out, 1, { lnum, 1, string.format('Possible incomplete block "%s"', name) })
        end
      end
    end
  end
  return out
end

C["mismatched-planning-repeaters"] = function(doc)
  local out = {}
  for _, p in ipairs(map_type(doc, "planning")) do
    local s, d = p.scheduled, p.deadline
    local function cum(ts)
      return ts and (ts.repeater_type == "cumulate" or ts.repeater_type == "catch-up")
    end
    if s and d and cum(s) and cum(d) and s.repeater_value > 0 and d.repeater_value > 0 then
      local same = s.repeater_type == d.repeater_type
        and s.repeater_unit == d.repeater_unit
        and s.repeater_value == d.repeater_value
      if not same then
        out[#out + 1] = at_begin(p, "Different repeaters in SCHEDULED and DEADLINE timestamps.")
      end
    end
  end
  return out
end

local VERBATIM_BLOCKS = {
  ["comment-block"] = true,
  ["example-block"] = true,
  ["export-block"] = true,
  ["src-block"] = true,
  ["verse-block"] = true,
}

C["misplaced-planning-info"] = function(doc)
  local out = {}
  for lnum, l in ipairs(doc.lines) do
    local ll = l:lower()
    local e = ll:match("^[ \t]*closed:()") or ll:match("^[ \t]*deadline:()") or ll:match("^[ \t]*scheduled:()")
    if e then
      local el = doc:element_at(lnum, e)
      if not (el and (VERBATIM_BLOCKS[el.type] or el.type == "planning")) then
        table.insert(out, 1, { lnum, 1, "Misplaced planning info line" })
      end
    end
  end
  return out
end

C["incomplete-drawer"] = function(doc)
  local out = {}
  local L = doc.lines
  local lnum = 1
  while lnum <= #L do
    local l = L[lnum]
    local nm = match_drawer(l)
    local nextl = lnum + 1
    if nm then
      local name = trim(l)
      local el = doc:element_at(lnum, #l + 1)
      local t = el and el.type
      if t == "drawer" then
        if el.cbegin then
          for x = math.max(lnum + 1, el.cbegin), el.end_line - 1 do
            if match_drawer(L[x]) then
              table.insert(out, 1, { x, 1, string.format("Possible misleading drawer entry %s", lisp_str(trim(L[x]))) })
            end
          end
        end
        nextl = el.stop
      elseif t == "property-drawer" then
        nextl = el.stop
      elseif not VERBATIM_BLOCKS[t] then
        table.insert(out, 1, { lnum, 1, string.format("Possible incomplete drawer %s", lisp_str(name)) })
      end
    end
    lnum = math.max(nextl, lnum + 1)
  end
  return out
end

C["indented-diary-sexp"] = function(doc)
  local out = {}
  for lnum, l in ipairs(doc.lines) do
    local e = l:match("^[ \t]+%%%%%(()")
    if e then
      local el = doc:element_at(lnum, e)
      if not (el and (VERBATIM_BLOCKS[el.type] or el.type == "diary-sexp")) then
        table.insert(out, 1, { lnum, 1, "Possible indented diary-sexp" })
      end
    end
  end
  return out
end

C["quote-section"] = function(doc)
  local out = {}
  for _, h in ipairs(map_type(doc, "headline")) do
    if h.raw_value:sub(1, 6) == "QUOTE " or h.raw_value:sub(1, 14) == "COMMENT QUOTE " then
      out[#out + 1] = at_begin(h, "Deprecated QUOTE section")
    end
  end
  return out
end

C["file-application"] = function(doc)
  local out = {}
  for _, o in ipairs(links(doc)) do
    if o.application then
      out[#out + 1] = at_obj(o, string.format('Deprecated "file+%s" link type', o.application))
    end
  end
  return out
end

C["percent-encoding-link-escape"] = function(doc)
  local out = {}
  for _, o in ipairs(links(doc)) do
    if o.format == "bracket" then
      local uri = o.path
      local obsolete = uri:find("%", 1, true) ~= nil
      local start = 1
      while true do
        local s = uri:find("%", start, true)
        if not s then
          break
        end
        local code = uri:sub(s + 1, s + 2)
        local nl = code:find("\n", 1, true)
        if #code < 2 or nl then
          code = nil
        end
        start = s + 1 + (code and 2 or 0)
        if not (code and contains({ "25", "5B", "5D", "20" }, code)) then
          obsolete = false
          break
        end
      end
      if obsolete then
        out[#out + 1] = at_obj(o, "Link escaped with obsolete percent-encoding syntax")
      end
    end
  end
  return out
end

C["spurious-colons"] = function(doc)
  local out = {}
  for _, h in ipairs(map_type(doc, "headline")) do
    if contains(h.tags, "") then
      out[#out + 1] = at_begin(h, "Tags contain a spurious colon")
    end
  end
  return out
end

return C

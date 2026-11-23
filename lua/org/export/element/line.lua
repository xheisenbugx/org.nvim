---@mod org.export.element.line Line classification for the export parser
---
--- Predicates on single lines (headlines, comments, clocks, drawers,
--- blocks, tables, list items) and affiliated keywords.
---
--- Part of org.export.element, which loads it.

local elines = require("org.element_lines")
local shared = require("org.export.element.shared")

local indentation = shared.indentation

---------------------------------------------------------------------------
-- Line classification
---------------------------------------------------------------------------

local headline_stars = elines.headline_stars
local is_comment_line = elines.is_comment_line

local function is_clock_line(l)
  return l:match("^[ \t]*CLOCK:") ~= nil
end

-- org-element-planning-line-re
local is_planning_line = require("org.parser").is_planning_line

local drawer_name = elines.drawer_name
local is_end_line = elines.is_end_line
local property_line = elines.property_line
local property_drawer_end = elines.property_drawer_end
local is_fixed_width = elines.is_fixed_width
local is_footnote_def = elines.is_footnote_def
local is_hr = elines.is_hr
local latex_env_begin = elines.latex_env_begin
local block_type = elines.block_type
local is_dynamic_block = elines.is_dynamic_block
local is_table_line = elines.is_table_line

local function is_tableel_rule(l)
  return require("org.table.el").is_rule(l)
end

--- Item bullet of a line (org-item-re, alphabetical bullets when allowed).
local function item_match(l, alpha, term)
  term = term or "[%.%)]"
  local ind, bullet = l:match("^([ \t]*)([%-%+])[ \t]")
  if not ind then
    ind, bullet = l:match("^([ \t]*)([%-%+])$")
  end
  if not ind then
    ind, bullet = l:match("^([ \t]+)(%*)[ \t]")
    if not ind then
      ind, bullet = l:match("^([ \t]+)(%*)$")
    end
  end
  if not ind then
    ind, bullet = l:match("^([ \t]*)(%d+" .. term .. ")[ \t]")
    if not ind then
      ind, bullet = l:match("^([ \t]*)(%d+" .. term .. ")$")
    end
  end
  if not ind and alpha then
    ind, bullet = l:match("^([ \t]*)(%a" .. term .. ")[ \t]")
    if not ind then
      ind, bullet = l:match("^([ \t]*)(%a" .. term .. ")$")
    end
  end
  if ind then
    return indentation(ind), bullet
  end
end

local AFFILIATED = elines.AFFILIATED_MAP
local DUAL = elines.DUAL
local MULTIPLE = elines.MULTIPLE
local PARSED = elines.PARSED

--- Match an affiliated keyword line. Returns official key, value, dual value.
local function affiliated_match(l)
  local key, rest = l:match("^[ \t]*#%+([%w_%-]+)(.*)$")
  if not key then
    return nil
  end
  local up = key:upper()
  local official = AFFILIATED[up]
  local dual
  if official and DUAL[official] then
    local d, r = rest:match("^%[(.*)%](:.*)$")
    if d then
      dual, rest = d, r
    end
  end
  if not rest:match("^:") then
    return nil
  end
  if not official then
    if up:match("^ATTR_[%w_%-]+$") then
      official = up
    else
      return nil
    end
  end
  local value = rest:sub(2):gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
  return official, value, dual
end

-- Locals the later parts share
shared.headline_stars = headline_stars
shared.is_comment_line = is_comment_line
shared.is_clock_line = is_clock_line
shared.is_planning_line = is_planning_line
shared.drawer_name = drawer_name
shared.is_end_line = is_end_line
shared.property_line = property_line
shared.property_drawer_end = property_drawer_end
shared.is_fixed_width = is_fixed_width
shared.is_footnote_def = is_footnote_def
shared.is_hr = is_hr
shared.latex_env_begin = latex_env_begin
shared.block_type = block_type
shared.is_dynamic_block = is_dynamic_block
shared.is_table_line = is_table_line
shared.is_tableel_rule = is_tableel_rule
shared.item_match = item_match
shared.DUAL = DUAL
shared.MULTIPLE = MULTIPLE
shared.PARSED = PARSED
shared.affiliated_match = affiliated_match

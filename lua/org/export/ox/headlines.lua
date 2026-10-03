---@mod org.export.ox.headlines Headline levels, numbers, tags and categories; the export date
---
--- Part of org.export.ox, which loads it: the functions are fields of
--- that module.

local element = require("org.export.element")
local M = require("org.export.ox")

local cfg = M.cfg

---------------------------------------------------------------------------
-- Headlines
---------------------------------------------------------------------------

function M.get_relative_level(headline, info)
  return headline.level + (info.headline_offset or 0)
end

function M.low_level_p(headline, info)
  local limit = info.headline_levels
  if type(limit) == "number" and limit >= 0 then
    local level = M.get_relative_level(headline, info)
    if level > limit then
      return level - limit
    end
  end
  return nil
end

--- Inherited node property (org-export-get-node-property).
function M.get_node_property(prop, datum, inherited)
  local hl = datum.type == "headline" and datum or element.lineage(datum, "headline")
  if not inherited then
    return datum.props and datum.props[prop]
  end
  local n = datum.type == "headline" and datum or hl
  while n do
    if n.props and n.props[prop] ~= nil then
      return n.props[prop]
    end
    n = n.parent
  end
  return nil
end

function M.numbered_headline_p(headline, info)
  local un = M.get_node_property("UNNUMBERED", headline, true)
  if un and un ~= "nil" then
    return false
  end
  local sec = info.section_numbers
  local level = M.get_relative_level(headline, info)
  if type(sec) == "number" then
    return level <= sec
  end
  return sec and true or false
end

function M.get_headline_number(headline, info)
  if M.numbered_headline_p(headline, info) then
    return info.headline_numbering[headline]
  end
end

function M.number_to_roman(n)
  local roman = {
    { 1000, "M" },
    { 900, "CM" },
    { 500, "D" },
    { 400, "CD" },
    { 100, "C" },
    { 90, "XC" },
    { 50, "L" },
    { 40, "XL" },
    { 10, "X" },
    { 9, "IX" },
    { 5, "V" },
    { 4, "IV" },
    { 1, "I" },
  }
  if n <= 0 then
    return tostring(n)
  end
  local res = {}
  for _, r in ipairs(roman) do
    while n >= r[1] do
      n = n - r[1]
      res[#res + 1] = r[2]
    end
  end
  return table.concat(res)
end

function M.get_tags(el, info, tags, inherited)
  local drop = {}
  for _, t in ipairs(tags or {}) do
    drop[t] = true
  end
  local list
  if not inherited then
    list = el.tags or {}
  else
    local current = vim.deepcopy(el.tags or {})
    local have = {}
    for _, t in ipairs(current) do
      have[t] = true
    end
    local p = el.parent
    while p do
      if p.type == "headline" or p.type == "inlinetask" then
        for _, t in ipairs(p.tags or {}) do
          if not have[t] then
            have[t] = true
            table.insert(current, 1, t)
          end
        end
      end
      p = p.parent
    end
    list = {}
    local seen = {}
    for _, t in ipairs(vim.list_extend(vim.deepcopy(info.filetags or {}), current)) do
      if not seen[t] then
        seen[t] = true
        list[#list + 1] = t
      end
    end
  end
  local out = {}
  for _, t in ipairs(list) do
    if not drop[t] then
      out[#out + 1] = t
    end
  end
  return out
end

function M.get_category(blob, info)
  local c = M.get_node_property("CATEGORY", blob, true)
  if c then
    return c
  end
  for _, v in ipairs(info.keywords.CATEGORY or {}) do
    return v
  end
  local file = info.input_file
  return file and vim.fn.fnamemodify(file, ":t:r") or "???"
end

function M.get_alt_title(headline)
  return headline.alt_title or headline.title
end

---------------------------------------------------------------------------
-- Dates
---------------------------------------------------------------------------

function M.get_date(info, fmt)
  local date = info.date
  fmt = fmt or cfg().date_timestamp_format
  if not date or #date == 0 then
    return nil
  end
  if fmt and #date == 1 and date[1].type == "timestamp" then
    return M.format_timestamp(date[1], fmt)
  end
  return date
end

---@mod org.lint.checkers.footnotes org-lint checkers: footnotes
---
--- Checker functions by name: `C[name](doc)` returns `{ lnum, col,
--- message }` reports. lua/org/lint/init.lua registers them
--- (`M.checkers`) and runs them.

local helpers = require("org.lint.helpers")

local map_type = helpers.map_type
local map_objects = helpers.map_objects
local at_begin = helpers.at_begin
local at_post = helpers.at_post
local at_obj = helpers.at_obj
local footnote_section_name = helpers.footnote_section_name

local C = {}

C["undefined-footnote-reference"] = function(doc)
  local defs = {}
  for _, el in ipairs(doc.elements) do
    if el.type == "footnote-definition" then
      defs[el.label] = true
    end
  end
  for _, o in ipairs(map_objects(doc, "footnote-reference")) do
    if o.ref_type == "inline" and o.label then
      defs[o.label] = true
    end
  end
  local out = {}
  for _, o in ipairs(map_objects(doc, "footnote-reference")) do
    if o.ref_type == "standard" and not defs[o.label] then
      out[#out + 1] = at_obj(o, string.format("Missing definition for footnote [%s]", o.label))
    end
  end
  return out
end

C["unreferenced-footnote-definition"] = function(doc)
  local refs = {}
  for _, o in ipairs(map_objects(doc, "footnote-reference")) do
    if o.label then
      refs[o.label] = true
    end
  end
  local out = {}
  for _, el in ipairs(map_type(doc, "footnote-definition")) do
    if el.label and not refs[el.label] then
      out[#out + 1] = at_post(el, string.format("No reference for footnote definition [%s]", el.label))
    end
  end
  return out
end

C["extraneous-element-in-footnote-section"] = function(doc)
  local name = footnote_section_name()
  if not name then
    return {}
  end
  local ok_types = {
    comment = true,
    ["comment-block"] = true,
    ["footnote-definition"] = true,
    ["property-drawer"] = true,
    section = true,
  }
  local out = {}
  for _, h in ipairs(map_type(doc, "headline")) do
    if h.raw_value == name then
      local found = false
      local function walk(node)
        for _, c in ipairs(node.children) do
          if found then
            return
          end
          if not ok_types[c.type] and not (c.type == "headline" and c.commented) then
            found = true
            return
          end
          if c.type ~= "footnote-definition" and c.type ~= "property-drawer" then
            walk(c)
          end
        end
      end
      walk(h)
      if found then
        out[#out + 1] = at_begin(h, "Extraneous elements in footnote section are not exported")
      end
    end
  end
  return out
end

return C

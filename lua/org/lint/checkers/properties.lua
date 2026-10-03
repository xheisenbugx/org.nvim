---@mod org.lint.checkers.properties org-lint checkers: properties
---
--- Checker functions by name: `C[name](doc)` returns `{ lnum, col,
--- message }` reports. lua/org/lint/init.lua registers them
--- (`M.checkers`) and runs them.

local util = require("org.lint.util")
local data = require("org.lint.data")
local helpers = require("org.lint.helpers")

local lisp_str = util.lisp_str
local nw = util.nw
local contains = util.contains
local SPECIAL_PROPERTIES = data.SPECIAL_PROPERTIES
local map_type = helpers.map_type
local at_begin = helpers.at_begin
local at_post = helpers.at_post
local duration_p = helpers.duration_p

local C = {}

C["special-property-in-properties-drawer"] = function(doc)
  local out = {}
  for _, np in ipairs(map_type(doc, "node-property")) do
    if np.key and contains(SPECIAL_PROPERTIES, np.key:upper()) then
      out[#out + 1] = at_begin(np, string.format('Special property "%s" found in a properties drawer', np.key))
    end
  end
  return out
end

C["obsolete-properties-drawer"] = function(doc)
  local out = {}
  for _, d in ipairs(map_type(doc, "drawer")) do
    if d.name == "PROPERTIES" then
      -- `before' is always nil in Emacs (assq on nodes), hence "contents"
      out[#out + 1] = at_post(d, "Incorrect contents for PROPERTIES drawer")
    end
  end
  return out
end

C["invalid-effort-property"] = function(doc)
  local out = {}
  for _, np in ipairs(map_type(doc, "node-property")) do
    if np.key == "EFFORT" and nw(np.value) and not duration_p(np.value) then
      out[#out + 1] = at_begin(np, string.format("Invalid effort duration format: %s", lisp_str(np.value)))
    end
  end
  return out
end

C["invalid-id-property"] = function(doc)
  local out = {}
  for _, np in ipairs(map_type(doc, "node-property")) do
    if np.key == "ID" and nw(np.value) and np.value:find("::", 1, true) then
      out[#out + 1] = at_begin(np, string.format('IDs should not include "::": %s', lisp_str(np.value)))
    end
  end
  return out
end

return C

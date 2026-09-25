---@mod org.export.ast Compatibility module
---
--- The export engine is `org.export.ox` (driver) and `org.export.element`
--- (parser). This module only keeps the entity table used by completion.

local entities = require("org.export.entities")

local M = {}

--- name = { html, utf8, latex } for every Org entity (org-entities).
M.ENTITIES = {}
for name, e in pairs(entities) do
  local latex = e[1]
  if e[2] then
    latex = "$" .. latex .. "$"
  end
  M.ENTITIES[name] = { e[3], e[6], latex }
end

return M

---@mod org.export.hooks Preprocessors extensions add to the export pipeline
---
--- Kept apart from `org.export.ox` so an extension can register one at
--- setup without loading the exporter.

local M = {}

--- Line preprocessors run before #+INCLUDE keywords are expanded, in name
--- order: `name -> fun(lines, ctx): string[]|nil`, where `ctx` has
--- `dir`, `filename`, `bufnr` and `backend`. A function returning a table
--- replaces the lines. Empty unless an extension adds one.
---@type table<string, fun(lines: string[], ctx: table): string[]|nil>
M.preprocessors = {}

--- Run the preprocessors over `lines`.
---@param lines string[]
---@param ctx table
---@return string[]
function M.preprocess(lines, ctx)
  if next(M.preprocessors) == nil then
    return lines
  end
  local names = vim.tbl_keys(M.preprocessors)
  table.sort(names)
  for _, name in ipairs(names) do
    local r = M.preprocessors[name](lines, ctx)
    if type(r) == "table" then
      lines = r
    end
  end
  return lines
end

return M

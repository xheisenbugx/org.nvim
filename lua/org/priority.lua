---@mod org.priority Priorities ([#A])

local edit = require("org.edit")
local utils = require("org.utils")

local M = {}

--- Shift priority. dir = 1 raises (towards highest), -1 lowers.
--- Moving past either end removes the cookie (Emacs behaviour).
---@param target? org.Target
---@param dir integer
function M.shift(target, dir)
  local bufnr, file, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local p = file:priorities()
  local hi, lo, def = p.highest:byte(), p.lowest:byte(), p.default:byte()
  local new
  if not hl.priority then
    new = def
  else
    new = hl.priority:byte() - dir
    if new < hi or new > lo then
      new = nil
    end
  end
  local value = new and string.char(new) or false
  edit.update_headline(bufnr, hl.line, { priority = value })
  return value
end

function M.up(target)
  return M.shift(target, 1)
end

function M.down(target)
  return M.shift(target, -1)
end

--- Set priority explicitly; prompts for a character (SPC removes).
---@param target? org.Target
---@param value? string
function M.set(target, value)
  local bufnr, file, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local p = file:priorities()
  if value == nil then
    value = utils.getchar(string.format("Priority %s-%s, SPC to remove: ", p.highest, p.lowest))
    if not value then
      return nil
    end
  end
  if value == " " or value == "" then
    edit.update_headline(bufnr, hl.line, { priority = false })
    return false
  end
  value = value:upper()
  local b = value:byte()
  if #value ~= 1 or b < p.highest:byte() or b > p.lowest:byte() then
    utils.warn(string.format("Priority must be between %s and %s", p.highest, p.lowest))
    return nil
  end
  edit.update_headline(bufnr, hl.line, { priority = value })
  return value
end

return M

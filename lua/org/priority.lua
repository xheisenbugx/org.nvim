---@mod org.priority Priorities ([#A], [#10])
---
--- A port of Emacs `org-priority`: priorities are capital letters A-Z or
--- numbers 0-64 (`#+PRIORITIES: 1 10 5`); a smaller value is a higher
--- priority.

local config = require("org.config")
local edit = require("org.edit")
local utils = require("org.utils")

local M = {}

--- Fire the User autocmd `OrgPriorityChanged` when the priority cookie of
--- the headline at (bufnr, lnum) changed (`from` / `to`: nil without one).
local function changed(bufnr, lnum, old, new)
  if old == new then
    return
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "OrgPriorityChanged",
    data = { bufnr = bufnr, lnum = lnum, file = name ~= "" and vim.fs.normalize(name) or nil, from = old, to = new },
    modeline = false,
  })
end

--- Numeric value of a priority string or number (org-priority-to-value):
--- its number when it contains digits, else its first character's code.
---@param s string|integer|nil
---@return integer|nil
function M.to_value(s)
  if s == nil then
    return nil
  end
  if type(s) == "number" then
    return s
  end
  local n = tostring(s):match("(%d+)")
  if n then
    return tonumber(n)
  end
  return tostring(s):byte(1)
end

--- String form of a priority value (org-priority-to-string).
---@param v integer
function M.to_string(v)
  if v >= 0 and v <= 64 then
    return tostring(v)
  end
  return string.char(v)
end

--- Is `v` a priority value (0-64 or A-Z) within the file's range?
local function valid(v, range)
  return type(v) == "number"
    and ((v >= 0 and v <= 64) or (v >= 65 and v <= 90))
    and (not range or (v >= range.hi and v <= range.lo))
end

--- The priority range of a file as values: { hi, lo, def, numeric }.
---@param file org.File
function M.range(file)
  local p = file:priorities()
  local hi, lo, def = M.to_value(p.highest), M.to_value(p.lowest), M.to_value(p.default)
  return { hi = hi, lo = lo, def = def, numeric = lo >= 0 and lo <= 64 }
end

--- Effective priority value of a headline: its cookie or the default.
---@param hl org.Headline
function M.value(hl)
  return M.to_value(hl.priority) or M.range(hl.file).def
end

--- Emacs sort key of a priority (org-get-priority): 1000 × (lowest − value),
--- or what `priority_get_priority_function` returns for the headline line
--- (org-priority-get-priority-function).
---@param hl org.Headline
function M.get_priority(hl)
  local fn = config.opts.priority_get_priority_function
  if type(fn) == "function" then
    local ok, v = pcall(fn, hl.raw or hl.file.lines[hl.line] or "")
    if ok and tonumber(v) then
      return tonumber(v)
    end
  end
  local r = M.range(hl.file)
  return 1000 * (r.lo - M.value(hl))
end

--- Are the priority commands enabled (org-priority-enable-commands)?
--- Warns when they are not.
---@param quiet? boolean do not warn
function M.enabled(quiet)
  if config.opts.priority_enable_commands == false then
    if not quiet then
      utils.warn("Priority commands are disabled")
    end
    return false
  end
  return true
end

-- The last shift that removed a cookie, to wrap around on the next one
-- (Emacs checks `last-command`).
local last_removal = nil

--- Shift priority. dir = 1 raises (towards highest), -1 lowers. Moving past
--- either end removes the cookie; the next shift in the same direction
--- right after that wraps around to the other end (Emacs `org-priority`
--- 'up / 'down). Returns the new priority, or nil when it was removed.
--- Never `false`: to a keymap that means "not applicable" and replays the
--- key (<S-Down> pages down).
---@param target? org.Target
---@param dir integer
function M.shift(target, dir)
  if not M.enabled() then
    return nil
  end
  local bufnr, file, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local r = M.range(file)
  local cur = M.to_value(hl.priority)
  local repeated = last_removal
    and last_removal.bufnr == bufnr
    and last_removal.lnum == hl.line
    and last_removal.dir == dir
    and last_removal.tick == vim.api.nvim_buf_get_changedtick(bufnr)
  last_removal = nil
  local new
  if cur then
    new = cur - dir
  elseif repeated then
    new = dir > 0 and r.lo or r.hi
  elseif config.opts.priority_start_cycle_with_default == false then
    -- org-priority-start-cycle-with-default: start one step past the default
    new = r.def - dir
  else
    new = r.def
  end
  if not valid(new, r) then
    if not cur then
      utils.warn("The default can not be set, see `priority_default` why")
      return nil
    end
    new = nil
  end
  local value = new and M.to_string(new)
  edit.update_headline(bufnr, hl.line, { priority = value or false })
  changed(bufnr, hl.line, hl.priority, value or nil)
  if not value then
    last_removal = { bufnr = bufnr, lnum = hl.line, dir = dir, tick = vim.api.nvim_buf_get_changedtick(bufnr) }
    utils.notify("Priority removed")
  end
  return value
end

function M.up(target)
  return M.shift(target, 1)
end

function M.down(target)
  return M.shift(target, -1)
end

--- Show the priority of the entry as Emacs computes it for sorting
--- (org-priority-show, C-u C-c ,): 1000 × (lowest − priority).
function M.show(target)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local v = M.get_priority(hl)
  utils.notify(string.format("Priority is %d", v))
  return v
end

--- Set priority explicitly; prompts for a character, or a number when the
--- range is numeric with two digits (SPC removes). With a count of 4
--- (C-u C-c ,), show the priority instead.
---@param target? org.Target
---@param value? string|integer
function M.set(target, value)
  if target == nil and value == nil and vim.v.count == 4 then
    return M.show()
  end
  if not M.enabled() then
    return nil
  end
  local bufnr, file, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local r = M.range(file)
  local old = hl.priority
  local msg = string.format("Priority %s-%s, SPC to remove: ", M.to_string(r.hi), M.to_string(r.lo))
  if value == nil then
    if r.numeric and r.lo >= 10 then
      value = utils.input({ prompt = msg })
    else
      value = utils.getchar(msg)
    end
    if not value then
      return nil
    end
  end
  if value == " " or value == "" then
    edit.update_headline(bufnr, hl.line, { priority = false })
    changed(bufnr, hl.line, old, nil)
    return nil
  end
  local v
  if type(value) == "number" then
    v = value
  elseif r.numeric then
    v = tostring(value):match("^%s*(%d+)%s*$") and tonumber(value) or nil
  else
    local s = tostring(value):upper()
    v = #s == 1 and s:byte() or nil
  end
  if not valid(v, r) then
    utils.warn(string.format("Priority must be between %s and %s", M.to_string(r.hi), M.to_string(r.lo)))
    return nil
  end
  local str = M.to_string(v)
  edit.update_headline(bufnr, hl.line, { priority = str })
  changed(bufnr, hl.line, old, str)
  return str
end

return M

---@mod org.edit Low-level buffer editing primitives
---
--- Every high-level operation accepts an optional `target`:
---   `nil`                       -> headline at cursor in the current buffer
---   `{ bufnr = n, lnum = l }`   -> headline containing line `l` in buffer `n`
--- Primitives here never prompt and never log; they just rewrite lines.

local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")

local M = {}

---@alias org.Target { bufnr?: integer, lnum?: integer }

--- Resolve a target to (bufnr, file, headline). headline may be nil.
---@param target? org.Target
---@return integer bufnr, org.File file, org.Headline|nil headline
function M.resolve(target)
  target = target or {}
  local bufnr = target.bufnr or vim.api.nvim_get_current_buf()
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local lnum = target.lnum
  if not lnum then
    if bufnr == vim.api.nvim_get_current_buf() then
      lnum = vim.api.nvim_win_get_cursor(0)[1]
    else
      lnum = 1
    end
  end
  local file = files.get_buffer(bufnr)
  return bufnr, file, file:headline_at(lnum)
end

--- Like resolve, but warns and returns nil when not on/under a headline.
function M.resolve_headline(target)
  local bufnr, file, hl = M.resolve(target)
  if not hl then
    utils.warn("Not under a headline")
    return nil
  end
  return bufnr, file, hl
end

--- Re-fetch a headline after an edit (same buffer, by line).
function M.refresh(bufnr, lnum)
  local file = files.get_buffer(bufnr)
  return file:headline_at(lnum), file
end

--- Indentation used for planning lines / drawers under a headline.
function M.body_indent(level)
  if require("org.config").opts.adapt_indentation then
    return string.rep(" ", level + 1)
  end
  return ""
end

---------------------------------------------------------------------------
-- Headline line
---------------------------------------------------------------------------

--- Place tags on a headline text according to `tags_column`.
---@param before string headline text without tags
---@param tags string[]
function M.with_tags(before, tags)
  before = before:gsub("%s+$", "")
  if not tags or #tags == 0 then
    return before
  end
  local tagstr = ":" .. table.concat(tags, ":") .. ":"
  local col = require("org.config").opts.tags_column or -77
  local w = utils.width(before)
  local pad
  if col < 0 then
    pad = -col - w - utils.width(tagstr)
  else
    pad = col - w - 1
  end
  pad = math.max(pad, 1)
  return before .. string.rep(" ", pad) .. tagstr
end

--- Build a headline line from parts.
---@param p { level: integer, todo?: string, priority?: string, commented?: boolean, title?: string, tags?: string[] }
function M.build_headline(p)
  local parts = { string.rep("*", p.level) }
  if p.todo and p.todo ~= "" then
    parts[#parts + 1] = p.todo
  end
  if p.priority and p.priority ~= "" then
    parts[#parts + 1] = "[#" .. p.priority .. "]"
  end
  if p.commented then
    parts[#parts + 1] = "COMMENT"
  end
  if p.title and p.title ~= "" then
    parts[#parts + 1] = p.title
  end
  local line = table.concat(parts, " ")
  if #parts == 1 then
    line = line .. " "
  end
  return M.with_tags(line, p.tags)
end

--- Realign the tags of a headline line.
function M.align_tags_line(line, todo_cfg)
  local p = parser.parse_headline_line(line, todo_cfg)
  if not p or #p.tags == 0 then
    return line
  end
  return M.build_headline(p)
end

--- Update components of the headline at `lnum`.
--- `changes` keys: todo, priority, title, tags, level, commented.
--- Use `false` to remove todo/priority.
function M.update_headline(bufnr, lnum, changes)
  local file = files.get_buffer(bufnr)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  local p = parser.parse_headline_line(line, file.settings.todo)
  if not p then
    return false
  end
  for k, v in pairs(changes) do
    if v == false and (k == "todo" or k == "priority") then
      p[k] = nil
    else
      p[k] = v
    end
  end
  local new = M.build_headline(p)
  if new ~= line then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new })
  end
  return true
end

---------------------------------------------------------------------------
-- Planning
---------------------------------------------------------------------------

--- Build a planning line from { scheduled, deadline, closed } dates.
function M.build_planning(planning, indent)
  local parts = {}
  if planning.closed then
    parts[#parts + 1] = "CLOSED: " .. planning.closed:to_string()
  end
  if planning.deadline then
    parts[#parts + 1] = "DEADLINE: " .. planning.deadline:to_string()
  end
  if planning.scheduled then
    parts[#parts + 1] = "SCHEDULED: " .. planning.scheduled:to_string()
  end
  if #parts == 0 then
    return nil
  end
  return (indent or "") .. table.concat(parts, " ")
end

--- Set (or remove with nil) a planning entry for the headline at `lnum`.
---@param kind "scheduled"|"deadline"|"closed"
function M.set_planning(bufnr, lnum, kind, value)
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    return false
  end
  local planning = vim.deepcopy(hl.planning)
  -- deepcopy loses metatables; rebuild dates
  local date = require("org.date")
  for k, v in pairs(planning) do
    planning[k] = date.Date.new(v)
    if v.range_end then
      planning[k].range_end = date.Date.new(v.range_end)
    end
  end
  planning[kind] = value
  local indent = M.body_indent(hl.level)
  if hl.planning_line then
    indent = file.lines[hl.planning_line]:match("^(%s*)")
  end
  local line = M.build_planning(planning, indent)
  if hl.planning_line then
    if line then
      vim.api.nvim_buf_set_lines(bufnr, hl.planning_line - 1, hl.planning_line, false, { line })
    else
      vim.api.nvim_buf_set_lines(bufnr, hl.planning_line - 1, hl.planning_line, false, {})
    end
  elseif line then
    vim.api.nvim_buf_set_lines(bufnr, hl.line, hl.line, false, { line })
  end
  return true
end

---------------------------------------------------------------------------
-- Properties & drawers
---------------------------------------------------------------------------

--- Line after the headline, planning line and property drawer.
function M.meta_end(hl)
  local l = hl.line
  if hl.planning_line then
    l = hl.planning_line
  end
  if hl.properties_range then
    l = hl.properties_range[2]
  end
  return l
end

--- Set or delete (value = nil) a property in the headline's drawer.
function M.set_property(bufnr, lnum, name, value)
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    return false
  end
  local indent = M.body_indent(hl.level)
  if hl.properties_range then
    local s, e = hl.properties_range[1], hl.properties_range[2]
    indent = file.lines[s]:match("^(%s*)")
    for i = s + 1, e - 1 do
      local key = file.lines[i]:match("^%s*:([^%s:]+):")
      if key and key:upper() == name:upper() then
        if value == nil then
          vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, {})
          if e - s == 2 then
            -- drawer is now empty: remove it
            vim.api.nvim_buf_set_lines(bufnr, s - 1, s + 1, false, {})
          end
        else
          vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { indent .. ":" .. key .. ": " .. value })
        end
        return true
      end
    end
    if value ~= nil then
      vim.api.nvim_buf_set_lines(bufnr, e - 1, e - 1, false, { indent .. ":" .. name .. ": " .. value })
    end
    return true
  end
  if value == nil then
    return true
  end
  local at = hl.planning_line or hl.line
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, {
    indent .. ":PROPERTIES:",
    indent .. ":" .. name .. ": " .. value,
    indent .. ":END:",
  })
  return true
end

--- Ensure a drawer named `name` exists after the meta lines; returns its
--- (start, end) line numbers.
function M.ensure_drawer(bufnr, lnum, name)
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  for _, d in ipairs(hl.drawers) do
    if d.name:upper() == name:upper() then
      return d.start, d["end"]
    end
  end
  local indent = M.body_indent(hl.level)
  local at = M.meta_end(hl)
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, { indent .. ":" .. name .. ":", indent .. ":END:" })
  return at + 1, at + 2
end

--- Name of the log drawer, or nil when logging directly into the entry.
--- With a headline, `#+STARTUP: logdrawer|nologdrawer` and the (inherited)
--- LOG_INTO_DRAWER property override `log_into_drawer`.
---@param hl? org.Headline
function M.log_drawer_name(hl)
  local d = require("org.config").opts.log_into_drawer
  if hl then
    local startup = hl.file.settings.startup
    if startup.logdrawer then
      d = true
    elseif startup.nologdrawer then
      d = false
    end
    local prop = hl:get_property("LOG_INTO_DRAWER", true)
    if prop and prop ~= "" then
      if prop == "nil" then
        d = false
      elseif prop == "t" then
        d = true
      else
        d = prop
      end
    end
  end
  if d == true then
    return "LOGBOOK"
  end
  return d or nil
end

--- Add a log entry (list of lines, first starts with "- ") to the headline.
function M.add_log_entry(bufnr, lnum, entry_lines)
  local cfg = require("org.config").opts
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    return
  end
  local drawer = M.log_drawer_name(hl)
  local reversed = cfg.log_states_order_reversed ~= false
  if file.settings.startup.logstatesreversed then
    reversed = true
  elseif file.settings.startup.nologstatesreversed then
    reversed = false
  end
  if drawer then
    local s, e = M.ensure_drawer(bufnr, hl.line, drawer)
    local indent = vim.api.nvim_buf_get_lines(bufnr, s - 1, s, false)[1]:match("^(%s*)")
    local lines = vim.tbl_map(function(l)
      return indent .. l
    end, entry_lines)
    if reversed then
      vim.api.nvim_buf_set_lines(bufnr, s, s, false, lines)
    else
      vim.api.nvim_buf_set_lines(bufnr, e - 1, e - 1, false, lines)
    end
  else
    local indent = M.body_indent(hl.level)
    local lines = vim.tbl_map(function(l)
      return indent .. l
    end, entry_lines)
    local at = M.meta_end(hl)
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, lines)
  end
end

--- Format a note body into log entry lines: first line + continuation.
function M.log_lines(header, note)
  local out = { header }
  if note and vim.trim(note) ~= "" then
    out[1] = header .. " \\\\"
    for _, l in ipairs(vim.split(note, "\n")) do
      out[#out + 1] = "  " .. l
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Subtrees
---------------------------------------------------------------------------

---@return integer start, integer end (1-based, inclusive)
function M.subtree_range(bufnr, lnum)
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    return nil
  end
  return hl.line, hl.end_line
end

--- Change the level of every headline in `lines` by `delta`.
function M.shift_levels(lines, delta)
  local out = {}
  for i, l in ipairs(lines) do
    local stars = l:match("^(%*+) ")
    if stars then
      local n = math.max(1, #stars + delta)
      out[i] = string.rep("*", n) .. l:sub(#stars + 1)
    else
      out[i] = l
    end
  end
  return out
end

--- Normalize subtree lines so the first headline has `level`.
function M.relevel(lines, level)
  local first = lines[1] and (lines[1]:match("^(%*+)") or "")
  if not first or first == "" then
    return lines
  end
  return M.shift_levels(lines, level - #first)
end

return M

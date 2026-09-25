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

local region_ns = vim.api.nvim_create_namespace("org.edit.region")

--- In Visual mode, the headlines of the selection when
--- `loop_over_headlines_in_active_region` is set (Emacs
--- org-loop-over-headlines-in-active-region): leaves Visual mode and returns
--- a list of `{ bufnr, lnum = function }` whose `lnum()` follows edits.
--- Headlines hidden in a closed fold are skipped, like Emacs skips
--- invisible entries; with "start-level" only headlines of the first
--- headline's level are used. Returns nil outside Visual mode.
---@return { bufnr: integer, lnum: fun(): integer|nil }[]|nil
function M.region_headlines()
  local loop = require("org.config").opts.loop_over_headlines_in_active_region
  local mode = vim.fn.mode()
  if loop == false or not (mode == "v" or mode == "V" or mode == "\22") then
    return nil
  end
  local s, _, e = utils.visual_range()
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  local bufnr = vim.api.nvim_get_current_buf()
  local file = files.get_buffer(bufnr)
  local out, level = {}, nil
  for _, hl in ipairs(file.headlines) do
    if hl.line >= s and hl.line <= e then
      local fc = vim.fn.foldclosed(hl.line)
      level = level or hl.level
      if (fc == -1 or fc == hl.line) and (loop ~= "start-level" or hl.level == level) then
        local id = vim.api.nvim_buf_set_extmark(bufnr, region_ns, hl.line - 1, 0, {})
        out[#out + 1] = {
          bufnr = bufnr,
          lnum = function()
            local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, region_ns, id, {})
            vim.api.nvim_buf_del_extmark(bufnr, region_ns, id)
            return pos[1] and pos[1] + 1 or nil
          end,
        }
      end
    end
  end
  return out
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
    pad = col - w
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

--- A property drawer line `:NAME: value` formatted with `property_format`
--- (org-property-format, `%-10s %s`); an empty value leaves no trailing
--- space.
function M.property_line(indent, name, value)
  local fmt = require("org.config").opts.property_format or "%-10s %s"
  local ok, text = pcall(string.format, fmt, ":" .. name .. ":", value or "")
  if not ok then
    text = ":" .. name .. ": " .. (value or "")
  end
  return (indent or "") .. text:gsub("%s+$", "")
end

--- Set or delete (value = nil) a property in the headline's drawer. Before
--- the first headline, the file-level property drawer at the top of the
--- file is used (created when needed), like Emacs. Deleting also removes
--- the `NAME+` lines.
function M.set_property(bufnr, lnum, name, value)
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  local range, indent, at
  if hl then
    range = hl.properties_range
    indent = M.body_indent(hl.level)
    at = hl.planning_line or hl.line
  else
    range = file.properties_range
    indent = ""
    -- after leading comments (org-insert-property-drawer)
    at = 0
    while file.lines[at + 1] and file.lines[at + 1]:match("^%s*#%s") do
      at = at + 1
    end
  end
  local upper = name:upper()
  if range then
    local s, e = range[1], range[2]
    indent = file.lines[s]:match("^(%s*)")
    if value == nil then
      local removed = 0
      for i = e - 1, s + 1, -1 do
        local key = file.lines[i]:match("^%s*:([^%s:]+):")
        if key and (key:upper() == upper or key:upper() == upper .. "+") then
          vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, {})
          removed = removed + 1
        end
      end
      if removed > 0 and e - s - 1 == removed then
        -- drawer is now empty: remove it
        vim.api.nvim_buf_set_lines(bufnr, s - 1, s + 1, false, {})
      end
      return true
    end
    for i = s + 1, e - 1 do
      local key = file.lines[i]:match("^%s*:([^%s:]+):")
      if key and key:upper() == upper then
        vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { M.property_line(indent, name, value) })
        return true
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, e - 1, e - 1, false, { M.property_line(indent, name, value) })
    return true
  end
  if value == nil then
    return true
  end
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, {
    indent .. ":PROPERTIES:",
    M.property_line(indent, name, value),
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
  if not entry_lines or #entry_lines == 0 then
    return
  end
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

--- Emacs default note headings (org-log-note-headings).
M.DEFAULT_LOG_NOTE_HEADINGS = {
  done = "CLOSING NOTE %t",
  state = "State %-12s from %-12S %t",
  note = "Note taken on %t",
  reschedule = "Rescheduled from %S on %t",
  delschedule = "Not scheduled, was %S on %t",
  redeadline = "New deadline from %S on %t",
  deldeadline = "Removed deadline, was %S on %t",
  refile = "Refiled on %t",
  ["clock-out"] = "",
}

--- Quote a state or timestamp for a note heading (%s / %S): timestamps
--- are made inactive.
local function quote_state(v)
  if v == nil then
    return ""
  end
  if type(v) == "table" then
    v = v:clone({ active = false }):to_string({ range = false })
  elseif v:match("^<.*>$") then
    v = "[" .. v:sub(2, -2) .. "]"
  end
  return '"' .. v .. '"'
end

--- Heading of a log note for `purpose` ("done", "state", "note",
--- "reschedule", ...) from `log_note_headings` (org-log-note-headings),
--- with `%t %T %d %D %s %S %u %U` replaced, like org-store-log-note.
--- Returns the heading without the leading "- " ("" when the heading is
--- empty).
---@param purpose string
---@param state? string|table new state or timestamp (%s)
---@param previous? string|table previous state or timestamp (%S)
---@param time? table timestamp for %t (defaults to the effective time)
function M.log_heading(purpose, state, previous, time)
  local date = require("org.date")
  local headings = require("org.config").opts.log_note_headings or {}
  local fmt = headings[purpose]
  if fmt == nil then
    fmt = M.DEFAULT_LOG_NOTE_HEADINGS[purpose] or ""
  end
  time = time or date.effective_now()
  local values = {
    t = time:clone({ active = false }):to_string(),
    T = time:clone({ active = true }):to_string(),
    d = time:clone({ active = false, hour = vim.NIL, min = vim.NIL }):to_string(),
    D = time:clone({ active = true, hour = vim.NIL, min = vim.NIL }):to_string(),
    s = quote_state(state),
    S = quote_state(previous),
    u = vim.env.USER or vim.env.LOGNAME or "",
    U = vim.env.USER or "",
  }
  return (
    fmt:gsub("%%(%-?%d*)([a-zA-Z])", function(flags, c)
      local v = values[c]
      if v == nil then
        return nil
      end
      return flags ~= "" and string.format("%" .. flags .. "s", v) or v
    end)
  )
end

--- Log entry lines for a note of `purpose` (see `log_heading`), or nil
--- when both the heading and the note are empty.
function M.log_entry(purpose, note, state, previous, time)
  local heading = M.log_heading(purpose, state, previous, time)
  if heading ~= "" then
    return M.log_lines("- " .. heading, note)
  end
  if not note or vim.trim(note) == "" then
    return nil
  end
  local lines = vim.split(vim.trim(note), "\n")
  local out = { "- " .. lines[1] }
  for i = 2, #lines do
    out[#out + 1] = "  " .. lines[i]
  end
  return out
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

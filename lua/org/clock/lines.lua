---@mod org.clock.lines Editing CLOCK lines
---
--- Recompute a CLOCK line's duration and shift its timestamps, alone or
--- with the neighbouring task in the clock history.
---
--- Part of org.clock, which loads it.

local edit = require("org.edit")
local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")
local shared = require("org.clock.shared")

local M = require("org.clock")

local buf_path = shared.buf_path
local find_entry = shared.find_entry
local persist = shared.persist
local state_in_buffer = shared.state_in_buffer

---------------------------------------------------------------------------
-- Clock lines
---------------------------------------------------------------------------

--- Recompute the duration of a CLOCK line (org-clock-update-time-maybe).
--- When `old_line` (the line before an edit) was the running clock's open
--- line, the running clock follows its new start.
---@param old_line? string
function M.update_clock_line(bufnr, lnum, old_line)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  local c = line and parser.parse_clock_line(line)
  if not c then
    return false
  end
  if not c["end"] then
    local st = M.state
    if st and old_line and state_in_buffer(bufnr) and M._is_open_clock_of(old_line, st.start) then
      st.start = c.start:clone({ active = false }):to_string({ range = false })
      persist()
      vim.cmd("redrawstatus")
    end
    return true
  end
  local new = M.format_clock_line(line:match("^(%s*)"), c.start, c["end"])
  if new ~= line then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new })
  end
  return true
end

--- Shift both timestamps of the CLOCK line at the cursor by `n` units of
--- the part under the cursor, keeping the duration (org-clock-timestamps-up
--- / -down, C-S-Up / C-S-Down). On an open clock only its timestamp moves.
--- Returns false when not on a CLOCK line.
---@param n integer
function M.timestamps_shift(n)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  local c = parser.parse_clock_line(line)
  if not c then
    return false
  end
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local s1 = line:find("[", 1, true)
  if col < s1 then
    vim.api.nvim_win_set_cursor(0, { lnum, s1 })
  end
  if not c["end"] then
    -- an open clock: only its timestamp (the running clock follows it)
    return require("org.timestamps").increment(n) ~= false
  end
  local s2 = line:find("--[", 1, true)
  local on_end = col > s2 + 1
  if not require("org.timestamps").increment(n) then
    return false
  end
  local new = parser.parse_clock_line(vim.api.nvim_get_current_line())
  if not new or not new["end"] then
    return true
  end
  local start, stop = new.start, new["end"]
  if on_end then
    start = start:add(stop:minutes() - c["end"]:minutes(), "min")
  else
    stop = stop:add(start:minutes() - c.start:minutes(), "min")
  end
  local text = M.format_clock_line(line:match("^(%s*)"), start, stop)
  local cursor = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { text })
  vim.api.nvim_win_set_cursor(0, { lnum, math.min(cursor[2], #text - 1) })
  return true
end

--- On a CLOCK line, change the timestamp at the cursor by `n` (like
--- S-Up/S-Down) and move the touching timestamp of the neighbouring task in
--- the clock history by the same amount: the previous task's clock-out when
--- changing a clock-in, the next task's clock-in when changing a clock-out
--- (org-shiftmetaup / org-shiftmetadown on clock lines). Returns false when
--- not on a CLOCK timestamp.
---@param n integer
function M.timestamps_adjust_closest(n)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local c = parser.parse_clock_line(line)
  local s1 = line:find("[", 1, true)
  if not c or not s1 or col + 1 < s1 then
    return false
  end
  local s2 = line:find("--[", 1, true)
  local on_start = not s2 or col + 1 < s2
  local before = on_start and c.start:minutes() or c["end"]:minutes()
  if not require("org.timestamps").increment(n) then
    return false
  end
  local new = parser.parse_clock_line(vim.api.nvim_get_current_line())
  if not new then
    -- on a bracket, the change made the timestamp active: no clock left
    return true
  end
  local delta = (on_start and new.start:minutes() or (new["end"] and new["end"]:minutes() or before)) - before
  local hl = files.get_buffer(bufnr):headline_at(lnum)
  if #M.history < 2 or not hl or delta == 0 then
    utils.notify("No clock to adjust")
    return true
  end
  local path = buf_path(bufnr)
  local idx
  for i, h in ipairs(M.history) do
    if h.path == path and ((h.id and h.id == hl.properties.ID) or h.title == hl:plain_title()) then
      idx = i
      break
    end
  end
  -- the history is newest first: the previous task is the next entry
  local other = idx and M.history[idx + (on_start and 1 or -1)]
  local obuf, olnum = find_entry(other)
  if not obuf then
    utils.notify("No clock to adjust")
    return true
  end
  local ohl = files.get_buffer(obuf):headline_at(olnum)
  local clocks = vim.deepcopy(ohl.clocks)
  table.sort(clocks, function(a, b)
    return a.line < b.line
  end)
  for _, oc in ipairs(clocks) do
    if not on_start or oc["end"] then
      local l = vim.api.nvim_buf_get_lines(obuf, oc.line - 1, oc.line, false)[1]
      local indent = l:match("^(%s*)")
      local text
      if on_start then
        text = M.format_clock_line(indent, oc.start, oc["end"]:add(delta, "min"))
      elseif oc["end"] then
        text = M.format_clock_line(indent, oc.start:add(delta, "min"), oc["end"])
      else
        text = indent .. "CLOCK: " .. oc.start:add(delta, "min"):clone({ active = false }):to_string({ range = false })
      end
      vim.api.nvim_buf_set_lines(obuf, oc.line - 1, oc.line, false, { text })
      M.update_clock_line(obuf, oc.line, l)
      utils.notify(
        string.format(
          "Clock adjusted in %s for heading: %s",
          vim.fn.fnamemodify(vim.api.nvim_buf_get_name(obuf), ":t"),
          ohl:plain_title()
        )
      )
      return true
    end
  end
  utils.notify("No clock to adjust")
  return true
end

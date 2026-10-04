---@mod org.clock.report Clock report commands
---
--- Insert or update a clocktable (org-clock-report), its default
--- parameters, and shifting its :block (org-clocktable-shift).
---
--- Part of org.clock, which loads it.

local date = require("org.date")
local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.clock.shared")

local M = require("org.clock")

local clock_cfg = shared.clock_cfg
local iso_week_shift = shared.iso_week_shift

--- Shift the `:block` of the clocktable whose `#+BEGIN:` line is at the
--- cursor by `n` periods and update it (org-clocktable-shift, S-arrows):
--- today → today-1, 2026-W39 → 2026-W40, 2026-Q3 → 2026-Q4, ...
--- Returns false when not on a clocktable line.
---@param n integer negative = towards the past
function M.clocktable_shift(n)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  if not line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]:%s+clocktable%f[%W]") then
    return false
  end
  local s = line:match(":block%s+()%S")
  if not s then
    utils.warn("Line needs a :block definition before this command works")
    return true
  end
  local e = line:find("%s", s) or #line + 1
  local block = line:sub(s, e - 1)
  local alias = {
    yesterday = "today-1",
    lastweek = "thisweek-1",
    lastmonth = "thismonth-1",
    lastyear = "thisyear-1",
    lastq = "thisq-1",
  }
  block = alias[block] or block
  local ins
  local base, shift = block:match("^(%a+)([-+]%d+)$")
  base = base or block
  if base == "today" or base == "thisweek" or base == "thismonth" or base == "thisyear" or base == "thisq" then
    local k = (tonumber(shift) or 0) + n
    ins = k == 0 and base or string.format("%s%+d", base, k)
  else
    local y, rest = block:match("^(%d+)(.*)$")
    y = tonumber(y)
    if not y then
      utils.warn("Cannot shift clocktable block")
      return true
    end
    local dm, dd = rest:match("^%-(%d%d?)%-(%d%d?)$")
    local w = rest:match("^%-[wW](%d%d?)$")
    local q = rest:match("^%-[qQ](%d)$")
    local mo = rest:match("^%-(%d%d?)$")
    if dm then
      local d = date.from_days(date.days_from_civil(y, tonumber(dm), tonumber(dd)) + n)
      ins = string.format("%04d-%02d-%02d", d.year, d.month, d.day)
    elseif w then
      local iy, iw = iso_week_shift(y, tonumber(w), n)
      ins = string.format("%d-W%02d", iy, iw)
    elseif q then
      local idx = tonumber(q) - 1 + n
      ins = string.format("%d-Q%d", y + math.floor(idx / 4), idx % 4 + 1)
    elseif mo then
      local total = y * 12 + tonumber(mo) - 1 + n
      ins = string.format("%04d-%02d", math.floor(total / 12), total % 12 + 1)
    elseif rest == "" then
      ins = tostring(y + n)
    else
      utils.warn("Cannot shift clocktable block")
      return true
    end
  end
  vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { line:sub(1, s - 1) .. ins .. line:sub(e) })
  require("org.dblock").update_at_cursor()
  return true
end

local function lisp_value(v)
  if v == true then
    return "t"
  elseif v == false then
    return "nil"
  elseif type(v) == "table" then
    return "(" .. table.concat(vim.tbl_map(lisp_value, v), " ") .. ")"
  end
  return tostring(v)
end

--- The parameters of a new clock table (org-clock-clocktable-default-properties):
--- `:scope` first (`scope` unless the properties give one), then `:maxlevel`,
--- then the others by name. Values: true is `t`, a list `( ... )`, false
--- leaves the key out, anything else as written.
---@param scope string
---@return string
function M.default_properties_string(scope)
  local props = clock_cfg().clocktable_default_properties or {}
  local out = " :scope " .. lisp_value(props.scope == nil and scope or props.scope)
  if props.maxlevel ~= nil and props.maxlevel ~= false then
    out = out .. " :maxlevel " .. lisp_value(props.maxlevel)
  end
  local keys = vim.tbl_filter(function(k)
    return k ~= "scope" and k ~= "maxlevel" and props[k] ~= false
  end, vim.tbl_keys(props))
  table.sort(keys)
  for _, k in ipairs(keys) do
    out = out .. " :" .. k .. " " .. lisp_value(props[k])
  end
  return out
end

--- Insert a clock table, or update the one at the cursor (org-clock-report).
--- The new table covers the entry at the cursor (:scope subtree), or the
--- file before the first headline, with `clock.clocktable_default_properties`.
--- With a count, update the first clock table of the buffer instead.
function M.clock_report()
  local dblock = require("org.dblock")
  local bufnr = vim.api.nvim_get_current_buf()
  M.remove_overlays(bufnr)
  if vim.v.count > 0 then
    for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if l:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]:%s+clocktable%f[%W]") then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        vim.cmd("normal! zv")
        break
      end
    end
  end
  local existing = dblock.at_cursor()
  if existing and existing.name:lower() == "clocktable" then
    return dblock.update_block(bufnr, existing)
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  local before_first = files.get_buffer(bufnr):headline_at(lnum) == nil
  local header = "#+BEGIN: clocktable" .. M.default_properties_string(before_first and "file" or "subtree")
  -- org-create-dblock: on a non-blank line, the block goes below it
  local at = line:match("%S") and lnum or lnum - 1
  local indent = line:match("%S") and "" or line:match("^(%s*)")
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, { indent .. header, indent .. "#+END:" })
  vim.api.nvim_win_set_cursor(0, { at + 1, 0 })
  return dblock.update_block(bufnr, dblock.find_at(bufnr, at + 1))
end

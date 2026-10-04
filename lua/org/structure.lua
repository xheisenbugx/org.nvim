---@mod org.structure Structure editing and navigation
---
--- Headline insertion, promotion/demotion, subtree moves, the subtree kill
--- ring, cloning, sorting, narrowing, structure templates and headline
--- motions / text objects.
---
--- This file holds the helpers the parts share (line access, the current
--- headline, siblings, relevel); it loads the rest from org/structure/:
--- heading (inserting and editing headings), template (drawers, structure
--- templates), level (promote/demote), move (moving subtrees), kill (kill
--- ring, yank, clone), sort, narrow, toggle (comment, heading, emphasis)
--- and motion (heading motions, text objects).

local config = require("org.config")
local edit = require("org.edit")
local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")

local M = {}
-- The parts in org/structure/ add their functions to this table and
-- require it back, so it must be in package.loaded before they load.
package.loaded["org.structure"] = M

--- Subtrees cut or copied with `cut_subtree` / `copy_subtree` (newest last).
M.kill_ring = {}

local function buf()
  return vim.api.nvim_get_current_buf()
end

local function cursor()
  return vim.api.nvim_win_get_cursor(0)
end

local function get_lines(bufnr, s, e)
  return vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
end

local function set_lines(bufnr, s, e, lines)
  vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, lines)
end

local function is_blank(l)
  return l == nil or l:match("^%s*$") ~= nil
end

--- Insert `lines` before line `at` (a line past the end appends). Lines
--- inserted right before a fold become part of it for Vim, which then
--- forgets the open/closed state of the folds nested in it; appended to
--- the end of the line above instead, the folds below are kept.
local function insert_lines(bufnr, at, lines)
  if at <= 1 or #lines == 0 then
    vim.api.nvim_buf_set_lines(bufnr, at - 1, at - 1, false, lines)
    return
  end
  local prev = vim.api.nvim_buf_get_lines(bufnr, at - 2, at - 1, false)[1]
  local text = { "" }
  vim.list_extend(text, lines)
  vim.api.nvim_buf_set_text(bufnr, at - 2, #prev, at - 2, #prev, text)
end

--- Whether only odd levels are used (org-odd-levels-only, `#+STARTUP:
--- odd` / `oddeven`).
function M.odd_levels_only(bufnr)
  local ok, file = pcall(files.get_buffer, bufnr or 0)
  local startup = ok and file.settings.startup or {}
  if startup.odd then
    return true
  elseif startup.oddeven then
    return false
  end
  return config.opts.odd_levels_only == true
end

--- Level step of promote/demote (org-level-increment).
function M.level_increment(bufnr)
  return M.odd_levels_only(bufnr) and 2 or 1
end

local function current_headline()
  local file = files.get_buffer(0)
  local hl = file:headline_at(cursor()[1])
  return hl, file
end

local exit_visual = utils.exit_visual

local function in_visual()
  local m = vim.fn.mode()
  return m == "v" or m == "V" or m == "\22"
end

local function start_insert()
  if vim.fn.mode():sub(1, 1) == "i" then
    return
  end
  utils.start_insert()
end

local function siblings(hl)
  if hl.inlinetask then
    -- inline tasks are not in the outline tree: no siblings
    return { hl }
  end
  return hl.parent and hl.parent.children or hl.file.children
end

local function sibling_index(hl)
  for i, s in ipairs(siblings(hl)) do
    if s.line == hl.line then
      return i
    end
  end
end

--- Rewrite headline lines in `lines` with level delta, realigning tags and
--- fixing the indentation when `adapt_indentation` is on, like
--- org-fixup-indentation: the planning line and property drawer right after
--- a headline are indented to its new level (properties aligned), the
--- LOGBOOK drawer and, unless it is "headline-data", the other lines are
--- shifted by the level change.
local function relevel(lines, delta, todo_cfg)
  local adapt = require("org.ui.decorations").adapt_indentation(0)
  -- headline data: i -> "planning" | "properties" | "log", with the level
  local data, data_level = {}, {}
  if adapt then
    for h, l in ipairs(lines) do
      local level = parser.headline_level(l)
      if level then
        local j = h + 1
        local nxt = lines[j] or ""
        if nxt:match("^%s*SCHEDULED:") or nxt:match("^%s*DEADLINE:") or nxt:match("^%s*CLOSED:") then
          data[j], data_level[j] = "planning", level
          j = j + 1
        end
        for _, name in ipairs({ "PROPERTIES", "LOGBOOK" }) do
          if (lines[j] or ""):upper():match("^%s*:" .. name .. ":%s*$") then
            local k = j
            while lines[k] and not lines[k]:upper():match("^%s*:END:%s*$") do
              k = k + 1
            end
            if lines[k] then
              for m = j, k do
                data[m], data_level[m] = name == "PROPERTIES" and "properties" or "log", level
              end
              j = k + 1
            end
          end
        end
      end
    end
  end
  local function shift(l)
    if delta > 0 then
      return string.rep(" ", delta) .. l
    end
    local n = math.min(-delta, #l:match("^(%s*)"))
    return l:sub(n + 1)
  end
  local out = {}
  for i, l in ipairs(lines) do
    -- inline tasks keep their level (org-with-limited-levels)
    local p = parser.outline_level(l) and parser.parse_headline_line(l, todo_cfg)
    local kind = data[i]
    if p then
      -- like org-promote / org-demote: change the stars, realign the tags
      out[i] = string.rep("*", math.max(1, p.level + delta)) .. l:sub(#l:match("^%*+") + 1)
      if #p.tags > 0 and edit.auto_align_tags() then
        local s = out[i]:find("[ \t]+:[^%s]+:[ \t]*$")
        if s then
          out[i] = edit.with_tags(out[i]:sub(1, s - 1), p.tags)
        end
      end
    elseif kind == "planning" or kind == "properties" then
      local ind = string.rep(" ", math.max(1, data_level[i] + delta) + 1)
      local key, value = l:match("^%s*:([^%s:]+%+?):%s*(.-)%s*$")
      if kind == "properties" and key and key:upper() ~= "PROPERTIES" and key:upper() ~= "END" then
        local fmt = config.opts.property_format or "%-10s %s"
        out[i] = ind .. vim.trim(string.format(fmt, ":" .. key .. ":", value))
      else
        out[i] = ind .. vim.trim(l)
      end
    elseif kind == "log" then
      out[i] = is_blank(l) and l or shift(l)
    elseif
      adapt
      and adapt ~= "headline-data"
      and not is_blank(l)
      and not l:match("^#%+")
      and not parser.headline_level(l)
    then
      out[i] = shift(l)
    else
      out[i] = l
    end
  end
  return out
end

-- Local functions the parts below share
local shared = require("org.structure.shared")
shared.buf = buf
shared.cursor = cursor
shared.current_headline = current_headline
shared.exit_visual = exit_visual
shared.get_lines = get_lines
shared.in_visual = in_visual
shared.insert_lines = insert_lines
shared.is_blank = is_blank
shared.relevel = relevel
shared.set_lines = set_lines
shared.sibling_index = sibling_index
shared.siblings = siblings
shared.start_insert = start_insert

require("org.structure.heading")
require("org.structure.template")
require("org.structure.level")
require("org.structure.move")
require("org.structure.kill")
require("org.structure.sort")
require("org.structure.narrow")
require("org.structure.toggle")
require("org.structure.motion")

return M

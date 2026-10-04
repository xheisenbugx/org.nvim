---@mod org.structure.toggle Toggles and emphasis
---
--- Toggle COMMENT and headings, insert emphasis markers.
---
--- Part of org.structure, which loads it.

local edit = require("org.edit")
local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")
local shared = require("org.structure.shared")

local M = require("org.structure")

local buf = shared.buf
local cursor = shared.cursor
local current_headline = shared.current_headline
local exit_visual = shared.exit_visual
local get_lines = shared.get_lines
local in_visual = shared.in_visual
local is_blank = shared.is_blank
local set_lines = shared.set_lines
local start_insert = shared.start_insert

---------------------------------------------------------------------------
-- Toggles
---------------------------------------------------------------------------

function M.toggle_comment()
  local bufnr = buf()
  local hl = current_headline()
  if not hl then
    utils.warn("Not on a headline")
    return
  end
  edit.update_headline(bufnr, hl.line, { commented = not hl.commented })
end

--- org-toggle-heading (C-c *): headlines become text; list items become
--- headlines one level below the current entry (checkboxes turn into
--- TODO / DONE); text lines become headlines. In Visual mode every line
--- of the selection; with a count (C-u) on text, only the first line, and
--- on an item the whole list.
function M.toggle_heading()
  local bufnr = buf()
  local file = files.get_buffer(bufnr)
  local lists = require("org.lists")
  local count = vim.v.count
  local s, e
  local region = in_visual()
  if region then
    s, _, e = utils.visual_range()
    exit_visual()
  else
    s = cursor()[1]
    e = s
    if count > 0 and lists.item_on(bufnr, s) then
      local struct = lists.struct_at(bufnr, s)
      s, e, region = struct.first, struct.last, true
    end
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- skip blank and comment lines
  while s < e and (is_blank(lines[s]) or lines[s]:match("^%s*#%s") or lines[s]:match("^%s*#$")) do
    s = s + 1
  end
  local toggled = false
  if parser.headline_level(lines[s]) then
    for i = s, e do
      if parser.headline_level(lines[i]) then
        lines[i] = lines[i]:gsub("^%*+ ", "", 1)
        toggled = true
      end
    end
    set_lines(bufnr, s, e, vim.list_slice(lines, s, e))
  elseif lists.item_on(bufnr, s) then
    local struct = lists.struct_at(bufnr, s)
    local hl = file:headline_at(s)
    local level = hl and hl.level + 1 or 1
    local stop = math.min(struct.last, e)
    local sel = {}
    for _, it in ipairs(struct.items) do
      if it.lnum >= s and it.lnum <= stop then
        sel[#sel + 1] = it
      end
    end
    local in_sel = {}
    for _, it in ipairs(sel) do
      in_sel[it] = true
    end
    local todo_cfg = file.settings.todo
    local done_kw = todo_cfg:done_names()[1] or "DONE"
    local todo_kw = todo_cfg:todo_names()[1] or "TODO"
    local out = {}
    for _, it in ipairs(sel) do
      local depth = 1
      local p = it.parent
      while p do
        if in_sel[p] then
          depth = depth + 1
        end
        p = p.parent
      end
      local text = lines[it.lnum]:sub(it.content_col + 1)
      if it.tag then
        local term, desc = text:match("^(.-)%s+::%s*(.*)$")
        text = " " .. (term or "") .. " " .. (desc or "")
      end
      local kw = it.checkbox == "X" and (done_kw .. " ") or it.checkbox and (todo_kw .. " ") or ""
      out[#out + 1] = (string.rep("*", level + depth - 1) .. " " .. kw .. text):gsub("%s+$", "")
      if region then
        for l = it.lnum + 1, math.min(it.end_lnum, stop) do
          local owner
          for _, o in ipairs(struct.items) do
            if o.lnum <= l and l <= o.end_lnum then
              owner = o
            end
          end
          if owner == it and not is_blank(lines[l]) then
            out[#out + 1] = vim.trim(lines[l])
          end
        end
      end
    end
    set_lines(bufnr, s, region and stop or s, out)
    toggled = true
  else
    local hl = file:headline_at(s)
    local stars
    if count > 0 and count ~= 4 then
      stars = string.rep("*", count)
    else
      local cur = hl and hl.level or 0
      local add = cur == 0 and "*" or (M.odd_levels_only(bufnr) and "**" or "*")
      stars = string.rep("*", cur) .. add
    end
    local last = (count == 4) and s or e
    for i = s, last do
      local l = lines[i]
      if
        not is_blank(l)
        and not parser.headline_level(l)
        and not lists.parse_item_line(l)
        and not (l:match("^%s*#%s") or l:match("^%s*#$"))
      then
        lines[i] = stars .. " " .. l:gsub("^%s+", "")
        toggled = true
      end
    end
    set_lines(bufnr, s, last, vim.list_slice(lines, s, last))
  end
  if not toggled then
    utils.notify("Cannot toggle heading from here")
  end
end

--- Characters allowed before and after emphasis markers
--- (org-emphasis-regexp-components).
local EMPH_PRE = "[%-%s%('\"{]"
local EMPH_POST = "[%-%s%.,:!%?;'\"%)}\\%[]"

--- org-emphasize (C-c C-x C-f): wrap the Visual selection in an emphasis
--- marker, replacing markers already around it (a space removes them).
--- Without a selection, insert a pair of markers at the cursor and start
--- Insert mode between them. Spaces are added where the markers would
--- not be recognized.
function M.emphasize()
  local bufnr = buf()
  local visual = in_visual()
  local srow, scol, erow, ecol, mode
  if visual then
    srow, scol, erow, ecol, mode = utils.visual_range()
    exit_visual()
  end
  local ch = utils.getchar("Emphasis marker or tag: [*/_=~+]")
  if not ch then
    return
  end
  local s
  if ch == " " then
    s = ""
  elseif ch:match("^[%*/_=~%+]$") then
    s = ch
  else
    utils.warn(string.format('No such emphasis marker: "%s"', ch))
    return
  end
  local tb = require("org.textbuf").from_buffer(bufnr, visual and { srow, scol - 1 } or cursor())
  local text = ""
  if visual then
    local b, e
    if mode == "V" then
      local first = get_lines(bufnr, srow, srow)[1]
      b = tb:pos_of(srow, #first:match("^(%s*)"))
      e = tb:line_end(tb:pos_of(erow, 0))
    else
      b = tb:pos_of(srow, scol - 1)
      local last = get_lines(bufnr, erow, erow)[1]
      local char_len = ecol <= #last and #vim.fn.strcharpart(last:sub(ecol), 0, 1) or 1
      e = tb:pos_of(erow, math.min(ecol - 1 + math.max(char_len, 1), #last))
    end
    tb:goto_char(b)
    text = tb:delete(b, e)
    while #text > 1 and text:sub(1, 1) == text:sub(-1) and text:sub(1, 1):match("[%*/_=~%+]") do
      text = text:sub(2, -2)
    end
  end
  local new = s .. text .. s
  if not tb:bolp() and not tb.text:sub(tb.point - 1, tb.point - 1):match(EMPH_PRE) then
    tb:insert(" ")
  end
  if
    not tb:eobp()
    and not tb.text:sub(tb.point, tb.point):match(EMPH_POST)
    and tb.text:sub(tb.point, tb.point) ~= "\n"
  then
    tb:insert(" ")
    tb:goto_char(tb.point - 1)
  end
  tb:insert(new)
  if not visual then
    tb:goto_char(tb.point - 1)
  end
  tb:apply()
  if not visual and ch ~= " " then
    start_insert()
  end
end

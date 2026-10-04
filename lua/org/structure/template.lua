---@mod org.structure.template Drawers and structure templates
---
--- org-insert-drawer, org-insert-structure-template and the `<s` tempo
--- expansion.
---
--- Part of org.structure, which loads it.

local config = require("org.config")
local edit = require("org.edit")
local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")
local textbuf = require("org.textbuf")
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
-- Drawers & structure templates
---------------------------------------------------------------------------

--- Emacs point for commands that insert at point: in Insert mode the
--- cursor; in Normal mode the end of the line, or its beginning when the
--- cursor is in column 0.
local function command_point()
  local pos = cursor()
  if vim.fn.mode():sub(1, 1) == "i" or pos[2] == 0 then
    return pos
  end
  return { pos[1], #vim.api.nvim_get_current_line() }
end

--- Insert a drawer (org-insert-drawer, C-c C-x d): at the cursor (a line
--- is split, like Emacs), around the Visual selection, or a property
--- drawer with a count (C-u). Leaves the cursor inside it.
function M.insert_drawer()
  local bufnr = buf()
  local visual = in_visual()
  local s, e
  if visual then
    s, _, e = utils.visual_range()
    exit_visual()
  end
  if vim.v.count > 0 then
    local hl = current_headline()
    if not hl then
      utils.warn("Property drawers need a headline")
      return
    end
    if hl.properties_range then
      local r = hl.properties_range
      if r[2] == r[1] + 1 then
        set_lines(bufnr, r[2], r[2] - 1, { "" })
        vim.api.nvim_win_set_cursor(0, { r[2], 0 })
      else
        vim.api.nvim_win_set_cursor(0, { r[1] + 1, 0 })
      end
      return
    end
    local indent = edit.body_indent(hl.level)
    local at = hl.planning_line or hl.line
    set_lines(bufnr, at + 1, at, { indent .. ":PROPERTIES:", "", indent .. ":END:" })
    vim.api.nvim_win_set_cursor(0, { at + 2, 0 })
    return
  end
  local name = utils.input({ prompt = "Drawer: " })
  if name == nil then
    return
  end
  if not (":" .. name .. ":"):match("^:[%w_%-]+:$") then
    utils.warn("Invalid drawer name")
    return
  end
  if visual then
    local lines = get_lines(bufnr, s, e)
    for _, l in ipairs(lines) do
      if parser.headline_level(l) then
        utils.warn("Drawers cannot contain headlines")
        return
      end
    end
    while s < e and is_blank(get_lines(bufnr, s, s)[1]) do
      s = s + 1
    end
    while e > s and is_blank(get_lines(bufnr, e, e)[1]) do
      e = e - 1
    end
    local hl = files.get_buffer(bufnr):headline_at(s)
    local indent = hl and edit.body_indent(hl.level) or ""
    set_lines(bufnr, e + 1, e, { indent .. ":END:" })
    set_lines(bufnr, s, s - 1, { indent .. ":" .. name .. ":" })
    vim.api.nvim_win_set_cursor(0, { s, #indent })
    return
  end
  local tb = textbuf.from_buffer(bufnr, command_point())
  if not tb:bolp() then
    tb:insert("\n")
  end
  tb:insert(":" .. name .. ":\n\n:END:\n")
  tb:forward_line(-2)
  tb:apply()
  vim.cmd("startinsert")
end

--- Block types of the structure template menu (org-structure-template-alist).
function M.structure_templates()
  local out = {}
  for key, block in pairs(config.opts.structure_template_alist or {}) do
    if block then
      out[#out + 1] = { key = key, block = block }
    end
  end
  table.sort(out, function(a, b)
    if a.key:lower() ~= b.key:lower() then
      return a.key:lower() < b.key:lower()
    end
    return a.key > b.key
  end)
  return out
end

--- Insert a `#+begin_TYPE` / `#+end_TYPE` block around the Visual
--- selection, or an empty one at the cursor (a line is split when the
--- cursor is in the middle of it, like Emacs). For src and export blocks
--- the cursor goes after `#+begin_src ` to type the language; otherwise
--- inside the block. A type written in upper case gives #+BEGIN_/#+END_.
---@param type string
function M.insert_block(type, s, e)
  local bufnr = buf()
  local extended = type == "src" or type == "export"
  local first_word = type:match("^(%S+)") or type
  local upcase = first_word == first_word:upper() and first_word:lower() ~= first_word
  local begin_kw, end_kw = upcase and "BEGIN" or "begin", upcase and "END" or "end"
  local verbatim = type:match("^example") or type:match("^export") or type:match("^src") or type:match("^comment")
  if s then
    local lines = get_lines(bufnr, s, e)
    while #lines > 1 and is_blank(lines[#lines]) do
      table.remove(lines)
      e = e - 1
    end
    local column = #lines[1]:match("^(%s*)")
    local ind = string.rep(" ", column)
    if verbatim then
      lines = require("org.babel.blocks").escape(lines)
    end
    local out = { ind .. "#+" .. begin_kw .. "_" .. type .. (extended and " " or "") }
    vim.list_extend(out, lines)
    out[#out + 1] = ind .. "#+" .. end_kw .. "_" .. first_word
    set_lines(bufnr, s, e, out)
    vim.api.nvim_win_set_cursor(0, { s, #out[1] })
    return
  end
  local tb = textbuf.from_buffer(bufnr, command_point())
  local column = #tb:line():match("^(%s*)")
  local before = tb.text:sub(tb:line_beg(), tb.point - 1)
  if before:match("^%s*$") then
    tb:goto_char(tb:line_beg())
  else
    tb:insert("\n")
  end
  local ind = string.rep(" ", column)
  local save = tb.point
  tb:insert(ind .. "#+" .. begin_kw .. "_" .. type .. (extended and " " or "") .. "\n")
  tb:insert(ind .. "#+" .. end_kw .. "_" .. first_word)
  local rest = tb.text:sub(tb.point, tb:line_end() - 1)
  if rest:match("^[ \t]*$") then
    tb:delete(tb.point, tb:line_end())
  else
    tb:insert("\n")
  end
  tb:goto_char(save)
  if extended then
    tb:goto_char(tb:line_end())
  else
    tb:forward_line(1)
    tb:skip_forward(" \t")
  end
  tb:apply()
  start_insert()
end

--- org-tempo: expand `<KEY` before the cursor (Insert mode) into a block
--- of `structure_template_alist` or a keyword of `tempo_keywords`
--- (`<I` asks for a file to include). Returns true when it expanded.
function M.tempo_expand()
  local pos = cursor()
  local line = vim.api.nvim_get_current_line()
  local before = line:sub(1, pos[2])
  local key = before:match("<(%w+)$")
  if not key then
    return false
  end
  local start = pos[2] - #key - 1
  local ind = string.rep(" ", #line:match("^(%s*)"))
  local rest = line:sub(pos[2] + 1)
  local prefix = line:sub(1, start)
  local lnum = pos[1]
  local block = config.opts.structure_template_alist[key]
  local kw = (config.opts.tempo_keywords or {})[key]
  local out, row, col
  if block then
    local special = block == "src" or block == "export"
    local first = block:match("^(%S+)") or block
    local upcase = first == first:upper() and first:lower() ~= first
    local b, en = upcase and "BEGIN" or "begin", upcase and "END" or "end"
    local begin_line = prefix .. "#+" .. b .. "_" .. block .. (special and " " or "")
    if special then
      out = { begin_line .. rest, ind, ind .. "#+" .. en .. "_" .. first }
      row, col = lnum, #begin_line
    else
      out = { begin_line, ind .. rest, ind .. "#+" .. en .. "_" .. first }
      row, col = lnum + 1, #ind
    end
  elseif kw then
    local text = prefix .. "#+" .. kw .. ": "
    out = { text .. rest }
    row, col = lnum, #text
  elseif key == "I" then
    local f = utils.input({ prompt = "Include file: ", completion = "file" })
    if not f then
      return true
    end
    local rel = vim.fn.fnamemodify(f, ":.")
    local text = prefix .. '#+include: "' .. rel .. '" '
    out = { text .. rest }
    row, col = lnum, #text
  else
    return false
  end
  set_lines(0, lnum, lnum, out)
  vim.api.nvim_win_set_cursor(0, { row, col })
  return true
end

--- org-insert-structure-template (C-c C-,): pick a block type from
--- `structure_template_alist` (TAB asks for any type) and insert it.
function M.insert_structure_template()
  local visual = in_visual()
  local s, e
  if visual then
    s, _, e = utils.visual_range()
    exit_visual()
  end
  local items = {}
  for _, t in ipairs(M.structure_templates()) do
    items[#items + 1] = { key = t.key, label = t.block, value = t.block }
  end
  items[#items + 1] = { key = "\t", label = "(TAB) any block type", value = "\t" }
  local type = require("org.ui").menu({ title = "Insert structure", items = items })
  if not type then
    return
  end
  if type == "\t" then
    type = utils.input({ prompt = "Structure type: " })
    if not type then
      return
    end
    type = vim.trim(type)
    if type == "" then
      utils.warn("Empty structure type")
      return
    end
  end
  M.insert_block(type, s, e)
end

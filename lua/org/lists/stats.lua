---@mod org.lists.stats Statistics cookies
---
--- Counting checkboxes and TODO children into [n/m] and [%] cookies.
--- Part of org.lists, which loads it.

local files = require("org.files")
local shared = require("org.lists.shared")

local M = require("org.lists")

local curbuf = shared.curbuf
local cursor_lnum = shared.cursor_lnum
local lopt = shared.lopt
local set_lines = shared.set_lines

---------------------------------------------------------------------------
-- Statistics cookies
---------------------------------------------------------------------------

local function replace_cookies(line, done, total)
  local pct = total == 0 and 0 or math.floor(done * 100 / total)
  -- lint: allow gsub: numbers
  line = line:gsub("%[%d*/%d*%]", "[" .. done .. "/" .. total .. "]")
  -- lint: allow gsub: a number
  line = line:gsub("%[%d*%%%]", "[" .. pct .. "%%]")
  return line
end

local function has_cookie(line)
  return line:find("%[%d*/%d*%]") or line:find("%[%d*%%%]")
end

local function count_checkboxes(items, recursive)
  local done, total = 0, 0
  local function walk(list)
    for _, it in ipairs(list) do
      if it.checkbox then
        total = total + 1
        if it.checkbox == "X" then
          done = done + 1
        end
      end
      if recursive then
        walk(it.children)
      end
    end
  end
  walk(items)
  return done, total
end

--- Done and total counts of the child entries of `hl` that a TODO
--- statistics cookie counts (org-provide-todo-statistics).
---@return integer done, integer total
function M.todo_counts(file, hl)
  local cookie_data = (hl.properties.COOKIE_DATA or ""):lower()
  local cfg = require("org.config").opts
  local recursive = cookie_data:find("recursive") ~= nil or cfg.hierarchical_todo_statistics == false
  -- which headlines count (org-provide-todo-statistics): true = TODO
  -- keywords, "all-headlines", a list of keywords (plus done keywords) or
  -- { todo keywords, done keywords }
  local provide = cfg.provide_todo_statistics
  local function counts(c)
    local kw, done_kw = c.todo, c:is_done()
    if provide == "all-headlines" then
      return true, done_kw
    elseif type(provide) == "table" and type(provide[1]) == "table" then
      local in_done = done_kw and vim.tbl_contains(provide[2] or {}, kw)
      return vim.tbl_contains(provide[1], kw) or in_done, in_done
    elseif type(provide) == "table" then
      return vim.tbl_contains(provide, kw) or done_kw, done_kw
    end
    return kw ~= nil, done_kw
  end
  local done, total = 0, 0
  local function walk(children)
    for _, c in ipairs(children) do
      local counted, is_done = counts(c)
      if counted then
        total = total + 1
        if is_done then
          done = done + 1
        end
      end
      if recursive then
        walk(c.children)
      end
    end
  end
  walk(hl.children)
  return done, total
end

--- Whether checkbox cookies of the entry with COOKIE_DATA `cookie_data`
--- count every box below them (org-checkbox-hierarchical-statistics).
local function checkbox_recursive(cookie_data)
  return cookie_data:find("recursive") ~= nil or lopt("checkbox_hierarchical_statistics") == false
end

--- Counts for a headline cookie.
local function headline_counts(file, hl)
  local cookie_data = (hl.properties.COOKIE_DATA or ""):lower()
  local recursive = checkbox_recursive(cookie_data)
  local mode
  if cookie_data:find("todo") then
    mode = "todo"
  elseif cookie_data:find("checkbox") then
    mode = "checkbox"
  end
  local lists = M.parse_region(file.lines, hl.line + 1, hl.body_end)
  if not mode then
    local d, t = 0, 0
    for _, l in ipairs(lists) do
      local a, b = count_checkboxes(l.items, recursive)
      d, t = d + a, t + b
    end
    if t > 0 then
      return d, t
    end
    mode = "todo"
  end
  if mode == "checkbox" then
    local d, t = 0, 0
    for _, l in ipairs(lists) do
      local a, b = count_checkboxes(l.items, recursive)
      d, t = d + a, t + b
    end
    return d, t
  end
  return M.todo_counts(file, hl)
end

--- Update cookies in list items of lines[from..to] and in headline `hl`.
local function update_section(bufnr, file, hl, from, to)
  local lines = file.lines
  local changes = {}
  local _, all = M.parse_region(lines, from, to)
  local cookie_data = (hl and hl.properties.COOKIE_DATA or ""):lower()
  -- COOKIE_DATA "todo": the entry's cookies count TODO children only
  if not cookie_data:find("todo") then
    local recursive = checkbox_recursive(cookie_data)
    for _, it in ipairs(all) do
      if has_cookie(lines[it.lnum]) then
        local d, t = count_checkboxes(it.children, recursive)
        changes[it.lnum] = replace_cookies(lines[it.lnum], d, t)
      end
    end
  end
  if hl and has_cookie(lines[hl.line]) then
    local d, t = headline_counts(file, hl)
    changes[hl.line] = replace_cookies(lines[hl.line], d, t)
  end
  for lnum, text in pairs(changes) do
    if text ~= lines[lnum] then
      set_lines(bufnr, lnum, lnum, { text })
    end
  end
end

--- Update the cookies relevant to `lnum`: list items in its section, the
--- containing headline and every ancestor headline.
function M.update_statistics_for(bufnr, lnum)
  bufnr = curbuf(bufnr)
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    update_section(bufnr, file, nil, 1, file.preamble_end)
    return
  end
  local chain = {}
  local h = hl
  while h do
    chain[#chain + 1] = h.line
    h = h.parent
  end
  for idx, l in ipairs(chain) do
    file = files.get_buffer(bufnr)
    local cur = file:headline_on(l)
    if cur then
      if idx == 1 then
        update_section(bufnr, file, cur, cur.line + 1, cur.body_end)
      else
        update_section(bufnr, file, cur, cur.line + 1, cur.line)
      end
    end
  end
end

--- Update every statistics cookie of the buffer.
function M.update_all_statistics(bufnr)
  bufnr = curbuf(bufnr)
  local file = files.get_buffer(bufnr)
  update_section(bufnr, file, nil, 1, file.preamble_end)
  -- deepest headlines first so parents see updated children
  local lines_list = {}
  for _, h in ipairs(file.headlines) do
    lines_list[#lines_list + 1] = { line = h.line, level = h.level }
  end
  table.sort(lines_list, function(a, b)
    return a.level > b.level
  end)
  for _, e in ipairs(lines_list) do
    file = files.get_buffer(bufnr)
    local h = file:headline_on(e.line)
    if h then
      update_section(bufnr, file, h, h.line + 1, h.body_end)
    end
  end
end

--- C-c # (org-update-statistics-cookies): update the cookies of the
--- current entry. On a headline with child entries and no checkboxes, its
--- TODO cookie; on a leaf headline without checkboxes, the cookie becomes
--- [0/0] / [100%]. With a count (C-u), update every cookie of the buffer.
function M.update_statistics()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.v.count > 0 then
    return M.update_all_statistics(bufnr)
  end
  local lnum = cursor_lnum()
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    update_section(bufnr, file, nil, 1, file.preamble_end)
    return
  end
  if hl.line ~= lnum then
    update_section(bufnr, file, hl, hl.line + 1, hl.body_end)
    return
  end
  local _, all = M.parse_region(file.lines, hl.line + 1, hl.body_end)
  local has_boxes = false
  for _, it in ipairs(all) do
    if it.checkbox then
      has_boxes = true
    end
  end
  local todo_cookie = (hl.properties.COOKIE_DATA or ""):lower():find("todo")
  if has_boxes and not todo_cookie then
    update_section(bufnr, file, hl, hl.line + 1, hl.body_end)
  elseif #hl.children > 0 then
    update_section(bufnr, file, hl, hl.line + 1, hl.line)
  else
    local line = file.lines[hl.line]
    local new = line:gsub("%[%d*%%%]", "[100%%]"):gsub("%[%d*/%d*%]", "[0/0]")
    if new ~= line then
      set_lines(bufnr, hl.line, hl.line, { new })
    end
  end
end

shared.update_section = update_section

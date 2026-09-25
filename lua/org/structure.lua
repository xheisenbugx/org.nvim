---@mod org.structure Structure editing and navigation
---
--- Headline insertion, promotion/demotion, subtree moves, the subtree kill
--- ring, cloning, sorting, narrowing, structure templates and headline
--- motions / text objects.

local config = require("org.config")
local date = require("org.date")
local edit = require("org.edit")
local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")

local M = {}

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

local function current_headline()
  local file = files.get_buffer(0)
  local hl = file:headline_at(cursor()[1])
  return hl, file
end

local function exit_visual()
  local m = vim.fn.mode()
  if m == "v" or m == "V" or m == "\22" then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
end

local function in_visual()
  local m = vim.fn.mode()
  return m == "v" or m == "V" or m == "\22"
end

--- Rewrite headline lines in `lines` with level delta, realigning tags and
--- shifting body indentation when `adapt_indentation` is on.
local function relevel(lines, delta, todo_cfg)
  local adapt = config.opts.adapt_indentation
  local out = {}
  for i, l in ipairs(lines) do
    local p = parser.parse_headline_line(l, todo_cfg)
    if p then
      p.level = math.max(1, p.level + delta)
      out[i] = edit.build_headline(p)
      if p.title == "" and not p.todo and #p.tags == 0 then
        out[i] = string.rep("*", p.level) .. l:sub(#l:match("^%*+") + 1)
      end
    elseif adapt and not is_blank(l) and not l:match("^#%+") then
      if delta > 0 then
        out[i] = string.rep(" ", delta) .. l
      else
        local n = math.min(-delta, #l:match("^(%s*)"))
        out[i] = l:sub(n + 1)
      end
    else
      out[i] = l
    end
  end
  return out
end

--- Whether to put a blank line before a new heading.
local function want_blank(bufnr, hl)
  local b = config.opts.blank_before_new_entry
  local v = type(b) == "table" and b.heading or b
  if v == true then
    return true
  elseif v == "auto" and hl then
    return hl.line > 1 and is_blank(get_lines(bufnr, hl.line - 1, hl.line - 1)[1])
  end
  return false
end

---------------------------------------------------------------------------
-- Inserting headings
---------------------------------------------------------------------------

local function heading_text(level, todo)
  local s = string.rep("*", level) .. " "
  if todo then
    s = s .. todo .. " "
  end
  return s
end

--- Insert a heading of `level` after line `after` (0 = top of buffer).
local function insert_heading_at(bufnr, after, level, todo, blank)
  local lines = { heading_text(level, todo) }
  if blank and after > 0 and not is_blank(get_lines(bufnr, after, after)[1]) then
    table.insert(lines, 1, "")
  end
  set_lines(bufnr, after + 1, after, lines)
  local lnum = after + #lines
  vim.api.nvim_win_set_cursor(0, { lnum, #lines[#lines] })
  return lnum
end

local function first_todo(file)
  return file.settings.todo:first_todo()
end

--- M-RET on/under a headline.
---@param opts { todo?: boolean, respect_content?: boolean }
function M.meta_return_heading(opts)
  opts = opts or {}
  local bufnr = buf()
  local hl, file = current_headline()
  local todo = opts.todo and first_todo(file) or nil
  local pos = cursor()
  if not hl then
    local line = vim.api.nvim_get_current_line()
    if is_blank(line) then
      set_lines(bufnr, pos[1], pos[1], { heading_text(1, todo) })
      vim.api.nvim_win_set_cursor(0, { pos[1], #heading_text(1, todo) })
      return
    end
    insert_heading_at(bufnr, pos[1], 1, todo, false)
    return
  end
  if not opts.respect_content and pos[1] == hl.line and pos[2] == 0 then
    -- at the beginning of a headline: new sibling above
    set_lines(bufnr, hl.line, hl.line - 1, { heading_text(hl.level, todo) })
    vim.api.nvim_win_set_cursor(0, { hl.line, #heading_text(hl.level, todo) })
    return
  end
  local after = hl.end_line
  local trailing_blank = is_blank(get_lines(bufnr, after, after)[1]) and after > hl.line
  insert_heading_at(bufnr, after, hl.level, todo, want_blank(bufnr, hl) and not trailing_blank)
end

local function start_insert()
  vim.cmd("startinsert!")
end

function M.insert_heading()
  M.meta_return_heading({ respect_content = true })
  start_insert()
end

function M.insert_todo_heading()
  M.meta_return_heading({ respect_content = true, todo = true })
  start_insert()
end

--- Insert a child heading right after the current entry's own section.
function M.insert_subheading()
  local bufnr = buf()
  local hl = current_headline()
  if not hl then
    return M.insert_heading()
  end
  insert_heading_at(bufnr, hl.body_end, hl.level + 1, nil, false)
  start_insert()
end

---------------------------------------------------------------------------
-- Drawers & structure templates
---------------------------------------------------------------------------

function M.insert_drawer()
  local bufnr = buf()
  local visual = in_visual()
  local s, e
  if visual then
    s, _, e = utils.visual_range()
    exit_visual()
  end
  local name = utils.input({ prompt = "Drawer name (empty = PROPERTIES): " })
  if name == nil then
    return
  end
  name = vim.trim(name)
  if name == "" then
    local hl = current_headline()
    if not hl then
      utils.warn("Property drawers need a headline")
      return
    end
    if hl.properties_range then
      vim.api.nvim_win_set_cursor(0, { hl.properties_range[1], 0 })
      return
    end
    local indent = edit.body_indent(hl.level)
    local at = hl.planning_line or hl.line
    set_lines(bufnr, at + 1, at, { indent .. ":PROPERTIES:", indent .. ":END:" })
    vim.api.nvim_win_set_cursor(0, { at + 1, 0 })
    return
  end
  name = name:upper()
  if visual then
    local indent = get_lines(bufnr, s, s)[1]:match("^(%s*)")
    set_lines(bufnr, e + 1, e, { indent .. ":END:" })
    set_lines(bufnr, s, s - 1, { indent .. ":" .. name .. ":" })
    return
  end
  local lnum = cursor()[1]
  local line = vim.api.nvim_get_current_line()
  local hl = current_headline()
  local at, indent
  if hl and lnum == hl.line then
    at = edit.meta_end(hl)
    indent = edit.body_indent(hl.level)
  else
    at = lnum
    indent = line:match("^(%s*)")
  end
  set_lines(bufnr, at + 1, at, { indent .. ":" .. name .. ":", indent, indent .. ":END:" })
  vim.api.nvim_win_set_cursor(0, { at + 2, #indent })
  vim.cmd("startinsert!")
end

M.templates = {
  { key = "a", label = "export ascii", block = "export", args = "ascii" },
  { key = "c", label = "center", block = "center" },
  { key = "C", label = "comment", block = "comment" },
  { key = "e", label = "example", block = "example" },
  { key = "E", label = "export", block = "export", prompt = "Export backend: " },
  { key = "x", label = "export (backend)", block = "export", prompt = "Export backend: " },
  { key = "h", label = "export html", block = "export", args = "html" },
  { key = "l", label = "export latex", block = "export", args = "latex" },
  { key = "q", label = "quote", block = "quote" },
  { key = "s", label = "src", block = "src", prompt = "Language: " },
  { key = "v", label = "verse", block = "verse" },
  { key = "i", label = "index", keyword = "index" },
}

function M.insert_structure_template()
  local bufnr = buf()
  local visual = in_visual()
  local s, e
  if visual then
    s, _, e = utils.visual_range()
    exit_visual()
  end
  local items = {}
  for _, t in ipairs(M.templates) do
    items[#items + 1] = { key = t.key, label = t.label, value = t }
  end
  local t = require("org.ui").menu({ title = "Insert structure", items = items })
  if not t then
    return
  end
  local args = t.args
  if t.prompt then
    args = utils.input({ prompt = t.prompt })
    if args == nil then
      return
    end
    args = vim.trim(args)
  end
  local lnum = cursor()[1]
  local line = vim.api.nvim_get_current_line()
  if t.keyword then
    local indent = line:match("^(%s*)")
    local text = indent .. "#+" .. t.keyword .. ": "
    if is_blank(line) then
      set_lines(bufnr, lnum, lnum, { text })
    else
      set_lines(bufnr, lnum + 1, lnum, { text })
      lnum = lnum + 1
    end
    vim.api.nvim_win_set_cursor(0, { lnum, #text })
    vim.cmd("startinsert!")
    return
  end
  local begin = "#+begin_" .. t.block .. ((args and args ~= "") and (" " .. args) or "")
  local finish = "#+end_" .. t.block
  if visual then
    local indent = get_lines(bufnr, s, s)[1]:match("^(%s*)")
    set_lines(bufnr, e + 1, e, { indent .. finish })
    set_lines(bufnr, s, s - 1, { indent .. begin })
    vim.api.nvim_win_set_cursor(0, { s, 0 })
    return
  end
  local indent = line:match("^(%s*)")
  local block = { indent .. begin, indent, indent .. finish }
  if is_blank(line) then
    set_lines(bufnr, lnum, lnum, block)
  else
    set_lines(bufnr, lnum + 1, lnum, block)
    lnum = lnum + 1
  end
  vim.api.nvim_win_set_cursor(0, { lnum + 1, #indent })
  vim.cmd("startinsert!")
end

---------------------------------------------------------------------------
-- Promote / demote
---------------------------------------------------------------------------

local function change_level(hl, file, delta, subtree)
  local bufnr = buf()
  if hl.level + delta < 1 then
    utils.warn("Cannot promote to level 0. Use toggle_heading to turn it into text")
    return
  end
  local s = hl.line
  local e = subtree and hl.end_line or hl.body_end
  local lines = get_lines(bufnr, s, e)
  local new = relevel(lines, delta, file.settings.todo)
  if not subtree then
    -- only the headline (and its own body when adapting indentation)
    for i = 2, #new do
      if parser.headline_level(lines[i]) then
        new[i] = lines[i]
      end
    end
  end
  local pos = cursor()
  set_lines(bufnr, s, e, new)
  local l = vim.api.nvim_buf_get_lines(bufnr, pos[1] - 1, pos[1], false)[1] or ""
  vim.api.nvim_win_set_cursor(0, { pos[1], math.max(0, math.min(pos[2] + delta, #l)) })
end

local function headline_for_level_change()
  local hl, file = current_headline()
  if not hl then
    utils.warn("Not on a headline")
    return nil
  end
  return hl, file
end

function M.promote_heading()
  local hl, file = headline_for_level_change()
  if hl then
    change_level(hl, file, -1, false)
  end
end

function M.demote_heading()
  local hl, file = headline_for_level_change()
  if hl then
    change_level(hl, file, 1, false)
  end
end

function M.promote_subtree()
  local hl, file = headline_for_level_change()
  if hl then
    for _ = 1, math.max(vim.v.count, 1) do
      change_level(hl, file, -1, true)
      hl, file = current_headline()
      if hl.level == 1 then
        break
      end
    end
  end
end

function M.demote_subtree()
  local hl, file = headline_for_level_change()
  if hl then
    for _ = 1, math.max(vim.v.count, 1) do
      change_level(hl, file, 1, true)
      hl, file = current_headline()
    end
  end
end

--- Promote (delta < 0) or demote (delta > 0) every headline in the
--- Visual selection (org-metaleft / org-metaright with an active region).
--- Returns false when the selection contains no headline.
function M.change_level_region(delta)
  local bufnr = buf()
  local s, _, e = utils.visual_range()
  exit_visual()
  local file = files.get_buffer(bufnr)
  local heads = {}
  for _, hl in ipairs(file.headlines) do
    if hl.line >= s and hl.line <= e then
      heads[#heads + 1] = hl
    end
  end
  if #heads == 0 then
    return false
  end
  for _, hl in ipairs(heads) do
    if hl.level + delta < 1 then
      utils.warn("Cannot promote to level 0. Use toggle_heading to turn it into text")
      return
    end
  end
  -- bottom-up so body re-indentation keeps line numbers valid
  for i = #heads, 1, -1 do
    local hl = heads[i]
    local lines = get_lines(bufnr, hl.line, hl.body_end)
    local new = relevel(lines, delta, file.settings.todo)
    for j = 2, #new do
      if parser.headline_level(lines[j]) then
        new[j] = lines[j]
      end
    end
    set_lines(bufnr, hl.line, hl.body_end, new)
  end
end

--- On an empty headline (only stars and maybe a TODO keyword), cycle its
--- level: child of the previous entry, then up the hierarchy, then back
--- (org-cycle-level, used by TAB right after M-RET). Returns false when
--- the headline is not empty.
function M.cycle_level()
  local bufnr = buf()
  local lnum = cursor()[1]
  local line = vim.api.nvim_get_current_line()
  local file = files.get_buffer(bufnr)
  local p = parser.parse_headline_line(line, file.settings.todo)
  if not p or vim.trim(p.title) ~= "" or p.priority or #p.tags > 0 then
    return false
  end
  local cur = p.level
  local prev_hl = lnum > 1 and file:headline_at(lnum - 1) or nil
  local prev = prev_hl and prev_hl.level or 0
  local new
  if prev == 0 then
    new = 1 -- first headline of the file
  elseif prev == cur then
    new = cur + 1 -- sibling -> child
  elseif prev == 1 then
    new = 1
  elseif cur == 1 then
    new = prev -- back to the sibling level
  elseif cur < prev then
    new = cur - 1
  else
    new = prev - 1
  end
  local rest = line:sub(#line:match("^%*+") + 1)
  local text = string.rep("*", math.max(new, 1)) .. rest
  vim.api.nvim_set_current_line(text)
  vim.api.nvim_win_set_cursor(0, { lnum, #text })
end

--- Drag the line at the cursor up (dir = -1) or down (dir = 1), count
--- times (org-drag-line-backward / org-drag-line-forward, M-S-Up/Down).
function M.drag_line(dir)
  local bufnr = buf()
  local pos = cursor()
  local n = math.max(vim.v.count, 1)
  local target = pos[1] + dir * n
  if target < 1 or target > vim.api.nvim_buf_line_count(bufnr) then
    utils.warn("Cannot move line " .. (dir < 0 and "up" or "down"))
    return
  end
  local line = get_lines(bufnr, pos[1], pos[1])[1]
  set_lines(bufnr, pos[1], pos[1], {})
  set_lines(bufnr, target, target - 1, { line })
  vim.api.nvim_win_set_cursor(0, { target, pos[2] })
end

---------------------------------------------------------------------------
-- Moving subtrees
---------------------------------------------------------------------------

local function siblings(hl)
  return hl.parent and hl.parent.children or hl.file.children
end

local function sibling_index(hl)
  for i, s in ipairs(siblings(hl)) do
    if s.line == hl.line then
      return i
    end
  end
end

local function move_subtree(dir)
  local bufnr = buf()
  for _ = 1, math.max(vim.v.count, 1) do
    local hl = current_headline()
    if not hl then
      utils.warn("Not on a headline")
      return
    end
    local sibs = siblings(hl)
    local idx = sibling_index(hl)
    local other = sibs[idx + dir]
    if not other then
      utils.warn("Cannot move past " .. (dir < 0 and "first" or "last") .. " sibling")
      return
    end
    local a, b = hl, other
    if dir < 0 then
      a, b = other, hl
    end
    local a_lines = get_lines(bufnr, a.line, a.end_line)
    local b_lines = get_lines(bufnr, b.line, b.end_line)
    -- the last subtree of the buffer may lack the trailing blank the
    -- other one carries; keep blank-line separation stable
    local pos = cursor()
    local offset = pos[1] - hl.line
    set_lines(bufnr, a.line, b.end_line, vim.list_extend(vim.deepcopy(b_lines), a_lines))
    local new_start = dir < 0 and a.line or (a.line + #b_lines)
    vim.api.nvim_win_set_cursor(0, { new_start + offset, pos[2] })
  end
end

function M.move_subtree_up()
  move_subtree(-1)
end

function M.move_subtree_down()
  move_subtree(1)
end

---------------------------------------------------------------------------
-- Kill ring
---------------------------------------------------------------------------

local function subtree_lines()
  local hl = current_headline()
  if not hl then
    utils.warn("Not in a subtree")
    return nil
  end
  local count = math.max(vim.v.count, 1)
  local last = hl
  local sibs = siblings(hl)
  local idx = sibling_index(hl)
  for i = 1, count - 1 do
    if sibs[idx + i] then
      last = sibs[idx + i]
    end
  end
  return hl, get_lines(buf(), hl.line, last.end_line), last.end_line
end

local function remember(lines)
  table.insert(M.kill_ring, vim.deepcopy(lines))
  if #M.kill_ring > 20 then
    table.remove(M.kill_ring, 1)
  end
  vim.fn.setreg('"', lines, "l")
  pcall(vim.fn.setreg, "0", lines, "l")
end

function M.copy_subtree()
  local hl, lines = subtree_lines()
  if not hl then
    return
  end
  remember(lines)
  utils.notify(string.format("Copied subtree (%d lines)", #lines))
end

function M.cut_subtree()
  local hl, lines, last = subtree_lines()
  if not hl then
    return
  end
  remember(lines)
  set_lines(buf(), hl.line, last, {})
  local n = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.min(hl.line, n), 0 })
  utils.notify(string.format("Cut subtree (%d lines)", #lines))
end

--- Paste the last killed subtree (or a subtree in the unnamed register)
--- after the current subtree, at the current level (count = level).
function M.paste_subtree()
  local bufnr = buf()
  local reg = vim.fn.getreg('"', 1, true)
  local lines
  if type(reg) == "table" and reg[1] and parser.headline_level(reg[1]) then
    lines = reg
  else
    lines = M.kill_ring[#M.kill_ring]
  end
  if not lines or not lines[1] or not parser.headline_level(lines[1]) then
    utils.warn("Nothing to paste: no subtree in the kill ring or register")
    return
  end
  local hl, file = current_headline()
  local level, after
  if hl then
    level = hl.level
    after = hl.end_line
  else
    level = 1
    after = cursor()[1]
  end
  if vim.v.count > 0 then
    level = vim.v.count
  end
  local first_level = parser.headline_level(lines[1])
  local new = relevel(lines, level - first_level, file.settings.todo)
  set_lines(bufnr, after + 1, after, new)
  vim.api.nvim_win_set_cursor(0, { after + 1, 0 })
end

---------------------------------------------------------------------------
-- Clone with time shift
---------------------------------------------------------------------------

--- Shift all timestamps (except CLOCK lines) in `line`.
local function shift_line_timestamps(line, n, unit, strip_repeater)
  if line:match("^%s*CLOCK:") then
    return line
  end
  local items = date.parse_all(line)
  for i = #items, 1, -1 do
    local it = items[i]
    local d = it.date
    local nd = n ~= 0 and d:add_with_range(n, unit) or d:clone()
    if d.range_end and not nd.range_end then
      nd.range_end = d.range_end
    end
    if strip_repeater then
      nd.repeater = nil
      if nd.range_end then
        nd.range_end.repeater = nil
      end
    end
    line = line:sub(1, it.start_col - 1) .. nd:to_string() .. line:sub(it.end_col + 1)
  end
  return line
end

function M.clone_subtree()
  local bufnr = buf()
  local hl = current_headline()
  if not hl then
    utils.warn("Not in a subtree")
    return
  end
  local n = utils.input({ prompt = "Number of clones to produce: ", default = "1" })
  n = tonumber(n or "")
  if not n or n < 1 then
    return
  end
  local shift = utils.input({ prompt = "Date shift per clone (e.g. +1w, empty to copy unchanged): " })
  if shift == nil then
    return
  end
  local sn, su = vim.trim(shift):match("^%+?(%d+)([hdwmy])$")
  sn = tonumber(sn or 0)
  su = su or "d"
  local src = get_lines(bufnr, hl.line, hl.end_line)
  local out = {}
  for i = 1, n do
    local clone = {}
    for _, l in ipairs(src) do
      if not l:match("^%s*:ID:") then
        clone[#clone + 1] = shift_line_timestamps(l, sn * i, su, sn ~= 0)
      end
    end
    -- drop property drawers emptied by removing the ID
    for j = #clone - 1, 1, -1 do
      if clone[j]:match("^%s*:PROPERTIES:%s*$") and clone[j + 1] and clone[j + 1]:match("^%s*:END:%s*$") then
        table.remove(clone, j + 1)
        table.remove(clone, j)
      end
    end
    vim.list_extend(out, clone)
  end
  set_lines(bufnr, hl.end_line + 1, hl.end_line, out)
end

---------------------------------------------------------------------------
-- Sorting
---------------------------------------------------------------------------

local SORT_ITEMS = {
  { key = "a", label = "alphabetically", kind = "alpha" },
  { key = "n", label = "numerically", kind = "numeric" },
  { key = "t", label = "by time (first timestamp)", kind = "time" },
  { key = "s", label = "by scheduled date", kind = "scheduled" },
  { key = "d", label = "by deadline", kind = "deadline" },
  { key = "c", label = "by creation time", kind = "created" },
  { key = "p", label = "by priority", kind = "priority" },
  { key = "o", label = "by TODO order", kind = "todo" },
  { key = "r", label = "by property", kind = "property" },
  { key = "k", label = "by clocking time", kind = "clock", only = "entries" },
  { key = "x", label = "by checkbox status", kind = "checkbox", only = "items" },
}

local function plain(s)
  s = s:gsub("%[%[([^%]]-)%]%[([^%]]-)%]%]", "%2"):gsub("%[%[([^%]]-)%]%]", "%1")
  return vim.trim(s):lower()
end

local function first_ts(text, active_only)
  for _, it in ipairs(date.parse_all(text)) do
    if not active_only or it.date.active then
      return it.date:minutes()
    end
  end
end

--- Key extractor for headlines.
local function headline_key(kind, prop)
  return function(h)
    if kind == "alpha" then
      return plain(h.title)
    elseif kind == "numeric" then
      return tonumber(h.title:match("^%s*(%-?%d+%.?%d*)"))
    elseif kind == "time" then
      local cands = {}
      if h.planning.deadline then
        cands[#cands + 1] = h.planning.deadline:minutes()
      end
      if h.planning.scheduled then
        cands[#cands + 1] = h.planning.scheduled:minutes()
      end
      if h.timestamps[1] then
        cands[#cands + 1] = h.timestamps[1].date:minutes()
      end
      table.sort(cands)
      return cands[1]
    elseif kind == "scheduled" then
      return h.planning.scheduled and h.planning.scheduled:minutes() or nil
    elseif kind == "deadline" then
      return h.planning.deadline and h.planning.deadline:minutes() or nil
    elseif kind == "created" then
      local c = h.properties.CREATED and date.parse(h.properties.CREATED)
      if c then
        return c:minutes()
      end
      local body = h:body_lines()
      for _, l in ipairs(body) do
        local m = first_ts(l, false)
        if m then
          return m
        end
      end
      return nil
    elseif kind == "priority" then
      return require("org.priority").value(h)
    elseif kind == "todo" then
      if not h.todo then
        return nil
      end
      local kw = h.file.settings.todo:get(h.todo)
      return kw and kw.index or nil
    elseif kind == "property" then
      local v = h:get_property(prop)
      if v == nil then
        return nil
      end
      return tonumber(v) or v:lower()
    elseif kind == "clock" then
      return h:clocked_minutes(nil, nil, true)
    end
  end
end

--- Key extractor for list items.
local function item_key(kind, _)
  return function(it, lines)
    local text = it.tag or it.text or ""
    if kind == "alpha" then
      return plain(text)
    elseif kind == "numeric" then
      return tonumber(text:match("^%s*(%-?%d+%.?%d*)"))
    elseif kind == "time" or kind == "scheduled" or kind == "deadline" or kind == "created" then
      return first_ts(table.concat(lines, " "), false)
    elseif kind == "todo" or kind == "checkbox" then
      -- checked items last
      return it.checkbox == "X" and 2 or it.checkbox == "-" and 1 or 0
    end
    return plain(text)
  end
end

local function mixed_compare(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then
    return ta == "number"
  end
  return a < b
end

function M.sort()
  local bufnr = buf()
  local lnum = cursor()[1]
  local line = vim.api.nvim_get_current_line()
  local lists = require("org.lists")
  local on_item = not parser.headline_level(line) and lists.item_at(bufnr, lnum)
  local items = {}
  for _, it in ipairs(SORT_ITEMS) do
    if not it.only or it.only == (on_item and "items" or "entries") then
      items[#items + 1] = { key = it.key, label = it.label, value = { kind = it.kind, reverse = false } }
      items[#items + 1] =
        { key = it.key:upper(), label = it.label .. " (reverse)", value = { kind = it.kind, reverse = true } }
    end
  end
  local choice = require("org.ui").menu({ title = on_item and "Sort list" or "Sort entries", items = items })
  if not choice then
    return
  end
  local prop
  if choice.kind == "property" then
    prop = utils.input({ prompt = "Property: " })
    if not prop or vim.trim(prop) == "" then
      return
    end
    prop = vim.trim(prop)
  end
  if on_item then
    lists.sort_items(bufnr, lnum, item_key(choice.kind, prop), choice.reverse)
    return
  end
  local hl, file = current_headline()
  local children = hl and hl.children or file.children
  if #children < 2 then
    utils.notify("Nothing to sort")
    return
  end
  local keyfn = headline_key(choice.kind, prop)
  local blocks = {}
  for i, c in ipairs(children) do
    local lines = get_lines(bufnr, c.line, c.end_line)
    -- make sure each block ends with the same blank-line convention
    blocks[#blocks + 1] = { idx = i, key = keyfn(c), lines = lines }
  end
  -- normalize trailing blank lines: if any block ends in blanks, keep the
  -- last block's trailing state at the end
  local last_trailing = {}
  local lb = blocks[#blocks].lines
  while #lb > 1 and is_blank(lb[#lb]) do
    table.insert(last_trailing, 1, table.remove(lb))
  end
  local sep_blank = is_blank(blocks[1].lines[#blocks[1].lines])
  if sep_blank and not is_blank(lb[#lb]) then
    lb[#lb + 1] = ""
    table.remove(last_trailing)
  end
  table.sort(blocks, function(a, b)
    if a.key == nil and b.key == nil then
      return a.idx < b.idx
    elseif a.key == nil then
      return false
    elseif b.key == nil then
      return true
    elseif a.key == b.key then
      return a.idx < b.idx
    end
    if choice.reverse then
      return mixed_compare(b.key, a.key)
    end
    return mixed_compare(a.key, b.key)
  end)
  local out = {}
  for i, b in ipairs(blocks) do
    local lines = b.lines
    if i == #blocks and sep_blank then
      while #lines > 1 and is_blank(lines[#lines]) do
        table.remove(lines)
      end
    end
    vim.list_extend(out, lines)
  end
  vim.list_extend(out, last_trailing)
  set_lines(bufnr, children[1].line, children[#children].end_line, out)
end

---------------------------------------------------------------------------
-- Narrowing
---------------------------------------------------------------------------

local function narrow(window)
  local bufnr = buf()
  local hl = current_headline()
  if not hl then
    utils.warn("Not in a subtree")
    return
  end
  return require("org.special").open({
    source_buf = bufnr,
    start_line = hl.line,
    end_line = hl.end_line,
    lines = get_lines(bufnr, hl.line, hl.end_line),
    filetype = "org",
    name = "narrow " .. hl:plain_title(),
    window = window,
  })
end

function M.narrow_subtree()
  narrow()
end

--- Edit the current subtree in a split window (org-tree-to-indirect-buffer).
--- Uses `win_split_mode` when it is a split / tab, otherwise a horizontal
--- split. The buffer is an edit buffer like `narrow_subtree`: `:w` or the
--- save mapping writes it back.
function M.tree_to_indirect_buffer()
  local mode = config.opts.win_split_mode
  if mode ~= "split" and mode ~= "vsplit" and mode ~= "tab" then
    mode = "split"
  end
  return narrow(mode)
end

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

--- org-toggle-heading: headline <-> text/list item.
function M.toggle_heading()
  local bufnr = buf()
  local s, e
  if in_visual() then
    s, _, e = utils.visual_range()
    exit_visual()
  else
    s = cursor()[1]
    e = s
  end
  local file = files.get_buffer(bufnr)
  local lines = get_lines(bufnr, s, e)
  local lists = require("org.lists")
  local out = {}
  if parser.headline_level(lines[1]) then
    for i, l in ipairs(lines) do
      local stars = l:match("^%*+%s*")
      out[i] = stars and parser.headline_level(l) and l:sub(#stars + 1) or l
    end
  else
    local hl = file:headline_at(s)
    local level = hl and hl.level + 1 or 1
    local todo_cfg = file.settings.todo
    for i, l in ipairs(lines) do
      if is_blank(l) then
        out[i] = l
      else
        local item = lists.parse_item_line(l)
        local text, todo
        if item then
          text = item.text
          if item.checkbox == "X" then
            todo = todo_cfg:first_done()
          elseif item.checkbox then
            todo = todo_cfg:first_todo()
          end
        else
          text = vim.trim(l)
        end
        out[i] = heading_text(level, todo) .. text
        out[i] = out[i]:gsub("%s+$", "")
      end
    end
  end
  set_lines(bufnr, s, e, out)
end

--- Wrap the visual selection in an emphasis marker.
function M.emphasize()
  local bufnr = buf()
  local srow, scol, erow, ecol, mode = utils.visual_range()
  exit_visual()
  local ch = utils.getchar("Emphasis marker [*/_=~+]: ")
  if not ch or not ch:match("^[%*/_=~%+]$") then
    return
  end
  if mode == "V" then
    local first = get_lines(bufnr, srow, srow)[1]
    local last = get_lines(bufnr, erow, erow)[1]
    local ind = #first:match("^(%s*)")
    if srow == erow then
      set_lines(bufnr, srow, srow, { first:sub(1, ind) .. ch .. first:sub(ind + 1) .. ch })
    else
      set_lines(bufnr, erow, erow, { last .. ch })
      set_lines(bufnr, srow, srow, { first:sub(1, ind) .. ch .. first:sub(ind + 1) })
    end
    return
  end
  -- charwise: end column may point at a multibyte char start
  local last = get_lines(bufnr, erow, erow)[1]
  local ecol_end = ecol
  if last and ecol <= #last then
    local char_len = #vim.fn.strcharpart(last:sub(ecol), 0, 1)
    ecol_end = ecol + math.max(char_len, 1) - 1
  end
  vim.api.nvim_buf_set_text(bufnr, erow - 1, math.min(ecol_end, #last), erow - 1, math.min(ecol_end, #last), { ch })
  vim.api.nvim_buf_set_text(bufnr, srow - 1, scol - 1, srow - 1, scol - 1, { ch })
end

---------------------------------------------------------------------------
-- Navigation
---------------------------------------------------------------------------

local function jump(lnum)
  if not lnum then
    return
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
end

local function visible(lnum)
  local fc = vim.fn.foldclosed(lnum)
  return fc == -1 or fc == lnum
end

function M.next_heading()
  local file = files.get_buffer(0)
  local lnum = cursor()[1]
  local target
  for _ = 1, math.max(vim.v.count, 1) do
    local found
    for _, h in ipairs(file.headlines) do
      if h.line > lnum and visible(h.line) then
        found = h.line
        break
      end
    end
    if not found then
      break
    end
    target, lnum = found, found
  end
  jump(target)
end

function M.prev_heading()
  local file = files.get_buffer(0)
  local lnum = cursor()[1]
  local target
  for _ = 1, math.max(vim.v.count, 1) do
    local found
    for i = #file.headlines, 1, -1 do
      local h = file.headlines[i]
      if h.line < lnum and visible(h.line) then
        found = h.line
        break
      end
    end
    if not found then
      break
    end
    target, lnum = found, found
  end
  jump(target)
end

local function sibling_jump(dir)
  local target
  for _ = 1, math.max(vim.v.count, 1) do
    local hl = current_headline()
    if not hl then
      break
    end
    local sib = siblings(hl)[sibling_index(hl) + dir]
    if not sib then
      if not target then
        utils.warn("No " .. (dir > 0 and "next" or "previous") .. " sibling")
      end
      break
    end
    target = sib.line
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
  if target then
    jump(target)
  end
end

function M.next_sibling()
  sibling_jump(1)
end

function M.prev_sibling()
  sibling_jump(-1)
end

function M.goto_parent()
  local hl = current_headline()
  if not hl then
    return
  end
  local target = hl
  for _ = 1, math.max(vim.v.count, 1) do
    target = target.parent or target
  end
  if target == hl then
    utils.warn("Already at top level")
    return
  end
  jump(target.line)
end

--- Pick a headline of the current buffer and jump to it.
function M.goto_heading()
  local file = files.get_buffer(0)
  if #file.headlines == 0 then
    utils.warn("No headlines in buffer")
    return
  end
  local choice = utils.select(file.headlines, {
    prompt = "Go to heading",
    format_item = function(h)
      local path = h:outline_path()
      path[#path + 1] = h:plain_title()
      local prefix = h.todo and (h.todo .. " ") or ""
      return string.rep("*", h.level) .. " " .. prefix .. table.concat(path, " / ")
    end,
  })
  if choice then
    jump(choice.line)
    vim.cmd("normal! zv")
  end
end

---------------------------------------------------------------------------
-- Text objects
---------------------------------------------------------------------------

local function select_lines(s, e)
  if in_visual() then
    vim.cmd("normal! \27")
  end
  vim.api.nvim_win_set_cursor(0, { s, 0 })
  vim.cmd("normal! V")
  vim.api.nvim_win_set_cursor(0, { e, 0 })
end

--- Select the current headline's section. `inner` excludes the headline.
function M.select_heading(inner)
  local hl = current_headline()
  if not hl then
    return
  end
  if inner then
    if hl.body_end <= hl.line then
      return
    end
    select_lines(hl.line + 1, hl.body_end)
  else
    select_lines(hl.line, hl.body_end)
  end
end

--- Visually select the current subtree, linewise (org-mark-subtree). A
--- count selects that many sibling subtrees; in visual mode the selection
--- is extended to the next sibling subtree.
function M.mark_subtree()
  local file = files.get_buffer(0)
  local start, stop
  if in_visual() then
    local srow, _, erow = utils.visual_range()
    local hl = file:headline_at(srow)
    if not hl then
      return false
    end
    local sibs = siblings(hl)
    local last
    for i = sibling_index(hl), #sibs do
      last = sibs[i]
      if sibs[i].end_line > erow then
        break
      end
    end
    start, stop = hl.line, last.end_line
  else
    local hl = file:headline_at(cursor()[1])
    if not hl then
      return false
    end
    local sibs = siblings(hl)
    local idx = sibling_index(hl)
    local last = sibs[math.min(idx + math.max(vim.v.count, 1) - 1, #sibs)] or hl
    start, stop = hl.line, last.end_line
  end
  local fc = vim.fn.foldclosed(start)
  if fc ~= -1 and fc ~= start then
    -- inside a closed ancestor: linewise Visual would grab the whole fold
    vim.api.nvim_win_set_cursor(0, { start, 0 })
    vim.cmd("normal! zv")
  end
  select_lines(start, stop)
end

--- Select the current subtree. `inner` excludes the headline.
function M.select_subtree(inner)
  local hl = current_headline()
  if not hl then
    return
  end
  if inner then
    if hl.end_line <= hl.line then
      return
    end
    select_lines(hl.line + 1, hl.end_line)
  else
    select_lines(hl.line, hl.end_line)
  end
end

return M

---@mod org.structure.heading Inserting and editing headings
---
--- M-RET and friends (org-insert-heading), the headline editor and
--- the odd/even level conversions.
---
--- Part of org.structure, which loads it.

local config = require("org.config")
local edit = require("org.edit")
local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")
local shared = require("org.structure.shared")

local M = require("org.structure")

local buf = shared.buf
local cursor = shared.cursor
local current_headline = shared.current_headline
local get_lines = shared.get_lines
local relevel = shared.relevel
local set_lines = shared.set_lines
local start_insert = shared.start_insert

---------------------------------------------------------------------------
-- Inserting headings (a port of org-insert-heading)
---------------------------------------------------------------------------

local textbuf = require("org.textbuf")

local function heading_text(level, todo)
  local s = string.rep("*", level) .. " "
  if todo then
    s = s .. todo .. " "
  end
  return s
end

--- Headline level of the line containing `pos` in textbuf `tb`, or nil.
local function tb_level(tb, pos)
  return parser.headline_level(tb:line(pos))
end

--- Like tb_level, but nil for inline tasks: the headlines that searches
--- for a heading find (org-with-limited-levels).
local function tb_outline_level(tb, pos)
  return parser.outline_level(tb:line(pos))
end

--- Move to the beginning of the headline at or above point
--- (org-back-to-heading). Returns false before the first headline.
local function tb_back_to_heading(tb)
  local p = tb:line_beg()
  local here = p
  while true do
    -- org-at-heading-p on the line itself, then limited levels above
    if (p == here and tb_level(tb, p)) or tb_outline_level(tb, p) then
      tb:goto_char(p)
      return true
    end
    if p == 1 then
      return false
    end
    p = tb:line_beg(p - 1)
  end
end

--- outline-next-heading: move to the next headline, or to the end of the
--- buffer. Returns true when one was found.
local function tb_next_heading(tb)
  local p = tb:line_beg()
  while true do
    local nl = tb.text:find("\n", p, true)
    if not nl or nl + 1 > #tb.text then
      tb:goto_char(tb:point_max())
      return false
    end
    p = nl + 1
    if tb_outline_level(tb, p) then
      tb:goto_char(p)
      return true
    end
  end
end

--- Level of the entry containing point (org-current-level).
local function tb_current_level(tb)
  local save = tb.point
  local ok = tb_back_to_heading(tb)
  local lvl = ok and tb_level(tb) or nil
  tb:goto_char(save)
  return lvl
end

--- org-up-heading-safe from a headline start.
local function tb_up_heading(tb)
  local lvl = tb_level(tb)
  local p = tb:line_beg()
  while p > 1 do
    p = tb:line_beg(p - 1)
    local l = tb_outline_level(tb, p)
    if l and l < lvl then
      tb:goto_char(p)
      return true
    end
  end
  return false
end

--- org-end-of-subtree with TO-HEADING: the start of the next headline of
--- the same or a higher level, or the end of the buffer.
local function tb_end_of_subtree(tb)
  local lvl = tb_level(tb)
  local p = tb:line_beg()
  while true do
    local nl = tb.text:find("\n", p, true)
    if not nl or nl + 1 > #tb.text then
      tb:goto_char(tb:point_max())
      return
    end
    p = nl + 1
    local l = tb_outline_level(tb, p)
    if l and l <= lvl then
      tb:goto_char(p)
      return
    end
  end
end

--- org-N-empty-lines-before-current: exactly `n` empty lines above the
--- line at point.
local function tb_n_empty_lines_before(tb, n)
  local _, col = tb:rowcol()
  tb:goto_char(tb:line_beg())
  if not tb:bobp() then
    local bol = tb.point
    tb:skip_backward(" \t\r\n")
    local start = tb:line_end()
    tb:goto_char(bol)
    tb:delete(start, tb:line_beg() - 1)
  end
  tb:insert(string.rep("\n", n))
  tb:goto_char(math.min(tb.point + col, tb:line_end()))
end

--- org--blank-before-heading-p for `blank_before_new_entry.heading`.
local function heading_blank_p(tb, parent)
  local b = config.opts.blank_before_new_entry
  local v
  if type(b) == "table" then
    v = b.heading
  else
    v = b
  end
  if v ~= "auto" then
    return v == true
  end
  local save = tb.point
  local res = false
  local before_first = tb_current_level(tb) == nil
  if not (before_first and not tb_next_heading(tb)) then
    tb_back_to_heading(tb)
    if parent then
      tb_up_heading(tb)
    end
    if not tb:bobp() then
      res = tb:line_empty_p(-1)
    elseif tb_next_heading(tb) then
      res = tb:line_empty_p(-1)
    end
  end
  tb:goto_char(save)
  return res
end
M._heading_blank_p = heading_blank_p

--- Emacs org-M-RET-may-split-line for `context` ("headline", "item").
function M.may_split_line(context)
  local v = config.opts.meta_return_split_line
  if type(v) == "table" then
    if v[context] ~= nil then
      return v[context]
    end
    return v.default ~= false
  end
  return v ~= false
end

--- Title range of a headline line (match group 4 of
--- org-complex-heading-regexp): 1-based first column and the column after
--- its last character.
local function title_range(line, todo_cfg)
  local stars = line:match("^(%*+) ")
  if not stars then
    return nil
  end
  local s = #stars + 1
  while line:sub(s, s) == " " do
    s = s + 1
  end
  local word = line:match("^(%S+)", s)
  if word and todo_cfg:is_keyword(word) and (line:sub(s + #word, s + #word) == " " or s + #word > #line) then
    s = s + #word
    while line:sub(s, s) == " " do
      s = s + 1
    end
  end
  if line:match("^%[#%w%]", s) and (line:sub(s + 4, s + 4) == " " or s + 4 > #line) then
    s = s + 4
    while line:sub(s, s) == " " do
      s = s + 1
    end
  end
  local e
  local tags_s = line:find("[ \t]+:[%w_@#%%:\128-\255]+:[ \t]*$")
  -- with no title, the tags follow the keyword's separating space
  if tags_s and tags_s >= s - 1 then
    e = tags_s
  else
    e = line:find("[ \t]*$")
  end
  if e <= s then
    return nil
  end
  return s, e
end

--- Insert a new headline (org-insert-heading).
---
--- opts.arg: nil, 4 (C-u: after the subtree, like `respect_content`) or
--- 16 (C-u C-u: at the end of the parent's subtree). opts.pos: the Emacs
--- point as { row, col0 } (default: the cursor). opts.split: whether the
--- line may be split at point (default `meta_return_split_line`).
--- opts.invisible: point is hidden in a fold (insert after the subtree).
---@param opts? { arg?: integer, respect_content?: boolean, pos?: integer[], split?: boolean, level?: integer, invisible?: boolean }
function M.insert_heading_at_point(opts)
  opts = opts or {}
  local bufnr = buf()
  local tb = textbuf.from_buffer(bufnr, opts.pos)
  -- parsed only to split a headline (its TODO keywords)
  local function todo_cfg()
    return files.get_buffer(bufnr).settings.todo
  end
  local arg = opts.arg
  local blank = heading_blank_p(tb, arg == 16)
  local current_level = tb_current_level(tb)
  local stars = string.rep("*", opts.level or current_level or 1)
  local split = opts.split
  if split == nil then
    split = M.may_split_line("headline")
  end
  local function maybe_add_blank_after()
    local save = tb.point
    tb:goto_char(tb:line_end())
    if not tb:eobp() then
      tb:goto_char(tb.point + 1)
      if blank and tb_level(tb) then
        tb:insert("\n")
      end
    end
    tb:goto_char(save)
  end
  local function prev_line_empty()
    return tb:line_empty_p(-1)
  end
  local respect = opts.respect_content or config.opts.insert_heading_respect_content
  if respect or arg == 4 or arg == 16 or opts.invisible then
    if not current_level then
      tb_next_heading(tb)
    else
      tb_back_to_heading(tb)
      if arg == 16 then
        tb_up_heading(tb)
      end
      tb_end_of_subtree(tb)
    end
    if not tb:bolp() then
      tb:insert("\n")
    end
    if blank and tb.point > 1 then
      local save = tb.point
      tb:goto_char(tb.point - 1)
      local before_first = tb_current_level(tb) == nil
      tb:goto_char(save)
      if before_first then
        tb:insert("\n")
        tb:goto_char(tb.point - 1)
      end
    end
    if not current_level and not tb:eobp() and not tb:bobp() then
      if tb:bolp() and tb_level(tb) then
        tb:insert("\n")
      end
      tb:goto_char(tb.point - 1)
    end
    if not (blank and prev_line_empty()) then
      tb_n_empty_lines_before(tb, blank and 1 or 0)
    end
    tb:insert(stars .. " \n")
    tb:goto_char(tb.point - 1)
    maybe_add_blank_after()
  elseif tb_level(tb) then
    if tb:bolp() then
      if blank then
        local save = tb.point
        tb:insert("\n")
        tb:goto_char(save)
      end
      local save = tb.point
      tb:insert(stars .. " \n")
      tb:goto_char(save)
      if not (blank and prev_line_empty()) then
        tb_n_empty_lines_before(tb, blank and 1 or 0)
      end
      tb:goto_char(tb:line_end())
    else
      local bol = tb:line_beg()
      local ts, te = title_range(tb:line(), todo_cfg())
      local col = tb.point - bol + 1
      if split and ts and col >= ts and col <= te then
        -- move the rest of the title to the new headline, keep the tags
        local moved = tb:delete(tb.point, bol + te - 1)
        if tb.text:sub(tb.point, tb:line_end() - 1):match("^[ \t]*$") then
          tb:delete(tb.point, tb:line_end())
        else
          local new = edit.auto_align_tags() and edit.align_tags_line(tb:line(), todo_cfg()) or tb:line()
          tb.text = tb.text:sub(1, bol - 1) .. new .. tb.text:sub(tb:line_end())
        end
        tb:goto_char(tb:line_end(bol))
        if blank then
          tb:insert("\n")
        end
        tb:insert("\n" .. stars .. " ")
        maybe_add_blank_after()
        if moved:match("%S") then
          tb:insert(moved)
        end
      else
        tb:goto_char(tb:line_end())
        if blank then
          tb:insert("\n")
        end
        tb:insert("\n" .. stars .. " ")
        maybe_add_blank_after()
      end
    end
  elseif tb:bolp() then
    tb:insert(stars .. " ")
    if not (blank and prev_line_empty()) then
      tb_n_empty_lines_before(tb, blank and 1 or 0)
    end
    maybe_add_blank_after()
  else
    if not split then
      tb:goto_char(tb:line_end())
    end
    tb:insert("\n" .. stars .. " ")
    if not (blank and prev_line_empty()) then
      tb_n_empty_lines_before(tb, blank and 1 or 0)
    end
    maybe_add_blank_after()
  end
  tb:apply()
  -- org-insert-heading-hook
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "OrgInsertHeading",
    data = { bufnr = bufnr, lnum = cursor()[1] },
    modeline = false,
  })
end

--- The TODO keyword of a new TODO heading (org-insert-todo-heading): the
--- one of the previous sibling, or the first keyword when that has none,
--- is done, or with C-u (`arg` 4).
local function todo_for_new_heading(bufnr, lnum, arg)
  local file = files.get_buffer(bufnr)
  local todo_cfg = file.settings.todo
  local first = todo_cfg.keywords[1] and todo_cfg.keywords[1].name
  if arg == 4 then
    return first
  end
  local hl = file:headline_on(lnum)
  local prev
  if hl then
    local sibs = hl.parent and hl.parent.children or file.children
    for i, s in ipairs(sibs) do
      if s.line == hl.line then
        prev = sibs[i - 1]
      end
    end
  end
  if not prev or not prev.todo or todo_cfg:is_done(prev.todo) then
    return first
  end
  return prev.todo
end

--- Insert `kw` after the stars of the headline at the cursor, leaving the
--- cursor after it.
local function add_todo_keyword(bufnr, kw)
  local row = cursor()[1]
  local line = get_lines(bufnr, row, row)[1]
  local stars = line:match("^%*+ ")
  if not kw or not stars then
    return
  end
  set_lines(bufnr, row, row, { stars .. kw .. " " .. line:sub(#stars + 1) })
  vim.api.nvim_win_set_cursor(0, { row, #stars + #kw + 1 })
end

--- M-RET on or under a headline (org-insert-heading), or M-S-RET with
--- `todo` (org-insert-todo-heading). `arg` is the C-u prefix (4 or 16).
---@param opts? { todo?: boolean, arg?: integer, respect_content?: boolean, pos?: integer[], split?: boolean }
function M.meta_return_heading(opts)
  opts = opts or {}
  local bufnr = buf()
  local pos = opts.pos or cursor()
  -- point hidden in a closed fold: Emacs inserts after the subtree
  local fc = vim.fn.foldclosed(pos[1])
  local invisible = fc ~= -1 and (pos[1] ~= fc or pos[2] > 0)
  local arg = opts.arg
  if opts.todo and arg == 4 then
    arg = nil -- C-u M-S-RET only forces the first keyword
  end
  M.insert_heading_at_point({
    arg = arg,
    respect_content = opts.respect_content,
    pos = pos,
    split = opts.split,
    invisible = invisible,
  })
  if opts.todo then
    local row = cursor()[1]
    local todo = require("org.todo")
    local kw = todo.default_state(todo_for_new_heading(bufnr, row, opts.arg), nil)
    if config.opts.treat_insert_todo_heading_as_state_change and kw ~= "" and kw then
      -- org-treat-insert-todo-heading-as-state-change: a real state change,
      -- logged like C-c C-t
      local line = get_lines(bufnr, row, row)[1]
      local stars = line and line:match("^%*+ ")
      if stars and todo.change_state({ bufnr = bufnr, lnum = row }, kw) then
        local now = get_lines(bufnr, row, row)[1]
        if now == stars .. kw then
          set_lines(bufnr, row, row, { now .. " " })
        end
        vim.api.nvim_win_set_cursor(0, { row, #stars + #kw + 1 })
      end
    else
      add_todo_keyword(bufnr, kw ~= "" and kw or nil)
    end
    require("org.lists").update_statistics_for(bufnr, cursor()[1])
    local hl = files.get_buffer(bufnr):headline_on(cursor()[1])
    if hl then
      todo.run_statistics_hooks(bufnr, hl)
    end
  end
end

--- C-RET (org-insert-heading-respect-content).
function M.insert_heading()
  M.meta_return_heading({ respect_content = true })
  start_insert()
end

--- C-S-RET (org-insert-todo-heading-respect-content).
function M.insert_todo_heading()
  local c = vim.v.count
  M.meta_return_heading({ respect_content = true, todo = true, arg = c > 0 and (c >= 16 and 16 or 4) or nil })
  start_insert()
end

--- org-insert-subheading: insert a heading like M-RET (at the end of the
--- line, without splitting it) and demote it; on a list item, insert an
--- item and indent it.
function M.insert_subheading()
  local lnum = cursor()[1]
  local lists = require("org.lists")
  local line = vim.api.nvim_get_current_line()
  if not parser.headline_level(line) and lists.item_at(0, lnum) then
    lists.new_item({ pos = { lnum, #line }, split = false })
    lists.indent_item(1, false)
  else
    M.meta_return_heading({ arg = vim.v.count > 0 and vim.v.count or nil, pos = { lnum, #line }, split = false })
    local row = cursor()[1]
    local l = get_lines(0, row, row)[1]
    local add = string.rep("*", M.level_increment())
    set_lines(0, row, row, { add .. l })
    vim.api.nvim_win_set_cursor(0, { row, #l + #add })
  end
  start_insert()
end

--- org-insert-todo-subheading: insert a TODO heading like M-S-RET (at the
--- end of the line) and demote it; on a list item, insert a checkbox item
--- and indent it. A count is the C-u prefix of org-insert-todo-heading.
function M.insert_todo_subheading()
  local lnum = cursor()[1]
  local lists = require("org.lists")
  local line = vim.api.nvim_get_current_line()
  local c = vim.v.count
  if not parser.headline_level(line) and lists.item_at(0, lnum) then
    lists.new_item({ checkbox = true, pos = { lnum, #line }, split = false })
    lists.indent_item(1, false)
  else
    M.meta_return_heading({
      todo = true,
      arg = c > 0 and (c >= 16 and 16 or 4) or nil,
      pos = { lnum, #line },
      split = false,
    })
    local row = cursor()[1]
    local l = get_lines(0, row, row)[1]
    local add = string.rep("*", M.level_increment())
    set_lines(0, row, row, { add .. l })
    vim.api.nvim_win_set_cursor(0, { row, #l + #add })
  end
  start_insert()
end

--- org-edit-headline: edit the title of the current headline (keeping its
--- TODO keyword, priority and tags) in a prompt, or set it to `heading`.
---@param heading? string
function M.edit_headline(heading)
  local bufnr = buf()
  local hl, file = current_headline()
  if not hl then
    utils.warn("Before first headline")
    return
  end
  local todo_cfg = file.settings.todo
  local line = get_lines(bufnr, hl.line, hl.line)[1]
  local ts, te = title_range(line, todo_cfg)
  local old = ts and line:sub(ts, te - 1) or nil
  local new = heading
  if new == nil then
    new = utils.input({ prompt = "Edit: ", default = old or "" })
    if new == nil then
      return
    end
  end
  new = vim.trim(new)
  if new == old or (old == nil and new == "") then
    return
  end
  if old then
    line = line:sub(1, ts - 1) .. new .. line:sub(te)
  else
    -- after the stars, TODO keyword and priority, before the tags
    local tags_s = line:find("[ \t]+:[%w_@#%%:\128-\255]+:[ \t]*$")
    local before = (tags_s and line:sub(1, tags_s - 1) or line):gsub("[ \t]+$", "")
    line = before .. " " .. new .. (tags_s and line:sub(tags_s) or "")
  end
  if edit.auto_align_tags() then
    line = edit.align_tags_line(line, todo_cfg)
  end
  line = line:gsub("[ \t]+$", "")
  set_lines(bufnr, hl.line, hl.line, { line })
end

--- Relevel every headline of the buffer to `new_level(level)`, like
--- org-demote / org-promote on each of them.
local function relevel_buffer(new_level)
  local bufnr = buf()
  local file = files.get_buffer(bufnr)
  local todo_cfg = file.settings.todo
  local pos = cursor()
  for i = #file.headlines, 1, -1 do
    local hl = file.headlines[i]
    local delta = new_level(hl.level) - hl.level
    if delta ~= 0 then
      local lines = get_lines(bufnr, hl.line, hl.body_end)
      local new = relevel(lines, delta, todo_cfg)
      for j = 2, #new do
        if parser.headline_level(lines[j]) then
          new[j] = lines[j]
        end
      end
      set_lines(bufnr, hl.line, hl.body_end, new)
    end
  end
  local l = get_lines(bufnr, pos[1], pos[1])[1] or ""
  vim.api.nvim_win_set_cursor(0, { pos[1], math.min(pos[2], math.max(#l - 1, 0)) })
end

--- org-convert-to-odd-levels: level 2 becomes 3, 3 becomes 5, ... (after
--- confirmation).
function M.convert_to_odd_levels()
  if not utils.confirm("Are you sure you want to globally change levels to odd? ") then
    return
  end
  relevel_buffer(function(level)
    return 2 * level - 1
  end)
end

--- org-convert-to-oddeven-levels: level 3 becomes 2, 5 becomes 3, ...
--- Refused when the file has a headline of even level.
function M.convert_to_oddeven_levels()
  local file = files.get_buffer(buf())
  for _, hl in ipairs(file.headlines) do
    if hl.level % 2 == 0 then
      vim.api.nvim_win_set_cursor(0, { hl.line, 0 })
      pcall(vim.cmd, "normal! zv")
      utils.error("Not all levels are odd in this file.  Conversion not possible")
      return
    end
  end
  if not utils.confirm("Are you sure you want to globally change levels to odd-even? ") then
    return
  end
  relevel_buffer(function(level)
    return (level + 1) / 2
  end)
  -- like Emacs, which searched for even levels from the start
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

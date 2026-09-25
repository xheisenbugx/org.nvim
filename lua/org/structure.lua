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
      -- like org-promote / org-demote: change the stars, realign the tags
      out[i] = string.rep("*", math.max(1, p.level + delta)) .. l:sub(#l:match("^%*+") + 1)
      if #p.tags > 0 then
        local s = out[i]:find("[ \t]+:[^%s]+:[ \t]*$")
        if s then
          out[i] = edit.with_tags(out[i]:sub(1, s - 1), p.tags)
        end
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

--- Move to the beginning of the headline at or above point
--- (org-back-to-heading). Returns false before the first headline.
local function tb_back_to_heading(tb)
  local p = tb:line_beg()
  while true do
    if tb_level(tb, p) then
      tb:goto(p)
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
      tb:goto(tb:point_max())
      return false
    end
    p = nl + 1
    if tb_level(tb, p) then
      tb:goto(p)
      return true
    end
  end
end

--- Level of the entry containing point (org-current-level).
local function tb_current_level(tb)
  local save = tb.point
  local ok = tb_back_to_heading(tb)
  local lvl = ok and tb_level(tb) or nil
  tb:goto(save)
  return lvl
end

--- org-up-heading-safe from a headline start.
local function tb_up_heading(tb)
  local lvl = tb_level(tb)
  local p = tb:line_beg()
  while p > 1 do
    p = tb:line_beg(p - 1)
    local l = tb_level(tb, p)
    if l and l < lvl then
      tb:goto(p)
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
      tb:goto(tb:point_max())
      return
    end
    p = nl + 1
    local l = tb_level(tb, p)
    if l and l <= lvl then
      tb:goto(p)
      return
    end
  end
end

--- org-N-empty-lines-before-current: exactly `n` empty lines above the
--- line at point.
local function tb_n_empty_lines_before(tb, n)
  local _, col = tb:rowcol()
  tb:goto(tb:line_beg())
  if not tb:bobp() then
    local bol = tb.point
    tb:skip_backward(" \t\r\n")
    local start = tb:line_end()
    tb:goto(bol)
    tb:delete(start, tb:line_beg() - 1)
  end
  tb:insert(string.rep("\n", n))
  tb:goto(math.min(tb.point + col, tb:line_end()))
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
  tb:goto(save)
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
  local tags_s = line:find("[ \t]+:[%w_@#%%:]+:[ \t]*$")
  if tags_s and tags_s >= s then
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
  local file = files.get_buffer(bufnr)
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
    tb:goto(tb:line_end())
    if not tb:eobp() then
      tb:goto(tb.point + 1)
      if blank and tb_level(tb) then
        tb:insert("\n")
      end
    end
    tb:goto(save)
  end
  local function prev_line_empty()
    return tb:line_empty_p(-1)
  end
  if opts.respect_content or arg == 4 or arg == 16 or opts.invisible then
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
      tb:goto(tb.point - 1)
      local before_first = tb_current_level(tb) == nil
      tb:goto(save)
      if before_first then
        tb:insert("\n")
        tb:goto(tb.point - 1)
      end
    end
    if not current_level and not tb:eobp() and not tb:bobp() then
      if tb:bolp() and tb_level(tb) then
        tb:insert("\n")
      end
      tb:goto(tb.point - 1)
    end
    if not (blank and prev_line_empty()) then
      tb_n_empty_lines_before(tb, blank and 1 or 0)
    end
    tb:insert(stars .. " \n")
    tb:goto(tb.point - 1)
    maybe_add_blank_after()
  elseif tb_level(tb) then
    if tb:bolp() then
      if blank then
        local save = tb.point
        tb:insert("\n")
        tb:goto(save)
      end
      local save = tb.point
      tb:insert(stars .. " \n")
      tb:goto(save)
      if not (blank and prev_line_empty()) then
        tb_n_empty_lines_before(tb, blank and 1 or 0)
      end
      tb:goto(tb:line_end())
    else
      local bol = tb:line_beg()
      local ts, te = title_range(tb:line(), file.settings.todo)
      local col = tb.point - bol + 1
      if split and ts and col >= ts and col <= te then
        -- move the rest of the title to the new headline, keep the tags
        local moved = tb:delete(tb.point, bol + te - 1)
        if tb.text:sub(tb.point, tb:line_end() - 1):match("^[ \t]*$") then
          tb:delete(tb.point, tb:line_end())
        else
          local new = edit.align_tags_line(tb:line(), file.settings.todo)
          tb.text = tb.text:sub(1, bol - 1) .. new .. tb.text:sub(tb:line_end())
        end
        tb:goto(tb:line_end(bol))
        if blank then
          tb:insert("\n")
        end
        tb:insert("\n" .. stars .. " ")
        maybe_add_blank_after()
        if moved:match("%S") then
          tb:insert(moved)
        end
      else
        tb:goto(tb:line_end())
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
      tb:goto(tb:line_end())
    end
    tb:insert("\n" .. stars .. " ")
    if not (blank and prev_line_empty()) then
      tb_n_empty_lines_before(tb, blank and 1 or 0)
    end
    maybe_add_blank_after()
  end
  tb:apply()
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
    add_todo_keyword(bufnr, todo_for_new_heading(bufnr, row, opts.arg))
    require("org.lists").update_statistics_for(bufnr, cursor()[1])
  end
end

local function start_insert()
  if vim.fn.mode():sub(1, 1) == "i" then
    return
  end
  if cursor()[2] >= #vim.api.nvim_get_current_line() then
    vim.cmd("startinsert!")
  else
    vim.cmd("startinsert")
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
    set_lines(0, row, row, { "*" .. l })
    vim.api.nvim_win_set_cursor(0, { row, #l + 1 })
  end
  start_insert()
end

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
    tb:goto(tb:line_beg())
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
  tb:goto(save)
  if extended then
    tb:goto(tb:line_end())
  else
    tb:forward_line(1)
    tb:skip_forward(" \t")
  end
  tb:apply()
  start_insert()
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


---------------------------------------------------------------------------
-- Promote / demote
---------------------------------------------------------------------------

local function change_level(hl, file, delta, subtree)
  local bufnr = buf()
  delta = delta * M.level_increment(bufnr)
  if hl.level + delta < 1 then
    utils.warn("Cannot promote to level 0.  UNDO to recover if necessary")
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
  delta = delta * M.level_increment(bufnr)
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
      utils.warn("Cannot promote to level 0.  UNDO to recover if necessary")
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

local function move_subtree(dir, n)
  local bufnr = buf()
  n = n or math.max(vim.v.count, 1)
  local hl = current_headline()
  if not hl then
    utils.warn("Not on a headline")
    return
  end
  local sibs = siblings(hl)
  local idx = sibling_index(hl)
  if not sibs[idx + dir * n] then
    utils.warn("Cannot move past superior level or buffer limit")
    return
  end
  local folded = vim.fn.foldclosed(hl.line) == hl.line
  local pos = cursor()
  local offset = pos[1] - hl.line
  local text = get_lines(bufnr, hl.line, hl.end_line)
  local new_start
  if dir > 0 then
    local other = sibs[idx + n]
    -- insert after the other subtree, then delete the original
    set_lines(bufnr, other.end_line + 1, other.end_line, text)
    set_lines(bufnr, hl.line, hl.end_line, {})
    new_start = other.end_line + 1 - #text
  else
    local other = sibs[idx - n]
    set_lines(bufnr, hl.line, hl.end_line, {})
    set_lines(bufnr, other.line, other.line - 1, text)
    new_start = other.line
  end
  vim.api.nvim_win_set_cursor(0, { new_start + offset, pos[2] })
  -- keep the moved subtree folded or open, like Emacs
  vim.cmd("silent! normal! zx")
  if folded then
    pcall(vim.cmd, new_start .. "foldclose")
  else
    pcall(vim.cmd, new_start .. "foldopen")
  end
end

function M.move_subtree_up()
  move_subtree(-1)
end

function M.move_subtree_down()
  move_subtree(1)
end

--- M-up / M-down with a Visual selection (org-metaup / org-metadown with
--- a region): when it starts at a headline, move the selected subtrees
--- past the previous / next sibling; otherwise move the selected lines up
--- or down one line. The selection follows.
function M.move_region(dir)
  local bufnr = buf()
  local s, _, e = utils.visual_range()
  exit_visual()
  local file = files.get_buffer(bufnr)
  local first = s
  while first < e and is_blank(get_lines(bufnr, first, first)[1]) do
    first = first + 1
  end
  local hl = file:headline_on(first)
  local n = vim.api.nvim_buf_line_count(bufnr)
  if hl then
    local level = hl.level
    for l = first + 1, e do
      local lv = parser.headline_level(get_lines(bufnr, l, l)[1])
      if lv and lv < level then
        utils.warn("Cannot move past superior level or buffer limit")
        return
      end
    end
    local sibs = siblings(hl)
    local idx = sibling_index(hl)
    if dir < 0 then
      local prev = sibs[idx - 1]
      if not prev then
        utils.warn("Cannot move past superior level or buffer limit")
        return
      end
      -- the previous sibling goes below the selected subtrees
      local last_sel = hl
      for i = idx, #sibs do
        if sibs[i].line <= e then
          last_sel = sibs[i]
        end
      end
      local text = get_lines(bufnr, prev.line, prev.end_line)
      set_lines(bufnr, last_sel.end_line + 1, last_sel.end_line, text)
      set_lines(bufnr, prev.line, prev.end_line, {})
      local size = last_sel.end_line - hl.line + 1
      s, e = prev.line, prev.line + size - 1
    else
      local last_sel = hl
      for i = idx, #sibs do
        if sibs[i].line <= e then
          last_sel = sibs[i]
        end
      end
      local nxt = sibs[sibling_index(last_sel) + 1]
      if not nxt then
        utils.warn("Cannot move past superior level or buffer limit")
        return
      end
      local text = get_lines(bufnr, nxt.line, nxt.end_line)
      set_lines(bufnr, nxt.line, nxt.end_line, {})
      set_lines(bufnr, hl.line, hl.line - 1, text)
      local size = last_sel.end_line - hl.line + 1
      s, e = hl.line + #text, hl.line + #text + size - 1
    end
  else
    if (dir < 0 and s <= 1) or (dir > 0 and e >= n) then
      utils.warn("Cannot move " .. (dir < 0 and "up" or "down"))
      return
    end
    local lines = get_lines(bufnr, s, e)
    if dir < 0 then
      local above = get_lines(bufnr, s - 1, s - 1)
      set_lines(bufnr, s - 1, e, vim.list_extend(lines, above))
      s, e = s - 1, e - 1
    else
      local below = get_lines(bufnr, e + 1, e + 1)
      set_lines(bufnr, s, e + 1, vim.list_extend(below, lines))
      s, e = s + 1, e + 1
    end
  end
  vim.api.nvim_win_set_cursor(0, { s, 0 })
  vim.cmd("normal! V")
  vim.api.nvim_win_set_cursor(0, { e, 0 })
end

---------------------------------------------------------------------------
-- Kill ring
---------------------------------------------------------------------------

--- Line not hidden by a closed fold (the first line of a fold shows).
local function line_visible(lnum)
  return require("org.fold").line_visible(lnum)
end

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

--- Whether the last copied or cut subtree was folded
--- (org-subtree-clip-folded), and its text (org-subtree-clip).
M.clip_folded = false
M.clip = nil

local function remember(lines, folded)
  table.insert(M.kill_ring, vim.deepcopy(lines))
  if #M.kill_ring > 20 then
    table.remove(M.kill_ring, 1)
  end
  M.clip = vim.deepcopy(lines)
  M.clip_folded = folded
  vim.fn.setreg('"', lines, "l")
  pcall(vim.fn.setreg, "0", lines, "l")
end

local function characters(lines)
  local n = 0
  for _, l in ipairs(lines) do
    n = n + vim.fn.strchars(l) + 1
  end
  return n
end

--- org-copy-subtree (count: that many sibling subtrees).
function M.copy_subtree()
  local hl, lines = subtree_lines()
  if not hl then
    return
  end
  remember(lines, vim.fn.foldclosed(hl.line) == hl.line)
  utils.notify(string.format("Copied: Subtree(s) with %d characters", characters(lines)))
end

--- org-cut-subtree (count: that many sibling subtrees).
function M.cut_subtree()
  local hl, lines, last = subtree_lines()
  if not hl then
    return
  end
  remember(lines, vim.fn.foldclosed(hl.line) == hl.line)
  set_lines(buf(), hl.line, last, {})
  local n = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.min(hl.line, n), 0 })
  utils.notify(string.format("Cut: Subtree(s) with %d characters", characters(lines)))
end

--- Whether `lines` form one or more subtrees: they start with a headline
--- (after blank lines) and no later headline is higher
--- (org-kill-is-subtree-p).
local function is_subtree(lines)
  local start
  for _, l in ipairs(lines or {}) do
    local lv = parser.headline_level(l)
    if not start then
      if lv then
        start = lv
      elseif l:match("%S") then
        return false
      end
    elseif lv and lv < start then
      return false
    end
  end
  return start ~= nil
end

--- Paste the last killed subtree (or a subtree in the unnamed register)
--- at the cursor, like org-paste-subtree: at the beginning of a headline
--- (column 0) before it with its level; elsewhere before the next visible
--- headline, at the deeper level of the visible headlines around. With a
--- count: 4 (C-u) after the current subtree at its level, 16 (C-u C-u)
--- as the first child, any other N at level N. On an otherwise empty
--- headline ("***"), the number of stars is the level (the line is
--- removed).
function M.paste_subtree()
  local bufnr = buf()
  local reg = vim.fn.getreg('"', 1, true)
  local lines
  if type(reg) == "table" and is_subtree(reg) then
    lines = reg
  else
    lines = M.kill_ring[#M.kill_ring]
  end
  if not is_subtree(lines) then
    utils.warn("The kill is not a (set of) tree(s). Use p to yank anyway")
    return
  end
  lines = vim.deepcopy(lines)
  local file = files.get_buffer(bufnr)
  local count = vim.v.count
  local arg = (count == 4 or count == 16) and count or nil
  local numeric = count > 0 and not arg and count or nil
  local pos = cursor()
  local lnum = pos[1]
  local line = vim.api.nvim_get_current_line()
  local old_level
  for _, l in ipairs(lines) do
    old_level = parser.headline_level(l)
    if old_level then
      break
    end
  end
  local cur_level = parser.headline_level(line)
  local level_indicator
  local force
  if (not numeric) and line:match("^%*+[ \t]*$") and pos[2] >= #line:match("^%*+") then
    level_indicator = #line:match("^%*+")
    force = level_indicator
  elseif arg == 4 then
    local hl = file:headline_at(lnum)
    force = hl and hl.level or 1
  elseif arg == 16 then
    force = nil
  elseif numeric then
    force = numeric
  elseif cur_level and pos[2] == 0 then
    force = cur_level
  end
  local function prev_visible_level()
    local l = lnum
    if not cur_level then
      l = lnum - 1
      while l >= 1 do
        local lv = parser.headline_level(get_lines(bufnr, l, l)[1])
        if lv and line_visible(l) then
          return lv
        end
        l = l - 1
      end
      return 1
    end
    return cur_level
  end
  local function next_visible_line(from)
    local total = vim.api.nvim_buf_line_count(bufnr)
    for l = from + 1, total do
      if parser.headline_level(get_lines(bufnr, l, l)[1]) and line_visible(l) then
        return l
      end
    end
  end
  local prev_level = prev_visible_level()
  local nl = next_visible_line(lnum)
  local next_level = nl and parser.headline_level(get_lines(bufnr, nl, nl)[1]) or 1
  local new_level = force or math.max(arg == 16 and prev_level + 1 or 0, prev_level, next_level)
  -- remove the level indicator line
  if level_indicator then
    set_lines(bufnr, lnum, lnum, {})
    lnum = lnum - 1
    nl = nl and nl - 1
  end
  local at
  if not level_indicator and cur_level and pos[2] == 0 and not arg then
    at = lnum
  else
    local from = lnum
    if arg == 4 then
      local hl = files.get_buffer(bufnr):headline_at(math.max(lnum, 1))
      if hl then
        from = hl.end_line
      end
    end
    local target = next_visible_line(math.max(from, 0))
    at = target or (vim.api.nvim_buf_line_count(bufnr) + 1)
  end
  local shift = new_level - old_level
  local new = shift ~= 0 and relevel(lines, shift, file.settings.todo) or lines
  set_lines(bufnr, at, at - 1, new)
  local first = at
  while first < at + #new - 1 and is_blank(get_lines(bufnr, first, first)[1]) do
    first = first + 1
  end
  vim.api.nvim_win_set_cursor(0, { first, 0 })
  if M.clip_folded and vim.deep_equal(M.clip, lines) then
    vim.cmd("silent! normal! zx")
    pcall(vim.cmd, first .. "foldclose")
  end
  utils.notify(string.format("Clipboard pasted as level %d subtree", new_level))
end

---------------------------------------------------------------------------
-- Clone with time shift
---------------------------------------------------------------------------

--- Shift all timestamps (except CLOCK lines) in `line`.
local function shift_line_timestamps(line, n, unit, strip_repeater)
  local items = date.parse_all(line)
  for i = #items, 1, -1 do
    local it = items[i]
    local d = it.date
    local nd = n ~= 0 and d:add_with_range(n, unit) or d:clone()
    if d.range_end and not nd.range_end then
      nd.range_end = d.range_end
    end
    if strip_repeater and d.active then
      nd.repeater = nil
      if nd.range_end then
        nd.range_end.repeater = nil
      end
    end
    line = line:sub(1, it.start_col - 1) .. nd:to_string() .. line:sub(it.end_col + 1)
  end
  return line
end

--- Remove drawers left empty (org-remove-empty-drawer-at).
local function remove_empty_drawers(lines)
  local i = 1
  while i < #lines do
    if lines[i]:match("^%s*:[%w_%-]+:%s*$") and not lines[i]:match("^%s*:[Ee][Nn][Dd]:") then
      local j = i + 1
      while j <= #lines and lines[j]:match("^%s*$") do
        j = j + 1
      end
      if lines[j] and lines[j]:match("^%s*:[Ee][Nn][Dd]:%s*$") then
        for _ = i, j do
          table.remove(lines, i)
        end
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return lines
end

--- Clone the subtree at the cursor N times, shifting its timestamps by a
--- given offset per clone (org-clone-subtree-with-time-shift). Clones
--- lose their CLOCK lines and get a new ID (or none with
--- `clone_delete_id`). When the subtree has a repeating timestamp, the
--- clones and the original lose the repeater and one more clone, shifted
--- past the last one, keeps it. The shift is only asked for when the
--- subtree has timestamps; a count skips it.
function M.clone_subtree()
  local bufnr = buf()
  local hl = current_headline()
  if not hl then
    utils.warn("No subtree to clone")
    return
  end
  local n = utils.input({ prompt = "Number of clones to produce: " })
  if n == nil then
    return
  end
  n = tonumber(vim.trim(n))
  if not n or n < 0 or n ~= math.floor(n) then
    utils.warn("Invalid number of replications")
    return
  end
  local src = get_lines(bufnr, hl.line, hl.end_line)
  local has_ts = false
  for _, l in ipairs(src) do
    if #date.parse_all(l) > 0 then
      has_ts = true
      break
    end
  end
  local shift = ""
  if has_ts and vim.v.count == 0 then
    shift = utils.input({ prompt = "Date shift per clone (e.g. +1w, empty to copy unchanged): " })
    if shift == nil then
      return
    end
  end
  local sn, su
  if shift:match("%S") then
    sn, su = shift:match("^%s*([+-]?%d+)([hdwmy])%s*$")
    if not sn then
      utils.warn("Invalid shift specification " .. shift)
      return
    end
    sn = tonumber(sn)
  end
  local doshift = sn ~= nil
  local has_repeater = false
  if doshift then
    for _, l in ipairs(src) do
      if l:match("<[^<>]+ [.+]?%+%d+[hdwmy][^<>]*>") then
        has_repeater = true
      end
    end
  end
  local nmin, nmax, n_no_remove = 1, n, -1
  if has_repeater then
    nmin, nmax, n_no_remove = 0, n + 1, n + 1
  end
  local out = {}
  for k = nmin, nmax do
    local clone = vim.deepcopy(src)
    if hl.properties.ID then
      for j, l in ipairs(clone) do
        if l:match("^%s*:ID:") then
          if config.opts.clone_delete_id then
            table.remove(clone, j)
          else
            local ind, sep = l:match("^(%s*:ID:)(%s+)")
            clone[j] = (ind or ":ID:") .. (sep or " ") .. require("org.id").new_id()
          end
          break
        end
      end
    end
    if k ~= 0 then
      for j = #clone, 1, -1 do
        if clone[j]:match("^%s*CLOCK:") then
          table.remove(clone, j)
        end
      end
      remove_empty_drawers(clone)
    end
    if doshift then
      for j, l in ipairs(clone) do
        if not l:match("^%s*CLOCK:") or k ~= 0 then
          clone[j] = shift_line_timestamps(l, sn * k, su, k ~= n_no_remove)
        end
      end
    end
    vim.list_extend(out, clone)
  end
  if has_repeater then
    set_lines(bufnr, hl.line, hl.end_line, out)
  else
    set_lines(bufnr, hl.end_line + 1, hl.end_line, out)
  end
  vim.api.nvim_win_set_cursor(0, { hl.line, 0 })
end

---------------------------------------------------------------------------
-- Sorting (org-sort-entries / org-sort-list)
---------------------------------------------------------------------------

local SORT_ENTRIES = {
  { key = "a", label = "alphabetically", kind = "alpha" },
  { key = "n", label = "numerically", kind = "numeric" },
  { key = "p", label = "by priority", kind = "priority" },
  { key = "r", label = "by property", kind = "property" },
  { key = "o", label = "by TODO order", kind = "todo" },
  { key = "f", label = "by function", kind = "func" },
  { key = "t", label = "by time (first timestamp)", kind = "time" },
  { key = "s", label = "by scheduled date", kind = "scheduled" },
  { key = "d", label = "by deadline", kind = "deadline" },
  { key = "c", label = "by creation time", kind = "created" },
  { key = "k", label = "by clocking time", kind = "clock" },
}

local SORT_LIST = {
  { key = "a", label = "alphabetically", kind = "alpha" },
  { key = "n", label = "numerically", kind = "numeric" },
  { key = "t", label = "by time (first timestamp)", kind = "time" },
  { key = "f", label = "by function", kind = "func" },
  { key = "x", label = "by checkbox status", kind = "checkbox" },
}

--- Text as displayed: link descriptions instead of links
--- (org-sort-remove-invisible).
local function visible_text(s)
  s = s:gsub("%[%[([^%]]-)%]%[([^%]]-)%]%]", "%2"):gsub("%[%[([^%]]-)%]%]", "%1")
  return s
end

--- Emacs `string-to-number`: the number at the start of `s`, else 0.
local function string_to_number(s)
  s = s:gsub("^%s+", "")
  local n = s:match("^[+-]?%d+%.?%d*[eE][+-]?%d+") or s:match("^[+-]?%d*%.%d+") or s:match("^[+-]?%d+")
  return tonumber(n or "") or 0
end

--- Minutes of the first timestamp of `text` (active ones first when
--- `active_first`), or nil.
local function first_ts_minutes(text, active_first)
  local items = date.parse_all(text)
  if active_first then
    for _, it in ipairs(items) do
      if it.date.active then
        return it.date:minutes()
      end
    end
  end
  return items[1] and items[1].date:minutes() or nil
end

local function now_minutes()
  local now = date.now()
  return now:minutes()
end

--- Resolve a key or compare function typed at a prompt: a name in
--- `sort_functions`, or a Lua expression returning a function.
local function read_function(prompt, allow_empty)
  local s = utils.input({ prompt = prompt })
  if s == nil then
    return nil, true
  end
  s = vim.trim(s)
  if s == "" then
    if allow_empty then
      return nil
    end
    utils.warn("Missing key extractor")
    return nil, true
  end
  local fns = config.opts.sort_functions or {}
  if type(fns[s]) == "function" then
    return fns[s]
  end
  local chunk = load("return " .. s)
  local ok, fn = pcall(chunk or function() end)
  if ok and type(fn) == "function" then
    return fn
  end
  utils.warn("Not a function: " .. s)
  return nil, true
end

--- Sort `records` ({ key, lines }) by key like Emacs `sort-subr`: stable,
--- `reverse` sorts in decreasing order keeping equal keys in order.
local function sort_records(records, less, reverse)
  for i, r in ipairs(records) do
    r.idx = i
  end
  table.sort(records, function(a, b)
    local x, y = a.key, b.key
    if reverse then
      x, y = y, x
    end
    if less(x, y) then
      return true
    elseif less(y, x) then
      return false
    end
    return a.idx < b.idx
  end)
end

local function default_less(a, b)
  if type(a) == "number" and type(b) == "number" then
    return a < b
  end
  if a == nil or b == nil then
    return a == nil and b ~= nil
  end
  if type(a) ~= type(b) then
    return type(a) == "number"
  end
  return tostring(a) < tostring(b)
end

--- Key extractor for an entry: `h` is the headline.
local function entry_key(kind, prop, with_case, keyfn)
  local case = with_case and function(s)
    return s
  end or string.lower
  return function(h, lines)
    local body = table.concat(lines, "\n", 1, (h.body_end - h.line) + 1)
    if kind == "alpha" then
      return case(visible_text(h.title))
    elseif kind == "numeric" then
      return string_to_number(visible_text(h.title))
    elseif kind == "time" then
      return first_ts_minutes(body, true) or now_minutes()
    elseif kind == "created" then
      for _, l in ipairs(vim.split(body, "\n")) do
        local ts = l:match("^%s*(%[%d%d%d%d%-%d%d%-%d%d[^%]]*%])")
        if ts then
          local d = date.parse(ts)
          if d then
            return d:minutes()
          end
        end
      end
      return now_minutes()
    elseif kind == "scheduled" then
      return h.planning.scheduled and h.planning.scheduled:minutes() or now_minutes()
    elseif kind == "deadline" then
      return h.planning.deadline and h.planning.deadline:minutes() or now_minutes()
    elseif kind == "priority" then
      local p = h.priority or h.file:priorities().default
      return p:byte(1)
    elseif kind == "todo" then
      local todo_cfg = h.file.settings.todo
      local n = #todo_cfg.keywords
      local kw = h.todo and todo_cfg:get(h.todo)
      if not kw then
        return 99
      end
      local len = n - kw.index + 1
      return kw.done and 99 + len or 99 - len
    elseif kind == "property" then
      return h:get_property(prop) or ""
    elseif kind == "clock" then
      return h:clocked_minutes(nil, nil, true) or 0
    elseif kind == "func" then
      local v = keyfn(h, lines)
      if type(v) == "string" then
        v = case(v)
      end
      return v
    end
  end
end

--- Key extractor for a list item.
local function item_key(kind, with_case, keyfn)
  local case = with_case and function(s)
    return s
  end or string.lower
  return function(it, lines)
    local first = lines[1]
    local after = first:match("^%s*[-+*0-9.)]+[ \t]+%[[- X]%][ \t]+(.*)$")
      or first:match("^%s*[-+*0-9.)]+[ \t]+(.*)$")
      or ""
    if kind == "alpha" then
      return case(visible_text(after))
    elseif kind == "numeric" then
      return string_to_number(visible_text(after))
    elseif kind == "time" then
      local timer = after:match("^([-+]?%d+:%d%d:%d%d)%s+::")
      if timer then
        local sign, h, m, s = timer:match("^([-+]?)(%d+):(%d%d):(%d%d)$")
        local secs = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
        return sign == "-" and -secs or secs
      end
      local ts = first_ts_minutes(first, true)
      return ts and ts * 60 or now_minutes() * 60
    elseif kind == "checkbox" then
      local box = first:match("^%s*[-+*0-9.)]+([ \t]+%[[- X]%])[ \t]")
      return box or ""
    elseif kind == "func" then
      local v = keyfn(it, lines)
      if type(v) == "string" then
        v = case(v)
      end
      return v
    end
  end
end

--- Sort the siblings of the list item at `lnum` (org-sort-list).
local function sort_list(bufnr, lnum, choice, with_case)
  local lists = require("org.lists")
  local keyfn, cmp
  if choice.kind == "func" then
    local abort
    keyfn, abort = read_function("Function for extracting keys: ")
    if abort then
      return
    end
    cmp, abort = read_function("Function for comparing keys (empty for default): ", true)
    if abort then
      return
    end
  end
  local item = lists.item_at(bufnr, lnum)
  local sibs = lists.siblings(item)
  local key = item_key(choice.kind, with_case, keyfn)
  -- records are the items without trailing blank lines, which stay put
  local records = {}
  for _, s in ipairs(sibs) do
    local stop = s.end_lnum
    records[#records + 1] = { lines = get_lines(bufnr, s.lnum, stop), s = s.lnum, e = stop }
    records[#records].key = key(s, records[#records].lines)
  end
  local slots = {}
  for i, r in ipairs(records) do
    slots[i] = { s = r.s, e = r.e }
  end
  sort_records(records, cmp or default_less, choice.reverse)
  for i = #slots, 1, -1 do
    set_lines(bufnr, slots[i].s, slots[i].e, records[i].lines)
  end
  lists.repair(bufnr, sibs[1].lnum)
end

--- Sort entries (org-sort-entries): the children of the current headline,
--- the top-level entries before the first headline, or the entries of the
--- Visual selection. With a count (C-u), sorting is case-sensitive.
function M.sort()
  local bufnr = buf()
  local lnum = cursor()[1]
  local line = vim.api.nvim_get_current_line()
  local lists = require("org.lists")
  local visual = in_visual()
  local vs, ve
  if visual then
    vs, _, ve = utils.visual_range()
    exit_visual()
  end
  local with_case = vim.v.count > 0
  local on_item = not visual and not parser.headline_level(line) and lists.item_at(bufnr, lnum)
  local menu_items = {}
  for _, it in ipairs(on_item and SORT_LIST or SORT_ENTRIES) do
    menu_items[#menu_items + 1] = { key = it.key, label = it.label, value = { kind = it.kind, reverse = false } }
    menu_items[#menu_items + 1] =
      { key = it.key:upper(), label = it.label .. " (reverse)", value = { kind = it.kind, reverse = true } }
  end
  if on_item then
    local choice = require("org.ui").menu({ title = "Sort plain list", items = menu_items })
    if choice then
      sort_list(bufnr, lnum, choice, with_case)
    end
    return
  end
  local file = files.get_buffer(bufnr)
  -- the records: siblings at the level of the first entry in the range
  local start, stop, what
  if visual then
    local first
    for _, h in ipairs(file.headlines) do
      if h.line >= vs then
        first = h
        break
      end
    end
    if not first or first.line > ve then
      utils.warn("Nothing to sort")
      return
    end
    local last_hl = file:headline_at(ve)
    start, stop, what = first.line, last_hl.end_line, "region"
    -- the end of the subtree without its trailing blank lines
    while stop > start and is_blank(get_lines(bufnr, stop, stop)[1]) do
      stop = stop - 1
    end
  else
    local hl = file:headline_at(lnum)
    if hl then
      if #hl.children == 0 then
        utils.warn("Nothing to sort")
        return
      end
      start, stop, what = hl.children[1].line, hl.end_line, "children"
      while stop > start and is_blank(get_lines(bufnr, stop, stop)[1]) do
        stop = stop - 1
      end
    else
      if not file.headlines[1] then
        utils.warn("Nothing to sort")
        return
      end
      start, stop, what = file.headlines[1].line, vim.api.nvim_buf_line_count(bufnr), "top-level"
    end
  end
  local level = parser.headline_level(get_lines(bufnr, start, start)[1])
  local heads = {}
  for _, h in ipairs(file.headlines) do
    if h.line >= start and h.line <= stop then
      if h.level < level then
        utils.warn("Region to sort contains a level above the first entry")
        return
      end
      if h.level == level then
        heads[#heads + 1] = h
      end
    end
  end
  local choice = require("org.ui").menu({ title = "Sort " .. what, items = menu_items })
  if not choice then
    return
  end
  local prop, keyfn, cmp
  if choice.kind == "property" then
    prop = utils.input({ prompt = "Property: " })
    if not prop or vim.trim(prop) == "" then
      return
    end
    prop = vim.trim(prop)
  elseif choice.kind == "func" then
    local abort
    keyfn, abort = read_function("Function for extracting keys: ")
    if abort then
      return
    end
    cmp, abort = read_function("Function for comparing keys (empty for default): ", true)
    if abort then
      return
    end
  end
  local key = entry_key(choice.kind, prop, with_case, keyfn)
  local records = {}
  for i, h in ipairs(heads) do
    local e = heads[i + 1] and heads[i + 1].line - 1 or stop
    local lines = get_lines(bufnr, h.line, e)
    records[#records + 1] = { lines = lines, key = key(h, lines) }
  end
  sort_records(records, cmp or default_less, choice.reverse)
  local out = {}
  for _, r in ipairs(records) do
    vim.list_extend(out, r.lines)
  end
  set_lines(bufnr, start, stop, out)
  vim.api.nvim_win_set_cursor(0, { math.min(lnum, vim.api.nvim_buf_line_count(bufnr)), cursor()[2] })
  utils.notify("Sorting entries...done")
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
    tb:goto(b)
    text = tb:delete(b, e)
    while #text > 1 and text:sub(1, 1) == text:sub(-1) and text:sub(1, 1):match("[%*/_=~%+]") do
      text = text:sub(2, -2)
    end
  end
  local new = s .. text .. s
  if not tb:bolp() and not tb.text:sub(tb.point - 1, tb.point - 1):match(EMPH_PRE) then
    tb:insert(" ")
  end
  if not tb:eobp() and not tb.text:sub(tb.point, tb.point):match(EMPH_POST) and tb.text:sub(tb.point, tb.point) ~= "\n" then
    tb:insert(" ")
    tb:goto(tb.point - 1)
  end
  tb:insert(new)
  if not visual then
    tb:goto(tb.point - 1)
  end
  tb:apply()
  if not visual and ch ~= " " then
    start_insert()
  end
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
  return require("org.fold").line_visible(lnum)
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

---@mod org.fold Folding and visibility cycling
---
--- Headlines fold by level. Plain list items with children or more lines
--- fold one level deeper (org-cycle-include-plain-lists), and drawers
--- (`:PROPERTIES:`, `:LOGBOOK:`, ...) and blocks (`#+begin_...` /
--- `#+BEGIN:` dynamic blocks) one level deeper than what contains them,
--- like Emacs. TAB cycles a subtree or an item (folded → children →
--- subtree), S-TAB the whole buffer (overview → contents → show all).
---
--- Vim folds nest: an open fold shows all of its lines, so they cannot
--- show the child headlines of an entry while hiding its own text (the
--- Emacs CONTENTS view, show_children, show_branches) nor hide the
--- siblings of a sparse-tree match. Those lines are hidden with
--- `conceal_lines` extmarks (Neovim 0.11+), on top of the folds. The
--- cursor never rests on such a line: line motions skip them and other
--- jumps reveal them. Without `conceal_lines` the text stays visible.

local config = require("org.config")
local parser = require("org.parser")

local M = {}

local cache = {} -- bufnr -> { tick, levels, regions }
local ns_hide = vim.api.nvim_create_namespace("org.fold.hide")
local ns_ellipsis = vim.api.nvim_create_namespace("org.fold.ellipsis")

--- Whether this Neovim can hide lines with `conceal_lines` extmarks.
M.conceal_supported = (function()
  local ok = pcall(function()
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "x" })
    vim.api.nvim_buf_set_extmark(b, ns_hide, 0, 0, { conceal_lines = "" })
    vim.api.nvim_buf_delete(b, { force = true })
  end)
  return ok
end)()

local function is_drawer_start(line)
  local name = line:match("^%s*:([%w_%-]+):%s*$")
  return name ~= nil and name:upper() ~= "END"
end

local function is_drawer_end(line)
  return line:match("^%s*:[Ee][Nn][Dd]:%s*$") ~= nil
end

local function block_start(line)
  local name = line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
  if name then
    return name:lower()
  end
  if line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]:") then
    return ":"
  end
end

local function is_block_end(line, name)
  if name == ":" then
    return line:match("^%s*#%+[Ee][Nn][Dd]:") ~= nil
  end
  local e = line:match("^%s*#%+[Ee][Nn][Dd]_(%S+)")
  return e ~= nil and e:lower() == name
end

local function is_blank(l)
  return l == nil or l:match("^%s*$") ~= nil
end

--- Plain list items that span several lines, per line: the number of
--- such items containing it and whether one starts there.
local function item_depths(lines)
  local depth, starts = {}, {}
  if config.opts.cycle_include_plain_lists == false then
    return depth, starts
  end
  local lists = require("org.lists")
  local n = #lines
  local s = 1
  while s <= n do
    local e = s
    while e + 1 <= n and not (lines[e + 1]:byte(1) == 42 and parser.headline_level(lines[e + 1])) do
      e = e + 1
    end
    local from = (lines[s]:byte(1) == 42 and parser.headline_level(lines[s])) and s + 1 or s
    if from <= e then
      local _, all = lists.parse_region(lines, from, e)
      for _, it in ipairs(all) do
        if it.end_lnum > it.lnum then
          starts[it.lnum] = true
          for l = it.lnum, it.end_lnum do
            depth[l] = (depth[l] or 0) + 1
          end
        end
      end
    end
    s = e + 1
  end
  return depth, starts
end

--- Compute fold levels for all lines.
---@return table levels, table regions (list of {start, end, kind})
function M.compute(lines)
  local levels, regions = {}, {}
  local cur = 0
  local n = #lines
  local depth, item_start = item_depths(lines)
  local min_inline = parser.inlinetask_min_level()
  local i = 1
  while i <= n do
    local line = lines[i]
    local lvl = line:byte(1) == 42 and parser.headline_level(line) or nil
    local inline_stop
    if lvl and min_inline and lvl >= min_inline then
      -- an inline task folds up to its END line, inside the entry
      for j = i + 1, n do
        local l = lines[j]
        local lv = l:byte(1) == 42 and parser.headline_level(l)
        if lv then
          if lv >= min_inline and l:match("^%*+%s+END%s*$") then
            inline_stop = j
          end
          break
        end
      end
      lvl = nil
    end
    if inline_stop then
      local inner = cur + (depth[i] or 0) + 1
      levels[i] = ">" .. inner
      for j = i + 1, inline_stop - 1 do
        levels[j] = inner
      end
      levels[inline_stop] = "<" .. inner
      regions[#regions + 1] = { start = i, ["end"] = inline_stop, kind = "inlinetask" }
      i = inline_stop + 1
    elseif lvl then
      levels[i] = ">" .. lvl
      cur = lvl
      i = i + 1
    else
      local base = cur + (depth[i] or 0)
      local kind, bname
      -- (a results drawer keeps its own drawer fold)
      local rstop = line:match("^%s*#%+[Rr][Ee][Ss][Uu][Ll][Tt][Ss][%[:]")
        and not is_drawer_start(lines[i + 1] or "")
        and require("org.babel.blocks").results_end(lines, i)
      if rstop and rstop > i then
        -- a #+RESULTS keyword and its result fold like Emacs'
        -- org-babel-hide-result-toggle (TAB on the keyword)
        local inner = cur + 1
        levels[i] = ">" .. inner
        for j = i + 1, rstop - 1 do
          levels[j] = inner
        end
        levels[rstop] = "<" .. inner
        regions[#regions + 1] = { start = i, ["end"] = rstop, kind = "results" }
        i = rstop + 1
        goto continue
      end
      if is_drawer_start(line) then
        kind = "drawer"
      else
        bname = block_start(line)
        if bname then
          kind = "block"
        end
      end
      local stop
      if kind then
        for j = i + 1, n do
          local l = lines[j]
          if l:byte(1) == 42 and parser.headline_level(l) then
            break
          end
          if (kind == "drawer" and is_drawer_end(l)) or (kind == "block" and is_block_end(l, bname)) then
            stop = j
            break
          end
        end
      end
      if stop and stop > i then
        local inner = base + 1
        levels[i] = ">" .. inner
        for j = i + 1, stop - 1 do
          levels[j] = inner
        end
        levels[stop] = "<" .. inner
        regions[#regions + 1] = { start = i, ["end"] = stop, kind = kind }
        i = stop + 1
      else
        levels[i] = item_start[i] and (">" .. base) or base
        if item_start[i] then
          regions[#regions + 1] = { start = i, kind = "item" }
        end
        i = i + 1
      end
    end
    ::continue::
  end
  -- org-cycle-separator-lines: with enough blank lines before a headline,
  -- the last one stays visible when the subtree above is folded
  local sep = config.opts.cycle_separator_lines or 2
  if sep > 0 then
    for l = 2, n do
      local lvl = levels[l]
      if type(lvl) == "string" and lvl:sub(1, 1) == ">" and lines[l]:byte(1) == 42 then
        local k = 0
        while l - 1 - k >= 1 and is_blank(lines[l - 1 - k]) and type(levels[l - 1 - k]) == "number" do
          k = k + 1
        end
        if k >= sep then
          levels[l - 1] = tonumber(lvl:sub(2)) - 1
        end
      end
    end
  end
  return levels, regions
end

local function get(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = cache[bufnr]
  if c and c.tick == tick then
    return c
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local levels, regions = M.compute(lines)
  c = { tick = tick, levels = levels, regions = regions }
  cache[bufnr] = c
  return c
end

function M.foldexpr(lnum)
  lnum = lnum or vim.v.lnum
  local c = get(vim.api.nvim_get_current_buf())
  return c.levels[lnum] or 0
end

local function hl_exists(name)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name })
  return ok and h and next(h) ~= nil
end

--- The org-ellipsis text.
local function ellipsis()
  -- org-ellipsis nil shows the standard "..."
  return config.opts.ellipsis or "..."
end

function M.foldtext()
  local lnum = vim.v.foldstart
  local line = vim.fn.getline(lnum)
  local lvl = parser.headline_level(line)
  local group = "Folded"
  if lvl then
    local g = "OrgHeadlineLevel" .. (((lvl - 1) % 8) + 1)
    if hl_exists(g) then
      group = g
    end
  elseif is_drawer_start(line) and hl_exists("OrgDrawer") then
    group = "OrgDrawer"
  end
  line = line:gsub("\t", string.rep(" ", vim.bo.tabstop))
  return { { line, group }, { ellipsis(), "Comment" } }
end

---------------------------------------------------------------------------
-- Hidden lines (conceal_lines)
---------------------------------------------------------------------------

local function curbuf()
  return vim.api.nvim_get_current_buf()
end

--- Is line `lnum` hidden by a conceal_lines mark?
function M.is_concealed(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and curbuf() or bufnr
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_hide, { lnum - 1, 0 }, { lnum - 1, -1 }, { limit = 1 })
  return #marks > 0
end

--- Hide lines [s, e] (1-based, inclusive).
function M.conceal(bufnr, s, e)
  if not M.conceal_supported then
    return
  end
  bufnr = (bufnr == nil or bufnr == 0) and curbuf() or bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  for i, l in ipairs(lines) do
    local row = s + i - 2
    if not M.is_concealed(bufnr, row + 1) then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_hide, row, 0, {
        end_row = row,
        end_col = #l,
        conceal_lines = "",
        invalidate = true,
        undo_restore = false,
      })
    end
  end
end

--- Show lines [s, e] hidden by `conceal`.
function M.unconceal(bufnr, s, e)
  bufnr = (bufnr == nil or bufnr == 0) and curbuf() or bufnr
  if e < s then
    return
  end
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_hide, { s - 1, 0 }, { e - 1, -1 }, {})
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_del_extmark(bufnr, ns_hide, m[1])
  end
end

--- Show every hidden line of the buffer.
function M.clear_hidden(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and curbuf() or bufnr
  vim.api.nvim_buf_clear_namespace(bufnr, ns_hide, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_ellipsis, 0, -1)
end

--- Is line `lnum` visible in the current window (not inside a closed fold
--- nor hidden)?
function M.line_visible(lnum)
  local fc = vim.fn.foldclosed(lnum)
  if fc ~= -1 and fc ~= lnum then
    return false
  end
  return not M.is_concealed(0, lnum)
end

local function file()
  return require("org.files").get_buffer(0)
end

--- Put the ellipsis after headlines whose text is hidden while the fold
--- is open (Emacs shows "..." after any heading with invisible text).
local function refresh_ellipsis()
  local bufnr = curbuf()
  vim.api.nvim_buf_clear_namespace(bufnr, ns_ellipsis, 0, -1)
  if not M.conceal_supported then
    return
  end
  for _, hl in ipairs(file().headlines) do
    if hl.end_line > hl.line and vim.fn.foldclosed(hl.line) == -1 and M.is_concealed(bufnr, hl.line + 1) then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_ellipsis, hl.line - 1, 0, {
        virt_text = { { ellipsis(), "Comment" } },
        virt_text_pos = "eol",
      })
    end
  end
end
M.refresh_ellipsis = refresh_ellipsis

---------------------------------------------------------------------------
-- Window helpers
---------------------------------------------------------------------------

local function set_win_opts(win)
  local wo = vim.wo[win][0]
  wo.foldmethod = "expr"
  wo.foldexpr = "v:lua.require'org.fold'.foldexpr(v:lnum)"
  wo.foldtext = "v:lua.require'org.fold'.foldtext()"
  wo.foldenable = true
  local fc = vim.wo[win].fillchars
  if not fc:find("fold:") then
    wo.fillchars = (fc ~= "" and fc .. "," or "") .. "fold: "
  end
  if M.conceal_supported and vim.wo[win].conceallevel < 2 then
    -- hidden lines need conceallevel >= 2
    wo.conceallevel = 2
  end
end

local function lnum_closed(lnum)
  return vim.fn.foldclosed(lnum) ~= -1
end

--- Close the fold starting at lnum if it is open.
local function close_at(lnum)
  if vim.fn.foldclosed(lnum) == -1 and vim.fn.foldlevel(lnum) > 0 then
    pcall(vim.cmd, lnum .. "foldclose")
  end
end

local function open_at(lnum)
  if vim.fn.foldclosed(lnum) ~= -1 then
    pcall(vim.cmd, lnum .. "foldopen")
  end
end

--- Close drawer folds in [s, e].
local function close_drawers(s, e)
  local c = get(vim.api.nvim_get_current_buf())
  -- innermost first doesn't matter: drawers don't nest
  for _, r in ipairs(c.regions) do
    if r.kind == "drawer" and r.start >= s and r["end"] <= e then
      if vim.fn.foldclosed(r.start) == -1 then
        close_at(r.start)
      end
    end
  end
end

local function has_fold(hl)
  return hl.end_line > hl.line
end

--- Close the block folds (`#+begin_...`) in [s, e] (org-fold-hide-block-all).
local function close_blocks(s, e)
  local c = get(vim.api.nvim_get_current_buf())
  for _, r in ipairs(c.regions) do
    if r.kind == "block" and r.start >= s and r["end"] <= e then
      close_at(r.start)
    end
  end
end

--- Open the item folds in [s, e] (the text of an entry shows its lists).
local function open_items(s, e)
  local c = get(vim.api.nvim_get_current_buf())
  for _, r in ipairs(c.regions) do
    if r.kind == "item" and r.start >= s and r.start <= e then
      open_at(r.start)
    end
  end
end

--- Re-fold archived subtrees (`:ARCHIVE:` tag) whose headline is in
--- [s, e], so visibility cycling never opens them
--- (org-cycle-hide-archived-subtrees). Returns true when the headline at
--- `s` itself is archived.
local function hide_archived(s, e)
  if config.opts.cycle_open_archived_trees or M._force_archived then
    return false
  end
  local self_archived = false
  for _, hl in ipairs(file().headlines) do
    if hl.line >= s and hl.line <= e and vim.tbl_contains(hl.tags, "ARCHIVE") and has_fold(hl) then
      close_at(hl.line)
      if hl.line == s then
        self_archived = true
      end
    end
  end
  return self_archived
end

local function hide_archived_all()
  hide_archived(1, vim.api.nvim_buf_line_count(0))
end

--- Hide the text of an entry (the lines between its headline and its
--- first child) while its fold is open.
local function hide_entry(hl)
  if hl.body_end > hl.line then
    M.conceal(0, hl.line + 1, hl.body_end)
  end
end

--- Show the text of an entry: open its fold if needed (its children
--- stay hidden) and unhide its lines (org-fold-show-entry).
local function show_entry(hl)
  if has_fold(hl) and lnum_closed(hl.line) then
    open_at(hl.line)
    for _, ch in ipairs(hl.children) do
      if has_fold(ch) then
        close_at(ch.line)
      end
      M.conceal(0, ch.line, ch.line)
    end
  end
  M.unconceal(0, hl.line + 1, hl.body_end)
  open_items(hl.line + 1, hl.body_end)
  close_drawers(hl.line, hl.body_end)
end

--- Open the fold of `hl` whose contents were hidden, keeping them hidden:
--- its text and child headlines get concealed.
local function open_hidden(hl)
  if not has_fold(hl) or not lnum_closed(hl.line) then
    return false
  end
  open_at(hl.line)
  hide_entry(hl)
  for _, ch in ipairs(hl.children) do
    if has_fold(ch) then
      close_at(ch.line)
    end
    M.conceal(0, ch.line, ch.line)
  end
  return true
end

--- Make the headline `hl` visible, opening its ancestors without showing
--- anything else (org-fold-heading on the path).
local function show_heading_path(hl)
  local path = {}
  local h = hl
  while h do
    table.insert(path, 1, h)
    h = h.parent
  end
  for idx, a in ipairs(path) do
    M.unconceal(0, a.line, a.line)
    if idx < #path then
      open_hidden(a)
    end
  end
end

---------------------------------------------------------------------------
-- Global visibility
---------------------------------------------------------------------------

function M.overview()
  M.clear_hidden()
  vim.cmd("normal! zM")
  vim.b.org_global_cycle = "overview"
end

--- Show the headlines down to `level` without their text
--- (org-cycle-content): CONTENTS, and #+STARTUP: showNlevels.
local function show_levels(level)
  M.clear_hidden()
  vim.cmd("normal! zM")
  -- parents come first, so each fold opened here is visible
  for _, hl in ipairs(file().headlines) do
    if hl.level < level and #hl.children > 0 then
      open_at(hl.line)
      hide_entry(hl)
    end
  end
  hide_archived_all()
  refresh_ellipsis()
end

function M.content()
  show_levels(math.huge)
  vim.b.org_global_cycle = "content"
end

function M.show_all()
  M.clear_hidden()
  vim.cmd("normal! zR")
  vim.b.org_global_cycle = "showall"
end

--- Everything visible except drawers (Emacs "showall").
local function show_all_but_drawers()
  M.clear_hidden()
  vim.cmd("normal! zR")
  close_drawers(1, vim.api.nvim_buf_line_count(0))
  hide_archived_all()
  vim.b.org_global_cycle = "showall"
end

function M.global_cycle()
  if vim.v.count > 0 then
    show_levels(vim.v.count)
    vim.b.org_global_cycle = "content"
    return
  end
  local state = vim.b.org_global_cycle or "showall"
  if state == "showall" then
    M.overview()
    vim.api.nvim_echo({ { "OVERVIEW" } }, false, {})
  elseif state == "overview" then
    M.content()
    vim.api.nvim_echo({ { "CONTENTS" } }, false, {})
  else
    show_all_but_drawers()
    vim.api.nvim_echo({ { "SHOW ALL" } }, false, {})
  end
end

---------------------------------------------------------------------------
-- Local cycling
---------------------------------------------------------------------------

--- Show the whole subtree of the ancestor at `level` of the headline at
--- the cursor (org-cycle with a numeric argument).
local function show_ancestor_subtree(level)
  local hl = file():headline_at(vim.api.nvim_win_get_cursor(0)[1])
  if not hl then
    return false
  end
  while hl.parent and hl.level > level do
    hl = hl.parent
  end
  show_heading_path(hl)
  pcall(vim.cmd, hl.line .. "," .. hl.end_line .. "foldopen!")
  M.unconceal(0, hl.line, hl.end_line)
  close_drawers(hl.line, hl.end_line)
  hide_archived(hl.line + 1, hl.end_line)
  refresh_ellipsis()
end

--- Remember the state of the last TAB, like Emacs `last-command`: the
--- next TAB continues the cycle only if nothing happened in between.
local function set_last_cycle(lnum, status)
  vim.w.org_last_cycle = {
    buf = curbuf(),
    lnum = lnum,
    tick = vim.api.nvim_buf_get_changedtick(0),
    status = status,
  }
end

local function last_cycle_status(lnum)
  local s = vim.w.org_last_cycle
  if s and s.buf == curbuf() and s.lnum == lnum and s.tick == vim.api.nvim_buf_get_changedtick(0) then
    return s.status
  end
end

--- Whether everything after line `lnum` up to `last` is hidden (or blank).
local function all_hidden_after(lnum, last)
  if lnum_closed(lnum) then
    return true
  end
  local lines = vim.api.nvim_buf_get_lines(0, lnum, last, false)
  for i, l in ipairs(lines) do
    local n = lnum + i
    if M.line_visible(n) and not is_blank(l) then
      return false
    end
  end
  return true
end

--- TAB on a plain list item (org-cycle-include-plain-lists).
local function cycle_item(lnum, item)
  if item.end_lnum <= item.lnum then
    vim.api.nvim_echo({ { "EMPTY ENTRY" } }, false, {})
    return
  end
  local has_children = #item.children > 0
  local last = last_cycle_status(lnum)
  if all_hidden_after(lnum, item.end_lnum) and has_children then
    -- CHILDREN: the item text, its sub-items folded
    open_at(lnum)
    M.unconceal(0, lnum + 1, item.end_lnum)
    for _, ch in ipairs(item.children) do
      if ch.end_lnum > ch.lnum then
        close_at(ch.lnum)
      end
    end
    vim.api.nvim_echo({ { "CHILDREN" } }, false, {})
    set_last_cycle(lnum, "children")
  elseif (all_hidden_after(lnum, item.end_lnum) and not has_children) or last == "children" then
    pcall(vim.cmd, lnum .. "," .. item.end_lnum .. "foldopen!")
    M.unconceal(0, lnum + 1, item.end_lnum)
    close_drawers(lnum, item.end_lnum)
    vim.api.nvim_echo({ { has_children and "SUBTREE" or "SUBTREE (NO CHILDREN)" } }, false, {})
    set_last_cycle(lnum, "subtree")
  else
    close_at(lnum)
    vim.api.nvim_echo({ { "FOLDED" } }, false, {})
    set_last_cycle(lnum, "folded")
  end
end

--- TAB outside headlines, items, drawers and blocks: indent the line
--- when `cycle_emulate_tab` says so (org-cycle-emulate-tab), else cycle
--- the entry containing the cursor. Returns nil when handled.
local function emulate_tab(lnum, line)
  local mode = config.opts.cycle_emulate_tab
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local emulate
  if mode == true then
    emulate = true
  elseif mode == "white" then
    emulate = is_blank(line)
  elseif mode == "whitestart" then
    emulate = line:sub(1, col):match("^%s*$") ~= nil
  elseif mode == "exc-hl-bol" then
    emulate = true
  else
    emulate = false
  end
  if emulate then
    return require("org.element").indent_line(lnum)
  end
  local hl = file():headline_at(lnum)
  if not hl then
    return false
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_win_set_cursor(0, { hl.line, 0 })
  M.cycle()
  if M.line_visible(pos[1]) then
    vim.api.nvim_win_set_cursor(0, pos)
  end
end

--- TAB. With a count: 16 restores the startup visibility, 64 shows
--- everything (drawers too), any other N shows the whole subtree of the
--- ancestor at level N (like C-u C-u TAB, C-u C-u C-u TAB and M-N TAB).
function M.cycle()
  local count = vim.v.count
  if count == 16 then
    return M.set_startup_visibility()
  elseif count == 64 then
    return M.show_everything()
  elseif count > 0 then
    return show_ancestor_subtree(count)
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  local bufnr = vim.api.nvim_get_current_buf()
  local c = get(bufnr)
  for _, r in ipairs(c.regions) do
    if r.start == lnum and r.kind ~= "item" then
      if lnum_closed(lnum) then
        open_at(lnum)
      else
        close_at(lnum)
      end
      return
    end
  end
  if not parser.headline_level(line) then
    if config.opts.cycle_include_plain_lists ~= false then
      local item = require("org.lists").item_on(bufnr, lnum)
      if item then
        return cycle_item(lnum, item)
      end
    end
    return emulate_tab(lnum, line)
  end
  local f = file()
  local hl = f:headline_on(lnum)
  if not hl then
    return false
  end
  if not has_fold(hl) then
    vim.api.nvim_echo({ { "EMPTY ENTRY" } }, false, {})
    set_last_cycle(lnum, nil)
    return
  end
  local archived_msg = "Subtree is archived and stays closed (use force_cycle_archived to cycle it)"
  local last = last_cycle_status(lnum)
  local hidden = all_hidden_after(lnum, hl.end_line)
  if hidden and #hl.children > 0 then
    -- CHILDREN: the entry text and the child headlines, folded
    open_at(lnum)
    for _, ch in ipairs(hl.children) do
      if has_fold(ch) then
        close_at(ch.line)
      end
    end
    M.unconceal(0, hl.line + 1, hl.end_line)
    open_items(hl.line + 1, hl.body_end)
    close_drawers(hl.line, hl.body_end)
    refresh_ellipsis()
    set_last_cycle(lnum, "children")
    if hide_archived(hl.line, hl.end_line) then
      vim.api.nvim_echo({ { archived_msg } }, false, {})
      return
    end
    vim.api.nvim_echo({ { "CHILDREN" } }, false, {})
    return
  end
  if (hidden and #hl.children == 0) or last == "children" then
    -- SUBTREE
    pcall(vim.cmd, hl.line .. "," .. hl.end_line .. "foldopen!")
    M.unconceal(0, hl.line + 1, hl.end_line)
    close_drawers(hl.line, hl.end_line)
    refresh_ellipsis()
    set_last_cycle(lnum, "subtree")
    if hide_archived(hl.line, hl.end_line) then
      vim.api.nvim_echo({ { archived_msg } }, false, {})
      return
    end
    vim.api.nvim_echo({ { #hl.children == 0 and "SUBTREE (NO CHILDREN)" or "SUBTREE" } }, false, {})
    return
  end
  -- FOLDED
  close_at(lnum)
  refresh_ellipsis()
  set_last_cycle(lnum, "folded")
  vim.api.nvim_echo({ { "FOLDED" } }, false, {})
end

--- Cycle the subtree at the cursor even when it is archived
--- (org-cycle-force-archived).
function M.force_cycle_archived()
  M._force_archived = true
  local ok, res = pcall(M.cycle)
  M._force_archived = nil
  if not ok then
    error(res)
  end
  return res
end

---------------------------------------------------------------------------
-- Subtree visibility commands
---------------------------------------------------------------------------

--- Headline at the cursor (the one whose section contains it).
local function headline_at_cursor()
  return file():headline_at(vim.api.nvim_win_get_cursor(0)[1])
end

--- Show the headlines of `hl`'s subtree down to `depth` levels below it
--- (org-fold-show-children): their text stays hidden; the text of `hl`
--- stays as it was.
local function show_descendants(hl, depth)
  show_heading_path(hl)
  local was_hidden = lnum_closed(hl.line)
  if was_hidden then
    open_hidden(hl)
  end
  local function walk(h, rel)
    for _, ch in ipairs(h.children) do
      M.unconceal(0, ch.line, ch.line)
      if rel + 1 < depth and #ch.children > 0 then
        if lnum_closed(ch.line) then
          open_hidden(ch)
        else
          hide_entry(ch)
        end
        walk(ch, rel + 1)
      elseif has_fold(ch) then
        close_at(ch.line)
      end
    end
  end
  walk(hl, 0)
  refresh_ellipsis()
end

--- Show all headlines of the current subtree, without their text
--- (org-kill-note-or-show-branches outside capture / outline-show-branches).
function M.show_branches()
  local hl = headline_at_cursor()
  if not hl then
    return false
  end
  show_descendants(hl, math.huge)
end

--- Show the direct children of the current headline, folded
--- (org-show-children). With a count N, show N levels.
function M.show_children()
  local hl = headline_at_cursor()
  if not hl then
    return false
  end
  show_descendants(hl, math.max(vim.v.count, 1))
end

--- Show the context of line `lnum` (org-fold-show-set-visibility):
--- `detail` is "minimal", "ancestors", "lineage", "tree" or "canonical"
--- (see org-fold-show-context-detail).
function M.show_context(lnum, detail)
  detail = detail or "ancestors"
  local f = file()
  local hl = f:headline_at(lnum)
  if not hl then
    M.unconceal(0, lnum, lnum)
    return
  end
  local on_heading = hl.line == lnum
  show_heading_path(hl)
  if not on_heading then
    show_entry(hl)
  end
  if detail == "lineage" or detail == "tree" or detail == "canonical" then
    -- the children of every ancestor
    local a = hl.parent
    while a do
      for _, ch in ipairs(a.children) do
        M.unconceal(0, ch.line, ch.line)
      end
      if detail == "canonical" then
        show_entry(a)
        for _, ch in ipairs(a.children) do
          M.unconceal(0, ch.line, ch.line)
        end
      end
      a = a.parent
    end
  end
  if not on_heading and #hl.children > 0 then
    if detail == "lineage" then
      M.unconceal(0, hl.children[1].line, hl.children[1].line)
    elseif detail == "tree" or detail == "canonical" then
      for _, ch in ipairs(hl.children) do
        M.unconceal(0, ch.line, ch.line)
      end
    end
  end
  if vim.fn.foldclosed(lnum) ~= -1 and vim.fn.foldclosed(lnum) ~= lnum then
    local pos = vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    vim.cmd("normal! zv")
    vim.api.nvim_win_set_cursor(0, pos)
  end
  M.unconceal(0, lnum, lnum)
  refresh_ellipsis()
end

--- Make the context around the cursor visible (org-reveal): the headline
--- path, the siblings at every level and the current entry (lineage).
--- `arg` 4 (C-u) also shows the text of the ancestors (canonical); true
--- or 16 (C-u C-u) shows the parent's whole subtree.
---@param arg? boolean|integer defaults to the count
function M.reveal(arg)
  if arg == nil then
    arg = vim.v.count > 0 and vim.v.count or false
  end
  -- org-crypt puts org-decrypt-entry on org-fold-reveal-start-hook
  require("org.crypt").reveal_hook()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local hl = headline_at_cursor()
  if not hl then
    vim.cmd("normal! zv")
    return
  end
  if arg == true or (type(arg) == "number" and arg >= 16) then
    local top = hl.parent or hl
    show_heading_path(top)
    pcall(vim.cmd, top.line .. "," .. top.end_line .. "foldopen!")
    M.unconceal(0, top.line, top.end_line)
    close_drawers(top.line, top.end_line)
    refresh_ellipsis()
    return
  end
  M.show_context(lnum, arg == 4 and "canonical" or "lineage")
end

--- Copy the visible text (closed folds contribute only their first line,
--- hidden lines nothing) of the buffer, or of the lines of the visual
--- selection, into the unnamed and `+` registers (org-copy-visible).
function M.copy_visible()
  local s, e = 1, vim.api.nvim_buf_line_count(0)
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local srow, _, erow = require("org.utils").visual_range()
    s, e = srow, erow
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
  local out = {}
  local lnum = s
  while lnum <= e do
    local fc = vim.fn.foldclosed(lnum)
    if fc == -1 then
      if not M.is_concealed(0, lnum) then
        out[#out + 1] = vim.fn.getline(lnum)
      end
      lnum = lnum + 1
    else
      if fc == lnum and not M.is_concealed(0, lnum) then
        out[#out + 1] = vim.fn.getline(lnum)
      end
      lnum = vim.fn.foldclosedend(lnum) + 1
    end
  end
  vim.fn.setreg('"', out, "l")
  pcall(vim.fn.setreg, "+", out, "l")
  require("org.utils").notify(string.format("Copied %d visible line(s)", #out))
  return out
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

--- Apply the VISIBILITY property of every headline that has one
--- (org-cycle-set-visibility-according-to-property): `folded`,
--- `children`, `content` or `all`. The headline itself is revealed.
function M.apply_visibility_properties()
  local pos = vim.api.nvim_win_get_cursor(0)
  for _, hl in ipairs(file().headlines) do
    local state = hl.properties.VISIBILITY
    state = state and state:lower()
    if state and has_fold(hl) then
      if state == "folded" then
        close_at(hl.line)
      else
        show_heading_path(hl)
      end
      if state == "children" then
        -- org-fold-show-hidden-entry + org-fold-show-children
        show_entry(hl)
        for _, ch in ipairs(hl.children) do
          M.unconceal(0, ch.line, ch.line)
          if has_fold(ch) then
            close_at(ch.line)
          end
        end
      elseif state == "content" then
        -- every headline of the subtree, no text
        open_at(hl.line)
        local function walk(h)
          if #h.children > 0 then
            open_at(h.line)
            hide_entry(h)
          end
          for _, ch in ipairs(h.children) do
            M.unconceal(0, ch.line, ch.line)
            if #ch.children > 0 then
              walk(ch)
            elseif has_fold(ch) then
              close_at(ch.line)
            end
          end
        end
        walk(hl)
      elseif state == "all" or state == "showall" then
        pcall(vim.cmd, hl.line .. "," .. hl.end_line .. "foldopen!")
        M.unconceal(0, hl.line, hl.end_line)
        close_drawers(hl.line, hl.end_line)
      end
    end
  end
  vim.api.nvim_win_set_cursor(0, pos)
  refresh_ellipsis()
end

local STARTUP_MODES = {
  "overview",
  "content",
  "showall",
  "showeverything",
  "nofold",
  "fold",
  "show2levels",
  "show3levels",
  "show4levels",
  "show5levels",
}

--- Resolve an on/off `#+STARTUP` word pair against a default.
local function startup_flag(startup, on, off, default)
  if startup[on] then
    return true
  elseif startup[off] then
    return false
  end
  return default
end

--- Apply #+STARTUP / startup_folded visibility in the current window,
--- then hide blocks (`hideblocks`), apply VISIBILITY properties, fold
--- archived subtrees and hide drawers (org-cycle-set-startup-visibility).
function M.apply_startup(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local f = require("org.files").get_buffer(bufnr)
  local startup = f.settings.startup or {}
  local mode = config.opts.startup_folded or "overview"
  for _, k in ipairs(STARTUP_MODES) do
    if startup[k] then
      mode = k
    end
  end
  if mode == "fold" then
    mode = "overview"
  end
  local levels = tonumber(mode:match("^show(%d)levels$") or "")
  if mode == "overview" then
    M.overview()
  elseif mode == "content" then
    M.content()
  elseif levels then
    show_levels(levels)
    vim.b.org_global_cycle = "content"
  else
    M.clear_hidden()
    vim.cmd("normal! zR")
    vim.b.org_global_cycle = "showall"
  end
  if mode == "showeverything" then
    return
  end
  local last = vim.api.nvim_buf_line_count(0)
  if startup_flag(startup, "hideblocks", "nohideblocks", config.opts.hide_block_startup) then
    close_blocks(1, last)
  end
  M.apply_visibility_properties()
  hide_archived_all()
  if startup_flag(startup, "hidedrawers", "nohidedrawers", config.opts.hide_drawer_startup ~= false) then
    close_drawers(1, last)
  end
end

--- Return to the startup visibility, VISIBILITY properties included
--- (C-u C-u TAB, org-cycle-set-startup-visibility).
function M.set_startup_visibility()
  M.apply_startup(0)
  vim.api.nvim_echo({ { "Startup visibility, plus VISIBILITY properties" } }, false, {})
end

--- Show the entire buffer, drawers included (C-u C-u C-u TAB).
function M.show_everything()
  M.clear_hidden()
  vim.cmd("normal! zR")
  vim.b.org_global_cycle = "showall"
  vim.api.nvim_echo({ { "Entire buffer visible, including drawers" } }, false, {})
end

--- Keep the cursor off hidden lines: line motions skip them, other jumps
--- reveal the line (Emacs never leaves point in invisible text).
local function on_cursor_moved(bufnr)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local prev = vim.w.org_prev_lnum or lnum
  vim.w.org_prev_lnum = lnum
  if not M.is_concealed(bufnr, lnum) then
    return
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  local dir = lnum >= prev and 1 or -1
  if math.abs(lnum - prev) <= 1 then
    local l = lnum
    while l >= 1 and l <= n and not M.line_visible(l) do
      l = l + dir
    end
    if l < 1 or l > n then
      l = lnum
      while l >= 1 and l <= n and not M.line_visible(l) do
        l = l - dir
      end
    end
    if l >= 1 and l <= n then
      vim.w.org_prev_lnum = l
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      return
    end
  end
  M.show_context(lnum, "lineage")
end

--- org-fold-catch-invisible-edits for text typed on a hidden line.
local function on_insert_char(bufnr)
  local mode = config.opts.catch_invisible_edits
  if not mode then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if not M.is_concealed(bufnr, lnum) then
    return
  end
  if mode == "error" then
    vim.v.char = ""
    require("org.utils").warn("Edit in invisible region aborted, repeat to confirm with text visible")
    return
  end
  M.show_context(lnum, "lineage")
  if mode == "show-and-error" or mode == "smart" then
    vim.v.char = ""
    require("org.utils").warn("Edit in invisible region aborted, repeat to confirm with text visible")
  end
end

function M.setup_buffer(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local function setup_win(win)
    set_win_opts(win)
    if not vim.b[bufnr].org_startup_done then
      vim.b[bufnr].org_startup_done = true
      vim.api.nvim_win_call(win, function()
        M.apply_startup(bufnr)
      end)
    end
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) == bufnr then
    setup_win(win)
  end
  local group = vim.api.nvim_create_augroup("org.fold." .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = bufnr,
    group = group,
    callback = function()
      local w = vim.api.nvim_get_current_win()
      if vim.wo[w].foldexpr ~= "v:lua.require'org.fold'.foldexpr(v:lnum)" then
        setup_win(w)
      end
    end,
  })
  if M.conceal_supported then
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = bufnr,
      group = group,
      callback = function()
        on_cursor_moved(bufnr)
      end,
    })
    vim.api.nvim_create_autocmd("InsertCharPre", {
      buffer = bufnr,
      group = group,
      callback = function()
        on_insert_char(bufnr)
      end,
    })
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    group = group,
    callback = function()
      cache[bufnr] = nil
    end,
  })
end

return M

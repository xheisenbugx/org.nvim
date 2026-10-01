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

--- The first non-blank byte of `line` (nil for a blank line). Checked
--- before matching patterns, which LuaJIT doesn't compile.
local function first_byte(line)
  local j = 1
  local b = line:byte(1)
  while b == 32 or (b ~= nil and b >= 9 and b <= 13) do
    j = j + 1
    b = line:byte(j)
  end
  return b
end

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
      local fb = first_byte(line)
      -- (a results drawer keeps its own drawer fold)
      local rstop = fb == 35
        and line:match("^%s*#%+[Rr][Ee][Ss][Uu][Ll][Tt][Ss][%[:]")
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
      if fb == 58 and is_drawer_start(line) then
        kind = "drawer"
      elseif fb == 35 then
        bname = block_start(line)
        if bname then
          kind = "block"
        end
      end
      local stop
      if kind then
        local want = kind == "drawer" and 58 or 35
        for j = i + 1, n do
          local l = lines[j]
          if l:byte(1) == 42 and parser.headline_level(l) then
            break
          end
          if
            first_byte(l) == want
            and ((kind == "drawer" and is_drawer_end(l)) or (kind == "block" and is_block_end(l, bname)))
          then
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

---------------------------------------------------------------------------
-- Fold level cache
--
-- Levels are computed for the whole buffer once, then kept up to date per
-- edit: an on_bytes callback shifts the cached levels and records the rows
-- that changed, and the next lookup recomputes only the sections, from one
-- outline headline to the next, around them. Fold levels never depend on
-- text beyond the enclosing sections, so an edit in a large file costs the
-- size of one entry, not of the file. (on_bytes, unlike on_lines, runs
-- before Neovim evaluates 'foldexpr' for an edit. Undo and redo are the
-- exception: they report their changes afterwards, so a lookup that finds
-- the text changed since the last report recomputes everything.) Regions
-- (drawers, blocks, ...) are only needed by commands and are computed for
-- the whole buffer on demand.
---------------------------------------------------------------------------

local tracked = {} -- bufnr -> true while on_bytes reports its changes

--- Options the levels depend on; a change forces a full recompute.
local function signature()
  return table.concat({
    tostring(config.opts.cycle_include_plain_lists),
    tostring(config.opts.cycle_separator_lines),
    tostring(parser.inlinetask_min_level()),
  }, "\0")
end

local function on_bytes(_, bufnr, tick, start_row, _, _, old_rows, _, _, new_rows)
  if not tracked[bufnr] then
    return true
  end
  local c = cache[bufnr]
  if not c or c.late then
    return
  end
  -- the changedtick before the edit: the edit makes it tick + 1
  c.expect = tick + 1
  -- 1-based lines [first, old_last] became [first, new_last]
  local first = start_row + 1
  local old_last, new_last = first + old_rows, first + new_rows
  local delta = new_rows - old_rows
  local levels, n = c.levels, c.n
  if delta ~= 0 then
    table.move(levels, old_last + 1, n + 1, old_last + 1 + delta)
    for i = n + delta + 1, n do
      levels[i] = nil
    end
    c.n = n + delta
  end
  -- a deletion or a new headline can change the line above
  local ds, de = math.max(1, first - 1), new_last
  local d = c.dirty
  if d then
    -- earlier dirty lines, where they are now
    local function map(l)
      if l < first then
        return l
      elseif l > old_last then
        return l + delta
      end
      return new_last
    end
    ds, de = math.min(ds, map(d[1])), math.max(de, map(d[2]))
  end
  c.dirty = { ds, de }
end

local function track(bufnr)
  if tracked[bufnr] then
    return
  end
  tracked[bufnr] = vim.api.nvim_buf_attach(bufnr, false, {
    on_bytes = on_bytes,
    on_reload = function(_, b)
      cache[b] = nil
    end,
    on_detach = function(_, b)
      tracked[b] = nil
      cache[b] = nil
    end,
  }) or nil
end

--- Writing or reading a file resets 'modified', which bumps changedtick
--- without changing the text or reporting anything. Accept that bump when
--- it is the only change since the levels were computed.
local function accept_unchanged_tick(bufnr)
  local c = cache[bufnr]
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  if c and not c.late and c.tick == tick - 1 and c.expect == tick - 1 then
    c.tick, c.expect = tick, tick
  end
end

local function outline_level(line, min_inline)
  if line:byte(1) ~= 42 then
    return nil
  end
  local lvl = parser.headline_level(line)
  if lvl and min_inline and lvl >= min_inline then
    return nil
  end
  return lvl
end

local CHUNK = 256

--- The nearest outline headline at or above `lnum` (1 when there is none).
local function headline_above(bufnr, lnum, min_inline)
  local e = lnum
  while e >= 1 do
    local s = math.max(1, e - CHUNK + 1)
    local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
    for i = #lines, 1, -1 do
      if outline_level(lines[i], min_inline) then
        return s + i - 1
      end
    end
    e = s - 1
  end
  return 1
end

--- The nearest outline headline below `lnum` (the last line when none).
local function headline_below(bufnr, lnum, n, min_inline)
  local s = lnum + 1
  while s <= n do
    local e = math.min(n, s + CHUNK - 1)
    local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
    for i, l in ipairs(lines) do
      if outline_level(l, min_inline) then
        return s + i - 1
      end
    end
    s = e + 1
  end
  return n
end

--- Recompute the levels of the sections around the dirty lines.
local function update(bufnr, c)
  local n = c.n
  local min_inline = parser.inlinetask_min_level()
  local ds = math.max(1, math.min(c.dirty[1], n))
  local de = math.max(ds, math.min(c.dirty[2], n))
  c.dirty = nil
  local hs = headline_above(bufnr, ds, min_inline)
  if hs > 1 and hs >= ds - 1 then
    -- the headline itself may have changed: the blank lines above it
    -- (org-cycle-separator-lines) belong to the previous section
    hs = headline_above(bufnr, hs - 1, min_inline)
  end
  -- up to and including the next headline, whose separator lines are ours
  local he = headline_below(bufnr, de, n, min_inline)
  local part = M.compute(vim.api.nvim_buf_get_lines(bufnr, hs - 1, he, false))
  local levels = c.levels
  for i = hs, he do
    levels[i] = part[i - hs + 1]
  end
end

local function get(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = cache[bufnr]
  if c and c.tick == tick then
    return c
  end
  local sig = signature()
  if
    c
    and not c.late
    and c.expect == tick
    and c.sig == sig
    and tracked[bufnr]
    and c.n == vim.api.nvim_buf_line_count(bufnr)
  then
    if c.dirty then
      update(bufnr, c)
    end
    c.tick = tick
    return c
  end
  track(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local levels, regions = M.compute(lines)
  local fresh = { tick = tick, expect = tick, n = #lines, levels = levels, sig = sig }
  fresh.regions, fresh.regions_tick = regions, tick
  if c and (c.late or c.expect ~= tick) then
    -- a change nothing reported (yet): undo and redo report theirs after
    -- this lookup, for text these levels already reflect. Ignore reports
    -- and recompute everything until the command is done.
    fresh.late = true
    vim.schedule(function()
      if cache[bufnr] == fresh then
        fresh.late, fresh.dirty = nil, nil
        if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_buf_get_changedtick(bufnr) ~= fresh.tick then
          cache[bufnr] = nil
        end
      end
    end)
  end
  cache[bufnr] = fresh
  return fresh
end

--- Fold regions (drawers, blocks, items, ...) of the sections covering
--- lines [s, e] (default: the whole buffer), possibly with others.
---@param s? integer
---@param e? integer
---@return table[] list of {start, end, kind}
local function regions(bufnr, s, e)
  local c = get(bufnr)
  if c.regions_tick == c.tick then
    return c.regions
  end
  local n = c.n
  s, e = math.max(1, s or 1), math.min(n, e or n)
  if s > 1 or e < n then
    -- only the sections around the range, like `update`
    local min_inline = parser.inlinetask_min_level()
    local hs = headline_above(bufnr, s, min_inline)
    local he = headline_below(bufnr, e, n, min_inline)
    if hs > 1 or he < n then
      local _, r = M.compute(vim.api.nvim_buf_get_lines(bufnr, hs - 1, he, false))
      for _, reg in ipairs(r) do
        reg.start = reg.start + hs - 1
        reg["end"] = reg["end"] and reg["end"] + hs - 1
      end
      return r
    end
  end
  local _, r = M.compute(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  c.regions, c.regions_tick = r, c.tick
  return r
end

M._regions = regions

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

-- custom properties hidden by toggle_custom_properties_visibility
local ns_custom = vim.api.nvim_create_namespace("org.custom_properties")

--- Is line `lnum` hidden by a conceal_lines mark?
function M.is_concealed(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and curbuf() or bufnr
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_hide, { lnum - 1, 0 }, { lnum - 1, -1 }, { limit = 1 })
  return #marks > 0
    or #vim.api.nvim_buf_get_extmarks(bufnr, ns_custom, { lnum - 1, 0 }, { lnum - 1, -1 }, { limit = 1 }) > 0
end

--- Hide lines [s, e] (1-based, inclusive).
function M.conceal(bufnr, s, e)
  if not M.conceal_supported then
    return
  end
  bufnr = (bufnr == nil or bufnr == 0) and curbuf() or bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  -- rows hidden already (one query for the range, not one per line)
  local hidden = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns_hide, { s - 1, 0 }, { e - 1, -1 }, {})) do
    hidden[m[2]] = true
  end
  for i, l in ipairs(lines) do
    local row = s + i - 2
    if not hidden[row] then
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
  -- innermost first doesn't matter: drawers don't nest
  for _, r in ipairs(regions(vim.api.nvim_get_current_buf(), s, e)) do
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
  for _, r in ipairs(regions(vim.api.nvim_get_current_buf(), s, e)) do
    if r.kind == "block" and r.start >= s and r["end"] <= e then
      close_at(r.start)
    end
  end
end

--- Open the item folds in [s, e] (the text of an entry shows its lists).
local function open_items(s, e)
  for _, r in ipairs(regions(vim.api.nvim_get_current_buf(), s, e)) do
    if r.kind == "item" and r.start >= s and r.start <= e then
      open_at(r.start)
    end
  end
end

--- Re-fold archived subtrees (`:ARCHIVE:` tag) whose headline is in
--- [s, e], so visibility cycling never opens them
--- (org-cycle-hide-archived-subtrees). Returns true when the headline at
--- `s` itself is archived.
local function hide_archived(s, e, always)
  if not always and (config.opts.cycle_open_archived_trees or M._force_archived) then
    return false
  end
  local self_archived = false
  for _, hl in ipairs(file().headlines) do
    -- (the raw line first: reading `tags` parses the headline)
    if
      hl.line >= s
      and hl.line <= e
      and hl.raw:find(":ARCHIVE:", 1, true)
      and vim.tbl_contains(hl.tags, "ARCHIVE")
      and has_fold(hl)
    then
      close_at(hl.line)
      if hl.line == s then
        self_archived = true
      end
    end
  end
  return self_archived
end

local has_visibility_property

local function hide_archived_all()
  hide_archived(1, vim.api.nvim_buf_line_count(0))
end

--- Fold every subtree tagged :ARCHIVE: (org-fold-hide-archived-subtrees),
--- whatever `cycle_open_archived_trees` says.
function M.hide_archived_subtrees()
  hide_archived(1, vim.api.nvim_buf_line_count(0), true)
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

--- Run the User autocmd `pattern` (OrgCyclePre, org-cycle-pre-hook, or
--- OrgCycle, org-cycle-hook) with the new visibility `state`: "overview",
--- "contents" or "all" after a global change, "folded", "children",
--- "subtree" (or "empty", before only) after a local one.
---@param lnum? integer the headline or item cycled (local cycling)
local function run_cycle_hook(pattern, state, lnum)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = pattern,
    data = { state = state, bufnr = curbuf(), lnum = lnum },
    modeline = false,
  })
end

function M.global_cycle()
  if vim.v.count > 0 then
    show_levels(vim.v.count)
    vim.b.org_global_cycle = "content"
    return
  end
  local state = vim.b.org_global_cycle or "showall"
  if state == "showall" then
    run_cycle_hook("OrgCyclePre", "overview")
    M.overview()
    vim.api.nvim_echo({ { "OVERVIEW" } }, false, {})
    run_cycle_hook("OrgCycle", "overview")
  elseif state == "overview" then
    run_cycle_hook("OrgCyclePre", "contents")
    M.content()
    vim.api.nvim_echo({ { "CONTENTS" } }, false, {})
    run_cycle_hook("OrgCycle", "contents")
  else
    run_cycle_hook("OrgCyclePre", "all")
    show_all_but_drawers()
    vim.api.nvim_echo({ { "SHOW ALL" } }, false, {})
    run_cycle_hook("OrgCycle", "all")
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

--- Change the visibility of the headline at `lnum` in the current window
--- the way org-agenda-show-1 does: 0 folds its subtree (org-fold-subtree),
--- 2 shows its text and child headlines without hiding anything already
--- visible (org-fold-show-entry, org-fold-show-children), 3 its subtree
--- with the drawers folded, 4 everything. Other folds are left alone.
---@param lnum integer
---@param level integer
---@return boolean false when there is no headline at `lnum`
function M.show_level(lnum, level)
  local hl = file():headline_at(lnum)
  if not hl then
    return false
  end
  show_heading_path(hl)
  if level == 0 then
    if has_fold(hl) then
      -- open everything first so that each :foldclose below closes the
      -- fold it names, then close the descendants deepest first: opening
      -- the subtree again later shows its child headlines folded
      pcall(vim.cmd, hl.line .. "," .. hl.end_line .. "foldopen!")
      local desc = {}
      local function walk(h)
        for _, ch in ipairs(h.children) do
          desc[#desc + 1] = ch
          walk(ch)
        end
      end
      walk(hl)
      for i = #desc, 1, -1 do
        if has_fold(desc[i]) then
          close_at(desc[i].line)
        end
      end
      close_at(hl.line)
    end
  elseif level == 2 then
    show_entry(hl)
    for _, ch in ipairs(hl.children) do
      M.unconceal(0, ch.line, ch.line)
    end
    hide_archived(hl.line + 1, hl.end_line)
  elseif level >= 3 then
    pcall(vim.cmd, hl.line .. "," .. hl.end_line .. "foldopen!")
    M.unconceal(0, hl.line, hl.end_line)
    if level == 3 then
      close_drawers(hl.line, hl.end_line)
      hide_archived(hl.line + 1, hl.end_line)
    end
  end
  refresh_ellipsis()
  return true
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
  local skip = config.opts.cycle_skip_children_state_if_no_children ~= false
  local last = last_cycle_status(lnum)
  local hooks = file():headline_at(lnum) ~= nil
  local function hook(pattern, state)
    if hooks then
      run_cycle_hook(pattern, state, lnum)
    end
  end
  if all_hidden_after(lnum, item.end_lnum) and (has_children or not skip) then
    -- CHILDREN: the item text, its sub-items folded
    hook("OrgCyclePre", "children")
    open_at(lnum)
    M.unconceal(0, lnum + 1, item.end_lnum)
    for _, ch in ipairs(item.children) do
      if ch.end_lnum > ch.lnum then
        close_at(ch.lnum)
      end
    end
    vim.api.nvim_echo({ { "CHILDREN" } }, false, {})
    set_last_cycle(lnum, "children")
    hook("OrgCycle", "children")
  elseif (all_hidden_after(lnum, item.end_lnum) and not has_children) or last == "children" then
    local skipped = all_hidden_after(lnum, item.end_lnum) and not has_children
    hook("OrgCyclePre", "subtree")
    pcall(vim.cmd, lnum .. "," .. item.end_lnum .. "foldopen!")
    M.unconceal(0, lnum + 1, item.end_lnum)
    close_drawers(lnum, item.end_lnum)
    vim.api.nvim_echo({ { skipped and "SUBTREE (NO CHILDREN)" or "SUBTREE" } }, false, {})
    set_last_cycle(lnum, "subtree")
    hook("OrgCycle", "subtree")
  else
    hook("OrgCyclePre", "folded")
    close_at(lnum)
    vim.api.nvim_echo({ { "FOLDED" } }, false, {})
    set_last_cycle(lnum, "folded")
    hook("OrgCycle", "folded")
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
  local limit = M.cycle_limit_level()
  while hl and limit and hl.level > limit do
    hl = hl.parent
  end
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

--- org-cycle-hook: image previews on TAB (ui.images.cycle_display), then
--- the OrgCycle User autocmd.
local function cycle_hook(state, hl)
  if (config.opts.ui.images or {}).cycle_display then
    local first_child = hl.children[1] and hl.children[1].line or nil
    pcall(require("org.ui.images").cycle_display, state, hl.line, hl.end_line, first_child)
  end
  run_cycle_hook("OrgCycle", state, hl.line)
end

--- The deepest level cycled as a headline (org-cycle-max-level, else one
--- less than the inline task level), in stars; nil = every level.
function M.cycle_limit_level()
  -- odd_levels_only or the buffer's #+STARTUP: odd / oddeven
  local odd = require("org.structure").odd_levels_only()
  local max = config.opts.cycle_max_level
  if max ~= nil and max ~= false then
    if type(max) ~= "number" or max < 1 or max % 1 ~= 0 then
      error("`cycle_max_level' must be a positive integer", 0)
    end
    return odd and 2 * max - 1 or max
  end
  local min_inline = parser.inlinetask_min_level()
  if min_inline then
    max = min_inline - 1
    return odd and 2 * max - 1 or max
  end
end

--- TAB. With a count: 16 restores the startup visibility, 64 shows
--- everything (drawers too), any other N shows the whole subtree of the
--- ancestor at level N (like C-u C-u TAB, C-u C-u C-u TAB and M-N TAB).
function M.cycle()
  if (config.opts.links or {}).tab_follows_link and require("org.links").link_at_cursor() then
    -- org-tab-follows-link: TAB on a link follows it
    return require("org.context").open_at_point()
  end
  local count = vim.v.count
  if count == 16 then
    return M.set_startup_visibility()
  elseif count == 64 then
    return M.show_everything()
  elseif count > 0 then
    return show_ancestor_subtree(count)
  end
  local limit = M.cycle_limit_level()
  local pos = vim.api.nvim_win_get_cursor(0)
  local lnum = pos[1]
  local line = vim.api.nvim_get_current_line()
  local bufnr = vim.api.nvim_get_current_buf()
  local level = parser.headline_level(line)
  if limit and level and level > limit then
    -- deeper headlines are text for cycling (org-cycle-max-level)
    level = nil
  end
  if config.opts.cycle_global_at_bob and lnum == 1 and pos[2] == 0 and not level then
    -- org-cycle-global-at-bob
    return M.global_cycle()
  end
  for _, r in ipairs(regions(bufnr, lnum, lnum)) do
    if r.start == lnum and r.kind ~= "item" then
      if lnum_closed(lnum) then
        open_at(lnum)
      else
        close_at(lnum)
      end
      return
    end
  end
  if not level then
    if line:match("^[ \t]*[|+]") and require("org.table.el").at(bufnr, lnum) then
      return require("org.table.el").hint()
    end
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
    run_cycle_hook("OrgCyclePre", "empty", lnum)
    vim.api.nvim_echo({ { "EMPTY ENTRY" } }, false, {})
    set_last_cycle(lnum, nil)
    return
  end
  local archived_msg = "Subtree is archived and stays closed (use force_cycle_archived to cycle it)"
  local last = last_cycle_status(lnum)
  local hidden = all_hidden_after(lnum, hl.end_line)
  local children = hl.children
  -- cycle_include_plain_lists = "integrate": list items count as children
  local integrate = config.opts.cycle_include_plain_lists == "integrate"
  local body_lists = integrate and require("org.lists").parse_region(f.lines, hl.line + 1, hl.body_end) or {}
  local has_children = #children > 0 or #body_lists > 0
  if integrate and not has_children then
    for l = hl.line + 1, hl.end_line do
      if require("org.lists").parse_item_line(f.lines[l]) then
        has_children = true
        break
      end
    end
  end
  -- no children: skip the CHILDREN state (org-cycle-skip-children-state-if-no-children)
  local skipped = hidden and not has_children and config.opts.cycle_skip_children_state_if_no_children ~= false
  if hidden and not skipped then
    -- CHILDREN: the entry text and the child headlines, folded
    run_cycle_hook("OrgCyclePre", "children", lnum)
    if limit and hl.level >= limit then
      -- children deeper than cycle_max_level are text: all of it shows
      -- (like Emacs, where they are no headlines for org-fold-show-children)
      pcall(vim.cmd, hl.line .. "," .. hl.end_line .. "foldopen!")
      M.unconceal(0, hl.line + 1, hl.end_line)
      close_drawers(hl.line, hl.end_line)
    else
      open_at(lnum)
      for _, ch in ipairs(children) do
        if has_fold(ch) then
          close_at(ch.line)
        end
      end
      M.unconceal(0, hl.line + 1, hl.end_line)
      open_items(hl.line + 1, hl.body_end)
      -- "integrate": every list shows its top-level items, folded
      for _, list in ipairs(body_lists) do
        for _, it in ipairs(list.items) do
          if it.end_lnum > it.lnum then
            close_at(it.lnum)
          end
        end
      end
      close_drawers(hl.line, hl.body_end)
    end
    refresh_ellipsis()
    set_last_cycle(lnum, "children")
    cycle_hook("children", hl)
    if hide_archived(hl.line, hl.end_line) then
      vim.api.nvim_echo({ { archived_msg } }, false, {})
      return
    end
    vim.api.nvim_echo({ { "CHILDREN" } }, false, {})
    return
  end
  if skipped or last == "children" then
    -- SUBTREE
    run_cycle_hook("OrgCyclePre", "subtree", lnum)
    pcall(vim.cmd, hl.line .. "," .. hl.end_line .. "foldopen!")
    M.unconceal(0, hl.line + 1, hl.end_line)
    close_drawers(hl.line, hl.end_line)
    refresh_ellipsis()
    set_last_cycle(lnum, "subtree")
    cycle_hook("subtree", hl)
    if hide_archived(hl.line, hl.end_line) then
      vim.api.nvim_echo({ { archived_msg } }, false, {})
      return
    end
    vim.api.nvim_echo({ { skipped and "SUBTREE (NO CHILDREN)" or "SUBTREE" } }, false, {})
    return
  end
  -- FOLDED
  run_cycle_hook("OrgCyclePre", "folded", lnum)
  close_at(lnum)
  refresh_ellipsis()
  set_last_cycle(lnum, "folded")
  cycle_hook("folded", hl)
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

--- Hide the text of the entry at the cursor; its child headlines stay as
--- they are (org-fold-hide-entry).
function M.hide_entry()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local f = file()
  local hl = f:headline_at(lnum)
  if not hl then
    -- before the first headline: the text above it
    local first = f.headlines[1]
    if first and first.line > 1 and M.conceal_supported then
      M.conceal(0, 1, first.line - 1)
      vim.api.nvim_win_set_cursor(0, { first.line, 0 })
    end
    return
  end
  if lnum_closed(hl.line) or hl.body_end <= hl.line then
    -- folded already, or no text
    return
  end
  if #hl.children == 0 then
    close_at(hl.line)
  else
    hide_entry(hl)
  end
  if lnum > hl.line then
    vim.api.nvim_win_set_cursor(0, { hl.line, 0 })
  end
  refresh_ellipsis()
end

--- Fold every block of the buffer (org-fold-hide-block-all).
function M.hide_block_all()
  close_blocks(1, vim.api.nvim_buf_line_count(0))
end

--- Fold every drawer of the buffer, or of the lines of the visual
--- selection (org-fold-hide-drawer-all).
function M.hide_drawer_all()
  local s, e = 1, vim.api.nvim_buf_line_count(0)
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    s, _, e = require("org.utils").visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
  close_drawers(s, e)
end

--- The visibility span shown around a location reached in `context`
--- (org-fold-show-context-detail): "agenda", "org-goto", "occur-tree",
--- "tags-tree", "link-search", "mark-goto", "bookmark-jump", "isearch"
--- or "default".
---@param context? string
---@return string
function M.context_detail(context)
  local opt = config.opts.fold_show_context_detail
  if opt == true then
    return "canonical"
  elseif not opt then
    return "minimal"
  elseif type(opt) == "string" then
    return opt
  end
  return (context and opt[context]) or opt.default or "minimal"
end

--- Show the context of line `lnum` for `context`, as set by
--- `fold_show_context_detail` (org-fold-show-context).
function M.show_context_for(lnum, context)
  M.show_context(lnum, M.context_detail(context))
end

--- Make the cursor line visible after a jump in `context` (see
--- `context_detail`), or open the folds around it (`zv`) in a window that
--- doesn't fold like Org.
function M.reveal_cursor(context)
  local ok = vim.wo.foldexpr == "v:lua.require'org.fold'.foldexpr(v:lnum)"
    and pcall(M.show_context_for, vim.api.nvim_win_get_cursor(0)[1], context)
  if not ok then
    pcall(vim.cmd, "normal! zv")
  end
end

--- Show the context of line `lnum` (org-fold-show-set-visibility):
--- `detail` is "minimal", "local", "ancestors", "ancestors-full",
--- "lineage", "tree" or "canonical" (see org-fold-show-context-detail).
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
  if detail == "ancestors-full" then
    -- the whole subtree
    pcall(vim.cmd, hl.line .. "," .. hl.end_line .. "foldopen!")
    M.unconceal(0, hl.line, hl.end_line)
    close_drawers(hl.line, hl.end_line)
  elseif not on_heading or detail == "local" then
    show_entry(hl)
  end
  if detail == "local" then
    -- and the next headline
    local nxt = f:headline_at(hl.body_end + 1)
    if nxt and nxt.line == hl.body_end + 1 then
      show_heading_path(nxt)
    end
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

--- Whether any line of the buffer mentions a VISIBILITY property (reading
--- every entry's properties would parse all of them).
function has_visibility_property(bufnr)
  local f = require("org.files").get_buffer(bufnr)
  return table.concat(f.lines, "\n"):upper():find(":VISIBILITY:", 1, true) ~= nil
end

--- Apply the VISIBILITY property of every headline that has one
--- (org-cycle-set-visibility-according-to-property): `folded`,
--- `children`, `content` or `all`. The headline itself is revealed.
function M.apply_visibility_properties()
  if not has_visibility_property(0) then
    refresh_ellipsis()
    return
  end
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

--- The startup visibility of a buffer (#+STARTUP or startup_folded) and
--- its #+STARTUP words.
local function startup_mode(bufnr)
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
  return mode, startup
end

--- Apply #+STARTUP / startup_folded visibility in the current window,
--- then hide blocks (`hideblocks`), apply VISIBILITY properties, fold
--- archived subtrees and hide drawers (org-cycle-set-startup-visibility).
---@param first? boolean the buffer was just set up, with 'foldlevel' set
--- for its startup visibility already (see `setup_buffer`)
function M.apply_startup(bufnr, first)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local mode, startup = startup_mode(bufnr)
  local levels = tonumber(mode:match("^show(%d)levels$") or "")
  local closed = false
  if first and vim.b[bufnr].org_startup_foldlevel == mode then
    -- 'foldlevel' was set for this mode before 'foldmethod' (zM or zR here
    -- would compute the folds of the whole buffer, and :edit computes
    -- them again once the file is loaded)
    M.clear_hidden()
    vim.b.org_global_cycle = mode == "overview" and "overview" or "showall"
    if mode == "showeverything" then
      return
    end
    closed = true
  elseif mode == "overview" then
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
  if closed then
    -- blocks and drawers are closed with everything else
    hide_archived_all()
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

--- Is line `lnum` hidden: concealed, or inside a closed fold below its
--- first line?
local function line_hidden(lnum)
  return lnum >= 1 and lnum <= vim.api.nvim_buf_line_count(0) and not M.line_visible(lnum)
end

--- org-fold-check-before-invisible-edit: `kind` ("insert", "delete" or
--- "delete-backward") is about to edit at the cursor. When that touches
--- hidden text (the cursor line is hidden, or the edit is at the end of a
--- line followed by hidden lines, or at the start of a line after hidden
--- ones), react as `catch_invisible_edits` says. Returns false when the
--- edit must not happen.
---@param kind "insert"|"delete"|"delete-backward"
---@return boolean
function M.check_invisible_edit(kind)
  local mode = config.opts.catch_invisible_edits
  if not mode then
    return true
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  local lnum, col = pos[1], pos[2]
  local line = vim.api.nvim_get_current_line()
  local here = not M.line_visible(lnum)
  local at = here or (col >= #line and line_hidden(lnum + 1))
  local before = here or (col == 0 and line_hidden(lnum - 1))
  if not (at or before) then
    return true
  end
  local msg = "Edit in invisible region aborted, repeat to confirm with text visible"
  if mode == "error" then
    require("org.utils").warn("Editing in invisible areas is prohibited, make them visible first")
    return false
  end
  local props = package.loaded["org.properties"]
  if props and props.custom_properties_hidden and props.custom_properties_hidden(0) then
    -- the hidden text may be custom properties (org-custom-properties)
    if require("org.utils").confirm("Display invisible properties in this buffer?") then
      props.toggle_custom_properties_visibility()
      if mode == "smart" or mode == "show-and-error" then
        require("org.utils").warn(msg)
        return false
      end
      return true
    end
  end
  M.show_context(lnum, "local")
  if at and col >= #line and lnum < vim.api.nvim_buf_line_count(0) then
    M.show_context(lnum + 1, "local")
  end
  if before and lnum > 1 then
    M.show_context(lnum - 1, "local")
  end
  if mode == "show" then
    require("org.utils").notify("Unfolding invisible region around point before editing")
    return true
  elseif mode == "smart" and at and not before and (kind == "insert" or kind == "delete-backward") then
    require("org.utils").notify("Unfolding invisible region around point before editing")
    return true
  end
  require("org.utils").warn(msg)
  return false
end

--- The kind of edit `command` makes, when `catch_invisible_edits_commands`
--- lists it (org-fold-catch-invisible-edits-commands).
local function edit_kind(command)
  local cmds = config.opts.catch_invisible_edits_commands
  return type(cmds) == "table" and cmds[command] or nil
end

--- Check an action before it runs (see `check_invisible_edit`): false
--- when it must not.
function M.check_invisible_edit_command(command)
  if vim.bo.filetype ~= "org" or not config.opts.catch_invisible_edits then
    return true
  end
  local kind = edit_kind(command)
  if not kind then
    return true
  end
  return M.check_invisible_edit(kind)
end

--- Text typed in Insert mode (the self_insert command).
local function on_insert_char()
  local kind = edit_kind("self_insert")
  if kind and not M.check_invisible_edit(kind) then
    vim.v.char = ""
  end
end

-- <BS>, <Del> and <CR> in Insert mode, checked before Vim runs them
-- (delete_backward_char, delete_char and return).
local key_ns
local insert_keys
local function watch_insert_keys()
  if key_ns then
    return
  end
  insert_keys = {
    [vim.keycode("<BS>")] = "delete_backward_char",
    [vim.keycode("<C-h>")] = "delete_backward_char",
    [vim.keycode("<Del>")] = "delete_char",
    [vim.keycode("<CR>")] = "return",
    [vim.keycode("<C-m>")] = "return",
  }
  key_ns = vim.on_key(function(key)
    local command = insert_keys[key]
    if not command or vim.bo.filetype ~= "org" or not config.opts.catch_invisible_edits then
      return
    end
    local mode = vim.api.nvim_get_mode().mode
    if mode ~= "i" and mode ~= "R" then
      return
    end
    local kind = edit_kind(command)
    if kind then
      local ok, allowed = pcall(M.check_invisible_edit, kind)
      if ok and not allowed then
        return ""
      end
    end
  end, vim.api.nvim_create_namespace("org.fold.keys"))
end

function M.setup_buffer(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local function setup_win(win)
    -- a hidden load (bufload, nvim_buf_call) runs in Vim's autocommand
    -- window: the startup visibility waits for a real window
    if vim.fn.win_gettype(win) == "autocmd" then
      return
    end
    local first = not vim.b[bufnr].org_startup_done
    if first then
      -- Set 'foldlevel' before 'foldmethod' when it alone gives the
      -- startup visibility: the folds are then computed once, as the
      -- file is displayed.
      local mode = startup_mode(bufnr)
      if mode == "overview" and not has_visibility_property(bufnr) then
        vim.wo[win][0].foldlevel = 0
        vim.b[bufnr].org_startup_foldlevel = mode
      elseif mode == "showeverything" then
        -- what zR sets: the deepest fold
        local deepest = 0
        for _, l in pairs(get(bufnr).levels) do
          deepest = math.max(deepest, tonumber(type(l) == "string" and l:sub(2) or l) or 0)
        end
        vim.wo[win][0].foldlevel = deepest
        vim.b[bufnr].org_startup_foldlevel = mode
      end
    end
    set_win_opts(win)
    if first then
      vim.b[bufnr].org_startup_done = true
      vim.api.nvim_win_call(win, function()
        M.apply_startup(bufnr, true)
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
        on_insert_char()
      end,
    })
    watch_insert_keys()
  end
  vim.api.nvim_create_autocmd({ "BufWritePost", "BufEnter" }, {
    buffer = bufnr,
    group = group,
    callback = function()
      accept_unchanged_tick(bufnr)
    end,
  })
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

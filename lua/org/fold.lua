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

-- Blocks whose contents are raw text: nothing folds inside them.
local RAW_BLOCKS = { src = true, example = true, export = true, comment = true, verse = true }

--- The end of the drawer or block starting at line `i` (nil when it has
--- none before line `limit` or a headline).
local function region_end(lines, i, limit, kind, bname)
  local want = kind == "drawer" and 58 or 35
  for j = i + 1, limit do
    local l = lines[j]
    if l:byte(1) == 42 and parser.headline_level(l) then
      return nil
    end
    if
      first_byte(l) == want
      and ((kind == "drawer" and is_drawer_end(l)) or (kind == "block" and is_block_end(l, bname)))
    then
      return j
    end
  end
end

--- The kind of fold region starting at `line`: "drawer" or "block" (with
--- the block name), nil for others.
local function region_start(line)
  local fb = first_byte(line)
  if fb == 58 and is_drawer_start(line) then
    return "drawer"
  elseif fb == 35 then
    local bname = block_start(line)
    if bname then
      return "block", bname
    end
  end
end

--- Give the lines inside the region [s, stop] the level `inner`, and fold
--- the drawers and blocks nested in it one level deeper: a block in a
--- drawer, a drawer or block in a quote, center, special or dynamic block
--- (Emacs folds those on their own too).
local function fill_region(lines, s, stop, inner, kind, bname, levels, regions)
  levels[s] = ">" .. inner
  levels[stop] = "<" .. inner
  regions[#regions + 1] = { start = s, ["end"] = stop, kind = kind }
  local nested = kind == "drawer" or not RAW_BLOCKS[bname]
  local j = s + 1
  while j < stop do
    local k, name
    if nested then
      k, name = region_start(lines[j])
      if k == "drawer" and kind == "drawer" then
        -- drawers don't nest
        k = nil
      end
    end
    local e = k and region_end(lines, j, stop - 1, k, name)
    if e and e > j then
      fill_region(lines, j, e, inner + 1, k, name, levels, regions)
      j = e + 1
    else
      levels[j] = inner
      j = j + 1
    end
  end
end

--- Compute fold levels for all lines. The fold level of a headline is its
--- depth in the outline, not its number of stars: `*** C` right under
--- `* A` folds at level 2, so that no fold of its own (level 2, then 3)
--- holds its siblings.
---@param lines string[]
---@param stack? integer[] the stars of the headlines containing `lines[1]`
--- (outermost first)
---@param at_eof? boolean whether `lines` ends the buffer (default true)
---@return table levels
---@return table regions list of {start, end, kind}
---@return table stars line -> stars of each outline headline
function M.compute(lines, stack, at_eof)
  local levels, regions, stars = {}, {}, {}
  stack = stack and vim.list_slice(stack) or {}
  local cur = #stack
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
      while #stack > 0 and stack[#stack] >= lvl do
        stack[#stack] = nil
      end
      stack[#stack + 1] = lvl
      cur = #stack
      stars[i] = lvl
      levels[i] = ">" .. cur
      i = i + 1
    else
      local base = cur + (depth[i] or 0)
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
      else
        local kind, bname = region_start(line)
        local stop = kind and region_end(lines, i, n, kind, bname)
        if stop and stop > i then
          fill_region(lines, i, stop, base + 1, kind, bname, levels, regions)
          i = stop + 1
        else
          levels[i] = item_start[i] and (">" .. base) or base
          if item_start[i] then
            regions[#regions + 1] = { start = i, kind = "item" }
          end
          i = i + 1
        end
      end
    end
  end
  -- org-cycle-separator-lines: with enough blank lines before a headline,
  -- the last one (all of them when negative) stays visible when the
  -- subtree above is folded
  local sep = config.opts.cycle_separator_lines or 2
  if sep ~= 0 then
    local need = math.abs(sep)
    for l = 2, n do
      local lvl = levels[l]
      if type(lvl) == "string" and lvl:sub(1, 1) == ">" and lines[l]:byte(1) == 42 then
        local k = 0
        while l - 1 - k >= 1 and is_blank(lines[l - 1 - k]) and type(levels[l - 1 - k]) == "number" do
          k = k + 1
        end
        if k >= need then
          local parent = tonumber(lvl:sub(2)) - 1
          for b = l - (sep > 0 and 1 or k), l - 1 do
            levels[b] = parent
          end
        end
      end
    end
  end
  if at_eof ~= false then
    -- blank lines at the end of the file never fold (Emacs never hides
    -- them, org-cycle-show-empty-lines)
    local l = n
    while l >= 1 and is_blank(lines[l]) and type(levels[l]) == "number" do
      levels[l] = 0
      l = l - 1
    end
  end
  return levels, regions, stars
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

-- Neovim skips foldUpdate() while State has MODE_INSERT (Insert and
-- Replace mode, `r` included) for 'foldmethod' expr, so the folds of an
-- edit made there stay as they were (a headline typed in Insert mode gets
-- no fold of its own). Like Neovim's treesitter folding, the rows edited
-- there are kept here and their folds updated once that mode is left.
local stale = {} -- bufnr -> { first, last } (1-based) edited in Insert mode

local function in_insert_state()
  local m = vim.api.nvim_get_mode().mode
  return m:byte(1) == 105 or m:byte(1) == 82 -- "i", "R"
end

local flush_stale

local stale_group = vim.api.nvim_create_augroup("org.fold.stale", { clear = true })

local function schedule_flush(bufnr)
  -- leaving Insert mode (ModeChanged also follows <C-c>, which skips
  -- InsertLeave), or right away for `r`, which never enters Insert mode
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = stale_group,
    callback = function()
      if in_insert_state() then
        return
      end
      for b in pairs(stale) do
        if vim.api.nvim_buf_is_valid(b) then
          flush_stale(b)
        else
          stale[b] = nil
        end
      end
      return true
    end,
  })
  vim.schedule(function()
    if stale[bufnr] and vim.api.nvim_buf_is_valid(bufnr) and not in_insert_state() then
      flush_stale(bufnr)
    end
  end)
end

local function note_stale(bufnr, first, last)
  local s = stale[bufnr]
  if s then
    s[1], s[2] = math.min(s[1], first), math.max(s[2], last)
    return
  end
  stale[bufnr] = { first, last }
  schedule_flush(bufnr)
end

--- The stars of line `line` when it is an outline headline.
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

local function on_bytes(_, bufnr, tick, start_row, start_col, _, old_rows, old_col, _, new_rows, new_col)
  if not tracked[bufnr] then
    return true
  end
  if in_insert_state() then
    note_stale(bufnr, start_row + 1, start_row + 1 + new_rows)
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
  local levels, stars, n = c.levels, c.stars, c.n
  -- The fewest stars of a headline the edit removed, added or changed:
  -- the depth of the headlines after it can change down to the next one
  -- with as few stars (see `update`).
  local min_inline = parser.inlinetask_min_level()
  local mstars = c.mstars or math.huge
  local new_lines = vim.api.nvim_buf_get_lines(
    bufnr,
    start_row,
    start_row + new_rows + ((new_col > 0 or new_rows == 0) and 1 or 0),
    false
  )
  if old_rows == 0 and new_rows == 0 then
    -- within one line: only a change of its stars counts
    local now = new_lines[1] and outline_level(new_lines[1], min_inline)
    if now ~= stars[first] then
      mstars = math.min(mstars, now or math.huge, stars[first] or math.huge)
    end
  else
    local last_old = old_last - ((old_col == 0 and old_rows > 0 and start_col == 0) and 1 or 0)
    for l = first, math.min(last_old, n) do
      if stars[l] then
        mstars = math.min(mstars, stars[l])
      end
    end
    for _, l in ipairs(new_lines) do
      local s = outline_level(l, min_inline)
      if s then
        mstars = math.min(mstars, s)
      end
    end
  end
  c.mstars = mstars < math.huge and mstars or nil
  if delta ~= 0 then
    table.move(levels, old_last + 1, n + 1, old_last + 1 + delta)
    table.move(stars, old_last + 1, n + 1, old_last + 1 + delta)
    for i = n + delta + 1, n do
      levels[i] = nil
      stars[i] = nil
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

--- The stars of the headlines containing line `l` (outermost first),
--- from the cached stars of the lines above it.
local function stack_at(c, l)
  local st, lim = {}, math.huge
  local stars = c.stars
  for i = l - 1, 1, -1 do
    local s = stars[i]
    if s and s < lim then
      st[#st + 1] = s
      lim = s
      if s <= 1 then
        break
      end
    end
  end
  local out = {}
  for i = #st, 1, -1 do
    out[#out + 1] = st[i]
  end
  return out
end

--- Recompute the levels of the sections around the dirty lines.
local function update(bufnr, c)
  local n = c.n
  local min_inline = parser.inlinetask_min_level()
  local ds = math.max(1, math.min(c.dirty[1], n))
  local de = math.max(ds, math.min(c.dirty[2], n))
  local mstars = c.mstars
  c.dirty, c.mstars = nil, nil
  local hs = headline_above(bufnr, ds, min_inline)
  if hs > 1 and hs >= ds - 1 then
    -- the headline itself may have changed: the blank lines above it
    -- (org-cycle-separator-lines) belong to the previous section
    hs = headline_above(bufnr, hs - 1, min_inline)
  end
  -- up to and including the next headline, whose separator lines are ours
  local he = headline_below(bufnr, de, n, min_inline)
  if mstars then
    -- A headline with `mstars` stars changed: the headlines after it may
    -- now have another parent, up to the next one with as few stars,
    -- whose depth and parents are those of the headlines before the edit.
    while he < n do
      local s = outline_level(vim.api.nvim_buf_get_lines(bufnr, he - 1, he, false)[1], min_inline)
      if s and s <= mstars then
        break
      end
      he = headline_below(bufnr, he, n, min_inline)
    end
  end
  local part, _, pstars = M.compute(vim.api.nvim_buf_get_lines(bufnr, hs - 1, he, false), stack_at(c, hs), he >= n)
  local levels, stars = c.levels, c.stars
  for i = hs, he do
    levels[i] = part[i - hs + 1]
    stars[i] = pstars[i - hs + 1]
  end
  if stale[bufnr] then
    -- the folds to update once Insert mode is left
    local r = c.recomputed
    c.recomputed = r and { math.min(r[1], hs), math.max(r[2], he) } or { hs, he }
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
  local levels, regions, stars = M.compute(lines)
  local fresh = { tick = tick, expect = tick, n = #lines, levels = levels, stars = stars, sig = sig }
  if stale[bufnr] then
    fresh.recomputed = { 1, #lines }
  end
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

flush_stale = function(bufnr)
  local s = stale[bufnr]
  if not s then
    return
  end
  local c = get(bufnr)
  stale[bufnr] = nil
  local r = c.recomputed or s
  c.recomputed = nil
  local first = math.max(1, math.min(s[1], r[1]))
  local last = math.min(c.n, math.max(s[2], r[2]))
  if not vim._foldupdate then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.wo[win].foldmethod == "expr" then
      pcall(vim._foldupdate, win, first - 1, last)
    end
  end
end

--- Recompute the fold levels of `bufnr` after its settings changed
--- (C-c C-c on a `#+` line), keeping the folds that are open or closed
--- as they are, like Emacs (org-save-outline-visibility); `zx` would reset
--- them all to 'foldlevel'.
function M.refresh(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  cache[bufnr] = nil
  local n = vim.api.nvim_buf_line_count(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.wo[win].foldmethod == "expr" then
      if vim._foldupdate then
        pcall(vim._foldupdate, win, 0, n)
      else
        vim.api.nvim_win_call(win, function()
          vim.cmd("normal! zx")
        end)
      end
    end
  end
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
      local _, r = M.compute(vim.api.nvim_buf_get_lines(bufnr, hs - 1, he, false), nil, he >= n)
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

--- The rows (0-based) in [s, e] hidden by a conceal_lines mark. A mark
--- whose line was replaced is invalid and hides nothing.
local function hidden_rows(bufnr, s, e)
  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns_hide, { s, 0 }, { e, -1 }, { details = true })) do
    if not m[4].invalid then
      rows[m[2]] = true
    end
  end
  return rows
end

--- Is line `lnum` hidden by a conceal_lines mark?
function M.is_concealed(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and curbuf() or bufnr
  return hidden_rows(bufnr, lnum - 1, lnum - 1)[lnum - 1] ~= nil
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
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns_hide, { s - 1, 0 }, { e - 1, -1 }, { details = true })) do
    if m[4].invalid then
      vim.api.nvim_buf_del_extmark(bufnr, ns_hide, m[1])
    else
      hidden[m[2]] = true
    end
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

---------------------------------------------------------------------------
-- Ellipsis
---------------------------------------------------------------------------

-- 'foldtext' is empty, so Neovim draws a closed fold's first line as it
-- draws it open, with its syntax groups and concealed text: a folded heading
-- keeps the faces of its TODO keyword, tags, links... as in Emacs, where
-- folding only hides the text after it. The ellipsis after it, and after
-- a heading whose text is hidden while its fold is open (Emacs shows "..."
-- wherever invisible text follows a heading), is an inline mark at the end
-- of the line (eol marks aren't drawn on a closed fold, and start one cell
-- after the line). The marks live in a namespace scoped to the window,
-- since folds are per window: each redraw compares them with the folds
-- and hidden lines on screen and moves them when they differ, so they
-- can't outlive what they stand for.
local closed_ns = {} -- winid -> namespace

local function win_ns(win)
  local ns = closed_ns[win]
  if not ns then
    ns = vim.api.nvim_create_namespace("org.fold.closed." .. win)
    closed_ns[win] = ns
    if vim.api.nvim__ns_set then
      pcall(vim.api.nvim__ns_set, ns, { wins = { win } })
    end
  end
  return ns
end

local function uses_empty_foldtext(win, buf)
  return vim.bo[buf].filetype == "org"
    and vim.wo[win].foldtext == ""
    and vim.wo[win].foldexpr == "v:lua.require'org.fold'.foldexpr(v:lnum)"
end

--- Whether the line `line` is an outline heading (inline tasks included).
local function is_heading(line)
  return line:byte(1) == 42 and parser.headline_level(line) ~= nil
end

--- The ellipsis marks rows [top, bot] (0-based) of `win` need: for the
--- closed folds and the headings followed by hidden lines, as
--- "row:col:wincol" keys (wincol -1 for an inline mark at col).
local function ellipsis_rows(win, buf, top, bot)
  local rows = {}
  local hidden = hidden_rows(buf, top, bot + 1)
  local columns = package.loaded["org.columns"]
  local overlay = columns and columns.overlay_lines and columns.overlay_lines(buf) or nil
  local leftcol = 0
  vim.api.nvim_win_call(win, function()
    if not vim.wo[win].wrap then
      leftcol = vim.fn.winsaveview().leftcol
    end
    local function add(l, line)
      local r = overlay and overlay[l]
      if r then
        -- a column view row: after the row, like Emacs
        rows[(l - 1) .. ":0:" .. (columns.overlay_width and columns.overlay_width(buf, l) or 0)] = true
      elseif leftcol == 0 or vim.fn.strdisplaywidth(line) > leftcol then
        -- (a line scrolled out of view shows no ellipsis: Neovim would
        -- draw it in the first column of a closed fold)
        rows[(l - 1) .. ":" .. #line .. ":-1"] = true
      end
    end
    local l = top + 1
    while l <= bot + 1 do
      local fc = vim.fn.foldclosed(l)
      if fc == -1 then
        if hidden[l] and not hidden[l - 1] then
          local line = vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ""
          if is_heading(line) then
            add(l, line)
          end
        end
        l = l + 1
      else
        if fc == l and not hidden[l - 1] then
          add(l, vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or "")
        end
        l = vim.fn.foldclosedend(l) + 1
      end
    end
  end)
  return rows
end

local function marked_rows(buf, ns, top, bot)
  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { top, 0 }, { bot, -1 }, { details = true })) do
    rows[m[2] .. ":" .. m[3] .. ":" .. (m[4].virt_text_win_col or -1)] = m[1]
  end
  return rows
end

local function same_keys(a, b)
  for k in pairs(a) do
    if b[k] == nil then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

local function sync_closed(win, buf, top, bot)
  if not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  if vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end
  local ns = win_ns(win)
  if not uses_empty_foldtext(win, buf) then
    -- a window that stopped folding like Org ('foldtext' or 'filetype'
    -- changed) keeps no ellipsis
    if #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { limit = 1 }) > 0 then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      vim.cmd("redraw")
    end
    return
  end
  local want, have = ellipsis_rows(win, buf, top, bot), marked_rows(buf, ns, top, bot)
  if same_keys(want, have) then
    return
  end
  for key, id in pairs(have) do
    if not want[key] then
      vim.api.nvim_buf_del_extmark(buf, ns, id)
    end
  end
  for key in pairs(want) do
    if not have[key] then
      local row, col, wincol = key:match("^(%d+):(%d+):(%-?%d+)$")
      local opts = { virt_text = { { ellipsis(), "Comment" } }, undo_restore = false }
      if wincol == "-1" then
        opts.virt_text_pos = "inline"
      else
        opts.virt_text_win_col = tonumber(wincol)
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, tonumber(row), tonumber(col), opts)
    end
  end
  vim.cmd("redraw")
end
M._sync_closed = sync_closed

--- Put the ellipsis after headlines whose text is hidden while the fold
--- is open, in a window that doesn't draw it itself (see above: a
--- 'foldtext' of its own).
local function refresh_ellipsis()
  local bufnr = curbuf()
  vim.api.nvim_buf_clear_namespace(bufnr, ns_ellipsis, 0, -1)
  if not M.conceal_supported or uses_empty_foldtext(vim.api.nvim_get_current_win(), bufnr) then
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

local pending = {}
vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace("org.fold.closed"), {
  on_win = function(_, win, buf, top, bot)
    if pending[win] then
      return false
    end
    local stale
    if uses_empty_foldtext(win, buf) then
      stale = not same_keys(ellipsis_rows(win, buf, top, bot), marked_rows(buf, win_ns(win), top, bot))
    else
      local ns = closed_ns[win]
      stale = ns ~= nil and #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { limit = 1 }) > 0
    end
    if stale then
      -- marks can't change while the window is being drawn
      pending[win] = true
      vim.schedule(function()
        pending[win] = nil
        sync_closed(win, buf, top, bot)
      end)
    end
    return false
  end,
})

vim.api.nvim_create_autocmd("WinClosed", {
  group = vim.api.nvim_create_augroup("org.fold.closed", { clear = true }),
  callback = function(args)
    local win = tonumber(args.match)
    local ns = win and closed_ns[win]
    if ns then
      closed_ns[win] = nil
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
          vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
        end
      end
    end
  end,
})

---------------------------------------------------------------------------
-- Window helpers
---------------------------------------------------------------------------

local function set_win_opts(win)
  local wo = vim.wo[win][0]
  wo.foldmethod = "expr"
  wo.foldexpr = "v:lua.require'org.fold'.foldexpr(v:lnum)"
  -- empty: the line as drawn open, with an ellipsis mark (see "Ellipsis")
  wo.foldtext = ""
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

--- Open the folds of lines [s, e] except those of drawers, blocks and
--- `#+RESULTS`, which keep their state: Emacs shows a subtree
--- (org-fold-show-subtree, SUBTREE) by revealing its outline only, so
--- `hideblocks` blocks and folded drawers stay folded.
local function open_outline(s, e)
  local keep = {}
  for _, r in ipairs(regions(vim.api.nvim_get_current_buf(), s, e)) do
    if r.kind == "block" or r.kind == "results" or r.kind == "drawer" then
      keep[r.start] = true
    end
  end
  if next(keep) == nil then
    pcall(vim.cmd, s .. "," .. e .. "foldopen!")
    return
  end
  local l = s
  while l <= e do
    local fc = vim.fn.foldclosed(l)
    if fc == -1 then
      l = l + 1
    elseif keep[fc] then
      l = vim.fn.foldclosedend(l) + 1
    else
      -- one level at a time, so that a closed block inside stays closed
      local tries = 0
      while vim.fn.foldclosed(l) == fc and tries < 100 do
        pcall(vim.cmd, l .. "foldopen")
        tries = tries + 1
      end
      if vim.fn.foldclosed(l) == fc then
        l = vim.fn.foldclosedend(l) + 1
      end
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

---------------------------------------------------------------------------
-- Global visibility
---------------------------------------------------------------------------

-- Emacs folds the outline, drawers and blocks separately: hiding the
-- outline (OVERVIEW, CONTENTS) leaves a drawer or block as it was, so it
-- shows the same once its entry is shown again. Vim folds nest instead,
-- and the state of a fold inside a closed one can't be read. The states
-- are read while visible and kept here, with an extmark at each start.
local ns_state = vim.api.nvim_create_namespace("org.fold.state")
local region_closed = {} -- bufnr -> { [extmark id] = closed }

local KEEPS_STATE = { drawer = true, block = true, results = true }

--- Whether drawers and blocks are folded when nothing says otherwise:
--- `hidedrawers` and `hideblocks` (#+STARTUP or their options).
local function default_closed(bufnr)
  local _, startup = startup_mode(bufnr)
  return {
    drawer = startup_flag(startup, "hidedrawers", "nohidedrawers", config.opts.hide_drawer_startup ~= false),
    block = startup_flag(startup, "hideblocks", "nohideblocks", config.opts.hide_block_startup) and true or false,
    results = false,
  }
end

--- Whether each drawer, block and result of `regs` is folded (by start
--- line): as shown when it is visible, else as last recorded.
---@param fresh? boolean ignore the current folds (startup)
local function region_states(bufnr, regs, fresh)
  local defaults = default_closed(bufnr)
  local known = {}
  local mem = region_closed[bufnr] or {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns_state, 0, -1, {})) do
    if mem[m[1]] ~= nil then
      known[m[2] + 1] = mem[m[1]]
    end
  end
  local states = {}
  for _, r in ipairs(regs) do
    if KEEPS_STATE[r.kind] then
      local fc = not fresh and vim.fn.foldclosed(r.start)
      if fc == -1 then
        states[r.start] = false
      elseif fc == r.start then
        states[r.start] = true
      elseif not fresh and known[r.start] ~= nil then
        states[r.start] = known[r.start]
      else
        states[r.start] = defaults[r.kind]
      end
    end
  end
  return states
end

local function record_states(bufnr, states)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_state, 0, -1)
  local mem = {}
  for lnum, closed in pairs(states) do
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_state, lnum - 1, 0, {})
    if ok then
      mem[id] = closed
    end
  end
  region_closed[bufnr] = mem
end

--- Record that the drawer or block at `lnum` was folded or unfolded.
local function record_state(bufnr, lnum, closed)
  local mem = region_closed[bufnr]
  if not mem then
    mem = {}
    region_closed[bufnr] = mem
  end
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_state, { lnum - 1, 0 }, { lnum - 1, -1 }, {})
  if marks[1] then
    mem[marks[1][1]] = closed
    return
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_state, lnum - 1, 0, {})
  if ok then
    mem[id] = closed
  end
end

--- Fold the outline of the buffer (every headline, item and inline task),
--- leaving each drawer, block and result as it was (see `region_states`).
---@param fresh? boolean the buffer was just loaded: drawers and blocks are
--- as `hidedrawers` and `hideblocks` say
local function hide_outline(fresh)
  local bufnr = curbuf()
  local regs = regions(bufnr)
  local states = region_states(bufnr, regs, fresh)
  record_states(bufnr, states)
  local open = false
  for _, closed in pairs(states) do
    if not closed then
      open = true
      break
    end
  end
  if not open then
    vim.cmd("normal! zM")
    return
  end
  -- everything open, then close the folds to close from the last one up:
  -- each :foldclose then closes the fold starting on its line
  vim.cmd("normal! zR")
  local starts = {}
  for _, hl in ipairs(file().headlines) do
    if has_fold(hl) then
      starts[#starts + 1] = hl.line
    end
  end
  for _, r in ipairs(regs) do
    -- (items stay open: whatever shows an entry opens its items)
    if r.kind == "inlinetask" or states[r.start] then
      starts[#starts + 1] = r.start
    end
  end
  table.sort(starts)
  local prev
  for i = #starts, 1, -1 do
    local l = starts[i]
    if l ~= prev and vim.fn.foldclosed(l) == -1 and vim.fn.foldlevel(l) > 0 then
      pcall(vim.cmd, l .. "foldclose")
    end
    prev = l
  end
end

---@param fresh? boolean (see `hide_outline`)
function M.overview(fresh)
  M.clear_hidden()
  hide_outline(fresh)
  vim.b.org_global_cycle = "overview"
end

--- The inline tasks in the text of `hl` (the lines of their headlines).
local function inline_tasks(hl)
  local min_inline = parser.inlinetask_min_level()
  if not min_inline or hl.body_end <= hl.line then
    return {}
  end
  local out = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, hl.line, hl.body_end, false)) do
    local lv = l:byte(1) == 42 and parser.headline_level(l)
    if lv and lv >= min_inline and not l:match("^%*+%s+END%s*$") then
      out[#out + 1] = hl.line + i
    end
  end
  return out
end

--- How many blank lines before the headline after line `last` stay
--- visible when the text above it is hidden (org-cycle-separator-lines,
--- see org-cycle-show-empty-lines): the last one, or all of them when the
--- option is negative, if there are enough.
local function separator_lines(last)
  local sep = config.opts.cycle_separator_lines or 2
  if sep == 0 or last >= vim.api.nvim_buf_line_count(0) then
    return 0
  end
  local nxt = vim.api.nvim_buf_get_lines(0, last, last + 1, false)[1] or ""
  if not (nxt:byte(1) == 42 and parser.headline_level(nxt)) then
    return 0
  end
  local k = 0
  while last - k >= 1 and is_blank(vim.api.nvim_buf_get_lines(0, last - k - 1, last - k, false)[1]) do
    k = k + 1
  end
  if k < math.abs(sep) then
    return 0
  end
  return sep > 0 and 1 or k
end

--- Hide the text of `hl` like org-cycle-content: the separator lines
--- before its first child stay visible, and so do its inline tasks,
--- folded (org-inlinetask-hide-tasks).
local function hide_entry_contents(hl)
  if hl.body_end <= hl.line then
    return
  end
  local last = hl.body_end - separator_lines(hl.body_end)
  if last > hl.line then
    M.conceal(0, hl.line + 1, last)
  end
  for _, l in ipairs(inline_tasks(hl)) do
    M.unconceal(0, l, l)
    for _, r in ipairs(regions(curbuf(), l, l)) do
      if r.kind == "inlinetask" and r.start == l then
        close_at(l)
      end
    end
  end
end

--- Show the headlines with up to `level` stars without their text
--- (org-cycle-content): CONTENTS, and #+STARTUP: showNlevels.
---@param fresh? boolean (see `hide_outline`)
local function show_levels(level, fresh)
  M.clear_hidden()
  hide_outline(fresh)
  -- parents come first, so each fold opened here is visible
  for _, hl in ipairs(file().headlines) do
    if hl.level < level and has_fold(hl) then
      local shown = false
      for _, ch in ipairs(hl.children) do
        if ch.level <= level then
          shown = true
        end
      end
      if shown or #inline_tasks(hl) > 0 then
        open_at(hl.line)
        hide_entry_contents(hl)
        for _, ch in ipairs(hl.children) do
          if ch.level > level then
            -- under a skipped level: deeper than shown
            M.conceal(0, ch.line, ch.line)
          end
        end
      end
    end
  end
  hide_archived_all()
  refresh_ellipsis()
end

---@param fresh? boolean (see `hide_outline`)
function M.content(fresh)
  show_levels(math.huge, fresh)
  vim.b.org_global_cycle = "content"
end

function M.show_all()
  M.clear_hidden()
  vim.cmd("normal! zR")
  vim.b.org_global_cycle = "showall"
end

--- Every headline and block shown, drawers as they were (Emacs "showall",
--- org-fold-show-all '(headings blocks)).
local function show_all_but_drawers()
  local bufnr = curbuf()
  local regs = regions(bufnr)
  local states = region_states(bufnr, regs)
  M.clear_hidden()
  vim.cmd("normal! zR")
  for i = #regs, 1, -1 do
    local r = regs[i]
    if r.kind == "drawer" and states[r.start] then
      close_at(r.start)
    end
  end
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

--- Where the cursor shows: the start of the closed fold holding it, else
--- the nearest visible line above it (the text Vim and `on_cursor_moved`
--- would move it to).
local function shown_lnum(lnum)
  local fc = vim.fn.foldclosed(lnum)
  if fc ~= -1 then
    return fc
  end
  local l = lnum
  while l > 1 and not M.line_visible(l) do
    l = l - 1
    fc = vim.fn.foldclosed(l)
    if fc ~= -1 then
      return fc
    end
  end
  return l
end

--- Remember the global cycle just done (Emacs checks `last-command`): the
--- cursor goes where it shows, so that nothing moves it before the next
--- command.
local function set_last_global()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local shown = shown_lnum(lnum)
  if shown ~= lnum then
    vim.api.nvim_win_set_cursor(0, { shown, 0 })
  end
  vim.w.org_last_global = { buf = curbuf(), tick = vim.api.nvim_buf_get_changedtick(0), lnum = shown }
end

--- Whether the last command in this window was a global cycle.
local function last_was_global()
  local s = vim.w.org_last_global
  return s ~= nil
    and s.buf == curbuf()
    and s.tick == vim.api.nvim_buf_get_changedtick(0)
    and s.lnum == vim.api.nvim_win_get_cursor(0)[1]
end

function M.global_cycle()
  if vim.v.count > 0 then
    show_levels(vim.v.count)
    vim.b.org_global_cycle = "content"
    return
  end
  -- CONTENTS and SHOW ALL only right after the previous state; any other
  -- command in between starts again from OVERVIEW (org-cycle-internal-global)
  local state = last_was_global() and vim.b.org_global_cycle or "showall"
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
  set_last_global()
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
  open_outline(hl.line, hl.end_line)
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
    open_outline(lnum, item.end_lnum)
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
      record_state(bufnr, lnum, lnum_closed(lnum))
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
      open_outline(hl.line, hl.end_line)
      M.unconceal(0, hl.line + 1, hl.end_line)
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
      -- drawers stay as they are: Emacs cycling reveals the outline only
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
    open_outline(hl.line, hl.end_line)
    M.unconceal(0, hl.line + 1, hl.end_line)
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

--- Hide the subtree of `hl` (org-fold-hide-subtree), then show its
--- headlines down to `depth` levels below it (org-fold-show-children):
--- their text and that of `hl` stay hidden.
local function show_descendants(hl, depth)
  show_heading_path(hl)
  if #hl.children == 0 then
    if has_fold(hl) then
      close_at(hl.line)
    end
    refresh_ellipsis()
    return
  end
  if lnum_closed(hl.line) then
    open_hidden(hl)
  else
    hide_entry(hl)
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

--- Show all headlines of the current subtree, without their text, and
--- fold its archived subtrees (org-kill-note-or-show-branches outside
--- capture).
function M.show_branches()
  local hl = headline_at_cursor()
  if not hl then
    return false
  end
  show_descendants(hl, math.huge)
  hide_archived(hl.line, hl.end_line, true)
  refresh_ellipsis()
end

--- Show the direct children of the current headline, folded, its text
--- hidden (org-ctrl-c-tab outside tables). With a count N, show N levels.
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
    require("org.utils").exit_visual()
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
    open_outline(top.line, top.end_line)
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
    require("org.utils").exit_visual()
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
        -- every headline of the subtree, no text (org-fold-subtree, then
        -- org-cycle-content): a headline without children stays folded
        if #hl.children == 0 then
          close_at(hl.line)
        end
        local function walk(h)
          if #h.children > 0 then
            open_at(h.line)
            hide_entry_contents(h)
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
        open_outline(hl.line, hl.end_line)
        M.unconceal(0, hl.line, hl.end_line)
        close_drawers(hl.line, hl.end_line)
      end
    end
  end
  vim.api.nvim_win_set_cursor(0, pos)
  refresh_ellipsis()
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
    M.overview(true)
  elseif mode == "content" then
    M.content(true)
  elseif levels then
    show_levels(levels, true)
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
    -- blocks and drawers were closed with everything else: open those
    -- that `hideblocks` and `hidedrawers` leave open
    local states = region_states(bufnr, regions(bufnr), true)
    local open = false
    for _, c in pairs(states) do
      open = open or not c
    end
    if open then
      hide_outline(true)
    else
      record_states(bufnr, states)
    end
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

-- The keys typed since the cursor last moved: a move to the next line
-- is a line motion (j, k, ...) unless they hold a jump (a search, a mark,
-- G, an Ex command, ...), which must show the line it lands on.
local recent_keys = ""
local motion_ns

local function watch_motion_keys()
  if motion_ns then
    return
  end
  -- (only typed keys: those of :normal in a function are no motion)
  motion_ns = vim.on_key(function(_, typed)
    if typed and typed ~= "" then
      recent_keys = (recent_keys .. typed):sub(-64)
    end
  end, vim.api.nvim_create_namespace("org.fold.motion"))
end

--- Whether the cursor got where it is by a jump: keys holding one, or no
--- key at all (a function moved it: search(), a plugin...).
local function jumped()
  local keys = recent_keys
  recent_keys = ""
  if keys == "" then
    return true
  end
  -- (special keys are three bytes from K_SPECIAL, 0x80: <Down>, <Up>...)
  local s = keys:gsub("\128..", "")
  return s:find("[/?nN*#%%GHML'`:{}()\15]") ~= nil or s:find("gg", 1, true) ~= nil or s:find("[%[%]][%[%]]") ~= nil
end

--- Keep the cursor off hidden lines: line motions skip them, other jumps
--- reveal the line (Emacs never leaves point in invisible text).
local function on_cursor_moved(bufnr)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local prev = vim.w.org_prev_lnum or lnum
  vim.w.org_prev_lnum = lnum
  local jump = jumped()
  if not M.is_concealed(bufnr, lnum) then
    return
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  local dir = lnum >= prev and 1 or -1
  if math.abs(lnum - prev) <= 1 and not jump then
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
    watch_motion_keys()
  end
  vim.api.nvim_create_autocmd({ "BufWritePost", "BufEnter" }, {
    buffer = bufnr,
    group = group,
    callback = function()
      accept_unchanged_tick(bufnr)
    end,
  })
  -- :edit re-reads the file (Emacs revert-buffer re-runs org-mode): its
  -- startup visibility applies again, from the #+STARTUP: line on disk
  vim.api.nvim_create_autocmd("BufReadPre", {
    buffer = bufnr,
    group = group,
    callback = function()
      vim.b[bufnr].org_startup_done = nil
      vim.b[bufnr].org_startup_foldlevel = nil
      -- the reload would move the marks of the old visibility (hidden
      -- lines, ellipses, fold states) onto other rows
      M.clear_hidden(bufnr)
      vim.api.nvim_buf_clear_namespace(bufnr, ns_state, 0, -1)
      for _, ns in pairs(closed_ns) do
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      end
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

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
---
--- This file holds the fold levels ('foldexpr' and its per-buffer cache,
--- the hot path) and loads the rest from org/fold/:
---
---   fold/hidden.lua    hidden lines (conceal_lines) and the ellipsis
---   fold/helpers.lua   opening and closing folds, archived subtrees,
---                      showing entries, startup mode
---   fold/global.lua    global visibility (S-TAB)
---   fold/cycle.lua     local cycling (TAB), show_level
---   fold/commands.lua  show_branches, show_children, reveal, ...
---   fold/setup.lua     startup visibility, VISIBILITY properties,
---                      invisible edits, setup_buffer
---   fold/shared.lua    private table of the locals the parts share
---
--- Every function is a field of this module, as before the split.

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

-- Neovim re-evaluates 'foldexpr' only around the lines an edit changed,
-- but the levels of other lines can change with them (deleting a block's
-- end line unfolds the block, removing a headline changes the depth of
-- the next ones), and their folds would stay as they were: TAB on such a
-- headline then says FOLDED and hides nothing. Like Neovim's treesitter
-- folding, the rows edited are kept here and, once the edit is done, the
-- folds of the rows whose levels changed are updated (`flush_stale`).
-- Neovim also skips foldUpdate() while State has MODE_INSERT (Insert and
-- Replace mode, `r` included), so the update after an edit made there
-- waits until that mode is left (a headline typed in Insert mode gets its
-- own fold then).
local stale = {} -- bufnr -> { first, last } (1-based) edited, folds not updated

local function in_insert_state()
  local m = vim.api.nvim_get_mode().mode
  return m:byte(1) == 105 or m:byte(1) == 82 -- "i", "R"
end

local flush_stale

local stale_group = vim.api.nvim_create_augroup("org.fold.stale", { clear = true })

local waiting -- a ModeChanged autocommand waits for Insert mode to end

--- Update the folds of the edited buffers once Insert mode is left
--- (ModeChanged also follows <C-c>, which skips InsertLeave).
local function flush_after_insert()
  if waiting then
    return
  end
  waiting = vim.api.nvim_create_autocmd("ModeChanged", {
    group = stale_group,
    callback = function()
      if in_insert_state() then
        return
      end
      waiting = nil
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
end

local function note_stale(bufnr, first, last)
  if in_insert_state() then
    flush_after_insert()
  end
  local s = stale[bufnr]
  if s then
    s[1], s[2] = math.min(s[1], first), math.max(s[2], last)
    return
  end
  stale[bufnr] = { first, last }
  -- once the edit is done (`o` and `r` edit before or without Insert mode)
  vim.schedule(function()
    if not stale[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if in_insert_state() then
      flush_after_insert()
    else
      flush_stale(bufnr)
    end
  end)
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
  note_stale(bufnr, start_row + 1, start_row + 1 + new_rows)
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
  -- the rows whose levels changed, whose folds `flush_stale` updates
  local cs, ce
  for i = hs, he do
    local v = part[i - hs + 1]
    if levels[i] ~= v then
      cs, ce = cs or i, i
    end
    levels[i] = v
    stars[i] = pstars[i - hs + 1]
  end
  if cs then
    local r = c.recomputed
    c.recomputed = r and { math.min(r[1], cs), math.max(r[2], ce) } or { cs, ce }
  end
end

--- The rows of `new` (`n` rows) between the levels it shares with `old`
--- (`o` rows) at its start and at its end, nil when it has all of them.
local function changed_rows(old, o, new, n)
  local p = 0
  while p < o and p < n and old[p + 1] == new[p + 1] do
    p = p + 1
  end
  if p == o and p == n then
    return nil
  end
  local q = 0
  while q < o - p and q < n - p and old[o - q] == new[n - q] do
    q = q + 1
  end
  return { math.min(p + 1, n), math.max(p + 1, n - q) }
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
  if c and not c.dirty and c.sig == sig then
    -- after an undo or a redo: the folds of the rows between the levels
    -- the text before and after it share at its start and at its end
    fresh.recomputed = changed_rows(c.levels, c.n, levels, #lines)
  elseif c or stale[bufnr] then
    fresh.recomputed = { 1, #lines }
  end
  local r, pr = fresh.recomputed, c and c.recomputed
  if pr then
    -- rows not updated yet
    fresh.recomputed = r and { math.min(r[1], pr[1]), math.max(r[2], pr[2]) } or pr
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
        if not vim.api.nvim_buf_is_valid(bufnr) then
          cache[bufnr] = nil
        elseif vim.api.nvim_buf_get_changedtick(bufnr) ~= fresh.tick then
          -- recompute on the next lookup; these levels tell which changed
          fresh.expect = nil
        end
      end
    end)
  end
  cache[bufnr] = fresh
  return fresh
end

--- The numeric level of a 'foldexpr' value.
local function numeric(v)
  if type(v) == "number" then
    return v
  end
  return #v == 2 and v:byte(2) - 48 or tonumber(v:sub(2))
end

--- The last rows of the folds around row `l`, innermost first.
local function fold_ends(levels, n, l)
  local ends = {}
  local depth = numeric(levels[l] or 0)
  for i = l + 1, n do
    local v = levels[i]
    -- the folds this row ends: those from level `j` on
    local j = numeric(v) + 1
    if type(v) == "string" and v:byte(1) == 62 then -- ">"
      j = j - 1
    end
    if j <= depth then
      ends[#ends + 1] = i - 1
      depth = j - 1
      if depth <= 0 then
        return ends
      end
    end
  end
  ends[#ends + 1] = n
  return ends
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
  local ends = fold_ends(c.levels, c.n, last)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.wo[win].foldmethod == "expr" then
      pcall(vim._foldupdate, win, first - 1, last)
      -- Neovim can leave the last row of a fold around the edit at a
      -- wrong level without evaluating it (`>1 >2 >3 2`, editing the
      -- first row: the last one gets level 0): check those rows.
      vim.api.nvim_win_call(win, function()
        for _, e in ipairs(ends) do
          if vim.fn.foldlevel(e) ~= numeric(c.levels[e] or 0) then
            pcall(vim._foldupdate, win, e - 1, e)
          end
        end
      end)
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
-- Parts
---------------------------------------------------------------------------

-- The rest of the module lives in org/fold/*.lua, loaded here in this
-- order (each uses locals of those before it, through org.fold.shared).
-- They add their functions to M and require it back, so it must be in
-- package.loaded before they load.
package.loaded["org.fold"] = M

local shared = require("org.fold.shared")
shared.accept_unchanged_tick = accept_unchanged_tick
shared.cache = cache
shared.ellipsis = ellipsis
shared.get = get
shared.is_blank = is_blank
shared.ns_ellipsis = ns_ellipsis
shared.ns_hide = ns_hide
shared.regions = regions

require("org.fold.hidden")
require("org.fold.helpers")
require("org.fold.global")
require("org.fold.cycle")
require("org.fold.commands")
require("org.fold.setup")

return M

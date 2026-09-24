---@mod org.fold Folding and visibility cycling
---
--- Headlines fold by level. Drawers (`:PROPERTIES:`, `:LOGBOOK:`, ...) and
--- blocks (`#+begin_...` / `#+BEGIN:` dynamic blocks) fold one level deeper
--- than their headline, like Emacs. TAB cycles a subtree
--- (folded → children → subtree), S-TAB the whole buffer
--- (overview → contents → show all).

local config = require("org.config")
local parser = require("org.parser")

local M = {}

local cache = {} -- bufnr -> { tick, levels, regions }

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

--- Compute fold levels for all lines.
---@return table levels, table regions (list of {start, end, kind})
function M.compute(lines)
  local levels, regions = {}, {}
  local cur = 0
  local n = #lines
  local i = 1
  while i <= n do
    local line = lines[i]
    local lvl = line:byte(1) == 42 and parser.headline_level(line) or nil
    if lvl then
      levels[i] = ">" .. lvl
      cur = lvl
      i = i + 1
    else
      local kind, bname
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
        local inner = cur + 1
        levels[i] = ">" .. inner
        for j = i + 1, stop - 1 do
          levels[j] = inner
        end
        levels[stop] = "<" .. inner
        regions[#regions + 1] = { start = i, ["end"] = stop, kind = kind }
        i = stop + 1
      else
        levels[i] = cur
        i = i + 1
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

function M.foldtext()
  local lnum = vim.v.foldstart
  local line = vim.fn.getline(lnum)
  local ellipsis = config.opts.ellipsis or " …"
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
  return { { line, group }, { ellipsis, "Comment" } }
end

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

local function file()
  return require("org.files").get_buffer(0)
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

---------------------------------------------------------------------------
-- Global visibility
---------------------------------------------------------------------------

function M.overview()
  vim.cmd("normal! zM")
  vim.b.org_global_cycle = "overview"
end

function M.content()
  vim.cmd("normal! zM")
  for _, hl in ipairs(file().headlines) do
    if #hl.children > 0 then
      open_at(hl.line)
    end
  end
  vim.b.org_global_cycle = "content"
end

function M.show_all()
  vim.cmd("normal! zR")
  vim.b.org_global_cycle = "showall"
end

--- Everything visible except drawers (Emacs "showall").
local function show_all_but_drawers()
  vim.cmd("normal! zR")
  close_drawers(1, vim.api.nvim_buf_line_count(0))
  vim.b.org_global_cycle = "showall"
end

--- Show headlines up to `level`.
local function show_levels(level)
  vim.cmd("normal! zM")
  for _, hl in ipairs(file().headlines) do
    if hl.level < level and #hl.children > 0 then
      open_at(hl.line)
    end
  end
end

function M.global_cycle()
  if vim.v.count > 0 then
    show_levels(vim.v.count)
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

function M.cycle()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  local bufnr = vim.api.nvim_get_current_buf()
  local c = get(bufnr)
  for _, r in ipairs(c.regions) do
    if r.start == lnum then
      if lnum_closed(lnum) then
        open_at(lnum)
      else
        close_at(lnum)
      end
      return
    end
  end
  if not parser.headline_level(line) then
    return false
  end
  local f = file()
  local hl = f:headline_on(lnum)
  if not hl then
    return false
  end
  if not has_fold(hl) then
    vim.api.nvim_echo({ { "EMPTY ENTRY" } }, false, {})
    return
  end
  local function descendants(h, out)
    for _, ch in ipairs(h.children) do
      out[#out + 1] = ch
      descendants(ch, out)
    end
    return out
  end
  if lnum_closed(lnum) then
    open_at(lnum)
    if #hl.children == 0 then
      close_drawers(hl.line, hl.end_line)
      vim.api.nvim_echo({ { "SUBTREE (NO CHILDREN)" } }, false, {})
      return
    end
    -- CHILDREN: close each child, and drawers in the entry's own section
    for _, ch in ipairs(hl.children) do
      if has_fold(ch) then
        close_at(ch.line)
      end
    end
    close_drawers(hl.line, hl.body_end)
    vim.api.nvim_echo({ { "CHILDREN" } }, false, {})
    return
  end
  local any_open = false
  local any_foldable = false
  for _, d in ipairs(descendants(hl, {})) do
    if has_fold(d) then
      any_foldable = true
      if not lnum_closed(d.line) then
        any_open = true
      end
    end
  end
  if any_foldable and not any_open then
    -- SUBTREE
    vim.cmd(hl.line .. "," .. hl.end_line .. "foldopen!")
    close_drawers(hl.line, hl.end_line)
    vim.api.nvim_echo({ { "SUBTREE" } }, false, {})
    return
  end
  -- FOLDED
  close_at(lnum)
  vim.api.nvim_echo({ { "FOLDED" } }, false, {})
end

---------------------------------------------------------------------------
-- Subtree visibility commands
---------------------------------------------------------------------------

--- Headline at the cursor (the one whose section contains it).
local function headline_at_cursor()
  return file():headline_at(vim.api.nvim_win_get_cursor(0)[1])
end

--- Open `hl` (and its ancestors), show descendants down to `depth` levels
--- below it and fold the rest. Leaves are folded at any depth, so only
--- headlines stay visible - except the text of entries that have visible
--- children, which Vim folds cannot hide separately.
local function show_descendants(hl, depth)
  pcall(vim.cmd, hl.line .. "," .. hl.end_line .. "foldopen!")
  local function walk(h, rel)
    if rel > 0 and (rel >= depth or #h.children == 0) then
      if has_fold(h) then
        close_at(h.line)
      end
      return
    end
    close_drawers(h.line, h.body_end)
    for _, ch in ipairs(h.children) do
      walk(ch, rel + 1)
    end
  end
  walk(hl, 0)
end

--- Show all headlines of the current subtree, folding their bodies
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

--- Make the context around the cursor visible (org-reveal): open the
--- folds hiding the cursor so the headline path and its siblings show, and
--- the current entry's own text. With a count, show the parent's whole
--- subtree.
---@param whole_parent? boolean defaults to `vim.v.count > 0`
function M.reveal(whole_parent)
  if whole_parent == nil then
    whole_parent = vim.v.count > 0
  end
  vim.cmd("normal! zv")
  local hl = headline_at_cursor()
  if not hl then
    return
  end
  if whole_parent then
    local top = hl.parent or hl
    pcall(vim.cmd, top.line .. "," .. top.end_line .. "foldopen!")
    close_drawers(top.line, top.end_line)
    return
  end
  if has_fold(hl) and lnum_closed(hl.line) then
    open_at(hl.line)
    for _, ch in ipairs(hl.children) do
      if has_fold(ch) then
        close_at(ch.line)
      end
    end
    close_drawers(hl.line, hl.body_end)
  end
end

--- Copy the visible text (closed folds contribute only their first line)
--- of the buffer, or of the lines of the visual selection, into the
--- unnamed and `+` registers (org-copy-visible).
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
      out[#out + 1] = vim.fn.getline(lnum)
      lnum = lnum + 1
    else
      if fc == lnum then
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

--- Apply #+STARTUP / startup_folded visibility in the current window.
function M.apply_startup(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local f = require("org.files").get_buffer(bufnr)
  local startup = f.settings.startup or {}
  local mode = config.opts.startup_folded or "overview"
  for _, k in ipairs({ "overview", "content", "showall", "showeverything", "nofold", "fold" }) do
    if startup[k] then
      mode = k
    end
  end
  if mode == "fold" then
    mode = "overview"
  end
  if mode == "overview" then
    M.overview()
  elseif mode == "content" then
    M.content()
  elseif mode == "showall" then
    show_all_but_drawers()
  else
    vim.cmd("normal! zR")
    vim.b.org_global_cycle = "showall"
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
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = bufnr,
    group = vim.api.nvim_create_augroup("org.fold." .. bufnr, { clear = true }),
    callback = function()
      local w = vim.api.nvim_get_current_win()
      if vim.wo[w].foldexpr ~= "v:lua.require'org.fold'.foldexpr(v:lnum)" then
        setup_win(w)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      cache[bufnr] = nil
    end,
  })
end

return M

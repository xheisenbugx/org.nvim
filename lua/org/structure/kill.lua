---@mod org.structure.kill Subtree kill ring, yank and clone
---
--- Copy, cut, paste and yank subtrees (the kill ring and the clip live on
--- the facade table), and org-clone-subtree-with-time-shift.
---
--- Part of org.structure, which loads it.

local config = require("org.config")
local date = require("org.date")
local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")
local shared = require("org.structure.shared")

local M = require("org.structure")

local buf = shared.buf
local cursor = shared.cursor
local current_headline = shared.current_headline
local get_lines = shared.get_lines
local insert_lines = shared.insert_lines
local is_blank = shared.is_blank
local relevel = shared.relevel
local set_lines = shared.set_lines
local sibling_index = shared.sibling_index
local siblings = shared.siblings

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
---@param opts? { lines?: string[], pos?: integer[] } the subtree (default the
--- `"` register or the kill ring) and where Emacs's point is (default the
--- cursor; a row past the end is the end of the buffer)
---@return integer|nil first, integer|nil last the inserted lines
function M.paste_subtree(opts)
  opts = opts or {}
  local bufnr = buf()
  local reg = vim.fn.getreg('"', 1, true)
  local lines = opts.lines
  if not lines and type(reg) == "table" and is_subtree(reg) then
    lines = reg
  elseif not lines then
    lines = M.kill_ring[#M.kill_ring]
  end
  if not is_subtree(lines) then
    utils.warn("The kill is not a (set of) tree(s). Use p to yank anyway")
    return
  end
  lines = vim.deepcopy(lines)
  local file = files.get_buffer(bufnr)
  local count = opts.lines and 0 or vim.v.count
  local arg = (count == 4 or count == 16) and count or nil
  local numeric = count > 0 and not arg and count or nil
  local pos = opts.pos or cursor()
  local lnum = pos[1]
  local line = get_lines(bufnr, lnum, lnum)[1] or ""
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
  insert_lines(bufnr, at, new)
  local first = at
  while first < at + #new - 1 and is_blank(get_lines(bufnr, first, first)[1]) do
    first = first + 1
  end
  vim.api.nvim_win_set_cursor(0, { first, 0 })
  if not opts.lines and M.clip_folded and vim.deep_equal(M.clip, lines) then
    -- (not zx: that would reset the folds of the whole buffer)
    pcall(vim.cmd, first .. "foldclose")
  end
  utils.notify(string.format("Clipboard pasted as level %d subtree", new_level))
  return first, at + #new - 1
end

--- Fold the subtrees in lines [s, e] unless that would hide the text after
--- them (org-yank with org-yank-folded-subtrees).
local function fold_yanked(bufnr, s, e)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local first_level
  for l = s, e do
    first_level = parser.headline_level(get_lines(bufnr, l, l)[1])
    if first_level then
      break
    end
  end
  if not first_level then
    return
  end
  local nxt = e + 1
  while nxt <= total and is_blank(get_lines(bufnr, nxt, nxt)[1]) do
    nxt = nxt + 1
  end
  if nxt <= total then
    local lv = parser.headline_level(get_lines(bufnr, nxt, nxt)[1])
    if not lv or lv > first_level then
      utils.notify("Inserted text not folded because that would swallow text")
      return
    end
  end
  local file = files.get_buffer(bufnr)
  local tops = {}
  for _, hl in ipairs(file.headlines) do
    if hl.line >= s and hl.line <= e and hl.level <= first_level then
      tops[#tops + 1] = hl.line
    end
  end
  vim.api.nvim_buf_call(bufnr, function()
    for i = #tops, 1, -1 do
      local l = tops[i]
      if vim.fn.foldclosed(l) == -1 and vim.fn.foldlevel(l) > 0 then
        pcall(vim.cmd, l .. "foldclose")
      end
    end
  end)
end

--- `p` / `P` (org-yank): a register holding whole subtrees is put with its
--- level adjusted to the surrounding headlines (`yank_adjusted_subtrees`)
--- and folded (`yank_folded_subtrees`). With a count, or any other text,
--- a plain put.
---@param before? boolean `P`
function M.yank(before)
  local bufnr = buf()
  local reg = vim.v.register
  local count = vim.v.count
  local key = before and "P" or "p"
  local function plain()
    vim.cmd(string.format('normal! "%s%s%s', reg, count > 0 and count or "", key))
  end
  local lines = vim.fn.getreg(reg, 1, true)
  local cfg = config.opts
  if
    count > 0
    or vim.fn.getregtype(reg) ~= "V"
    or type(lines) ~= "table"
    or not is_subtree(lines)
    or not (cfg.yank_folded_subtrees or cfg.yank_adjusted_subtrees)
  then
    plain()
    return
  end
  local row = cursor()[1]
  local s, e
  local fold = cfg.yank_folded_subtrees
  if cfg.yank_adjusted_subtrees then
    -- Emacs point: the start of the line the text goes before
    local at = before and row or row + 1
    s, e = M.paste_subtree({ lines = lines, pos = { at, 0 } })
    -- Emacs folds only when the subtree went in at point (before a
    -- headline), not before the next headline
    fold = fold and s == at
  else
    plain()
    s, e = vim.api.nvim_buf_get_mark(bufnr, "[")[1], vim.api.nvim_buf_get_mark(bufnr, "]")[1]
  end
  if s and fold then
    fold_yanked(bufnr, s, e)
    vim.api.nvim_win_set_cursor(0, { s, 0 })
  end
end

function M.yank_before()
  return M.yank(true)
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

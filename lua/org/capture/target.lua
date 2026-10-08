---@mod org.capture.target Capture target resolution and date trees
---
--- Part of org.capture, which loads it: the target file, headline,
--- outline path, date tree and function targets, tracked with an
--- extmark until the capture ends.

local config = require("org.config")
local date = require("org.date")
local files = require("org.files")
local marks = require("org.marks")
local parser = require("org.parser")
local utils = require("org.utils")
local shared = require("org.capture.shared")

local M = require("org.capture")

---------------------------------------------------------------------------
-- Target resolution
---------------------------------------------------------------------------

--- Buffer and headline line of the running clock (the `clock` target).
---@return integer|nil bufnr, integer|nil lnum
function M.clock_location()
  local ok, clock = pcall(require, "org.clock")
  if not ok or not clock.state then
    return nil
  end
  local bufnr, lnum = clock.find_open_clock()
  if not bufnr then
    return nil
  end
  local hl = files.get_buffer(bufnr):headline_at(lnum)
  return bufnr, hl and hl.line or nil
end

--- Absolute target file for a template (org-capture-expand-file): ""
--- is `default_notes_file`, relative names are relative to
--- `org_directory`. nil for the clock/ID/location targets that can't be
--- found.
function M.target_path(tpl)
  local t = tpl.target or tpl.file
  if type(t) == "function" then
    t = t()
  end
  if t == "clock" then
    local bufnr = M.clock_location()
    return bufnr and vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr)) or nil
  end
  if tpl.id and not t then
    local loc = require("org.id").find(tpl.id)
    return loc and loc.filename or nil
  end
  if t == nil or t == "" then
    t = config.opts.default_notes_file
  end
  return utils.expand(t)
end

local function get_line(bufnr, lnum)
  return vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
end

local function is_blank(l)
  return l ~= nil and l:match("^%s*$") ~= nil
end

--- A buffer holding only one empty line (a new file).
local function is_empty_buffer(bufnr)
  return vim.api.nvim_buf_line_count(bufnr) == 1 and get_line(bufnr, 1) == ""
end

--- Insert `lines` after line `at` (0 = top); an empty buffer is replaced.
local function put(bufnr, at, lines)
  if is_empty_buffer(bufnr) then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, lines)
    return 0
  end
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, lines)
  return at
end

---------------------------------------------------------------------------
-- Date trees (org-datetree)
---------------------------------------------------------------------------

local function comparefun(pattern)
  return function(sibling, new)
    local a, b = sibling:match(pattern), new:match(pattern)
    if not (a and b) then
      return nil
    end
    return a < b and -1 or (a > b and 1 or 0)
  end
end

local GROUPINGS = {
  day = { "year", "month", "day" },
  month = { "year", "month" },
  week = { "year", "week", "day" },
}

--- Headline titles (with their comparison functions) of the date tree
--- nodes for `d` (org-datetree-find-create-entry). `grouping` is a subset
--- of { "year", "quarter", "month", "week", "day" }.
function M.datetree_hierarchy(grouping, d)
  local has = {}
  for _, g in ipairs(grouping) do
    has[g] = true
  end
  local t = os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })
  local iso_year = tonumber(os.date("%G", t))
  local week = tonumber(os.date("%V", t))
  local nominal_year = has.week and iso_year or d.year
  local nominal_month = d.month
  if has.week then
    -- the month containing the week's Thursday
    local wd = tonumber(os.date("%u", t))
    nominal_month = tonumber(os.date("%m", t + (4 - wd) * 86400))
  end
  local quarter = (has.week and not has.month) and math.min(4, 1 + math.floor((week - 1) / 13))
    or (1 + math.floor((nominal_month - 1) / 3))
  local out = {}
  if has.year then
    out[#out + 1] = { tostring(nominal_year), comparefun("([12]%d%d%d)") }
  end
  if has.quarter then
    out[#out + 1] = { string.format("%d-Q%d", nominal_year, quarter), comparefun("([12]%d%d%d%-Q[1-4])") }
  end
  if has.month then
    out[#out + 1] = {
      string.format("%04d-%02d %s", nominal_year, nominal_month, date.MONTH_NAMES_LONG[nominal_month]),
      comparefun("([12]%d%d%d%-[01]%d) %S"),
    }
  end
  if has.week then
    out[#out + 1] = { os.date("%G-W%V", t), comparefun("([12]%d%d%d%-W[0-5]%d)") }
  end
  if has.day then
    out[#out + 1] = {
      string.format("%04d-%02d-%02d %s", d.year, d.month, d.day, date.DAY_NAMES_LONG[d:weekday()]),
      comparefun("([12]%d%d%d%-[01]%d%-[0123]%d) %S"),
    }
  end
  return out
end

--- Find or create the headline `title` of `level` among the headlines in
--- lines [s, e] (org-datetree--find-create-subheading): the first one
--- comparing equal is used, a new one goes before the first later one.
---@return integer line
---@return boolean created
local function dt_subheading(bufnr, s, e, level, title, cmp)
  local file = files.get_buffer(bufnr)
  -- something follows the parent's subtree
  local followed = e < vim.api.nvim_buf_line_count(bufnr)
  local sibling
  for _, hl in ipairs(file.headlines) do
    if hl.line >= s and hl.line <= e and hl.level == level then
      local r = cmp(hl.title, title)
      if r == true or (type(r) == "number" and r >= 0) then
        sibling = hl
        break
      end
    end
  end
  if sibling then
    local r = cmp(sibling.title, title)
    if r == true or r == 0 then
      return sibling.line, false
    end
  end
  local at = sibling and sibling.line - 1 or e
  -- blank lines before the new node are removed ...
  local b = at
  while b >= s and b > 0 and is_blank(get_line(bufnr, b)) do
    b = b - 1
  end
  -- ... and one is added when org--blank-before-heading-p says so
  local blank = false
  local setting = config.opts.blank_before_new_entry
  setting = type(setting) == "table" and setting.heading or setting
  if setting == true then
    blank = b > 0
  elseif setting == "auto" and b > 0 then
    local f = files.get_buffer(bufnr)
    -- the buffer is narrowed to the parent's subtree: its heading is at bob
    local h = f:headline_at(b)
    if h and h.line > math.max(s - 1, 1) then
      blank = is_blank(get_line(bufnr, h.line - 1))
    elseif h then
      for _, n in ipairs(f.headlines) do
        if n.line > e then
          break
        elseif n.line > at + 1 then
          blank = is_blank(get_line(bufnr, n.line - 1))
          break
        end
      end
    end
  end
  if b < at then
    vim.api.nvim_buf_set_lines(bufnr, b, at, false, {})
    at = b
  end
  local new = { string.rep("*", level) .. " " .. title }
  if at == 0 or blank then
    -- Emacs inserts "\n* title\n": at the top of the buffer that leaves an
    -- empty first line
    table.insert(new, 1, "")
  end
  local heading = put(bufnr, at, new) + #new
  if not sibling and followed then
    -- Emacs narrows to the parent subtree minus its final newline, so a
    -- node added at its end keeps one blank line before the next heading
    vim.api.nvim_buf_set_lines(bufnr, heading, heading, false, { "" })
  end
  return heading, true
end

--- Create/find the date tree for `d` under `parent_lnum` (nil = top level,
--- or under the headline with a DATE_TREE / WEEK_TREE property); returns
--- the line of the innermost node.
---@param tree_type? "day"|"week"|"month"|string[]|fun(d: org.Date): table
function M.ensure_datetree(bufnr, parent_lnum, d, tree_type)
  tree_type = tree_type or "day"
  local hier
  if type(tree_type) == "function" then
    hier = {}
    for _, h in ipairs(tree_type(d)) do
      if type(h) == "string" then
        local title = h
        hier[#hier + 1] = {
          title,
          function(a, b)
            return a == b and 0 or nil
          end,
        }
      else
        hier[#hier + 1] = h
      end
    end
  else
    local grouping = type(tree_type) == "table" and tree_type or GROUPINGS[tree_type]
    if not grouping then
      error("Unrecognized :tree-type " .. tostring(tree_type), 0)
    end
    for _, g in ipairs(grouping) do
      if not vim.tbl_contains({ "year", "quarter", "month", "week", "day" }, g) then
        error("Unrecognized datetree grouping elements " .. tostring(g), 0)
      end
    end
    hier = M.datetree_hierarchy(grouping, d)
    if not parent_lnum and type(tree_type) == "string" then
      -- the old way of placing the tree: a headline with a property
      local prop = tree_type == "week" and "WEEK_TREE" or "DATE_TREE"
      local hl = files.get_buffer(bufnr):find_headline(function(h)
        return h.properties[prop] ~= nil
      end)
      parent_lnum = hl and hl.line or nil
    end
  end
  local level, s, e = 1, 1, vim.api.nvim_buf_line_count(bufnr)
  local line = parent_lnum
  local created = false
  for _, h in ipairs(hier) do
    if line then
      local hl = files.get_buffer(bufnr):headline_at(line)
      level, s, e = hl.level + 1, hl.line + 1, hl.end_line
    end
    line, created = dt_subheading(bufnr, s, e, level, h[1], h[2])
  end
  local stamp = config.opts.datetree_add_timestamp
  local grouping = type(tree_type) == "table" and tree_type or GROUPINGS[tree_type]
  if stamp and grouping and vim.tbl_contains(grouping, "day") and created then
    -- org-datetree-add-timestamp: a new day node gets its date
    local ts = date.Date.new({ year = d.year, month = d.month, day = d.day, active = stamp ~= "inactive" })
    local indent = config.opts.adapt_indentation == true and string.rep(" ", level + 1) or ""
    vim.api.nvim_buf_set_lines(bufnr, line, line, false, { indent .. ts:to_string() })
  end
  return line
end

--- Find the headline for a file+headline target, creating it at the end
--- of the file when missing.
local function find_or_create_headline(bufnr, title)
  local file = files.get_buffer(bufnr)
  local hl = file:find_by_title(title)
  if hl then
    return hl.line
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  return put(bufnr, n, { "* " .. title }) + 1
end

--- Track only the text created while resolving a capture target. Abort
--- must not reload a whole target buffer: it may have acquired other edits.
local function track_target_changes(loc, before)
  loc.original_lines = before
  loc.changes = {}
  local after = vim.api.nvim_buf_get_lines(loc.bufnr, 0, -1, false)
  local hunks =
    vim.diff(table.concat(before, "\n") .. "\n", table.concat(after, "\n") .. "\n", { result_type = "indices" })
  for _, h in ipairs(hunks) do
    if h[4] > 0 then
      loc.changes[#loc.changes + 1] = {
        original = vim.list_slice(before, h[1], h[1] + h[2] - 1),
        created = vim.list_slice(after, h[3], h[3] + h[4] - 1),
        mark = marks.range(loc.bufnr, h[3], h[3] + h[4] - 1, { invalidate = true }),
      }
    end
  end
end

--- Resolve a template's target when the capture starts
--- (org-capture-set-target-location). Headlines of file+headline and the
--- date tree nodes are created now. Positions are tracked with extmarks.
---@param tpl table
---@param ctx table
---@return table|nil loc { bufnr, mark, target_entry_p, insert_here, new_buffer }
---@return string|nil error
function M.resolve_target(tpl, ctx)
  local bufnr, line, col, entry_p = nil, nil, 0, true
  local before
  local loc = {}
  local t = tpl.target or tpl.file
  if ctx.here then
    bufnr = ctx.origin_buf or vim.api.nvim_get_current_buf()
    local cur = ctx.origin_cursor or vim.api.nvim_win_get_cursor(0)
    line, col = cur[1], cur[2]
    loc.insert_here = true
    entry_p = false
  elseif type(tpl.location) == "function" then
    -- (function f): the function chooses the buffer and position
    local b, l, c = tpl.location()
    bufnr = b or vim.api.nvim_get_current_buf()
    if not l then
      local cur = vim.api.nvim_win_get_cursor(0)
      l, c = cur[1], cur[2]
    end
    line, col = l, c or 0
    entry_p = parser.headline_level(get_line(bufnr, line) or "") ~= nil and col == 0
    loc.exact = not entry_p
  elseif t == "clock" then
    bufnr, line = M.clock_location()
    if not bufnr then
      return nil, "No running clock that could be used as capture target"
    end
  elseif tpl.id and not t then
    local found = require("org.id").find(tpl.id)
    if not found then
      return nil, string.format('Cannot find target ID "%s"', tpl.id)
    end
    loc.new_buffer = utils.find_buffer(found.filename) == nil
    bufnr = found.bufnr or utils.load_buffer(found.filename)
    local hl = files.get_buffer(bufnr):find_by_id(tpl.id)
    line = hl and hl.line or nil
  else
    local path = M.target_path(tpl)
    if not path then
      return nil, "Invalid file location"
    end
    loc.new_buffer = utils.find_buffer(path) == nil
    bufnr = utils.load_buffer(path)
    loc.was_modified = vim.bo[bufnr].modified
    before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if tpl.headline then
      local title = tpl.headline
      if type(title) == "function" then
        title = title()
      end
      if title then
        line = find_or_create_headline(bufnr, title)
      else
        -- a headline function that names none: the file itself
        entry_p = false
      end
    elseif tpl.olp then
      local olp = tpl.olp
      if type(olp) == "function" then
        olp = vim.api.nvim_buf_call(bufnr, olp)
      end
      if type(olp) == "string" then
        olp = vim.split(olp, "/", { trimempty = true })
      end
      local nodes = files.get_buffer(bufnr).children
      local hl
      for i, name in ipairs(olp) do
        hl = nil
        for _, h in ipairs(nodes) do
          if h:plain_title() == name or h.title == name then
            hl = h
            break
          end
        end
        if not hl then
          return nil, string.format("Heading not found on level %d: %s", i, name)
        end
        nodes = hl.children
      end
      line = hl and hl.line or nil
    elseif tpl.regexp then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for i, l in ipairs(lines) do
        local m = vim.fn.matchstrpos(l, tpl.regexp)
        if m[2] >= 0 then
          line, col = i, tpl.prepend and m[2] or m[3]
          break
        end
      end
      if not line then
        return nil, "No match for target regexp in file " .. path
      end
      entry_p = parser.headline_level(get_line(bufnr, line)) ~= nil
      loc.exact = true
    elseif type(tpl.func) == "function" or type(tpl["function"]) == "function" then
      -- file+function: the function returns the line (and column), or
      -- moves the cursor
      local fn = tpl.func or tpl["function"]
      local l, c
      vim.api.nvim_buf_call(bufnr, function()
        l, c = fn(bufnr)
        if not l then
          local cur = vim.api.nvim_win_get_cursor(0)
          l, c = cur[1], cur[2]
        end
      end)
      line, col = l, c or 0
      entry_p = parser.headline_level(get_line(bufnr, line) or "") ~= nil and col == 0
      loc.exact = not entry_p
    else
      entry_p = false
    end
  end
  if loc.was_modified == nil and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    loc.was_modified = vim.bo[bufnr].modified
  end
  before = before or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if tpl.datetree and not ctx.here then
    local tt = type(tpl.datetree) == "table" and tpl.datetree.tree_type or tpl.tree_type or "day"
    line = M.ensure_datetree(bufnr, entry_p and line or nil, ctx.date or date.today(), tt)
    col, entry_p, loc.exact = 0, true, false
  end
  if entry_p and not line then
    return nil, "Capture target not found"
  end
  loc.bufnr = bufnr
  loc.target_entry_p = entry_p
  track_target_changes(loc, before)
  if line then
    local len = #(get_line(bufnr, line) or "")
    local heading = entry_p and not loc.insert_here and files.get_buffer(bufnr):headline_on(line)
    if heading then
      -- the mark goes invalid when the headline line is deleted (or
      -- rewritten); the title then finds it again
      loc.title, loc.level = heading.title, heading.level
      loc.mark = marks.set(bufnr, line, nil, { invalidate = true })
    else
      -- an exact position: text inserted there goes before it
      loc.mark = marks.set(bufnr, line, math.min(col, len), { gravity = "right" })
    end
  end
  return loc
end

--- Current (line, col) of a location's mark.
local function mark_pos(loc)
  local lnum, col, invalid
  if loc.mark then
    lnum, col, invalid = loc.mark:pos()
  end
  if not lnum then
    return nil
  end
  if loc.title and not invalid then
    return lnum, 0
  end
  if invalid then
    local file = files.get_buffer(loc.bufnr)
    local hl = file:headline_on(lnum)
    if hl and hl.title == loc.title and hl.level == loc.level then
      return hl.line, 0
    end
    local found
    for _, h in ipairs(file.headlines) do
      if h.title == loc.title and h.level == loc.level then
        if found then
          return nil -- ambiguous
        end
        found = h
      end
    end
    return found and found.line or nil, 0
  end
  return lnum, col
end

local function release(loc)
  if loc then
    marks.del(loc.mark)
    for _, change in ipairs(loc.changes or {}) do
      marks.del(change.mark)
    end
  end
end

local function cleanup_target(loc)
  if not loc or not vim.api.nvim_buf_is_valid(loc.bufnr) then
    return
  end
  for i = #(loc.changes or {}), 1, -1 do
    local change = loc.changes[i]
    local first, last = change.mark:rows()
    if first then
      first = first - 1
      local current = vim.api.nvim_buf_get_lines(loc.bufnr, first, last, false)
      local owned = vim.deep_equal(current, change.created)
      -- A user may have added text or children immediately after a generated
      -- heading. Keep that heading too, so the surviving text keeps its parent.
      if owned then
        for _, hl in ipairs(files.get_buffer(loc.bufnr).headlines) do
          if hl.line > first and hl.line <= last and hl.end_line > last then
            owned = false
            break
          end
        end
      end
      if owned then
        vim.api.nvim_buf_set_lines(loc.bufnr, first, last, false, change.original)
      end
    end
  end
  local lines = vim.api.nvim_buf_get_lines(loc.bufnr, 0, -1, false)
  if vim.deep_equal(lines, loc.original_lines) and not loc.was_modified then
    -- The target may have been written while capturing: only clear the
    -- flag when the file still holds the restored text.
    -- (an empty or missing file is a buffer with one empty line)
    local name = vim.api.nvim_buf_get_name(loc.bufnr)
    local disk = name ~= "" and utils.readfile(name) or {}
    vim.bo[loc.bufnr].modified = name ~= "" and not vim.deep_equal(#disk > 0 and disk or { "" }, lines)
  end
end

-- Shared with the parts loaded after this one
shared.get_line = get_line
shared.is_blank = is_blank
shared.is_empty_buffer = is_empty_buffer
shared.put = put
shared.mark_pos = mark_pos
shared.release = release
shared.cleanup_target = cleanup_target

--- Positions that follow edits (like Emacs markers).
---
--- Code that edits a buffer and needs to find a line again afterwards
--- (the source of a refile, the target of a capture, an archived entry)
--- sets a mark instead of adding up line deltas by hand. Marks are
--- extmarks in one namespace: they move with insertions and deletions
--- made by anyone, and die with their buffer.
---
--- ```lua
--- local marks = require("org.marks")
--- local src = marks.range(bufnr, hl.line, hl.end_line)
--- -- ... insert or delete lines anywhere ...
--- local s, e = src:rows()
--- src:del()
--- ```
---
--- Line numbers are 1-based and columns 0-based, as in the rest of org.nvim.
local M = {}

M.ns = vim.api.nvim_create_namespace("org.marks")

local api = vim.api

local function line_len(bufnr, lnum)
  return #(api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or "")
end

local function check(bufnr, lnum)
  if not (bufnr and api.nvim_buf_is_valid(bufnr)) then
    return nil, "buffer " .. tostring(bufnr) .. " is not valid"
  end
  if not api.nvim_buf_is_loaded(bufnr) then
    return nil, "buffer " .. bufnr .. " is not loaded"
  end
  local n = api.nvim_buf_line_count(bufnr)
  if type(lnum) ~= "number" or lnum < 1 or lnum > n then
    return nil, string.format("line %s is outside buffer %d (%d lines)", tostring(lnum), bufnr, n)
  end
  return true
end

---------------------------------------------------------------------------
-- Mark: one position
---------------------------------------------------------------------------

---@class org.Mark
---@field bufnr integer
---@field id integer|nil extmark id, nil once deleted
local Mark = {}
Mark.__index = Mark

--- The extmark's position and details, or nil when it is gone (deleted,
--- or its buffer wiped or unloaded).
local function get(bufnr, id)
  if not id or not api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local ok, pos = pcall(api.nvim_buf_get_extmark_by_id, bufnr, M.ns, id, { details = true })
  if not ok or not pos or not pos[1] then
    return nil
  end
  return pos
end

--- Current position: (lnum, col, invalid). `invalid` is true when the mark
--- was set with `invalidate` and the text around it was deleted; the
--- position is then where that text was. nil when the mark is gone.
---@return integer|nil lnum, integer|nil col, boolean|nil invalid
function Mark:pos()
  local pos = get(self.bufnr, self.id)
  if not pos then
    return nil
  end
  return pos[1] + 1, pos[2], pos[3].invalid == true
end

--- Current line, or nil when the mark is gone or invalid.
---@return integer|nil
function Mark:lnum()
  local lnum, _, invalid = self:pos()
  if invalid then
    return nil
  end
  return lnum
end

--- Delete the mark (safe to call more than once).
function Mark:del()
  if self.id and api.nvim_buf_is_valid(self.bufnr) then
    pcall(api.nvim_buf_del_extmark, self.bufnr, M.ns, self.id)
  end
  self.id = nil
end

--- The extmark options and position, to put the mark back with
--- `restore()` after a whole-buffer restore moved it.
function Mark:save()
  local pos = get(self.bufnr, self.id)
  if not pos or pos[3].invalid then
    return nil
  end
  return { mark = self, row = pos[1], col = pos[2], details = pos[3] }
end

---------------------------------------------------------------------------
-- Range: whole lines (a subtree, a region)
---------------------------------------------------------------------------

---@class org.MarkRange: org.Mark
local Range = setmetatable({}, { __index = Mark })
Range.__index = Range

--- Current lines (s, e), 1-based and inclusive; nil when the range is
--- gone, invalid, or all its lines were deleted.
---@return integer|nil s, integer|nil e
function Range:rows()
  local pos = get(self.bufnr, self.id)
  if not pos or pos[3].invalid then
    return nil
  end
  local s, e = pos[1] + 1, pos[3].end_row
  if pos[3].end_col and pos[3].end_col > 0 then
    -- the end is inside a line (only at the end of the buffer)
    e = e + 1
  end
  if e < s then
    return nil
  end
  return s, e
end

--- Text of the range (nil when it is gone).
---@return string[]|nil
function Range:lines()
  local s, e = self:rows()
  return s and api.nvim_buf_get_lines(self.bufnr, s - 1, e, false) or nil
end

---------------------------------------------------------------------------
-- Constructors
---------------------------------------------------------------------------

--- How a line is followed: on a non-empty line the mark sits after the
--- first character with left gravity, so text inserted before the line
--- pushes it down while rewriting the line (delete + insert, as
--- nvim_buf_set_lines does) leaves it there. An empty line has only
--- column 0; right gravity then follows text inserted above.
local function line_anchor(bufnr, lnum)
  if line_len(bufnr, lnum) > 0 then
    return 1, false
  end
  return 0, true
end

---@class org.MarkOpts
---@field gravity? "left"|"right" with a column: where the mark goes when text is inserted at it ("left": stays before it, like an Emacs marker; "right": moves after it). Default "left".
---@field invalidate? boolean the mark turns invalid when its line is deleted (or rewritten)

--- Set a mark at (bufnr, lnum[, col]). Without `col` the mark follows the
--- line: text inserted or deleted above moves it, edits of the line
--- itself don't. With `col`, it is a position inside the line with the
--- chosen gravity. Returns nil and a message when the position does not
--- exist.
---@param bufnr integer
---@param lnum integer
---@param col? integer
---@param opts? org.MarkOpts
---@return org.Mark|nil, string|nil err
function M.set(bufnr, lnum, col, opts)
  opts = opts or {}
  local ok, err = check(bufnr, lnum)
  if not ok then
    return nil, err
  end
  local right
  if col == nil then
    col, right = line_anchor(bufnr, lnum)
  else
    col = math.max(0, math.min(col, line_len(bufnr, lnum)))
    right = opts.gravity == "right"
  end
  local id = api.nvim_buf_set_extmark(bufnr, M.ns, lnum - 1, col, {
    right_gravity = right,
    invalidate = opts.invalidate or nil,
  })
  return setmetatable({ bufnr = bufnr, id = id }, Mark)
end

---@class org.MarkRangeOpts
---@field invalidate? boolean the range turns invalid when all its lines are deleted
---@field grow? boolean lines inserted right before the first line or right after the last join the range (default: they stay outside); sets `grow_start` and `grow_end`
---@field grow_start? boolean text inserted at the start of the first line joins the range
---@field grow_end? boolean text inserted right after the last line joins the range

--- Follow lines s..e (inclusive) of a buffer: lines inserted inside the
--- range extend it, lines deleted from it shrink it.
---@param bufnr integer
---@param s integer
---@param e integer
---@param opts? org.MarkRangeOpts
---@return org.MarkRange|nil, string|nil err
function M.range(bufnr, s, e, opts)
  opts = opts or {}
  local ok, err = check(bufnr, s)
  if ok and e < s - 1 then
    ok, err = nil, string.format("range %d-%d is empty", s, e)
  end
  if ok and e > api.nvim_buf_line_count(bufnr) then
    ok, err = check(bufnr, e)
  end
  if not ok then
    return nil, err
  end
  local col, right = 0, false
  if not (opts.grow or opts.grow_start) then
    col, right = line_anchor(bufnr, s)
  end
  local id = api.nvim_buf_set_extmark(bufnr, M.ns, s - 1, col, {
    end_row = e,
    end_col = 0,
    right_gravity = right,
    end_right_gravity = (opts.grow or opts.grow_end) == true,
    invalidate = opts.invalidate or nil,
  })
  return setmetatable({ bufnr = bufnr, id = id }, Range)
end

--- A mark in file `filename`, which is loaded into a (hidden) buffer when
--- no buffer has it yet.
---@param filename string
---@param lnum integer
---@param col? integer
---@param opts? org.MarkOpts
---@return org.Mark|nil, string|nil err
function M.in_file(filename, lnum, col, opts)
  local ok, bufnr = pcall(require("org.utils").load_buffer, filename)
  if not ok then
    return nil, "cannot load " .. filename .. ": " .. tostring(bufnr)
  end
  return M.set(bufnr, lnum, col, opts)
end

--- Put marks saved with `Mark:save()` back where they were, with their ids
--- (a whole-buffer restore squashes the marks of the lines it replaces).
---@param saved table[] results of `Mark:save()` (nil entries are skipped)
function M.restore(saved)
  for _, s in pairs(saved) do
    local m, d = s.mark, s.details
    if api.nvim_buf_is_valid(m.bufnr) then
      local n = api.nvim_buf_line_count(m.bufnr)
      m.id = api.nvim_buf_set_extmark(m.bufnr, M.ns, math.min(s.row, n - 1), s.col, {
        id = m.id,
        end_row = d.end_row and math.min(d.end_row, n) or nil,
        end_col = d.end_col,
        right_gravity = d.right_gravity,
        end_right_gravity = d.end_right_gravity,
        invalidate = d.invalidate,
        strict = false,
      })
    end
  end
end

--- Delete marks (nil entries are skipped).
function M.del(...)
  for i = 1, select("#", ...) do
    local m = select(i, ...)
    if m then
      m:del()
    end
  end
end

--- Call fn(track) and delete every mark made with `track` afterwards,
--- also when fn fails. `track` is `M.set` / `M.range` whose result is
--- remembered: `track(bufnr, lnum[, col, opts])` and
--- `track.range(bufnr, s, e, opts)`. Returns what fn returns.
function M.with(fn)
  local made = {}
  local function remember(m, err)
    if m then
      made[#made + 1] = m
    end
    return m, err
  end
  local track = setmetatable({
    range = function(...)
      return remember(M.range(...))
    end,
  }, {
    __call = function(_, ...)
      return remember(M.set(...))
    end,
  })
  local res = vim.F.pack_len(pcall(fn, track))
  for _, m in ipairs(made) do
    m:del()
  end
  if not res[1] then
    error(res[2], 0)
  end
  return unpack(res, 2, res.n)
end

return M

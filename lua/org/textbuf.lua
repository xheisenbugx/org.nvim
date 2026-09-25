---@mod org.textbuf Emacs-style text buffer for faithful command ports
---
--- A small in-memory buffer with an Emacs-like point, used to port Org
--- commands whose exact result depends on character-level operations
--- (inserting newlines, deleting blank lines around point, ...). The
--- buffer text is the lines joined with "\n" plus a final newline, like a
--- file with 'eol'. Positions are 1-based byte offsets; `point` is before
--- the character at that position. `apply()` writes back only the lines
--- that changed and moves the cursor to point.

local M = {}
M.__index = M

--- Build a buffer from `bufnr` (default current) with point at the cursor
--- (or at { row, col0 }).
---@param bufnr? integer
---@param pos? integer[] { row (1-based), col (0-based) }
function M.from_buffer(bufnr, pos)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  pos = pos or vim.api.nvim_win_get_cursor(0)
  local self = setmetatable({ bufnr = bufnr, orig = lines }, M)
  self.text = table.concat(lines, "\n") .. "\n"
  self.point = self:pos_of(pos[1], pos[2])
  return self
end

--- Position of (row, col0).
function M:pos_of(row, col)
  local p = 1
  for _ = 1, row - 1 do
    local nl = self.text:find("\n", p, true)
    if not nl then
      return #self.text + 1
    end
    p = nl + 1
  end
  local le = self.text:find("\n", p, true) or (#self.text + 1)
  return math.min(p + col, le)
end

--- (row, col0) of a position.
function M:rowcol(pos)
  pos = pos or self.point
  local row, p = 1, 1
  while true do
    local nl = self.text:find("\n", p, true)
    if not nl or nl >= pos then
      return row, pos - p
    end
    row = row + 1
    p = nl + 1
  end
end

function M:point_min()
  return 1
end

function M:point_max()
  return #self.text + 1
end

function M:bobp()
  return self.point == 1
end

function M:eobp()
  return self.point == #self.text + 1
end

function M:line_beg(pos)
  pos = pos or self.point
  local p = pos - 1
  while p >= 1 and self.text:sub(p, p) ~= "\n" do
    p = p - 1
  end
  return p + 1
end

function M:line_end(pos)
  pos = pos or self.point
  return self.text:find("\n", pos, true) or (#self.text + 1)
end

function M:bolp()
  return self.point == self:line_beg()
end

function M:eolp()
  return self.point == self:line_end()
end

--- Text of the line containing `pos`.
function M:line(pos)
  pos = pos or self.point
  return self.text:sub(self:line_beg(pos), self:line_end(pos) - 1)
end

function M:goto(pos)
  self.point = math.max(1, math.min(pos, #self.text + 1))
end

--- Move to the beginning of the Nth next (or previous) line; returns the
--- shortfall like Emacs `forward-line`.
function M:forward_line(n)
  n = n or 1
  local p = self:line_beg()
  if n > 0 then
    for i = 1, n do
      local nl = self.text:find("\n", p, true)
      if not nl then
        self.point = #self.text + 1
        return n - i + 1
      end
      p = nl + 1
    end
    self.point = p
  else
    for i = 1, -n do
      if p == 1 then
        self.point = 1
        return -n - i + 1
      end
      p = self:line_beg(p - 1)
    end
    self.point = p
  end
  return 0
end

function M:insert(s)
  self.text = self.text:sub(1, self.point - 1) .. s .. self.text:sub(self.point)
  self.point = self.point + #s
end

--- Delete [a, b) and return the deleted text. Point follows like Emacs.
function M:delete(a, b)
  if a > b then
    a, b = b, a
  end
  local s = self.text:sub(a, b - 1)
  self.text = self.text:sub(1, a - 1) .. self.text:sub(b)
  if self.point >= b then
    self.point = self.point - (b - a)
  elseif self.point > a then
    self.point = a
  end
  return s
end

--- Move point backward over characters of the Lua character class body
--- `set` (e.g. " \t\n").
function M:skip_backward(set)
  local pat = "[" .. set .. "]"
  while self.point > 1 and self.text:sub(self.point - 1, self.point - 1):match(pat) do
    self.point = self.point - 1
  end
end

function M:skip_forward(set)
  local pat = "[" .. set .. "]"
  while self.point <= #self.text and self.text:sub(self.point, self.point):match(pat) do
    self.point = self.point + 1
  end
end

--- Is the line `n` lines away (-1 previous, 1 next) blank?
function M:line_empty_p(n)
  local row = self:rowcol()
  local target = row + n
  local lines = self:lines()
  if target < 1 or target > #lines then
    return false
  end
  return lines[target]:match("^%s*$") ~= nil
end

--- Lines of the buffer text (without the implicit final newline).
function M:lines()
  local t = self.text
  if t:sub(-1) == "\n" then
    t = t:sub(1, -2)
  end
  return vim.split(t, "\n", { plain = true })
end

--- Write the changed lines back and put the cursor at point.
---@param set_cursor? boolean default true
function M:apply(set_cursor)
  local new = self:lines()
  local old = self.orig
  local s = 1
  while s <= #old and s <= #new and old[s] == new[s] do
    s = s + 1
  end
  local eo, en = #old, #new
  while eo >= s and en >= s and old[eo] == new[en] do
    eo, en = eo - 1, en - 1
  end
  if s <= eo or s <= en then
    vim.api.nvim_buf_set_lines(self.bufnr, s - 1, eo, false, vim.list_slice(new, s, en))
  end
  self.orig = new
  if set_cursor ~= false then
    local row, col = self:rowcol()
    row = math.min(row, #new)
    vim.api.nvim_win_set_cursor(0, { row, col })
  end
end

return M

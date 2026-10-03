---@mod org.babel.buffer Executing and clearing every block of a buffer or subtree
---
--- Part of org.babel: it adds its functions to that module, which it
--- requires back. Load it through `require("org.babel")`.

local blocks_mod = require("org.babel.blocks")
local utils = require("org.utils")

local M = require("org.babel")
local P = require("org.babel.internal")

local buf_lines = M.buf_lines
local get_file = M.get_file
local buffer_blocks = M._buffer_blocks
local resolve_buf = P.resolve_buf
local ns = vim.api.nvim_create_namespace("org.babel")

--- (org-babel-map-executables).
local function executables(bufnr, s, e)
  local lines, list = buffer_blocks(bufnr)
  local jobs = {}
  local covered = {}
  for _, b in ipairs(list) do
    if b.start >= s and b.finish <= e then
      jobs[#jobs + 1] = { line = b.start, col = 0 }
    end
    for l = b.start, b.finish do
      covered[l] = true
    end
    if b.results then
      for l = b.results.start, b.results.finish do
        covered[l] = true
      end
    end
  end
  local literal = blocks_mod.inline_literal_lines(lines)
  for i = s, math.min(e, #lines) do
    local l = lines[i]
    if not literal[i] and not covered[i] and not l:match("^%s*#%+") and not l:match("^%s*: ") then
      for _, ib in ipairs(M.inline_all(l)) do
        jobs[#jobs + 1] = { line = i, col = ib.s, inline = true }
      end
    end
  end
  table.sort(jobs, function(x, y)
    if x.line ~= y.line then
      return x.line < y.line
    end
    return x.col < y.col
  end)
  return jobs
end

--- Execute every executable of lines `s`..`e` in order, each one asked
--- about like Emacs (org-babel-execute-buffer).
---@param opts? { skip_confirm?: boolean, sync?: boolean, on_done?: fun(n: integer) }
local function execute_many(bufnr, s, e, opts)
  opts = opts or {}
  M.wipe_error_buffer()
  local jobs = executables(bufnr, s, e)
  if #jobs == 0 then
    utils.notify("No source blocks to evaluate")
    if opts.on_done then
      opts.on_done(0)
    end
    return
  end
  for _, job in ipairs(jobs) do
    job.mark = vim.api.nvim_buf_set_extmark(bufnr, ns, job.line - 1, math.max(job.col - 1, 0), {})
  end
  local i = 0
  local step
  local function stop()
    for k = i + 1, #jobs do
      pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, jobs[k].mark)
    end
    if opts.on_done then
      opts.on_done(i)
    end
  end
  -- a job that fails like an Emacs user-error stops the rest
  local function after(_, abort)
    if abort then
      return stop()
    end
    if opts.sync then
      return
    end
    vim.schedule(step)
  end
  step = function()
    i = i + 1
    local job = jobs[i]
    if not job then
      if opts.on_done then
        opts.on_done(#jobs)
      end
      return
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, job.mark, {})
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, job.mark)
    local lnum = pos[1] + 1
    local aborted = false
    local function sync_done(okv, abort)
      aborted = abort or false
      after(okv, abort)
    end
    if job.inline then
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
      local ib = M.inline_at(line, pos[2] + 1)
      if not ib then
        return step()
      end
      if opts.sync then
        M.execute_inline_at(bufnr, lnum, ib, { skip_confirm = opts.skip_confirm, sync = true, on_done = sync_done })
        if not aborted then
          return step()
        end
        return
      end
      M.execute_inline_at(bufnr, lnum, ib, { skip_confirm = opts.skip_confirm, on_done = after })
    else
      if opts.sync then
        M.execute({ bufnr = bufnr, lnum = lnum, skip_confirm = opts.skip_confirm, sync = true, on_done = sync_done })
        if not aborted then
          return step()
        end
        return
      end
      M.execute({ bufnr = bufnr, lnum = lnum, skip_confirm = opts.skip_confirm, on_done = after })
    end
  end
  step()
end

--- C-c C-v b: execute every src block, #+CALL line and inline element of
--- the buffer (org-babel-execute-buffer).
---@param opts? { bufnr?: integer, skip_confirm?: boolean, sync?: boolean, on_done?: fun(n: integer) }
function M.execute_buffer(opts)
  opts = opts or {}
  local bufnr = resolve_buf(opts.bufnr)
  execute_many(bufnr, 1, vim.api.nvim_buf_line_count(bufnr), opts)
end

--- C-c C-v s: the same for the subtree at the cursor.
---@param opts? { bufnr?: integer, lnum?: integer, skip_confirm?: boolean, sync?: boolean, on_done?: fun(n: integer) }
function M.execute_subtree(opts)
  opts = opts or {}
  local bufnr = resolve_buf(opts.bufnr)
  local file = get_file(bufnr)
  local lnum = opts.lnum or vim.api.nvim_win_get_cursor(0)[1]
  local hl = file and file:headline_at(lnum)
  local s, e = 1, vim.api.nvim_buf_line_count(bufnr)
  if hl then
    s, e = hl.line, hl.end_line
  end
  execute_many(bufnr, s, e, opts)
end

--- Delete the result of block `b` (org-babel-remove-result): the
--- `#+RESULTS:` keyword, its result and the blank lines before it.
local function remove_block_result(bufnr, b)
  local s, e = b.results.start, b.results.finish
  local lines = buf_lines(bufnr)
  while s - 1 > b.finish and lines[s - 1] and lines[s - 1]:match("^%s*$") do
    s = s - 1
  end
  vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, {})
end

--- Remove every result in the buffer.
function M.remove_all_results(bufnr)
  bufnr = resolve_buf(bufnr)
  local _, list = buffer_blocks(bufnr)
  local n = 0
  for i = #list, 1, -1 do
    local b = list[i]
    if b.results and b.results.start > b.finish then
      remove_block_result(bufnr, b)
      n = n + 1
    end
  end
  utils.notify(string.format("Removed %d result%s", n, n == 1 and "" or "s"))
  return n
end

--- Remove the results of the block at cursor. With a count (Emacs C-u),
--- remove every result in the buffer.
function M.remove_result()
  if vim.v.count > 0 then
    return M.remove_all_results()
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local b = M.at_block(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  if not b or not b.results then
    utils.notify("No results to remove")
    return
  end
  remove_block_result(bufnr, b)
end

--- Remove the `{{{results(...)}}}` after the inline src block or inline
--- call at the cursor, with the white space before it
--- (org-babel-remove-inline-result). Returns false when the cursor is not
--- on an inline src block or call.
function M.remove_inline_result()
  local bufnr = vim.api.nvim_get_current_buf()
  local ib = M.inline_at_cursor()
  if not ib then
    return false
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  -- the rest of the paragraph: the macro may follow on the next line
  local lines = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, -1, false)
  local para = {}
  for i, l in ipairs(lines) do
    if i > 1 and l:match("^%s*$") then
      break
    end
    para[#para + 1] = l
  end
  local text = table.concat(para, "\n")
  local from = ib.e + 1
  local ws = text:match("^[ \t\n]*", from)
  local ms = from + #ws
  if not text:sub(ms):match("^{{{results%(") then
    return
  end
  local close = text:find(")}}}", ms, true)
  if not close then
    return
  end
  local stop = close + 3
  local function pos(offset)
    local row, col = 0, offset - 1
    for _, l in ipairs(para) do
      if col <= #l then
        break
      end
      col = col - #l - 1
      row = row + 1
    end
    return lnum - 1 + row, col
  end
  local srow, scol = pos(from)
  local erow, ecol = pos(stop + 1)
  vim.api.nvim_buf_set_text(bufnr, srow, scol, erow, ecol, {})
end

--- The `:cache` hash of the `#+RESULTS[hash]` line `line` when byte column
--- `col` (1-based) is on it.
function M.hash_at(line, col)
  local pre, hash = line:match("^([ \t]*#%+[Rr][Ee][Ss][Uu][Ll][Tt][Ss]%[%([^)]+%) )(%w+)%]:")
  if not pre then
    pre, hash = line:match("^([ \t]*#%+[Rr][Ee][Ss][Uu][Ll][Tt][Ss]%[)(%w+)%]:")
  end
  if pre and col > #pre and col <= #pre + #hash then
    return hash
  end
end

--- C-c C-c on the hash of a `#+RESULTS[hash]` line: copy the hash to the
--- unnamed register and show it (org-babel-hash-at-point). Returns false
--- when the cursor is not on a hash.
function M.hash_at_point()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local hash = M.hash_at(vim.api.nvim_get_current_line(), col)
  if not hash then
    return false
  end
  vim.fn.setreg('"', hash)
  vim.api.nvim_echo({ { hash } }, true, {})
  return hash
end

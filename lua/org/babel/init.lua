---@mod org.babel Source block evaluation, tangling and editing
---
--- Evaluation runs asynchronously via `vim.system` (Lua blocks run inside
--- Neovim), as a job of org.babel.jobs (spinner, cancelling). Results are
--- written below the block as `#+RESULTS:`.

local blocks_mod = require("org.babel.blocks")
local langs = require("org.babel.langs")
local lisp = require("org.babel.lisp")
local results = require("org.babel.results")
local session_mod = require("org.babel.session")
local utils = require("org.utils")

local M = {}

-- The parts required at the end of this file add their functions to M
-- and require it back, so it must be in package.loaded before them.
package.loaded["org.babel"] = M

local ns = vim.api.nvim_create_namespace("org.babel")

M.parse_blocks = blocks_mod.parse_blocks
M.parse_header_string = blocks_mod.parse_header_string
M.dedent = blocks_mod.dedent

local function buf_lines(bufnr)
  if type(bufnr) == "table" then
    return bufnr -- a list of lines (export)
  end
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function resolve_buf(bufnr)
  if not bufnr or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local function get_file(bufnr)
  if type(bufnr) == "table" then
    return require("org.parser").parse(bufnr)
  end
  local ok, f = pcall(function()
    return require("org.files").get_buffer(bufnr)
  end)
  return ok and f or nil
end
M.buf_lines = buf_lines
M.get_file = get_file

-- parse_blocks of the last buffer asked about, keyed by its changedtick:
-- inserting a result changes the tick, so positions are never stale.
-- Callers must treat the blocks as read-only (at_block hands out copies).
local blocks_cache

--- The lines and parsed blocks of `bufnr` (a buffer or a list of lines).
---@return string[] lines, table[] blocks
local function buffer_blocks(bufnr)
  if type(bufnr) ~= "number" then
    return bufnr, blocks_mod.parse_blocks(bufnr)
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  -- the bodies depend on src_preserve_indentation too
  local preserve = require("org.config").opts.src_preserve_indentation
  local c = blocks_cache
  if c and c.bufnr == bufnr and c.tick == tick and c.preserve == preserve then
    return c.lines, c.list
  end
  local lines = buf_lines(bufnr)
  local list = blocks_mod.parse_blocks(lines)
  blocks_cache = { bufnr = bufnr, tick = tick, preserve = preserve, lines = lines, list = list }
  return lines, list
end
M._buffer_blocks = buffer_blocks

--- Block containing `lnum` (begin line .. end line, the #+NAME/#+HEADER
--- lines above it, or its #+RESULTS), or a #+CALL line. Returns nil otherwise.
function M.at_block(bufnr, lnum)
  bufnr = resolve_buf(bufnr)
  local lines, list = buffer_blocks(bufnr)
  for _, b in ipairs(list) do
    local top = b.start
    local k = b.start - 1
    while k >= 1 and lines[k]:match("^%s*#%+[%a_]+:") and not lines[k]:match("^%s*#%+[Rr][Ee][Ss][Uu][Ll][Tt][Ss]") do
      top = k
      k = k - 1
    end
    if
      (lnum >= top and lnum <= b.finish)
      or (b.results and lnum >= b.results.start and lnum <= b.results.finish and not b.call)
    then
      -- a copy: the cached block stays untouched
      b = vim.deepcopy(b)
      b.file = get_file(bufnr)
      b.args = M.block_args(b, b.file, bufnr)
      return b
    end
  end
  return nil
end

--- Header args of a call (#+CALL line or inline `call_`) of `target`,
--- merged like org-babel-lob-get-info: the target's header args, then
--- `babel.default_lob_header_args`, the properties at the call, the inside
--- header `[...]`, the arguments (positional ones fill the target's
--- variables in order) and the end header.
---@param call { start: integer, inside?: string, call_args?: string, params?: string }
function M.call_header_args(target, call, file)
  local cfg = require("org.config").opts.babel or {}
  local state = { pos = 0 }
  local args = blocks_mod.header_args(target, not target.lob and file or nil, nil, { no_finish = true, state = state })
  blocks_mod.merge(args, blocks_mod.dict_pairs(cfg.default_lob_header_args or { exports = "results" }), state)
  if file then
    local lang = target.lang
    blocks_mod.merge(args, M.parse_header_string(blocks_mod.inherited_property(file, call.start, "HEADER-ARGS")), state)
    if lang and lang ~= "" then
      local p = blocks_mod.inherited_property(file, call.start, "HEADER-ARGS:" .. lang)
      blocks_mod.merge(args, M.parse_header_string(p), state)
    end
  end
  blocks_mod.merge(args, M.parse_header_string(call.inside or ""), state)
  blocks_mod.merge(args, blocks_mod.call_args(call.call_args or ""), state)
  blocks_mod.merge(args, M.parse_header_string(call.params or ""), state)
  return blocks_mod.finish(args)
end

--- Merged header args for a block (resolving #+CALL targets).
function M.block_args(b, file, bufnr)
  if b.call then
    local target = M.find_named_block(bufnr, b.target)
    if not target then
      return nil
    end
    local args = M.call_header_args(target, {
      start = b.start,
      inside = table.concat(b.header_lines, " "),
      call_args = b.call_args,
      params = b.params,
    }, file)
    return args, target
  end
  return blocks_mod.header_args(b, file)
end

--- The src block named `name` in `lines_or_buf` (a list of lines or a
--- buffer), or in the Library of Babel.
function M.find_named_block(lines_or_buf, name)
  local _, list = buffer_blocks(lines_or_buf)
  for _, b in ipairs(list) do
    if not b.call and b.name == name then
      return type(lines_or_buf) == "number" and vim.deepcopy(b) or b
    end
  end
  if M.library[name] then
    return vim.deepcopy(M.library[name])
  end
end

-- shared with the parts below
local P = require("org.babel.internal")
P.resolve_buf = resolve_buf

require("org.babel.noweb")
require("org.babel.vars")
require("org.babel.exec")
require("org.babel.params")
require("org.babel.evaluate")
require("org.babel.inline")
require("org.babel.buffer")
require("org.babel.edit")
require("org.babel.commands")
require("org.babel.export")
require("org.babel.check")

return M

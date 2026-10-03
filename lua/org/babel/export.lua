---@mod org.babel.export Evaluation during export (org-export-use-babel)
---
--- Part of org.babel: it adds its functions to that module, which it
--- requires back. Load it through `require("org.babel")`.

local blocks_mod = require("org.babel.blocks")
local session_mod = require("org.babel.session")
local utils = require("org.utils")

local M = require("org.babel")
local P = require("org.babel.internal")

local buf_lines = M.buf_lines
local get_file = M.get_file
local resolve_buf = P.resolve_buf
local ns = vim.api.nvim_create_namespace("org.babel")
local in_commented = M.in_commented
local buf_dir = M.buf_dir

---------------------------------------------------------------------------
-- Evaluation during export (org-export-use-babel)
---------------------------------------------------------------------------

--- Evaluate the code of `bufnr` for export and return the resulting lines;
--- the buffer itself is not changed. Like Emacs: blocks and #+CALL lines
--- with `:exports results|both` are evaluated and their results replaced,
--- `:exports code|none` blocks only run when they use a session (to keep it
--- in step), inline src blocks and calls get their `{{{results}}}`, and
--- `:eval never-export|no-export` (or never/no) blocks are left alone.
---@param lines? string[] the lines to evaluate (default: the buffer's)
---@return string[]
function M.export_evaluate(bufnr, lines)
  bufnr = resolve_buf(bufnr)
  lines = lines or buf_lines(bufnr)
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
  vim.b[scratch].org_babel_dir = buf_dir(bufnr)
  local file = get_file(scratch)
  local jobs = {}
  local blocked = { never = true, no = true, ["never-export"] = true, ["no-export"] = true }
  for _, b in ipairs(blocks_mod.parse_blocks(lines)) do
    if not in_commented(file, b.start) then
      local args = M.block_args(b, file, scratch)
      if args and not blocked[args.eval or ""] then
        -- #+CALL lines get :exports results from babel.default_lob_header_args
        local exports = args.exports or "code"
        local silent = (exports == "code" or exports == "none") and session_mod.name(args.session) ~= nil
        if exports == "results" or exports == "both" or silent then
          jobs[#jobs + 1] = { line = b.start, silent = silent }
        end
      end
    end
  end
  -- Inline objects may occur in greater elements and verse blocks.
  local literal = blocks_mod.inline_literal_lines(lines)
  for i, l in ipairs(lines) do
    if not literal[i] and not l:match("^%s*#%+") and not l:match("^%s*:") and not in_commented(file, i) then
      for _, ib in ipairs(M.inline_all(l)) do
        jobs[#jobs + 1] = { line = i, inline = ib, col = ib.s }
      end
    end
  end
  table.sort(jobs, function(x, y)
    if x.line ~= y.line then
      return x.line < y.line
    end
    return (x.col or 0) < (y.col or 0)
  end)
  for _, job in ipairs(jobs) do
    job.mark = vim.api.nvim_buf_set_extmark(scratch, ns, job.line - 1, (job.col or 1) - 1, {})
  end
  -- like Emacs, each block is confirmed on its own (org-confirm-babel-evaluate,
  -- :eval query / query-export)
  for _, job in ipairs(jobs) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(scratch, ns, job.mark, {})
    local lnum = pos[1] + 1
    local ok, err = pcall(function()
      if job.inline then
        local line = vim.api.nvim_buf_get_lines(scratch, lnum - 1, lnum, false)[1] or ""
        local ib = M.inline_at(line, pos[2] + 1)
        if ib then
          M.execute_inline_at(scratch, lnum, ib, { sync = true, export = true })
        end
      else
        M.execute({
          bufnr = scratch,
          lnum = lnum,
          sync = true,
          export = true,
          handling = job.silent and "none" or nil,
        })
      end
    end)
    if not ok then
      utils.error("babel (export): " .. tostring(err))
    end
  end
  local out = vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
  pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  return out
end

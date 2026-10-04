---@mod org.babel.inline Inline src blocks and inline calls
---
--- Part of org.babel: it adds its functions to that module, which it
--- requires back. Load it through `require("org.babel")`.

local blocks_mod = require("org.babel.blocks")
local jobs = require("org.babel.jobs")
local lisp = require("org.babel.lisp")
local results = require("org.babel.results")
local utils = require("org.utils")

local M = require("org.babel")
local P = require("org.babel.internal")

local buf_lines = M.buf_lines
local get_file = M.get_file
local buf_dir = M.buf_dir
local track_source = P.track_source
local take_source = P.take_source
local ns = vim.api.nvim_create_namespace("org.babel")

---------------------------------------------------------------------------
-- Inline src blocks: src_lang[:args]{body} {{{results(=value=)}}}
---------------------------------------------------------------------------

--- Inline src block or inline call of `line` covering column `col`
--- (1-based), or nil. Calls are `call_name[inside](args)[end]`.
---@return { lang?: string, params: string, body?: string, call?: boolean, target?: string, inside?: string, call_args?: string, s: integer, e: integer }|nil
function M.inline_at(line, col)
  for _, ib in ipairs(M.inline_all(line)) do
    if col >= ib.s and col <= ib.e then
      return ib
    end
  end
end

--- Start columns of the inline src blocks and inline calls that the object
--- parser finds in `line`, like `org-element-context`: none inside verbatim,
--- code, link paths, export snippets, macros or another inline block.
---@return table<integer, boolean>
function M.inline_object_starts(line)
  local element = require("org.export.element")
  local parser = element.new()
  local starts = {}
  local function walk(s, offset, R)
    local p, n = 1, #s
    while p <= n do
      local node, e = parser:object_at(s, p, R)
      if node then
        local span = s:sub(p, e - 1 - (node.post_blank or 0))
        local inner, at
        if node.type == "inline-src-block" or node.type == "inline-babel-call" then
          starts[offset + p] = true
        elseif node.inner then
          -- emphasis, sub/superscript: the contents end the object
          inner = node.inner
          local k = span:find(inner, 1, true)
          while k do
            at = k
            k = span:find(inner, k + 1, true)
          end
        elseif node.type == "link" and node.format == "bracket" then
          at, inner = span:match("^%[%[.-%]%[()(.*)%]%]$")
        elseif node.type == "footnote-reference" and node.fn_type == "inline" then
          at, inner = span:match("^%[fn:[^:%]]*:()(.*)%]$")
        end
        if inner and at then
          walk(inner, offset + p + at - 2, element.RESTRICTIONS[node.type] or element.RESTRICTIONS.paragraph)
        end
        p = e
      else
        p = p + 1
      end
    end
  end
  walk(line, 0, element.RESTRICTIONS.paragraph)
  return starts
end

--- Every inline src block and inline call of `line`, left to right. Like
--- Emacs, only real objects count: not text in verbatim, code, link paths
--- and the like, nor comment, fixed-width and table lines.
function M.inline_all(line)
  local list = M.inline_candidates(line)
  if #list == 0 then
    return list
  end
  if line:match("^%s*#%s") or line:match("^%s*#$") or line:match("^%s*:%s") or line:match("^%s*:$") then
    return {}
  end
  -- table cells can't contain inline Babel code (org-element-object-restrictions)
  if line:match("^%s*|") then
    return {}
  end
  local starts = M.inline_object_starts(line)
  return vim.tbl_filter(function(ib)
    return starts[ib.s] == true
  end, list)
end

--- Everything in `line` that looks like an inline src block or call.
function M.inline_candidates(line)
  local list = {}
  local init = 1
  while true do
    local s, _, kind = line:find("(%l+)_", init)
    if not s then
      return list
    end
    local found
    if (kind == "src" or kind == "call") and (s == 1 or not line:sub(s - 1, s - 1):match("[%w_]")) then
      local rest = line:sub(s)
      if kind == "src" then
        local lang, hdr, body = rest:match("^src_([^%s%[{]+)(%b[])(%b{})")
        if not lang then
          hdr = ""
          lang, body = rest:match("^src_([^%s%[{]+)(%b{})")
        end
        if lang then
          local params = hdr ~= "" and hdr:sub(2, -2) or ""
          found = { lang = lang, params = params, body = body:sub(2, -2), len = 4 + #lang + #hdr + #body }
        end
      else
        local name = rest:match("^call_([^%s%[%(]+)")
        if name then
          local after = rest:sub(6 + #name)
          local inside = after:match("^%b[]") or ""
          after = after:sub(#inside + 1)
          local cargs = after:match("^%b()")
          if cargs then
            after = after:sub(#cargs + 1)
            local ending = after:match("^%b[]") or ""
            found = {
              call = true,
              target = name,
              inside = inside:sub(2, -2),
              call_args = cargs:sub(2, -2),
              params = ending:sub(2, -2),
              len = 5 + #name + #inside + #cargs + #ending,
            }
          end
        end
      end
    end
    if found then
      found.s, found.e, found.len = s, s + found.len - 1, nil
      list[#list + 1] = found
      init = found.e + 1
    else
      init = s + 1
    end
  end
end

function M.inline_at_cursor()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  return M.inline_at(vim.api.nvim_get_current_line(), col)
end

--- Evaluate the inline src block or inline call at the cursor and insert or
--- replace its `{{{results(...)}}}` right after it (C-c C-c on it).
function M.execute_inline(opts)
  local ib = M.inline_at_cursor()
  if not ib then
    return false
  end
  return M.execute_inline_at(vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1], ib, opts)
end

--- Source block and header args of an inline element of line `lnum`.
function M.inline_info(bufnr, lnum, ib, file)
  if ib.call then
    local target = M.find_named_block(buf_lines(bufnr), ib.target)
    if not target then
      return nil
    end
    local args = M.call_header_args(target, {
      start = lnum,
      inside = ib.inside,
      call_args = ib.call_args,
      params = ib.params,
    }, file)
    return target, args
  end
  local src = { start = lnum, lang = ib.lang, params = ib.params, header_lines = {}, inline = true }
  src.body = { (ib.body:gsub("\n[ \t]*", " ")) }
  return src, blocks_mod.header_args(src, file, nil, { inline = true })
end

--- Evaluate the inline element `ib` (from `M.inline_at`) of line `lnum`.
---@param opts? { skip_confirm?: boolean, sync?: boolean, export?: boolean, on_done?: fun(ok: boolean, abort?: boolean) }
function M.execute_inline_at(bufnr, lnum, ib, opts)
  opts = opts or {}
  local done = opts.on_done or function() end
  local file = get_file(bufnr)
  local src, args = M.inline_info(bufnr, lnum, ib, file)
  if not src then
    utils.error("call_" .. ib.target .. ": no block named " .. ib.target)
    done(false, true)
    return
  end
  local source = track_source(bufnr, lnum - 1, ib.s - 1, lnum - 1, ib.e)
  local job
  local function finish(result, info)
    if job and job.cancelled then
      return
    end
    jobs.finish(job)
    local pos, abort = take_source(bufnr, source)
    if not pos then
      done(false, abort)
      return
    end
    if info.skipped then
      done(false, info.abort)
      return
    end
    local iargs = args
    if info.drop_file then
      iargs = vim.deepcopy(args)
      iargs.results_spec.type = nil
    end
    local rp = results.result_params(iargs)
    if rp.none then
      done(true)
      return
    end
    if rp.silent then
      -- :results silent echoes the value (message "%S")
      utils.notify(lisp.prin1(result))
      done(true)
      return
    end
    local text, err = results.format_inline(result, iargs, src.lang, { base_dir = buf_dir(bufnr), cwd = info.cwd })
    if not text then
      -- a user-error in Emacs: it also stops org-babel-execute-buffer
      utils.error(err)
      done(false, true)
      return
    end
    if pos and pos[1] then
      -- set_text keeps the extmarks of later inline elements of the line
      local row, col = pos[3].end_row, pos[3].end_col
      local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
      local after = line:sub(col + 1)
      local ws = after:match("^(%s*)")
      -- a raw result may hold newlines: they are inserted as they are
      local parts = vim.split(text, "\n", { plain = true })
      if after:sub(#ws + 1):match("^{{{results%(") then
        -- replace the existing macro (it ends at the first ")}}}")
        local e = after:find(")}}}", #ws + 1, true)
        local stop = e and (col + e + 3) or #line
        vim.api.nvim_buf_set_text(bufnr, row, col + #ws, row, stop, parts)
      else
        local before = line:sub(1, col)
        local trimmed = before:gsub("[ \t]+$", "")
        parts[1] = " " .. parts[1]
        vim.api.nvim_buf_set_text(bufnr, row, #trimmed, row, #trimmed, parts)
      end
    end
    M.fire("OrgBabelAfterExecute", { bufnr = bufnr, lang = src.lang, name = src.name, result = result, inline = true })
    done(info.error == nil)
  end
  local eopts = { sync = opts.sync, skip_confirm = opts.skip_confirm, export = opts.export }
  eopts.on_start = function()
    -- an asynchronous run: a spinner on the line, and it can be cancelled
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, source.mark, {})
    if pos[1] then
      job = jobs.start(bufnr, pos[1], { lang = src.lang, name = src.name })
      job.on_cancel = function()
        pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, source.mark)
        done(false, true)
      end
      eopts.job = job
    end
  end
  if opts.sync then
    local result, info = M.evaluate(bufnr, src, args, eopts)
    finish(result, info)
    return
  end
  M.evaluate(bufnr, src, args, eopts, finish)
end

--- Everything that can be executed in lines `s`..`e` of the buffer:
--- src blocks, #+CALL lines, inline src blocks and inline calls, in order

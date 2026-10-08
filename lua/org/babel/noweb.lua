---@mod org.babel.noweb Noweb references (<<name>>) in src block bodies
---
--- Part of org.babel: it adds its functions to that module, which it
--- requires back. Load it through `require("org.babel")`.

local blocks_mod = require("org.babel.blocks")
local lisp = require("org.babel.lisp")
local utils = require("org.utils")

local M = require("org.babel")
local P = require("org.babel.internal")

local get_file = M.get_file
local buffer_blocks = M._buffer_blocks

---------------------------------------------------------------------------
-- Noweb
---------------------------------------------------------------------------

--- Is `lnum` inside a COMMENT headline (or one of its descendants)?
local function in_commented(file, lnum)
  local hl = file and file:headline_at(lnum)
  while hl do
    if hl.commented then
      return true
    end
    hl = hl.parent
  end
  return false
end
M.in_commented = in_commented

local function noweb_for(args, purpose)
  local v = args.noweb or "no"
  if purpose == "eval" then
    local expand = {
      yes = true,
      eval = true,
      ["no-export"] = true,
      ["strip-export"] = true,
      ["tangle-eval"] = true,
      ["strip-tangle"] = true,
    }
    return expand[v] and "expand" or nil
  elseif purpose == "tangle" then
    if v == "strip-tangle" then
      return "strip"
    end
    return (v == "yes" or v == "tangle" or v == "no-export" or v == "strip-export" or v == "tangle-eval") and "expand"
      or nil
  elseif purpose == "export" then
    if v == "strip-export" then
      return "strip"
    end
    return (v == "yes" or v == "strip-tangle") and "expand" or nil
  end
end

--- Library of Babel: named blocks ingested from other files (`lob_ingest`).
M.library = {}

--- Expansion (list of lines) of the noweb reference `ref`.
local function noweb_reference(bufnr, ref, depth, purpose, ctx, parent_args)
  if ref:find("%(.*%)") then
    -- <<name(args)>>: the result of evaluating the named block with args
    local ok, v = pcall(M.resolve_var, bufnr, ref, {}, {}, { skip_confirm = ctx.skip_confirm })
    if not ok then
      if type(bufnr) == "number" and (purpose or "eval") == "eval" then
        error("noweb <<" .. ref .. ">>: " .. tostring(v), 0)
      end
      utils.warn("noweb <<" .. ref .. ">>: " .. tostring(v))
      return { "" }
    end
    if type(v) ~= "string" then
      v = lisp.prin1(v)
    end
    return vim.split(v, "\n", { plain = true })
  end
  -- :comments noweb wraps each expansion in link comments (ob-tangle)
  local comment = parent_args and parent_args.comments == "noweb" and purpose == "tangle"
  local function body_of(b, args, named)
    local nw = noweb_for(args, purpose or "eval")
    local body = b.body
    if nw then
      -- like org-babel-expand-noweb-references, an included block is
      -- expanded: only the block being tangled or exported strips
      body = M.expand_noweb(bufnr, b.body, depth + 1, nil, args, purpose)
    end
    -- like Emacs, a link comment points at the referenced block the first
    -- time it is looked up, then (from its reference cache) at the block
    -- being tangled
    local seen = M._noweb_seen
    local first = named and (not seen or not seen[ref])
    if named and seen then
      seen[ref] = true
    end
    if comment then
      local link_block = first and b or (M._noweb_parent or b)
      local beg_c, end_c = require("org.babel.tangle").comment_links(bufnr, b, ctx.file, nil, true, link_block)
      local cs, ce = require("org.babel.tangle").comment_delims(b.lang)
      local out = { cs .. beg_c .. ce }
      vim.list_extend(out, body)
      -- ob-tangle wraps the body as "BEG\nBODY\nEND\n": an empty line follows
      vim.list_extend(out, { cs .. end_c .. ce, "" })
      body = out
    end
    return body
  end
  -- the text of a headline with this CUSTOM_ID or ID
  local hbody = type(bufnr) == "number" and M.headline_body and M.headline_body(bufnr, ref, true)
  if hbody then
    return vim.split(hbody, "\n", { plain = true })
  end
  -- a block named `ref` is unique
  for _, b in ipairs(ctx.all) do
    if not b.call and b.name == ref and not in_commented(ctx.file, b.start) then
      return body_of(b, ctx.header_args(b), true)
    end
  end
  local lob = M.library[ref]
  if lob then
    return vim.deepcopy(lob.body)
  end
  -- all blocks with a matching :noweb-ref, each followed by its own
  -- :noweb-sep when another one comes after it
  local text, sep
  for _, b in ipairs(ctx.all) do
    if not b.call and not in_commented(ctx.file, b.start) then
      local args = ctx.header_args(b)
      if blocks_mod.unquote(args["noweb-ref"]) == ref then
        local chunk = table.concat(body_of(b, args), "\n")
        text = text and (text .. sep .. chunk) or chunk
        sep = args["noweb-sep"] and blocks_mod.unquote(args["noweb-sep"]):gsub("\\n", "\n") or "\n"
      end
    end
  end
  if not text then
    return { "" }
  end
  return vim.split(text, "\n", { plain = true })
end

--- Find the next noweb reference `<<ref>>` of `line` at or after `pos`,
--- like `org-babel-noweb-wrap`: the reference starts and ends with a
--- non-blank character and may contain spaces (`<<add(a=3, b=4)>>`).
---@return integer|nil s, integer? e, string? ref
local function find_noweb(line, pos)
  local cfg = require("org.config").opts.babel or {}
  local open, close = cfg.noweb_wrap_start or "<<", cfg.noweb_wrap_end or ">>"
  local init = pos
  while true do
    local s = line:find(open, init, true)
    if not s then
      return nil
    end
    local first = s + #open
    local c1 = line:sub(first, first)
    if c1 ~= "" and not c1:match("[ \t]") then
      -- the shortest reference ending with a non-blank character
      local from = first + 1
      while true do
        local e = line:find(close, from, true)
        if not e then
          break
        end
        if not line:sub(e - 1, e - 1):match("[ \t]") then
          return s, e + #close - 1, line:sub(first, e - 1)
        end
        from = e + 1
      end
    end
    init = s + 1
  end
end
M.find_noweb = find_noweb

-- The parsed blocks (and their header args) of a buffer, shared by the
-- noweb expansions of one operation while the buffer is unchanged, like
-- Emacs' org-babel-expand-noweb-references--cache.
local noweb_scope, noweb_cache = 0, nil

local function noweb_ctx(bufnr)
  local tick = type(bufnr) == "number" and vim.api.nvim_buf_get_changedtick(bufnr) or nil
  local c = noweb_cache
  if c and c.bufnr == bufnr and c.tick == tick then
    return c.ctx
  end
  local lines, all = buffer_blocks(bufnr)
  local file = get_file(bufnr)
  local ctx = { lines = lines, all = all, file = file, args = {} }
  function ctx.header_args(b)
    local a = ctx.args[b]
    if not a then
      a = blocks_mod.header_args(b, file)
      ctx.args[b] = a
    end
    return a
  end
  if noweb_scope > 0 then
    noweb_cache = { bufnr = bufnr, tick = tick, ctx = ctx }
  end
  return ctx
end

--- Run `fn(...)` with the noweb cache enabled: the noweb expansions it
--- makes share one parse of the buffer (tangling every block of a file).
function M.with_noweb_cache(fn, ...)
  noweb_scope = noweb_scope + 1
  local res = vim.F.pack_len(pcall(fn, ...))
  noweb_scope = noweb_scope - 1
  if noweb_scope == 0 then
    noweb_cache = nil
  end
  if not res[1] then
    error(res[2], 0)
  end
  return unpack(res, 2, res.n)
end

local expand_noweb

--- Expand <<ref>> references in body lines. `mode` "strip" removes them.
--- `args` are the header args of the expanded block (:noweb-prefix).
function M.expand_noweb(bufnr, body, depth, mode, args, purpose)
  return M.with_noweb_cache(expand_noweb, bufnr, body, depth, mode, args, purpose)
end

expand_noweb = function(bufnr, body, depth, mode, args, purpose)
  depth = depth or 0
  if depth > 20 then
    error("noweb: reference depth exceeded")
  end
  local ctx = noweb_ctx(bufnr)
  local prefix_opt = args and args["noweb-prefix"]
  local use_prefix = not (prefix_opt == "no" or prefix_opt == "nil")
  local out = {}
  for _, line in ipairs(body) do
    if not find_noweb(line, 1) then
      out[#out + 1] = line
    elseif mode == "strip" then
      local parts, pos = {}, 1
      while true do
        local s, e = find_noweb(line, pos)
        if not s then
          parts[#parts + 1] = line:sub(pos)
          break
        end
        parts[#parts + 1] = line:sub(pos, s - 1)
        pos = e + 1
      end
      -- the line stays, like replace-regexp-in-string in ob-tangle
      out[#out + 1] = table.concat(parts)
    else
      local built = { "" }
      local pos = 1
      while true do
        local s, e, ref = find_noweb(line, pos)
        if not s then
          built[#built] = built[#built] .. line:sub(pos)
          break
        end
        -- like Emacs, the prefix is the text between the previous
        -- reference (or the line start) and this one
        local prefix = use_prefix and line:sub(pos, s - 1) or ""
        built[#built] = built[#built] .. line:sub(pos, s - 1)
        for i, x in ipairs(noweb_reference(bufnr, ref, depth, purpose, ctx, args)) do
          if i == 1 then
            built[#built] = built[#built] .. x
          else
            built[#built + 1] = prefix .. x
          end
        end
        pos = e + 1
      end
      vim.list_extend(out, built)
    end
  end
  return out
end

-- shared with the other parts of org.babel
P.noweb_for = noweb_for

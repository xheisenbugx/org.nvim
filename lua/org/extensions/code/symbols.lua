---@mod org.extensions.code.symbols Symbols of code buffers (LSP, treesitter, text)
---
--- Finding a symbol by name and naming the symbol at the cursor. The
--- language server's document symbols come first, then treesitter
--- definitions, then a text search for the name.

local M = {}

-- LSP SymbolKind values that name a definition worth linking to
local DEF_KINDS = {
  [2] = true, -- Module
  [3] = true, -- Namespace
  [5] = true, -- Class
  [6] = true, -- Method
  [9] = true, -- Constructor
  [10] = true, -- Enum
  [11] = true, -- Interface
  [12] = true, -- Function
  [23] = true, -- Struct
}

-- treesitter node types of definitions (matched as substrings)
local TS_DEF = { "function", "method", "class", "struct", "interface", "enum", "impl", "trait", "module", "type_spec" }

local function opts()
  return require("org.extensions").opts("code") or require("org.extensions.code").defaults
end

---------------------------------------------------------------------------
-- LSP
---------------------------------------------------------------------------

local function supports_symbols(client)
  if client.supports_method then
    local ok, res = pcall(client.supports_method, client, "textDocument/documentSymbol")
    if ok then
      return res
    end
    ok, res = pcall(client.supports_method, "textDocument/documentSymbol")
    if ok then
      return res
    end
  end
  return client.server_capabilities and client.server_capabilities.documentSymbolProvider and true or false
end

local function clients(buf)
  local list = {}
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if supports_symbols(c) then
      list[#list + 1] = c
    end
  end
  return list
end

-- Could a running client attach to `buf` soon (it serves its filetype)?
local function client_expected(buf)
  local ft = vim.bo[buf].filetype
  for _, c in ipairs(vim.lsp.get_clients()) do
    local fts = c.config and c.config.filetypes
    if fts and vim.tbl_contains(fts, ft) then
      return true
    end
  end
  return false
end

--- The document symbols of `buf` from its language servers, as a flat
--- list `{ name, full, kind, lnum, col, end_lnum }` (1-based lines, 0-based
--- byte columns; `full` joins the names of the enclosing symbols with ".").
--- `wait`: wait up to `lsp_timeout` for a server to attach. nil without
--- a server.
---@param buf integer
---@param wait? boolean
---@return table[]|nil
function M.lsp_symbols(buf, wait)
  local timeout = opts().lsp_timeout or 1000
  if timeout <= 0 then
    return nil
  end
  if #clients(buf) == 0 then
    if not (wait and client_expected(buf)) then
      return nil
    end
    vim.wait(timeout, function()
      return #clients(buf) > 0
    end, 20)
    if #clients(buf) == 0 then
      return nil
    end
  end
  local params = { textDocument = { uri = vim.uri_from_bufnr(buf) } }
  local ok, res = pcall(vim.lsp.buf_request_sync, buf, "textDocument/documentSymbol", params, timeout)
  if not ok or type(res) ~= "table" then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local function bytecol(lnum, col)
    local line = lines[lnum] or ""
    local bok, b = pcall(vim.str_byteindex, line, col, true)
    return bok and b or col
  end
  local out = {}
  local function add(sym, parent)
    local range = sym.selectionRange or sym.range or (sym.location and sym.location.range)
    if not range then
      return
    end
    local full = sym.name
    if parent then
      full = parent .. "." .. sym.name
    elseif sym.containerName and sym.containerName ~= "" then
      full = sym.containerName .. "." .. sym.name
    end
    local whole = sym.range or (sym.location and sym.location.range) or range
    out[#out + 1] = {
      name = sym.name,
      full = full,
      kind = sym.kind,
      lnum = range.start.line + 1,
      col = bytecol(range.start.line + 1, range.start.character),
      start_lnum = whole.start.line + 1,
      end_lnum = whole["end"].line + 1,
    }
    for _, child in ipairs(sym.children or {}) do
      add(child, full)
    end
  end
  for _, r in pairs(res) do
    for _, sym in ipairs((r and r.result) or {}) do
      add(sym)
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Treesitter
---------------------------------------------------------------------------

local function ts_root(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return nil
  end
  local tok, trees = pcall(parser.parse, parser)
  if not tok or not trees or not trees[1] then
    return nil
  end
  return trees[1]:root()
end

local function is_def(node)
  local t = node:type()
  local decl = t:find("definition", 1, true)
    or t:find("declaration", 1, true)
    or t:find("item", 1, true)
    or t:find("spec", 1, true)
  if not decl then
    return false
  end
  for _, d in ipairs(TS_DEF) do
    if t:find(d, 1, true) then
      return true
    end
  end
  return false
end

local function def_name(node, buf)
  local name = node:field("name")[1]
  if not name then
    return nil
  end
  return vim.treesitter.get_node_text(name, buf)
end

---------------------------------------------------------------------------
-- Finding a symbol
---------------------------------------------------------------------------

local function last_segment(sym)
  return sym:match("([^.:#]+)$") or sym
end

-- Rank of a symbol entry for the name `sym` (0 = no match).
local function score(name, full, sym)
  if name == sym or full == sym then
    return 3
  end
  local last = last_segment(sym)
  -- "M.foo" asked, "foo" found (or the other way round)
  if last_segment(name) == last and (full:sub(-#sym) == sym or name:sub(-#sym) == sym) then
    return 2
  end
  if last_segment(name) == last then
    return 1
  end
  return 0
end

--- Position of symbol `sym` in `buf` from treesitter definitions.
local function ts_find(buf, sym)
  local root = ts_root(buf)
  if not root then
    return nil
  end
  local best, best_score
  local function walk(node, depth)
    if depth > 60 then
      return
    end
    if is_def(node) then
      local name = def_name(node, buf)
      if name then
        local s = score(name, name, sym)
        if s > 0 and (not best_score or s > best_score) then
          local nm = node:field("name")[1]
          local r, c = nm:range()
          best, best_score = { lnum = r + 1, col = c }, s
        end
      end
    end
    for child in node:iter_children() do
      walk(child, depth + 1)
    end
  end
  walk(root, 0)
  return best
end

--- Position of `sym` by searching the text: a definition line first
--- (`function sym`, `def sym`, `class sym`, `sym = ...`), then any
--- whole-word occurrence.
---@param lines string[]
---@param sym string
---@return { lnum: integer, col: integer }|nil
function M.text_find(lines, sym)
  local last = last_segment(sym)
  local esym, elast = vim.pesc(sym), vim.pesc(last)
  local keywords = {
    "function", "def", "class", "fn", "func", "struct", "interface", "enum", "type", "trait", "impl", "module",
    "macro", "local", "const", "let", "var", "sub", "proc",
  }
  local tries = {
    function(l)
      return l:find("function%s+" .. esym .. "%f[^%w_]")
    end,
    function(l)
      for _, k in ipairs(keywords) do
        local s = l:find("%f[%w_]" .. k .. "%s+[%w_%*&%.:]-" .. elast .. "%f[^%w_]")
        if s then
          return l:find(elast .. "%f[^%w_]", s)
        end
      end
    end,
    function(l)
      return l:find("^%s*" .. esym .. "%s*[:=]")
    end,
    function(l)
      return l:find("%f[%w_]" .. elast .. "%f[^%w_]")
    end,
  }
  for _, try in ipairs(tries) do
    for i, l in ipairs(lines) do
      local s = try(l)
      if s then
        local c = l:find(elast, s, true) or s
        return { lnum = i, col = c - 1 }
      end
    end
  end
  return nil
end

--- Where `sym` is defined in `buf`: `{ lnum, col, via }` (via = "lsp",
--- "treesitter" or "text"), or nil.
---@param buf integer
---@param sym string
---@return table|nil
function M.find(buf, sym)
  local syms = M.lsp_symbols(buf, true)
  if syms then
    local best, best_score
    for _, s in ipairs(syms) do
      local sc = score(s.name, s.full, sym)
      if sc > 0 and (not best_score or sc > best_score) then
        best, best_score = s, sc
      end
    end
    if best then
      return { lnum = best.lnum, col = best.col, via = "lsp" }
    end
  end
  local ts = ts_find(buf, sym)
  if ts then
    ts.via = "treesitter"
    return ts
  end
  local t = M.text_find(vim.api.nvim_buf_get_lines(buf, 0, -1, false), sym)
  if t then
    t.via = "text"
  end
  return t
end

--- Name of the innermost definition around line `lnum` of `buf` (LSP, then
--- treesitter), or nil.
---@param buf integer
---@param lnum integer
---@param col? integer 0-based
---@return string|nil
function M.at(buf, lnum, col)
  local syms = M.lsp_symbols(buf, false)
  if syms then
    local best
    for _, s in ipairs(syms) do
      if DEF_KINDS[s.kind] and s.start_lnum <= lnum and lnum <= s.end_lnum then
        if not best or (s.end_lnum - s.start_lnum) <= (best.end_lnum - best.start_lnum) then
          best = s
        end
      end
    end
    if best then
      return best.name
    end
  end
  local root = ts_root(buf)
  if not root then
    return nil
  end
  local ok, node = pcall(root.named_descendant_for_range, root, lnum - 1, col or 0, lnum - 1, col or 0)
  node = ok and node or nil
  while node do
    if is_def(node) then
      local name = def_name(node, buf)
      if name then
        return name
      end
    end
    node = node:parent()
  end
  return nil
end

return M

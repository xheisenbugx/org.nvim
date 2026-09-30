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

-- LSP SymbolKind values whose name qualifies the symbols inside them
-- (`Class.method`)
local CONTAINER_KINDS = { [2] = true, [3] = true, [5] = true, [10] = true, [11] = true, [23] = true }

-- treesitter node types of definitions (matched as substrings of types
-- that also contain "definition", "declaration", "item" or "spec")
local TS_DEF = {
  "function",
  "method",
  "class",
  "struct",
  "interface",
  "enum",
  "impl",
  "trait",
  "module",
  "mod_item",
  "namespace",
  "type_spec",
  "type_alias",
  "type_item",
  "macro",
  "constructor",
}

-- of those, the ones whose name qualifies the definitions inside them
local TS_CONTAINER = { "class", "struct", "interface", "enum", "impl", "trait", "module", "mod_item", "namespace" }

-- node types that are definitions whatever their name (Ruby)
local TS_EXACT = { method = "def", singleton_method = "def", class = "container", module = "container" }

-- nodes that bind a name to a value: a definition when the value is a
-- function or a class (`const f = () => {}`, `M.f = function() end`)
local TS_BINDING = { variable_declarator = true, assignment_statement = true, field = true, pair = true }

local function opts()
  return require("org.extensions").opts("code") or require("org.extensions.code").defaults
end

---------------------------------------------------------------------------
-- LSP
---------------------------------------------------------------------------

local METHOD = "textDocument/documentSymbol"

--- Does `client` answer textDocument/documentSymbol? Neovim 0.11+ has
--- `client:supports_method(m)`; 0.10 only the field `client.supports_method(m)`,
--- which says yes to anything that is not a method name (so a colon call
--- there would accept every client).
---@param client table
---@return boolean
function M.supports_symbols(client)
  local mt = getmetatable(client)
  local cls = mt and type(mt.__index) == "table" and rawget(mt.__index, "supports_method")
  local ok, res
  if type(cls) == "function" then
    ok, res = pcall(cls, client, METHOD)
  elseif type(client.supports_method) == "function" then
    ok, res = pcall(client.supports_method, METHOD)
  end
  if ok then
    return res and true or false
  end
  return client.server_capabilities and client.server_capabilities.documentSymbolProvider and true or false
end

local function clients(buf)
  local list = {}
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    if M.supports_symbols(c) then
      list[#list + 1] = c
    end
  end
  return list
end

-- Will a server attach to `buf` soon? One that is starting for it
-- (vim.lsp.start or vim.lsp.enable ran on FileType and it is still
-- initializing), or a running one that serves its filetype.
local function client_expected(buf)
  -- `_uninitialized` (0.10 to 0.12) also lists clients still initializing
  local ok, starting = pcall(vim.lsp.get_clients, { bufnr = buf, _uninitialized = true })
  if ok and #starting > 0 then
    return true
  end
  local ft = vim.bo[buf].filetype
  for _, c in ipairs(vim.lsp.get_clients()) do
    local fts = c.config and c.config.filetypes
    if fts and vim.tbl_contains(fts, ft) then
      return true
    end
  end
  return false
end

--- Byte column of the `index` of a position in `line` counted in
--- `encoding` ("utf-8", "utf-16" or "utf-32").
---@param line string
---@param index integer
---@param encoding? string
---@return integer
function M.byte_col(line, index, encoding)
  encoding = encoding or "utf-16"
  if encoding == "utf-8" or index <= 0 then
    return math.min(math.max(index, 0), #line)
  end
  local ok, b
  if vim.fn.has("nvim-0.11") == 1 then
    ok, b = pcall(vim.str_byteindex, line, encoding, index, false)
  else
    ok, b = pcall(vim.str_byteindex, line, index, encoding == "utf-16")
  end
  if ok and type(b) == "number" then
    return b
  end
  return math.min(index, #line)
end

local function encoding_of(client_id)
  local c = vim.lsp.get_client_by_id and vim.lsp.get_client_by_id(client_id)
  return c and c.offset_encoding or "utf-16"
end

--- The document symbols of `buf` from its language servers, as a flat
--- list `{ name, full, qual, kind, lnum, col, start_lnum, end_lnum }`
--- (1-based lines, 0-based byte columns; `full` joins the names of the
--- enclosing symbols with ".", `qual` only those of enclosing classes,
--- modules... ). `wait`: wait up to `lsp_timeout` for a server that is
--- starting (or serves the filetype) to attach. nil without a server.
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
  local ok, res = pcall(vim.lsp.buf_request_sync, buf, METHOD, params, timeout)
  if not ok or type(res) ~= "table" then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local out = {}
  local function add(sym, parent, enc)
    local range = sym.selectionRange or sym.range or (sym.location and sym.location.range)
    if not range or type(sym.name) ~= "string" then
      return
    end
    local full, qual = sym.name, sym.name
    if parent then
      full = parent.full .. "." .. sym.name
      if parent.container then
        qual = parent.qual .. "." .. sym.name
      end
    elseif sym.containerName and sym.containerName ~= "" then
      full = sym.containerName .. "." .. sym.name
      qual = full
    end
    local whole = sym.range or (sym.location and sym.location.range) or range
    local lnum = range.start.line + 1
    out[#out + 1] = {
      name = sym.name,
      full = full,
      qual = qual,
      kind = sym.kind,
      lnum = lnum,
      col = M.byte_col(lines[lnum] or "", range.start.character, enc),
      start_lnum = whole.start.line + 1,
      end_lnum = whole["end"].line + 1,
    }
    local me = { full = full, qual = qual, container = CONTAINER_KINDS[sym.kind] or false }
    for _, child in ipairs(sym.children or {}) do
      add(child, me, enc)
    end
  end
  for id, r in pairs(res) do
    if type(r) == "table" and type(r.result) == "table" then
      local enc = encoding_of(id)
      for _, sym in ipairs(r.result) do
        add(sym, nil, enc)
      end
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

local function has_word(t, words)
  for _, d in ipairs(words) do
    if t:find(d, 1, true) then
      return true
    end
  end
  return false
end

local function is_function_value(node)
  local t = node and node:type() or ""
  return t:find("function", 1, true) ~= nil or t:find("arrow", 1, true) ~= nil or t == "lambda"
end

-- The name and value nodes of a binding (see TS_BINDING).
local function binding(node)
  if node:type() == "assignment_statement" then
    -- Lua: (variable_list name: ...) (expression_list value: ...)
    local vars, exprs = node:named_child(0), node:named_child(1)
    return vars and vars:field("name")[1], exprs and exprs:field("value")[1]
  end
  return node:field("name")[1] or node:field("key")[1], node:field("value")[1]
end

--- Is `node` a definition? "def", "container" (a definition whose name
--- qualifies the ones inside it) or nil.
---@param node TSNode
---@return string|nil
local function def_kind(node)
  local t = node:type()
  if TS_EXACT[t] then
    return TS_EXACT[t]
  end
  if TS_BINDING[t] then
    local name, value = binding(node)
    if name and value then
      if is_function_value(value) then
        return "def"
      elseif value:type():find("class", 1, true) then
        return "container"
      end
    end
    return nil
  end
  local decl = t:find("definition", 1, true) or t:find("declaration", 1, true) or t:find("item", 1, true)
  if not decl and t:find("spec", 1, true) then
    -- C/C++ struct_specifier...: a definition only with a body
    decl = not t:find("specifier", 1, true) or node:field("body")[1] ~= nil
  end
  if not decl or not has_word(t, TS_DEF) then
    return nil
  end
  return has_word(t, TS_CONTAINER) and "container" or "def"
end

--- The node naming definition `node`, or nil.
---@param node TSNode
---@return TSNode|nil
local function name_node(node)
  local t = node:type()
  if TS_BINDING[t] then
    return (binding(node))
  end
  local name = node:field("name")[1]
  if name then
    return name
  end
  -- C/C++: follow the declarators to the identifier
  local d = node:field("declarator")[1]
  for _ = 1, 10 do
    local inner = d and d:field("declarator")[1]
    if not inner then
      break
    end
    d = inner
  end
  if d and d:type():find("identifier", 1, true) then
    return d
  end
  -- Rust: `impl Type { ... }`
  if t == "impl_item" then
    return node:field("type")[1]
  end
  return nil
end

local function node_text(node, buf)
  local ok, text = pcall(vim.treesitter.get_node_text, node, buf)
  return ok and text or nil
end

--- Name of definition `node` qualified by the containers around it
--- (`Greeter.hello` for a method of a class), unless it is qualified
--- already (`M.setup`).
local function qualified(node, name, buf)
  if name:find("[.:]") then
    return name
  end
  local parts = { name }
  local p = node:parent()
  local depth = 0
  while p and depth < 60 do
    if def_kind(p) == "container" then
      local nn = name_node(p)
      local text = nn and node_text(nn, buf)
      if text and not text:find("\n", 1, true) then
        table.insert(parts, 1, text)
        if text:find("[.:]") then
          break
        end
      end
    end
    p = p:parent()
    depth = depth + 1
  end
  return table.concat(parts, ".")
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

--- Position of symbol `sym` in the tree `root` of `source` (a buffer or
--- the text) from treesitter definitions: `{ lnum, col }` and `{ first,
--- last, len }` (the lines of the whole definition, the name's length).
--- Only the places where the last segment of the name occurs are looked
--- at (from the node there up to its definition), not the whole tree.
local function ts_search(root, source, sym, lines)
  local last = last_segment(sym)
  if last == "" then
    return nil
  end
  local best, best_score, def
  for i, l in ipairs(lines) do
    local init = 1
    while true do
      local s = l:find(last, init, true)
      if not s then
        break
      end
      init = s + #last
      local ok, node = pcall(root.named_descendant_for_range, root, i - 1, s - 1, i - 1, s - 1)
      node = ok and node or nil
      local depth = 0
      while node and depth < 8 do
        if def_kind(node) then
          local nn = name_node(node)
          if nn then
            local sr, sc, er, ec = nn:range()
            -- the occurrence is the definition's name
            if sr <= i - 1 and i - 1 <= er and (sr < i - 1 or sc <= s - 1) and (er > i - 1 or s - 1 < ec) then
              local name = node_text(nn, source)
              if name then
                local sc2 = score(name, qualified(node, name, source), sym)
                if sc2 > 0 and (not best_score or sc2 > best_score) then
                  local dr, _, der, dec = node:range()
                  best, best_score = { lnum = sr + 1, col = sc }, sc2
                  -- a range ending at column 0 ends on the line before
                  def = { first = dr + 1, last = (dec == 0 and der > dr) and der or der + 1, len = #name }
                end
              end
            end
            break
          end
        end
        node = node:parent()
        depth = depth + 1
      end
      if best_score == 3 then
        return best, def
      end
    end
  end
  return best, def
end

local function ts_find(buf, sym, lines)
  local root = ts_root(buf)
  if not root then
    return nil
  end
  return (ts_search(root, buf, sym, lines))
end

local TEXT_KEYWORDS = {
  "function",
  "def",
  "class",
  "fn",
  "func",
  "struct",
  "interface",
  "enum",
  "type",
  "trait",
  "impl",
  "module",
  "macro",
  "local",
  "const",
  "let",
  "var",
  "sub",
  "proc",
}

--- Position of `sym` by searching the text: a definition line first
--- (`function sym`, `def sym`, `class sym`, `sym = ...`), then any
--- whole-word occurrence.
---@param lines string[]
---@param sym string
---@return { lnum: integer, col: integer }|nil
function M.text_find(lines, sym)
  local last = last_segment(sym)
  if last == "" then
    return nil
  end
  local esym, elast = vim.pesc(sym), vim.pesc(last)
  -- only the lines holding the name
  local cand = {}
  for i, l in ipairs(lines) do
    if l:find(last, 1, true) then
      cand[#cand + 1] = i
    end
  end
  local tries = {
    function(l)
      return l:find("function%s+" .. esym .. "%f[^%w_]")
    end,
    function(l)
      for _, k in ipairs(TEXT_KEYWORDS) do
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
    for _, i in ipairs(cand) do
      local l = lines[i]
      local s = try(l)
      if s then
        local c = l:find(last, s, true) or s
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
      local sc = math.max(score(s.name, s.full, sym), score(s.name, s.qual or s.full, sym))
      if sc > 0 and (not best_score or sc > best_score) then
        best, best_score = s, sc
      end
    end
    if best then
      return { lnum = best.lnum, col = best.col, via = "lsp" }
    end
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ts = ts_find(buf, sym, lines)
  if ts then
    ts.via = "treesitter"
    return ts
  end
  local t = M.text_find(lines, sym)
  if t then
    t.via = "text"
  end
  return t
end

--- Name of the innermost definition around line `lnum` of `buf` (LSP, then
--- treesitter), qualified by its class or module (`Greeter.hello`), or nil.
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
      return best.qual or best.name
    end
  end
  local root = ts_root(buf)
  if not root then
    return nil
  end
  local ok, start = pcall(root.named_descendant_for_range, root, lnum - 1, col or 0, lnum - 1, col or 0)
  start = ok and start or nil
  local function name_of(node)
    if def_kind(node) then
      local nn = name_node(node)
      local name = nn and node_text(nn, buf)
      if name and name ~= "" and not name:find("\n", 1, true) then
        return qualified(node, name, buf)
      end
    end
  end
  local node = start
  while node do
    local name = name_of(node)
    if name then
      return name
    end
    node = node:parent()
  end
  -- the cursor on a keyword before the definition (`const f = () => {}`):
  -- a definition starting on this line below the node there
  local function below(n, depth)
    for child in n:iter_children() do
      if child:named() and child:start() == lnum - 1 then
        local name = name_of(child) or (depth < 3 and below(child, depth + 1))
        if name then
          return name
        end
      end
    end
  end
  return start and below(start, 0) or nil
end

--- Where `sym` is defined in file `path`, without loading it into a
--- buffer or asking a language server (for other extensions: the org
--- language server's go-to-definition, transclusion): `{ lnum, col, len,
--- first, last }` (`first`..`last` the lines of the whole definition when
--- treesitter found it, else the line), or nil.
---@param path string
---@param sym string
---@return table|nil
function M.find_in_file(path, sym)
  local buf = vim.fn.bufnr(path)
  local lines, source, root
  if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
    lines, source, root = vim.api.nvim_buf_get_lines(buf, 0, -1, false), buf, ts_root(buf)
  else
    local ok, l = pcall(vim.fn.readfile, path)
    if not ok then
      return nil
    end
    lines = l
    source = table.concat(lines, "\n")
    local ft = vim.filetype.match({ filename = path, contents = vim.list_slice(lines, 1, 5) })
    local lang = ft and vim.treesitter.language.get_lang(ft) or ft
    if lang and pcall(vim.treesitter.language.add, lang) then
      local pok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
      local tok, trees = pcall(function()
        return pok and parser and parser:parse() or nil
      end)
      root = tok and trees and trees[1] and trees[1]:root() or nil
    end
  end
  if root then
    local pos, def = ts_search(root, source, sym, lines)
    if pos then
      return { lnum = pos.lnum, col = pos.col, len = def.len, first = def.first, last = def.last }
    end
  end
  local t = M.text_find(lines, sym)
  if t then
    t.len, t.first, t.last = #last_segment(sym), t.lnum, t.lnum
  end
  return t
end

return M

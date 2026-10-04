---@mod org.symbols The outline of a buffer as document symbols
---
--- Headlines (each covering its subtree), named src blocks and tables,
--- and optionally `<<targets>>`, in the shape of LSP `DocumentSymbol`s:
--- 0-based lines, byte columns (UTF-8 positions). The `lsp` extension's
--- textDocument/documentSymbol, `org.api.symbols()` and the aerial.nvim and
--- outline.nvim providers (`lua/org/integrations/`) all come from here, so
--- they agree with each other. Built from the cached parse (`org.files`),
--- no language server needed.

local files = require("org.files")

local M = {}

--- Symbol kinds (`vim.lsp.protocol.SymbolKind` names) by what the symbol
--- is; the `lsp` extension's `symbol_kinds` option overrides them.
M.KINDS = {
  heading = "Namespace",
  todo = "Event",
  done = "Constant",
  src_block = "Function",
  table = "Struct",
  target = "Key",
}

---@param name string|integer|nil
---@return integer
local function kind_of(name)
  local kinds = vim.lsp.protocol.SymbolKind
  if type(name) == "number" then
    return name
  end
  return kinds[name] or kinds.Namespace
end

---@param kinds table|nil
---@param what string
local function kind_for(kinds, what)
  return kind_of((kinds or {})[what] or M.KINDS[what])
end

--- Symbol kind of a headline: `kinds.todo` / `kinds.done` by its TODO
--- state, else `kinds.heading`.
---@param hl org.Headline
---@param kinds? table names by what, defaults `M.KINDS`
---@return integer
function M.headline_kind(hl, kinds)
  if hl.todo then
    return kind_for(kinds, hl:is_done() and "done" or "todo")
  end
  return kind_for(kinds, "heading")
end

--- `TODO [#A] :tag1:tag2:`: the parts of a headline that are not its title.
---@param hl org.Headline
---@return string
function M.detail(hl)
  local parts = {}
  if hl.todo then
    parts[#parts + 1] = hl.todo
  end
  if hl.priority then
    parts[#parts + 1] = "[#" .. hl.priority .. "]"
  end
  if #hl.tags > 0 then
    parts[#parts + 1] = ":" .. table.concat(hl.tags, ":") .. ":"
  end
  return table.concat(parts, " ")
end

--- The name a headline's symbol shows: its title without links' targets
--- and statistics cookies.
---@param hl org.Headline
---@return string
function M.name(hl)
  local t = hl:plain_title()
  return t ~= "" and t or "(untitled)"
end

--- Byte span (1-based, inclusive) of a headline's title in its line; an
--- empty title gives e = s - 1.
---@param hl org.Headline
---@return integer s, integer e
function M.title_span(hl)
  local raw = hl.raw
  local pos = (raw:find("[^%*]") or #raw + 1)
  pos = raw:find("%S", pos) or #raw + 1
  if hl.todo and raw:sub(pos, pos + #hl.todo - 1) == hl.todo then
    pos = raw:find("%S", pos + #hl.todo) or #raw + 1
  end
  if hl.priority then
    local p = raw:find("[#" .. hl.priority .. "]", pos, true)
    if p == pos then
      pos = raw:find("%S", pos + #hl.priority + 3) or #raw + 1
    end
  end
  if hl.commented and raw:sub(pos, pos + 6) == "COMMENT" then
    pos = raw:find("%S", pos + 7) or #raw + 1
  end
  local title = hl.title or ""
  if title == "" then
    return pos, pos - 1
  end
  local s = raw:find(title, pos, true) or pos
  return s, s + #title - 1
end

--- Lines of a buffer that hold text the `transclusion` extension
--- inserted (a set of 1-based line numbers), or nil when there is none.
--- That text belongs to another file: symbols, references, rename and
--- diagnostics leave it out.
---@param bufnr integer|nil
---@return table<integer, true>|nil
function M.foreign(bufnr)
  if not bufnr or not require("org.extensions").loaded.transclusion then
    return nil
  end
  local ok, regs = pcall(function()
    return require("org.extensions.transclusion").regions(bufnr)
  end)
  if not ok or type(regs) ~= "table" or #regs == 0 then
    return nil
  end
  local set = {}
  for _, r in ipairs(regs) do
    -- rows are 0-based: the keyword is on 1-based line r.s, the text below
    for row = r.s, r.e do
      set[row + 1] = true
    end
  end
  return next(set) and set or nil
end

local function pos(lnum, col)
  return { line = lnum - 1, character = math.max(0, (col or 1) - 1) }
end

--- Range over the 1-based inclusive byte columns `s`..`e` of line `lnum`.
local function span(lnum, s, e)
  return { start = pos(lnum, s), ["end"] = pos(lnum, e + 1) }
end

--- Range of whole lines `first`..`last`.
local function lines_range(lines, first, last)
  last = math.max(first, last or first)
  return { start = pos(first, 1), ["end"] = pos(last, #(lines[last] or "") + 1) }
end

--- Named src blocks and tables: { lnum, last, name, col, kind }, `col` the
--- column of the name on line `lnum`.
local function named_elements(lines, want_src, want_tables)
  local out = {}
  local i, n = 1, #lines
  while i <= n do
    local col, name = lines[i]:match("^[ \t]*#%+[Nn][Aa][Mm][Ee]:[ \t]+()(.-)[ \t]*$")
    if name and name ~= "" then
      local j = i + 1
      -- other affiliated keywords (#+CAPTION:, #+ATTR_HTML:, ...)
      while j <= n and lines[j]:match("^[ \t]*#%+[%w_]+:") and not lines[j]:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_") do
        j = j + 1
      end
      local l = lines[j] or ""
      if want_src and l:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]") then
        local k = j + 1
        while k <= n and not lines[k]:match("^[ \t]*#%+[Ee][Nn][Dd]_[Ss][Rr][Cc]") do
          k = k + 1
        end
        out[#out + 1] = { lnum = i, last = math.min(k, n), name = name, col = col, kind = "src_block" }
        i = k
      elseif want_tables and l:match("^[ \t]*|") then
        local k = j
        while
          k + 1 <= n and (lines[k + 1]:match("^[ \t]*|") or lines[k + 1]:match("^[ \t]*#%+[Tt][Bb][Ll][Ff][Mm]:"))
        do
          k = k + 1
        end
        out[#out + 1] = { lnum = i, last = k, name = name, col = col, kind = "table" }
        i = k
      end
    end
    i = i + 1
  end
  return out
end

--- `<<target>>` and `<<<radio target>>>` outside blocks, comments and
--- drawers: { lnum, s, e, name, radio }.
local function targets_of(lines)
  local links = require("org.links")
  local skip
  local out = {}
  for lnum, line in ipairs(lines) do
    if line:find("<<", 1, true) then
      skip = skip or links.ignored_lines(lines)
      if not skip[lnum] then
        for _, t in ipairs(links.line_targets(line)) do
          out[#out + 1] = { lnum = lnum, s = t.ts, e = t.te, name = t.text, radio = t.radio }
        end
      end
    end
  end
  return out
end

--- Insert `sym` into `list`, keeping it in line order.
local function insert_ordered(list, sym)
  local at = #list + 1
  local line = sym.range.start.line
  for i, c in ipairs(list) do
    if c.range.start.line > line then
      at = i
      break
    end
  end
  table.insert(list, at, sym)
end

---@class org.symbols.Opts
---@field src_blocks? boolean named src blocks (default true)
---@field tables? boolean named tables (default true)
---@field targets? boolean `<<targets>>` and `<<<radio targets>>>` (default false)
---@field kinds? table<string, string|integer> kinds by what (`M.KINDS`)
---@field foreign? table<integer, true> lines to leave out (transcluded text)

--- Document symbols of a parsed file: each headline with its subtree as
--- range and its title as selection range; named src blocks, tables and
--- targets as children of their entry (top-level before the first
--- headline). Besides the LSP fields every symbol has `type` ("headline",
--- "src_block", "table", "target" or "radio_target"), `lnum` and
--- `end_lnum` (1-based), and a headline `level`.
---@param file org.File
---@param opts? org.symbols.Opts
---@return table[] DocumentSymbol[]
function M.document(file, opts)
  opts = opts or {}
  local lines = file.lines
  local kinds = opts.kinds
  local foreign = opts.foreign or {}
  local by_line = {}
  -- symbols of a headline (none for one the transclusion extension
  -- inserted: its own-file children, if any, take its place)
  local function build(hl, into)
    if foreign[hl.line] then
      for _, c in ipairs(hl.children) do
        build(c, into)
      end
      return
    end
    local s, e = M.title_span(hl)
    if e < s then
      s, e = 1, #hl.raw
    end
    local sym = {
      name = M.name(hl),
      detail = M.detail(hl),
      kind = M.headline_kind(hl, kinds),
      range = lines_range(lines, hl.line, hl.end_line),
      selectionRange = span(hl.line, s, e),
      children = {},
      type = "headline",
      level = hl.level,
      lnum = hl.line,
      end_lnum = hl.end_line,
    }
    by_line[hl.line] = sym
    into[#into + 1] = sym
    for _, c in ipairs(hl.children) do
      build(c, sym.children)
    end
  end
  local out = {}
  for _, hl in ipairs(file.children) do
    build(hl, out)
  end
  local extra = {}
  if opts.src_blocks ~= false or opts.tables ~= false then
    for _, el in ipairs(named_elements(lines, opts.src_blocks ~= false, opts.tables ~= false)) do
      extra[#extra + 1] = {
        name = el.name,
        detail = el.kind == "src_block" and "src block" or "table",
        kind = kind_for(kinds, el.kind),
        range = lines_range(lines, el.lnum, el.last),
        selectionRange = span(el.lnum, el.col, el.col + #el.name - 1),
        type = el.kind,
        lnum = el.lnum,
        end_lnum = el.last,
      }
    end
  end
  if opts.targets then
    for _, t in ipairs(targets_of(lines)) do
      local r = span(t.lnum, t.s, t.e)
      extra[#extra + 1] = {
        name = t.name,
        detail = t.radio and "radio target" or "target",
        kind = kind_for(kinds, "target"),
        range = r,
        selectionRange = r,
        type = t.radio and "radio_target" or "target",
        lnum = t.lnum,
        end_lnum = t.lnum,
      }
    end
  end
  for _, sym in ipairs(extra) do
    if not foreign[sym.lnum] then
      local hl = file:headline_at(sym.lnum)
      while hl and foreign[hl.line] do
        hl = hl.parent
      end
      local parent = hl and by_line[hl.line]
      insert_ordered(parent and parent.children or out, sym)
    end
  end
  return out
end

--- Document symbols of an org buffer (see `M.document`), leaving out text
--- the `transclusion` extension inserted.
---@param bufnr integer
---@param opts? org.symbols.Opts
---@return table[]
function M.buffer(bufnr, opts)
  local o = vim.tbl_extend("keep", { foreign = M.foreign(bufnr) }, opts or {})
  return M.document(files.get_buffer(bufnr), o)
end

--- The headline symbols (without children) from the outermost to the one
--- containing line `lnum`: breadcrumbs. Only walks the headline's
--- ancestors, so it is cheap enough for a winbar or statusline.
---@param file org.File
---@param lnum integer
---@param opts? org.symbols.Opts
---@return table[]
function M.path(file, lnum, opts)
  opts = opts or {}
  local foreign = opts.foreign or {}
  local out = {}
  local hl = file:headline_at(lnum)
  while hl do
    if not foreign[hl.line] then
      local s, e = M.title_span(hl)
      if e < s then
        s, e = 1, #hl.raw
      end
      table.insert(out, 1, {
        name = M.name(hl),
        detail = M.detail(hl),
        kind = M.headline_kind(hl, opts.kinds),
        range = lines_range(file.lines, hl.line, hl.end_line),
        selectionRange = span(hl.line, s, e),
        children = {},
        type = "headline",
        level = hl.level,
        lnum = hl.line,
        end_lnum = hl.end_line,
      })
    end
    hl = hl.parent
  end
  return out
end

return M

---@mod org.extensions.lsp.symbols Symbols, folding ranges and document links

local util = require("org.extensions.lsp.util")
local targets = require("org.extensions.lsp.targets")

local M = {}

local function kind_of(name)
  local kinds = vim.lsp.protocol.SymbolKind
  return kinds[name] or (type(name) == "number" and name) or kinds.Namespace
end

--- Symbol kind of a headline: by TODO state (`symbol_kinds.todo` /
--- `.done`), else `symbol_kinds.heading`.
function M.headline_kind(hl)
  local k = util.opts().symbol_kinds or {}
  if hl.todo then
    return kind_of(hl:is_done() and k.done or k.todo)
  end
  return kind_of(k.heading)
end

local function detail(hl)
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

local function name_of(hl)
  local t = hl:plain_title()
  return t ~= "" and t or "(untitled)"
end

--- Named src blocks and tables: { lnum, last, name, kind, name_lnum }.
local function named_elements(lines, want_src, want_tables)
  local out = {}
  local i, n = 1, #lines
  while i <= n do
    local name = lines[i]:match("^[ \t]*#%+[Nn][Aa][Mm][Ee]:[ \t]+(.-)[ \t]*$")
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
        out[#out + 1] = { lnum = i, last = math.min(k, n), name = name, kind = "src_block" }
        i = k
      elseif want_tables and l:match("^[ \t]*|") then
        local k = j
        while
          k + 1 <= n and (lines[k + 1]:match("^[ \t]*|") or lines[k + 1]:match("^[ \t]*#%+[Tt][Bb][Ll][Ff][Mm]:"))
        do
          k = k + 1
        end
        out[#out + 1] = { lnum = i, last = k, name = name, kind = "table" }
        i = k
      end
    end
    i = i + 1
  end
  return out
end

--- textDocument/documentSymbol: the outline, each headline's range
--- covering its subtree; named src blocks and tables as children of their
--- entry.
---@param doc org.lsp.Doc
---@return table[] DocumentSymbol[]
function M.document(doc)
  local o = util.opts().document_symbols or {}
  local lines = doc.lines
  local kinds = util.opts().symbol_kinds or {}
  local by_line = {}
  local foreign = doc.foreign or {}
  -- symbols of a headline (none for one the transclusion extension
  -- inserted: its own-file children, if any, take its place)
  local function build(hl, into)
    if foreign[hl.line] then
      for _, c in ipairs(hl.children) do
        build(c, into)
      end
      return
    end
    local s, e = util.title_span(hl)
    if e < s then
      s, e = 1, #hl.raw
    end
    local last = hl.end_line
    local sym = {
      name = name_of(hl),
      detail = detail(hl),
      kind = M.headline_kind(hl),
      range = util.line_range(lines, hl.line, last),
      selectionRange = util.range(hl.line, s, e),
      children = {},
    }
    by_line[hl.line] = sym
    into[#into + 1] = sym
    for _, c in ipairs(hl.children) do
      build(c, sym.children)
    end
  end
  local out = {}
  for _, hl in ipairs(doc.file.children) do
    build(hl, out)
  end
  if o.src_blocks ~= false or o.tables ~= false then
    local named = vim.tbl_filter(function(el)
      return not foreign[el.lnum]
    end, named_elements(lines, o.src_blocks ~= false, o.tables ~= false))
    for _, el in ipairs(named) do
      local line = lines[el.lnum]
      local s = line:find(el.name, 1, true)
      local sym = {
        name = el.name,
        detail = el.kind == "src_block" and "src block" or "table",
        kind = kind_of(kinds[el.kind]),
        range = util.line_range(lines, el.lnum, el.last),
        selectionRange = util.range(el.lnum, s, s + #el.name - 1),
      }
      local hl = doc.file:headline_at(el.lnum)
      while hl and foreign[hl.line] do
        hl = hl.parent
      end
      local parent = hl and by_line[hl.line]
      if parent then
        -- keep the children in line order
        local list = parent.children
        local at = #list + 1
        for i, c in ipairs(list) do
          if c.range.start.line > el.lnum - 1 then
            at = i
            break
          end
        end
        table.insert(list, at, sym)
      else
        local at = #out + 1
        for i, c in ipairs(out) do
          if c.range.start.line > el.lnum - 1 then
            at = i
            break
          end
        end
        table.insert(out, at, sym)
      end
    end
  end
  return out
end

local function matches(terms, text)
  text = text:lower()
  for _, t in ipairs(terms) do
    if not text:find(t, 1, true) then
      return false
    end
  end
  return true
end

--- workspace/symbol: headlines of the workspace files whose title, TODO
--- keyword and tags contain every word of the query (ignoring case).
---@param query string
---@return table[] SymbolInformation[]
function M.workspace(query)
  local terms = vim.split(vim.trim(query or ""):lower(), "%s+", { trimempty = true })
  local limit = util.opts().workspace_symbol_limit or 1000
  local out = {}
  for _, path in ipairs(util.workspace_files()) do
    local doc = util.doc_from_path(path)
    if doc then
      for _, hl in ipairs(doc.file.headlines) do
        local text = table.concat({ hl.todo or "", hl.title or "", table.concat(hl.tags, ":") }, " ")
        if matches(terms, text) and not (doc.foreign and doc.foreign[hl.line]) then
          local s, e = util.title_span(hl)
          if e < s then
            s, e = 1, #hl.raw
          end
          local container = util.olp(hl)
          out[#out + 1] = {
            name = name_of(hl),
            kind = M.headline_kind(hl),
            location = { uri = doc.uri, range = util.range(hl.line, s, e) },
            containerName = vim.fs.basename(path) .. (container ~= "" and (" › " .. container) or ""),
          }
          if #out >= limit then
            return out
          end
        end
      end
    end
  end
  return out
end

--- textDocument/foldingRange: subtrees, blocks and drawers.
---@param doc org.lsp.Doc
function M.folding(doc)
  local out = {}
  local lines = doc.lines
  for _, hl in ipairs(doc.file.headlines) do
    local last = hl.end_line
    while last > hl.line and lines[last]:match("^%s*$") do
      last = last - 1
    end
    if last > hl.line then
      out[#out + 1] = { startLine = hl.line - 1, endLine = last - 1, kind = "region" }
    end
    for _, d in ipairs(hl.drawers or {}) do
      if d["end"] and d["end"] > d.start then
        out[#out + 1] = { startLine = d.start - 1, endLine = d["end"] - 1, kind = "region" }
      end
    end
  end
  local open
  for i, l in ipairs(lines) do
    local b = l:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
    if b and not open then
      open = { i, b:lower() }
    elseif open and l:lower():match("^[ \t]*#%+end_" .. vim.pesc(open[2]) .. "%f[%W]") then
      if i > open[1] then
        out[#out + 1] = { startLine = open[1] - 1, endLine = i - 1, kind = "region" }
      end
      open = nil
    end
  end
  table.sort(out, function(a, b)
    return a.startLine < b.startLine or (a.startLine == b.startLine and a.endLine > b.endLine)
  end)
  return out
end

local WEB = { http = true, https = true, ftp = true, mailto = true, news = true }

--- textDocument/documentLink: web links and links whose target resolves
--- (a file URI, with `#L<line>` for a position inside it).
---@param doc org.lsp.Doc
function M.links(doc)
  local out = {}
  local memo, uris = {}, {}
  for _, item in ipairs(targets.doc_links(doc)) do
    local l = item.link
    local target
    if WEB[l.type] then
      target = l.type .. ":" .. l.path
    else
      local key = (l.type or "") .. "\0" .. l.target
      if memo[key] == nil then
        local loc = targets.resolve(doc, l)
        if loc then
          uris[loc.path] = uris[loc.path] or util.uri(loc.path)
          memo[key] = uris[loc.path] .. (loc.lnum > 1 and ("#L" .. loc.lnum) or "")
        else
          memo[key] = false
        end
      end
      target = memo[key] or nil
    end
    if target then
      out[#out + 1] = { range = targets.link_range(l), target = target, tooltip = l.target }
    end
  end
  return out
end

return M

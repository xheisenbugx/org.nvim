---@mod org.extensions.lsp.symbols Symbols, folding ranges and document links

local util = require("org.extensions.lsp.util")
local targets = require("org.extensions.lsp.targets")
local core = require("org.symbols")

local M = {}

--- Symbol kind of a headline: by TODO state (`symbol_kinds.todo` /
--- `.done`), else `symbol_kinds.heading`.
function M.headline_kind(hl)
  return core.headline_kind(hl, util.opts().symbol_kinds)
end

local name_of = core.name

--- textDocument/documentSymbol: the outline, each headline's range
--- covering its subtree; named src blocks and tables (and targets with
--- `document_symbols.targets`) as children of their entry (`org.symbols`).
---@param doc org.lsp.Doc
---@return table[] DocumentSymbol[]
function M.document(doc)
  local o = util.opts().document_symbols or {}
  return core.document(doc.file, {
    src_blocks = o.src_blocks,
    tables = o.tables,
    targets = o.targets,
    kinds = util.opts().symbol_kinds,
    foreign = doc.foreign,
  })
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

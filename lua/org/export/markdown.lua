---@mod org.export.markdown Markdown (GitHub flavoured) backend

local ast = require("org.export.ast")

local M = {}

M.extension = "md"

local function esc(s)
  return (s:gsub("([%*`])", "\\%1"))
end

local R = {}
R.__index = R

function M.new(doc)
  return setmetatable({ doc = doc, o = doc.options, fn_n = {}, fn_order = {}, fn_defs = {}, shift = 0 }, R)
end

function R:footnote(label, def)
  if not label then
    label = "__anon" .. (#self.fn_order + 1)
  end
  if not self.fn_n[label] then
    self.fn_order[#self.fn_order + 1] = label
    self.fn_n[label] = #self.fn_order
  end
  if def and not self.fn_defs[label] then
    self.fn_defs[label] = def
  end
  return self.fn_n[label]
end

function R:inline(nodes)
  local out = {}
  for _, nd in ipairs(nodes or {}) do
    local t = nd.type
    if t == "text" then
      out[#out + 1] = esc(nd.value)
    elseif t == "bold" then
      out[#out + 1] = "**" .. self:inline(nd.children) .. "**"
    elseif t == "italic" then
      out[#out + 1] = "*" .. self:inline(nd.children) .. "*"
    elseif t == "underline" then
      out[#out + 1] = "<u>" .. self:inline(nd.children) .. "</u>"
    elseif t == "strike" then
      out[#out + 1] = "~~" .. self:inline(nd.children) .. "~~"
    elseif t == "verbatim" or t == "code" then
      local ticks = nd.value:find("`", 1, true) and "``" or "`"
      out[#out + 1] = ticks .. nd.value .. ticks
    elseif t == "sub" then
      out[#out + 1] = "<sub>" .. self:inline(nd.children) .. "</sub>"
    elseif t == "sup" then
      out[#out + 1] = "<sup>" .. self:inline(nd.children) .. "</sup>"
    elseif t == "linebreak" then
      out[#out + 1] = "  \n"
    elseif t == "entity" then
      out[#out + 1] = ast.ENTITIES[nd.name][2]
    elseif t == "latex" then
      out[#out + 1] = nd.value
    elseif t == "timestamp" then
      if self.o.timestamps ~= false then
        out[#out + 1] = "`" .. nd.value .. "`"
      end
    elseif t == "target" then
      out[#out + 1] = '<a id="' .. (nd.id or ast.slug(nd.value)) .. '"></a>'
    elseif t == "snippet" then
      if nd.backend == "md" or nd.backend == "markdown" or nd.backend == "html" then
        out[#out + 1] = nd.value
      end
    elseif t == "footnote_ref" then
      out[#out + 1] = "[^" .. self:footnote(nd.label, nd.def) .. "]"
    elseif t == "link" then
      out[#out + 1] = self:link(nd)
    end
  end
  return table.concat(out)
end

function R:link(nd)
  local kind, target = ast.classify_link(self.doc, nd.path)
  local desc = nd.desc and self:inline(nd.desc) or nil
  local custom = require("org.links").export_link(nd.path, desc, "md")
  if custom then
    return custom
  elseif kind == "image" and not nd.desc then
    return "![" .. vim.fn.fnamemodify(target, ":t") .. "](" .. target .. ")"
  elseif kind == "url" or kind == "image" or kind == "other" then
    if not desc and nd.plain then
      return "<" .. target .. ">"
    end
    return "[" .. (desc or target) .. "](" .. target .. ")"
  elseif kind == "internal" then
    local label = desc
    if not label then
      for _, h in ipairs(self.doc.headlines) do
        if h.id == target then
          label = self:inline(h.title)
        end
      end
    end
    return "[" .. (label or nd.path) .. "](#" .. target .. ")"
  elseif kind == "file" then
    local href = target:gsub("%.org$", ".md")
    return "[" .. (desc or target) .. "](" .. href .. ")"
  end
  return desc or nd.path
end

local function indent_lines(lines, prefix, first)
  local out = {}
  for i, l in ipairs(lines) do
    if i == 1 and first then
      out[i] = first .. l
    else
      out[i] = l == "" and "" or prefix .. l
    end
  end
  return out
end

--- Render elements into a list of lines (blocks separated by blank lines).
function R:elements(nodes)
  local out = {}
  for _, nd in ipairs(nodes or {}) do
    local lines = self:element(nd)
    if lines and #lines > 0 then
      if #out > 0 then
        out[#out + 1] = ""
      end
      vim.list_extend(out, lines)
    end
  end
  return out
end

function R:headline_title(nd)
  local parts = {}
  if nd.todo and self.o.todo ~= false then
    parts[#parts + 1] = nd.todo
  end
  if nd.priority and self.o.pri then
    parts[#parts + 1] = "[#" .. nd.priority .. "]"
  end
  parts[#parts + 1] = self:inline(nd.title)
  local s = table.concat(parts, " ")
  if self.o.tags ~= false and #nd.tags > 0 then
    s = s .. "&emsp;<kbd>" .. table.concat(nd.tags, "</kbd> <kbd>") .. "</kbd>"
  end
  return s
end

function R:element(nd)
  local t = nd.type
  if t == "paragraph" then
    local text = self:inline(nd.inline)
    return vim.split(text, "\n", { plain = true })
  elseif t == "headline" then
    if nd.deep then
      local lines = { "- **" .. self:headline_title(nd) .. "**" }
      local body = self:elements(nd.children)
      if #body > 0 then
        lines[#lines + 1] = ""
        vim.list_extend(lines, indent_lines(body, "  "))
      end
      return lines
    end
    local level = math.min(nd.level + self.shift, 6)
    local num = ""
    if nd.number and self.o.num and self.number_headings then
      num = table.concat(nd.number, ".") .. " "
    end
    local lines = { string.rep("#", level) .. " " .. num .. self:headline_title(nd) }
    if nd.id and nd.id ~= ast.slug(nd.raw_title) then
      lines[1] = '<a id="' .. nd.id .. '"></a>\n' .. lines[1]
      lines = vim.split(table.concat(lines, "\n"), "\n", { plain = true })
    end
    if nd.planning then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "`" .. nd.planning .. "`"
    end
    local body = self:elements(nd.children)
    if #body > 0 then
      lines[#lines + 1] = ""
      vim.list_extend(lines, body)
    end
    return lines
  elseif t == "list" then
    return self:list(nd)
  elseif t == "table" then
    return self:table(nd)
  elseif t == "src" then
    local fence = "```"
    for _, l in ipairs(nd.lines) do
      if l:find("```", 1, true) then
        fence = "~~~~"
      end
    end
    local lines = { fence .. nd.lang }
    vim.list_extend(lines, nd.lines)
    lines[#lines + 1] = fence
    return lines
  elseif t == "example" or t == "fixed" then
    local lines = { "```" }
    vim.list_extend(lines, nd.lines)
    lines[#lines + 1] = "```"
    return lines
  elseif t == "quote" then
    local body = self:elements(nd.children)
    local out = {}
    for i, l in ipairs(body) do
      out[i] = l == "" and ">" or ("> " .. l)
    end
    return out
  elseif t == "center" or t == "special" then
    return self:elements(nd.children)
  elseif t == "verse" then
    local out = {}
    for _, l in ipairs(nd.lines) do
      out[#out + 1] = self:inline(l) .. "  "
    end
    return out
  elseif t == "export" then
    if nd.backend == "md" or nd.backend == "markdown" or nd.backend == "html" then
      return nd.lines
    end
  elseif t == "latex_env" then
    local out = { "$$" }
    vim.list_extend(out, nd.lines)
    out[#out + 1] = "$$"
    return out
  elseif t == "hr" then
    return { "---" }
  elseif t == "keyword_toc" then
    return self:toc(nd.depth)
  end
  return nil
end

function R:list(nd)
  local out = {}
  local n = 0
  for _, it in ipairs(nd.items) do
    n = n + 1
    if it.counter and tonumber(it.counter) then
      n = tonumber(it.counter)
    end
    local marker = nd.kind == "ordered" and (n .. ". ") or "- "
    local box = ""
    if it.checkbox == "on" then
      box = "[x] "
    elseif it.checkbox == "off" then
      box = "[ ] "
    elseif it.checkbox == "trans" then
      box = "[-] "
    end
    local body = self:elements(it.children)
    if nd.kind == "description" then
      local term = "**" .. self:inline(it.term) .. "**"
      if #body > 0 then
        body[1] = term .. ": " .. body[1]
      else
        body = { term }
      end
    end
    if #body == 0 then
      body = { "" }
    end
    body[1] = box .. body[1]
    vim.list_extend(out, indent_lines(body, string.rep(" ", #marker), marker))
  end
  return out
end

function R:table(nd)
  local rows = {}
  local ncols = 0
  for _, r in ipairs(nd.rows) do
    if r ~= "hline" then
      local cells = {}
      for c, cell in ipairs(r.cells) do
        cells[c] = self:inline(cell):gsub("|", "\\|")
      end
      rows[#rows + 1] = cells
      ncols = math.max(ncols, #cells)
    end
  end
  if #rows == 0 then
    return nil
  end
  local header = nd.header > 0 and nd.header or 0
  local out = {}
  local function line(cells)
    local parts = {}
    for c = 1, ncols do
      parts[c] = cells[c] or ""
    end
    return "| " .. table.concat(parts, " | ") .. " |"
  end
  local sep = {}
  for c = 1, ncols do
    sep[c] = "---"
  end
  if header == 0 then
    local empty = {}
    out[#out + 1] = line(empty)
    out[#out + 1] = "|" .. table.concat(sep, "|") .. "|"
  end
  for i, cells in ipairs(rows) do
    out[#out + 1] = line(cells)
    if header > 0 and i == header then
      out[#out + 1] = "|" .. table.concat(sep, "|") .. "|"
    end
  end
  if nd.affiliated and nd.affiliated.caption then
    table.insert(out, 1, "")
    table.insert(out, 1, "*" .. self:inline(nd.affiliated.caption) .. "*")
  end
  return out
end

function R:toc(depth)
  local max = depth or (type(self.o.toc) == "number" and self.o.toc) or tonumber(self.o.H) or 3
  local out = {}
  local function walk(nodes)
    for _, nd in ipairs(nodes) do
      if nd.type == "headline" and not nd.deep and nd.level <= max then
        out[#out + 1] = string.rep("  ", nd.level - 1) .. "- [" .. ast.plain(nd.title) .. "](#" .. nd.id .. ")"
        walk(nd.children)
      end
    end
  end
  walk(self.doc.children)
  if #out == 0 then
    return nil
  end
  table.insert(out, 1, "")
  table.insert(out, 1, string.rep("#", 1 + self.shift) .. " Table of Contents")
  return out
end

function R:footnotes()
  if #self.fn_order == 0 then
    return {}
  end
  local out = {}
  for _, label in ipairs(self.fn_order) do
    local n = self.fn_n[label]
    local body
    if self.fn_defs[label] then
      body = { self:inline(self.fn_defs[label]) }
    else
      body = self:elements(self.doc.footnote_defs[label] or {})
    end
    if #body == 0 then
      body = { "" }
    end
    vim.list_extend(out, indent_lines(body, "    ", "[^" .. n .. "]: "))
  end
  return out
end

function M.render(doc, opts)
  opts = opts or {}
  local r = M.new(doc)
  local o = doc.options
  local out = {}
  local function add(lines)
    if lines and #lines > 0 then
      if #out > 0 then
        out[#out + 1] = ""
      end
      vim.list_extend(out, lines)
    end
  end
  if not opts.body_only and o.title ~= false and doc.title then
    r.shift = 1
    add({ "# " .. r:inline(ast.parse_inline(doc.title, o)) })
    if doc.subtitle then
      add({ "*" .. r:inline(ast.parse_inline(doc.subtitle, o)) .. "*" })
    end
  end
  if o.toc then
    add(r:toc())
  end
  add(r:elements(doc.children))
  add(r:footnotes())
  return table.concat(out, "\n") .. "\n"
end

return M

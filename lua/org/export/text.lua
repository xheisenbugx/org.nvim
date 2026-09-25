---@mod org.export.text Plain text (UTF-8) backend, like Emacs ox-ascii

local ast = require("org.export.ast")
local utils = require("org.utils")

local M = {}

M.extension = "txt"
M.WIDTH = 72

local function text_width()
  return require("org.config").opts.export.text_width or M.WIDTH
end

local R = {}
R.__index = R

function M.new(doc)
  return setmetatable({ doc = doc, o = doc.options, fn_n = {}, fn_order = {}, fn_defs = {}, links = {} }, R)
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

local function special(s)
  return (s:gsub("%-%-%-", "—"):gsub("%-%-", "–"):gsub("%.%.%.", "…"))
end

function R:inline(nodes)
  local out = {}
  for _, nd in ipairs(nodes or {}) do
    local t = nd.type
    if t == "text" then
      local v = nd.value:gsub("\n", " ")
      out[#out + 1] = self.o.special_strings ~= false and special(v) or v
    elseif t == "bold" then
      out[#out + 1] = "*" .. self:inline(nd.children) .. "*"
    elseif t == "italic" then
      out[#out + 1] = "/" .. self:inline(nd.children) .. "/"
    elseif t == "underline" then
      out[#out + 1] = "_" .. self:inline(nd.children) .. "_"
    elseif t == "strike" then
      out[#out + 1] = "+" .. self:inline(nd.children) .. "+"
    elseif t == "verbatim" or t == "code" then
      out[#out + 1] = "`" .. nd.value .. "'"
    elseif t == "sub" then
      out[#out + 1] = "_" .. self:inline(nd.children)
    elseif t == "sup" then
      out[#out + 1] = "^" .. self:inline(nd.children)
    elseif t == "linebreak" then
      out[#out + 1] = "\n"
    elseif t == "entity" then
      out[#out + 1] = ast.ENTITIES[nd.name][2]
    elseif t == "latex" then
      out[#out + 1] = nd.value
    elseif t == "timestamp" then
      if self.o.timestamps ~= false then
        out[#out + 1] = nd.value
      end
    elseif t == "target" then
      if not nd.radio then -- a radio target's text follows it
        out[#out + 1] = nd.value
      end
    elseif t == "snippet" then
      if nd.backend == "ascii" or nd.backend == "txt" then
        out[#out + 1] = nd.value
      end
    elseif t == "footnote_ref" then
      out[#out + 1] = "[" .. self:footnote(nd.label, nd.def) .. "]"
    elseif t == "link" then
      local kind, target = ast.classify_link(self.doc, nd.path)
      if nd.desc then
        local d = self:inline(nd.desc)
        if kind == "url" or kind == "file" or kind == "other" or kind == "image" then
          out[#out + 1] = d .. " <" .. target .. ">"
        else
          out[#out + 1] = d
        end
      else
        if kind == "internal" then
          local label = nd.path
          for _, h in ipairs(self.doc.headlines) do
            if h.id == target then
              label = h.number and table.concat(h.number, ".") or ast.plain(h.title)
            end
          end
          out[#out + 1] = label
        else
          out[#out + 1] = "<" .. target .. ">"
        end
      end
    end
  end
  return table.concat(out)
end

--- Fill text into lines of at most `width` display cells.
function M.fill(text, width, prefix, first_prefix)
  prefix = prefix or ""
  first_prefix = first_prefix or prefix
  local out = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    local cur = nil
    local pre = #out == 0 and first_prefix or prefix
    for word in para:gmatch("%S+") do
      if not cur then
        cur = pre .. word
      elseif utils.width(cur) + 1 + utils.width(word) > width then
        out[#out + 1] = cur
        cur = prefix .. word
      else
        cur = cur .. " " .. word
      end
    end
    out[#out + 1] = cur or pre:gsub("%s+$", "")
  end
  return out
end

function R:elements(nodes, indent)
  indent = indent or ""
  local out = {}
  for _, nd in ipairs(nodes or {}) do
    local lines = self:element(nd, indent)
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
  if nd.number then
    parts[#parts + 1] = table.concat(nd.number, ".")
  end
  if nd.todo and self.o.todo ~= false then
    parts[#parts + 1] = nd.todo
  end
  if nd.priority and self.o.pri then
    parts[#parts + 1] = "[#" .. nd.priority .. "]"
  end
  parts[#parts + 1] = self:inline(nd.title)
  local s = table.concat(parts, " ")
  if self.o.tags ~= false and #nd.tags > 0 then
    s = s .. "  :" .. table.concat(nd.tags, ":") .. ":"
  end
  return s
end

local function prefixed(lines, indent)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = l == "" and "" or indent .. l
  end
  return out
end

function R:element(nd, indent)
  local t = nd.type
  local width = text_width()
  if t == "paragraph" then
    return M.fill(self:inline(nd.inline), width, indent)
  elseif t == "headline" then
    local title = self:headline_title(nd)
    local lines
    if nd.deep then
      lines = M.fill(title, width, indent .. "  ", indent .. "- ")
    elseif nd.level == 1 then
      lines = { "", title, string.rep("═", utils.width(title)) }
    elseif nd.level == 2 then
      lines = { title, string.rep("─", utils.width(title)) }
    else
      lines = { title }
    end
    if nd.planning then
      lines[#lines + 1] = indent .. "  " .. nd.planning
    end
    local body = self:elements(nd.children, nd.deep and (indent .. "  ") or indent)
    if #body > 0 then
      lines[#lines + 1] = ""
      vim.list_extend(lines, body)
    end
    return lines
  elseif t == "list" then
    local out = {}
    local n = 0
    for _, it in ipairs(nd.items) do
      n = n + 1
      if it.counter and tonumber(it.counter) then
        n = tonumber(it.counter)
      end
      local marker = nd.kind == "ordered" and (n .. ". ") or "• "
      local box = ""
      if it.checkbox == "on" then
        box = "☑ "
      elseif it.checkbox == "off" then
        box = "☐ "
      elseif it.checkbox == "trans" then
        box = "◩ "
      end
      local sub = indent .. string.rep(" ", utils.width(marker))
      local body = {}
      local first_para = it.children[1] and it.children[1].type == "paragraph"
      local lead = box
      if nd.kind == "description" then
        lead = box .. self:inline(it.term) .. ": "
      end
      if first_para then
        vim.list_extend(body, M.fill(lead .. self:inline(it.children[1].inline), width, sub, indent .. marker))
        local rest = self:elements(vim.list_slice(it.children, 2, #it.children), sub)
        vim.list_extend(body, rest)
      else
        body[1] = indent .. marker .. lead
        vim.list_extend(body, self:elements(it.children, sub))
      end
      vim.list_extend(out, body)
    end
    return out
  elseif t == "table" then
    return prefixed(self:table(nd), indent)
  elseif t == "src" or t == "example" or t == "fixed" then
    return prefixed(nd.lines, indent .. "  ")
  elseif t == "quote" then
    return self:elements(nd.children, indent .. "  ")
  elseif t == "center" or t == "special" then
    return self:elements(nd.children, indent)
  elseif t == "verse" then
    local out = {}
    for _, l in ipairs(nd.lines) do
      out[#out + 1] = indent .. "  " .. self:inline(l)
    end
    return out
  elseif t == "export" then
    if nd.backend == "ascii" or nd.backend == "txt" then
      return nd.lines
    end
  elseif t == "latex_env" then
    return prefixed(nd.lines, indent)
  elseif t == "hr" then
    return { indent .. string.rep("─", 40) }
  elseif t == "keyword_toc" then
    return self:toc(nd.depth)
  end
end

function R:table(nd)
  local rows, widths, ncols = {}, {}, 0
  for _, r in ipairs(nd.rows) do
    if r == "hline" then
      rows[#rows + 1] = "hline"
    else
      local cells = {}
      for c, cell in ipairs(r.cells) do
        cells[c] = self:inline(cell)
        widths[c] = math.max(widths[c] or 0, utils.width(cells[c]))
      end
      ncols = math.max(ncols, #cells)
      rows[#rows + 1] = cells
    end
  end
  local numeric = {}
  for c = 1, ncols do
    widths[c] = widths[c] or 0
    local num, total = 0, 0
    for _, r in ipairs(rows) do
      if r ~= "hline" and r[c] and r[c] ~= "" then
        total = total + 1
        if r[c]:match("^%s*[-+]?[%d.,]+%%?%s*$") then
          num = num + 1
        end
      end
    end
    numeric[c] = total > 0 and num / total >= 0.5
  end
  local out = {}
  for _, r in ipairs(rows) do
    if r == "hline" then
      local parts = {}
      for c = 1, ncols do
        parts[c] = string.rep("─", widths[c] + 2)
      end
      out[#out + 1] = "├" .. table.concat(parts, "┼") .. "┤"
    else
      local parts = {}
      for c = 1, ncols do
        local v = r[c] or ""
        if numeric[c] then
          parts[c] = " " .. utils.pad_left(v, widths[c]) .. " "
        else
          parts[c] = " " .. utils.pad_right(v, widths[c]) .. " "
        end
      end
      out[#out + 1] = "│" .. table.concat(parts, "│") .. "│"
    end
  end
  if nd.affiliated and nd.affiliated.caption then
    table.insert(out, 1, self:inline(nd.affiliated.caption))
  end
  return out
end

function R:toc(depth)
  local max = depth or (type(self.o.toc) == "number" and self.o.toc) or tonumber(self.o.H) or 3
  local out = { "Table of Contents", "═════════════════", "" }
  local any = false
  local function walk(nodes)
    for _, nd in ipairs(nodes) do
      if nd.type == "headline" and not nd.deep and nd.level <= max then
        any = true
        local num = nd.number and (table.concat(nd.number, ".") .. " ") or ""
        out[#out + 1] = string.rep("  ", nd.level - 1) .. num .. ast.plain(nd.title)
        walk(nd.children)
      end
    end
  end
  walk(self.doc.children)
  return any and out or nil
end

function R:footnotes()
  if #self.fn_order == 0 then
    return nil
  end
  local out = { "", "Footnotes", "═════════", "" }
  for _, label in ipairs(self.fn_order) do
    local n = self.fn_n[label]
    local text
    if self.fn_defs[label] then
      text = self:inline(self.fn_defs[label])
    else
      text = table.concat(self:elements(self.doc.footnote_defs[label] or {}), " ")
    end
    vim.list_extend(out, M.fill(text, text_width(), "    ", "[" .. n .. "] "))
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
    local title = r:inline(ast.parse_inline(doc.title, o))
    local head = {}
    local function center(s)
      local pad = math.max(0, math.floor((text_width() - utils.width(s)) / 2))
      return string.rep(" ", pad) .. s
    end
    head[#head + 1] = center(title)
    head[#head + 1] = center(string.rep("═", utils.width(title)))
    if doc.author and o.author then
      head[#head + 1] = ""
      head[#head + 1] = center(doc.author)
    end
    if doc.date and o.date then
      head[#head + 1] = center(doc.date)
    end
    add(head)
  end
  if o.toc then
    add(r:toc())
  end
  add(r:elements(doc.children))
  add(r:footnotes())
  -- collapse leading blank lines
  while out[1] == "" do
    table.remove(out, 1)
  end
  return table.concat(out, "\n") .. "\n"
end

return M

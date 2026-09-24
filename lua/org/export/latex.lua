---@mod org.export.latex LaTeX backend (article class)

local ast = require("org.export.ast")

local M = {}

M.extension = "tex"

local function esc(s)
  s = s:gsub("\\", "\1")
  s = s:gsub("([{}%$&#_%%])", "\\%1")
  s = s:gsub("%^", "\\^{}"):gsub("~", "\\textasciitilde{}")
  s = s:gsub("\1", "\\textbackslash{}")
  return s
end
M.escape = esc

local function verb(s)
  return "\\texttt{" .. esc(s) .. "}"
end

local SECTIONS = { "section", "subsection", "subsubsection", "paragraph", "subparagraph" }

local R = {}
R.__index = R

function M.new(doc)
  return setmetatable({ doc = doc, o = doc.options, fn_defs = {} }, R)
end

function R:inline(nodes)
  local out = {}
  for _, nd in ipairs(nodes or {}) do
    local t = nd.type
    if t == "text" then
      out[#out + 1] = esc(nd.value)
    elseif t == "bold" then
      out[#out + 1] = "\\textbf{" .. self:inline(nd.children) .. "}"
    elseif t == "italic" then
      out[#out + 1] = "\\emph{" .. self:inline(nd.children) .. "}"
    elseif t == "underline" then
      out[#out + 1] = "\\uline{" .. self:inline(nd.children) .. "}"
    elseif t == "strike" then
      out[#out + 1] = "\\sout{" .. self:inline(nd.children) .. "}"
    elseif t == "verbatim" or t == "code" then
      out[#out + 1] = verb(nd.value)
    elseif t == "sub" then
      out[#out + 1] = "\\textsubscript{" .. self:inline(nd.children) .. "}"
    elseif t == "sup" then
      out[#out + 1] = "\\textsuperscript{" .. self:inline(nd.children) .. "}"
    elseif t == "linebreak" then
      out[#out + 1] = "\\\\\n"
    elseif t == "entity" then
      out[#out + 1] = ast.ENTITIES[nd.name][3]
    elseif t == "latex" then
      out[#out + 1] = nd.value
    elseif t == "timestamp" then
      if self.o.timestamps ~= false then
        out[#out + 1] = "\\textit{" .. esc(nd.value) .. "}"
      end
    elseif t == "target" then
      out[#out + 1] = "\\label{" .. (nd.id or ast.slug(nd.value)) .. "}"
    elseif t == "snippet" then
      if nd.backend == "latex" then
        out[#out + 1] = nd.value
      end
    elseif t == "footnote_ref" then
      local def = nd.def
      if def then
        out[#out + 1] = "\\footnote{" .. self:inline(def) .. "}"
      else
        local els = self.doc.footnote_defs[nd.label or ""] or {}
        local body = {}
        for _, e in ipairs(els) do
          if e.type == "paragraph" then
            body[#body + 1] = self:inline(e.inline)
          end
        end
        out[#out + 1] = "\\footnote{" .. table.concat(body, " ") .. "}"
      end
    elseif t == "link" then
      local kind, target = ast.classify_link(self.doc, nd.path)
      local desc = nd.desc and self:inline(nd.desc) or nil
      if kind == "image" and not desc then
        out[#out + 1] = "\\includegraphics[width=.9\\linewidth]{" .. target .. "}"
      elseif kind == "url" or kind == "other" or kind == "image" then
        out[#out + 1] = desc and ("\\href{" .. target:gsub("%%", "\\%%") .. "}{" .. desc .. "}")
          or ("\\url{" .. target .. "}")
      elseif kind == "internal" then
        out[#out + 1] = desc and ("\\hyperref[" .. target .. "]{" .. desc .. "}") or ("\\ref{" .. target .. "}")
      elseif kind == "file" then
        out[#out + 1] = "\\href{" .. target:gsub("%.org$", ".pdf") .. "}{" .. (desc or esc(target)) .. "}"
      else
        out[#out + 1] = desc or esc(nd.path)
      end
    end
  end
  return table.concat(out)
end

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

function R:element(nd)
  local t = nd.type
  if t == "paragraph" then
    return vim.split(self:inline(nd.inline), "\n", { plain = true })
  elseif t == "headline" then
    local title = {}
    if nd.todo and self.o.todo ~= false then
      title[#title + 1] = "\\textbf{" .. esc(nd.todo) .. "}"
    end
    if nd.priority and self.o.pri then
      title[#title + 1] = "\\framebox{\\#" .. esc(nd.priority) .. "}"
    end
    title[#title + 1] = self:inline(nd.title)
    local s = table.concat(title, " ")
    if self.o.tags ~= false and #nd.tags > 0 then
      s = s .. "\\hfill{}\\textsc{" .. esc(table.concat(nd.tags, ":")) .. "}"
    end
    local lines
    if nd.deep or nd.level > #SECTIONS then
      lines = { "\\begin{itemize}", "\\item " .. s .. "\\label{" .. nd.id .. "}" }
      vim.list_extend(lines, self:elements(nd.children))
      lines[#lines + 1] = "\\end{itemize}"
      return lines
    end
    local star = nd.number and "" or "*"
    lines = { string.format("\\%s%s{%s}", SECTIONS[nd.level], star, s), "\\label{" .. nd.id .. "}" }
    local body = self:elements(nd.children)
    if #body > 0 then
      vim.list_extend(lines, body)
    end
    return lines
  elseif t == "list" then
    local env = nd.kind == "ordered" and "enumerate" or (nd.kind == "description" and "description" or "itemize")
    local lines = { "\\begin{" .. env .. "}" }
    for _, it in ipairs(nd.items) do
      local box = ""
      if it.checkbox == "on" then
        box = "[$\\boxtimes$] "
      elseif it.checkbox == "off" then
        box = "[$\\square$] "
      elseif it.checkbox == "trans" then
        box = "[$\\boxminus$] "
      end
      local head = "\\item" .. (nd.kind == "description" and ("[" .. self:inline(it.term) .. "] ") or " ")
      if box ~= "" and nd.kind ~= "description" then
        head = "\\item" .. box
      end
      local body = self:elements(it.children)
      if #body > 0 then
        body[1] = head .. body[1]
      else
        body = { head }
      end
      vim.list_extend(lines, body)
    end
    lines[#lines + 1] = "\\end{" .. env .. "}"
    return lines
  elseif t == "table" then
    local ncols = 0
    for _, r in ipairs(nd.rows) do
      if r ~= "hline" then
        ncols = math.max(ncols, #r.cells)
      end
    end
    local lines = { "\\begin{table}[htbp]", "\\centering" }
    if nd.affiliated and nd.affiliated.caption then
      lines[#lines + 1] = "\\caption{" .. self:inline(nd.affiliated.caption) .. "}"
    end
    lines[#lines + 1] = "\\begin{tabular}{" .. string.rep("l", ncols) .. "}"
    for _, r in ipairs(nd.rows) do
      if r == "hline" then
        lines[#lines + 1] = "\\hline"
      else
        local cells = {}
        for c = 1, ncols do
          cells[c] = self:inline(r.cells[c] or {})
        end
        lines[#lines + 1] = table.concat(cells, " & ") .. " \\\\"
      end
    end
    lines[#lines + 1] = "\\end{tabular}"
    lines[#lines + 1] = "\\end{table}"
    return lines
  elseif t == "src" or t == "example" or t == "fixed" then
    local lines = { "\\begin{verbatim}" }
    vim.list_extend(lines, nd.lines)
    lines[#lines + 1] = "\\end{verbatim}"
    return lines
  elseif t == "quote" or t == "center" then
    local env = t == "quote" and "quote" or "center"
    local lines = { "\\begin{" .. env .. "}" }
    vim.list_extend(lines, self:elements(nd.children))
    lines[#lines + 1] = "\\end{" .. env .. "}"
    return lines
  elseif t == "special" then
    return self:elements(nd.children)
  elseif t == "verse" then
    local lines = { "\\begin{verse}" }
    for _, l in ipairs(nd.lines) do
      lines[#lines + 1] = self:inline(l) .. "\\\\"
    end
    lines[#lines + 1] = "\\end{verse}"
    return lines
  elseif t == "export" then
    if nd.backend == "latex" or nd.backend == "tex" then
      return nd.lines
    end
  elseif t == "latex_env" then
    return nd.lines
  elseif t == "hr" then
    return { "\\noindent\\rule{\\textwidth}{0.5pt}" }
  elseif t == "keyword_toc" then
    return { "\\tableofcontents" }
  end
end

function M.render(doc, opts)
  opts = opts or {}
  local r = M.new(doc)
  local o = doc.options
  local body = r:elements(doc.children)
  if opts.body_only then
    return table.concat(body, "\n") .. "\n"
  end
  local out = {
    "\\documentclass[11pt]{" .. (doc.latex_class or "article") .. "}",
    "\\usepackage[utf8]{inputenc}",
    "\\usepackage[T1]{fontenc}",
    "\\usepackage{graphicx}",
    "\\usepackage{longtable}",
    "\\usepackage{wrapfig}",
    "\\usepackage{rotating}",
    "\\usepackage[normalem]{ulem}",
    "\\usepackage{amsmath}",
    "\\usepackage{amssymb}",
    "\\usepackage{capt-of}",
    "\\usepackage{hyperref}",
  }
  vim.list_extend(out, doc.latex_header or {})
  out[#out + 1] = "\\author{" .. ((doc.author and o.author) and esc(doc.author) or "") .. "}"
  out[#out + 1] = "\\date{" .. ((o.date and doc.date) and esc(doc.date) or (o.date and "\\today" or "")) .. "}"
  out[#out + 1] = "\\title{" .. (doc.title and r:inline(ast.parse_inline(doc.title, o)) or "") .. "}"
  out[#out + 1] = "\\hypersetup{pdftitle={" .. esc(doc.title or "") .. "}, pdfcreator={org.nvim}}"
  out[#out + 1] = "\\begin{document}"
  out[#out + 1] = ""
  if o.title ~= false and doc.title then
    out[#out + 1] = "\\maketitle"
  end
  if o.toc then
    local depth = type(o.toc) == "number" and o.toc or tonumber(o.H) or 3
    out[#out + 1] = "\\setcounter{tocdepth}{" .. depth .. "}"
    out[#out + 1] = "\\tableofcontents"
    out[#out + 1] = ""
  end
  vim.list_extend(out, body)
  out[#out + 1] = "\\end{document}"
  return table.concat(out, "\n") .. "\n"
end

return M

---@mod org.export.html HTML backend

local ast = require("org.export.ast")

local M = {}

M.extension = "html"

M.DEFAULT_STYLE = [[
:root { --fg:#1f2328; --muted:#59636e; --bg:#ffffff; --code-bg:#f6f8fa; --border:#d1d9e0; --accent:#0969da; --todo:#cf222e; --done:#1a7f37; }
@media (prefers-color-scheme: dark) { :root { --fg:#e6edf3; --muted:#9198a1; --bg:#0d1117; --code-bg:#161b22; --border:#3d444d; --accent:#4493f8; --todo:#ff7b72; --done:#3fb950; } }
html { background: var(--bg); color: var(--fg); }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; line-height: 1.6; max-width: 52rem; margin: 2rem auto; padding: 0 1rem; }
h1.title { font-size: 2.2em; margin-bottom: 0.1em; } p.subtitle { color: var(--muted); font-size: 1.2em; margin-top: 0; }
h2, h3, h4, h5, h6 { margin-top: 1.6em; line-height: 1.25; } h2 { border-bottom: 1px solid var(--border); padding-bottom: .3em; }
a { color: var(--accent); text-decoration: none; } a:hover { text-decoration: underline; }
code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.9em; }
code { background: var(--code-bg); padding: .15em .35em; border-radius: 4px; }
pre { background: var(--code-bg); border: 1px solid var(--border); border-radius: 6px; padding: .8em 1em; overflow-x: auto; position: relative; }
pre code { background: none; padding: 0; }
pre.src[data-lang]::before { content: attr(data-lang); position: absolute; top: .2em; right: .6em; font-size: .75em; color: var(--muted); }
table { border-collapse: collapse; margin: 1em 0; } th, td { border: 1px solid var(--border); padding: .35em .7em; } thead th { background: var(--code-bg); }
td.org-right, th.org-right { text-align: right; }
blockquote { margin: 1em 0; padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
.todo { color: var(--todo); font-weight: bold; font-family: monospace; } .done { color: var(--done); font-weight: bold; font-family: monospace; }
.priority { font-family: monospace; color: var(--muted); }
.tag { float: right; } .tag span { font-family: monospace; font-size: .75em; background: var(--code-bg); border: 1px solid var(--border); border-radius: 1em; padding: .05em .6em; margin-left: .3em; font-weight: normal; }
.timestamp { color: var(--muted); font-family: monospace; font-size: .9em; }
.section-number-2, .section-number-3, .section-number-4, .section-number-5, .section-number-6 { color: var(--muted); margin-right: .3em; }
#table-of-contents { border: 1px solid var(--border); border-radius: 6px; padding: .5em 1.2em; margin: 1.5em 0; }
#table-of-contents h2 { border: none; margin-top: .4em; font-size: 1.1em; } #table-of-contents ul { list-style: none; padding-left: 1.2em; }
.footnotes { border-top: 1px solid var(--border); margin-top: 3em; font-size: .9em; } .footdef { display: flex; gap: .5em; } .footdef .footpara { margin: 0; }
.verse { white-space: pre-line; font-style: italic; } .org-center { text-align: center; }
.figure { text-align: center; margin: 1em 0; } .figure img { max-width: 100%; } .caption { color: var(--muted); font-size: .9em; }
ul.org-checkbox { list-style: none; padding-left: 1.2em; }
#postamble { margin-top: 3em; color: var(--muted); font-size: .85em; border-top: 1px solid var(--border); padding-top: .5em; }
.planning { color: var(--muted); font-family: monospace; font-size: .85em; }
]]

local function esc(s)
  return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end
M.escape = esc

local function special_strings(s)
  return (s:gsub("%-%-%-", "&#x2014;"):gsub("%-%-", "&#x2013;"):gsub("%.%.%.", "&#x2026;"):gsub("\\%-", "&#xad;"))
end

local function attrs(attr)
  if not attr then
    return ""
  end
  local out = {}
  for _, p in ipairs(require("org.babel.blocks").parse_header_string(attr)) do
    out[#out + 1] = string.format(' %s="%s"', p.key, esc((p.value:gsub('^"(.*)"$', "%1"))))
  end
  return table.concat(out)
end

---------------------------------------------------------------------------
-- Renderer
---------------------------------------------------------------------------

local R = {}
R.__index = R

function M.new(doc, opts)
  return setmetatable({ doc = doc, o = doc.options, opts = opts or {}, fn_n = {}, fn_order = {}, fn_defs = {}, has_math = false }, R)
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
    self.fn_defs[label] = { inline = def }
  end
  return self.fn_n[label]
end

function R:inline(nodes)
  local out = {}
  for _, nd in ipairs(nodes or {}) do
    local t = nd.type
    if t == "text" then
      local s = esc(nd.value)
      if self.o.special_strings ~= false then
        s = special_strings(s)
      end
      out[#out + 1] = s
    elseif t == "bold" then
      out[#out + 1] = "<b>" .. self:inline(nd.children) .. "</b>"
    elseif t == "italic" then
      out[#out + 1] = "<i>" .. self:inline(nd.children) .. "</i>"
    elseif t == "underline" then
      out[#out + 1] = '<span class="underline">' .. self:inline(nd.children) .. "</span>"
    elseif t == "strike" then
      out[#out + 1] = "<del>" .. self:inline(nd.children) .. "</del>"
    elseif t == "verbatim" or t == "code" then
      out[#out + 1] = "<code>" .. esc(nd.value) .. "</code>"
    elseif t == "sub" then
      out[#out + 1] = "<sub>" .. self:inline(nd.children) .. "</sub>"
    elseif t == "sup" then
      out[#out + 1] = "<sup>" .. self:inline(nd.children) .. "</sup>"
    elseif t == "linebreak" then
      out[#out + 1] = "<br />\n"
    elseif t == "entity" then
      out[#out + 1] = ast.ENTITIES[nd.name][1]
    elseif t == "latex" then
      self.has_math = true
      out[#out + 1] = esc(nd.value)
    elseif t == "timestamp" then
      if self.o.timestamps ~= false then
        out[#out + 1] = '<span class="timestamp-wrapper"><span class="timestamp">' .. esc(nd.value) .. "</span></span>"
      end
    elseif t == "target" then
      out[#out + 1] = '<a id="' .. esc(nd.id or ast.slug(nd.value)) .. '"></a>'
    elseif t == "snippet" then
      if nd.backend == "html" then
        out[#out + 1] = nd.value
      end
    elseif t == "footnote_ref" then
      if self.o.footnotes ~= false then
        local n = self:footnote(nd.label, nd.def)
        out[#out + 1] = string.format('<sup><a id="fnr.%d" class="footref" href="#fn.%d" role="doc-backlink">%d</a></sup>', n, n, n)
      end
    elseif t == "link" then
      out[#out + 1] = self:link(nd)
    end
  end
  return table.concat(out)
end

function R:link(nd)
  local kind, target, _ = ast.classify_link(self.doc, nd.path)
  local desc = nd.desc and self:inline(nd.desc) or nil
  local custom = require("org.links").export_link(nd.path, desc, "html")
  if custom then
    return custom
  elseif kind == "image" and not nd.desc then
    return string.format('<img src="%s" alt="%s" />', esc(target), esc(vim.fn.fnamemodify(target, ":t")))
  elseif kind == "image" then
    return string.format('<a href="%s">%s</a>', esc(target), desc)
  elseif kind == "url" then
    return string.format('<a href="%s">%s</a>', esc(target), desc or esc(nd.path))
  elseif kind == "internal" then
    local label = desc
    if not label then
      for _, h in ipairs(self.doc.headlines) do
        if h.id == target then
          label = h.number and table.concat(h.number, ".") or self:inline(h.title)
        end
      end
    end
    return string.format('<a href="#%s">%s</a>', esc(target), label or esc(nd.path))
  elseif kind == "file" then
    local href = target:gsub("%.org$", ".html")
    return string.format('<a href="%s">%s</a>', esc(href), desc or esc(target))
  elseif kind == "other" then
    return string.format('<a href="%s">%s</a>', esc(target), desc or esc(target))
  end
  return desc or ("<i>" .. esc(nd.path) .. "</i>")
end

--- Escaped code lines; lines with a coderef get an anchor.
local function code_html(nd)
  local out = {}
  for i, l in ipairs(nd.lines) do
    local label = nd.coderefs and nd.coderefs[i]
    if label then
      out[i] = string.format('<span id="coderef-%s" class="coderef-off">%s</span>', esc(ast.slug(label)), esc(l))
    else
      out[i] = esc(l)
    end
  end
  return table.concat(out, "\n")
end

local function is_num(s)
  return s:match("^%s*[-+]?[%d.,]+%%?%s*$") ~= nil and s:match("%d") ~= nil
end

function R:element(nd, out)
  local t = nd.type
  if t == "paragraph" then
    local caption = nd.affiliated and nd.affiliated.caption
    -- standalone image paragraph -> figure
    if #nd.inline == 1 and nd.inline[1].type == "link" and ast.classify_link(self.doc, nd.inline[1].path) == "image" and not nd.inline[1].desc then
      local img = self:link(nd.inline[1])
      if nd.affiliated and nd.affiliated.attr and nd.affiliated.attr.html then
        img = img:gsub(" />$", attrs(nd.affiliated.attr.html) .. " />")
      end
      out[#out + 1] = '<div class="figure"' .. (nd.id and (' id="' .. nd.id .. '"') or "") .. "><p>" .. img .. "</p>"
      if caption then
        out[#out + 1] = '<p class="caption">' .. self:inline(caption) .. "</p>"
      end
      out[#out + 1] = "</div>"
      return
    end
    out[#out + 1] = "<p>\n" .. self:inline(nd.inline) .. "\n</p>"
  elseif t == "headline" then
    self:headline(nd, out)
  elseif t == "list" then
    self:list(nd, out)
  elseif t == "table" then
    self:table(nd, out)
  elseif t == "src" then
    local id = nd.id and (' id="' .. nd.id .. '"') or ""
    out[#out + 1] = '<div class="org-src-container">'
    if nd.affiliated and nd.affiliated.caption then
      out[#out + 1] = '<label class="org-src-name">' .. self:inline(nd.affiliated.caption) .. "</label>"
    end
    out[#out + 1] = string.format(
      '<pre class="src src-%s"%s data-lang="%s"><code>%s</code></pre>',
      esc(nd.lang),
      id,
      esc(nd.lang),
      code_html(nd)
    )
    out[#out + 1] = "</div>"
  elseif t == "example" or t == "fixed" then
    local cls = nd.properties and "properties" or "example"
    out[#out + 1] = '<pre class="' .. cls .. '">' .. code_html(nd) .. "</pre>"
  elseif t == "quote" then
    out[#out + 1] = "<blockquote>"
    self:elements(nd.children, out)
    out[#out + 1] = "</blockquote>"
  elseif t == "center" then
    out[#out + 1] = '<div class="org-center">'
    self:elements(nd.children, out)
    out[#out + 1] = "</div>"
  elseif t == "special" then
    out[#out + 1] = '<div class="' .. esc(nd.name) .. '">'
    self:elements(nd.children, out)
    out[#out + 1] = "</div>"
  elseif t == "verse" then
    local parts = {}
    for _, l in ipairs(nd.lines) do
      parts[#parts + 1] = self:inline(l)
    end
    out[#out + 1] = '<p class="verse">' .. table.concat(parts, "<br />\n") .. "</p>"
  elseif t == "export" then
    if nd.backend == "html" then
      vim.list_extend(out, nd.lines)
    end
  elseif t == "latex_env" then
    self.has_math = true
    out[#out + 1] = '<div class="equation-container">' .. esc(table.concat(nd.lines, "\n")) .. "</div>"
  elseif t == "hr" then
    out[#out + 1] = "<hr />"
  elseif t == "keyword_toc" then
    self:toc(out, nd.depth)
  end
end

function R:elements(nodes, out)
  for _, nd in ipairs(nodes or {}) do
    self:element(nd, out)
  end
end

function R:list(nd, out)
  local checkbox = false
  for _, it in ipairs(nd.items) do
    if it.checkbox then
      checkbox = true
    end
  end
  local tag = nd.kind == "ordered" and "ol" or (nd.kind == "description" and "dl" or "ul")
  local cls = checkbox and "org-checkbox" or ("org-" .. tag)
  out[#out + 1] = "<" .. tag .. ' class="' .. cls .. '">'
  for _, it in ipairs(nd.items) do
    local box = ""
    if it.checkbox == "on" then
      box = "<code>[X]</code> "
    elseif it.checkbox == "off" then
      box = "<code>[&#xa0;]</code> "
    elseif it.checkbox == "trans" then
      box = "<code>[-]</code> "
    end
    local inner = {}
    -- single paragraph: inline it
    if #it.children == 1 and it.children[1].type == "paragraph" then
      inner[1] = self:inline(it.children[1].inline)
    else
      self:elements(it.children, inner)
    end
    if nd.kind == "description" then
      out[#out + 1] = "<dt>" .. box .. self:inline(it.term) .. "</dt><dd>" .. table.concat(inner, "\n") .. "</dd>"
    else
      local value = it.counter and (' value="' .. esc(it.counter) .. '"') or ""
      out[#out + 1] = "<li" .. value .. ">" .. box .. table.concat(inner, "\n") .. "</li>"
    end
  end
  out[#out + 1] = "</" .. tag .. ">"
end

function R:table(nd, out)
  if #nd.rows == 0 then
    return
  end
  -- numeric columns get right alignment
  local ncols, numeric, total = 0, {}, {}
  for _, r in ipairs(nd.rows) do
    if r ~= "hline" then
      ncols = math.max(ncols, #r.raw)
      for c, v in ipairs(r.raw) do
        if v ~= "" then
          total[c] = (total[c] or 0) + 1
          if is_num(v) then
            numeric[c] = (numeric[c] or 0) + 1
          end
        end
      end
    end
  end
  local id = nd.id and (' id="' .. nd.id .. '"') or ""
  out[#out + 1] = "<table" .. id .. attrs(nd.affiliated and nd.affiliated.attr and nd.affiliated.attr.html) .. ">"
  if nd.affiliated and nd.affiliated.caption then
    out[#out + 1] = '<caption class="t-above">' .. self:inline(nd.affiliated.caption) .. "</caption>"
  end
  local data_i = 0
  local in_head = nd.header > 0
  if in_head then
    out[#out + 1] = "<thead>"
  else
    out[#out + 1] = "<tbody>"
  end
  for _, r in ipairs(nd.rows) do
    if r == "hline" then
      if in_head and data_i >= nd.header then
        out[#out + 1] = "</thead>"
        out[#out + 1] = "<tbody>"
        in_head = false
      end
    else
      data_i = data_i + 1
      local cells = {}
      local tagc = in_head and "th" or "td"
      for c = 1, ncols do
        local right = (total[c] or 0) > 0 and (numeric[c] or 0) / total[c] >= 0.5
        local cls = right and ' class="org-right"' or ' class="org-left"'
        cells[#cells + 1] = "<" .. tagc .. (in_head and ' scope="col"' or "") .. cls .. ">" .. self:inline(r.cells[c] or {}) .. "</" .. tagc .. ">"
      end
      out[#out + 1] = "<tr>" .. table.concat(cells) .. "</tr>"
    end
  end
  out[#out + 1] = in_head and "</thead>" or "</tbody>"
  out[#out + 1] = "</table>"
end

function R:headline_title(nd)
  local parts = {}
  if nd.todo and self.o.todo ~= false then
    parts[#parts + 1] = string.format('<span class="%s %s">%s</span>', nd.todo_type, esc(nd.todo), esc(nd.todo))
  end
  if nd.priority and self.o.pri then
    parts[#parts + 1] = '<span class="priority">[' .. esc(nd.priority) .. "]</span>"
  end
  parts[#parts + 1] = self:inline(nd.title)
  local s = table.concat(parts, " ")
  if self.o.tags ~= false and #nd.tags > 0 then
    local tags = {}
    for _, tg in ipairs(nd.tags) do
      tags[#tags + 1] = '<span class="' .. esc(tg) .. '">' .. esc(tg) .. "</span>"
    end
    s = s .. '&#xa0;&#xa0;&#xa0;<span class="tag">' .. table.concat(tags, "&#xa0;") .. "</span>"
  end
  return s
end

function R:headline(nd, out)
  if nd.deep then
    local tag = nd.number and "ol" or "ul"
    out[#out + 1] = "<" .. tag .. ' class="org-' .. tag .. '">'
    out[#out + 1] = '<li><a id="' .. nd.id .. '"></a>' .. self:headline_title(nd) .. "<br />"
    self:elements(nd.children, out)
    out[#out + 1] = "</li>"
    out[#out + 1] = "</" .. tag .. ">"
    return
  end
  local h = math.min(nd.level + 1, 6)
  out[#out + 1] = string.format('<div id="outline-container-%s" class="outline-%d">', nd.id, h)
  local num = ""
  if nd.number then
    num = string.format('<span class="section-number-%d">%s</span> ', h, table.concat(nd.number, "."))
  end
  out[#out + 1] = string.format('<h%d id="%s">%s%s</h%d>', h, nd.id, num, self:headline_title(nd), h)
  out[#out + 1] = string.format('<div class="outline-text-%d" id="text-%s">', h, nd.id)
  if nd.planning then
    out[#out + 1] = '<p class="planning">' .. esc(nd.planning) .. "</p>"
  end
  local sub = {}
  for _, c in ipairs(nd.children) do
    if c.type ~= "headline" then
      self:element(c, out)
    else
      sub[#sub + 1] = c
    end
  end
  out[#out + 1] = "</div>"
  for _, c in ipairs(sub) do
    self:element(c, out)
  end
  out[#out + 1] = "</div>"
end

function R:toc(out, depth)
  local max = depth or (type(self.o.toc) == "number" and self.o.toc) or tonumber(self.o.H) or 3
  local items = {}
  local function walk(nodes)
    for _, nd in ipairs(nodes) do
      if nd.type == "headline" and not nd.deep and nd.level <= max then
        items[#items + 1] = nd
        walk(nd.children)
      end
    end
  end
  walk(self.doc.children)
  if #items == 0 then
    return
  end
  out[#out + 1] = '<div id="table-of-contents" role="doc-toc">'
  out[#out + 1] = "<h2>Table of Contents</h2>"
  out[#out + 1] = '<div id="text-table-of-contents" role="doc-toc">'
  local level = 0
  for _, nd in ipairs(items) do
    while level < nd.level do
      out[#out + 1] = "<ul>"
      level = level + 1
    end
    while level > nd.level do
      out[#out + 1] = "</ul>"
      level = level - 1
    end
    local num = nd.number and (table.concat(nd.number, ".") .. ". ") or ""
    local title = self:inline(nd.title)
    out[#out + 1] = string.format('<li><a href="#%s">%s%s</a></li>', nd.id, num, title)
  end
  while level > 0 do
    out[#out + 1] = "</ul>"
    level = level - 1
  end
  out[#out + 1] = "</div>"
  out[#out + 1] = "</div>"
end

function R:footnotes(out)
  if #self.fn_order == 0 then
    return
  end
  out[#out + 1] = '<div id="footnotes" class="footnotes">'
  out[#out + 1] = '<h2 class="footnotes">Footnotes</h2>'
  out[#out + 1] = '<div id="text-footnotes">'
  local i = 1
  while i <= #self.fn_order do
    local label = self.fn_order[i]
    local n = self.fn_n[label]
    local body
    local def = self.fn_defs[label]
    if def then
      body = self:inline(def.inline)
    else
      local els = self.doc.footnote_defs[label]
      local tmp = {}
      if els and #els == 1 and els[1].type == "paragraph" then
        tmp[1] = self:inline(els[1].inline)
      else
        self:elements(els or {}, tmp)
      end
      body = table.concat(tmp, "\n")
    end
    out[#out + 1] = string.format(
      '<div class="footdef"><sup><a id="fn.%d" class="footnum" href="#fnr.%d" role="doc-backlink">%d</a></sup> <div class="footpara" role="doc-footnote"><p class="footpara">%s</p></div></div>',
      n,
      n,
      n,
      body
    )
    i = i + 1
  end
  out[#out + 1] = "</div>"
  out[#out + 1] = "</div>"
end

--- Render the document. Returns a string.
---@param doc table
---@param opts? { body_only?: boolean }
function M.render(doc, opts)
  opts = opts or {}
  local r = M.new(doc, opts)
  local o = doc.options
  local body = {}
  if not opts.body_only and o.title ~= false and doc.title then
    body[#body + 1] = '<h1 class="title">' .. r:inline(ast.parse_inline(doc.title, o)) .. "</h1>"
    if doc.subtitle then
      body[#body + 1] = '<p class="subtitle" role="doc-subtitle">' .. r:inline(ast.parse_inline(doc.subtitle, o)) .. "</p>"
    end
  end
  if o.toc then
    r:toc(body)
  end
  r:elements(doc.children, body)
  r:footnotes(body)
  if opts.body_only then
    return table.concat(body, "\n") .. "\n"
  end
  local cfg = (require("org.config").opts.export or {}).html or {}
  local head = {
    "<!DOCTYPE html>",
    '<html lang="' .. esc(doc.language or "en") .. '">',
    "<head>",
    '<meta charset="utf-8" />',
    '<meta name="viewport" content="width=device-width, initial-scale=1" />',
    "<title>" .. esc(doc.title or "") .. "</title>",
    '<meta name="generator" content="org.nvim" />',
  }
  if doc.author and o.author then
    head[#head + 1] = '<meta name="author" content="' .. esc(doc.author) .. '" />'
  end
  if doc.description then
    head[#head + 1] = '<meta name="description" content="' .. esc(doc.description) .. '" />'
  end
  if doc.keywords then
    head[#head + 1] = '<meta name="keywords" content="' .. esc(doc.keywords) .. '" />'
  end
  if cfg.style == nil then
    head[#head + 1] = "<style>\n" .. M.DEFAULT_STYLE .. "</style>"
  elseif type(cfg.style) == "string" then
    head[#head + 1] = "<style>\n" .. cfg.style .. "\n</style>"
  end
  for _, h in ipairs(doc.html_head or {}) do
    head[#head + 1] = h
  end
  if cfg.head_extra and cfg.head_extra ~= "" then
    head[#head + 1] = cfg.head_extra
  end
  if r.has_math and cfg.mathjax ~= false then
    head[#head + 1] = [==[<script>window.MathJax = { tex: { inlineMath: [['$','$'], ['\\(','\\)']], displayMath: [['$$','$$'], ['\\[','\\]']] } };</script>]==]
    head[#head + 1] = '<script id="MathJax-script" async src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js"></script>'
  end
  head[#head + 1] = "</head>"
  head[#head + 1] = "<body>"
  head[#head + 1] = '<div id="content" class="content">'
  local tail = { "</div>", '<div id="postamble" class="status">' }
  if doc.author and o.author then
    tail[#tail + 1] = '<p class="author">Author: ' .. esc(doc.author) .. "</p>"
  end
  if o.date then
    tail[#tail + 1] = '<p class="date">' .. (doc.date and ("Date: " .. esc(doc.date)) or ("Created: " .. os.date("%Y-%m-%d %a %H:%M"))) .. "</p>"
  end
  tail[#tail + 1] = "</div>"
  tail[#tail + 1] = "</body>"
  tail[#tail + 1] = "</html>"
  return table.concat(head, "\n") .. "\n" .. table.concat(body, "\n") .. "\n" .. table.concat(tail, "\n") .. "\n"
end

return M

---@mod org.extensions.hugo.backend.blocks Hugo transcoders: markup, blocks and headlines
---
--- Markup, lists, targets, equations, source and example blocks with
--- their captions, TODO keywords, tags and headlines (with anchors,
--- numbers and containers). Part of org.extensions.hugo.backend, which
--- loads it.

local ox = require("org.export.ox")
local element = require("org.export.element")
local html = require("org.export.html")
local md = require("org.export.markdown")
local fm = require("org.extensions.hugo.front_matter")
local shared = require("org.extensions.hugo.backend.shared")

local M = require("org.extensions.hugo.backend")

local T = M.transcoders
local fmt = shared.fmt
local nw = shared.nw
local trim = shared.trim
local opts = shared.opts
local truthy = shared.truthy
local encode = shared.encode
local REF_PREFIX = shared.REF_PREFIX
local named_reference = shared.named_reference
local anchor_name = shared.anchor_name
local target_anchor = shared.target_anchor
local style_string = shared.style_string

--- Wrap in a div when the element has #+attr_html attributes (defined
--- with paragraphs, which load after this part).
local function div_wrap(el, contents)
  return shared.div_wrap(el, contents)
end

T.italic = function(_, contents)
  return "_" .. (contents or "") .. "_"
end

T["strike-through"] = function(_, contents)
  return "~~" .. (contents or "") .. "~~"
end

--- `~code~`: <kbd> with `use_code_for_kbd`.
T.code = function(el, contents, info)
  if truthy(info.hugo_use_code_for_kbd) then
    return "<kbd>" .. encode(el.value) .. "</kbd>"
  end
  return md.transcoders.code(el)
end

T["plain-text"] = function(text, info, node)
  local orig = text
  text = text:gsub("[`*\\]", "\\%0")
  -- _ next to a word boundary
  text = text:gsub("(%S)_([%s%.!%?])", "%1\\_%2"):gsub("(%S)_$", "%1\\_")
  text = text:gsub("(%s)_(%S)", "%1\\_%2"):gsub("^_(%S)", "\\_%1")
  text = encode(text)
  text = text:gsub("{{%%", "{&lbrace;%%"):gsub("%%}}", "%%&rbrace;}")
  text = text:gsub("\n#", "\n\\#")
  text = text:gsub("!%[", "\\![")
  if info.with_smart_quotes and node then
    text = ox.activate_smart_quotes(text, "html", info, node)
  end
  if info.with_special_strings then
    text = html.convert_special_strings(text)
  end
  if info.preserve_breaks then
    text = text:gsub("[ \t]*\n", " <br/>\n")
  end
  _ = orig
  return text
end

T["footnote-reference"] = function(el, _, info)
  local sep = ""
  local prev = ox.get_previous_element(el, info)
  if prev and prev.type == "footnote-reference" then
    sep = info.html_footnote_separator or "<sup>, </sup>"
  end
  return sep .. fmt("[^fn:%d]", ox.get_footnote_number(el, info))
end

T["center-block"] = function(_, contents)
  return '<style>.org-center { margin-left: auto; margin-right: auto; text-align: center; }</style>\n\n<div class="org-center">\n\n'
    .. (contents or "")
    .. "\n</div>"
end

T["verse-block"] = function(_, contents, info)
  local s = contents or ""
  s = s:gsub("^([ \t\n\r]-)[ \t]*&gt;", "%1")
  local br = html.close_tag("br", nil, info)
  s = s:gsub(vim.pesc(br) .. "[ \t]*\n", "\n")
  s = s:gsub("[ \t]*\n", require("org.utils").gsub_escape(br .. "\n"))
  s = s:gsub("\n([ \t]+)", function(ws)
    return "\n" .. string.rep("&nbsp;", #ws)
  end)
  s = s:gsub("^([ \t]+)", function(ws)
    return string.rep("&nbsp;", #ws)
  end)
  return '<div class="verse">\n\n' .. s .. "\n</div>"
end

T["quote-block"] = function(el, contents, info)
  local s = div_wrap(el, md.transcoders["quote-block"](el, contents))
  local nxt = ox.get_next_element(el, info)
  if nxt and nxt.type == "quote-block" then
    s = s .. "\n\n<!--quoteend-->"
  end
  return s
end

T["plain-list"] = function(el, contents, info)
  local s = div_wrap(el, contents or "")
  local nxt = ox.get_next_element(el, info)
  if nxt and (nxt.type == "plain-list" or nxt.type == "src-block" or nxt.type == "example-block") then
    s = s .. "\n<!--listend-->"
  end
  return s
end

--- org-blackfriday-item: "-   " bullets, `[X]` boxes, and top-level
--- description lists as "Term\n: description".
T.item = function(el, contents, info)
  local list = el.parent
  local desc_list = list.list_type == "descriptive"
  local nested = desc_list and list.parent and list.parent.type == "item"
  local num = ox.get_ordinal(el, info)
  local n = type(num) == "table" and num[#num] or num or 1
  local bullet
  if list.list_type == "unordered" or (desc_list and nested) then
    bullet = "-"
  elseif list.list_type == "ordered" then
    bullet = fmt("%d. ", n)
  else
    bullet = n > 1 and "\n" or ""
  end
  local padding = ""
  if not (desc_list and not nested) and #bullet <= 3 then
    padding = string.rep(" ", 4 - #bullet)
  end
  local box = ({ on = "[X] ", trans = "[-] ", off = "[ ] " })[el.checkbox or ""] or ""
  local tag = ""
  if desc_list and el.tag then
    local t = ox.data(el.tag, info)
    tag = nested and fmt("**%s:** ", t) or (t .. "\n: ")
  end
  local body = contents and trim(md.prefix_lines(contents, "    ")) or ""
  return bullet .. padding .. box .. tag .. body
end

T.target = function(el)
  local anchor = target_anchor(el.value)
  return fmt('<span class="org-target" id="%s"></span>', anchor)
end

T["radio-target"] = function(el, text)
  local ref = REF_PREFIX.radio .. anchor_name(el.value)
  return fmt('<span class="org-radio" id="%s">%s</span>', ref, text or "")
end

--- Escape what Markdown would read in an equation
--- (org-blackfriday-escape-chars-in-equation).
local function escape_equation(s)
  s = s:gsub("(\\[%]%[(){}!\"#%$%%&'%*%+,%./:;<=>%?@\\%^_`|~%-])", "\\%1")
  s = s:gsub("[_%*`]", "\\%0")
  s = s:gsub("%(([cC])%)", "( %1)"):gsub("%(([rR])%)", "( %1)"):gsub("%(([tT][mM])%)", "( %1)")
  s = s:gsub("%]%(", "\\]\\(")
  s = s:gsub("\\[ \t]*\n", "\\\\\n"):gsub("\\[ \t]*$", "\\\\")
  return s
end
M.escape_equation = escape_equation

local function mathjax_p(info)
  return info.with_latex == true or info.with_latex == "mathjax" or info.with_latex == "t"
end

T["latex-fragment"] = function(el, contents, info)
  if not mathjax_p(info) then
    return html.transcoders["latex-fragment"](el, contents, info)
  end
  local v = el.value
  if v:sub(1, 2) == "$$" and v:sub(-2) == "$$" and #v >= 4 then
    v = "\\[" .. v:sub(3, -3) .. "\\]"
  elseif v:sub(1, 1) == "$" and v:sub(-1) == "$" and #v >= 2 then
    v = "\\(" .. v:sub(2, -2) .. "\\)"
  end
  return escape_equation(v)
end

T["latex-environment"] = function(el, contents, info)
  if not mathjax_p(info) then
    return html.transcoders["latex-environment"](el, contents, info)
  end
  return escape_equation(md.transcoders["latex-environment"](el, contents, info) or "")
end

T["line-break"] = function(el, contents, info)
  return html.transcoders["line-break"](el, contents, info)
end

T["fixed-width"] = function(el, _, info)
  local code =
    ox.format_code_default({ type = "example-block", value = el.value .. "\n", preserve_indent = true }, info)
  return "```text\n" .. code .. "```"
end

--- Escape Hugo shortcodes in the code of some languages
--- (org-hugo--escape-hugo-shortcode).
local function escape_shortcodes(code, lang)
  if lang == "md" or lang == "org" or lang == "go-html-template" or lang == "emacs-lisp" then
    code = code:gsub("({{%%)([^}][^}]-)(%%}})", "%1/*%2*/%3")
    code = code:gsub("({{<)([^}][^}]-)(>}})", "%1/*%2*/%3")
  end
  return code
end
M.escape_shortcodes = escape_shortcodes

local SYNTAX_LANGS = {
  ipython = "python",
  ["jupyter-python"] = "python",
  ["conf-toml"] = "toml",
  ["conf-space"] = "cfg",
  conf = "cfg",
}

--- Header arguments of a source block, `:key value` pairs.
local function block_params(el)
  local out = {}
  for _, kv in ipairs(fm.parse_arguments(el.parameters)) do
    out[kv[1]] = kv[2]
  end
  return out
end

--- A caption div for a code block or table.
local function caption_div(el, kind, ref, info)
  local caption = ox.get_caption(el)
  if not caption then
    return "", nil
  end
  local num = ox.get_ordinal(el, info, nil, function(e)
    return ox.get_caption(e) ~= nil
  end)
  local prefix = ox.translate(kind == "table" and "Table" or "Code Snippet", "html", info)
  local text = html.convert_special_strings(ox.data_with_backend(caption, "html", info))
  local label = ref and fmt('<a href="#%s">%s %s</a>', ref, prefix, tostring(num))
    or fmt("%s %s", prefix, tostring(num))
  if kind == "table" then
    return fmt('<div class="table-caption">\n  <span class="table-number">%s:</span>\n  %s\n</div>\n', label, text), num
  end
  return fmt(
    '\n<div class="src-block-caption">\n  <span class="src-block-number">%s:</span>\n  %s\n</div>',
    label,
    text
  ),
    num
end

--- org-hugo-src-block (in Goldmark mode): a fenced block with
--- `{ linenos=..., hl_lines=[...] }` attributes, or the `highlight`
--- shortcode when code fences are off (HUGO_CODE_FENCE empty);
--- `:front_matter_extra t` TOML/YAML blocks go into the front matter.
T["src-block"] = function(el, _, info)
  local lang = el.language
  local params = block_params(el)
  if truthy(params.front_matter_extra) and (lang == "toml" or lang == "yaml") then
    if lang == (info.hugo_front_matter_format or "toml") then
      info.hugo_fm_extra = ox.format_code_default(el, info)
    end
    return nil
  end
  local line_num_p = el.number_lines ~= nil
  local linenos = params.linenos ~= nil and tostring(params.linenos) or el.linenos_style
  local hl = params.hl_lines
  if type(hl) == "number" then
    hl = tostring(hl)
  end
  local style = params["syntax-style"]
  local fence = truthy(info.hugo_code_fence)
  local use_sc = not fence
  if type(hl) == "string" then
    if use_sc then
      hl = hl:gsub(",", " ")
    else
      local parts = {}
      for p in hl:gmatch("[^,]+") do
        parts[#parts + 1] = fmt("%q", vim.trim(p))
      end
      hl = "[" .. table.concat(parts, ",") .. "]"
    end
  else
    hl = nil
  end
  if el.parent and el.parent.type == "item" and not ox.get_caption(el) then
    -- (org-blackfriday-separate-elements) no blank line before a paragraph
    local nxt = ox.get_next_element(el, info)
    if nxt and nxt.type == "paragraph" then
      el.post_blank = 0
    end
  end
  local ref = named_reference(el, "src-block")
  local anchor = ref and fmt('<a id="%s"></a>\n', ref) or ""
  local caption = caption_div(el, "src", ref, info)
  local code = escape_shortcodes(ox.format_code_default(el, info), lang)
  local attrs = {}
  if not use_sc then
    local a = ox.read_attribute("attr_html", el)
    local s = html.attribute_string(a)
    if nw(s) then
      attrs[#attrs + 1] = s
    end
  end
  if linenos or line_num_p then
    attrs[#attrs + 1] = "linenos=" .. (linenos or "true")
    local start = code:match("^%s*(%d+)  ")
    if start then
      attrs[#attrs + 1] = "linenostart=" .. start
    end
    if line_num_p then
      code = code:gsub("\n%s*%d+  ", "\n"):gsub("^%s*%d+  ", "")
    end
  end
  if hl then
    attrs[#attrs + 1] = "hl_lines=" .. hl
  end
  if style then
    attrs[#attrs + 1] = "style=" .. tostring(style)
  end
  local attr_str = table.concat(attrs, ", ")
  local body
  if use_sc then
    body = fmt(
      "{{< highlight %s%s >}}\n%s{{< /highlight >}}\n",
      lang or "",
      nw(attr_str) and fmt(' "%s"', attr_str) or "",
      code
    )
  else
    local ticks = "```"
    local longest = 0
    for run in code:gmatch("\n?[ \t]*(```+)") do
      longest = math.max(longest, #run)
    end
    if longest >= 3 then
      ticks = string.rep("`", longest + 1)
    end
    if el.parent and el.parent.type == "item" then
      -- Blackfriday issue 239: list markers at the start of code lines
      code = code:gsub("\n([ \t]*[-+*] )", "\n\226\128\139%1"):gsub("^([ \t]*[-+*] )", "\226\128\139%1")
    end
    local l = SYNTAX_LANGS[lang or ""] or lang or ""
    body = ticks .. l .. (nw(attr_str) and (" { " .. attr_str .. " }") or "") .. "\n" .. code .. ticks
  end
  if not use_sc then
    return style_string(el) .. anchor .. body .. caption
  end
  return div_wrap(el, anchor .. body .. caption)
end

--- org-hugo-example-block: a "text" source block (`:linenos` in the
--- switches too). Like ox-hugo, the element itself gets the language, so
--- line numbers continued from earlier blocks are found.
T["example-block"] = function(el, contents, info)
  el.language = "text"
  local sw = el.switches
  if nw(sw) then
    el.linenos_style = sw:match(":linenos%s+([^%s]+)")
  end
  return T["src-block"](el, contents, info)
end

T["inline-src-block"] = function(el, _, info)
  local lang = el.language or ""
  local copy = setmetatable({ value = escape_shortcodes(el.value, lang) }, { __index = el })
  return fmt('<span class="inline-src language-%s" data-lang="%s">%s</span>', lang, lang, md.transcoders.verbatim(copy))
end

T["export-snippet"] = function(el, contents, info)
  local b = el.back_end
  if b == "hugo" or b == "markdown" or b == "md" then
    return el.value
  end
  return ox.with_backend("html", el, contents, info)
end

T["export-block"] = function(el, contents, info)
  if el.back_end_type == "HUGO" then
    local lines = element.remove_indentation(vim.split((el.value:gsub("\n$", "")), "\n", { plain = true }))
    return table.concat(lines, "\n") .. "\n"
  end
  return md.transcoders["export-block"](el, contents, info)
end

T.drawer = function(el, contents, info)
  local name = (el.drawer_name or ""):upper()
  local log = require("org.api").option("log_into_drawer")
  if name == "LOGBOOK" or (type(log) == "string" and name == log:upper()) then
    return ""
  end
  return html.transcoders.drawer(el, contents)
end

--- `#+hugo: more` is the summary splitter; other `#+hugo:` values are
--- written as they are.
T.keyword = function(el, contents, info)
  local k, v = el.key, el.value or ""
  if k == "HUGO" then
    if v:match("^%s*more%s*$") then
      return "<!--more-->"
    end
    return v
  elseif k == "TOC" and v:match("%f[%w]headlines%f[%W]") then
    local depth = tonumber(v:match("%f[%d](%d+)%f[%D]"))
    local localp = v:match("%f[%w]local%f[%W]") ~= nil
    local scope = localp and el or nil
    if depth and depth > 0 then
      local toc = M.build_toc(info, depth, scope, localp)
      if toc then
        local lines = element.remove_indentation(vim.split((toc:gsub("\n$", "")), "\n", { plain = true }))
        return table.concat(lines, "\n") .. "\n"
      end
    end
    return nil
  end
  return md.transcoders.keyword(el, contents, info)
end

--- A valid class name (org-html-fix-class-name).
local function class_name(s)
  return (s:gsub("[^%w_]", "_"))
end

--- The HTML of a TODO keyword (org-hugo--todo).
local function todo_html(todo, info)
  local done = info.todo_done and info.todo_done(todo)
  return fmt(
    '<span class="org-todo %s %s%s">%s</span>',
    done and "done" or "todo",
    info.html_todo_kwd_class_prefix or "",
    class_name(todo),
    (todo:gsub("([^_])__([^_])", "%1 %2"))
  )
end

--- Tags processed like ox-hugo's `org-hugo-tag-processing-functions`:
--- `a__b` -> "a b" (allow_spaces_in_tags), `a_b` -> "a-b" and `a___b`
--- -> "a_b" (prefer_hyphen_in_tags).
---@param tags string[]
---@param info table
---@return string[]
function M.process_tags(tags, info)
  local out = {}
  for _, t in ipairs(tags) do
    if truthy(info.hugo_allow_spaces_in_tags) then
      local prev
      repeat
        prev = t
        t = t:gsub("([^_])__([^_])", "%1 %2")
      until t == prev
    end
    if truthy(info.hugo_prefer_hyphen_in_tags) then
      t = t:gsub("^_([^_])", "-%1")
      t = t:gsub("^___([^_])", "_%1")
      t = t:gsub("([^_])_$", "%1-")
      t = t:gsub("([^_])___$", "%1_")
      t = t:gsub("([^_])_([^_])", "%1-%2")
      t = t:gsub("([^_])___([^_])", "%1_%2")
    end
    out[#out + 1] = t
  end
  return out
end

local function tags_html(tags, info)
  if #tags == 0 then
    return nil
  end
  local parts = {}
  for _, t in ipairs(tags) do
    parts[#parts + 1] = fmt('<span class="%s%s">%s</span>', info.html_tag_class_prefix or "", class_name(t), t)
  end
  return '<span class="tag">' .. table.concat(parts) .. "</span>"
end

--- Section number of a headline (org-hugo--get-heading-number).
local function heading_number(h, info, toc)
  local onlytoc = info.section_numbers == "onlytoc"
  if (toc or not onlytoc) and ox.numbered_headline_p(h, info) then
    local nums = {}
    for i, n in ipairs(ox.get_headline_number(h, info) or {}) do
      nums[i] = tostring(n)
    end
    if #nums > 0 then
      return fmt('<span class="section-num">%s</span> ', table.concat(nums, "."))
    end
  end
  return nil
end

local function container(h, info)
  local props = h.props or {}
  if nw(props.HTML_CONTAINER) then
    return props.HTML_CONTAINER
  elseif nw(props.EXPORT_HTML_CONTAINER) then
    return props.EXPORT_HTML_CONTAINER
  elseif nw(info.html_container) then
    if truthy(info.html_container_nested) or ox.get_relative_level(h, info) == 1 then
      return info.html_container
    end
    return "div"
  end
  return nil
end

T.headline = function(el, contents, info)
  if el.footnote_section_p then
    return nil
  end
  local numbers = heading_number(el, info, false)
  local loffset = tonumber(info.hugo_level_offset) or 0
  local level = ox.get_relative_level(el, info)
  local effective = loffset + level
  local title = ox.data(el.title, info)
  local todo = info.with_todo_keywords and el.todo_keyword or nil
  local todo_s = todo and (todo_html(todo, info) .. " ") or ""
  local tags_s = ""
  if info.with_tags then
    local t = tags_html(M.process_tags(ox.get_tags(el, info), info), info)
    if t then
      tags_s = " " .. t
    end
  end
  local priority = (info.with_priority and el.priority) and fmt("[#%s] ", el.priority) or ""
  local style = info.md_headline_style or "atx"
  if
    ox.low_level_p(el, info)
    or not (style == "atx" or style == "setext")
    or (style == "atx" and effective > 6)
    or (style == "setext" and effective > 2)
  then
    local bullet = "-"
    if ox.numbered_headline_p(el, info) then
      local num = ox.get_headline_number(el, info)
      bullet = tostring(num[#num]) .. "."
    end
    local heading = todo_s .. " " .. priority .. title
    local body = contents and md.prefix_lines(contents, "    ") or ""
    return "<!--list-separator-->\n\n" .. bullet .. " " .. heading .. tags_s .. "\n\n" .. body
  end
  local anchor = truthy(opts().headline_anchor) and ("{#" .. M.anchor(el, info) .. "}") or ""
  local heading = todo_s .. (numbers or "") .. title .. tags_s .. " " .. anchor .. "\n"
  local heading_title
  if style == "setext" and level < 3 then
    heading_title = "\n" .. heading .. string.rep(level == 1 and "=" or "-", vim.fn.strchars(heading)) .. "\n\n"
  else
    heading_title = "\n" .. string.rep("#", effective) .. " " .. heading .. "\n"
  end
  local content = nw(contents) and contents or ""
  local wrap = container(el, info)
  if wrap then
    local props = el.props or {}
    local class = props.HTML_CONTAINER_CLASS or props.EXPORT_HTML_CONTAINER_CLASS or info.html_container_class
    class = nw(class) and (" " .. class) or ""
    return fmt('<%s class="outline-%d%s">\n%s%s\n</%s>', wrap, level, class, heading_title, content, wrap)
  end
  return heading_title .. content
end

shared.caption_div = caption_div
shared.escape_shortcodes = escape_shortcodes
shared.heading_number = heading_number
shared.todo_html = todo_html

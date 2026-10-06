---@mod org.extensions.hugo.backend The `hugo` export back-end (port of ox-hugo)
---
--- Derived from `md` with the Blackfriday changes ox-hugo builds on
--- (fenced code, pipe tables, `[^fn:N]` footnotes, `_italic_`,
--- `~~strike~~`, `<details>` blocks) and ox-hugo's own transcoders:
--- headings with `{#anchor}`s one level down, `{{< figure >}}` for
--- standalone images, `{{< relref >}}` for links to other posts and Org
--- files, attachments copied to the site, `{{< highlight >}}` when code
--- fences are off, paired shortcodes, `#+begin_description`, `#+hugo:
--- more` and the front matter (`org.extensions.hugo.front_matter`) put
--- before the body by a body filter. `org.extensions.hugo.export` drives
--- it (which post, which file).

local ox = require("org.export.ox")
local element = require("org.export.element")
local html = require("org.export.html")
local md = require("org.export.markdown")
local fm = require("org.extensions.hugo.front_matter")

local M = {}

local fmt = string.format
local nw = ox.nw
local trim = ox.trim

local TRIM_PRE = "<!-- trim-pre -->"
local TRIM_POST = "<!-- trim-post -->"

--- Options of the extension (its defaults when it is not enabled).
local function opts()
  return require("org.extensions").opts("hugo") or require("org.extensions.hugo").defaults
end

--- org-hugo--value-get-true-p: nil, false, "", "nil" (and "false") are false.
---@param v any
---@return boolean
local function truthy(v)
  if v == nil or v == false then
    return false
  end
  if type(v) == "string" then
    local l = vim.trim(v):lower()
    return l ~= "" and l ~= "nil" and l ~= "false"
  end
  return true
end
M.truthy = truthy

--- "true" / "false" for a front matter boolean
--- (org-hugo--front-matter-value-booleanize).
---@param v any
---@return string
local function booleanize(v)
  if v == true then
    return "true"
  end
  local l = type(v) == "string" and vim.trim(v):lower() or nil
  if v == nil or v == false or l == "nil" or l == "false" or l == "no" or l == "" then
    return "false"
  elseif l == "t" or l == "true" or l == "yes" then
    return "true"
  end
  error(fmt("%q needs to represent a boolean value", tostring(v)), 0)
end
M.booleanize = booleanize

---------------------------------------------------------------------------
-- Anchors and references
---------------------------------------------------------------------------

local HTML_ESC = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }

local function encode(s)
  return (s:gsub("[&<>]", HTML_ESC))
end

--- Title of a headline as Markdown (for slugs).
local function md_title(h, info)
  return ox.data_with_backend(h.title or {}, "md", info)
end

--- Anchor of a headline (org-hugo--get-anchor with the default
--- `org-hugo-anchor-functions`): its EXPORT_FILE_NAME (a post inside the
--- post), CUSTOM_ID, the slug of its title, or an MD5 of the title.
---@param h table headline
---@param info table
---@return string
function M.anchor(h, info)
  local props = h.props or {}
  local file = nw(props.EXPORT_FILE_NAME)
  if file then
    local bundle = nw(props.EXPORT_HUGO_BUNDLE)
    if bundle and (file == "index" or file == "_index") then
      return vim.fn.fnamemodify(bundle, ":t:r")
    end
    return vim.fn.fnamemodify(file, ":t:r")
  end
  if nw(props.CUSTOM_ID) then
    return props.CUSTOM_ID
  end
  local title = md_title(h, info)
  local slug = nw(title) and nw(fm.slug(title, true))
  if slug then
    return slug
  end
  return vim.fn.sha256(title or ""):sub(1, 6)
end

--- Prefixes of named element anchors (org-blackfriday--get-ref-prefix).
local REF_PREFIX = {
  figure = "figure--",
  radio = "org-radio--",
  ["src-block"] = "code-snippet--",
  table = "table--",
  target = "org-target--",
}

--- Anchor from a `#+name` (org-blackfriday--get-reference), or nil.
---@param el table
---@param kind? string
---@return string|nil
local function named_reference(el, kind)
  local name = el.name
  if not nw(name) then
    return nil
  end
  local prefix = REF_PREFIX[kind or el.type] or ("org-" .. el.type .. "--")
  for _, p in ipairs({ "code__", "tab__", "table__", "img__", "fig__", "figure__", "__" }) do
    if name:sub(1, #p) == p then
      name = name:sub(#p + 1)
      break
    end
  end
  return prefix .. name:gsub("[_/]", "-")
end

--- A valid anchor name (org-blackfriday--valid-html-anchor-name).
local function anchor_name(s)
  return (s:gsub("^%.", ""):gsub("[^%w%-_:%.]", "-"))
end

--- Anchor of a `<<target>>` (org-blackfriday--get-target-anchor).
local function target_anchor(value)
  if value:sub(1, 1) == "." then
    return anchor_name(value)
  end
  return REF_PREFIX.target .. anchor_name(value)
end
M.target_anchor = target_anchor

---------------------------------------------------------------------------
-- Transcoders
---------------------------------------------------------------------------

--- CSS of #+attr_css (org-blackfriday--make-css-property-string).
local function css_string(el)
  local a = ox.read_attribute("attr_css", el)
  local parts = {}
  for _, k in ipairs(a._keys) do
    if a[k] ~= nil then
      parts[#parts + 1] = fmt("%s: %s; ", k, (encode(a[k]):gsub('"', "&quot;")))
    end
  end
  return table.concat(parts, " ")
end

--- A <style> for the first #+attr_html class of `el` from its #+attr_css
--- (org-blackfriday--get-style-str).
local function style_string(el)
  local class = ox.read_attribute("attr_html", el, "class")
  local first = class and class:match("%S+")
  local css = first and css_string(el) or ""
  if nw(css) then
    return fmt("<style>.%s { %s }</style>\n\n", first, css)
  end
  return ""
end

local T = {}

-- wraps an element with #+attr_html in a <div> (defined with paragraphs)
local div_wrap

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
  local log = require("org.config").opts.log_into_drawer
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

---------------------------------------------------------------------------
-- Paragraphs and tables
---------------------------------------------------------------------------

--- Wrap in a div when the element has #+attr_html attributes
--- (org-blackfriday--div-wrap-maybe).
div_wrap = function(el, contents)
  local a = ox.read_attribute("attr_html", el)
  if el.type == "paragraph" then
    for _, k in ipairs({ "target", "rel", "src", "alt", "height", "width", "caption" }) do
      a[k] = nil
    end
  end
  local s = html.attribute_string(a)
  if not nw(s) then
    return contents
  end
  return style_string(el) .. fmt("<div %s>\n\n%s\n</div>", s, contents)
end

--- Is the post in Chinese or Japanese (org-hugo--lang-cjk-p)?
local function cjk_p(info)
  local l = nw(info.hugo_locale) or vim.env.LANGUAGE or vim.env.LC_ALL or vim.env.LANG or ""
  local two = l:sub(1, 2)
  return two == "zh" or two == "ja"
end

local function process_paragraph(el, contents, info)
  local s = contents or ""
  if cjk_p(info) then
    -- join lines of CJK text without a space
    s = s:gsub("([\128-\255])[ \t]*\n[ \t]*([\192-\255])", "%1%2")
  end
  if not truthy(info.hugo_preserve_filling) then
    local words = {}
    for w in s:gmatch("%S+") do
      words[#words + 1] = w
    end
    s = table.concat(words, " ") .. "\n"
  end
  s = s:gsub("(%[%^[^%]]+%])[ \t]*(%.+)", "%1%2")
  s = s:gsub("[ \t]+(%[%^[^%]]+%])", "&nbsp;%1")
  return md.transcoders.paragraph(el, s)
end

T.paragraph = function(el, contents, info)
  local parent = el.parent
  if parent and parent.type == "item" then
    -- (org-blackfriday-separate-elements) no blank line before a block
    local nxt = ox.get_next_element(el, info)
    if nxt and (nxt.type == "src-block" or nxt.type == "example-block") then
      el.post_blank = 0
    end
  end
  if parent and parent.type == "item" and not ox.get_previous_element(el, info) then
    local nxt = ox.get_next_element(el, info)
    local after = nxt and ox.get_next_element(nxt, info)
    if not after and (not nxt or nxt.type == "plain-list") then
      return process_paragraph(el, contents, info)
    end
  end
  if html.standalone_image_p(el, info) then
    local ref = named_reference(el, "figure")
    return (ref and fmt('<a id="%s"></a>\n\n', ref) or "") .. (contents or "")
  end
  local label = nw(el.name) and fmt('<a id="%s"></a>\n\n', ox.get_reference(el, info)) or ""
  return div_wrap(el, label .. process_paragraph(el, contents, info))
end

T.table = function(el, _, info)
  if el.table_type == "table.el" then
    return html.transcoders.table(el, nil, info)
  end
  local rows = {}
  local special = ox.table_has_special_column_p(el)
  local align = {}
  for _, r in ipairs(el.contents) do
    if r.row_type == "standard" then
      if ox.table_row_is_special_p(r, info) then
        local cells = r.contents
        for c = (special and 2 or 1), #cells do
          local v = cells[c].contents
          local txt = v and #v == 1 and v[1].type == "plain-text" and v[1].value or nil
          local a = txt and txt:match("^<([lrc])%d*>$")
          if a then
            align[c - (special and 1 or 0)] = a
          end
        end
      elseif not info.ignore[r] then
        local cells = {}
        for c, cell in ipairs(r.contents) do
          if not info.ignore[cell] and not (special and c == 1) then
            cells[#cells + 1] = (ox.data(cell.contents, info):gsub("|", "\\|"))
          end
        end
        rows[#rows + 1] = cells
      end
    end
  end
  if #rows == 0 then
    return nil
  end
  local ncols, widths = 0, {}
  for _, r in ipairs(rows) do
    ncols = math.max(ncols, #r)
    for c, v in ipairs(r) do
      widths[c] = math.max(widths[c] or 0, vim.fn.strdisplaywidth(v))
    end
  end
  local function line(cells)
    local parts = {}
    for c = 1, ncols do
      local v = cells[c] or ""
      local cell = "| " .. v .. string.rep(" ", math.max(0, (widths[c] or 0) - vim.fn.strdisplaywidth(v))) .. " "
      if #cell < 3 then
        cell = cell .. string.rep(" ", 3 - #cell)
      end
      parts[#parts + 1] = cell
    end
    return table.concat(parts) .. "|"
  end
  local function rule()
    local parts = {}
    for c = 1, ncols do
      local w = math.max(1, widths[c] or 0) + 2
      local seg = string.rep("-", w)
      local a = align[c]
      if a == "l" or a == "c" then
        seg = ":" .. seg:sub(2)
      end
      if a == "r" or a == "c" then
        seg = seg:sub(1, -2) .. ":"
      end
      parts[#parts + 1] = "|" .. seg
    end
    return table.concat(parts) .. "|"
  end
  local out = {}
  if #rows == 1 then
    out[#out + 1] = line({})
    out[#out + 1] = rule()
    out[#out + 1] = line(rows[1])
  else
    out[#out + 1] = line(rows[1])
    out[#out + 1] = rule()
    for i = 2, #rows do
      out[#out + 1] = line(rows[i])
    end
  end
  local ref = named_reference(el, "table")
  local anchor = ref and fmt('<a id="%s"></a>\n', ref) or ""
  local caption, num = caption_div(el, "table", ref, info)
  local a = ox.read_attribute("attr_html", el)
  local class = nw(a.class) or ("table-" .. (num and tostring(num) or "nocaption"))
  local css = css_string(el)
  local pre, post = "", ""
  if nw(css) then
    pre = fmt("<style>.%s table { %s }</style>\n\n", class:match("%S+"), css)
  end
  if nw(a.class) or nw(css) then
    pre = pre .. fmt('<div class="ox-hugo-table %s">\n', class)
  end
  if pre ~= "" then
    post = "\n</div>\n"
  end
  local blank = (pre .. anchor .. caption) ~= "" and "\n" or ""
  return pre .. anchor .. caption .. blank .. table.concat(out, "\n") .. "\n" .. post
end

---------------------------------------------------------------------------
-- Special blocks
---------------------------------------------------------------------------

--- org-blackfriday-html5-inline-elements
local HTML5_INLINE = {
  "abbr",
  "audio",
  "bdi",
  "bdo",
  "button",
  "canvas",
  "cite",
  "data",
  "datalist",
  "del",
  "dfn",
  "embed",
  "iframe",
  "input",
  "ins",
  "kbd",
  "label",
  "map",
  "mark",
  "meter",
  "noscript",
  "object",
  "output",
  "picture",
  "progress",
  "q",
  "ruby",
  "s",
  "samp",
  "script",
  "select",
  "slot",
  "small",
  "span",
  "svg",
  "template",
  "textarea",
  "time",
  "u",
  "var",
  "video",
}
local HTML5_BLOCK = {
  "article",
  "aside",
  "audio",
  "canvas",
  "details",
  "figcaption",
  "figure",
  "footer",
  "header",
  "menu",
  "meter",
  "nav",
  "output",
  "progress",
  "section",
  "summary",
  "video",
}

local function block_type_props(btype)
  local props = opts().special_block_type_properties or {}
  return props[btype] or {}
end

--- The Org source of a block's contents (for `raw` blocks).
local function raw_contents(el)
  return element.interpret(el.contents or {})
end

--- org-blackfriday-special-block: <details>/<summary>, HTML5 elements,
--- else a <div> (or <span> with trimming) with the type as class.
local function blackfriday_special(el, contents, info, trim_pre, trim_post)
  local btype = el.block_type
  local inline = vim.tbl_contains(HTML5_INLINE, btype)
  local block = vim.tbl_contains(HTML5_BLOCK, btype)
  local fancy = inline or block or btype == "details" or btype == "summary"
  local a = ox.read_attribute("attr_html", el)
  if not fancy then
    if a.class then
      a.class = a.class .. " " .. btype
    else
      a._keys[#a._keys + 1] = "class"
      a.class = btype
    end
  end
  if nw(el.name) and a.id == nil then
    a._keys[#a._keys + 1] = "id"
    a.id = el.name
  end
  local parts = {}
  for _, k in ipairs(a._keys) do
    local v = a[k]
    if v ~= nil then
      if (btype == "details" and k == "open") or v == "t" then
        if truthy(v) then
          parts[#parts + 1] = k
        end
      else
        parts[#parts + 1] = fmt('%s="%s"', k, (encode(v):gsub('"', "&quot;")))
      end
    end
  end
  local attr = #parts > 0 and (" " .. table.concat(parts, " ")) or ""
  contents = trim(contents or "")
  if btype == "details" then
    local div = '<div class="details">'
    local s, e = contents:find("<summary>.-</summary>")
    if s then
      contents = contents:sub(1, e) .. "\n" .. div .. contents:sub(e + 1)
    else
      contents = div .. "\n\n" .. contents
    end
    contents = contents .. "\n</div>"
    return fmt("<%s%s>\n%s\n</%s>", btype, attr, contents, btype)
  elseif btype == "summary" then
    local h = ox.data_with_backend(el.contents or {}, "html", info)
    h = h:gsub("</?p>", ""):gsub("\n\n+", "\n\n")
    return fmt("<%s%s>%s</%s>", btype, attr, trim(h), btype)
  elseif inline then
    return fmt("%s<%s%s>%s</%s>%s", trim_pre, btype, attr, contents, btype, trim_post)
  elseif block then
    return fmt("%s<%s%s>\n\n%s\n\n</%s>%s", trim_pre, btype, attr, contents, btype, trim_post)
  end
  if trim_pre ~= "" or trim_post ~= "" then
    return fmt("%s<span%s>%s</span>%s", trim_pre, attr, contents, trim_post)
  end
  return fmt("%s<div%s>\n\n%s\n\n</div>%s", trim_pre, attr, contents, trim_post)
end

--- The paired shortcode of `btype` in HUGO_PAIRED_SHORTCODES ("%name" for
--- shortcodes with Markdown contents), or nil.
local function paired_shortcode(btype, info)
  local str = info.hugo_paired_shortcodes
  if not nw(str) then
    return nil
  end
  for sc in str:gmatch("%S+") do
    if sc == btype or sc == "%" .. btype then
      return sc
    end
  end
  return nil
end

T["special-block"] = function(el, contents, info)
  local btype = el.block_type
  local tprops = block_type_props(btype)
  local header = {}
  for _, h in ipairs(el.header or {}) do
    for _, kv in ipairs(fm.parse_arguments(h)) do
      header[kv[1]] = kv[2]
    end
  end
  local function pick(key)
    if header[key] ~= nil then
      return header[key]
    end
    return tprops[key]
  end
  local trim_pre = truthy(pick("trim-pre")) and TRIM_PRE or ""
  local last = ox.get_next_element(el, info) == nil
  -- like ox-hugo, the default for trim-post is the type's :trim-pre
  local tp = header["trim-post"]
  if tp == nil then
    tp = tprops["trim-pre"]
  end
  local trim_post = (not last and truthy(tp)) and TRIM_POST or ""
  if #(el.contents or {}) == 0 then
    -- an empty block is left out
    return nil
  end
  if tprops.raw then
    contents = raw_contents(el)
  end
  contents = trim(contents or "")
  local a = ox.read_attribute("attr_html", el)
  if btype == "tikzjax" then
    local s = '<script type="text/tikz">\n  \\begin{tikzpicture}\n' .. contents .. "\n\\end{tikzpicture}\n</script>"
    if nw(a.caption) then
      s = "<figure>\n" .. s .. fmt("\n<figcaption>%s</figcaption>\n</figure>", a.caption)
    end
    return s
  elseif btype == "description" then
    info.description = escape_shortcodes(contents, "md")
    info.hugo_description_block = true
    return nil
  end
  local sc = paired_shortcode(btype, info)
  if sc then
    local raw_attr = el.attr_shortcode
    local args
    if raw_attr then
      local joined = table.concat(raw_attr, " ")
      if joined:match("^%s*:") then
        args = html.attribute_string(ox.read_attribute("attr_shortcode", el))
      else
        args = joined
      end
    end
    args = nw(args) and (" " .. args .. " ") or " "
    local ch_open, ch_close = "<", ">"
    if sc:sub(1, 1) == "%" then
      ch_open, ch_close = "%", "%"
    end
    local open = fmt("%s{{%s %s%s%s}}", trim_pre, ch_open, btype, args, ch_close)
    local close = fmt("{{%s /%s %s}}%s", ch_open, btype, ch_close, trim_post)
    return open .. "\n" .. contents .. "\n" .. close
  end
  return blackfriday_special(el, contents, info, trim_pre, trim_post)
end

---------------------------------------------------------------------------
-- Links
---------------------------------------------------------------------------

local EXTERNAL = { http = true, https = true, ftp = true, mailto = true }

--- The `{{< relref >}}` of a link to another post or Org file.
local function relref(ref)
  return fmt('{{< relref "%s" >}}', ref)
end

--- Attributes of #+attr_html above the paragraph of `link`, when it is
--- the paragraph's first link.
local function link_attrs(link, info)
  local parent = element.parent_element(link)
  if not parent then
    return { _keys = {} }
  end
  local first = element.map(parent, "link", function(l)
    return l
  end, { first_match = true, ignore = info.ignore })
  if first ~= link then
    return { _keys = {} }
  end
  return ox.read_attribute("attr_html", parent)
end

--- Description and anchor of a link resolved in this post's tree.
local function internal_link(el, dest, desc, info)
  if dest.type == "headline" then
    local d = nw(desc)
    if not d then
      if ox.numbered_headline_p(dest, info) then
        local nums = {}
        for i, n in ipairs(ox.get_headline_number(dest, info) or {}) do
          nums[i] = tostring(n)
        end
        d = table.concat(nums, ".")
      else
        d = ox.data(dest.title, info)
      end
    end
    return fmt("[%s](#%s)", d, M.anchor(dest, info))
  end
  local d = nw(desc)
  if not d then
    local number = ox.get_ordinal(dest, info, nil, function(e)
      return ox.get_caption(e) ~= nil
    end)
    if type(number) == "number" then
      d = tostring(number)
    elseif type(number) == "table" then
      local parts = {}
      for i, x in ipairs(number) do
        parts[i] = tostring(x)
      end
      d = table.concat(parts, ".")
    end
    if d and opts().link_desc_insert_type then
      local kind = dest.type == "paragraph" and "Figure" or dest.type == "table" and "Table" or "Code Snippet"
      d = ox.translate(kind, "html", info) .. " " .. d
    end
  end
  if not d then
    return nil
  end
  local ref
  if dest.type == "src-block" or dest.type == "table" then
    ref = named_reference(dest) or ox.get_reference(dest, info)
  elseif dest.type == "paragraph" and html.standalone_image_p(dest, info) then
    ref = named_reference(dest, "figure") or ox.get_reference(dest, info)
  elseif dest.type == "target" then
    ref = target_anchor(dest.value)
  else
    ref = ox.get_reference(dest, info)
  end
  _ = el
  return fmt("[%s](#%s)", d, ref)
end

--- A link to a heading, target or name outside this post, through the
--- index of the whole file the driver builds (`info.hugo_index`).
local function outside_link(el, desc, info)
  local index = info.hugo_index
  if not index then
    return nil
  end
  local t = el.link_type
  local entry
  if t == "custom-id" then
    entry = index.custom_id[el.path]
  elseif t == "id" then
    entry = index.id[el.path]
  else
    local path = el.path
    if path:sub(1, 1) == "*" then
      entry = index.title[vim.trim(path:sub(2))]
    else
      entry = index.target[path] or index.name[path] or index.title[path]
    end
  end
  if not entry or not entry.post then
    return nil
  end
  local ref
  if entry.is_post or not entry.anchor or (t == "fuzzy" and el.path:sub(1, 1) ~= "*" and not entry.headline) then
    ref = entry.post
  else
    ref = entry.post .. "#" .. entry.anchor
  end
  local d = nw(desc) or (entry.headline and entry.title) or nil
  return fmt("[%s](%s)", d or relref(ref), relref(ref))
end

--- Anchor of the place a search option finds in an Org file
--- (org-hugo--search-and-get-anchor): a post's slug, or "#anchor".
local function search_anchor(file, search, info)
  local lines = require("org.utils").readfile(file)
  if not lines then
    error(fmt("Unable to open Org file `%s'", file), 0)
  end
  local index = require("org.extensions.hugo.export").link_index(lines, file, info)
  local entry
  if search:sub(1, 1) == "#" then
    entry = index.custom_id[search:sub(2)]
  elseif search:sub(1, 1) == "*" then
    entry = index.title[vim.trim(search:sub(2))]
  else
    entry = index.target[search] or index.name[search] or index.title[search]
  end
  if not entry or not entry.anchor then
    return ""
  end
  if entry.is_post then
    return entry.anchor
  end
  return "#" .. entry.anchor
end

local function image_link(el, desc, info)
  local parent = el.parent
  local useful = (parent and parent.type == "link") and parent.parent or parent
  local a = useful and ox.read_attribute("attr_html", useful) or { _keys = {} }
  local caption
  local pe = element.parent_element(el)
  local cap = pe and ox.get_caption(pe)
  if cap then
    caption = nw(ox.data(cap, info))
  end
  caption = caption or nw(a.caption)
  if caption then
    local num = ox.get_ordinal(useful, info, nil, function(e)
      return ox.get_caption(e) ~= nil or ox.read_attribute("attr_html", e, "caption") ~= nil
    end)
    caption = fmt(
      '<span class="figure-number">%s %s: </span>%s',
      ox.translate("Figure", "html", info),
      tostring(type(num) == "table" and num[#num] or num or 1),
      caption
    )
  end
  local raw = el.path
  local external = EXTERNAL[el.link_type]
  local path = external and raw or M.attachment(raw, info)
  local source = external and (el.link_type .. ":" .. path) or path
  local standalone = useful and useful.type == "paragraph" and html.standalone_image_p(useful, info)
  local nattrs = 0
  for _, k in ipairs(a._keys) do
    if a[k] ~= nil then
      nattrs = nattrs + 1
    end
  end
  _ = desc
  if not standalone then
    if nattrs == 0 or (a.alt and nattrs == 1) then
      return fmt("![%s](%s)", a.alt or "", source)
    end
    a.target, a.rel = nil, nil
    return html.format_image(source, a, info)
  end
  local params = {
    { "src", source },
    { "alt", a.alt },
    { "caption", caption and caption:gsub('"', '\\"') or nil },
    { "link", a.link },
    { "title", a.title },
    { "class", a.class },
    { "attr", a.attr },
    { "attrlink", a.attrlink },
    { "width", a.width },
    { "height", a.height },
    { "target", a.target },
    { "rel", a.rel },
  }
  local parts = {}
  for _, p in ipairs(params) do
    if p[2] ~= nil then
      parts[#parts + 1] = fmt('%s="%s"', p[1], p[2])
    end
  end
  return "{{< figure " .. table.concat(parts, " ") .. " >}}"
end

T.link = function(el, desc, info)
  local t = el.link_type
  desc = (desc ~= nil and desc ~= "") and desc or nil
  local custom = ox.custom_protocol_maybe(el, desc, "md", info)
  if custom then
    return custom
  end
  if t == "custom-id" or t == "id" or t == "fuzzy" then
    local ok, dest = pcall(t == "fuzzy" and ox.resolve_fuzzy_link or ox.resolve_id_link, el, info)
    if ok and dest and dest.type ~= "plain-text" then
      return internal_link(el, dest, desc, info)
    end
    local out = outside_link(el, desc, info)
    if out then
      return out
    end
    if t == "id" then
      local loc = require("org.extensions.hugo.export").find_id(el.path, info)
      if loc then
        local ref = loc.anchor and (loc.is_post and loc.anchor or (loc.ref .. "#" .. loc.anchor)) or loc.ref
        return fmt("[%s](%s)", desc or relref(ref), relref(ref))
      end
    end
    if ok and dest and dest.type == "plain-text" then
      local p = dest.value:gsub("%.[Oo][Rr][Gg]$", ".md")
      return desc and fmt("[%s](%s)", desc, p) or fmt("<%s>", p)
    end
    error(dest, 0)
  end
  if ox.inline_image_p(el, html.inline_image_rules) then
    return image_link(el, desc, info)
  end
  if t == "info" then
    return M.info_link(el.path, desc)
  end
  if t == "coderef" or t == "radio" then
    if t == "radio" then
      local dest = ox.resolve_radio_link(el, info)
      if not dest then
        return desc
      end
      return fmt("[%s](#%s)", desc or "", REF_PREFIX.radio .. anchor_name(dest.value))
    end
    return md.transcoders.link(el, desc, info)
  end
  local path
  local params = ""
  if EXTERNAL[t] then
    local a = link_attrs(el, info)
    local parts = {}
    for _, k in ipairs({ "title", "style", "referrerpolicy", "media", "target", "rel", "sizes", "type" }) do
      if a[k] ~= nil then
        parts[#parts + 1] = fmt('%s="%s"', k, a[k])
      end
    end
    params = table.concat(parts, " ")
    path = t .. ":" .. html.url_encode(el.path)
  elseif t == "file" then
    local p = el.path:gsub("^file://", "")
    if p:lower():match("%.org$") then
      local ref = vim.fn.fnamemodify(p, ":t:r")
      local anchor = ""
      if nw(el.search_option) then
        local base = info.input_file and vim.fn.fnamemodify(info.input_file, ":p:h") or vim.fn.getcwd()
        anchor = search_anchor(require("org.utils").expand(p, base), el.search_option, info)
      end
      if nw(anchor) and anchor:sub(1, 1) ~= "#" then
        path = relref(anchor)
      elseif nw(ref) or nw(anchor) then
        path = relref(ref .. anchor)
      else
        path = ""
      end
    else
      path = M.attachment(p, info)
    end
  else
    path = el.path
  end
  if desc and desc:match("^{{<%s*figure%s+") and not desc:match("^{{<%s*figure%s+.*link=") then
    return (desc:gsub("%s*>}}$", function(m)
      return fmt(' link="%s"', path) .. m
    end))
  elseif desc and nw(params) then
    return fmt('<a href="%s" %s>%s</a>', encode(path), params, desc)
  elseif desc then
    if not path:match("^{{< relref ") and path:match("%s") then
      path = "<" .. path .. ">"
    end
    return fmt("[%s](%s)", desc, path)
  elseif nw(params) then
    local p = encode(path)
    return fmt('<a href="%s" %s>%s</a>', p, params, (p:gsub(":", "&colon;")))
  elseif path:match("^{{< relref ") then
    return fmt("[%s](%s)", path, path)
  elseif nw(path) then
    return "<" .. path .. ">"
  end
  return ""
end

--- Emacs manuals on gnu.org (org-info-emacs-documents).
local EMACS_MANUALS = {}
for _, m in ipairs({
  "ada-mode",
  "auth",
  "autotype",
  "bovine",
  "calc",
  "ccmode",
  "cl",
  "dbus",
  "dired-x",
  "ebrowse",
  "ede",
  "ediff",
  "edt",
  "efaq",
  "efaq-w32",
  "eglot",
  "eieio",
  "eintr",
  "elisp",
  "emacs",
  "emacs-gnutls",
  "emacs-mime",
  "epa",
  "erc",
  "ert",
  "eshell",
  "eudc",
  "eww",
  "flymake",
  "forms",
  "gnus",
  "htmlfontify",
  "idlwave",
  "ido",
  "info",
  "mairix-el",
  "message",
  "mh-e",
  "modus-themes",
  "newsticker",
  "nxml-mode",
  "octave-mode",
  "org",
  "pcl-cvs",
  "pgg",
  "rcirc",
  "reftex",
  "remember",
  "sasl",
  "sc",
  "semantic",
  "ses",
  "sieve",
  "smtpmail",
  "speedbar",
  "srecode",
  "todo-mode",
  "tramp",
  "transient",
  "url",
  "use-package",
  "vhdl-mode",
  "vip",
  "viper",
  "vtable",
  "widget",
  "wisent",
  "woman",
}) do
  EMACS_MANUALS[m] = true
end

--- GNU software with manuals on gnu.org (org-hugo-info-gnu-software).
local GNU_SOFTWARE = {}
for name in
  ([[
3dldf 8sync a2ps acct acm adns alive anubis apl archimedes aris artanis aspell auctex autoconf
autoconf-archive autogen automake avl ballandpaddle barcode bash bayonne bazaar bc behistun bfd
binutils bison bool bpel2owfn c-graph ccaudio ccd2cue ccide ccrtp ccscript cflow cgicc chess cim
classpath classpathx clisp combine commoncpp complexity config consensus coreutils cpio cppi
cssc cursynth dap datamash dc ddd ddrescue dejagnu denemo dia dico diction diffutils direvent
djgpp dominion dr-geo easejs ed edma electric emacs emacs-muse emms enscript epsilon fdisk
ferret findutils fisicalab foliot fontopia fontutils freedink freefont freeipmi freetalk fribidi
g-golf gama garpd gawk gcal gcc gcide gcl gcompris gdb gdbm gengen gengetopt gettext gforth
ggradebook ghostscript gift gimp glean global glpk glue gmediaserver gmp gnash gnat gnats
gnatsweb gnowsys gnu-c-manual gnu-crypto gnu-pw-mgr gnuae gnuastro gnubatch gnubg gnubiff gnubik
gnucap gnucash gnucobol gnucomm gnudos gnufm gnugo gnuit gnujdoc gnujump gnukart gnulib gnumach
gnumed gnumeric gnump3d gnun gnunet gnupg gnupod gnuprologjava gnuradio gnurobots gnuschool
gnushogi gnusound gnuspeech gnuspool gnustandards gnustep gnutls gnutrition gnuzilla goptical
gorm gpaint gperf gprolog grabcomics greg grep gretl groff grub gsasl gsegrafix gsl gslip gsrc
gss gtick gtypist guile guile-cv guile-dbi guile-gnome guile-ncurses guile-opengl guile-rpc
guile-sdl guix gurgle gv gvpe gwl gxmessage gzip halifax health hello help2man hp2xx html-info
httptunnel hurd hyperbole icecat idutils ignuit indent inetutils inklingreader intlfonts jacal
jami java-getopt jel jitter jtw jwhois kawa kopi leg less libc libcdio libdbh liberty-eiffel
libextractor libffcall libgcrypt libiconv libidn libjit libmatheval libmicrohttpd libredwg
librejs libsigsegv libtasn1 libtool libunistring libxmi lightning lilypond lims linux-libre
liquidwar6 lispintro lrzsz lsh m4 macchanger mailman mailutils make marst maverik mc mcron mcsim
mdk mediagoblin melting mempool mes metaexchange metahtml metalogic-inference mifluz mig
miscfiles mit-scheme moe motti mpc mpfr mpria mtools nana nano nano-archimedes ncurses nettle
network ocrad octave oleo oo-browser orgadoc osip panorama parallel parted pascal patch paxutils
pcb pem pexec pies pipo plotutils poke polyxmass powerguru proxyknife pspp psychosynth pth
pythonwebkit qexo quickthreads r radius rcs readline recutils reftex remotecontrol rottlog rpge
rush sather scm screen sed serveez sharutils shepherd shishi shmm shtool sipwitch slib smalltalk
social solfege spacechart spell sqltutor src-highlite ssw stalkerfs stow stump superopt swbis
sysutils taler talkfilters tar termcap termutils teseq teximpatient texinfo texmacs time tramp
trans-coord trueprint unifont units unrtf userv uucp vc-dwim vcdimager vera vmgen wb wdiff
websocket4j webstump wget which womb xaos xboard xlogmaster xmlat xnee xorriso zile
]]):gmatch("%S+")
do
  GNU_SOFTWARE[name] = true
end

--- An `info:` link as a link to the manual on the web
--- (org-hugo--org-info-export): Org's on orgmode.org, Emacs' on gnu.org.
---@param path string
---@param desc string|nil
---@return string
function M.info_link(path, desc)
  local manual, node = path:match("^([^#:]*)[#:]:?(.*)$")
  manual = manual or path
  node = (node and node ~= "") and node or "Top"
  local title = fmt('Emacs Lisp: (info \\"(%s) %s\\")', manual, node)
  if not desc then
    local cap = manual:sub(1, 1):upper() .. manual:sub(2):lower()
    desc = node == "Top" and (cap .. " Info") or fmt("%s Info: %s", cap, node)
  end
  local function node_url()
    if node == "Top" then
      return "index.html"
    end
    local parts = {}
    for _, c in ipairs(vim.fn.split((node:gsub("[ \t\n\r]+", " ")), "\\zs")) do
      if c == " " then
        parts[#parts + 1] = "-"
      elseif c:match("^[%w]$") then
        parts[#parts + 1] = c
      else
        parts[#parts + 1] = fmt("_%04x", vim.fn.char2nr(c))
      end
    end
    local n = table.concat(parts)
    if n:match("^%d") then
      n = "g_t" .. n
    end
    return n .. ".html"
  end
  local link
  if manual:lower() == "org" then
    link = "https://orgmode.org/manual/" .. node_url()
  elseif EMACS_MANUALS[manual] then
    link = fmt("https://www.gnu.org/software/emacs/manual/html_node/%s/%s", manual, node_url())
  elseif GNU_SOFTWARE[manual] then
    link = fmt("https://www.gnu.org/software/%s/manual/html_node/%s", manual, node_url())
  else
    link = manual .. ".html"
  end
  return fmt('[%s](%s "%s")', desc, link, title)
end

---------------------------------------------------------------------------
-- Attachments
---------------------------------------------------------------------------

local function realpath(p)
  return vim.uv.fs_realpath(p) or vim.fs.normalize(p)
end

local function copy_if_newer(src, dest)
  local s = vim.uv.fs_stat(src)
  local d = vim.uv.fs_stat(dest)
  if d and s and d.mtime.sec >= s.mtime.sec then
    return
  end
  vim.fn.mkdir(vim.fn.fnamemodify(dest, ":h"), "p")
  local ok, err = vim.uv.fs_copyfile(src, dest)
  if not ok then
    error(fmt("Cannot copy %s to %s: %s", src, dest, tostring(err)), 0)
  end
end

--- Copy a linked local file to the site and return its path there
--- (org-hugo--attachment-rewrite-maybe): files already under `static/`
--- or the bundle keep their path; a path with `/static/` in it goes to
--- the same place under the site's static dir; in a page bundle files
--- go into the bundle; others go to `static/<static_subdir>/`. Files
--- whose extension is not in `copy_extensions`, or that do not exist,
--- keep their path.
---@param path string
---@param info table
---@return string
function M.attachment(path, info)
  local base = info.hugo_base_dir_abs
  if not base then
    return path
  end
  local src_dir = info.input_file and vim.fn.fnamemodify(info.input_file, ":p:h") or vim.fn.getcwd()
  local unhex = path:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end)
  local file = require("org.utils").expand(unhex, src_dir)
  local ext = vim.fn.fnamemodify(unhex, ":e"):lower()
  local allowed = false
  for _, e in ipairs(opts().copy_extensions or {}) do
    if e:lower() == ext then
      allowed = true
    end
  end
  local static = base .. "/static"
  local bundle = info.hugo_bundle_dir
  local dest_dir = bundle or static
  if vim.fn.isdirectory(static) == 0 then
    error(fmt("Please create the %s directory", static), 0)
  end
  if not (allowed and vim.uv.fs_stat(file) and vim.fn.isdirectory(dest_dir) == 1) then
    return path
  end
  local real = realpath(file)
  local real_dest = realpath(dest_dir)
  if real:sub(1, #real_dest + 1) == real_dest .. "/" then
    return "/" .. real:sub(#real_dest + 2)
  end
  local rel
  local s = real:find("/static/", 1, true)
  if s then
    dest_dir = static
    rel = real:sub(s + 8)
  elseif bundle then
    local name = vim.fn.fnamemodify(bundle, ":t")
    local content = realpath(base .. "/" .. (info.hugo_content_folder or "content"))
    if realpath(bundle) == content then
      name = "_home"
    end
    local b = real:find("/" .. name .. "/", 1, true)
    local srcd = realpath(src_dir) .. "/"
    if b then
      rel = real:sub(b + #name + 2)
    elseif real:sub(1, #srcd) == srcd then
      rel = real:sub(#srcd + 1)
    else
      rel = vim.fn.fnamemodify(unhex, ":t")
    end
  else
    rel = (opts().static_subdir or "ox-hugo") .. "/" .. vim.fn.fnamemodify(unhex, ":t")
  end
  copy_if_newer(real, dest_dir .. "/" .. rel)
  if bundle and dest_dir == bundle then
    return rel
  end
  return "/" .. rel
end

---------------------------------------------------------------------------
-- Templates
---------------------------------------------------------------------------

--- Table of contents (org-hugo--build-toc).
function M.build_toc(info, n, scope, localp)
  local current
  local items = {}
  for _, h in ipairs(ox.collect_headlines(info, n, scope)) do
    local raw = ox.get_relative_level(h, info)
    local level = raw
    if scope then
      current = current or raw
      level = raw - current + 1
    end
    local indent = string.rep(" ", 4 * (level - 1))
    local todo = info.with_todo_keywords and h.todo_keyword
    local todo_s = todo and (todo_html(todo, info) .. " ") or ""
    local number = heading_number(h, info, true) or ""
    local entry = fmt(
      "[%s%s](#%s)",
      todo_s,
      ox.data_with_backend(ox.get_alt_title(h), ox.toc_entry_backend("hugo"), info),
      M.anchor(h, info)
    )
    local tags = ""
    if info.with_tags and info.with_tags ~= "not-in-toc" then
      local tl = ox.get_tags(h, info)
      if #tl > 0 then
        tags = ":" .. table.concat(tl, ":") .. ":"
      end
    end
    items[#items + 1] = indent .. "- " .. number .. entry .. tags
  end
  if #items == 0 then
    return nil
  end
  local list = table.concat(items, "\n")
  local classes = { "ox-hugo-toc", "toc" }
  if list:match('^%s*%- <span class="section%-num"') or list:match('\n%s*%- <span class="section%-num"') then
    classes[#classes + 1] = "has-section-numbers"
  end
  if localp then
    classes[#classes + 1] = "local"
  end
  local heading = localp and ""
    or fmt('\n<div class="heading">%s</div>\n', ox.translate("Table of Contents", "html", info))
  return fmt('<div class="%s">\n%s\n%s\n\n</div>\n<!--endtoc-->\n', table.concat(classes, " "), heading, list)
end

--- Footnote definitions (org-blackfriday-footnote-section, Goldmark).
local function footnote_section(info)
  local defs = ox.collect_footnote_definitions(info)
  if #defs == 0 then
    return ""
  end
  local out = {}
  for _, d in ipairs(defs) do
    local def = trim(ox.data(d[3], info)):gsub("\n", "\n    ")
    out[#out + 1] = fmt("[^fn:%d]: %s", d[1], def)
  end
  return table.concat(out, "\n")
end

T.inner_template = function(contents, info)
  local level = info.with_toc
  if level and type(level) ~= "number" then
    level = info.headline_levels
  end
  local toc = ""
  if type(level) == "number" and level > 0 then
    toc = (M.build_toc(info, level) or "") .. "\n"
  end
  local c = contents or ""
  -- special blocks inside quote blocks
  local n
  repeat
    c, n = c:gsub("\n%s*>%s?" .. vim.pesc(TRIM_PRE), TRIM_PRE)
  until n == 0
  c = c:gsub("[%s]*" .. vim.pesc(TRIM_PRE), "\n")
  c = c:gsub(vim.pesc(TRIM_POST) .. "[%s>]+([^-#`])", " %1")
  c = c:gsub(vim.pesc(TRIM_POST), "")
  local s = toc .. c .. "\n" .. footnote_section(info)
  return (s:gsub("^%s+", ""))
end

T.template = function(contents)
  return contents
end

---------------------------------------------------------------------------
-- Filters
---------------------------------------------------------------------------

--- The options of a subtree post that it inherits from its parents (and
--- the post's own, with `PROP+` values joined), which the generic
--- environment does not see: `info.hugo_ctx.props` from the driver.
local function inherit_options(info)
  local ctx = info.hugo_ctx
  if not (ctx and ctx.props) then
    return info
  end
  local options = vim.list_extend(vim.deepcopy(ox.all_options(M.backend)), ox.global_options())
  local inherited_options = ctx.props.EXPORT_OPTIONS
  if inherited_options then
    local parsed = ox.parse_option_line(inherited_options)
    for _, o in ipairs(options) do
      if o[3] and parsed[o[3]] ~= nil then
        info[o[1]] = parsed[o[3]]
      end
    end
  end
  local seen = {}
  for _, o in ipairs(options) do
    local key = o[2]
    if key and not seen[o[1]] and o[5] ~= "parse" then
      seen[o[1]] = true
      local v = ctx.props["EXPORT_" .. key]
      if v ~= nil then
        if o[5] == "split" then
          v = vim.split(v, "%s+", { trimempty = true })
        end
        info[o[1]] = v
      end
    end
  end
  return info
end

--- Resolve the post's directories (org-hugo--get-pub-dir): it is an
--- error not to have a base dir.
local function directories(info)
  local ctx = info.hugo_ctx or {}
  local base = nw(info.hugo_base_dir)
  if not base and ctx.to_buffer then
    return info
  end
  if not base then
    error("It is mandatory to set the HUGO_BASE_DIR property or the `extensions.hugo.base_dir' option", 0)
  end
  local src_dir = info.input_file and vim.fn.fnamemodify(info.input_file, ":p:h") or vim.fn.getcwd()
  base = require("org.utils").expand(base, src_dir):gsub("/+$", "")
  info.hugo_base_dir_abs = base
  info.hugo_content_folder = nw(info.hugo_content_folder) or opts().content_folder or "content"
  local section = info.hugo_section
  if type(section) ~= "string" then
    error("It is mandatory to set the HUGO_SECTION property", 0)
  end
  -- an empty section (or "/") is the content directory itself
  section = vim.trim(section):gsub("^/+", ""):gsub("/+$", "")
  if ctx.section_frag then
    section = section .. "/" .. ctx.section_frag:gsub("^/+", ""):gsub("/+$", "")
  end
  local bundle = ctx.bundle or nw(info.hugo_bundle)
  local dir = base .. "/" .. info.hugo_content_folder .. (section ~= "" and ("/" .. section) or "")
  if bundle then
    dir = dir .. "/" .. bundle:gsub("/+$", "")
    info.hugo_bundle_dir = dir
  end
  info.hugo_pub_dir = dir
  info.hugo_section_path = section
  if not ctx.to_buffer then
    -- like ox-hugo, the post's directory exists before the body is written
    -- (files linked from it are copied into a bundle)
    vim.fn.mkdir(dir, "p")
  end
  return info
end

local function options_filter(info)
  info = inherit_options(info)
  info.hugo_index = info.hugo_ctx and info.hugo_ctx.index or nil
  return directories(info)
end

--- Copy the files of HUGO_RESOURCES `:src` into the bundle
--- (org-hugo--copy-resources-maybe).
local function copy_resources(info)
  local bundle = info.hugo_bundle_dir
  if not bundle or not nw(info.hugo_resources) then
    return
  end
  local src_dir = info.input_file and vim.fn.fnamemodify(info.input_file, ":p:h") or vim.fn.getcwd()
  for _, kv in ipairs(fm.parse_arguments(info.hugo_resources)) do
    if kv[1] == "src" and type(kv[2]) == "string" then
      for _, f in ipairs(vim.fn.glob(src_dir .. "/" .. kv[2], false, true)) do
        local ext = vim.fn.fnamemodify(f, ":e"):lower()
        if vim.tbl_contains(opts().copy_extensions or {}, ext) then
          local rel = f:sub(#src_dir + 2)
          copy_if_newer(f, bundle .. "/" .. rel)
        end
      end
    end
  end
end

local function body_filter(body, _, info)
  copy_resources(info)
  if truthy(info.hugo_delete_trailing_ws) and not info.preserve_breaks then
    body = body:gsub("[ \t]+\n", "\n"):gsub("[ \t]+$", ""):gsub("\n+$", "\n")
  end
  local front = require("org.extensions.hugo.export").front_matter(info)
  local extra = info.hugo_fm_extra
  if nw(extra) then
    front = front:gsub("(%+%+%+\n*)$", function(m)
      return extra .. m
    end, 1)
    if not front:find(vim.pesc(extra), 1, true) then
      front = front:gsub("(%-%-%-\n*)$", function(m)
        return extra .. m
      end, 1)
    end
  end
  local footer = opts().footer or ""
  body = nw(body) and ("\n" .. body:gsub("\n+$", "") .. "\n") or ""
  return front .. body .. footer
end

M.transcoders = T

M.backend = ox.define_backend("hugo", {
  parent = "md",
  transcoders = T,
  options = function()
    local o = opts()
    return {
      { "with_toc", nil, "toc", o.with_toc },
      { "section_numbers", nil, "num", o.with_section_numbers },
      { "author", "AUTHOR", nil, ox.user_full_name(), "newline" },
      { "creator", "CREATOR", nil, ox.creator_string() .. " + hugo" },
      { "with_smart_quotes", nil, "'", false },
      { "with_special_strings", nil, "-", false },
      { "with_sub_superscript", nil, "^", "{}" },
      { "hugo_with_locale", "HUGO_WITH_LOCALE", nil, nil },
      { "hugo_front_matter_format", "HUGO_FRONT_MATTER_FORMAT", nil, o.front_matter_format or "toml" },
      { "hugo_level_offset", "HUGO_LEVEL_OFFSET", nil, "1" },
      { "hugo_preserve_filling", "HUGO_PRESERVE_FILLING", nil, o.preserve_filling },
      { "hugo_delete_trailing_ws", "HUGO_DELETE_TRAILING_WS", nil, o.delete_trailing_ws },
      { "hugo_section", "HUGO_SECTION", nil, o.section },
      { "hugo_bundle", "HUGO_BUNDLE", nil, nil },
      { "hugo_base_dir", "HUGO_BASE_DIR", nil, o.base_dir },
      { "hugo_content_folder", "HUGO_BASE_CONTENT_FOLDER", nil, o.content_folder },
      { "hugo_code_fence", "HUGO_CODE_FENCE", nil, true },
      { "hugo_use_code_for_kbd", "HUGO_USE_CODE_FOR_KBD", nil, o.use_code_for_kbd },
      { "hugo_prefer_hyphen_in_tags", "HUGO_PREFER_HYPHEN_IN_TAGS", nil, o.prefer_hyphen_in_tags },
      { "hugo_allow_spaces_in_tags", "HUGO_ALLOW_SPACES_IN_TAGS", nil, o.allow_spaces_in_tags },
      { "hugo_auto_set_lastmod", "HUGO_AUTO_SET_LASTMOD", nil, o.auto_set_lastmod },
      { "hugo_custom_front_matter", "HUGO_CUSTOM_FRONT_MATTER", nil, nil, "space" },
      { "hugo_front_matter_key_replace", "HUGO_FRONT_MATTER_KEY_REPLACE", nil, nil, "space" },
      { "hugo_date_format", "HUGO_DATE_FORMAT", nil, o.date_format },
      { "hugo_paired_shortcodes", "HUGO_PAIRED_SHORTCODES", nil, o.paired_shortcodes, "space" },
      { "html_container", "HTML_CONTAINER", nil, o.container_element },
      { "html_container_class", "HTML_CONTAINER_CLASS", nil, "" },
      { "html_container_nested", "HTML_CONTAINER_NESTED", nil, nil },
      -- front matter
      { "hugo_aliases", "HUGO_ALIASES", nil, nil, "space" },
      { "hugo_audio", "HUGO_AUDIO", nil, nil },
      { "date", "DATE", nil, nil },
      { "description", "DESCRIPTION", nil, nil },
      { "hugo_draft", "HUGO_DRAFT", nil, nil },
      { "hugo_expirydate", "HUGO_EXPIRYDATE", nil, nil },
      { "hugo_headless", "HUGO_HEADLESS", nil, nil },
      { "hugo_images", "HUGO_IMAGES", nil, nil, "newline" },
      { "hugo_iscjklanguage", "HUGO_ISCJKLANGUAGE", nil, nil },
      { "hugo_keywords", "KEYWORDS", nil, nil, "newline" },
      { "hugo_layout", "HUGO_LAYOUT", nil, nil },
      { "hugo_lastmod", "HUGO_LASTMOD", nil, nil },
      { "hugo_linktitle", "HUGO_LINKTITLE", nil, nil },
      { "hugo_locale", "HUGO_LOCALE", nil, nil },
      { "hugo_markup", "HUGO_MARKUP", nil, nil },
      { "hugo_menu", "HUGO_MENU", nil, nil, "space" },
      { "hugo_menu_override", "HUGO_MENU_OVERRIDE", nil, nil, "space" },
      { "hugo_outputs", "HUGO_OUTPUTS", nil, nil, "space" },
      { "hugo_publishdate", "HUGO_PUBLISHDATE", nil, nil },
      { "hugo_series", "HUGO_SERIES", nil, nil, "newline" },
      { "hugo_slug", "HUGO_SLUG", nil, nil },
      { "hugo_tags", "HUGO_TAGS", nil, nil, "newline" },
      { "hugo_categories", "HUGO_CATEGORIES", nil, nil, "newline" },
      { "hugo_resources", "HUGO_RESOURCES", nil, nil, "space" },
      { "hugo_type", "HUGO_TYPE", nil, nil },
      { "hugo_url", "HUGO_URL", nil, nil },
      { "hugo_videos", "HUGO_VIDEOS", nil, nil, "newline" },
      { "hugo_weight", "HUGO_WEIGHT", nil, nil, "space" },
    }
  end,
  filters = {
    options = { options_filter },
    body = { body_filter },
  },
})

return M

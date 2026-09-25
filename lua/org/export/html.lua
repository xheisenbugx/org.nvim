---@mod org.export.html HTML back-end (port of Emacs ox-html.el)

local ox = require("org.export.ox")
local element = require("org.export.element")
local entities = require("org.export.entities")
local data = require("org.export.html_data")

local M = {}

M.extension = "html"

local function hcfg()
  return (require("org.config").opts.export or {}).html or {}
end

local function opt(name, default)
  local v = hcfg()[name]
  if v == nil then
    return default
  end
  return v
end

local nw = ox.nw
local trim = ox.trim
local fmt = string.format

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- org-html-encode-plain-text
local function encode(s)
  return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end
M.encode_plain_text = encode
M.escape = function(s)
  return (encode(s):gsub('"', "&quot;"))
end

local function xhtml_p(info)
  return (info.html_doctype or ""):lower():find("xhtml", 1, true) ~= nil
end
M.xhtml_p = xhtml_p

local function html5_p(info)
  local dt = (info.html_doctype or ""):lower()
  return dt == "html5" or dt == "xhtml5" or dt == "<!doctype html>"
end
M.html5_p = html5_p

local function html5_fancy_p(info)
  return info.html_html5_fancy and html5_p(info)
end

local function close_tag(tag, attr, info)
  return "<" .. tag .. ((attr and nw(" " .. attr)) and (" " .. attr) or "") .. (xhtml_p(info) and " />" or ">")
end
M.close_tag = close_tag

--- Attribute string from an ordered attribute table (read_attribute).
local function attribute_string(attrs)
  local out = {}
  for _, k in ipairs(attrs._keys or {}) do
    local v = attrs[k]
    if v ~= nil then
      out[#out + 1] = fmt('%s="%s"', k, (encode(v):gsub('"', "&quot;")))
    end
  end
  return table.concat(out, " ")
end
M.attribute_string = attribute_string

local function set_attr(attrs, key, value)
  if attrs[key] == nil and not vim.tbl_contains(attrs._keys, key) then
    attrs._keys[#attrs._keys + 1] = key
  end
  attrs[key] = value
  return attrs
end

local function has_attr(attrs, key)
  return vim.tbl_contains(attrs._keys, key)
end

--- org-html--reference
function M.reference(datum, info, named_only)
  local t = datum.type
  local custom = (t == "headline" or t == "inlinetask") and datum.props and datum.props.CUSTOM_ID
  local user = custom
    or ((t == "radio-target" or t == "target") and datum.value)
    or datum.name
    or (datum.props and datum.props.ID and ("ID-" .. datum.props.ID))
  if user and (info.html_prefer_user_labels or custom) then
    return user
  end
  if named_only and not (t == "headline" or t == "inlinetask" or t == "radio-target" or t == "target") and not user then
    return nil
  end
  return ox.get_reference(datum, info)
end

local function translate(s, info)
  return ox.translate(s, "html", info)
end

local function fix_class_name(k)
  return (k:gsub("[^a-zA-Z0-9_]", "_"))
end

local function anchor(id, desc, attributes, info)
  local name = info.html_allow_name_attribute_in_anchors and id
  local a = (id and fmt(' id="%s"', id) or "") .. (name and fmt(' name="%s"', name) or "") .. (attributes or "")
  return fmt("<a%s>%s</a>", a, desc or "")
end

local function todo_html(todo, info)
  if not todo then
    return nil
  end
  local done = info.todo_done and info.todo_done(todo)
  return fmt(
    '<span class="%s %s%s">%s</span>',
    done and "done" or "todo",
    info.html_todo_kwd_class_prefix or "",
    fix_class_name(todo),
    todo
  )
end

local function priority_html(priority)
  return priority and fmt('<span class="priority">[%s]</span>', priority) or nil
end

local function tags_html(tags, info)
  if not tags or #tags == 0 then
    return nil
  end
  local parts = {}
  for _, t in ipairs(tags) do
    parts[#parts + 1] = fmt('<span class="%s">%s</span>', (info.html_tag_class_prefix or "") .. fix_class_name(t), t)
  end
  return fmt('<span class="tag">%s</span>', table.concat(parts, "&nbsp;"))
end

--- org-html-format-headline-default-function
function M.format_headline(todo, _todo_type, priority, text, tags, info)
  local t = todo_html(todo, info)
  local p = priority_html(priority)
  local g = tags_html(tags, info)
  return (t and (t .. " ") or "") .. (p and (p .. " ") or "") .. (text or "") .. (g and "&nbsp;&nbsp;&nbsp" or "") .. (g or "")
end

local function format_headline(info, ...)
  local f = hcfg().format_headline_function
  if type(f) == "function" then
    return f(...)
  end
  return M.format_headline(...)
end

local function format_timestamp(ts, info)
  local fancy = html5_fancy_p(info)
  local tag = fancy and "time" or "span"
  local attrs = 'class="timestamp"'
  if fancy then
    local f = ox.timestamp_has_time_p(ts) and "%FT%T" or "%F"
    attrs = attrs .. fmt(' datetime="%s"', ox.format_timestamp(ts, f))
  end
  local s = fmt("<%s %s>%s</%s>", tag, attrs, M.plain_text(ox.timestamp_translate(ts), info), tag)
  return (s:gsub("%-%-", "&ndash;"))
end
M.format_timestamp = format_timestamp

--- Checkbox markup (org-html-checkbox-types).
local CHECKBOXES = {
  unicode = { on = "&#x2611;", off = "&#x2610;", trans = "&#x2610;" },
  ascii = { on = "<code>[X]</code>", off = "<code>[&nbsp;]</code>", trans = "<code>[-]</code>" },
  html = {
    on = "<input type='checkbox' checked='checked' />",
    off = "<input type='checkbox' />",
    trans = "<input type='checkbox' />",
  },
}

---------------------------------------------------------------------------
-- Code
---------------------------------------------------------------------------

local function fontify(code, lang)
  local hl = hcfg().fontify
  if lang and type(hl) == "function" then
    local ok, r = pcall(hl, code, lang)
    if ok and r then
      return r
    end
  end
  return encode(code)
end

function M.do_format_code(code, lang, refs, retain_labels, num_start, wrap_lines)
  local lines = vim.split(code, "\n", { plain = true })
  local num_fmt = num_start and ("%" .. #tostring(#lines + num_start) .. "d: ") or nil
  code = fontify(code, lang)
  return ox.format_code(code, function(loc, num, ref)
    local s = (num_start and fmt('<span class="linenr">%s</span>', fmt(num_fmt, num)) or "")
      .. (wrap_lines and fmt("<code%s>%s</code>", num_start and fmt(' data-ox-html-linenr="%s"', num) or "", loc) or loc)
      .. ((ref and retain_labels) and fmt(" (%s)", ref) or "")
    if ref then
      return fmt('<span id="coderef-%s" class="coderef-off">%s</span>', ref, s)
    end
    return s
  end, num_start, refs)
end

function M.format_code_of(el, info)
  local code, refs = ox.unravel_code(el)
  return M.do_format_code(code, el.language, refs, el.retain_labels, ox.get_loc(el, info), info.html_wrap_src_lines)
end

local function textarea_block(el)
  local code = ox.unravel_code(el)
  local attr = ox.read_attribute("attr_html", el)
  local _, count = code:gsub("\n", "")
  return fmt(
    '<p>\n<textarea cols="%s" rows="%s">\n%s</textarea>\n</p>',
    attr.width or 80,
    attr.height or (count + 1),
    code
  )
end

---------------------------------------------------------------------------
-- TOC and lists of tables/listings
---------------------------------------------------------------------------

local function toc_text(entries, scope)
  local prev = scope and (entries[1][2] - 1) or 0
  local start = prev
  local out = {}
  for _, e in ipairs(entries) do
    local level = e[2]
    local cnt = level - prev
    local times = cnt > 0 and (cnt - 1) or -cnt
    prev = level
    local s = ""
    for _ = 1, times do
      s = s .. (cnt > 0 and "\n<ul>\n<li>" or "</li>\n</ul>\n")
    end
    s = s .. (cnt > 0 and "\n<ul>\n<li>" or "</li>\n<li>")
    out[#out + 1] = s .. e[1]
  end
  local tail = ""
  for _ = 1, prev - start do
    tail = tail .. "</li>\n</ul>\n"
  end
  return table.concat(out) .. tail
end

local function format_toc_headline(h, info)
  local num = ox.get_headline_number(h, info)
  local todo = info.with_todo_keywords and h.todo_keyword and ox.data(h.todo_keyword, info) or nil
  local todo_type = todo and h.todo_type
  local priority = info.with_priority and h.priority or nil
  local text = ox.data_with_backend(ox.get_alt_title(h), ox.toc_entry_backend("html"), info)
  local tags = info.with_tags == true and ox.get_tags(h, info) or nil
  local prefix = ""
  if not ox.low_level_p(h, info) and ox.numbered_headline_p(h, info) and num then
    local parts = {}
    for i, n in ipairs(num) do
      parts[i] = tostring(n)
    end
    prefix = table.concat(parts, ".") .. ". "
  end
  return fmt('<a href="#%s">%s</a>', M.reference(h, info), prefix .. format_headline(info, todo, todo_type, priority, text, tags, info))
end

function M.toc(depth, info, scope)
  local headlines = ox.collect_headlines(info, depth, scope)
  if #headlines == 0 then
    return nil
  end
  local entries = {}
  for _, h in ipairs(headlines) do
    entries[#entries + 1] = { format_toc_headline(h, info), ox.get_relative_level(h, info) }
  end
  local counter = info.html_toc_counter
  local suffix = counter and ("-" .. counter) or ""
  local toc = fmt('<div id="text-table-of-contents%s" role="doc-toc">', suffix) .. toc_text(entries, scope) .. "</div>\n"
  info.html_toc_counter = (counter or 0) + 1
  if scope then
    return toc
  end
  local outer = html5_fancy_p(info) and "nav" or "div"
  local top = info.html_toplevel_hlevel
  return fmt('<%s id="table-of-contents%s" role="doc-toc">\n', outer, suffix)
    .. fmt("<h%d>%s</h%d>\n", top, translate("Table of Contents", info), top)
    .. toc
    .. fmt("</%s>\n", outer)
end

local function has_caption(el)
  return el.caption ~= nil
end

local function list_of(kind, info)
  local entries, id, title, numfmt, cls
  if kind == "tables" then
    entries = ox.collect_tables(info)
    id, title, numfmt, cls = "list-of-tables", "List of Tables", "Table %d:", "table-number"
  else
    entries = ox.collect_listings(info)
    id, title, numfmt, cls = "list-of-listings", "List of Listings", "Listing %d:", "listing-number"
  end
  if #entries == 0 then
    return nil
  end
  local top = info.html_toplevel_hlevel
  local items = {}
  local count = 0
  local initial = fmt('<span class="%s">%s</span>', cls, translate(numfmt, info))
  for _, e in ipairs(entries) do
    local label = M.reference(e, info, true)
    local t = trim(ox.data(ox.get_caption(e, true) or ox.get_caption(e), info))
    count = count + 1
    local num = initial:gsub("%%d", tostring(count))
    if not label then
      items[#items + 1] = "<li>" .. num .. " " .. t .. "</li>"
    else
      items[#items + 1] = "<li>" .. fmt('<a href="#%s">%s %s</a>', label, num, t) .. "</li>"
    end
  end
  return fmt('<div id="%s">\n', id)
    .. fmt("<h%d>%s</h%d>\n", top, translate(title, info), top)
    .. fmt('<div id="text-%s">\n<ul>\n', id)
    .. table.concat(items, "\n")
    .. "\n</ul>\n</div>\n</div>"
end

---------------------------------------------------------------------------
-- Footnotes
---------------------------------------------------------------------------

function M.footnote_section(info)
  local defs = ox.collect_footnote_definitions(info)
  if #defs == 0 then
    return nil
  end
  local parts = {}
  for _, d in ipairs(defs) do
    local n, label, def = d[1], d[2], d[3]
    if label and tostring(tonumber(label)) == label then
      label = nil
    end
    local inline = true
    for _, x in ipairs(def) do
      if element.ELEMENTS[x.type] then
        inline = false
      end
    end
    local a = anchor(
      "fn." .. (label or n),
      tostring(n),
      fmt(' class="footnum" href="#fnr.%s" role="doc-backlink"', label or n),
      info
    )
    local contents = trim(ox.data(def, info))
    parts[#parts + 1] = fmt(
      '<div class="footdef">%s %s</div>\n',
      fmt(info.html_footnote_format, a),
      fmt(
        '<div class="footpara" role="doc-footnote">%s</div>',
        inline and fmt('<p class="footpara">%s</p>', contents) or contents
      )
    )
  end
  local section = info.html_footnotes_section
  local body = "\n" .. table.concat(parts, "\n") .. "\n"
  local title = translate("Footnotes", info)
  local i = 0
  return (section:gsub("%%s", function()
    i = i + 1
    return i == 1 and title or body
  end))
end

---------------------------------------------------------------------------
-- Template
---------------------------------------------------------------------------

local function build_meta_entry(label, identity, content)
  local s = "<meta " .. fmt('%s="%s', label, identity)
  if content then
    s = s .. '" content="' .. (encode(content):gsub('"', "&quot;"))
  end
  return s .. '" />\n'
end

local function build_meta_info(info)
  local title = M.plain_text(element.interpret(info.title or {}), info)
  if not nw(title) then
    title = "&lrm;"
  end
  local charset = info.html_coding_system or "utf-8"
  local out = {}
  if info.time_stamp_file then
    out[#out + 1] = ox.format_time("<!-- " .. info.html_metadata_timestamp_format .. " -->\n")
  end
  if html5_p(info) then
    out[#out + 1] = build_meta_entry("charset", charset)
  else
    out[#out + 1] = build_meta_entry("http-equiv", "Content-Type", "text/html;charset=" .. charset)
  end
  local vp = {}
  for _, cell in ipairs(info.html_viewport or {}) do
    if nw(cell[2]) then
      vp[#vp + 1] = cell[1] .. "=" .. cell[2]
    end
  end
  if #vp > 0 then
    out[#out + 1] = build_meta_entry("name", "viewport", table.concat(vp, ", "))
  end
  out[#out + 1] = fmt("<title>%s</title>\n", title)
  local meta = hcfg().meta_tags
  local tags
  if type(meta) == "function" then
    tags = meta(info)
  elseif type(meta) == "table" then
    tags = meta
  else
    local author = info.with_author and info.author and element.interpret(info.author) or nil
    tags = {}
    if nw(author) then
      tags[#tags + 1] = { "name", "author", author }
    end
    if nw(info.description) then
      tags[#tags + 1] = { "name", "description", info.description }
    end
    if nw(info.keywords_meta) then
      tags[#tags + 1] = { "name", "keywords", info.keywords_meta }
    end
    tags[#tags + 1] = { "name", "generator", "Org Mode" }
  end
  for _, t in ipairs(tags) do
    out[#out + 1] = build_meta_entry(t[1], t[2], t[3])
  end
  return table.concat(out)
end

local function norm_or_fn(v, info)
  if type(v) == "function" then
    v = tostring(v(info) or "")
  end
  return ox.normalize_string(v or "")
end

local function build_head(info)
  local s = ""
  if info.html_head_include_default_style then
    s = s .. ox.normalize_string(data.style_default)
  end
  -- legacy `style` option: CSS string added after the default style
  if type(hcfg().style) == "string" then
    s = s .. ox.normalize_string('<style type="text/css">\n' .. hcfg().style .. "\n</style>")
  end
  s = s .. (norm_or_fn(info.html_head, info) or "")
  s = s .. (norm_or_fn(info.html_head_extra, info) or "")
  if info.html_head_include_scripts then
    s = s .. (info.html_scripts or data.scripts)
  end
  return ox.normalize_string(s) or ""
end

local function has_math(info)
  return element.map(info.parse_tree, { ["latex-fragment"] = true, ["latex-environment"] = true }, function(x)
    return x
  end, { ignore = info.ignore, first_match = true }) ~= nil
end

local MATHJAX_DEFAULTS = {
  { "path", "https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js" },
  { "scale", 1.0 },
  { "align", "center" },
  { "font", "mathjax-modern" },
  { "overflow", "overflow" },
  { "tags", "ams" },
  { "indent", "0em" },
  { "multlinewidth", "85%" },
  { "tagindent", ".8em" },
  { "tagside", "right" },
}

local function num_str(v)
  if type(v) == "number" then
    if v == math.floor(v) then
      return fmt("%.1f", v)
    end
    return tostring(v)
  end
  return tostring(v)
end

local function build_mathjax_config(info)
  local wl = info.with_latex
  if not (wl == "mathjax" or wl == true) or not has_math(info) then
    return ""
  end
  if hcfg().mathjax == false then
    return ""
  end
  local template = info.html_mathjax_template or data.mathjax_template
  local user = hcfg().mathjax_options or {}
  local options = {}
  for _, o in ipairs(MATHJAX_DEFAULTS) do
    local v = user[o[1]]
    if v == nil then
      v = o[2]
    end
    options[#options + 1] = { o[1], v }
  end
  local inbuf = info.html_mathjax or ""
  for _, o in ipairs(options) do
    local sym, value = o[1], o[2]
    local m = inbuf:match("%f[%w]" .. sym .. ":%s*(%S+)")
    if m then
      value = m
      if sym == "scale" then
        local n = tonumber(value) or 1.0
        if n >= 10 then
          n = n / 100
        end
        value = n
      elseif sym == "font" then
        value = ({
          TeX = "mathjax-tex",
          ["STIX-Web"] = "mathjax-stix2",
          ["Asana-Math"] = "mathjax-asana",
          ["Neo-Euler"] = "mathjax-euler",
          ["Gyre-Pagella"] = "mathjax-pagella",
          ["Gyre-Termes"] = "mathjax-termes",
          ["Latin-Modern"] = "mathjax-modern",
        })[value] or value
      end
    end
    if sym == "linebreaks" or sym == "autonumber" then
      -- legacy options
    end
    template = template:gsub("%%" .. sym:upper() .. "([^A-Z])", function(after)
      return num_str(value) .. after
    end)
  end
  -- legacy in-buffer options
  local lb = inbuf:match("%f[%w]linebreaks:%s*(%S+)")
  if lb then
    template = template:gsub("displayOverflow: '[^']*'", "displayOverflow: '" .. (lb == "true" and "linebreak" or "overflow") .. "'")
  end
  local an = inbuf:match("%f[%w]autonumber:%s*(%S+)")
  if an then
    template = template:gsub("tags: '[^']*'", "tags: '" .. an:lower() .. "'")
  end
  return ox.normalize_string(template)
end

local function format_spec(info)
  local tsfmt = info.html_metadata_timestamp_format
  local date = ox.get_date(info, tsfmt)
  local emails = {}
  for e in (info.email or ""):gmatch("[^,]+") do
    e = trim(e)
    if e ~= "" then
      emails[#emails + 1] = fmt('<a href="mailto:%s">%s</a>', e, e)
    end
  end
  local file = info.input_file
  return {
    t = ox.data(info.title, info),
    s = ox.data(info.subtitle, info),
    d = type(date) == "string" and date or ox.data(date, info),
    T = ox.format_time(tsfmt),
    a = ox.data(info.author, info),
    e = table.concat(emails, ", "),
    c = info.creator or "",
    C = ox.format_time(tsfmt, file and vim.fn.getftime(file) > 0 and vim.fn.getftime(file) or nil),
    v = info.html_validation_link or "",
  }
end

local function format_spec_apply(s, spec)
  return (s:gsub("%%(.)", function(c)
    if c == "%" then
      return "%"
    end
    return spec[c] or ("%" .. c)
  end))
end

local function build_pre_postamble(kind, info)
  local section = info["html_" .. kind]
  if not section then
    return ""
  end
  local spec = format_spec(info)
  local contents
  if type(section) == "function" then
    contents = section(info)
  elseif type(section) == "string" and section ~= "auto" then
    contents = format_spec_apply(section, spec)
  elseif section == "auto" and kind == "postamble" then
    local parts = {}
    if info.with_date and nw(spec.d) then
      parts[#parts + 1] = fmt('<p class="date">%s: %s</p>\n', translate("Date", info), spec.d)
    end
    if info.with_author and nw(spec.a) then
      parts[#parts + 1] = fmt('<p class="author">%s: %s</p>\n', translate("Author", info), spec.a)
    end
    if info.with_email and nw(spec.e) then
      parts[#parts + 1] = fmt('<p class="email">%s: %s</p>\n', translate("Email", info), spec.e)
    end
    if info.time_stamp_file then
      parts[#parts + 1] = fmt(
        '<p class="date">%s: %s</p>\n',
        translate("Created", info),
        ox.format_time(info.html_metadata_timestamp_format)
      )
    end
    if info.with_creator and nw(spec.c) then
      parts[#parts + 1] = fmt('<p class="creator">%s</p>\n', spec.c)
    end
    if nw(spec.v) then
      parts[#parts + 1] = fmt('<p class="validation">%s</p>\n', spec.v)
    end
    contents = table.concat(parts)
  else
    local formats = kind == "preamble" and (info.html_preamble_format or { en = "" })
      or (info.html_postamble_format or data.postamble_format)
    local f = formats[info.language] or formats.en or ""
    contents = format_spec_apply(f, spec)
  end
  if not nw(contents) then
    return ""
  end
  local div = info.html_divs[kind]
  return fmt('<%s id="%s" class="status">\n', div[1], div[2]) .. ox.normalize_string(contents) .. fmt("</%s>\n", div[1])
end

--- org-html-infojs-install-script (options filter).
local function infojs_install(info)
  local use = opt("use_infojs", "when-configured")
  if not use or (use == "when-configured" and not nw(info.infojs_opt)) then
    return info
  end
  if info.html_klipsify_src then
    return info
  end
  local o = info.infojs_opt or ""
  local table_ = {
    { "path", "PATH", "https://orgmode.org/org-info.js" },
    { "view", "VIEW", "info" },
    { "toc", "TOC", info.with_toc and "1" or "0" },
    { "ftoc", "FIXED_TOC", "0" },
    { "tdepth", "TOC_DEPTH", "max" },
    { "sdepth", "SECTION_DEPTH", "max" },
    { "mouse", "MOUSE_HINT", "underline" },
    { "buttons", "VIEW_BUTTONS", "0" },
    { "ltoc", "LOCAL_TOC", "1" },
    { "up", "LINK_UP", info.html_link_up or "" },
    { "home", "LINK_HOME", info.html_link_home or "" },
  }
  local template = data.infojs_template
  local options = {}
  local path
  for _, e in ipairs(table_) do
    local val = o:match("%f[%w]" .. e[1] .. ":(%S+)") or e[3]
    if e[1] == "path" then
      path = val
    else
      if e[1] == "sdepth" or e[1] == "tdepth" then
        if val == "max" then
          val = tostring(info.headline_levels)
        end
      elseif e[1] == "toc" then
        info.with_toc = val == "1" or val == "t"
      end
      options[#options + 1] = fmt('org_html_manager.set("%s", "%s");', e[2], val)
    end
  end
  template = template:gsub("%%SCRIPT_PATH", path):gsub("%%MANAGER_OPTIONS", table.concat(options, "\n"))
  info.html_head_extra = (info.html_head_extra or "") .. "\n" .. template
  return info
end
M.infojs_install = infojs_install

local function inner_template(contents, info)
  local depth = info.with_toc
  return (depth and (M.toc(type(depth) == "number" and depth or nil, info) or "") or "")
    .. contents
    .. (M.footnote_section(info) or "")
end

local function template(contents, info)
  local out = {}
  if not html5_p(info) and xhtml_p(info) then
    local decl = info.html_xml_declaration
    local d
    if type(decl) == "string" then
      d = decl
    elseif type(decl) == "table" then
      d = decl[info.html_extension] or decl.html
    end
    if d and d ~= "" then
      out[#out + 1] = fmt(d, info.html_coding_system or "utf-8") .. "\n"
    end
  end
  out[#out + 1] = (data.doctypes[info.html_doctype] or info.html_doctype) .. "\n"
  local lang = info.language
  if xhtml_p(info) then
    out[#out + 1] = fmt('<html xmlns="http://www.w3.org/1999/xhtml" lang="%s" xml:lang="%s">\n', lang, lang)
  elseif html5_p(info) then
    out[#out + 1] = fmt('<html lang="%s">\n', lang)
  else
    out[#out + 1] = "<html>\n"
  end
  out[#out + 1] = "<head>\n"
  out[#out + 1] = build_meta_info(info)
  out[#out + 1] = build_head(info)
  out[#out + 1] = build_mathjax_config(info)
  out[#out + 1] = "</head>\n<body>\n"
  local up = trim(info.html_link_up or "")
  local home = trim(info.html_link_home or "")
  if not (up == "" and home == "") then
    local f = info.html_home_up_format or data.home_up_format
    local i = 0
    out[#out + 1] = (f:gsub("%%s", function()
      i = i + 1
      if i == 1 then
        return up ~= "" and up or home
      end
      return home ~= "" and home or up
    end))
  end
  out[#out + 1] = build_pre_postamble("preamble", info)
  local div = info.html_divs.content
  out[#out + 1] = fmt('<%s id="%s" class="%s">\n', div[1], div[2], info.html_content_class)
  if info.with_title and info.title then
    local fancy = html5_fancy_p(info)
    local sub = ""
    if info.subtitle then
      if fancy then
        sub = fmt('<p class="subtitle" role="doc-subtitle">%s</p>\n', ox.data(info.subtitle, info))
      else
        sub = "\n" .. close_tag("br", nil, info) .. "\n" .. fmt('<span class="subtitle">%s</span>\n', ox.data(info.subtitle, info))
      end
    end
    if fancy then
      out[#out + 1] = fmt('<header>\n<h1 class="title">%s</h1>\n%s</header>', ox.data(info.title, info), sub)
    else
      out[#out + 1] = fmt('<h1 class="title">%s%s</h1>\n', ox.data(info.title, info), sub)
    end
  end
  out[#out + 1] = contents
  out[#out + 1] = fmt("</%s>\n", div[1])
  out[#out + 1] = build_pre_postamble("postamble", info)
  if info.html_klipsify_src then
    out[#out + 1] = "<script>"
      .. (info.html_klipse_selection_script or "")
      .. '</script><script src="'
      .. (info.html_klipse_js or "")
      .. '"></script><link rel="stylesheet" type="text/css" href="'
      .. (info.html_klipse_css or "")
      .. '"/>'
  end
  out[#out + 1] = "</body>\n</html>"
  return table.concat(out)
end

---------------------------------------------------------------------------
-- Plain text
---------------------------------------------------------------------------

local function convert_special_strings(s)
  s = s:gsub("\\%-", "&shy;")
  s = s:gsub("%-%-%-([^%-])", "&mdash;%1")
  s = s:gsub("%-%-([^%-])", "&ndash;%1")
  s = s:gsub("%.%.%.", "&hellip;")
  return s
end
M.convert_special_strings = convert_special_strings

function M.plain_text(text, info, node)
  local out = encode(text)
  if info.with_smart_quotes and node then
    out = ox.activate_smart_quotes(out, "html", info, node)
  end
  if info.with_special_strings then
    out = convert_special_strings(out)
  end
  if info.preserve_breaks then
    out = out:gsub("\\\\([ \t]*\n)", "%1"):gsub("[ \t]*\n", close_tag("br", nil, info) .. "\n")
  end
  return out
end

---------------------------------------------------------------------------
-- Transcoders
---------------------------------------------------------------------------

local T = {}

local function markup(kind, contents, info)
  local f = info.html_text_markup_alist[kind] or "%s"
  return (f:gsub("%%s", function()
    return contents
  end))
end

T.bold = function(_, contents, info)
  return markup("bold", contents, info)
end
T.italic = function(_, contents, info)
  return markup("italic", contents, info)
end
T.underline = function(_, contents, info)
  return markup("underline", contents, info)
end
T["strike-through"] = function(_, contents, info)
  return markup("strike-through", contents, info)
end
T.code = function(el, _, info)
  return markup("code", encode(el.value), info)
end
T.verbatim = function(el, _, info)
  return markup("verbatim", encode(el.value), info)
end

T["center-block"] = function(_, contents)
  return fmt('<div class="org-center">\n%s</div>', contents or "")
end

T.clock = function(el, _, info)
  return fmt(
    '<p>\n<span class="timestamp-wrapper">\n<span class="timestamp-kwd">%s</span> %s%s\n</span>\n</p>',
    "CLOCK:",
    format_timestamp(el.value, info),
    el.duration and fmt(' <span class="timestamp">(%s)</span>', el.duration) or ""
  )
end

T.drawer = function(el, contents)
  local f = hcfg().format_drawer_function
  if type(f) == "function" then
    return f(el.drawer_name, contents)
  end
  return contents
end

T["dynamic-block"] = function(_, contents)
  return contents
end

T.entity = function(el)
  return (entities[el.name] or {})[3] or ("\\" .. el.name)
end

T["example-block"] = function(el, _, info)
  local attrs = ox.read_attribute("attr_html", el)
  if attrs.textarea then
    return textarea_block(el)
  end
  if attrs.class then
    attrs.class = "example " .. attrs.class
  else
    set_attr(attrs, "class", "example")
  end
  local ref = M.reference(el, info)
  if ref and not has_attr(attrs, "id") then
    set_attr(attrs, "id", ref)
  end
  local a = attribute_string(attrs)
  return fmt("<pre%s>\n%s</pre>", nw(a) and (" " .. a) or "", M.format_code_of(el, info))
end

T["export-snippet"] = function(el)
  if M.snippet_backend(el) == "html" then
    return el.value
  end
end

function M.snippet_backend(el)
  local tr = (require("org.config").opts.export or {}).snippet_translation or {}
  return tr[el.back_end] or el.back_end
end

T["export-block"] = function(el)
  if el.back_end_type == "HTML" then
    return table.concat(element.remove_indentation(vim.split((el.value:gsub("\n$", "")), "\n", { plain = true })), "\n")
      .. "\n"
  end
end

T["fixed-width"] = function(el)
  local lines = element.remove_indentation(vim.split(el.value, "\n", { plain = true }))
  return fmt('<pre class="example">\n%s</pre>', M.do_format_code(table.concat(lines, "\n")))
end

T["footnote-reference"] = function(el, _, info)
  local sep = ""
  local prev = ox.get_previous_element(el, info)
  if prev and prev.type == "footnote-reference" then
    sep = info.html_footnote_separator
  end
  local n = ox.get_footnote_number(el, info)
  local label = el.label
  if label and tostring(tonumber(label)) == label then
    label = nil
  end
  local id
  if ox.footnote_first_reference_p(el, info) then
    id = fmt("fnr.%s", label or n)
  else
    local lab = el.label
    local ord = ox.get_ordinal(el, info, nil, function(ref)
      if lab then
        return ref.label == lab
      end
      return ref.label == nil
    end)
    id = fmt("fnr.%s.%d", label or n, ord or 1)
  end
  return sep
    .. fmt(
      info.html_footnote_format,
      anchor(id, tostring(n), fmt(' class="footref" href="#fn.%s" role="doc-backlink"', label or n), info)
    )
end

local function container(h, info)
  return (h.props and h.props.HTML_CONTAINER) or (ox.get_relative_level(h, info) == 1 and info.html_container or "div")
end

T.section = function(el, contents, info)
  local parent = element.lineage(el, "headline")
  if not parent then
    return contents
  end
  local class_num = ox.get_relative_level(parent, info) + info.html_toplevel_hlevel - 1
  local num
  if ox.numbered_headline_p(parent, info) then
    local nums = ox.get_headline_number(parent, info)
    if nums then
      local parts = {}
      for i, x in ipairs(nums) do
        parts[i] = tostring(x)
      end
      num = table.concat(parts, "-")
    end
  end
  return fmt(
    '<div class="outline-text-%d" id="text-%s">\n%s</div>\n',
    class_num,
    (parent.props and parent.props.CUSTOM_ID) or num or ox.get_reference(parent, info),
    contents or ""
  )
end

function M.format_list_item(contents, ltype, checkbox, info, term_counter_id, headline)
  local class = checkbox and fmt(' class="%s"', checkbox) or ""
  local box = (checkbox and (CHECKBOXES[info.html_checkbox_type] or CHECKBOXES.ascii)[checkbox] or "")
    .. (checkbox and " " or "")
  local br = close_tag("br", nil, info)
  local extra = (nw(contents) and headline) and "\n" or ""
  local s
  if ltype == "ordered" then
    s = fmt("<li%s%s>", class, term_counter_id and fmt(' value="%s"', term_counter_id) or "")
      .. (headline and (headline .. br) or "")
  elseif ltype == "unordered" then
    s = fmt("<li%s%s>", class, term_counter_id and fmt(' id="%s"', term_counter_id) or "")
      .. (headline and (headline .. br) or "")
  else
    s = fmt("<dt%s>%s</dt>", class, box .. (term_counter_id or "(no term)")) .. "<dd>"
  end
  if ltype ~= "descriptive" then
    s = s .. box
  end
  s = s .. extra .. (nw(contents) and trim(contents) or "") .. extra
  if ltype == "descriptive" then
    return s .. "</dd>"
  end
  return s .. "</li>"
end

T.headline = function(el, contents, info)
  if el.footnote_section_p then
    return nil
  end
  local numberedp = ox.numbered_headline_p(el, info)
  local numbers = ox.get_headline_number(el, info)
  local level = ox.get_relative_level(el, info) + info.html_toplevel_hlevel - 1
  local todo = info.with_todo_keywords and el.todo_keyword and ox.data(el.todo_keyword, info) or nil
  local todo_type = todo and el.todo_type
  local priority = info.with_priority and el.priority or nil
  local text = ox.data(el.title, info)
  local tags = info.with_tags and ox.get_tags(el, info) or nil
  if tags and #tags == 0 then
    tags = nil
  end
  local full = format_headline(info, todo, todo_type, priority, text, tags, info)
  contents = contents or ""
  local id = M.reference(el, info)
  local formatted = info.html_self_link_headlines and fmt('<a href="#%s">%s</a>', id, full) or full
  if ox.low_level_p(el, info) then
    local html_type = numberedp and "ol" or "ul"
    return (ox.first_sibling_p(el, info) and fmt('<%s class="org-%s">\n', html_type, html_type) or "")
      .. M.format_list_item(contents, numberedp and "ordered" or "unordered", nil, info, nil, anchor(id, nil, nil, info) .. formatted)
      .. "\n"
      .. (ox.last_sibling_p(el, info) and fmt("</%s>\n", html_type) or "")
  end
  local extra_class = el.props and el.props.HTML_CONTAINER_CLASS
  local headline_class = el.props and el.props.HTML_HEADLINE_CLASS
  local first = el.contents[1]
  local num = ""
  if numberedp and numbers then
    local parts = {}
    for i, x in ipairs(numbers) do
      parts[i] = tostring(x)
    end
    num = fmt('<span class="section-number-%d">%s</span> ', level, table.concat(parts, ".") .. ".")
  end
  local body
  if first and first.type == "section" then
    body = contents
  elseif first then
    -- pretend there is an empty section (for org-info.js)
    body = T.section(first, "", info) .. contents
  else
    body = contents
  end
  local c = container(el, info)
  return fmt(
    '<%s id="%s" class="%s">%s%s</%s>\n',
    c,
    "outline-container-" .. id,
    fmt("outline-%d", level) .. (extra_class and (" " .. extra_class) or ""),
    fmt("\n<h%d id=\"%s\"%s>%s</h%d>\n", level, id, headline_class and fmt(' class="%s"', headline_class) or "", num .. formatted, level),
    body,
    c
  )
end

T["horizontal-rule"] = function(_, _, info)
  return close_tag("hr", nil, info)
end

T["inline-src-block"] = function(el, _, info)
  local lbl = M.reference(el, info, true)
  return fmt(
    '<code class="src src-%s"%s>%s</code>',
    el.language,
    lbl and fmt(' id="%s"', lbl) or "",
    fontify(el.value, el.language)
  )
end

T.inlinetask = function(el, contents, info)
  local todo = info.with_todo_keywords and el.todo_keyword or nil
  local todo_type = todo and el.todo_type
  local priority = info.with_priority and el.priority or nil
  local text = ox.data(el.title, info)
  local tags = info.with_tags and ox.get_tags(el, info) or nil
  if tags and #tags == 0 then
    tags = nil
  end
  local f = hcfg().format_inlinetask_function
  if type(f) == "function" then
    return f(todo, todo_type, priority, text, tags, contents, info)
  end
  return fmt(
    '<div class="inlinetask">\n<b>%s</b>%s\n%s</div>',
    format_headline(info, todo, todo_type, priority, text, tags, info),
    close_tag("br", nil, info),
    contents or ""
  )
end

T.item = function(el, contents, info)
  local list = el.parent
  local ltype = list.list_type
  local tag = el.tag and ox.data(el.tag, info) or nil
  return M.format_list_item(contents, ltype, el.checkbox, info, tag or el.counter)
end

T.keyword = function(el, _, info)
  local key, value = el.key, el.value
  if key == "HTML" then
    return value
  elseif key == "TOC" then
    local low = value:lower()
    if low:match("%f[%w]headlines%f[%W]") then
      local depth = tonumber(value:match("%f[%d](%d+)%f[%D]"))
      local scope
      local target = value:match(':target +(".-")') or value:match(":target +(%S+)")
      if target then
        scope = ox.resolve_link(target:gsub('^"(.*)"$', "%1"), info)
      elseif low:match("%f[%w]local%f[%W]") then
        scope = el
      end
      return M.toc(depth, info, scope)
    elseif value == "listings" then
      return list_of("listings", info)
    elseif value == "tables" then
      return list_of("tables", info)
    end
  end
end

--- Math environments (org-latex-math-environments-re).
local MATH_ENVS = {
  "equation",
  "eqnarray",
  "math",
  "displaymath",
  "align",
  "gather",
  "multline",
  "flalign",
  "alignat",
  "xalignat",
  "xxalignat",
  "subequations",
  "dmath",
  "dseries",
  "dgroup",
  "darray",
  "dsuspend",
}
function M.math_environment_p(el)
  local env = (el.value or ""):match("^[ \t]*\\begin{([^}]+)}")
  if not env then
    return false
  end
  env = env:gsub("%*$", "")
  for _, e in ipairs(MATH_ENVS) do
    if env == e then
      return true
    end
  end
  return false
end

local function latex_env_numbered_p(el)
  local env = (el.value or ""):match("^[ \t]*\\begin{([^}]+)}") or ""
  return not (env:match("%*$") or env == "displaymath")
end

T["latex-environment"] = function(el, _, info)
  local ptype = info.with_latex
  local frag = table.concat(element.remove_indentation(vim.split((el.value:gsub("\n$", "")), "\n", { plain = true })), "\n")
    .. "\n"
  local label = M.reference(el, info, true)
  if ptype == true or ptype == "mathjax" then
    if nw(label) then
      frag = frag:gsub("^([^\n]*)", "%1\n\\label{" .. label .. "}", 1)
    end
    return frag
  end
  local caption
  if latex_env_numbered_p(el) and M.math_environment_p(el) then
    caption = tostring(ox.get_ordinal(el, info, nil, function(l)
      return M.math_environment_p(l) and latex_env_numbered_p(l)
    end))
  end
  return fmt(
    '\n<div%s class="equation-container">\n%s%s\n</div>',
    nw(label) and fmt(' id="%s"', label) or "",
    fmt('<span class="equation">\n%s\n</span>', frag),
    nw(caption) and fmt('\n<span class="equation-label">\n%s\n</span>', caption) or ""
  )
end

--- $…$ and $$…$$ become \(…\) and \[…\] for MathJax (org-format-latex with
--- mathjax processing).
function M.mathjax_fragment(frag)
  if frag:match("^%$%$") then
    return "\\[" .. frag:sub(3, -3) .. "\\]"
  elseif frag:match("^%$") then
    return "\\(" .. frag:sub(2, -2) .. "\\)"
  end
  return frag
end

T["latex-fragment"] = function(el, _, info)
  local ptype = info.with_latex
  if ptype == true or ptype == "mathjax" then
    return M.mathjax_fragment(el.value)
  end
  return el.value
end

T["line-break"] = function(_, _, info)
  return close_tag("br", nil, info) .. "\n"
end

--- Inline image rules (org-html-inline-image-rules).
local IMG = { "jpeg", "jpg", "png", "gif", "svg", "webp", "avif" }
M.inline_image_rules = { file = IMG, http = IMG, https = IMG }

function M.inline_image_p(link, info)
  if #link.contents == 0 then
    return ox.inline_image_p(link, info.html_inline_image_rules)
  end
  local count = 0
  local ok = true
  for _, obj in ipairs(link.contents) do
    if obj.type == "plain-text" then
      if nw(obj.value) then
        ok = false
      end
    elseif obj.type == "link" then
      count = count + 1
      if count > 1 or not ox.inline_image_p(obj, info.html_inline_image_rules) then
        ok = false
      end
    else
      ok = false
    end
  end
  return ok and count == 1
end

function M.standalone_image_p(el, info, predicate)
  local paragraph = el.type == "paragraph" and el or (el.type == "link" and el.parent) or nil
  if not paragraph or paragraph.type ~= "paragraph" then
    return false
  end
  if predicate and not predicate(paragraph) then
    return false
  end
  local count = 0
  for _, obj in ipairs(paragraph.contents) do
    if not info.ignore[obj] then
      if obj.type == "plain-text" then
        if nw(obj.value) then
          return false
        end
      elseif obj.type == "link" then
        count = count + 1
        if count > 1 or not M.inline_image_p(obj, info) then
          return false
        end
      else
        return false
      end
    end
  end
  return count == 1
end

function M.format_image(source, attrs, info)
  local a = { _keys = { "src", "alt" }, src = source, alt = vim.fn.fnamemodify(source, ":t") }
  if source:match("%.svg$") then
    set_attr(a, "class", "org-svg")
  end
  for _, k in ipairs((attrs or {})._keys or {}) do
    if not (source:match("%.svg$") and k == "fallback") then
      set_attr(a, k, attrs[k])
    end
  end
  return close_tag("img", attribute_string(a), info)
end

local function wrap_image(contents, info, caption, label)
  local fancy = html5_fancy_p(info)
  return fmt(
    fancy and "\n<figure%s>\n%s%s\n</figure>" or "\n<div%s class=\"figure\">\n%s%s\n</div>",
    nw(label) and fmt(' id="%s"', label) or "",
    fancy and contents or fmt("<p>%s</p>", contents),
    nw(caption) and fmt(fancy and "\n<figcaption>%s</figcaption>" or "\n<p>%s</p>", caption) or ""
  )
end

local function link_org_as_html(raw, info)
  if info.html_link_org_files_as_html then
    local base = raw:match("^(.+)%.[Oo][Rr][Gg]$") or raw:match("^(.+)%.[Oo][Rr][Gg]%.gpg$")
    if base then
      local ext = info.html_extension
      return base .. (ext ~= "" and "." or "") .. ext
    end
  end
  return raw
end

local function url_encode(s)
  return (s:gsub("[^%w%-%._~:/%?#%[%]@!%$&'%(%)%*%+,;=%%]", function(c)
    return fmt("%%%02X", c:byte())
  end))
end
M.url_encode = url_encode

--- Resolve a search option of a file link to an anchor
--- (org-publish-resolve-external-link).
function M.resolve_external(option, path, info)
  local pub = require("org.export.publish")
  local r = pub.resolve_external_link(option, path, info)
  if r then
    return r
  end
  return option:gsub("^#", ""):gsub("^%*", "")
end

T.link = function(el, desc, info)
  local ltype = el.link_type
  local raw = el.path
  desc = nw(desc)
  local path
  if ltype == "file" then
    local rel = require("org.export.publish").file_relative_name(raw, info)
    raw = ox.file_uri(rel)
    local home = info.html_link_home and trim(info.html_link_home)
    if nw(home) and info.html_link_use_abs_url and not (raw:match("^/") or raw:match("^file:")) then
      raw = home:gsub("/?$", "/") .. raw
    end
    raw = link_org_as_html(raw, info)
    if el.search_option then
      path = raw .. "#" .. M.resolve_external(el.search_option, el.path, info)
    else
      path = raw
    end
  elseif ltype ~= "coderef" and ltype ~= "custom-id" and ltype ~= "fuzzy" and ltype ~= "radio" and ltype ~= "id" then
    path = url_encode(ltype .. ":" .. raw)
  end
  -- attributes of the parent paragraph (first link only)
  local attrs = { _keys = {} }
  local parent = element.parent_element(el)
  local target_link = el
  if el.parent and el.parent.type == "link" and M.inline_image_p(el, info) then
    target_link = el.parent
  end
  if parent then
    local first = element.map(parent.contents, "link", function(x)
      return x
    end, { first_match = true })
    if first == target_link then
      attrs = ox.read_attribute("attr_html", parent)
    end
  end
  local attributes = attribute_string(attrs)
  attributes = nw(attributes) and (" " .. attributes) or ""
  local custom = ox.custom_protocol_maybe(el, desc, "html", info)
  if custom then
    return custom
  end
  if info.html_inline_images and ox.inline_image_p(el, info.html_inline_image_rules) then
    return M.format_image(path or raw, attrs, info)
  end
  if ltype == "radio" then
    local dest = ox.resolve_radio_link(el, info)
    if not dest then
      return desc
    end
    return fmt('<a href="#%s"%s>%s</a>', M.reference(dest, info), attributes, desc or "")
  end
  if ltype == "custom-id" or ltype == "fuzzy" or ltype == "id" then
    local dest = ltype == "fuzzy" and ox.resolve_fuzzy_link(el, info) or ox.resolve_id_link(el, info)
    if dest.type == "plain-text" then
      local frag = "ID-" .. el.path
      local p = link_org_as_html(dest.value, info)
      return fmt('<a href="%s#%s"%s>%s</a>', p, frag, attributes, desc or dest.value)
    elseif dest.type == "headline" then
      local href = M.reference(dest, info)
      local d
      if ox.numbered_headline_p(dest, info) and not desc then
        local parts = {}
        for i, x in ipairs(ox.get_headline_number(dest, info) or {}) do
          parts[i] = tostring(x)
        end
        d = table.concat(parts, ".")
      else
        d = desc or ox.data(dest.title, info)
      end
      return fmt('<a href="#%s"%s>%s</a>', href, attributes, d)
    else
      local wl = info.with_latex
      if (wl == "mathjax" or wl == true) and dest.type == "latex-environment" and M.math_environment_p(dest) then
        return fmt(info.html_equation_reference_format, M.reference(dest, info))
      end
      local ref = M.reference(dest, info)
      local number
      if not desc then
        local pred = function(x)
          return x.caption ~= nil
        end
        if M.standalone_image_p(dest, info, pred) then
          local img = element.map(dest, "link", function(x)
            return x
          end, { first_match = true })
          number = ox.get_ordinal(img, info, { "link" }, function(x)
            return M.standalone_image_p(x, info, pred)
          end)
        else
          number = ox.get_ordinal(dest, info, nil, dest.type == "latex-environment" and function(x)
            return M.math_environment_p(x)
          end or function(x)
            return x.caption ~= nil
          end)
        end
      end
      local d = desc
      if not d then
        if number == nil then
          d = "No description for this link"
        elseif type(number) == "number" then
          d = tostring(number)
        else
          local parts = {}
          for i, x in ipairs(number) do
            parts[i] = tostring(x)
          end
          d = table.concat(parts, ".")
        end
      end
      return fmt('<a href="#%s"%s>%s</a>', ref, attributes, d)
    end
  end
  if ltype == "coderef" then
    local frag = "coderef-" .. encode(raw)
    local r = ox.resolve_coderef(raw, info)
    local f = ox.get_coderef_format(raw, desc)
    return fmt(
      '<a href="#%s" %s%s>%s</a>',
      frag,
      fmt("class=\"coderef\" onmouseover=\"CodeHighlightOn(this, '%s');\" onmouseout=\"CodeHighlightOff(this, '%s');\"", frag, frag),
      attributes,
      (f:gsub("%%s", function()
        return tostring(r)
      end))
    )
  end
  if path and desc then
    return fmt('<a href="%s"%s>%s</a>', encode(path), attributes, desc)
  end
  if path then
    local p = encode(path)
    return fmt('<a href="%s"%s>%s</a>', p, attributes, p)
  end
  return fmt("<i>%s</i>", desc or "")
end

T["node-property"] = function(el)
  return fmt("%s:%s", el.key, el.value and (" " .. el.value) or "")
end

T.paragraph = function(el, contents, info)
  local parent = el.parent
  local ptype = parent and parent.type
  local attrs = attribute_string(ox.read_attribute("attr_html", el))
  local extra = (ptype == "footnote-definition" or ptype == "org-data") and ' class="footpara"' or ""
  if ptype == "item" and not ox.get_previous_element(el, info) then
    local followers = ox.get_next_element(el, info, 2)
    if #followers <= 1 and (followers[1] == nil or followers[1].type == "plain-list") then
      return contents
    end
  end
  if M.standalone_image_p(el, info) then
    local raw = ox.data(ox.get_caption(el), info)
    local caption = raw
    if nw(raw) then
      local img = element.map(el, "link", function(x)
        return x
      end, { first_match = true })
      local pred = function(x)
        return x.caption ~= nil
      end
      local n = ox.get_ordinal(img, info, nil, function(x)
        return M.standalone_image_p(x, info, pred)
      end)
      caption = '<span class="figure-number">' .. (translate("Figure %d:", info):gsub("%%d", tostring(n))) .. " </span>" .. raw
    end
    return wrap_image(contents, info, caption, M.reference(el, info))
  end
  return fmt("<p%s%s>\n%s</p>", nw(attrs) and (" " .. attrs) or "", extra, contents or "")
end

T["plain-list"] = function(el, contents)
  local t = ({ ordered = "ol", unordered = "ul", descriptive = "dl" })[el.list_type]
  local attrs = ox.read_attribute("attr_html", el)
  local class = trim("org-" .. t .. " " .. (attrs.class or ""))
  set_attr(attrs, "class", class)
  return fmt("<%s %s>\n%s</%s>", t, attribute_string(attrs), contents or "", t)
end

T["plain-text"] = function(text, info, node)
  return M.plain_text(text, info, node)
end

T.planning = function(el, _, info)
  local parts = {}
  for _, kv in ipairs({ { "CLOSED:", el.closed }, { "DEADLINE:", el.deadline }, { "SCHEDULED:", el.scheduled } }) do
    if kv[2] then
      parts[#parts + 1] = fmt('<span class="timestamp-kwd">%s</span> %s ', kv[1], format_timestamp(kv[2], info))
    end
  end
  return fmt('<p><span class="timestamp-wrapper">%s</span></p>', trim(table.concat(parts)))
end

T["property-drawer"] = function(_, contents)
  if nw(contents) then
    return fmt('<pre class="example">\n%s</pre>', contents)
  end
end

T["quote-block"] = function(el, contents, info)
  local ref = M.reference(el, info, true)
  local attrs = ox.read_attribute("attr_html", el)
  if ref and not has_attr(attrs, "id") then
    set_attr(attrs, "id", ref)
  end
  local a = attribute_string(attrs)
  return fmt("<blockquote%s>\n%s</blockquote>", nw(a) and (" " .. a) or "", contents or "")
end

T["radio-target"] = function(el, text, info)
  return anchor(M.reference(el, info), text, nil, info)
end

local HTML5_ELEMENTS = {
  article = 1,
  aside = 1,
  audio = 1,
  canvas = 1,
  details = 1,
  figcaption = 1,
  figure = 1,
  footer = 1,
  header = 1,
  menu = 1,
  meter = 1,
  nav = 1,
  output = 1,
  progress = 1,
  section = 1,
  summary = 1,
  video = 1,
}

T["special-block"] = function(el, contents, info)
  local btype = el.block_type
  local fancy = html5_fancy_p(info) and HTML5_ELEMENTS[btype]
  local attrs = ox.read_attribute("attr_html", el)
  if not fancy then
    local class = attrs.class
    set_attr(attrs, "class", class and (class .. " " .. btype) or btype)
  end
  contents = contents or ""
  local ref = M.reference(el, info)
  if ref and not has_attr(attrs, "id") then
    set_attr(attrs, "id", ref)
  end
  local a = attribute_string(attrs)
  local str = nw(a) and (" " .. a) or ""
  if fancy then
    return fmt("<%s%s>\n%s</%s>", btype, str, contents, btype)
  end
  return fmt("<div%s>\n%s\n</div>", str, contents)
end

T["src-block"] = function(el, _, info)
  if ox.read_attribute("attr_html", el, "textarea") then
    return textarea_block(el)
  end
  local lang = el.language
  local code = M.format_code_of(el, info)
  local lbl = M.reference(el, info, true)
  local label = lbl and fmt(' id="%s"', lbl) or ""
  local caption = ox.get_caption(el)
  local cap = ""
  if caption then
    local n = ox.get_ordinal(el, info, nil, has_caption)
    cap = fmt(
      '<label class="org-src-name">%s%s</label>',
      fmt('<span class="listing-number">%s </span>', (translate("Listing %d:", info):gsub("%%d", tostring(n)))),
      trim(ox.data(caption, info))
    )
  end
  local klipse = info.html_klipsify_src
    and vim.tbl_contains({ "javascript", "js", "ruby", "scheme", "clojure", "php", "html" }, lang)
  if klipse then
    return fmt(
      '<div class="org-src-container">\n%s%s\n</div>',
      cap,
      fmt('<pre><code class="src src-%s"%s%s>%s</code></pre>', lang or "", label, lang == "html" and ' data-editor-type="html"' or "", code)
    )
  end
  return fmt(
    '<div class="org-src-container">\n%s%s\n</div>',
    cap,
    fmt('<pre class="src src-%s"%s><code>%s</code></pre>', lang or "", label, code)
  )
end

T["statistics-cookie"] = function(el)
  return fmt("<code>%s</code>", el.value)
end

T.subscript = function(_, contents)
  return fmt("<sub>%s</sub>", contents or "")
end

T.superscript = function(_, contents)
  return fmt("<sup>%s</sup>", contents or "")
end

T["table-cell"] = function(el, contents, info)
  local row = el.parent
  local tbl = element.lineage(el, "table")
  local attrs = ""
  if info.html_table_align_individual_fields then
    attrs = fmt(' class="org-%s"', ox.table_cell_alignment(el, info))
  end
  if not contents or trim(contents) == "" then
    contents = "&nbsp;"
  end
  if ox.table_has_header_p(tbl, info) and ox.table_row_group(row, info) == 1 then
    local h = info.html_table_header_tags
    return "\n" .. fmt(h[1], "col", attrs) .. contents .. h[2]
  end
  if info.html_table_use_header_tags_for_first_column then
    local _, col = ox.table_cell_address(el, info)
    if col == 0 then
      local h = info.html_table_header_tags
      return "\n" .. fmt(h[1], "row", attrs) .. contents .. h[2]
    end
  end
  local d = info.html_table_data_tags
  return "\n" .. fmt(d[1], attrs) .. contents .. d[2]
end

T["table-row"] = function(el, contents, info)
  if el.row_type ~= "standard" then
    return nil
  end
  local group = ox.table_row_group(el, info)
  local start_p = ox.table_row_starts_rowgroup_p(el, info)
  local end_p = ox.table_row_ends_rowgroup_p(el, info)
  local open_tag = info.html_table_row_open_tag
  local close = info.html_table_row_close_tag
  if type(open_tag) == "function" then
    open_tag = open_tag(ox.table_row_number(el, info), group, start_p, end_p)
  end
  if type(close) == "function" then
    close = close(ox.table_row_number(el, info), group, start_p, end_p)
  end
  local tags
  if group ~= 1 then
    tags = { "<tbody>", "\n</tbody>" }
  elseif ox.table_has_header_p(element.lineage(el, "table"), info) then
    tags = { "<thead>", "\n</thead>" }
  else
    tags = { "<tbody>", "\n</tbody>" }
  end
  return (start_p and tags[1] or "") .. "\n" .. open_tag .. (contents or "") .. "\n" .. close .. (end_p and tags[2] or "")
end

local function first_row_data_cells(tbl, info)
  local row
  for _, r in ipairs(tbl.contents) do
    if r.row_type ~= "rule" and not info.ignore[r] then
      row = r
      break
    end
  end
  if not row then
    return {}
  end
  local cells = row.contents
  if ox.table_has_special_column_p(tbl) then
    cells = vim.list_slice(cells, 2)
  end
  return cells
end

T.table = function(el, contents, info)
  if el.table_type == "table.el" then
    return trim(M.table_el(el) or "")
  end
  local caption = ox.get_caption(el)
  local number = ox.get_ordinal(el, info, nil, has_caption)
  local attrs = { _keys = { "id" }, id = M.reference(el, info, true) }
  if not html5_p(info) then
    for _, kv in ipairs(info.html_table_attributes or {}) do
      set_attr(attrs, kv[1], kv[2])
    end
  end
  local user = ox.read_attribute("attr_html", el)
  for _, k in ipairs(user._keys) do
    set_attr(attrs, k, user[k])
  end
  local a = attribute_string(attrs)
  local specs = {}
  for _, cell in ipairs(first_row_data_cells(el, info)) do
    local s = ""
    if ox.table_cell_starts_colgroup_p(cell, info) then
      s = s .. "\n<colgroup>"
    end
    s = s .. "\n" .. close_tag("col", " " .. fmt('class="org-%s"', ox.table_cell_alignment(cell, info)), info)
    if ox.table_cell_ends_colgroup_p(cell, info) then
      s = s .. "\n</colgroup>"
    end
    specs[#specs + 1] = s
  end
  local cap = ""
  if caption then
    cap = fmt(
      info.html_table_caption_above and '<caption class="t-above">%s</caption>' or '<caption class="t-bottom">%s</caption>',
      '<span class="table-number">' .. (translate("Table %d:", info):gsub("%%d", tostring(number))) .. "</span> " .. ox.data(caption, info)
    )
  end
  return fmt("<table%s>\n%s\n%s\n%s</table>", a == "" and "" or (" " .. a), cap, table.concat(specs, "\n"), contents or "")
end

--- table.el tables: rendered as preformatted text (Emacs uses table.el).
function M.table_el(el)
  return '<pre class="example">\n' .. encode(el.value) .. "</pre>"
end

T.target = function(el, _, info)
  return anchor(M.reference(el, info), nil, nil, info)
end

T.timestamp = function(el, _, info)
  local copy = setmetatable({ post_blank = 0 }, { __index = el })
  return fmt('<span class="timestamp-wrapper">%s</span>', format_timestamp(copy, info))
end

T["verse-block"] = function(_, contents, info)
  local br = close_tag("br", nil, info)
  contents = contents or ""
  contents = contents:gsub(vim.pesc(br) .. "[ \t]*\n", "\n")
  contents = contents:gsub("[ \t]*\n", br .. "\n")
  contents = contents:gsub("\n([ \t]+)", function(ws)
    return "\n" .. string.rep("&nbsp;", #ws)
  end)
  contents = contents:gsub("^([ \t]+)", function(ws)
    return string.rep("&nbsp;", #ws)
  end)
  return fmt('<p class="verse">\n%s</p>', contents)
end

T.citation = function(el, _, info)
  return require("org.export.cite").export_citation(el, info, "html")
end

T.template = template
T.inner_template = inner_template

M.transcoders = T

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

local function defaults()
  local c = hcfg()
  local function v(name, default)
    if c[name] == nil then
      return default
    end
    return c[name]
  end
  local head_default_style = v("head_include_default_style", true)
  if c.style == false then
    head_default_style = false
  end
  return {
    { "html_doctype", "HTML_DOCTYPE", nil, v("doctype", "xhtml-strict") },
    { "html_container", "HTML_CONTAINER", nil, v("container", "div") },
    { "html_content_class", "HTML_CONTENT_CLASS", nil, v("content_class", "content") },
    { "description", "DESCRIPTION", nil, nil, "newline" },
    { "keywords_meta", "KEYWORDS", nil, nil, "space" },
    { "html_html5_fancy", nil, "html5-fancy", v("html5_fancy", false) },
    { "html_link_use_abs_url", nil, "html-link-use-abs-url", v("link_use_abs_url", false) },
    { "html_link_home", "HTML_LINK_HOME", nil, v("link_home", "") },
    { "html_link_up", "HTML_LINK_UP", nil, v("link_up", "") },
    { "html_mathjax", "HTML_MATHJAX", nil, "", "space" },
    { "html_equation_reference_format", "HTML_EQUATION_REFERENCE_FORMAT", nil, v("equation_reference_format", "\\eqref{%s}"), "t" },
    { "html_postamble", nil, "html-postamble", v("postamble", "auto") },
    { "html_preamble", nil, "html-preamble", v("preamble", true) },
    { "html_head", "HTML_HEAD", nil, v("head", ""), "newline" },
    { "html_head_extra", "HTML_HEAD_EXTRA", nil, v("head_extra", ""), "newline" },
    { "subtitle", "SUBTITLE", nil, nil, "parse" },
    { "html_head_include_default_style", nil, "html-style", head_default_style },
    { "html_head_include_scripts", nil, "html-scripts", v("head_include_scripts", false) },
    { "html_allow_name_attribute_in_anchors", nil, nil, v("allow_name_attribute_in_anchors", false) },
    { "html_divs", nil, nil, v("divs", { preamble = { "div", "preamble" }, content = { "div", "content" }, postamble = { "div", "postamble" } }) },
    { "html_checkbox_type", nil, nil, v("checkbox_type", "ascii") },
    { "html_extension", nil, nil, v("extension", "html") },
    { "html_footnote_format", nil, nil, v("footnote_format", "<sup>%s</sup>") },
    { "html_footnote_separator", nil, nil, v("footnote_separator", "<sup>, </sup>") },
    { "html_footnotes_section", nil, nil, v("footnotes_section", data.footnotes_section) },
    { "html_home_up_format", nil, nil, v("home_up_format", data.home_up_format) },
    { "html_inline_image_rules", nil, nil, v("inline_image_rules", M.inline_image_rules) },
    { "html_link_org_files_as_html", nil, nil, v("link_org_files_as_html", true) },
    { "html_mathjax_template", nil, nil, v("mathjax_template", data.mathjax_template) },
    { "html_metadata_timestamp_format", nil, nil, v("metadata_timestamp_format", "%Y-%m-%d %a %H:%M") },
    { "html_postamble_format", nil, nil, v("postamble_format", data.postamble_format) },
    { "html_preamble_format", nil, nil, v("preamble_format", { en = "" }) },
    { "html_prefer_user_labels", nil, nil, v("prefer_user_labels", false) },
    { "html_self_link_headlines", nil, "html-self-link-headlines", v("self_link_headlines", false) },
    { "html_table_align_individual_fields", nil, nil, v("table_align_individual_fields", true) },
    { "html_table_caption_above", nil, nil, v("table_caption_above", true) },
    { "html_table_data_tags", nil, nil, v("table_data_tags", { "<td%s>", "</td>" }) },
    { "html_table_header_tags", nil, nil, v("table_header_tags", { '<th scope="%s"%s>', "</th>" }) },
    { "html_table_use_header_tags_for_first_column", nil, nil, v("table_use_header_tags_for_first_column", false) },
    { "html_tag_class_prefix", nil, nil, v("tag_class_prefix", "") },
    { "html_text_markup_alist", nil, nil, v("text_markup_alist", {
      bold = "<b>%s</b>",
      code = "<code>%s</code>",
      italic = "<i>%s</i>",
      ["strike-through"] = "<del>%s</del>",
      underline = '<span class="underline">%s</span>',
      verbatim = "<code>%s</code>",
    }) },
    { "html_todo_kwd_class_prefix", nil, nil, v("todo_kwd_class_prefix", "") },
    { "html_toplevel_hlevel", nil, nil, v("toplevel_hlevel", 2) },
    { "html_validation_link", nil, nil, v("validation_link", data.validation_link) },
    { "html_viewport", nil, nil, v("viewport", {
      { "width", "device-width" },
      { "initial-scale", "1" },
      { "minimum-scale", "" },
      { "maximum-scale", "" },
      { "user-scalable", "" },
    }) },
    { "html_inline_images", nil, nil, v("inline_images", true) },
    { "html_table_attributes", nil, nil, v("table_default_attributes", {
      { "border", "2" },
      { "cellspacing", "0" },
      { "cellpadding", "6" },
      { "rules", "groups" },
      { "frame", "hsides" },
    }) },
    { "html_table_row_open_tag", nil, nil, v("table_row_open_tag", "<tr>") },
    { "html_table_row_close_tag", nil, nil, v("table_row_close_tag", "</tr>") },
    { "html_xml_declaration", nil, nil, v("xml_declaration", {
      html = '<?xml version="1.0" encoding="%s"?>',
      php = '<?php echo "<?xml version=\\"1.0\\" encoding=\\"%s\\" ?>"; ?>',
    }) },
    { "html_coding_system", nil, nil, v("coding_system", "utf-8") },
    { "html_wrap_src_lines", nil, nil, v("wrap_src_lines", false) },
    { "html_klipsify_src", nil, nil, v("klipsify_src", false) },
    { "html_klipse_css", nil, nil, v("klipse_css", "https://storage.googleapis.com/app.klipse.tech/css/codemirror.css") },
    { "html_klipse_js", nil, nil, v("klipse_js", "https://storage.googleapis.com/app.klipse.tech/plugin_prod/js/klipse_plugin.min.js") },
    { "html_klipse_selection_script", nil, nil, v("klipse_selection_script", "") },
    { "html_scripts", nil, nil, v("scripts", data.scripts) },
    { "infojs_opt", "INFOJS_OPT", nil, nil },
    { "creator", "CREATOR", nil, v("creator_string", nil) or ox.creator_string() },
    { "latex_header", "LATEX_HEADER", nil, nil, "newline" },
  }
end

M.backend = ox.define_backend("html", {
  transcoders = T,
  options = defaults,
  filters = {
    options = {
      function(info)
        return infojs_install(info)
      end,
    },
    ["parse-tree"] = {
      function(tree, _, info)
        return ox.insert_image_links(tree, info, info.html_inline_image_rules)
      end,
    },
  },
})

--- Render a parsed document (legacy API); prefer org.export.to_string.
function M.render(doc, opts)
  error("org.export.html.render is replaced by org.export.to_string")
end

return M

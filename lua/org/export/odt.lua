---@mod org.export.odt OpenDocument Text back-end (port of ox-odt.el)
---
--- Writes content.xml with the transcoders of ox-odt.el, meta.xml,
--- styles.xml (the factory OrgOdtStyles.xml of Emacs, or the file named by
--- #+ODT_STYLES_FILE / `export.odt.styles_file`), the manifest and the
--- embedded pictures and formulas, and zips them with the pure-Lua writer
--- of org.export.zip (the `mimetype` entry first and uncompressed, as the
--- OpenDocument packaging rules require). With
--- `export.odt.preferred_output_format` the .odt file is then converted
--- (LibreOffice by default, org-odt-convert-process).

local ox = require("org.export.ox")
local element = require("org.export.element")
local entities = require("org.export.entities")
local zip = require("org.export.zip")

local M = {}

M.extension = "odt"

local fmt = string.format
local nw = ox.nw
local trim = ox.trim

local function ocfg()
  return (require("org.config").opts.export or {}).odt or {}
end

--- Directory of OrgOdtStyles.xml and OrgOdtContentTemplate.xml
--- (org-odt-styles-dir): etc/styles/ of the plugin.
function M.styles_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":p:h:h:h:h") .. "/etc/styles/"
end

local function read_file(path, binary)
  local f = io.open(path, binary and "rb" or "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

---------------------------------------------------------------------------
-- Constants (ox-odt.el)
---------------------------------------------------------------------------

local ID_PREFIX = "ID-" -- org-odt--id-attr-prefix
local BOOKMARK_PREFIX = "OrgXref." -- org-odt-bookmark-prefix

local TABLE_STYLE_FORMAT = [[

<style:style style:name="%s" style:family="table">
  <style:table-properties style:rel-width="%s%%" fo:margin-top="0cm" fo:margin-bottom="0.20cm" table:align="center"/>
</style:style>
]]

local SRC_BLOCK_PARAGRAPH_FORMAT =
  [[<style:style style:name="OrgSrcBlock" style:family="paragraph" style:parent-style-name="Preformatted_20_Text">
   <style:paragraph-properties fo:background-color="%s" fo:padding="0.049cm" fo:border="0.51pt solid #000000" style:shadow="none">
    <style:background-image/>
   </style:paragraph-properties>
   <style:text-properties fo:color="%s"/>
  </style:style>]]

--- org-odt-label-styles: STYLE -> { ATTACH-FMT, REF-MODE, REF-FMT }
local LABEL_STYLES = {
  ["math-formula"] = { "%c", "text", "(%n)" },
  ["math-label"] = { "(%n)", "text", "(%n)" },
  ["category-and-value"] = { "%e %n: %c", "category-and-value", "%e %n" },
  value = { "%e %n: %c", "value", "%n" },
}

--- org-odt-category-map-alist: { handle, od-variable, label-style, category }
M.CATEGORY_MAP = {
  { "__Table__", "Table", "value", "Table" },
  { "__Figure__", "Illustration", "value", "Figure" },
  { "__MathFormula__", "Text", "math-formula", "Equation" },
  { "__DvipngImage__", "Equation", "value", "Equation" },
  { "__Listing__", "Listing", "value", "Listing" },
}

--- org-odt-table-styles
M.TABLE_STYLES = {
  { "OrgEquation", "OrgEquation", { use_first_column_styles = true, use_last_column_styles = true } },
  { "TableWithHeaderRowAndColumn", "Custom", { use_first_row_styles = true, use_first_column_styles = true } },
  { "TableWithFirstRowandLastRow", "Custom", { use_first_row_styles = true, use_last_row_styles = true } },
  { "GriddedTable", "Custom", {} },
}

--- org-odt-convert-processes
M.CONVERT_PROCESSES = {
  { "LibreOffice", "soffice --headless --convert-to %f%x --outdir %d %i" },
  { "unoconv", "unoconv -f %f -o %d %i" },
}

--- org-odt-convert-capabilities: { class, input formats, { { fmt, ext, extra } } }
M.CONVERT_CAPABILITIES = {
  {
    "Text",
    { "odt", "ott", "doc", "rtf", "docx" },
    {
      { "pdf", "pdf" },
      { "odt", "odt" },
      { "rtf", "rtf" },
      { "ott", "ott" },
      { "doc", "doc", ':"MS Word 97"' },
      { "docx", "docx" },
      { "html", "html" },
    },
  },
  { "Web", { "html" }, { { "pdf", "pdf" }, { "odt", "odt" }, { "html", "html" } } },
  {
    "Spreadsheet",
    { "ods", "ots", "xls", "csv", "xlsx" },
    {
      { "pdf", "pdf" },
      { "ots", "ots" },
      { "html", "html" },
      { "csv", "csv" },
      { "ods", "ods" },
      { "xls", "xls" },
      { "xlsx", "xlsx" },
    },
  },
  {
    "Presentation",
    { "odp", "otp", "ppt", "pptx" },
    {
      { "pdf", "pdf" },
      { "swf", "swf" },
      { "odp", "odp" },
      { "otp", "otp" },
      { "ppt", "ppt" },
      { "pptx", "pptx" },
      { "odg", "odg" },
    },
  },
}

-- org-odt-default-image-sizes-alist and org-odt-max-image-size (cm)
local DEFAULT_IMAGE_SIZES = { ["as-char"] = { 5, 0.4 }, paragraph = { 5, 5 } }
local MAX_IMAGE_SIZE = { 17.0, 20.0 }

---------------------------------------------------------------------------
-- Per-export state (org-odt-automatic-styles, org-odt-object-counters,
-- org-odt-manifest-file-entries, embedded files...)
---------------------------------------------------------------------------

local function new_state()
  return {
    counters = {},
    table_styles = {},
    images = 0,
    formulas = 0,
    files = {}, -- { name, data } embedded in the package
    manifest = {}, -- { media-type, path, version? } in creation order
    src_styles = {}, -- htmlfontify-like styles for colorized source blocks
    src_style_order = {},
  }
end

local function state(info)
  if not info.odt_state then
    info.odt_state = new_state()
  end
  return info.odt_state
end

local function manifest_entry(info, media, path, version)
  local st = state(info)
  st.manifest[#st.manifest + 1] = { media, path, version }
end

--- org-odt-add-automatic-style: object name and (with props) style name.
local function add_automatic_style(info, object_type, props)
  local st = state(info)
  local n = (st.counters[object_type] or 0) + 1
  st.counters[object_type] = n
  local name = object_type .. n
  local style
  if props then
    style = "Org" .. name
    if object_type == "Table" then
      table.insert(st.table_styles, 1, { style, props })
    end
  end
  return name, style
end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------

--- org-odt--encode-tabs-and-spaces
local function encode_tabs_and_spaces(s)
  return (s:gsub("\t", "<text:tab/>"):gsub("  +", function(sp)
    return fmt(' <text:s text:c="%d"/>', #sp - 1)
  end))
end

--- org-odt--encode-plain-text
local function encode(text, no_whitespace_filling)
  text = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
  if no_whitespace_filling then
    return text
  end
  return encode_tabs_and_spaces(text)
end
M.encode_plain_text = encode

--- Unfill a string like `fill-region' with an infinite fill column: lines
--- of a paragraph are joined, runs of blanks become one space (two after
--- the end of a sentence when it had two or ended a line); leading and
--- trailing newlines and blank lines are kept.
function M.unfill(s)
  local lead = s:match("^\n*")
  local body = s:sub(#lead + 1)
  local tail = body:match("\n*$")
  body = body:sub(1, #body - #tail)
  local out = {}
  local pos = 1
  local function fill(seg)
    return (
      seg:gsub("()([ \t\n]+)", function(p, ws)
        local before = seg:sub(1, p - 1)
        if before:match("[%.%?!][%)%]}\"']*$") and (ws:find("\n", 1, true) or #ws >= 2) then
          return "  "
        end
        return " "
      end)
    )
  end
  while true do
    local a, b = body:find("\n[ \t]*\n[ \t\n]*", pos)
    if not a then
      out[#out + 1] = fill(body:sub(pos))
      break
    end
    out[#out + 1] = fill(body:sub(pos, a - 1))
    out[#out + 1] = body:sub(a, b)
    pos = b + 1
  end
  return lead .. table.concat(out) .. tail
end

local SPECIAL_STRINGS = {
  { "\\%-", "&#x00ad;" },
  { "%-%-%-([^%-])", "&#x2014;%1" },
  { "%-%-([^%-])", "&#x2013;%1" },
  { "%.%.%.", "&#x2026;" },
}

--- org-odt-plain-text
function M.plain_text(text, info, node)
  local out = encode(text, true)
  if info.with_smart_quotes and node then
    out = ox.activate_smart_quotes(out, "utf-8", info, node)
  end
  if info.with_special_strings then
    for _, p in ipairs(SPECIAL_STRINGS) do
      out = out:gsub(p[1], p[2])
    end
  end
  if info.preserve_breaks then
    out = out:gsub("\\\\[ \t]*\n", "<text:line-break/>"):gsub("[ \t]*\n", "<text:line-break/>")
  elseif nw(out) and not (node and element.lineage(node, "verse-block")) then
    local leading = out:match("^[ \t]+") or ""
    local trailing = #out > #leading and (out:match("[ \t]+$") or "") or ""
    out = leading .. M.unfill(out:sub(#leading + 1, #out - #trailing)) .. trailing
  end
  return out
end

local function strip_tags(s)
  return (s:gsub("<[^>]*>", ""))
end

---------------------------------------------------------------------------
-- Frames, targets, text boxes, sections
---------------------------------------------------------------------------

local function num(v)
  if type(v) == "number" then
    return v
  end
  return tonumber(v)
end

--- org-odt--frame
local function frame(info, text, width, height, style, extra, anchor, title, desc)
  width, height = num(width), num(height)
  local attrs = (width and fmt(' svg:width="%0.2fcm"', width) or "")
    .. (height and fmt(' svg:height="%0.2fcm"', height) or "")
    .. (extra or "")
    .. fmt(' text:anchor-type="%s"', anchor or "paragraph")
    .. fmt(' draw:name="%s"', (add_automatic_style(info, "Frame")))
  return fmt(
    '\n<draw:frame draw:style-name="%s"%s>\n%s\n</draw:frame>',
    style or "",
    attrs,
    text
      .. (title and fmt("<svg:title>%s</svg:title>", encode(title, true)) or "")
      .. (desc and fmt("<svg:desc>%s</svg:desc>", encode(desc, true)) or "")
  )
end

--- org-odt--target
local function target(text, id)
  if not id then
    return text
  end
  return fmt('\n<text:bookmark-start text:name="%s%s"/>', BOOKMARK_PREFIX, id)
    .. fmt('\n<text:bookmark text:name="%s"/>', id)
    .. text
    .. fmt('\n<text:bookmark-end text:name="%s%s"/>', BOOKMARK_PREFIX, id)
end

--- org-odt--textbox
local function textbox(info, text, width, height, style, extra, anchor)
  width, height = num(width), num(height)
  return frame(
    info,
    fmt(
      "\n<draw:text-box %s>%s\n</draw:text-box>",
      fmt(' fo:min-height="%0.2fcm"', height or 0.2) .. (not width and fmt(' fo:min-width="%0.2fcm"', 0.2) or ""),
      text
    ),
    width,
    nil,
    style,
    extra,
    anchor
  )
end

--- org-odt-format-section
local function format_section(info, text, style, name)
  local default = add_automatic_style(info, "Section")
  return fmt(
    '\n<text:section text:style-name="%s" %s>\n%s\n</text:section>',
    style,
    fmt('text:name="%s"', name or default),
    text
  )
end

local function span(style, text)
  return fmt('<text:span text:style-name="%s">%s</text:span>', style, text)
end

---------------------------------------------------------------------------
-- Headlines and table of contents
---------------------------------------------------------------------------

local function priority_string(p)
  return tostring(p)
end

--- org-odt-format-headline-default-function
function M.format_headline_default(todo, todo_type, priority, text, tags)
  local s = ""
  if todo then
    s = s .. span(todo_type == "done" and "OrgDone" or "OrgTodo", todo) .. " "
  end
  if priority then
    local p = priority_string(priority)
    s = s .. span("OrgPriority-" .. p, "[#" .. p .. "]") .. " "
  end
  s = s .. (text or "")
  if tags and #tags > 0 then
    local parts = {}
    for i, t in ipairs(tags) do
      parts[i] = span("OrgTag", t)
    end
    s = s .. "<text:tab/>" .. span("OrgTags", "[" .. table.concat(parts, " : ") .. "]")
  end
  return s
end

local function headline_numbers(h, info)
  local nums = ox.get_headline_number(h, info)
  if not nums then
    return nil
  end
  local parts = {}
  for i, n in ipairs(nums) do
    parts[i] = tostring(n)
  end
  return table.concat(parts, ".")
end

--- org-odt-format-headline--wrap
local function format_headline_wrap(h, backend, info, format_function)
  local function data(d)
    if backend then
      return ox.data_with_backend(d, backend, info)
    end
    return ox.data(d, info)
  end
  local section_number = ox.numbered_headline_p(h, info) and headline_numbers(h, info) or nil
  local todo = info.with_todo_keywords and h.todo_keyword and data(h.todo_keyword) or nil
  local todo_type = todo and h.todo_type or nil
  local priority = info.with_priority and h.priority or nil
  local text = data(h.title)
  local tags = info.with_tags and ox.get_tags(h, info) or nil
  if tags and #tags == 0 then
    tags = nil
  end
  local extra = {
    level = ox.get_relative_level(h, info),
    section_number = section_number,
    headline_label = ox.get_reference(h, info),
  }
  if format_function then
    return format_function(todo, todo_type, priority, text, tags, extra, info)
  end
  local f = info.odt_format_headline_function
  if type(f) == "function" then
    return f(todo, todo_type, priority, text, tags)
  end
  return M.format_headline_default(todo, todo_type, priority, text, tags)
end

--- org-odt-format-toc-headline
local function format_toc_headline(todo, _, priority, text, tags, extra, info)
  local s = extra.section_number and (extra.section_number .. ". ") or ""
  if todo then
    s = s .. span(info.todo_done and info.todo_done(todo) and "OrgDone" or "OrgTodo", todo) .. " "
  end
  if priority then
    local p = priority_string(priority)
    s = s .. span("OrgPriority-" .. p, "[#" .. p .. "]") .. " "
  end
  s = s .. (text or "")
  if tags then
    local parts = {}
    for i, t in ipairs(tags) do
      parts[i] = span("OrgTag", t)
    end
    s = s .. " " .. span("OrgTags", "[" .. table.concat(parts, " : ") .. "]")
  end
  return fmt('<text:a xlink:type="simple" xlink:href="#%s">%s</text:a>', extra.headline_label, s)
end

--- org-odt--format-toc
local function format_toc(title, entries, depth)
  local out = {
    '\n<text:table-of-content text:style-name="OrgIndexSection" text:protected="true" text:name="Table of Contents">\n',
    fmt('  <text:table-of-content-source text:outline-level="%d">', depth),
  }
  if title then
    out[#out + 1] = fmt(
      '\n    <text:index-title-template text:style-name="Contents_20_Heading">%s</text:index-title-template>\n',
      title
    )
  end
  for level = 1, 10 do
    out[#out + 1] = fmt(
      [[

      <text:table-of-content-entry-template text:outline-level="%d" text:style-name="Contents_20_%d">
       <text:index-entry-link-start text:style-name="Internet_20_link"/>
       <text:index-entry-chapter/>
       <text:index-entry-text/>
       <text:index-entry-link-end/>
      </text:table-of-content-entry-template>
]],
      level,
      level
    )
  end
  out[#out + 1] = "\n  </text:table-of-content-source>\n  <text:index-body>"
  if title then
    out[#out + 1] = fmt(
      [[

    <text:index-title text:style-name="Sect1" text:name="Table of Contents1_Head">
      <text:p text:style-name="Contents_20_Heading">%s</text:p>
    </text:index-title>
]],
      title
    )
  end
  out[#out + 1] = entries
  out[#out + 1] = "\n  </text:index-body>\n</text:table-of-content>"
  return table.concat(out)
end

--- org-odt-toc
function M.toc(depth, info, scope)
  local headlines = ox.collect_headlines(info, depth, scope)
  if #headlines == 0 then
    return nil
  end
  local backend = ox.toc_entry_backend("odt")
  local entries = {}
  for _, h in ipairs(headlines) do
    local entry = format_headline_wrap(h, backend, info, format_toc_headline)
    entries[#entries + 1] =
      fmt('\n<text:p text:style-name="%s">%s</text:p>', fmt("Contents_20_%d", ox.get_relative_level(h, info)), entry)
  end
  local title = not scope and ox.translate("Table of Contents", "utf-8", info) or nil
  return format_toc(title, table.concat(entries, "\n"), depth)
end

---------------------------------------------------------------------------
-- Labels and captions
---------------------------------------------------------------------------

local function category_map(info)
  local user = info.odt_category_map_alist
  local out = {}
  for _, e in ipairs(M.CATEGORY_MAP) do
    out[#out + 1] = e
  end
  if type(user) == "table" then
    for k, v in pairs(user) do
      local entry = type(k) == "string" and { k, v[1], v[2], v[3] } or v
      local replaced = false
      for i, e in ipairs(out) do
        if e[1] == entry[1] then
          out[i] = entry
          replaced = true
        end
      end
      if not replaced then
        out[#out + 1] = entry
      end
    end
  end
  return out
end

local function category_entry(info, handle)
  for _, e in ipairs(category_map(info)) do
    if e[1] == handle then
      return e
    end
  end
end

local function converted(x, kind)
  return x.odt_converted ~= nil and (not kind or x.odt_converted.kind == kind)
end

local function image_link_p(x, info)
  if x.type == "latex-fragment" then
    return converted(x, "image")
  end
  return x.type == "link" and ox.inline_image_p(x, info.odt_inline_image_rules)
end

local function formula_link_p(x, info)
  if x.type == "latex-fragment" then
    return converted(x, "mathml")
  end
  return x.type == "link" and ox.inline_image_p(x, info.odt_inline_formula_rules)
end

--- org-odt--standalone-link-p: a paragraph whose sole content is one link
--- (or converted LaTeX fragment) satisfying `link_pred`.
local function standalone_link_p(el, info, para_pred, link_pred)
  local p
  if el.type == "paragraph" then
    p = el
  elseif el.type == "link" or el.type == "latex-fragment" then
    if not link_pred or link_pred(el, info) then
      p = el.parent
    end
  end
  if not (p and p.type == "paragraph") then
    return false
  end
  if para_pred and not para_pred(p) then
    return false
  end
  local count = 0
  for _, x in ipairs(p.contents) do
    if not info.ignore[x] then
      if x.type == "plain-text" then
        if nw(x.value) then
          return false
        end
      elseif x.type == "link" or (x.type == "latex-fragment" and converted(x)) then
        if link_pred and not link_pred(x, info) then
          return false
        end
        count = count + 1
        if count > 1 then
          return false
        end
      else
        return false
      end
    end
  end
  return true
end
M.standalone_link_p = standalone_link_p

local function labelled(p)
  return p.caption ~= nil or p.name ~= nil
end

local PREDICATES = {
  __Table__ = function(el)
    return labelled(el)
  end,
  __Listing__ = function(el)
    return labelled(el)
  end,
  __Figure__ = function(el, info)
    return el.type == "paragraph" and standalone_link_p(el, info, labelled, image_link_p)
  end,
  __DvipngImage__ = function(el)
    return el.type == "latex-environment" and converted(el, "image") and labelled(el)
  end,
  __MathFormula__ = function(el, info)
    if el.type == "latex-environment" then
      return converted(el, "mathml") and labelled(el)
    end
    return el.type == "paragraph" and standalone_link_p(el, info, labelled, formula_link_p)
  end,
}

local TYPES = {
  __Table__ = { table = true },
  __Listing__ = { ["src-block"] = true },
  __Figure__ = { paragraph = true },
  __DvipngImage__ = { ["latex-environment"] = true },
  __MathFormula__ = { paragraph = true, ["latex-environment"] = true },
}

--- org-odt--enumerate: sequence number of `el` among the elements of
--- `types` satisfying `predicate`, prefixed with the number of the
--- enclosing numbered headline of level <= display outline level.
local function enumerate(el, info, predicate, types)
  local n = info.odt_display_outline_level or 2
  local scope
  local p = el.parent
  while p do
    if p.type == "headline" and ox.get_relative_level(p, info) <= n and ox.numbered_headline_p(p, info) then
      scope = p
      break
    end
    p = p.parent
  end
  local counter = 0
  local ordinal = element.map(scope or info.parse_tree, types or { [el.type] = true }, function(x)
    if not predicate or predicate(x, info) then
      counter = counter + 1
      if x == el then
        return counter
      end
    end
  end, { first_match = true, ignore = info.ignore })
  local prefix = scope and headline_numbers(scope, info)
  return (prefix and (prefix .. ".") or "") .. tostring(ordinal or 0)
end

local function default_category(el, info)
  local t = el.type
  if t == "table" then
    return "__Table__"
  elseif t == "src-block" then
    return "__Listing__"
  elseif t == "latex-environment" then
    if converted(el, "image") then
      return "__DvipngImage__"
    elseif converted(el, "mathml") then
      return "__MathFormula__"
    end
  elseif t == "paragraph" then
    if PREDICATES.__Figure__(el, info) then
      return "__Figure__"
    elseif PREDICATES.__MathFormula__(el, info) then
      return "__MathFormula__"
    end
  end
  error("Don't know how to format label for element type: " .. tostring(t), 0)
end

local function format_spec(s, spec)
  return (
    s:gsub("%%(%a)", function(c)
      local v = spec[c]
      if v == nil then
        return "%" .. c
      end
      return v
    end)
  )
end

--- org-odt-format-label: for "definition", { caption } (nil when `el` has
--- neither caption nor name); for "reference", the sequence reference.
local function format_label(el, info, op, category, label_style)
  local label = el.name and ox.get_reference(el, info)
  local caption = ox.get_caption(el)
  caption = caption and ox.data(caption, info) or nil
  if not (label or caption) then
    return nil
  end
  category = category or default_category(el, info)
  local entry = category_entry(info, category)
  local counter, cat = entry[2], entry[4]
  label_style = label_style or entry[3]
  local seqno = enumerate(el, info, PREDICATES[category], TYPES[category])
  cat = ox.translate(cat, "utf-8", info)
  local ls = LABEL_STYLES[label_style] or LABEL_STYLES.value
  local ref = label or ox.get_reference(el, info)
  if op == "definition" then
    return {
      (label and fmt('\n<text:bookmark text:name="%s"/>', label) or "")
        .. format_spec(ox.translate(ls[1], "utf-8", info), {
          e = cat,
          n = fmt(
            '<text:sequence text:ref-name="%s" text:name="%s" text:formula="ooow:%s+1" style:num-format="1">%s</text:sequence>',
            ref,
            counter,
            counter,
            seqno
          ),
          c = caption or "",
        }),
    }
  end
  return fmt(
    '<text:sequence-ref text:reference-format="%s" text:ref-name="%s">%s</text:sequence-ref>',
    ls[2],
    ref,
    format_spec(ls[3], { e = cat, n = seqno })
  )
end

---------------------------------------------------------------------------
-- Images and formulas
---------------------------------------------------------------------------

local MEDIA = { jpg = "jpeg", svg = "svg+xml", tif = "tiff" }

--- org-odt--copy-image-file: embed `path` as Images/NNNN.ext.
local function copy_image_file(info, path)
  local data = read_file(path, true)
  if not data then
    error("Cannot read image file " .. path, 0)
  end
  local st = state(info)
  local ext = (path:match("%.([%w]+)$") or "png"):lower()
  st.images = st.images + 1
  local name = fmt("Images/%04d.%s", st.images, ext)
  if st.images == 1 then
    manifest_entry(info, "", "Images/")
    table.insert(st.files, { name = "Images/" })
  end
  table.insert(st.files, { name = name, data = data })
  manifest_entry(info, "image/" .. (MEDIA[ext] or ext), name)
  return name
end

--- Pixel size of an image: PNG, GIF and JPEG headers, then ImageMagick's
--- identify, then the width/height of an SVG.
function M.image_pixel_size(path)
  local s = read_file(path, true)
  if not s then
    return nil
  end
  local function be16(i)
    local a, b = s:byte(i, i + 1)
    return a * 256 + b
  end
  if s:sub(1, 8) == "\137PNG\r\n\26\n" and #s >= 24 then
    return be16(17) * 65536 + be16(19), be16(21) * 65536 + be16(23)
  elseif s:sub(1, 4) == "GIF8" and #s >= 10 then
    local a, b, c, d = s:byte(7, 10)
    return a + b * 256, c + d * 256
  elseif s:sub(1, 2) == "\255\216" then
    local i = 3
    while i + 9 <= #s do
      if s:byte(i) ~= 255 then
        break
      end
      local marker = s:byte(i + 1)
      local len = be16(i + 2)
      if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
        return be16(i + 7), be16(i + 5)
      end
      i = i + 2 + len
    end
  end
  if vim.fn.executable("identify") == 1 then
    local res = vim.system({ "identify", "-format", "%w:%h", path }, { text = true }):wait()
    local w, h = (res.stdout or ""):match("(%d+):(%d+)")
    if w then
      return tonumber(w), tonumber(h)
    end
  end
  local svg = s:match("<svg[^>]*>")
  if svg then
    local w = tonumber(svg:match('%swidth="([%d%.]+)[p]?[x]?"'))
    local h = tonumber(svg:match('%sheight="([%d%.]+)[p]?[x]?"'))
    if not (w and h) then
      local vb = svg:match('viewBox="([^"]+)"')
      if vb then
        local nums = {}
        for n in vb:gmatch("[%-%d%.]+") do
          nums[#nums + 1] = tonumber(n)
        end
        w, h = nums[3], nums[4]
      end
    end
    if w and h then
      return w, h
    end
  end
  return nil
end

--- org-odt--image-size: { width, height } in cm.
local function image_size(file, info, user_width, user_height, scale, dpi, embed_as)
  dpi = dpi or info.odt_pixels_per_inch or 96
  if scale then
    user_width, user_height = nil, nil
  end
  local width, height
  if not (user_width and user_height) then
    local pw, ph = M.image_pixel_size(file)
    if pw and ph and pw > 0 and ph > 0 then
      width, height = pw / dpi * 2.54, ph / dpi * 2.54
    else
      local d = DEFAULT_IMAGE_SIZES[embed_as or "paragraph"] or DEFAULT_IMAGE_SIZES.paragraph
      width, height = d[1], d[2]
    end
  end
  if scale then
    width, height = width * scale, height * scale
  elseif user_width and user_height then
    width, height = user_width, user_height
  elseif user_height then
    width, height = user_height * (width / height), user_height
  elseif user_width then
    width, height = user_width, user_width * (height / width)
  end
  local mw, mh = MAX_IMAGE_SIZE[1], MAX_IMAGE_SIZE[2]
  if width > mw or height > mh then
    local s = math.min(mw / width, mh / height)
    width, height = width * s, height * s
  end
  return width, height
end

local FRAME_CFG = {
  ["As-CharImage"] = { { "OrgInlineImage", nil, "as-char" } },
  ParagraphImage = { { "OrgDisplayImage", nil, "paragraph" } },
  PageImage = { { "OrgPageImage", nil, "page" } },
  ["CaptionedAs-CharImage"] = {
    { "OrgCaptionedImage", ' style:rel-width="100%" style:rel-height="scale"', "paragraph" },
    { "OrgInlineImage", nil, "as-char" },
  },
  CaptionedParagraphImage = {
    { "OrgCaptionedImage", ' style:rel-width="100%" style:rel-height="scale"', "paragraph" },
    { "OrgImageCaptionFrame", nil, "paragraph" },
  },
  CaptionedPageImage = {
    { "OrgCaptionedImage", ' style:rel-width="100%" style:rel-height="scale"', "paragraph" },
    { "OrgPageImageCaptionFrame", nil, "page" },
  },
  InlineFormula = { { "OrgInlineFormula", nil, "as-char" } },
  DisplayFormula = { { "OrgDisplayFormula", nil, "as-char" } },
  CaptionedDisplayFormula = {
    { "OrgCaptionedFormula", nil, "paragraph" },
    { "OrgFormulaCaptionFrame", nil, "paragraph" },
  },
}

--- org-odt--render-image/formula
local function render_image_formula(info, key, href, width, height, captions, user, title, desc)
  local cfg = FRAME_CFG[key] or FRAME_CFG.ParagraphImage
  local inner, outer = cfg[1], cfg[2]
  local caption = captions and captions[1]
  local function merge(default, u)
    if not u then
      return default
    end
    return { u[1] or default[1], u[2] or default[2], u[3] or default[3] }
  end
  if not caption or not outer then
    inner = merge(inner, user)
    return frame(info, href, width, height, inner[1], inner[2], inner[3], title, desc)
  end
  outer = merge(outer, user)
  return textbox(
    info,
    fmt(
      '\n<text:p text:style-name="%s">%s</text:p>',
      "Illustration",
      frame(info, href, width, height, inner[1], inner[2], inner[3], title, desc) .. caption
    ),
    width,
    height,
    outer[1],
    outer[2],
    outer[3]
  )
end

local function input_dir(info)
  return info.input_file and vim.fn.fnamemodify(info.input_file, ":p:h") or vim.fn.getcwd()
end

local function expand_path(path, info)
  path = vim.fn.expand(path)
  if path:match("^/") or path:match("^%a:[/\\]") then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(input_dir(info) .. "/" .. path)
end

--- org-odt-link--inline-image: `node` is an image link or a LaTeX fragment
--- rendered as an image (`file` is then the rendered picture).
local function inline_image(node, info, file, title, desc)
  local src = file or expand_path(node.path, info)
  local href = fmt(
    '\n<draw:image xlink:href="%s" xlink:type="simple" xlink:show="embed" xlink:actuate="onLoad"/>',
    copy_image_file(info, src)
  )
  local attr_from = element.parent_element(node)
  local attrs = attr_from and ox.read_attribute("attr_odt", attr_from) or { _keys = {} }
  local anchor = attrs.anchor and attrs.anchor:lower()
  if anchor ~= "as-char" and anchor ~= "paragraph" and anchor ~= "page" then
    anchor = nil
  end
  local user = { anchor and attrs.style or nil, anchor and attrs.attributes or nil, anchor }
  local width, height =
    image_size(src, info, num(attrs.width), num(attrs.height or attrs.length), num(attrs.scale), nil, "paragraph")
  local standalone = standalone_link_p(node, info)
  local embed_as = standalone and "paragraph" or "as-char"
  local captions
  if standalone and node.parent and PREDICATES.__Figure__(node.parent, info) then
    captions = format_label(node.parent, info, "definition", "__Figure__")
  end
  -- the anchor of #+ATTR_ODT only overrides the frame parameters
  local entity = (captions and "Captioned" or "") .. (embed_as == "paragraph" and "Paragraph" or "As-Char") .. "Image"
  return render_image_formula(info, entity, href, width, height, captions, user, title, desc)
end

--- Embed a formula (MathML text or an .odf/.mml file) as Formula-NNNN/.
local function copy_formula(info, data)
  local st = state(info)
  st.formulas = st.formulas + 1
  local dir = fmt("Formula-%04d/", st.formulas)
  manifest_entry(info, "application/vnd.oasis.opendocument.formula", dir, "1.2")
  table.insert(st.files, { name = dir })
  table.insert(st.files, { name = dir .. "content.xml", data = data })
  manifest_entry(info, "text/xml", dir .. "content.xml")
  return dir
end

local function formula_file_data(path)
  local ext = (path:match("%.([%w]+)$") or ""):lower()
  if ext == "mathml" or ext == "mml" then
    local data = read_file(path, true)
    if not data then
      error("Cannot read formula file " .. path, 0)
    end
    return data
  elseif ext == "odf" then
    local data, err = zip.read(path, "content.xml")
    if not data then
      error(err, 0)
    end
    return data
  end
  error(path .. " is not a formula file", 0)
end

--- org-odt-link--inline-formula: `unit` is the paragraph (or LaTeX
--- environment) holding the formula when it is displayed.
local function inline_formula(info, data, standalone, unit, title, desc)
  local dir = copy_formula(info, data)
  local href =
    fmt('\n<draw:object %s xlink:href="%s" xlink:type="simple"/>', ' xlink:show="embed" xlink:actuate="onLoad"', dir)
  if not standalone then
    return render_image_formula(info, "InlineFormula", href, nil, nil, nil, nil, title, desc)
  end
  local captions = unit and labelled(unit) and format_label(unit, info, "definition", "__MathFormula__") or nil
  local equation = render_image_formula(info, "CaptionedDisplayFormula", href, nil, nil, captions, nil, title, desc)
  local label = unit and labelled(unit) and format_label(unit, info, "definition", "__MathFormula__", "math-label")
    or nil
  return equation .. "<text:tab/>" .. (label and label[1] or "")
end

---------------------------------------------------------------------------
-- LaTeX conversion (org-odt--translate-latex-fragments)
---------------------------------------------------------------------------

local function shellescape(s)
  return vim.fn.shellescape(s)
end

local function sh(cmd, cwd)
  local shell = vim.fn.has("win32") == 1 and { vim.o.shell, vim.o.shellcmdflag } or { "sh", "-c" }
  local ok, res = pcall(function()
    return vim.system(vim.list_extend(shell, { cmd }), { cwd = cwd, text = true }):wait(120000)
  end)
  if not ok then
    return { code = -1, stdout = "", stderr = tostring(res) }
  end
  return res
end

local function mathml_command()
  local c = ocfg()
  return c.latex_to_mathml_convert_command, c.latex_to_mathml_jar_file
end

--- org-format-latex-mathml-available-p
function M.mathml_available()
  local cmd, jar = mathml_command()
  if not nw(cmd) then
    return false
  end
  local exe = vim.split(vim.trim(cmd), "%s+")[1]
  if vim.fn.executable(exe) == 0 then
    return false
  end
  if cmd:find("%j", 1, true) then
    return jar ~= nil and vim.fn.filereadable(vim.fn.expand(jar)) == 1
  end
  return true
end

--- org-create-math-formula: MathML of a LaTeX fragment, or nil.
function M.latex_to_mathml(frag)
  local cmd, jar = mathml_command()
  if not nw(cmd) then
    return nil
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local tin, tout = dir .. "/ltxmathml-in", dir .. "/ltxmathml-out"
  local f = io.open(tin, "wb")
  if f then
    f:write(frag)
    f:close()
  end
  local full = format_spec(cmd, {
    j = jar and shellescape(vim.fn.fnamemodify(vim.fn.expand(jar), ":p")) or "",
    I = shellescape(tin),
    i = shellescape(frag),
    o = shellescape(tout),
  })
  local res = sh(full, dir)
  local out = read_file(tout) or ""
  vim.fn.delete(dir, "rf")
  local s = out:find('<math[^>]-xmlns="http://www.w3.org/1998/Math/MathML"[^>]->')
  local e
  if s then
    local p = s
    while true do
      local a, b = out:find("</math>", p, true)
      if not a then
        break
      end
      e, p = b, b + 1
    end
  end
  if not (s and e) then
    require("org.utils").warn("LaTeX to MathML conversion failed\n" .. (res.stdout or "") .. (res.stderr or ""))
    return nil
  end
  return '<?xml version="1.0" encoding="UTF-8"?>\n' .. out:sub(s, e)
end

--- Lisp printed form of a string (prin1-to-string).
local function prin1_string(s)
  if s == nil then
    return "nil"
  end
  return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
end

--- The MathML cache file of a fragment (org-format-latex-as-mathml):
--- <org file dir>/<latex_mathml_directory><file>-formula-<sha1>.mathml.
function M.mathml_cache_file(frag, info)
  local input = info.input_file
  if not input then
    return nil
  end
  local cmd = mathml_command()
  local dir = ocfg().latex_mathml_directory or "ltxmathml/"
  if dir ~= "" and not dir:match("/$") then
    dir = dir .. "/"
  end
  local prefix = dir .. vim.fn.fnamemodify(input, ":t:r")
  local absprefix = require("org.utils").is_absolute(prefix) and prefix
    or (vim.fn.fnamemodify(input, ":p:h") .. "/" .. prefix)
  local id = require("org.babel.sha1").hex("(" .. prin1_string(frag) .. " " .. prin1_string(cmd) .. ")")
  return absprefix .. "-formula-" .. id .. ".mathml"
end

--- org-format-latex-as-mathml: the MathML of a fragment, converted once and
--- kept in `export.odt.latex_mathml_directory` (org-latex-mathml-directory).
function M.latex_to_mathml_cached(frag, info)
  local file = M.mathml_cache_file(frag, info)
  if file and vim.uv.fs_stat(file) then
    return read_file(file)
  end
  local mathml = M.latex_to_mathml(frag)
  if mathml and file then
    vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
    local f = io.open(file, "wb")
    if f then
      f:write(mathml)
      f:close()
    end
  end
  return mathml
end

local LATEX_IMAGE_PACKAGES = [[
\usepackage[utf8]{inputenc}
\usepackage[T1]{fontenc}
\usepackage{graphicx}
\usepackage{amsmath}
\usepackage{amssymb}]]

local function latex_processes()
  local ok, images = pcall(require, "org.ui.images")
  local all = ok and vim.deepcopy(images.PROCESSES or {}) or {}
  local ui = (require("org.config").opts.ui or {}).latex_preview or {}
  for k, v in pairs(ui.processes or {}) do
    all[k] = v
  end
  return all, ok and images.DEFAULT_HEADER or nil
end

--- The spec of a LaTeX image process (org-preview-latex-process-alist
--- entry: dvipng, dvisvgm, imagemagick or a user process), or nil.
function M.latex_image_process(name)
  return type(name) == "string" and latex_processes()[name] or nil
end

--- Run a shell command (shell-command-to-string): stdout and stderr.
function M.shell_command_to_string(cmd, cwd)
  local res = sh(cmd, cwd)
  return (res.stdout or "") .. (res.stderr or "")
end

M.shellescape = shellescape
M.format_spec = format_spec

--- Programs of a LaTeX image process (org-preview-latex-process-alist)
--- are installed?
local function latex_process_available(name)
  local spec = latex_processes()[name]
  if not spec then
    return nil
  end
  for _, prog in ipairs(spec.programs or {}) do
    if vim.fn.executable(prog) == 0 then
      return false
    end
  end
  return true
end

--- Render a LaTeX fragment to a picture with `process` (org-create-formula-image).
function M.latex_to_image(frag, process, info)
  local all, default_header = latex_processes()
  local spec = all[process]
  if not spec then
    return nil
  end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local base = "orgtex"
  local header = (spec.latex_header or default_header or "\\documentclass{article}\n[DEFAULT-PACKAGES]\n[PACKAGES]")
    :gsub("%[N?O?%-?DEFAULT%-PACKAGES%]", function()
      return LATEX_IMAGE_PACKAGES
    end)
    :gsub("%[N?O?%-?PACKAGES%]", "")
  if nw(info.latex_header) then
    header = header .. "\n" .. info.latex_header
  end
  local doc = table.concat({
    header,
    "\\begin{document}",
    "\\definecolor{fg}{rgb}{0,0,0}%",
    "{\\color{fg}",
    frag,
    "}",
    "\\end{document}",
    "",
  }, "\n")
  local f = io.open(dir .. "/" .. base .. ".tex", "wb")
  if not f then
    return nil
  end
  f:write(doc)
  f:close()
  local dpi = 140 * (((require("org.config").opts.ui or {}).latex_preview or {}).scale or 1)
  local input = spec.image_input_type or "dvi"
  local ext = spec.image_output_type or "png"
  local function run(cmds, src, out_ext)
    for _, c in ipairs(cmds or {}) do
      local cmd = c:gsub("%%o%%b", shellescape(dir .. "/" .. base))
      cmd = format_spec(cmd, {
        b = base,
        f = shellescape(base .. "." .. src),
        F = shellescape(dir .. "/" .. base .. "." .. src),
        o = shellescape(dir .. "/"),
        O = shellescape(dir .. "/" .. base .. "." .. out_ext),
        D = tostring(math.floor(dpi)),
        S = fmt("%.3f", dpi / 140),
      })
      sh(cmd, dir)
    end
    return vim.uv.fs_stat(dir .. "/" .. base .. "." .. out_ext) ~= nil
  end
  if not run(spec.latex_compiler, "tex", input) then
    return nil
  end
  if not run(spec.transparent_image_converter or spec.image_converter, input, ext) then
    return nil
  end
  return dir .. "/" .. base .. "." .. ext
end

---------------------------------------------------------------------------
-- Source code
---------------------------------------------------------------------------

local function camel(name)
  local out = {}
  for part in name:gmatch("[^%.%-_]+") do
    out[#out + 1] = part:sub(1, 1):upper() .. part:sub(2)
  end
  return table.concat(out)
end

local function hl_color(group, key)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if ok and hl and hl[key] then
    return fmt("#%06x", hl[key])
  end
end

--- Register the text style of a highlight capture (org-odt-hfy-face-to-css).
local function src_style(info, capture)
  local st = state(info)
  local name = "OrgSrc" .. camel(capture)
  if st.src_styles[name] == nil then
    local color = hl_color("@" .. capture, "fg")
    if not color then
      st.src_styles[name] = false
      return nil
    end
    st.src_styles[name] = info.odt_create_custom_styles_for_srcblocks == false and ""
      or fmt(
        '\n<style:style style:name="%s" style:family="text">\n  <style:text-properties fo:color="%s"/>\n </style:style>',
        name,
        color
      )
    st.src_style_order[#st.src_style_order + 1] = name
  end
  return st.src_styles[name] and name or nil
end

local function hfy_quote(s)
  return (
    s:gsub('[<"&> \t]', {
      ["<"] = "&lt;",
      ['"'] = "&quot;",
      ["&"] = "&amp;",
      [">"] = "&gt;",
      [" "] = "<text:s/>",
      ["\t"] = "<text:tab/>",
    })
  )
end

--- Colorize `code` with tree-sitter (Emacs uses htmlfontify): one string
--- per line, or nil when the language has no parser/highlights query.
local function fontify_lines(code, lang, info)
  if not lang or not info.odt_fontify_srcblocks then
    return nil
  end
  local ft = vim.filetype.match({ filename = "x." .. lang }) or lang
  local tslang = vim.treesitter.language.get_lang(ft) or lang
  local ok, parser = pcall(vim.treesitter.get_string_parser, code, tslang)
  if not ok or not parser then
    return nil
  end
  local okq, query = pcall(vim.treesitter.query.get, tslang, "highlights")
  if not okq or not query then
    return nil
  end
  local okp, trees = pcall(function()
    return parser:parse()
  end)
  if not okp or not trees or not trees[1] then
    return nil
  end
  local lines = vim.split(code, "\n", { plain = true })
  local marks = {}
  for i = 1, #lines do
    marks[i] = {}
  end
  for id, node in query:iter_captures(trees[1]:root(), code, 0, -1) do
    local name = query.captures[id]
    if name and not name:match("^_") and name ~= "spell" and name ~= "nospell" and name ~= "conceal" then
      local sr, sc, er, ec = node:range()
      for r = sr, er do
        local l = lines[r + 1]
        if l then
          local from = r == sr and sc + 1 or 1
          local to = r == er and ec or #l
          for c = from, to do
            marks[r + 1][c] = name
          end
        end
      end
    end
  end
  local out = {}
  for i, l in ipairs(lines) do
    local parts = {}
    local c = 1
    while c <= #l do
      local cap = marks[i][c]
      local e = c
      while e < #l and marks[i][e + 1] == cap do
        e = e + 1
      end
      local text = hfy_quote(l:sub(c, e))
      local style = cap and src_style(info, cap)
      parts[#parts + 1] = style and span(style, text) or text
      c = e + 1
    end
    out[i] = table.concat(parts)
  end
  -- the default face gives the OrgSrcBlock paragraph style
  local st = state(info)
  if st.src_styles.OrgSrcBlock == nil then
    st.src_styles.OrgSrcBlock = info.odt_create_custom_styles_for_srcblocks == false and ""
      or fmt(SRC_BLOCK_PARAGRAPH_FORMAT, hl_color("Normal", "bg") or "#ffffff", hl_color("Normal", "fg") or "#000000")
    table.insert(st.src_style_order, 1, "OrgSrcBlock")
  end
  return out
end

local function split_nonempty_count(code)
  return #vim.split((code:gsub("^\n+", ""):gsub("\n+$", "")), "\n", { plain = true })
end

--- org-odt-do-format-code
local function do_format_code(code, info, lang, refs, retain_labels, num_start)
  local code_length = split_nonempty_count(code)
  local fontified = fontify_lines(code, lang, info)
  local par_style = fontified and "OrgSrcBlock" or "OrgFixedWidthBlock"
  local i = 0
  local out = ox.format_code(code, function(loc, line_num, ref)
    i = i + 1
    if i == code_length then
      par_style = par_style .. "LastLine"
    end
    local label = (ref and retain_labels) and fmt(" (%s)", ref) or ""
    if fontified then
      loc = (fontified[i] or hfy_quote(loc)) .. hfy_quote(label)
    else
      loc = encode(loc .. label)
    end
    if ref then
      loc = target(loc, "coderef-" .. ref)
    end
    loc = fmt('\n<text:p text:style-name="%s">%s</text:p>', par_style, loc)
    if line_num then
      return fmt("\n<text:list-item>%s\n</text:list-item>", loc)
    end
    return loc
  end, num_start, refs)
  if not num_start then
    return out
  end
  return fmt(
    '\n<text:list text:style-name="OrgSrcBlockNumberedLine"%s>%s</text:list>',
    num_start == 0 and ' text:continue-numbering="false"' or ' text:continue-numbering="true"',
    out
  )
end

--- org-odt-format-code
local function format_code(el, info)
  local code, refs = ox.unravel_code(el)
  return do_format_code(code, info, el.language, refs, el.retain_labels, ox.get_loc(el, info))
end

---------------------------------------------------------------------------
-- Timestamps
---------------------------------------------------------------------------

local function custom_formats()
  local c = require("org.config").opts
  local f = c.time_stamp_custom_formats or { "%m/%d/%y %a", "%m/%d/%y %a %H:%M" }
  local function strip(s)
    return (s:gsub("^[<%[]", ""):gsub("[>%]]$", ""))
  end
  return strip(f[1]), strip(f[2])
end

--- org-odt--format-timestamp
local function format_timestamp(ts, use_end, iso_only)
  local has_time = not ts or ox.timestamp_has_time_p(ts)
  local function ftime(f)
    if ts then
      return ox.format_timestamp(ts, f, use_end)
    end
    return os.date(f)
  end
  local iso = ftime(has_time and "%Y-%m-%dT%H:%M:%S" or "%Y-%m-%d")
  if iso_only then
    return iso
  end
  local style = has_time and "OrgDate2" or "OrgDate1"
  local d1, d2 = custom_formats()
  local date = ftime(has_time and d2 or d1)
  local rep = ""
  if ts and ts.repeater_type then
    rep = (({ ["catch-up"] = "++", restart = ".+", cumulate = "+" })[ts.repeater_type] or "")
      .. (ts.repeater_value and tostring(ts.repeater_value) or "")
      .. (({ hour = "h", day = "d", week = "w", month = "m", year = "y" })[ts.repeater_unit] or ts.repeater_unit or "")
  end
  return fmt(
    '<text:date text:date-value="%s" style:data-style-name="%s" text:fixed="true">%s</text:date>',
    iso,
    style,
    date
  ) .. (rep ~= "" and (" " .. rep) or "")
end

--- org-odt--build-date-styles
function M.build_date_styles(f, style)
  if not (f and style) then
    return ""
  end
  local alist = {
    A = '<number:day-of-week number:style="long"/>',
    B = '<number:month number:textual="true" number:style="long"/>',
    H = '<number:hours number:style="long"/>',
    M = '<number:minutes number:style="long"/>',
    S = '<number:seconds number:style="long"/>',
    V = "<number:week-of-year/>",
    Y = '<number:year number:style="long"/>',
    a = '<number:day-of-week number:style="short"/>',
    b = '<number:month number:textual="true" number:style="short"/>',
    d = '<number:day number:style="long"/>',
    e = '<number:day number:style="short"/>',
    h = '<number:month number:textual="true" number:style="short"/>',
    k = '<number:hours number:style="short"/>',
    m = '<number:month number:style="long"/>',
    p = "<number:am-pm/>",
    y = '<number:year number:style="short"/>',
  }
  local pre = {
    { "%%%d*N", "" },
    { "%%C", "Y" },
    { "%%D", "%%m/%%d/%%y" },
    { "%%G", "Y" },
    { "%%I", "%%H" },
    { "%%R", "%%H:%%M" },
    { "%%T", "%%H:%%M:%%S" },
    { "%%[UW]", "%%V" },
    { "%%Z", "" },
    { "%%c", "%%Y-%%M-%%d %%a %%H:%%M" },
    { "%%g", "%%y" },
    { "%%X", "%%x" },
    { "%%j", "" },
    { "%%l", "%%k" },
    { "%%s", "" },
    { "%%n", "<text:line-break/>" },
    { "%%r", "%%I:%%M:%%S %%p" },
    { "%%t", "<text:tab/>" },
    { "%%[uw]", "" },
    { "%%x", "%%Y-%%M-%%d %%a" },
    { "%%z", "" },
  }
  for _, p in ipairs(pre) do
    f = f:gsub(p[1], p[2])
  end
  local out = {}
  local pos = 1
  while true do
    local a, _, c = f:find("%%(%a)", pos)
    while a and not alist[c] do
      a, _, c = f:find("%%(%a)", a + 2)
    end
    if not a then
      break
    end
    local filler = f:sub(pos, a - 1)
    out[#out + 1] = "\n"
      .. (filler ~= "" and fmt("<number:text>%s</number:text>", encode(filler)) or "")
      .. "\n"
      .. alist[c]
    pos = a + 2
  end
  local filler = f:sub(pos)
  if filler ~= "" then
    out[#out + 1] = fmt("\n<number:text>%s</number:text>", encode(filler))
  end
  return fmt(
    '\n<number:date-style style:name="%s" %s>%s\n</number:date-style>',
    style,
    ' number:automatic-order="true" number:format-source="fixed"',
    table.concat(out)
  )
end

---------------------------------------------------------------------------
-- Transcoders
---------------------------------------------------------------------------

local T = {}

T.bold = function(_, contents)
  return span("Bold", contents or "")
end

T.italic = function(_, contents)
  return span("Emphasis", contents or "")
end

T.underline = function(_, contents)
  return span("Underline", contents or "")
end

T["strike-through"] = function(_, contents)
  return span("Strikethrough", contents or "")
end

T.subscript = function(_, contents)
  return span("OrgSubscript", contents or "")
end

T.superscript = function(_, contents)
  return span("OrgSuperscript", contents or "")
end

T.code = function(el)
  return span("OrgCode", encode(el.value))
end

T.verbatim = function(el)
  return span("OrgCode", encode(el.value))
end

T["statistics-cookie"] = function(el)
  return span("OrgCode", el.value)
end

--- Emacs signals an error ("FIXME") for inline source blocks; the code is
--- exported like `code` here.
T["inline-src-block"] = function(el)
  return span("OrgCode", encode(el.value))
end

T["center-block"] = function(_, contents)
  return contents
end

T["quote-block"] = function(_, contents)
  return contents
end

T["dynamic-block"] = function(_, contents)
  return contents
end

T.section = function(_, contents)
  return contents
end

T.drawer = function(el, contents, info)
  local f = info.odt_format_drawer_function
  if type(f) == "function" then
    return f(el.drawer_name, contents)
  end
  return contents
end

T.entity = function(el)
  return (entities[el.name] or {})[6] or ("\\" .. el.name)
end

T["line-break"] = function()
  return "<text:line-break/>"
end

T["horizontal-rule"] = function()
  return fmt('\n<text:p text:style-name="%s">%s</text:p>', "Horizontal_20_Line", "")
end

T.timestamp = function(el, _, info)
  local t = el.ts_type
  if not info.odt_use_date_fields then
    local value = M.plain_text(ox.timestamp_translate(el), info)
    if t == "active" or t == "active-range" then
      return span("OrgActiveTimestamp", value)
    elseif t == "inactive" or t == "inactive-range" then
      return span("OrgInactiveTimestamp", value)
    end
    return value
  end
  if t == "active" then
    return span("OrgActiveTimestamp", fmt("&lt;%s&gt;", format_timestamp(el)))
  elseif t == "inactive" then
    return span("OrgInactiveTimestamp", fmt("[%s]", format_timestamp(el)))
  elseif t == "active-range" then
    return span(
      "OrgActiveTimestamp",
      fmt("&lt;%s&gt;&#x2013;&lt;%s&gt;", format_timestamp(el), format_timestamp(el, true))
    )
  elseif t == "inactive-range" then
    return span("OrgInactiveTimestamp", fmt("[%s]&#x2013;[%s]", format_timestamp(el), format_timestamp(el, true)))
  end
  return span("OrgDiaryTimestamp", M.plain_text(ox.timestamp_translate(el), info))
end

T.clock = function(el, _, info)
  local nxt = ox.get_next_element(el, info)
  return fmt(
    '\n<text:p text:style-name="%s">%s</text:p>',
    (nxt and nxt.type == "clock") and "OrgClock" or "OrgClockLastLine",
    span("OrgClockKeyword", "CLOCK:")
      .. T.timestamp(el.value, nil, info)
      .. (el.duration and fmt(" (%s)", el.duration) or "")
  )
end

T.planning = function(el, _, info)
  local s = ""
  for _, kv in ipairs({
    { "OrgClosedKeyword", "CLOSED:", el.closed },
    { "OrgDeadlineKeyword", "DEADLINE:", el.deadline },
    { "OrgScheduledKeyword", "SCHEDULED:", el.scheduled },
  }) do
    if kv[3] then
      s = s .. span(kv[1], kv[2]) .. T.timestamp(kv[3], nil, info)
    end
  end
  return fmt('\n<text:p text:style-name="%s">%s</text:p>', "OrgPlanning", s)
end

T["example-block"] = function(el, _, info)
  return format_code(el, info)
end

T["fixed-width"] = function(el, _, info)
  return do_format_code(el.value, info)
end

T["export-snippet"] = function(el)
  local tr = (require("org.config").opts.export or {}).snippet_translation or {}
  if (tr[el.back_end] or el.back_end) == "odt" then
    return el.value
  end
end

T["export-block"] = function(el)
  if el.back_end_type == "ODT" then
    return table.concat(element.remove_indentation(vim.split((el.value:gsub("\n$", "")), "\n", { plain = true })), "\n")
      .. "\n"
  end
end

T.keyword = function(el, _, info)
  local key, value = el.key, el.value or ""
  if key == "ODT" then
    return value
  elseif key == "TOC" then
    local low = value:lower()
    if low:match("%f[%w]headlines%f[%W]") then
      local depth = tonumber(value:match("%f[%d](%d+)%f[%D]")) or info.headline_levels
      local scope
      local tgt = value:match(':target +(".-")') or value:match(":target +(%S+)")
      if tgt then
        scope = ox.resolve_link((tgt:gsub('^"(.*)"$', "%1")), info)
      elseif low:match("%f[%w]local%f[%W]") then
        scope = el
      end
      return M.toc(depth, info, scope)
    end
  end
end

--- org-odt--checkbox
local function checkbox(item)
  local c = item.checkbox
  if not c then
    return ""
  end
  return span("OrgCode", ({ on = "[&#x2713;] ", off = "[ ] ", trans = "[-] " })[c] or "")
end

--- org-odt--paragraph-style
local function paragraph_style(el)
  local p = element.lineage(el, { ["center-block"] = true, ["quote-block"] = true, section = true })
  if p and p.type == "center-block" then
    return "centered"
  elseif p and p.type == "quote-block" then
    return "quoted"
  end
end

--- org-odt--format-paragraph
local function format_paragraph(el, contents, info, default, center, quote)
  local style = paragraph_style(el)
  local parent = el.parent
  local box = ""
  if parent and parent.type == "item" and not ox.get_previous_element(el, info) then
    box = checkbox(parent)
  end
  return fmt(
    '\n<text:p text:style-name="%s">%s</text:p>',
    style == "quoted" and quote or style == "centered" and center or default,
    box .. (contents or "")
  )
end

T.paragraph = function(el, contents, info)
  return format_paragraph(el, contents, info, el.odt_style or "Text_20_body", "OrgCenter", "Quotations")
end

T["verse-block"] = function(_, contents)
  local lines = vim.split(contents or "", "\n", { plain = true })
  for i, l in ipairs(lines) do
    l = l:gsub("<text:line%-break/>[ \t]*$", ""):gsub("[ \t]+$", "")
    lines[i] = l:gsub("^[ \t]+", encode_tabs_and_spaces) .. "<text:line-break/>"
  end
  return fmt('\n<text:p text:style-name="OrgVerse">%s</text:p>', table.concat(lines))
end

T["property-drawer"] = function(_, contents)
  if nw(contents) then
    return fmt('<text:p text:style-name="OrgFixedWidthBlock">%s</text:p>', contents)
  end
end

T["node-property"] = function(el)
  return encode(fmt("%s:%s", el.key, el.value and (" " .. el.value) or ""))
end

T["plain-text"] = function(text, info, node)
  return M.plain_text(text, info, node)
end

T["radio-target"] = function(el, text, info)
  return target(text or "", ox.get_reference(el, info))
end

T.target = function(el, _, info)
  return target("", ox.get_reference(el, info))
end

T["footnote-reference"] = function(el, _, info)
  local prev = ox.get_previous_element(el, info)
  local sep = (prev and prev.type == "footnote-reference") and span("OrgSuperscript", ",") or ""
  local n = ox.get_footnote_number(el, info, nil, true)
  if not ox.footnote_first_reference_p(el, info, nil, true) then
    return sep
      .. span(
        "OrgSuperscript",
        fmt(
          '<text:note-ref text:note-class="footnote" text:reference-format="text" text:ref-name="fn%d">%d</text:note-ref>',
          n,
          n
        )
      )
  end
  local raw = ox.get_footnote_definition(el, info)
  local backend = ox.create_backend("odt", {
    paragraph = function(p, c, i)
      return format_paragraph(p, c, i, "Footnote", "OrgFootnoteCenter", "OrgFootnoteQuotations")
    end,
  })
  local def = trim(ox.data_with_backend(raw, backend, info))
  local first = raw and raw[1]
  if not (first and element.ELEMENTS[first.type]) then
    def = fmt('\n<text:p text:style-name="Footnote">%s</text:p>', def)
  end
  return sep
    .. fmt(
      '<text:note text:id="%s" text:note-class="%s">%s</text:note>',
      "fn" .. n,
      "footnote",
      fmt("<text:note-citation>%d</text:note-citation>", n) .. fmt("<text:note-body>%s</text:note-body>", def)
    )
end

T.headline = function(el, contents, info)
  if el.footnote_section_p then
    return nil
  end
  local full = format_headline_wrap(el, nil, info)
  local level = ox.get_relative_level(el, info)
  local numbered = ox.numbered_headline_p(el, info)
  local id = ox.get_reference(el, info)
  local extra = (el.props and el.props.ID) and target("", ID_PREFIX .. el.props.ID) or ""
  local anchored = target(full, id)
  contents = contents or ""
  if ox.low_level_p(el, info) then
    local open = ""
    if ox.first_sibling_p(el, info) then
      local parent = element.lineage(el, "headline")
      open = fmt(
        '\n<text:list text:style-name="%s" %s>',
        numbered and "OrgNumberedList" or "OrgBulletedList",
        fmt('text:continue-numbering="%s"', (parent and ox.low_level_p(parent, info)) and "true" or "false")
      )
    end
    local has_table = false
    for _, c in ipairs(el.contents) do
      if c.type == "section" then
        for _, x in ipairs(c.contents) do
          if x.type == "table" then
            has_table = true
          end
        end
        break
      end
    end
    return open
      .. fmt(
        "\n<text:list-item>\n%s\n%s",
        fmt('\n<text:p text:style-name="%s">%s</text:p>', "Text_20_body", extra .. anchored) .. contents,
        has_table and "</text:list-header>" or "</text:list-item>"
      )
      .. (ox.last_sibling_p(el, info) and "</text:list>" or "")
  end
  return fmt(
    '\n<text:h text:style-name="%s" text:outline-level="%s" text:is-list-header="%s">%s</text:h>',
    fmt("Heading_20_%s%s", level, numbered and "" or "_unnumbered"),
    level,
    numbered and "false" or "true",
    extra .. anchored
  ) .. contents
end

--- org-odt-format-inlinetask-default-function
function M.format_inlinetask_default(todo, todo_type, priority, name, tags, contents, info)
  return fmt(
    '\n<text:p text:style-name="%s">%s</text:p>',
    "Text_20_body",
    textbox(
      info,
      fmt(
        '\n<text:p text:style-name="%s">%s</text:p>',
        "OrgInlineTaskHeading",
        M.format_headline_default(todo, todo_type, priority, name, tags)
      ) .. (contents or ""),
      nil,
      nil,
      "OrgInlineTaskFrame",
      ' style:rel-width="100%"'
    )
  )
end

T.inlinetask = function(el, contents, info)
  local todo = info.with_todo_keywords and el.todo_keyword and ox.data(el.todo_keyword, info) or nil
  local todo_type = todo and el.todo_type or nil
  local priority = info.with_priority and el.priority or nil
  local text = ox.data(el.title, info)
  local tags = info.with_tags and ox.get_tags(el, info) or nil
  if tags and #tags == 0 then
    tags = nil
  end
  local f = info.odt_format_inlinetask_function
  if type(f) == "function" then
    return f(todo, todo_type, priority, text, tags, contents)
  end
  return M.format_inlinetask_default(todo, todo_type, priority, text, tags, contents, info)
end

local LIST_STYLES = {
  ordered = "OrgNumberedList",
  unordered = "OrgBulletedList",
  ["descriptive-1"] = "OrgDescriptionList",
  ["descriptive-2"] = "OrgDescriptionList",
  descriptive = "OrgDescriptionList",
}

T["plain-list"] = function(el, contents)
  local parent = el.parent
  return fmt(
    '\n<text:list text:style-name="%s" %s>\n%s</text:list>',
    LIST_STYLES[el.list_type] or "OrgBulletedList",
    fmt('text:continue-numbering="%s"', (parent and parent.type == "item") and "true" or "false"),
    contents or ""
  )
end

T.item = function(el, contents, info)
  local has_table = element.map(el.contents, "table", function(x)
    return x
  end, { first_match = true, no_recursion = { ["plain-list"] = true }, ignore = info.ignore })
  return fmt(
    "\n<text:list-item%s>\n%s\n%s",
    el.counter and fmt(' text:start-value="%s"', el.counter) or "",
    contents or "",
    has_table and "</text:list-header>" or "</text:list-item>"
  )
end

T["special-block"] = function(el, contents, info)
  local btype = el.block_type
  local attrs = ox.read_attribute("attr_odt", el)
  if btype == "annotation" then
    local author = attrs.author
    if not author and info.author then
      author = nw(ox.data(info.author, info))
    end
    local date = attrs.date
    if not date and type(info.date) == "table" then
      date = info.date[1]
    end
    local d
    if type(date) == "table" and date.type == "timestamp" then
      d = format_timestamp(date, nil, true)
    elseif type(date) == "table" and date.type == "plain-text" then
      d = date.value
    elseif type(date) == "string" then
      d = date
    end
    return fmt(
      "\n<text:p>%s</text:p>",
      fmt(
        "<office:annotation>\n%s\n</office:annotation>",
        (author and fmt("<dc:creator>%s</dc:creator>", author) or "")
          .. (d and fmt("<dc:date>%s</dc:date>", d) or "")
          .. (contents or "")
      )
    )
  elseif btype == "textbox" then
    return fmt(
      '\n<text:p text:style-name="%s">%s</text:p>',
      "Text_20_body",
      textbox(info, contents or "", attrs.width, attrs.height, attrs.style, attrs.extra, attrs.anchor)
    )
  end
  return contents
end

T["src-block"] = function(el, _, info)
  local attrs = ox.read_attribute("attr_odt", el)
  local caption = format_label(el, info, "definition")
  local code = format_code(el, info)
  if attrs.textbox then
    code = fmt('\n<text:p text:style-name="%s">%s</text:p>', "Text_20_body", textbox(info, code))
  end
  return (caption and fmt('\n<text:p text:style-name="%s">%s</text:p>', "Listing", caption[1]) or "") .. code
end

T["latex-environment"] = function(el, _, info)
  local conv = el.odt_converted
  if conv then
    local body
    local title, desc = "Latex-Environment", el.value
    if conv.kind == "mathml" then
      body = inline_formula(info, conv.data, true, el, title, desc)
    else
      local width, height = image_size(conv.data, info, nil, nil, nil, nil, "paragraph")
      local href = fmt(
        '\n<draw:image xlink:href="%s" xlink:type="simple" xlink:show="embed" xlink:actuate="onLoad"/>',
        copy_image_file(info, conv.data)
      )
      local captions = labelled(el) and format_label(el, info, "definition", "__DvipngImage__") or nil
      body = render_image_formula(
        info,
        (captions and "Captioned" or "") .. "ParagraphImage",
        href,
        width,
        height,
        captions,
        nil,
        title,
        desc
      )
    end
    local style = paragraph_style(el)
    return fmt(
      '\n<text:p text:style-name="%s">%s</text:p>',
      style == "quoted" and "Quotations" or style == "centered" and "OrgCenter" or "OrgFormula",
      body
    )
  end
  local frag = table.concat(element.remove_indentation(vim.split(el.value, "\n", { plain = true })), "\n")
  return do_format_code(frag, info)
end

T["latex-fragment"] = function(el, _, info)
  local conv = el.odt_converted
  if conv then
    -- like Emacs, the frame of a fragment alone in its paragraph has no
    -- title/description (they come from the paragraph, which replaces nothing)
    local standalone = standalone_link_p(el, info)
    local title = not standalone and "Latex-Fragment" or nil
    local desc = not standalone and el.value or nil
    if conv.kind == "mathml" then
      return inline_formula(info, conv.data, standalone, el.parent, title, desc)
    end
    return inline_image(el, info, conv.data, title, desc)
  end
  return span("OrgCode", encode(el.value, true))
end

--- org-odt-link--infer-description
local function infer_description(dest, info)
  local label
  if dest.type == "headline" or dest.type == "target" then
    label = ox.get_reference(dest, info)
  else
    return nil
  end
  local genealogy = {}
  local p = dest.parent
  while p do
    genealogy[#genealogy + 1] = p
    p = p.parent
  end
  local data = {}
  for i = #genealogy, 1, -1 do
    data[#data + 1] = genealogy[i]
  end
  -- item numbers of the list items holding the destination
  local item_numbers = {}
  local start
  for i, x in ipairs(data) do
    if x.type == "plain-list" then
      start = i
      break
    end
  end
  if start then
    local i = start
    while data[i] and data[i].type == "plain-list" do
      local item = data[i + 1]
      if not item then
        break
      end
      if data[i].list_type == "ordered" then
        item_numbers[#item_numbers + 1] = 1 + #(ox.get_previous_element(item, info, true) or {})
      else
        item_numbers[#item_numbers + 1] = false
      end
      i = i + 2
    end
  end
  local listified = {}
  local lstart
  for i, x in ipairs(data) do
    if x.type == "headline" and ox.low_level_p(x, info) then
      lstart = i
      break
    end
  end
  if lstart then
    for i = lstart, #data do
      local x = data[i]
      if x.type == "headline" then
        if ox.numbered_headline_p(x, info) then
          listified[#listified + 1] = 1 + #(ox.get_previous_element(x, info, true) or {})
        else
          listified[#listified + 1] = false
        end
      end
    end
  end
  local nums = vim.list_extend(listified, item_numbers)
  if #nums > 0 and not vim.tbl_contains(nums, false) then
    local parts = {}
    for i, n in ipairs(nums) do
      parts[i] = tostring(n) .. "."
    end
    return fmt(
      '<text:bookmark-ref text:reference-format="number-all-superior" text:ref-name="%s">%s</text:bookmark-ref>',
      label,
      table.concat(parts)
    )
  end
  local chain = { dest }
  vim.list_extend(chain, genealogy)
  if ox.numbered_headline_p(dest, info) then
    for _, x in ipairs(chain) do
      if x.type == "headline" and not ox.low_level_p(x, info) and ox.numbered_headline_p(x, info) then
        return fmt(
          '<text:bookmark-ref text:reference-format="chapter" text:ref-name="%s%s">%s</text:bookmark-ref>',
          BOOKMARK_PREFIX,
          label,
          headline_numbers(x, info) or ""
        )
      end
    end
  end
  for _, x in ipairs(chain) do
    if x.type == "headline" and not ox.low_level_p(x, info) then
      return fmt(
        '<text:bookmark-ref text:reference-format="text" text:ref-name="%s%s">%s</text:bookmark-ref>',
        BOOKMARK_PREFIX,
        label,
        ox.data(x.title, info)
      )
    end
  end
  return nil
end

local function ordinal_string(n)
  if type(n) == "table" then
    local parts = {}
    for i, x in ipairs(n) do
      parts[i] = tostring(x)
    end
    return "(" .. table.concat(parts, " ") .. ")"
  end
  return n and tostring(n) or ""
end

T.link = function(el, desc, info)
  local ltype = el.link_type
  local raw = el.path or ""
  if desc == "" then
    desc = nil
  end
  local imagep = ox.inline_image_p(el, info.odt_inline_image_rules)
  local path
  if ltype == "file" then
    local uri = ox.file_uri(raw)
    path = uri:match("^file://") and uri or ("../" .. uri)
  else
    path = ltype .. ":" .. raw
  end
  path = path:gsub("&", "&amp;")
  raw = raw:gsub("&", "&amp;")
  local custom = ox.custom_protocol_maybe(el, desc, "odt", info)
  if custom then
    return custom
  end
  if not desc and imagep then
    return inline_image(el, info)
  end
  if not desc and ox.inline_image_p(el, info.odt_inline_formula_rules) then
    local unit = el.parent and el.parent.type == "paragraph" and el.parent or nil
    return inline_formula(info, formula_file_data(expand_path(el.path, info)), standalone_link_p(el, info), unit)
  end
  if ltype == "radio" then
    local dest = ox.resolve_radio_link(el, info)
    if not dest then
      return desc
    end
    return fmt(
      '<text:bookmark-ref text:reference-format="text" text:ref-name="%s%s">%s</text:bookmark-ref>',
      BOOKMARK_PREFIX,
      ox.get_reference(dest, info),
      desc or ""
    )
  end
  if ltype == "custom-id" or ltype == "fuzzy" or ltype == "id" then
    local dest = ltype == "fuzzy" and ox.resolve_fuzzy_link(el, info) or ox.resolve_id_link(el, info)
    if dest.type == "headline" then
      if not desc then
        return infer_description(dest, info) or ox.data(dest.title, info)
      end
      return fmt('<text:a xlink:type="simple" xlink:href="#%s">%s</text:a>', ox.get_reference(dest, info), desc)
    elseif dest.type == "target" then
      return fmt(
        '<text:a xlink:type="simple" xlink:href="#%s">%s</text:a>',
        ox.get_reference(dest, info),
        desc or ordinal_string(ox.get_ordinal(dest, info))
      )
    elseif dest.type == "plain-text" then
      local file_link = setmetatable(
        { link_type = "file", path = dest.value, raw_link = "file:" .. dest.value },
        { __index = el }
      )
      return T.link(file_link, desc or "", info)
    end
    local ok, ref = pcall(format_label, dest, info, "reference")
    if not ok or not ref then
      local inferred = infer_description(dest, info)
      if inferred then
        return inferred
      end
      return fmt(
        '<text:a xlink:type="simple" xlink:href="#%s">%s</text:a>',
        ox.get_reference(dest, info),
        desc or encode(dest.name or raw)
      )
    elseif not desc then
      return ref
    end
    return fmt('<text:a xlink:type="simple" xlink:href="#%s">%s</text:a>', ox.get_reference(dest, info), desc)
  end
  if ltype == "coderef" then
    local line = ox.resolve_coderef(el.path, info)
    return format_spec(ox.get_coderef_format(el.path, desc), {
      s = fmt(
        '<text:bookmark-ref text:reference-format="number" text:ref-name="%scoderef-%s">%s</text:bookmark-ref>',
        BOOKMARK_PREFIX,
        raw,
        tostring(line)
      ),
    })
  end
  if desc then
    local c = el.contents
    if #c == 1 and c[1].type == "link" and ox.inline_image_p(c[1], info.odt_inline_image_rules) then
      return fmt('\n<draw:a xlink:type="simple" xlink:href="%s">\n%s\n</draw:a>', path, desc)
    end
    return fmt('<text:a xlink:type="simple" xlink:href="%s">%s</text:a>', path, desc)
  end
  return fmt('<text:a xlink:type="simple" xlink:href="%s">%s</text:a>', path, path)
end

---------------------------------------------------------------------------
-- Tables
---------------------------------------------------------------------------

local function unquote(s)
  if type(s) == "string" then
    return (s:gsub('^"(.*)"$', "%1"))
  end
  return s
end

--- org-odt-table-style-spec: the entry of `odt_table_styles` named by the
--- :style attribute of the table enclosing `el` (like Emacs, a table itself
--- only gets the automatic style).
local function table_style_spec(el, info)
  local tbl = element.lineage(el, "table")
  if not tbl then
    return nil
  end
  local style = ox.read_attribute("attr_odt", tbl, "style")
  if not style then
    return nil
  end
  for _, spec in ipairs(info.odt_table_styles or {}) do
    if spec[1] == style then
      return spec
    end
  end
end

--- org-odt-get-table-cell-styles
local function table_cell_styles(cell, info)
  local spec = table_style_spec(cell, info)
  if not spec then
    return nil
  end
  local r, c = ox.table_cell_address(cell, info)
  local rows, cols = ox.table_dimensions(element.lineage(cell, "table"), info)
  local sel = spec[3] or {}
  local function on(k)
    return sel[k] or sel[(k:gsub("_", "-"))]
  end
  local ctype = ""
  if on("use_first_column_styles") and c == 0 then
    ctype = "FirstColumn"
  elseif on("use_last_column_styles") and c + 1 == cols then
    ctype = "LastColumn"
  elseif on("use_first_row_styles") and r == 0 then
    ctype = "FirstRow"
  elseif on("use_last_row_styles") and r + 1 == rows then
    ctype = "LastRow"
  elseif on("use_banding_rows_styles") and r % 2 == 1 then
    ctype = "EvenRow"
  elseif on("use_banding_rows_styles") and r % 2 == 0 then
    ctype = "OddRow"
  elseif on("use_banding_columns_styles") and c % 2 == 1 then
    ctype = "EvenColumn"
  elseif on("use_banding_columns_styles") and c % 2 == 0 then
    ctype = "OddColumn"
  end
  return spec[2] .. ctype
end

T["table-cell"] = function(el, contents, info)
  local r, c = ox.table_cell_address(el, info)
  r, c = r or 0, c or 0
  local span_n = ox.table_cell_width(el, info) or 0
  local row = el.parent
  local tbl = element.lineage(el, "table")
  local custom = table_cell_styles(el, info)
  local pstyle
  if custom then
    pstyle = custom .. "TableParagraph"
  else
    local kind = "OrgTableContents"
    if ox.table_row_group(row, info) == 1 and ox.table_has_header_p(tbl, info) then
      kind = "OrgTableHeading"
    else
      local cols = ox.read_attribute("attr_odt", tbl, "header-columns")
      local hc = cols and (tonumber(cols) or (cols ~= "nil" and true)) or nil
      local limit = type(hc) == "number" and (hc - 1) or (hc and 0 or -1)
      if c <= limit then
        kind = "OrgTableHeading"
      end
    end
    local align = ox.table_cell_alignment(el, info) or "left"
    pstyle = kind .. align:sub(1, 1):upper() .. align:sub(2)
  end
  local cell_style = custom and (custom .. "TableCell")
    or (
      "OrgTblCell"
      .. ((ox.table_row_starts_rowgroup_p(row, info) or r == 0) and "T" or "")
      .. (ox.table_row_ends_rowgroup_p(row, info) and "B" or "")
      .. ((ox.table_cell_starts_colgroup_p(el, info) and c ~= 0) and "L" or "")
    )
  local attrs = fmt(' table:style-name="%s"', cell_style)
    .. (span_n > 0 and fmt(' table:number-columns-spanned="%d"', span_n + 1) or "")
  contents = contents or ""
  local first = el.contents[1]
  local body = (first and element.ELEMENTS[first.type]) and contents
    or fmt('\n<text:p text:style-name="%s">%s</text:p>', pstyle, contents)
  return fmt("\n<table:table-cell%s>\n%s\n</table:table-cell>", attrs, body)
    .. string.rep("\n<table:covered-table-cell/>", span_n)
    .. "\n"
end

T["table-row"] = function(el, contents, info)
  if el.row_type ~= "standard" then
    return nil
  end
  local tags
  if ox.table_row_group(el, info) == 1 and ox.table_has_header_p(element.lineage(el, "table"), info) then
    tags = { "\n<table:table-header-rows>", "\n</table:table-header-rows>" }
  else
    tags = { "\n<table:table-rows>", "\n</table:table-rows>" }
  end
  return (ox.table_row_starts_rowgroup_p(el, info) and tags[1] or "")
    .. fmt("\n<table:table-row>\n%s\n</table:table-row>", contents or "")
    .. (ox.table_row_ends_rowgroup_p(el, info) and tags[2] or "")
end

local function first_row_data_cells(tbl, info)
  for _, r in ipairs(tbl.contents) do
    if r.row_type ~= "rule" and not info.ignore[r] then
      local cells = r.contents
      if ox.table_has_special_column_p(tbl) then
        cells = vim.list_slice(cells, 2)
      end
      return cells
    end
  end
  return {}
end

--- org-odt--table
local function odt_table(el, contents, info)
  if el.table_type == "table.el" then
    require("org.utils").warn(
      "(ox-odt): Found table.el-type table in the source Org file."
        .. "  table.el doesn't support export to ODT format."
        .. "  Stripping the table from export."
    )
    return nil
  end
  local captions = format_label(el, info, "definition")
  local attrs = ox.read_attribute("attr_odt", el)
  local spec = table_style_spec(el, info)
  local custom = spec and spec[2]
  local cols = {}
  for _, cell in ipairs(first_row_data_cells(el, info)) do
    local width = 1 + (ox.table_cell_width(cell, info) or 0)
    local col = fmt('\n<table:table-column table:style-name="%s"/>', (custom or "OrgTable") .. "Column")
    cols[#cols + 1] = string.rep(col, width)
  end
  local props
  if #attrs._keys > 0 then
    props = attrs
  end
  local _, auto_style = add_automatic_style(info, "Table", props)
  return (captions and fmt('\n<text:p text:style-name="%s">%s</text:p>', "Table", captions[1]) or "")
    .. fmt('\n<table:table table:style-name="%s"%s>', custom or auto_style or "OrgTable", "")
    .. table.concat(cols, "\n")
    .. "\n"
    .. (contents or "")
    .. "</table:table>"
end

local function preceded_by_table_p(el, info)
  for _, x in ipairs(ox.get_previous_element(el, info, true) or {}) do
    if x.type == "table" then
      return true
    end
  end
  return false
end

T.table = function(el, contents, info)
  -- OpenDocument does not allow tables in list items: close the enclosing
  -- lists, put the table in an indented section and reopen the lists.
  local genealogy = {}
  local p = el.parent
  while p do
    genealogy[#genealogy + 1] = p
    p = p.parent
  end
  local tags = {}
  local parent_list
  if genealogy[1] and genealogy[1].type == "item" then
    for _, x in ipairs(genealogy) do
      if x.type == "plain-list" then
        parent_list = x
        tags[#tags + 1] = {
          "</text:list>",
          fmt(
            '\n<text:list text:style-name="%s" %s>',
            LIST_STYLES[x.list_type] or "OrgBulletedList",
            'text:continue-numbering="true"'
          ),
        }
      elseif x.type == "item" then
        if not parent_list then
          if preceded_by_table_p(el, info) then
            tags[#tags + 1] = { "</text:list-header>", "<text:list-header>" }
          else
            tags[#tags + 1] = { "</text:list-item>", "<text:list-header>" }
          end
        elseif preceded_by_table_p(parent_list, info) then
          tags[#tags + 1] = { "</text:list-header>", "<text:list-header>" }
        else
          tags[#tags + 1] = { "</text:list-item>", "<text:list-item>" }
        end
      end
    end
  end
  -- low-level headlines are lists too
  local step = "item"
  for _, x in ipairs(genealogy) do
    if x.type == "headline" and ox.low_level_p(x, info) then
      for _ = 1, 2 do
        if step == "plain-list" then
          step = "item"
          parent_list = x
          tags[#tags + 1] = {
            "</text:list>",
            fmt(
              '\n<text:list text:style-name="%s" %s>',
              ox.numbered_headline_p(x, info) and "OrgNumberedList" or "OrgBulletedList",
              'text:continue-numbering="true"'
            ),
          }
        else
          step = "plain-list"
          if not parent_list then
            if preceded_by_table_p(el, info) then
              tags[#tags + 1] = { "</text:list-header>", "<text:list-header>" }
            else
              tags[#tags + 1] = { "</text:list-item>", "<text:list-header>" }
            end
          else
            local sec = ox.get_previous_element(parent_list, info)
            local has = false
            if sec and sec.type == "section" then
              for _, y in ipairs(sec.contents) do
                if y.type == "table" then
                  has = true
                end
              end
            end
            tags[#tags + 1] = has and { "</text:list-header>", "<text:list-header>" }
              or { "</text:list-item>", "<text:list-item>" }
          end
        end
      end
    end
  end
  local close, open = {}, {}
  for i, t in ipairs(tags) do
    close[i] = t[1]
    open[#tags - i + 1] = t[2]
  end
  local tbl = odt_table(el, contents, info)
  local level = math.floor(#tags / 2)
  return "\n"
    .. table.concat(close, "\n")
    .. (tbl and format_section(info, tbl, fmt("OrgIndentedSection-Level-%d", level)) or "")
    .. table.concat(open, "\n")
end

T.citation = function(el, _, info)
  return require("org.export.cite").export_citation(el, info, "odt")
end

---------------------------------------------------------------------------
-- Template (content.xml)
---------------------------------------------------------------------------

local function title_block(info)
  local title = info.with_title and nw(ox.data(info.title, info)) or nil
  local subtitle = title and nw(ox.data(info.subtitle, info)) or nil
  local author = info.with_author and info.author and nw(ox.data(info.author, info)) or nil
  local email = nw(info.email)
  author = info.with_author and (author or email) or nil
  email = info.with_email and email or nil
  local out = {}
  if title then
    out[#out + 1] =
      fmt('\n<text:p text:style-name="%s">%s</text:p>\n', "OrgTitle", fmt("\n<text:title>%s</text:title>", title))
    out[#out + 1] = '\n<text:p text:style-name="OrgTitle"/>\n'
    if subtitle then
      out[#out + 1] = fmt(
        '<text:p text:style-name="OrgSubtitle">\n%s\n</text:p>\n',
        '<text:user-defined style:data-style-name="N0" text:name="subtitle">\n' .. subtitle .. "</text:user-defined>\n"
      )
      out[#out + 1] = '<text:p text:style-name="OrgSubtitle"/>\n'
    end
  end
  if author and not email then
    out[#out + 1] = fmt(
      '\n<text:p text:style-name="%s">%s</text:p>',
      "OrgSubtitle",
      fmt("<text:initial-creator>%s</text:initial-creator>", author)
    )
    out[#out + 1] = '\n<text:p text:style-name="OrgSubtitle"/>'
  elseif author and email then
    out[#out + 1] = fmt(
      '\n<text:p text:style-name="%s">%s</text:p>',
      "OrgSubtitle",
      fmt(
        '<text:a xlink:type="simple" xlink:href="%s">%s</text:a>',
        "mailto:" .. email,
        fmt("<text:initial-creator>%s</text:initial-creator>", author)
      )
    )
    out[#out + 1] = '\n<text:p text:style-name="OrgSubtitle"/>'
  end
  local date = info.date
  if info.with_date and type(date) == "table" and #date > 0 then
    local ts = (#date == 1 and date[1].type == "timestamp") and date[1] or nil
    out[#out + 1] = fmt(
      '\n<text:p text:style-name="%s">%s</text:p>',
      "OrgSubtitle",
      (info.odt_use_date_fields and ts) and format_timestamp(ts) or ox.data(date, info)
    )
    out[#out + 1] = '<text:p text:style-name="OrgSubtitle"/>'
  end
  return table.concat(out)
end

local function insert_before(s, marker, text)
  local a = s:find(marker, 1, true)
  if not a then
    return s
  end
  return s:sub(1, a - 1) .. text .. s:sub(a)
end

local function template(contents, info)
  local st = state(info)
  local file = info.odt_content_template_file
  file = file and expand_path(file, info) or (M.styles_dir() .. "OrgOdtContentTemplate.xml")
  local tpl = read_file(file)
  if not tpl then
    error("Cannot read the ODT content template " .. file, 0)
  end
  -- automatic styles: tables and date styles
  local auto = {}
  for _, s in ipairs(st.table_styles) do
    auto[#auto + 1] = fmt(TABLE_STYLE_FORMAT, s[1], unquote(s[2]["rel-width"]) or "96")
  end
  if info.odt_use_date_fields then
    local d1, d2 = "%Y-%M-%d %a", "%Y-%M-%d %a %H:%M"
    if require("org.config").opts.display_custom_times then
      d1, d2 = custom_formats()
    end
    auto[#auto + 1] = M.build_date_styles(d1, "OrgDate1")
    auto[#auto + 1] = M.build_date_styles(d2, "OrgDate2")
  end
  tpl = insert_before(tpl, "  </office:automatic-styles>", table.concat(auto))
  -- sequence declarations (display outline level)
  local decls = {}
  for _, e in ipairs(category_map(info)) do
    decls[#decls + 1] = fmt(
      '<text:sequence-decl text:display-outline-level="%d" text:name="%s"/>',
      info.odt_display_outline_level or 2,
      e[2]
    )
  end
  local new_decls = fmt("\n<text:sequence-decls>\n%s\n</text:sequence-decls>", table.concat(decls, "\n"))
  local a = tpl:find("<text:sequence-decls", 1, true)
  local _, b = tpl:find("</text:sequence-decls>", a or 1, true)
  if a and b then
    tpl = tpl:sub(1, a - 1) .. new_decls .. tpl:sub(b + 1)
  end
  -- title, author, date, table of contents and contents
  local toc = ""
  local with_toc = info.with_toc
  if with_toc then
    local depth = type(with_toc) == "number" and with_toc or info.headline_levels
    toc = M.toc(depth, info) or ""
  end
  return insert_before(tpl, "</office:text>", title_block(info) .. toc .. (contents or ""))
end

T.template = template

---------------------------------------------------------------------------
-- Filters
---------------------------------------------------------------------------

--- org-odt--strip-trailing-newlines
local function strip_trailing_newlines(tree, _, info)
  element.map(tree, "*", function(el)
    if element.ELEMENTS[el.type] then
      local c = el.contents
      local last = c and c[#c]
      if last and last.type == "plain-text" and last.value:sub(-1) == "\n" then
        if #last.value > 1 then
          last.value = last.value:sub(1, -2)
        else
          table.remove(c)
        end
      end
    end
  end, { ignore = info.ignore, with_affiliated = true })
  return tree
end

--- org-odt--translate-latex-fragments: normalize `tex:` and convert the
--- fragments to MathML or pictures.
local function translate_latex_fragments(tree, _, info)
  local mode = info.with_latex
  if not mode then
    return tree
  end
  local warning
  local processes = latex_processes()
  if mode == true or mode == "t" or mode == "mathml" then
    if M.mathml_available() then
      mode = "mathml"
    else
      warning = "`org-odt-with-latex': LaTeX to MathML converter not available.  Falling back to verbatim."
      mode = "verbatim"
    end
  elseif type(mode) == "string" and processes[mode] then
    if not latex_process_available(mode) then
      warning = "`org-odt-with-latex': LaTeX to image converter not available.  Falling back to verbatim."
      mode = "verbatim"
    end
  elseif mode ~= "verbatim" then
    warning = "`org-odt-with-latex': Unknown LaTeX option.  Forcing verbatim."
    mode = "verbatim"
  end
  local frags = element.map(tree, { ["latex-fragment"] = true, ["latex-environment"] = true }, function(x)
    return x
  end, { ignore = info.ignore, with_affiliated = true })
  if warning and #frags > 0 then
    require("org.utils").warn(warning)
  end
  info.with_latex = mode
  if mode == "verbatim" then
    return tree
  end
  for _, x in ipairs(frags) do
    local value = x.value or ""
    if mode == "mathml" then
      local mathml = M.latex_to_mathml_cached(value, info)
      if mathml then
        x.odt_converted = { kind = "mathml", data = mathml }
      end
    else
      local path = M.latex_to_image(value, mode, info)
      if path then
        x.odt_converted = { kind = "image", data = path }
      else
        require("org.utils").warn("LaTeX Conversion failed.")
      end
    end
  end
  return tree
end

--- org-odt--translate-description-lists: description lists become a list
--- of terms (bold paragraphs) each followed by a list with its definition.
local function translate_description_lists(tree, _, info)
  element.map(tree, "plain-list", function(el)
    if el.list_type == "descriptive" then
      local items = {}
      for _, item in ipairs(el.contents) do
        local term = item.tag and #item.tag > 0 and item.tag or { element.text("(no term)") }
        local para = element.node("paragraph", { odt_style = "Text_20_body_20_bold" }, term)
        local inner = element.node("item", {}, item.contents)
        local list = element.node("plain-list", { list_type = "descriptive-2" }, { inner })
        items[#items + 1] = element.node("item", { checkbox = item.checkbox }, { para, list })
      end
      -- a new list in Emacs (org-element-set): no blank lines after it
      el.list_type = "descriptive-1"
      el.post_blank = 0
      el.contents = items
      for _, it in ipairs(items) do
        it.parent = el
      end
    end
  end, { ignore = info.ignore })
  return tree
end

--- org-odt--translate-list-tables: lists with `#+ATTR_ODT: :list-table t`
--- become tables (level-1 items are rows, level-2 items the cells).
local function translate_list_tables(tree, _, info)
  local lists = element.map(tree, "plain-list", function(el)
    if ox.read_attribute("attr_odt", el, "list-table") then
      return el
    end
  end, { ignore = info.ignore })
  for _, l1 in ipairs(lists) do
    local rows = {}
    for _, item in ipairs(l1.contents) do
      if item.type == "item" then
        local leading, l2 = {}, nil
        local found = false
        for i, x in ipairs(item.contents) do
          if x.type == "plain-list" and i > 1 then
            l2 = x
            found = true
            break
          end
          leading[#leading + 1] = x
        end
        if not found then
          leading = item.contents
        end
        local cells = { element.node("table-cell", {}, leading) }
        for _, it in ipairs(l2 and l2.contents or {}) do
          if it.type == "item" then
            cells[#cells + 1] = element.node("table-cell", {}, it.contents)
          end
        end
        rows[#rows + 1] = element.node("table-row", { row_type = "standard" }, cells)
      end
    end
    local tbl = element.node("table", { table_type = "org", attr_odt = { ':style "GriddedTable"' } }, rows)
    local siblings = element.siblings(l1)
    if siblings then
      for i, x in ipairs(siblings) do
        if x == l1 then
          siblings[i] = tbl
          tbl.parent = l1.parent
          break
        end
      end
    end
  end
  return tree
end

local function translate_image_links(tree, _, info)
  return ox.insert_image_links(tree, info, info.odt_inline_image_rules)
end

--- org-odt--remove-forbidden: characters not allowed in XML 1.0.
local function remove_forbidden(text, _, info)
  local rep = info.odt_with_forbidden_chars
  if rep == true then
    return text
  end
  local pat = "[%z\1-\8\11\12\14-\31]"
  local pat2 = "\239\191[\190\191]"
  if rep == false or rep == nil then
    local m = text:match(pat) or text:match(pat2)
    if m then
      error(fmt("Forbidden character '%s' found.  See `export.odt.with_forbidden_chars'", m), 0)
    end
    return text
  end
  local counts = {}
  local function sub(c)
    counts[c] = (counts[c] or 0) + 1
    return rep
  end
  text = text:gsub(pat, sub):gsub(pat2, sub)
  for c, n in pairs(counts) do
    require("org.utils").warn(fmt("Replaced forbidden character %q with '%s' %d times", c, rep, n))
  end
  return text
end

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

local function defaults()
  local c = ocfg()
  local function v(name, default)
    if c[name] == nil then
      return default
    end
    return c[name]
  end
  local global_latex = (require("org.config").opts.export or {}).with_latex
  if global_latex == nil then
    global_latex = true
  end
  return {
    { "odt_styles_file", "ODT_STYLES_FILE", nil, v("styles_file", nil), "t" },
    { "odt_extra_styles", "ODT_EXTRA_STYLES", nil, v("extra_styles", nil), "newline" },
    { "description", "DESCRIPTION", nil, nil, "newline" },
    { "keywords_meta", "KEYWORDS", nil, nil, "space" },
    { "subtitle", "SUBTITLE", nil, nil, "parse" },
    { "odt_with_forbidden_chars", nil, nil, v("with_forbidden_chars", "") },
    { "odt_content_template_file", nil, nil, v("content_template_file", nil) },
    { "odt_display_outline_level", nil, nil, v("display_outline_level", 2) },
    { "odt_fontify_srcblocks", nil, nil, v("fontify_srcblocks", true) },
    { "odt_create_custom_styles_for_srcblocks", nil, nil, v("create_custom_styles_for_srcblocks", true) },
    { "odt_format_drawer_function", nil, nil, v("format_drawer_function", nil) },
    { "odt_format_headline_function", nil, nil, v("format_headline_function", nil) },
    { "odt_format_inlinetask_function", nil, nil, v("format_inlinetask_function", nil) },
    { "odt_inline_formula_rules", nil, nil, v("inline_formula_rules", { file = { "mathml", "mml", "odf" } }) },
    { "odt_inline_image_rules", nil, nil, v("inline_image_rules", { file = { "jpeg", "jpg", "png", "gif", "svg" } }) },
    { "odt_pixels_per_inch", nil, nil, v("pixels_per_inch", 96) },
    { "odt_table_styles", nil, nil, v("table_styles", M.TABLE_STYLES) },
    { "odt_use_date_fields", nil, nil, v("use_date_fields", false) },
    { "odt_category_map_alist", nil, nil, v("category_map_alist", nil) },
    { "with_latex", nil, "tex", v("with_latex", global_latex) },
    { "latex_header", "LATEX_HEADER", nil, nil, "newline" },
  }
end

M.transcoders = T

M.backend = ox.define_backend("odt", {
  transcoders = T,
  options = defaults,
  filters = {
    options = {
      function(info)
        info.odt_state = new_state()
        return info
      end,
    },
    ["parse-tree"] = {
      strip_trailing_newlines,
      translate_latex_fragments,
      translate_description_lists,
      translate_list_tables,
      translate_image_links,
    },
    ["final-output"] = { remove_forbidden },
  },
})

---------------------------------------------------------------------------
-- Package: meta.xml, styles.xml, manifest, zip
---------------------------------------------------------------------------

local function xml_text(s)
  return encode(strip_tags(s or ""), true)
end

--- meta.xml (written by org-odt-template in Emacs).
function M.meta_xml(info)
  local title = ox.data(info.title, info)
  local subtitle = ox.data(info.subtitle, info)
  local author = info.author and ox.data(info.author, info) or ""
  local out = {
    [[<?xml version="1.0" encoding="UTF-8"?>
     <office:document-meta
         xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
         xmlns:xlink="http://www.w3.org/1999/xlink"
         xmlns:dc="http://purl.org/dc/elements/1.1/"
         xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0"
         xmlns:ooo="http://openoffice.org/2004/office"
         office:version="1.2">
       <office:meta>
]],
    fmt("<dc:creator>%s</dc:creator>\n", xml_text(author)),
    fmt("<meta:initial-creator>%s</meta:initial-creator>\n", xml_text(author)),
  }
  if info.with_date then
    local date = info.date
    local ts = (type(date) == "table" and #date == 1 and date[1].type == "timestamp") and date[1] or nil
    local iso = format_timestamp(ts, nil, true)
    out[#out + 1] = fmt("<dc:date>%s</dc:date>\n", iso)
    out[#out + 1] = fmt("<meta:creation-date>%s</meta:creation-date>\n", iso)
  end
  out[#out + 1] = fmt("<meta:generator>%s</meta:generator>\n", xml_text(info.creator or ""))
  out[#out + 1] = fmt("<meta:keyword>%s</meta:keyword>\n", xml_text(info.keywords_meta or ""))
  out[#out + 1] = fmt("<dc:subject>%s</dc:subject>\n", xml_text(info.description or ""))
  out[#out + 1] = fmt("<dc:title>%s</dc:title>\n", xml_text(title))
  if nw(subtitle) then
    out[#out + 1] = fmt('<meta:user-defined meta:name="subtitle">%s</meta:user-defined>\n', xml_text(subtitle))
  end
  out[#out + 1] = "\n  </office:meta>\n</office:document-meta>"
  return table.concat(out)
end

--- The styles file specification: nil (factory styles), a path to a
--- styles.xml, .odt or .ott file, or { file, { members } }.
local function styles_spec(info)
  local spec = info.odt_styles_file
  if type(spec) == "string" then
    spec = trim(spec)
    if spec == "" then
      return nil
    end
    if spec:match("^%(.*%)$") then
      local v = ox.read_sexp(spec)
      if type(v) ~= "table" or type(v[1]) ~= "string" then
        error("Invalid styles file specification: " .. spec, 0)
      end
      return { v[1], type(v[2]) == "table" and v[2] or {} }
    end
    return (spec:gsub('^"(.*)"$', "%1"))
  end
  return spec
end

--- styles.xml and the extra package members of the styles file.
function M.styles_xml(info)
  local spec = styles_spec(info)
  local styles
  local extra = {}
  if spec == nil or spec == false then
    styles = read_file(M.styles_dir() .. "OrgOdtStyles.xml")
    if not styles then
      error("Missing styles file", 0)
    end
  elseif type(spec) == "table" then
    local archive = expand_path(spec[1], info)
    for _, member in ipairs(spec[2] or {}) do
      local data, err = zip.read(archive, member)
      if not data then
        error(err, 0)
      end
      if member == "styles.xml" then
        styles = data
      else
        extra[#extra + 1] = { name = member, data = data }
        local ext = (member:match("%.([%w]+)$") or ""):lower()
        if vim.tbl_contains({ "png", "jpg", "jpeg", "gif", "svg", "bmp", "tif", "tiff", "webp" }, ext) then
          manifest_entry(info, "image/" .. (MEDIA[ext] or ext), member)
        end
      end
    end
    if not styles then
      error("styles.xml must be one of the members of " .. spec[1], 0)
    end
  else
    local file = expand_path(spec, info)
    if vim.fn.filereadable(file) == 0 then
      error("Invalid specification of styles.xml file: " .. tostring(info.odt_styles_file), 0)
    end
    local ext = (file:match("%.([%w]+)$") or ""):lower()
    if ext == "xml" then
      styles = read_file(file)
    elseif ext == "odt" or ext == "ott" then
      local err
      styles, err = zip.read(file, "styles.xml")
      if not styles then
        error(err, 0)
      end
    else
      error("Invalid specification of styles.xml file: " .. tostring(info.odt_styles_file), 0)
    end
  end
  manifest_entry(info, "text/xml", "styles.xml")
  -- colorized source block styles
  local st = state(info)
  local src = {}
  for _, name in ipairs(st.src_style_order) do
    local s = st.src_styles[name]
    if s and s ~= "" then
      src[#src + 1] = " " .. s .. "\n"
    end
  end
  local add = "\n<!-- Org Htmlfontify Styles -->\n" .. table.concat(src) .. "\n"
  if nw(info.odt_extra_styles) then
    add = add .. "\n<!-- Org Extra Styles -->\n" .. info.odt_extra_styles .. "\n"
  end
  styles = insert_before(styles, "</office:styles>", add)
  -- outline numbering is kept up to the section-number level
  local sec = info.section_numbers
  styles = styles:gsub('<text:outline%-level%-style([^>]*)text:level="([^"]*)"([^>]*)>', function(a, level, b)
    local l = tonumber(level) or 0
    local keep
    if type(sec) == "number" then
      keep = l <= sec
    else
      keep = sec and true or false
    end
    if keep then
      return nil
    end
    return fmt('<text:outline-level-style%stext:level="%s" style:num-format="">', a, level)
  end)
  -- priority styles for the valid priority range
  if info.with_priority then
    local marker = '<style:style style:name="OrgPriority" style:family="text"/>'
    local a, b = styles:find(marker, 1, true)
    if a then
      local c = require("org.config").opts
      local hi, lo = c.priority_highest or "A", c.priority_lowest or "C"
      local items = {}
      local function add_p(p)
        items[#items + 1] = fmt(
          '  <style:style style:name="OrgPriority-%s" style:family="text" style:parent-style-name="OrgPriority"/>\n',
          p
        )
      end
      if type(hi) == "number" and type(lo) == "number" then
        for p = hi, lo do
          add_p(p)
        end
      else
        for p = tostring(hi):byte(), tostring(lo):byte() do
          add_p(string.char(p))
        end
      end
      styles = styles:sub(1, b) .. "\n  <!-- Org Priority Styles -->\n" .. table.concat(items) .. styles:sub(b + 1)
    end
  end
  return styles, extra
end

--- META-INF/manifest.xml (org-odt-write-manifest-file).
function M.manifest_xml(entries)
  local out = {
    [[<?xml version="1.0" encoding="UTF-8"?>
     <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
]],
  }
  for i = #entries, 1, -1 do
    local e = entries[i]
    out[#out + 1] = fmt(
      '\n<manifest:file-entry manifest:media-type="%s" manifest:full-path="%s"%s/>',
      e[1],
      e[2],
      e[3] and fmt(' manifest:version="%s"', e[3]) or ""
    )
  end
  out[#out + 1] = "\n</manifest:manifest>\n"
  return table.concat(out)
end

--- Package members of an exported document: `content` is the content.xml
--- produced by the export, `info` its communication channel.
---@return { name: string, data?: string }[]
function M.package_entries(content, info)
  local mimetype = "application/vnd.oasis.opendocument.text"
  manifest_entry(info, "text/xml", "meta.xml")
  local meta = M.meta_xml(info)
  local styles, extra = M.styles_xml(info)
  manifest_entry(info, "text/xml", "content.xml")
  manifest_entry(info, mimetype, "/", "1.2")
  local entries = {
    { name = "mimetype", data = mimetype },
    { name = "content.xml", data = content },
    { name = "styles.xml", data = styles },
    { name = "meta.xml", data = meta },
  }
  local seen = { mimetype = true, ["content.xml"] = true, ["styles.xml"] = true, ["meta.xml"] = true }
  local function add(e)
    if not seen[e.name] then
      seen[e.name] = true
      -- parent directories of members of the styles file
      local dir = e.name:match("^(.*/)[^/]+$")
      if dir and not seen[dir] then
        seen[dir] = true
        entries[#entries + 1] = { name = dir }
      end
      entries[#entries + 1] = e
    end
  end
  for _, e in ipairs(extra) do
    add(e)
  end
  for _, e in ipairs(state(info).files) do
    add(e)
  end
  entries[#entries + 1] = { name = "META-INF/" }
  entries[#entries + 1] = { name = "META-INF/manifest.xml", data = M.manifest_xml(state(info).manifest) }
  return entries
end

---------------------------------------------------------------------------
-- Conversion (org-odt-convert)
---------------------------------------------------------------------------

--- org-odt-do-reachable-formats: { converter-cmd, output formats } list.
local function reachable_formats(in_fmt)
  local c = ocfg()
  local process = c.convert_process
  if process == nil then
    process = "LibreOffice"
  end
  if not process then
    return {}
  end
  local cmd
  for _, p in ipairs(c.convert_processes or M.CONVERT_PROCESSES) do
    if p[1]:lower() == tostring(process):lower() then
      cmd = p[2]
    end
  end
  if not cmd then
    return {}
  end
  local out = {}
  for _, cap in ipairs(c.convert_capabilities or M.CONVERT_CAPABILITIES) do
    if vim.tbl_contains(cap[2], in_fmt) then
      out[#out + 1] = { cmd, cap[3] }
    end
  end
  return out
end

--- Output formats `in_fmt` files can be converted to (org-odt-reachable-formats).
function M.reachable_formats(in_fmt)
  local out = {}
  for _, e in ipairs(reachable_formats(in_fmt)) do
    for _, f in ipairs(e[2]) do
      out[#out + 1] = f[1]
    end
  end
  return out
end

local function file_url(path)
  return "file://" .. (path:gsub("[^%w%-%._~/]", function(ch)
    return fmt("%%%02X", ch:byte())
  end))
end

--- Convert `in_file` to `out_fmt` with `export.odt.convert_process`
--- (org-odt-convert). Returns the converted file or nil.
---@param in_file string
---@param out_fmt string
---@param open? boolean open the converted file
---@return string?
function M.convert(in_file, out_fmt, open)
  local utils = require("org.utils")
  in_file = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(in_file), ":p"))
  if vim.fn.filereadable(in_file) == 0 then
    utils.error("Cannot read " .. in_file)
    return nil
  end
  local in_fmt = (in_file:match("%.([%w]+)$") or ""):lower()
  local how
  for _, e in ipairs(reachable_formats(in_fmt)) do
    for _, f in ipairs(e[2]) do
      if f[1] == out_fmt and not how then
        how = { e[1], f }
      end
    end
  end
  if not how then
    utils.error(fmt("Cannot convert from %s format to %s format?", in_fmt, out_fmt))
    return nil
  end
  local out_file = in_file:gsub("%.[^./]*$", "") .. "." .. (how[2][2] or out_fmt)
  local out_dir = vim.fn.fnamemodify(in_file, ":h") .. "/"
  local cmd = format_spec(how[1], {
    i = shellescape(in_file),
    I = file_url(in_file),
    f = out_fmt,
    o = shellescape(out_file),
    O = file_url(out_file),
    d = shellescape(out_dir),
    D = file_url(out_dir),
    x = how[2][3] or "",
  })
  if vim.fn.filereadable(out_file) == 1 then
    os.remove(out_file)
  end
  local res = sh(cmd, out_dir)
  if vim.fn.filereadable(out_file) == 1 then
    utils.notify("Exported to " .. out_file)
    if open then
      vim.ui.open(out_file)
    end
    return out_file
  end
  utils.error("Export to " .. out_file .. " failed\n" .. (res.stdout or "") .. (res.stderr or ""))
  return nil
end

--- org-odt-convert as a command: ask for the file (default the buffer's)
--- and one of the output formats it can be converted to; a count opens the
--- result (C-u).
function M.convert_command()
  local utils = require("org.utils")
  local current = vim.api.nvim_buf_get_name(0)
  local in_file = utils.input({ prompt = "File to be converted: ", default = current, completion = "file" })
  if not in_file or vim.trim(in_file) == "" then
    return nil
  end
  in_file = vim.trim(in_file)
  local in_fmt = (in_file:match("%.([%w]+)$") or ""):lower()
  local choices = M.reachable_formats(in_fmt)
  if #choices == 0 then
    utils.error(fmt("No known converter or no known output formats for %s files", in_fmt))
    return nil
  end
  local open = vim.v.count > 0
  local out_fmt = require("org.ui").choose({ prompt = "Output format: ", title = "Convert to", items = choices })
  if not out_fmt or out_fmt == "" then
    return nil
  end
  return M.convert(in_file, out_fmt, open)
end

--- The first LaTeX fragment of `s` (org-latex-regexps, in their order).
function M.find_latex_fragment(s)
  local a = s:match("^[ \t]*(\\begin{[%w*]+}.-\\end{[%w*]+}[ \t]*\n?)")
    or s:match("\n[ \t]*(\\begin{[%w*]+}.-\\end{[%w*]+}[ \t]*\n?)")
  if a then
    return a
  end
  for _, pat in ipairs({ "^%$[^ \t\r\n,;.$]%$", "^%$[^ \t\n,;.$][^$\n\r]-[^ \t\n,.$]%$" }) do
    for i = 1, #s do
      if s:sub(i, i) == "$" and (i == 1 or s:sub(i - 1, i - 1) ~= "$") then
        local m = s:sub(i):match(pat)
        if m then
          return m
        end
      end
    end
  end
  return s:match("(\\%(.-\\%))") or s:match("(\\%[.-\\%])") or s:match("(%$%$.-%$%$)")
end

--- Export a LaTeX fragment as an OpenDocument formula file
--- (org-odt-export-as-odf): the fragment is converted to MathML with
--- `export.odt.latex_to_mathml_convert_command` and written as the
--- content.xml of FILE.odf. Interactively the fragment comes from the
--- Visual selection (its first LaTeX fragment) or a prompt, and the file
--- name from a prompt (default: the buffer's name with .odf). The MathML is
--- copied like the export output (`export.copy_to_kill_ring`).
---@param latex_frag? string
---@param odf_file? string
---@return string? odf file
function M.export_as_odf(latex_frag, odf_file)
  local utils = require("org.utils")
  local src = vim.api.nvim_buf_get_name(0)
  local default_file = (src ~= "" and vim.fn.fnamemodify(src, ":p:r") or (vim.fn.getcwd() .. "/formula")) .. ".odf"
  local interactive = latex_frag == nil
  if interactive then
    local frag
    local m = vim.fn.mode()
    if m == "v" or m == "V" or m == "\22" then
      local srow, scol, erow, ecol, mode = utils.visual_range()
      vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
      local text
      if mode == "v" then
        local last = vim.api.nvim_buf_get_lines(0, erow - 1, erow, false)[1] or ""
        local e = math.min(#last, ecol)
        text = table.concat(vim.api.nvim_buf_get_text(0, srow - 1, scol - 1, erow - 1, e, {}), "\n")
      else
        text = table.concat(vim.api.nvim_buf_get_lines(0, srow - 1, erow, false), "\n")
      end
      frag = M.find_latex_fragment(text)
    end
    latex_frag = utils.input({ prompt = "LaTeX Fragment: ", default = frag })
    if not latex_frag or latex_frag == "" then
      return nil
    end
    odf_file = utils.input({ prompt = "ODF filename: ", default = default_file, completion = "file" })
    if not odf_file or odf_file == "" then
      return nil
    end
  end
  odf_file = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(odf_file or default_file), ":p"))
  local mathml = M.latex_to_mathml(latex_frag)
  if not mathml then
    utils.error("No Math formula created")
    return nil
  end
  local mimetype = "application/vnd.oasis.opendocument.formula"
  local manifest = M.manifest_xml({ { "text/xml", "content.xml" }, { mimetype, "/", "1.2" } })
  vim.fn.mkdir(vim.fn.fnamemodify(odf_file, ":h"), "p")
  local ok, err = zip.write(odf_file, {
    { name = "mimetype", data = mimetype },
    { name = "content.xml", data = mathml },
    { name = "META-INF/" },
    { name = "META-INF/manifest.xml", data = manifest },
  })
  if not ok then
    utils.error("OpenDocument formula export failed: " .. tostring(err))
    return nil
  end
  require("org.export").maybe_copy(mathml, interactive)
  utils.notify("Created " .. odf_file)
  return odf_file
end

--- org-odt-export-as-odf-and-open
function M.export_as_odf_and_open()
  local out = M.export_as_odf()
  if out then
    vim.ui.open(out)
  end
  return out
end

---------------------------------------------------------------------------
-- Export
---------------------------------------------------------------------------

--- Write the OpenDocument package of an export to `out`.
---@return boolean ok, string? err
function M.write_package(out, content, info)
  local ok, entries = pcall(M.package_entries, content, info)
  if not ok then
    return false, tostring(entries)
  end
  vim.fn.mkdir(vim.fn.fnamemodify(out, ":h"), "p")
  return zip.write(out, entries)
end

--- Export `lines` to an .odt file (org-odt-export-to-odt).
---@param lines string[]
---@param xopts table options of ox.export_as
---@param opts? { output?: string, open?: boolean }
---@param src? string visited file
---@return string? output path
function M.export_file(lines, xopts, opts, src)
  opts = opts or {}
  local utils = require("org.utils")
  xopts = vim.tbl_extend("force", xopts or {}, { body_only = false })
  local ok, content, info = pcall(ox.export_as, "odt", lines, xopts)
  if not ok then
    utils.error("OpenDocument export failed: " .. tostring(content))
    return nil
  end
  local out = opts.output or require("org.export").output_file_name(src, "odt", info)
  local wok, err = M.write_package(out, content, info)
  if not wok then
    utils.error("OpenDocument export failed: " .. tostring(err))
    return nil
  end
  utils.notify("Created " .. out)
  local result = out
  local preferred = ocfg().preferred_output_format
  if nw(preferred) and preferred ~= "odt" then
    result = M.convert(out, preferred) or out
  end
  local c = require("org.config").opts.export or {}
  if opts.open or c.open_after_export then
    vim.ui.open(result)
  end
  return result
end

return M

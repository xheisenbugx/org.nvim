---@mod org.export.odt.transcode ODT transcoders
---
--- The element and object transcoders of ox-odt.el, except tables
--- (org.export.odt.table) and the template (org.export.odt.template).
---
--- Part of org.export.odt, which loads it.

local ox = require("org.export.ox")
local element = require("org.export.element")
local entities = require("org.export.entities")
local shared = require("org.export.odt.shared")

local M = require("org.export.odt")

local fmt = string.format
local nw = ox.nw
local trim = ox.trim

local ID_PREFIX = shared.ID_PREFIX
local BOOKMARK_PREFIX = shared.BOOKMARK_PREFIX
local encode_tabs_and_spaces = shared.encode_tabs_and_spaces
local encode = shared.encode
local target = shared.target
local textbox = shared.textbox
local span = shared.span
local headline_numbers = shared.headline_numbers
local format_headline_wrap = shared.format_headline_wrap
local standalone_link_p = shared.standalone_link_p
local labelled = shared.labelled
local format_spec = shared.format_spec
local format_label = shared.format_label
local copy_image_file = shared.copy_image_file
local image_size = shared.image_size
local render_image_formula = shared.render_image_formula
local expand_path = shared.expand_path
local inline_image = shared.inline_image
local formula_file_data = shared.formula_file_data
local inline_formula = shared.inline_formula
local do_format_code = shared.do_format_code
local format_code = shared.format_code
local format_timestamp = shared.format_timestamp

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
    -- lint: allow gsub: encode_tabs_and_spaces is a function (from org.export.odt.shared)
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
  local imagep = ox.inline_image_p(el, info.odt_inline_image_rules, true)
  local path
  if ltype == "file" then
    local uri = ox.file_uri(raw)
    path = uri:match("^file://") and uri or ("../" .. uri)
  else
    path = ltype .. ":" .. raw
  end
  -- Emacs only converts "&"; quotes and angle brackets would also break
  -- the xlink:href attribute (and the XML).
  local attr_escapes = { ["&"] = "&amp;", ['"'] = "&quot;", ["<"] = "&lt;", [">"] = "&gt;" }
  path = path:gsub('[&"<>]', attr_escapes)
  raw = raw:gsub('[&"<>]', attr_escapes)
  local custom = ox.custom_protocol_maybe(el, desc, "odt", info)
  if custom then
    return custom
  end
  if not desc and imagep then
    return inline_image(el, info)
  end
  if not desc and ox.inline_image_p(el, info.odt_inline_formula_rules, true) then
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
    if #c == 1 and c[1].type == "link" and ox.inline_image_p(c[1], info.odt_inline_image_rules, true) then
      return fmt('\n<draw:a xlink:type="simple" xlink:href="%s">\n%s\n</draw:a>', path, desc)
    end
    return fmt('<text:a xlink:type="simple" xlink:href="%s">%s</text:a>', path, desc)
  end
  return fmt('<text:a xlink:type="simple" xlink:href="%s">%s</text:a>', path, path)
end

-- Locals the later parts share
shared.T = T
shared.LIST_STYLES = LIST_STYLES

---@mod org.export.odt.template ODT content.xml template
---
--- The title block and content.xml (org-odt-template).
---
--- Part of org.export.odt, which loads it.

local ox = require("org.export.ox")
local shared = require("org.export.odt.shared")

local M = require("org.export.odt")

local fmt = string.format
local nw = ox.nw

local read_file = shared.read_file
local TABLE_STYLE_FORMAT = shared.TABLE_STYLE_FORMAT
local state = shared.state
local category_map = shared.category_map
local expand_path = shared.expand_path
local custom_formats = shared.custom_formats
local format_timestamp = shared.format_timestamp
local T = shared.T
local unquote = shared.unquote

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

-- Locals the later parts share
shared.insert_before = insert_before

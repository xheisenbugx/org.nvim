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
---
--- This file holds the constants, the per-export state, encoding and the
--- frame / section helpers; the rest loads from org/export/odt/: heading
--- (headlines, table of contents), label (captions), media (pictures and
--- formulas), latex (LaTeX to MathML or images), src (source code),
--- timestamp, transcode (the transcoders), table, template (content.xml),
--- backend (filters, back-end), package (meta.xml, styles.xml, manifest)
--- and convert (org-odt-convert, writing the package).

local ox = require("org.export.ox")
local element = require("org.export.element")

local M = {}
-- The parts in org/export/odt/ add their functions to this table and
-- require it back, so it must be in package.loaded before they load.
package.loaded["org.export.odt"] = M

M.extension = "odt"

local fmt = string.format
local nw = ox.nw

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
      -- lint: allow gsub: constant replacement pairs
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

-- Locals the parts below share
local shared = require("org.export.odt.shared")
shared.ocfg = ocfg
shared.read_file = read_file
shared.ID_PREFIX = ID_PREFIX
shared.BOOKMARK_PREFIX = BOOKMARK_PREFIX
shared.TABLE_STYLE_FORMAT = TABLE_STYLE_FORMAT
shared.SRC_BLOCK_PARAGRAPH_FORMAT = SRC_BLOCK_PARAGRAPH_FORMAT
shared.LABEL_STYLES = LABEL_STYLES
shared.DEFAULT_IMAGE_SIZES = DEFAULT_IMAGE_SIZES
shared.MAX_IMAGE_SIZE = MAX_IMAGE_SIZE
shared.new_state = new_state
shared.state = state
shared.manifest_entry = manifest_entry
shared.add_automatic_style = add_automatic_style
shared.encode_tabs_and_spaces = encode_tabs_and_spaces
shared.encode = encode
shared.strip_tags = strip_tags
shared.num = num
shared.frame = frame
shared.target = target
shared.textbox = textbox
shared.format_section = format_section
shared.span = span

require("org.export.odt.heading")
require("org.export.odt.label")
require("org.export.odt.media")
require("org.export.odt.latex")
require("org.export.odt.src")
require("org.export.odt.timestamp")
require("org.export.odt.transcode")
require("org.export.odt.table")
require("org.export.odt.template")
require("org.export.odt.backend")
require("org.export.odt.package")
require("org.export.odt.convert")

return M

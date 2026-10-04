---@mod org.export.odt.table ODT tables
---
--- Table, row and cell transcoders (org-odt-table and its helpers).
---
--- Part of org.export.odt, which loads it.

local ox = require("org.export.ox")
local element = require("org.export.element")
local shared = require("org.export.odt.shared")

local fmt = string.format

local add_automatic_style = shared.add_automatic_style
local format_section = shared.format_section
local format_label = shared.format_label
local T = shared.T
local LIST_STYLES = shared.LIST_STYLES

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

-- Locals the later parts share
shared.unquote = unquote

---@mod org.export.gfm GitHub flavoured Markdown back-end
---
--- Not part of Emacs Org (ox-md writes plain Markdown with HTML tables);
--- this back-end, derived from `md`, writes pipe tables, fenced code
--- blocks, `[^n]` footnotes, task list checkboxes, `~~strike~~` and a
--- `# Title` heading with the document headings one level below it.
--- Anchors follow GitHub's heading ids.

local ox = require("org.export.ox")
local element = require("org.export.element")
local entities = require("org.export.entities")

local M = {}

M.extension = "md"

local fmt = string.format
local trim = ox.trim

--- GitHub heading id of a title.
function M.slug(s)
  s = s:lower():gsub("[^%w%s%-_\128-\255]", ""):gsub("%s", "-")
  return s
end

local function anchor_of(h, info)
  if h.props and h.props.CUSTOM_ID then
    return h.props.CUSTOM_ID
  end
  info.gfm_ids = info.gfm_ids or { by = {}, used = {} }
  local ids = info.gfm_ids
  if ids.by[h] then
    return ids.by[h]
  end
  local base = M.slug(element.interpret(h.title))
  local id = base
  local n = 0
  while ids.used[id] do
    n = n + 1
    id = base .. "-" .. n
  end
  ids.used[id] = true
  ids.by[h] = id
  return id
end

local function esc(s)
  return (s:gsub("([%*`_\\])", "\\%1"))
end

local function indent_lines(s, prefix, first)
  local lines = vim.split((s:gsub("\n$", "")), "\n", { plain = true })
  for i, l in ipairs(lines) do
    if i == 1 and first then
      lines[i] = first .. l
    elseif l ~= "" then
      lines[i] = prefix .. l
    end
  end
  return table.concat(lines, "\n")
end

local T = {}

T.bold = function(_, c)
  return "**" .. (c or "") .. "**"
end
T.italic = function(_, c)
  return "*" .. (c or "") .. "*"
end
T.underline = function(_, c)
  return "<u>" .. (c or "") .. "</u>"
end
T["strike-through"] = function(_, c)
  return "~~" .. (c or "") .. "~~"
end
local function code(el)
  local ticks = el.value:find("`", 1, true) and "``" or "`"
  return ticks .. el.value .. ticks
end
T.code = code
T.verbatim = code
T["inline-src-block"] = code
T.entity = function(el)
  return (entities[el.name] or {})[6] or ("\\" .. el.name)
end
T.timestamp = function(el)
  return "`" .. ox.timestamp_translate(el) .. "`"
end

T["plain-text"] = function(text, info)
  text = esc(text)
  if info.with_special_strings then
    text = text:gsub("\\%-", "\xc2\xad")
  end
  if info.preserve_breaks then
    text = text:gsub("[ \t]*\n", "  \n")
  end
  return text
end

T["footnote-reference"] = function(el, _, info)
  return fmt("[^%d]", ox.get_footnote_number(el, info))
end

local function headline_text(el, info)
  local parts = {}
  if info.with_todo_keywords and el.todo_keyword then
    parts[#parts + 1] = el.todo_keyword
  end
  if info.with_priority and el.priority then
    parts[#parts + 1] = "[#" .. el.priority .. "]"
  end
  parts[#parts + 1] = ox.data(el.title, info)
  local s = table.concat(parts, " ")
  local tags = info.with_tags and ox.get_tags(el, info) or {}
  if #tags > 0 then
    s = s .. "&emsp;<kbd>" .. table.concat(tags, "</kbd> <kbd>") .. "</kbd>"
  end
  return s
end

T.headline = function(el, contents, info)
  if el.footnote_section_p then
    return nil
  end
  contents = contents or ""
  if ox.low_level_p(el, info) then
    local s = "- **" .. headline_text(el, info) .. "**"
    if trim(contents) ~= "" then
      s = s .. "\n\n" .. indent_lines(contents, "  ")
    end
    return s .. "\n"
  end
  local level = math.min(ox.get_relative_level(el, info) + (info.gfm_shift or 0), 6)
  local id = anchor_of(el, info)
  local anchor = ""
  if id ~= M.slug(element.interpret(el.title)) then
    anchor = fmt('<a id="%s"></a>\n', id)
  end
  return anchor .. string.rep("#", level) .. " " .. headline_text(el, info) .. "\n\n" .. contents
end

T.section = function(_, contents)
  return contents
end

T.paragraph = function(_, contents)
  return contents
end

T["plain-list"] = function(_, contents)
  return contents
end

T.item = function(el, contents, info)
  local list = el.parent
  local marker = "- "
  if list.list_type == "ordered" then
    local n = ox.get_ordinal(el, info)
    marker = tostring(n[#n]) .. ". "
  end
  local box = ({ on = "[x] ", off = "[ ] ", trans = "[-] " })[el.checkbox or ""] or ""
  local body = trim(contents or "")
  if list.list_type == "descriptive" then
    body = "**" .. ox.data(el.tag or {}, info) .. "**: " .. body
  end
  return indent_lines(box .. body, string.rep(" ", #marker), marker)
end

local function fence(lines, lang)
  local f = "```"
  if lines:find("```", 1, true) then
    f = "~~~~"
  end
  return f .. (lang or "") .. "\n" .. lines .. f
end

T["src-block"] = function(el, _, info)
  return fence(ox.format_code_default(el, info), el.language)
end
T["example-block"] = function(el, _, info)
  return fence(ox.format_code_default(el, info))
end
T["fixed-width"] = function(el)
  return fence(el.value .. "\n")
end

T["quote-block"] = function(_, contents)
  local lines = vim.split(((contents or ""):gsub("\n$", "")), "\n", { plain = true })
  for i, l in ipairs(lines) do
    lines[i] = l == "" and ">" or ("> " .. l)
  end
  return table.concat(lines, "\n")
end

T["center-block"] = function(_, c)
  return c
end
T["special-block"] = function(_, c)
  return c
end
T.drawer = function(_, c)
  return c
end
T["dynamic-block"] = function(_, c)
  return c
end

T["verse-block"] = function(_, contents)
  local lines = vim.split(((contents or ""):gsub("\n$", "")), "\n", { plain = true })
  for i, l in ipairs(lines) do
    lines[i] = l .. "  "
  end
  return table.concat(lines, "\n")
end

T["latex-environment"] = function(el, _, info)
  if not info.with_latex then
    return nil
  end
  return "$$\n" .. el.value .. "$$"
end

T["latex-fragment"] = function(el, _, info)
  if not info.with_latex then
    return nil
  end
  return el.value
end

T["horizontal-rule"] = function()
  return "---"
end

T["line-break"] = function()
  return "  \n"
end

T["export-block"] = function(el)
  local t = el.back_end_type
  if t == "MARKDOWN" or t == "MD" or t == "GFM" or t == "HTML" then
    return el.value
  end
end

T["export-snippet"] = function(el)
  local b = el.back_end
  if b == "md" or b == "markdown" or b == "gfm" or b == "html" then
    return el.value
  end
end

T.keyword = function(el, _, info)
  local k = el.key
  if k == "MARKDOWN" or k == "MD" or k == "HTML" then
    return el.value
  elseif k == "TOC" and el.value:lower():match("headlines") then
    local depth = tonumber(el.value:match("(%d+)"))
    local scope = el.value:lower():match("%f[%w]local%f[%W]") and el or nil
    return M.toc(info, depth, scope)
  end
end

T.target = function(el, _, info)
  return fmt('<a id="%s"></a>', ox.get_reference(el, info))
end

T["radio-target"] = function(el, text, info)
  return fmt('<a id="%s"></a>', ox.get_reference(el, info)) .. (text or "")
end

T.table = function(el, _, info)
  if el.table_type == "table.el" then
    return fence(el.value)
  end
  local rows = {}
  local ncols = 0
  local header = ox.table_has_header_p(el, info)
  local first_group = {}
  for _, r in ipairs(el.contents) do
    if r.row_type == "standard" and not info.ignore[r] then
      local cells = {}
      for _, c in ipairs(r.contents) do
        if not info.ignore[c] then
          cells[#cells + 1] = (ox.data(c.contents, info):gsub("|", "\\|"))
        end
      end
      ncols = math.max(ncols, #cells)
      rows[#rows + 1] = cells
      first_group[#rows] = header and ox.table_row_group(r, info) == 1
    end
  end
  if #rows == 0 then
    return nil
  end
  local function line(cells)
    local parts = {}
    for c = 1, ncols do
      parts[c] = cells[c] or ""
    end
    return "| " .. table.concat(parts, " | ") .. " |"
  end
  local sep = {}
  for c = 1, ncols do
    sep[c] = "---"
  end
  local out = {}
  if not header then
    out[#out + 1] = line({})
    out[#out + 1] = "|" .. table.concat(sep, "|") .. "|"
  end
  for i, cells in ipairs(rows) do
    out[#out + 1] = line(cells)
    if header and first_group[i] and not first_group[i + 1] then
      out[#out + 1] = "|" .. table.concat(sep, "|") .. "|"
    end
  end
  local caption = ox.get_caption(el)
  if caption then
    table.insert(out, 1, "")
    table.insert(out, 1, "*" .. ox.data(caption, info) .. "*")
  end
  return table.concat(out, "\n")
end

T.link = function(el, desc, info)
  local t = el.link_type
  desc = (desc and desc ~= "") and desc or nil
  local custom = ox.custom_protocol_maybe(el, desc, "gfm", info)
  if custom then
    return custom
  end
  if t == "file" and ox.inline_image_p(el) and not desc then
    return "![" .. vim.fn.fnamemodify(el.path, ":t") .. "](" .. el.path .. ")"
  end
  if t == "custom-id" or t == "fuzzy" or t == "id" then
    local ok, dest = pcall(t == "fuzzy" and ox.resolve_fuzzy_link or ox.resolve_id_link, el, info)
    if not ok then
      error(dest, 0)
    end
    if dest.type == "plain-text" then
      return fmt("[%s](%s)", desc or dest.value, dest.value)
    elseif dest.type == "headline" then
      return fmt("[%s](#%s)", desc or ox.data(dest.title, info), anchor_of(dest, info))
    end
    return fmt("[%s](#%s)", desc or el.path, ox.get_reference(dest, info))
  elseif t == "coderef" then
    return tostring(ox.resolve_coderef(el.path, info))
  elseif t == "radio" then
    local dest = ox.resolve_radio_link(el, info)
    return dest and fmt("[%s](#%s)", desc or el.path, ox.get_reference(dest, info)) or desc
  end
  local url = t == "file" and el.path or (t .. ":" .. el.path)
  if t == "file" and url:lower():match("%.org$") then
    url = url:sub(1, -5) .. ".md"
  end
  local ext = url:match("%.(%w+)$")
  if not desc and ext and vim.tbl_contains(ox.DEFAULT_IMAGE_EXT, ext:lower()) then
    return "![" .. vim.fn.fnamemodify(url, ":t") .. "](" .. url .. ")"
  end
  if not desc and el.format == "plain" then
    return "<" .. url .. ">"
  end
  return "[" .. (desc or url) .. "](" .. url .. ")"
end

T.planning = function(el, _, info)
  local parts = {}
  if el.deadline then
    parts[#parts + 1] = "DEADLINE: " .. ox.timestamp_translate(el.deadline)
  end
  if el.scheduled then
    parts[#parts + 1] = "SCHEDULED: " .. ox.timestamp_translate(el.scheduled)
  end
  if el.closed then
    parts[#parts + 1] = "CLOSED: " .. ox.timestamp_translate(el.closed)
  end
  _ = info
  return "`" .. table.concat(parts, " ") .. "`"
end

T.clock = function(el)
  return "`CLOCK: " .. ox.timestamp_translate(el.value) .. (el.duration and (" => " .. el.duration) or "") .. "`"
end

T["property-drawer"] = function(_, contents)
  if ox.nw(contents) then
    return fence(contents)
  end
end

T["node-property"] = function(el)
  return el.key .. ":" .. (el.value and (" " .. el.value) or "")
end

T.subscript = function(_, c)
  return "<sub>" .. (c or "") .. "</sub>"
end
T.superscript = function(_, c)
  return "<sup>" .. (c or "") .. "</sup>"
end
T["statistics-cookie"] = function(el)
  return el.value
end

T.inlinetask = function(el, contents, info)
  return "**" .. headline_text(el, info) .. "**\n\n" .. (contents or "")
end

function M.toc(info, depth, scope)
  local out = {}
  for _, h in ipairs(ox.collect_headlines(info, depth, scope)) do
    local ind = string.rep("  ", ox.get_relative_level(h, info) - 1)
    local text = ox.data_with_backend(ox.get_alt_title(h), ox.toc_entry_backend("gfm"), info)
    out[#out + 1] = ind .. "- [" .. text .. "](#" .. anchor_of(h, info) .. ")"
  end
  if #out == 0 then
    return nil
  end
  if scope then
    return table.concat(out, "\n")
  end
  return string.rep("#", 1 + (info.gfm_shift or 0)) .. " " .. ox.translate("Table of Contents", "utf-8", info) .. "\n\n" .. table.concat(out, "\n")
end

T.inner_template = function(contents, info)
  local parts = {}
  local depth = info.with_toc
  if depth then
    local toc = M.toc(info, type(depth) == "number" and depth or nil)
    if toc then
      parts[#parts + 1] = toc .. "\n\n"
    end
  end
  parts[#parts + 1] = contents
  local defs = ox.collect_footnote_definitions(info)
  if #defs > 0 then
    local notes = {}
    for _, d in ipairs(defs) do
      notes[#notes + 1] = indent_lines(trim(ox.data(d[3], info)), "    ", fmt("[^%d]: ", d[1]))
    end
    parts[#parts + 1] = "\n" .. table.concat(notes, "\n")
  end
  return table.concat(parts)
end

T.template = function(contents, info)
  if not (info.with_title and info.title) then
    return contents
  end
  local head = "# " .. ox.data(info.title, info) .. "\n\n"
  if info.subtitle then
    head = head .. "*" .. ox.data(info.subtitle, info) .. "*\n\n"
  end
  return head .. contents
end

M.transcoders = T

M.backend = ox.define_backend("gfm", {
  parent = "md",
  transcoders = T,
  filters = {
    options = {
      function(info)
        -- headings go one level below the "# Title" line of full documents
        if info.with_title and info.title and not (info.export_options or {}).body_only then
          info.gfm_shift = 1
        end
        return info
      end,
    },
  },
})

return M

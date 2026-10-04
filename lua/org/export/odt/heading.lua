---@mod org.export.odt.heading ODT headlines and table of contents
---
--- Headline text and numbering (org-odt-format-headline-function) and
--- the table of contents (org-odt-toc).
---
--- Part of org.export.odt, which loads it.

local ox = require("org.export.ox")
local shared = require("org.export.odt.shared")

local M = require("org.export.odt")

local fmt = string.format

local span = shared.span

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

-- Locals the later parts share
shared.headline_numbers = headline_numbers
shared.format_headline_wrap = format_headline_wrap

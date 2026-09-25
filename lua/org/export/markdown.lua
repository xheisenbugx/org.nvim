---@mod org.export.markdown Markdown back-end (port of Emacs ox-md.el)
---
--- Derived from the HTML back-end, like Emacs: tables, special blocks and
--- centered blocks are written as HTML, code is indented by four spaces
--- and footnotes use <sup> links. See `org.export.gfm` for GitHub
--- flavoured Markdown.

local ox = require("org.export.ox")
local element = require("org.export.element")
local html = require("org.export.html")

local M = {}

M.extension = "md"

local fmt = string.format
local nw = ox.nw
local trim = ox.trim

local function mcfg()
  return (require("org.config").opts.export or {}).md or {}
end

local function translate(s, info)
  return ox.translate(s, "html", info)
end

local function indent4(s)
  return (s:gsub("\n(.)", "\n    %1"):gsub("^(.)", "    %1"))
end

--- "^" -> "    " on every line, like (replace-regexp-in-string "^" "    " s)
local function prefix_lines(s, p)
  local out = {}
  local ends = s:match("\n$") ~= nil
  local body = ends and s:sub(1, -2) or s
  for line in (body .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = p .. line
  end
  local r = table.concat(out, "\n")
  if ends then
    r = r .. "\n" .. p
  end
  return r
end
M.prefix_lines = prefix_lines
_ = indent4

local function make_tag_string(tags)
  if not tags or #tags == 0 then
    return ""
  end
  return ":" .. table.concat(tags, ":") .. ":"
end

local function headline_referred_p(h, info)
  if h.footnote_section_p then
    return false
  end
  if info.with_toc then
    for _, x in ipairs(ox.collect_headlines(info, type(info.with_toc) == "number" and info.with_toc or nil)) do
      if x == h then
        return true
      end
    end
  end
  local p = h.parent
  while p do
    if p.type == "headline" or p.type == "org-data" then
      local section = p.contents[1]
      if section and section.type == "section" then
        local hit = element.map(section, "keyword", function(k)
          if k.key == "TOC" then
            local v = k.value:lower()
            if v:match("%f[%w]headlines%f[%W]") then
              local n = tonumber(k.value:match("%f[%d](%d+)%f[%D]"))
              local localp = v:match("%f[%w]local%f[%W]")
              for _, x in ipairs(ox.collect_headlines(info, n, localp and k or nil)) do
                if x == h then
                  return true
                end
              end
            end
          end
        end, { first_match = true, ignore = info.ignore })
        if hit then
          return true
        end
      end
    end
    p = p.parent
  end
  return element.map(info.parse_tree, "link", function(l)
    local ok, dest = pcall(ox.resolve_id_link, l, info)
    if ok and dest == h then
      return true
    end
  end, { first_match = true, ignore = info.ignore }) == true
end

local function headline_title(style, level, title, anchor, tags)
  local anchor_lines = anchor and (anchor .. "\n\n") or ""
  if (style == "setext" or style == "mixed") and level < 3 then
    local ch = level == 1 and "=" or "-"
    return "\n" .. anchor_lines .. title .. (tags or "") .. "\n" .. string.rep(ch, vim.fn.strchars(title)) .. "\n\n"
  end
  return "\n" .. anchor_lines .. string.rep("#", level) .. " " .. title .. (tags or "") .. "\n\n"
end

local function build_toc(info, n, scope)
  local out = {}
  if not scope then
    out[#out + 1] = headline_title(info.md_headline_style, info.md_toplevel_hlevel, translate("Table of Contents", info))
  end
  local entries = {}
  for _, h in ipairs(ox.collect_headlines(info, n, scope)) do
    local indentation = string.rep(" ", 4 * (ox.get_relative_level(h, info) - 1))
    local bullet
    if not ox.numbered_headline_p(h, info) then
      bullet = "-   "
    else
      local num = ox.get_headline_number(h, info)
      local prefix = fmt("%d.", num[#num])
      bullet = prefix .. string.rep(" ", math.max(1, 4 - #prefix))
    end
    local title = fmt(
      "[%s](#%s)",
      ox.data_with_backend(ox.get_alt_title(h), ox.toc_entry_backend("md"), info),
      (h.props and h.props.CUSTOM_ID) or ox.get_reference(h, info)
    )
    local tags = ""
    if info.with_tags and info.with_tags ~= "not-in-toc" then
      tags = make_tag_string(ox.get_tags(h, info))
    end
    entries[#entries + 1] = indentation .. bullet .. title .. tags
  end
  out[#out + 1] = table.concat(entries, "\n")
  out[#out + 1] = "\n"
  return table.concat(out)
end

local function footnote_section(info)
  local defs = ox.collect_footnote_definitions(info)
  if #defs == 0 then
    return nil
  end
  local items = {}
  for _, d in ipairs(defs) do
    local n = d[1]
    local text = trim(ox.data(d[3], info))
    local a = fmt('<a id="fn.%d" href="#fnr.%d">%d</a>', n, n, n)
    items[#items + 1] = fmt(info.md_footnote_format, a) .. " " .. text .. "\n"
  end
  local title = headline_title(info.md_headline_style, info.md_toplevel_hlevel, translate("Footnotes", info))
  local i = 0
  return (info.md_footnotes_section:gsub("%%s", function()
    i = i + 1
    return i == 1 and title or table.concat(items, "\n")
  end))
end

local function convert_to_html(datum, _, info)
  return ox.data_with_backend(datum, "html", info)
end

local T = {}

T.bold = function(_, contents)
  return fmt("**%s**", contents or "")
end

T.italic = function(_, contents)
  return fmt("*%s*", contents or "")
end

local function verbatim(el)
  local v = el.value
  if not v:find("`", 1, true) then
    return fmt("`%s`", v)
  elseif v:sub(1, 1) == "`" or v:sub(-1) == "`" then
    return fmt("`` %s ``", v)
  end
  return fmt("``%s``", v)
end
T.verbatim = verbatim
T.code = verbatim
T["inline-src-block"] = verbatim

T["center-block"] = convert_to_html
T.inlinetask = convert_to_html
T["special-block"] = convert_to_html
T.table = convert_to_html

T.drawer = function(_, contents)
  return contents
end
T["dynamic-block"] = function(_, contents)
  return contents
end

local function example_block(el, _, info)
  local code = ox.format_code_default(el, info)
  local lines = element.remove_indentation(vim.split((code:gsub("\n$", "")), "\n", { plain = true }))
  local s = table.concat(lines, "\n") .. (code:match("\n$") and "\n" or "")
  return prefix_lines(s, "    ")
end
T["example-block"] = example_block
T["src-block"] = example_block
T["fixed-width"] = function(el, _, info)
  -- fixed-width elements are formatted like example blocks
  local fake = { value = el.value .. "\n", type = "example-block" }
  return example_block(fake, nil, info)
end

T["export-block"] = function(el, contents, info)
  if el.back_end_type == "MARKDOWN" or el.back_end_type == "MD" then
    return table.concat(element.remove_indentation(vim.split((el.value:gsub("\n$", "")), "\n", { plain = true })), "\n")
      .. "\n"
  end
  return ox.with_backend("html", el, contents, info)
end

T.headline = function(el, contents, info)
  if el.footnote_section_p then
    return nil
  end
  local level = ox.get_relative_level(el, info) + info.md_toplevel_hlevel - 1
  local title = ox.data(el.title, info)
  local todo = info.with_todo_keywords and el.todo_keyword and (el.todo_keyword .. " ") or ""
  local tags = ""
  if info.with_tags then
    local tl = ox.get_tags(el, info)
    if #tl > 0 then
      tags = "     " .. make_tag_string(tl)
    end
  end
  local priority = (info.with_priority and el.priority) and fmt("[#%s] ", el.priority) or ""
  local heading = todo .. priority .. title
  local style = info.md_headline_style
  if
    ox.low_level_p(el, info)
    or not (style == "atx" or style == "mixed" or style == "setext")
    or (style == "atx" and level > 6)
    or (style == "setext" and level > 2)
    or (style == "mixed" and level > 6)
  then
    local bullet
    if not ox.numbered_headline_p(el, info) then
      bullet = "-"
    else
      local num = ox.get_headline_number(el, info)
      bullet = tostring(num[#num]) .. "."
    end
    return bullet .. string.rep(" ", 4 - #bullet) .. heading .. tags .. "\n\n" .. (contents and prefix_lines(contents, "    ") or "")
  end
  local anchor
  if headline_referred_p(el, info) then
    anchor = fmt('<a id="%s"></a>', (el.props and el.props.CUSTOM_ID) or ox.get_reference(el, info))
  end
  return headline_title(style, level, heading, anchor, tags) .. (contents or "")
end

T["horizontal-rule"] = function()
  return "---"
end

T.item = function(el, contents, info)
  local list = el.parent
  local bullet
  if list.list_type ~= "ordered" then
    bullet = "-"
  else
    local num = ox.get_ordinal(el, info)
    bullet = tostring(num[#num]) .. "."
  end
  local box = ({ on = "[X] ", trans = "[-] ", off = "[ ] " })[el.checkbox or ""] or ""
  local tag = el.tag and fmt("**%s:** ", ox.data(el.tag, info)) or ""
  return bullet .. string.rep(" ", math.max(1, 4 - #bullet)) .. box .. tag .. (contents and trim(prefix_lines(contents, "    ")) or "")
end

T.keyword = function(el, contents, info)
  local k = el.key
  if k == "MARKDOWN" or k == "MD" then
    return el.value
  elseif k == "TOC" then
    local v = el.value
    if v:lower():match("%f[%w]headlines%f[%W]") then
      local depth = tonumber(v:match("%f[%d](%d+)%f[%D]"))
      local scope
      local target = v:match(':target +(".-")') or v:match(":target +(%S+)")
      if target then
        scope = ox.resolve_link((target:gsub('^"(.*)"$', "%1")), info)
      elseif v:lower():match("%f[%w]local%f[%W]") then
        scope = el
      end
      local toc = build_toc(info, depth, scope)
      local lines = element.remove_indentation(vim.split((toc:gsub("\n$", "")), "\n", { plain = true }))
      return table.concat(lines, "\n") .. (toc:match("\n$") and "\n" or "")
    end
    return nil
  end
  return ox.with_backend("html", el, contents, info)
end

T["latex-environment"] = function(el, _, info)
  if not info.with_latex then
    return nil
  end
  local lines = element.remove_indentation(vim.split((el.value:gsub("\n$", "")), "\n", { plain = true }))
  local frag = table.concat(lines, "\n") .. "\n"
  local label = html.reference(el, info, true)
  if nw(label) then
    frag = frag:gsub("^([^\n]*)", "%1\n\\label{" .. label .. "}", 1)
  end
  return frag
end

T["latex-fragment"] = function(el, _, info)
  if not info.with_latex then
    return nil
  end
  local frag = el.value
  if frag:sub(1, 2) == "\\(" then
    return "$" .. frag:sub(3, -3) .. "$"
  elseif frag:sub(1, 2) == "\\[" then
    return "$$" .. frag:sub(3, -3) .. "$$"
  end
  return frag
end

T["line-break"] = function()
  return "  \n"
end

local function org_as_md(raw, info)
  if info.md_link_org_files_as_md and raw:lower():match("%.org$") then
    return raw:sub(1, -5) .. ".md"
  end
  return raw
end

T.link = function(el, desc, info)
  local ltype = el.link_type
  local raw = el.path
  local path
  if ltype == "file" then
    path = ox.file_uri(org_as_md(raw, info))
  else
    path = ltype .. ":" .. raw
  end
  desc = (desc ~= nil and desc ~= "") and desc or nil
  local custom = ox.custom_protocol_maybe(el, desc, "md", info)
  if custom then
    return custom
  end
  if ltype == "custom-id" or ltype == "id" or ltype == "fuzzy" then
    local dest = ltype == "fuzzy" and ox.resolve_fuzzy_link(el, info) or ox.resolve_id_link(el, info)
    if dest.type == "plain-text" then
      local p = org_as_md(dest.value, info)
      if not desc then
        return fmt("<%s>", p)
      end
      return fmt("[%s](%s)", desc, p)
    elseif dest.type == "headline" then
      local d = nw(desc)
      if not d then
        if ox.numbered_headline_p(dest, info) then
          local parts = {}
          for i, x in ipairs(ox.get_headline_number(dest, info) or {}) do
            parts[i] = tostring(x)
          end
          d = table.concat(parts, ".")
        else
          d = ox.data(dest.title, info)
        end
      end
      return fmt("[%s](#%s)", d, (dest.props and dest.props.CUSTOM_ID) or ox.get_reference(dest, info))
    else
      local d = nw(desc)
      if not d then
        local number = ox.get_ordinal(dest, info)
        if number == nil then
          d = nil
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
      if d then
        return fmt("[%s](#%s)", d, ox.get_reference(dest, info))
      end
      return nil
    end
  end
  if ox.inline_image_p(el, html.inline_image_rules) then
    local p
    if ltype ~= "file" then
      p = ltype .. ":" .. raw
    elseif not (raw:match("^/") or raw:match("^~")) then
      p = raw
    else
      p = vim.fn.fnamemodify(vim.fn.expand(raw), ":p")
    end
    local caption = ox.data(ox.get_caption(element.parent_element(el)) or {}, info)
    return fmt("![img](%s)", nw(caption) and fmt('%s "%s"', p, caption) or p)
  end
  if ltype == "coderef" then
    local f = ox.get_coderef_format(path, desc)
    local r = ox.resolve_coderef(raw, info)
    return (f:gsub("%%s", function()
      return tostring(r)
    end))
  end
  if ltype == "radio" then
    local dest = ox.resolve_radio_link(el, info)
    if not dest then
      return desc
    end
    return fmt('<a href="#%s">%s</a>', ox.get_reference(dest, info), desc or "")
  end
  if not desc then
    return fmt("<%s>", path)
  end
  return fmt("[%s](%s)", desc, path)
end

T["node-property"] = function(el)
  return fmt("%s:%s", el.key, el.value and (" " .. el.value) or "")
end

T.paragraph = function(el, contents)
  contents = (contents or ""):gsub("\n[ \t\n]*\n", "\n")
  local first = el.contents[1]
  if first and first.type == "plain-text" and first.value:sub(1, 1) == "#" then
    return "\\" .. contents
  end
  return contents
end

T["plain-list"] = function(_, contents)
  return contents
end

function M.plain_text(text, info, node)
  if info.with_smart_quotes and node then
    text = ox.activate_smart_quotes(text, "html", info, node)
  end
  text = text:gsub("([`%*_\\])", "\\%1")
  text = text:gsub("\n#", "\n\\#")
  text = text:gsub("!%[", "\\![")
  if info.with_special_strings then
    text = html.convert_special_strings(text)
  end
  if info.preserve_breaks then
    text = text:gsub("[ \t]*\n", "  \n")
  end
  return text
end

T["plain-text"] = function(text, info, node)
  return M.plain_text(text, info, node)
end

T["property-drawer"] = function(_, contents)
  if nw(contents) then
    return prefix_lines(contents, "    ")
  end
end

T["quote-block"] = function(_, contents)
  return prefix_lines((contents or ""):gsub("\n$", ""), "> ")
end

T.section = function(_, contents)
  return contents
end

T.inner_template = function(contents, info)
  local depth = info.with_toc
  return (depth and (build_toc(info, type(depth) == "number" and depth or nil) .. "\n") or "")
    .. contents
    .. "\n"
    .. (footnote_section(info) or "")
end

T.template = function(contents)
  return contents
end

M.transcoders = T

local function separate_elements(tree, _, info)
  local types = {}
  for k in pairs(element.ELEMENTS) do
    if k ~= "item" and k ~= "table-row" and k ~= "org-data" then
      types[k] = true
    end
  end
  element.map(tree, types, function(e)
    local pb = 1
    if e.type == "paragraph" and e.parent and e.parent.type == "item" and ox.first_sibling_p(e, info) then
      local nxt = ox.get_next_element(e, info)
      if nxt and nxt.type == "plain-list" and not ox.get_next_element(nxt, info) then
        pb = 0
      end
    end
    e.post_blank = pb
  end, { ignore = info.ignore })
  return tree
end

M.backend = ox.define_backend("md", {
  parent = "html",
  transcoders = T,
  options = function()
    local c = mcfg()
    local function v(name, default)
      if c[name] == nil then
        return default
      end
      return c[name]
    end
    return {
      { "md_footnote_format", nil, nil, v("footnote_format", "<sup>%s</sup>") },
      { "md_footnotes_section", nil, nil, v("footnotes_section", "%s%s") },
      { "md_headline_style", nil, nil, v("headline_style", "atx") },
      { "md_toplevel_hlevel", nil, nil, v("toplevel_hlevel", 1) },
      { "md_link_org_files_as_md", nil, nil, v("link_org_files_as_md", true) },
    }
  end,
  filters = {
    ["parse-tree"] = { separate_elements },
  },
})

return M

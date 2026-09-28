---@mod org.export.texinfo Texinfo back-end (port of Emacs ox-texinfo.el)
---
--- Writes a complete .texi manual: header (#+TEXINFO_* keywords), copying
--- section (headline with a COPYING property), title page, @contents, the
--- Top node and a master menu with a detailed node listing, one @node per
--- headline with the sectioning commands of the class, menus, indices,
--- floats and definition commands. `compile()` runs makeinfo to produce an
--- Info file (org-texinfo-export-to-info).

local ox = require("org.export.ox")
local element = require("org.export.element")
local entities = require("org.export.entities")

local M = {}

M.extension = "texi"

local nw = ox.nw
local trim = ox.trim
local fmt = string.format

local function tcfg()
  return (require("org.config").opts.export or {}).texinfo or {}
end

--- org-texinfo-classes
M.classes = {
  {
    "info",
    "@documentencoding AUTO\n@documentlanguage AUTO",
    { "@chapter %s", "@unnumbered %s", "@chapheading %s", "@appendix %s" },
    { "@section %s", "@unnumberedsec %s", "@heading %s", "@appendixsec %s" },
    { "@subsection %s", "@unnumberedsubsec %s", "@subheading %s", "@appendixsubsec %s" },
    { "@subsubsection %s", "@unnumberedsubsubsec %s", "@subsubheading %s", "@appendixsubsubsec %s" },
  },
}

--- org-texinfo-max-toc-depth
M.MAX_TOC_DEPTH = 4

--- org-texinfo-supported-coding-systems
M.SUPPORTED_CODING_SYSTEMS = { "US-ASCII", "UTF-8", "ISO-8859-15", "ISO-8859-1", "ISO-8859-2", "koi8-r", "koi8-u" }

--- org-texinfo-inline-image-rules
M.inline_image_rules = { file = { "eps", "pdf", "png", "jpg", "jpeg", "gif", "svg" } }

--- org-texinfo--quoted-keys-regexp
local QUOTED_KEYS = {
  "BS",
  "TAB",
  "RET",
  "ESC",
  "SPC",
  "DEL",
  "LFD",
  "DELETE",
  "SHIFT",
  "Ctrl",
  "Meta",
  "Alt",
  "Cmd",
  "Super",
  "UP",
  "LEFT",
  "RIGHT",
  "DOWN",
}

--- org-texinfo--definition-command-alist: Info prefix -> command.
local DEFINITION_COMMANDS = {
  { "deffn Command", "Command" },
  { "defun", "Function" },
  { "defmac", "Macro" },
  { "defspec", "Special Form" },
  { "defvar", "Variable" },
  { "defopt", "User Option" },
  { nil, "Key" },
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- Escape @, { and } and turn commas into @comma{} (org-texinfo--sanitize-content).
local function sanitize_content(text)
  return (text:gsub("[@{}]", "@%0"):gsub(",", "@comma{}"))
end
M.sanitize_content = sanitize_content

local function find_verb_separator(s)
  local ll = "~,./?;':\"|!@#%^&-_=+abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ<>()[]{}"
  for i = 1, #ll do
    local c = ll:sub(i, i)
    if not s:find(c, 1, true) then
      return c
    end
  end
end

--- Apply a format string with a single "%s".
local function format1(f, s)
  return (f:gsub("%%s", function()
    return s
  end, 1))
end

local function text_markup(text, markup, info)
  local f = (info.texinfo_text_markup_alist or {})[markup]
  if f == nil then
    return text
  elseif f == "code" then
    return fmt("@code{%s}", sanitize_content(text))
  elseif f == "samp" then
    return fmt("@samp{%s}", sanitize_content(text))
  elseif f == "verb" then
    local sep = find_verb_separator(text)
    return fmt("@verb{%s%s%s}", sep, text, sep)
  end
  return format1(f, text)
end

--- Maybe prepend an @anchor named after the element's #+NAME.
local function prepend_anchor(contents, node)
  if node.name then
    return "@anchor{" .. node.name .. "}\n" .. (contents or "")
  end
  return contents
end

--- org-texinfo--sanitize-node: make a string suitable as a node name.
local function sanitize_node(title)
  local s = title
  -- a leading "(" followed by ")" on the line becomes "["
  if s:match("^%([^\n]-%)") then
    s = "[" .. s:sub(2)
  end
  s = s:gsub("@comma{}", ""):gsub("@comma", "")
  s = s:gsub("[:,.]", "")
  s = s:gsub("[ \t]+", " ")
  return trim(s)
end
M.sanitize_node = sanitize_node

local toc_backend, title_backend

--- Title as a section reference (org-texinfo--sanitize-title-reference).
local function sanitize_title_reference(title, info)
  toc_backend = toc_backend or ox.toc_entry_backend("texinfo")
  return ox.data_with_backend(title, toc_backend, info)
end

--- Title as a section name (org-texinfo--sanitize-title).
local function sanitize_title(title, info)
  title_backend = title_backend
    or ox.create_backend("texinfo", {
      ["footnote-reference"] = function()
        return nil
      end,
      ["radio-target"] = function(_, c)
        return c
      end,
      target = function()
        return nil
      end,
    })
  return ox.data_with_backend(title, title_backend, info)
end

--- Node or anchor name of a headline, radio target, target or element;
--- unique in the document and never "Top" (org-texinfo--get-node).
local function get_node(datum, info)
  local cache = info.texinfo_node_cache
  if not cache then
    cache = { by_datum = {}, names = {} }
    info.texinfo_node_cache = cache
  end
  if cache.by_datum[datum] then
    return cache.by_datum[datum]
  end
  local t = datum.type
  local base
  if t == "headline" then
    base = sanitize_title_reference(ox.get_alt_title(datum), info)
  elseif t == "radio-target" then
    base = ox.data(datum.contents, info)
  elseif t == "target" then
    base = datum.value
  else
    base = datum.name or ox.get_reference(datum, info)
  end
  base = sanitize_node(base)
  -- parents get their node first so that the first of two equal titles
  -- keeps the plain name
  local parent = element.lineage(datum, "headline")
  if parent and not cache.by_datum[parent] then
    get_node(parent, info)
  end
  local name = base
  local salt = 0
  while name:lower() == "top" or cache.names[name] do
    salt = salt + 1
    name = base .. fmt(" (%d)", salt)
  end
  cache.by_datum[datum] = name
  cache.names[name] = true
  return name
end
M.get_node = get_node

--- Wrap `value` in a @float (org-texinfo--wrap-float).
local function wrap_float(value, info, ftype, label, caption, short)
  local backend = ox.toc_entry_backend("texinfo", {
    ["footnote-reference"] = function(f, c, i)
      return ox.with_backend("texinfo", f, c, i)
    end,
  })
  local short_backend = ox.toc_entry_backend("texinfo", {
    ["inline-src-block"] = function()
      return nil
    end,
    verbatim = function()
      return nil
    end,
  })
  local short_str = (short and caption) and fmt("@shortcaption{%s}\n", ox.data_with_backend(short, short_backend, info))
    or ""
  local caption_str = ""
  if short or caption then
    local b = short_str == "" and short_backend or backend
    caption_str = fmt("@caption{%s}\n", ox.data_with_backend(caption or short, b, info))
  end
  return fmt("@float %s%s\n%s\n%s%s@end float", ftype, label and ("," .. label) or "", value, caption_str, short_str)
end

--- Sectioning structure of the class (org-texinfo--sectioning-structure).
local function sectioning_structure(info)
  local class = info.texinfo_class
  for _, c in ipairs(info.texinfo_classes or M.classes) do
    if c[1] == class then
      return { unpack(c, 3) }
    end
  end
  error(fmt("Unknown Texinfo class: %q", tostring(class)), 0)
end

local function not_nil(v)
  return v ~= nil and v ~= false and v ~= "nil"
end

--- Replace the trailing "\n" plus blank lines of `s` by exactly one blank
--- line (org-texinfo--filter-section-blank-lines).
local function section_blank_lines(s)
  -- leftmost "\n" such that the rest is a series of "\n[ \t]*"
  local p = s:find("\n[\n \t]*$")
  while p do
    local rest = s:sub(p + 1)
    if rest == "" or (rest:sub(1, 1) == "\n" and not rest:find("[^\n \t]")) then
      return s:sub(1, p - 1) .. "\n\n"
    end
    p = s:find("\n", p + 1, true)
  end
  return s
end

---------------------------------------------------------------------------
-- Parse tree filters
---------------------------------------------------------------------------

--- Every headline gets one blank line after it and a section before its
--- children, needed to hold a menu (org-texinfo--normalize-headlines).
local function normalize_headlines(tree, _, info)
  element.map(tree, "headline", function(hl)
    hl.post_blank = 1
    local first
    for _, c in ipairs(hl.contents) do
      if not info.ignore[c] and (c.type == "headline" or c.type == "section") then
        first = c
        break
      end
    end
    if #hl.contents > 0 and (not first or first.type ~= "section") then
      local sec = element.node("section", {})
      sec.parent = hl
      table.insert(hl.contents, 1, sec)
    end
  end, { ignore = info.ignore })
  return tree
end

local function insert_before(new, node)
  local sib = element.siblings(node)
  for i, x in ipairs(sib) do
    if x == node then
      table.insert(sib, i, new)
      new.parent = node.parent
      return
    end
  end
end

--- Texinfo definition command of a descriptive item ("Function: name
--- args"): returns command, arguments (org-texinfo--match-definition).
local function match_definition(item, info)
  if not item.tag then
    return nil, nil
  end
  local tag = ox.data(item.tag, info)
  for _, d in ipairs(DEFINITION_COMMANDS) do
    local prefix = d[2] .. ": "
    if tag:sub(1, #prefix) == prefix then
      local args = tag:sub(#prefix + 1):match("^([^\n]+)")
      if args then
        local cmd, category
        if d[1] then
          cmd, category = d[1]:match("^(%S+) ?(.*)$")
          category = category ~= "" and category or nil
        end
        return cmd, category and (category .. " " .. args) or args
      end
    end
  end
  return nil, nil
end

--- org-texinfo--massage-key-item: "Key: C-c C-c (cmd)" items get a @kbd
--- tag and @kindex / @findex entries.
local function massage_key_item(plain_list, item, args, info)
  local key, cmd
  local s = args:find(" +%(([^()]+)%) *$")
  if s then
    key = args:sub(1, s - 1)
    cmd = args:match(" +%(([^()]+)%) *$")
  else
    key = args
  end
  local tag = { element.node("raw", { value = M.kbd_macro(key, true) }) }
  if cmd then
    tag[#tag + 1] = element.text(" (")
    tag[#tag + 1] = element.node("code", { value = cmd, post_blank = 0 })
    tag[#tag + 1] = element.text(")")
  end
  for _, o in ipairs(tag) do
    o.parent = item
  end
  item.tag = tag
  local findex = item.texinfo_findex or {}
  local kindex = item.texinfo_kindex or {}
  local next_item = ox.get_next_element(item, nil)
  local mx = key:sub(1, 4) == "M-x "
  if not cmd and mx then
    cmd = key:sub(5)
  end
  if cmd and not vim.tbl_contains(findex, cmd) then
    findex[#findex + 1] = cmd
  end
  if not mx then
    kindex[#kindex + 1] = key
  end
  if
    next_item
    and (not_nil(info.texinfo_compact_itemx) or not_nil(ox.read_attribute("attr_texinfo", plain_list, "compact")))
    and #item.contents == 0
    and item.post_blank == 1
  then
    next_item.texinfo_findex = findex
    next_item.texinfo_kindex = kindex
    item.texinfo_findex = nil
    item.texinfo_kindex = nil
  else
    local kws = {}
    for _, k in ipairs(kindex) do
      kws[#kws + 1] = element.node("keyword", { key = "KINDEX", value = k })
    end
    for _, c in ipairs(findex) do
      kws[#kws + 1] = element.node("keyword", { key = "FINDEX", value = c })
    end
    for i = #kws, 1, -1 do
      kws[i].parent = item
      table.insert(item.contents, 1, kws[i])
    end
  end
end

--- Split descriptive lists holding definition items into tables and
--- definition special blocks (org-texinfo--separate-definitions).
local function separate_definitions(tree, _, info)
  local lists = element.map(tree, "plain-list", function(l)
    if l.list_type == "descriptive" then
      return l
    end
  end, { ignore = info.ignore })
  for _, plain_list in ipairs(lists) do
    local items = {}
    for _, item in ipairs(vim.list_slice(plain_list.contents)) do
      local cmd, args = match_definition(item, info)
      if cmd then
        if #items > 0 then
          local new = element.node("plain-list", {
            list_type = "descriptive",
            attr_texinfo = plain_list.attr_texinfo,
            post_blank = 1,
          })
          for _, it in ipairs(items) do
            element.extract(it)
            it.parent = new
            new.contents[#new.contents + 1] = it
          end
          insert_before(new, plain_list)
          items = {}
        end
        local block = element.node("special-block", {
          block_type = cmd,
          texinfo_options = args,
          post_blank = #item.contents > 0 and 1 or 0,
        })
        for _, c in ipairs(item.contents) do
          c.parent = block
          block.contents[#block.contents + 1] = c
        end
        item.contents = {}
        insert_before(block, plain_list)
        element.extract(item)
      else
        if args then
          massage_key_item(plain_list, item, args, info)
        end
        items[#items + 1] = item
      end
    end
    if #plain_list.contents == 0 then
      element.extract(plain_list)
    end
  end
  return tree
end

---------------------------------------------------------------------------
-- Menus
---------------------------------------------------------------------------

--- Direct children of `scope` needing a menu entry (org-texinfo--menu-entries).
local function menu_entries(scope, info)
  local cache = info.texinfo_entries_cache
  if not cache then
    cache = {}
    info.texinfo_entries_cache = cache
  end
  if cache[scope] then
    return cache[scope]
  end
  local max_depth = #sectioning_structure(info)
  local out = {}
  for _, h in ipairs(ox.collect_headlines(info, 1, scope)) do
    if not (not_nil(ox.get_node_property("COPYING", h, true)) or max_depth < ox.get_relative_level(h, info)) then
      out[#out + 1] = h
    end
  end
  cache[scope] = out
  return out
end

--- Pad `s` with spaces to `width` columns.
local function pad(s, width)
  local w = vim.fn.strdisplaywidth(s)
  if w >= width then
    return s
  end
  return s .. string.rep(" ", width - w)
end

local function format_entries(entries, info)
  local parts = {}
  for _, h in ipairs(entries) do
    -- colons separate the title from the node name
    local title = sanitize_title_reference(ox.get_alt_title(h), info):gsub("[ \t]*:+", "")
    local node = get_node(h, info)
    local entry = "* " .. title .. ":" .. (title == node and ":" or (" " .. node .. ". "))
    local desc = h.props and h.props.DESCRIPTION
    if desc then
      entry = pad(entry, info.texinfo_node_description_column or 32) .. " " .. desc
    end
    parts[#parts + 1] = entry
  end
  return ox.normalize_string(table.concat(parts, "\n"))
end

local function build_menu(scope, info, level)
  if not level then
    return format_entries(menu_entries(scope, info), info)
  elseif level == 0 then
    return "\n"
  end
  local parts = {}
  for _, h in ipairs(menu_entries(scope, info)) do
    local entries = menu_entries(h, info)
    if #entries > 0 then
      parts[#parts + 1] = fmt(
        "%s\n\n%s\n",
        ox.data_with_backend(ox.get_alt_title(h), ox.toc_entry_backend("texinfo"), info),
        format_entries(entries, info)
      ) .. build_menu(h, info, level - 1)
    end
  end
  return table.concat(parts)
end

--- @menu for `scope` (a headline or the parse tree); `master` adds the
--- detailed node listing (org-texinfo-make-menu).
function M.make_menu(scope, info, master)
  local menu = build_menu(scope, info)
  if not nw(menu) then
    return nil
  end
  local detail = ""
  if master then
    local depth = info.with_toc
    if not (type(depth) == "number" and depth >= 0) then
      depth = M.MAX_TOC_DEPTH
    end
    local d = build_menu(scope, info, depth)
    if nw(d) then
      detail = "\n@detailmenu\n--- The Detailed Node Listing ---\n\n" .. d .. "@end detailmenu\n"
    end
  end
  return ox.normalize_string(fmt("@menu\n%s@end menu", menu .. detail))
end

---------------------------------------------------------------------------
-- Template
---------------------------------------------------------------------------

local function strip_quotes(s)
  if type(s) ~= "string" then
    return s
  end
  return s:match('^"(.*)"$') or s
end

local function sans_extension(f)
  return (f:gsub("%.[^./]*$", ""))
end

local function output_file(info)
  local f = info.output_file
  if type(info.texinfo_output_file) == "function" then
    f = info.texinfo_output_file(info)
  end
  return f
end

local function coding_system()
  local name = tcfg().coding_system or "utf-8"
  for _, s in ipairs(M.SUPPORTED_CODING_SYSTEMS) do
    if name:lower():find(s:lower(), 1, true) then
      return s
    end
  end
  return "UTF-8"
end

local function class_header(info)
  for _, c in ipairs(info.texinfo_classes or M.classes) do
    if c[1] == info.texinfo_class then
      return c[2]
    end
  end
end

local function template(contents, info)
  local title = ox.data(info.title, info)
  local copying = element.map(info.parse_tree, "headline", function(hl)
    if not_nil(hl.props and hl.props.COPYING) and #hl.contents > 0 then
      return hl.contents
    end
  end, { first_match = true, ignore = info.ignore })
  local out = {
    "\\input texinfo    @c -*- texinfo -*-\n",
    "@c %**start of header\n",
  }
  local outfile = output_file(info)
  local file = strip_quotes(info.texinfo_filename) or (outfile and (sans_extension(outfile) .. ".info"))
  if file then
    out[#out + 1] = fmt("@setfilename %s\n", file)
  end
  out[#out + 1] = fmt("@settitle %s\n", title)
  local header = class_header(info)
  if header then
    local language = info.language or ""
    local lines = vim.split(header, "\n", { plain = true })
    for i, l in ipairs(lines) do
      if l == "@documentlanguage AUTO" then
        lines[i] = "@documentlanguage " .. language
      elseif l == "@documentencoding AUTO" then
        lines[i] = "@documentencoding " .. coding_system()
      end
    end
    out[#out + 1] = ox.normalize_string(table.concat(lines, "\n"))
  end
  if info.texinfo_header then
    out[#out + 1] = ox.normalize_string(info.texinfo_header)
  end
  out[#out + 1] = "@c %**end of header\n\n"
  if info.texinfo_post_header then
    out[#out + 1] = ox.normalize_string(info.texinfo_post_header)
  end
  if copying then
    out[#out + 1] = fmt("@copying\n%s@end copying\n\n", ox.normalize_string(ox.data(copying, info)))
  end
  -- @direntry: "* DIRNAME: (FILENAME).   DESCRIPTION."
  local dircat = info.texinfo_dircat or "Misc"
  local dfile = strip_quotes(info.texinfo_filename) or outfile
  dfile = dfile and sans_extension(dfile)
  local dn = info.texinfo_dirname or info.texinfo_dirtitle
  if dn then
    dn = dn:gsub("%.$", "")
  end
  local dirname
  if dn and (dn:match("^%* ") or dn:match("%(.*%)")) then
    dirname = fmt("* %s.", dn:match("^%* (.*)$") or dn)
  elseif dn then
    dirname = fmt("* %s: (%s).", dn, dfile or dn)
  else
    dirname = fmt("* (%s).", dfile or "nil")
  end
  local dirdesc = info.texinfo_dirdesc or title
  if dirdesc and not dirdesc:match("%.$") then
    dirdesc = dirdesc .. "."
  end
  out[#out + 1] = "@dircategory " .. dircat .. "\n@direntry\n"
  out[#out + 1] = dirdesc and (pad(dirname, 23) .. " " .. dirdesc) or dirname
  out[#out + 1] = "\n@end direntry\n\n"
  out[#out + 1] = "@finalout\n@titlepage\n"
  if info.with_title then
    out[#out + 1] = fmt("@title %s\n", info.texinfo_printed_title or title or "")
    if info.subtitle then
      out[#out + 1] = fmt("@subtitle %s\n", ox.data(info.subtitle, info))
    end
  end
  if info.with_author then
    local author = ox.data(info.author, info)
    author = nw(author) and author or nil
    local email = info.with_email and ox.data(info.email, info) or nil
    email = nw(email) and email or nil
    if author and email then
      out[#out + 1] = fmt("@author %s (@email{%s})\n", author, email)
    elseif author then
      out[#out + 1] = fmt("@author %s\n", author)
    elseif email then
      out[#out + 1] = fmt("@author @email{%s}\n", email)
    end
    if info.subauthor then
      out[#out + 1] = ox.normalize_string((("\n" .. info.subauthor):gsub("\n", "\n@author "):sub(2)))
    end
  end
  if copying then
    out[#out + 1] = "@page\n@vskip 0pt plus 1filll\n@insertcopying\n"
  end
  out[#out + 1] = "@end titlepage\n\n"
  if info.with_toc then
    out[#out + 1] = "@contents\n\n"
  end
  out[#out + 1] = "@ifnottex\n@node Top\n"
  out[#out + 1] = fmt("@top %s\n", title)
  -- text before the first headline belongs to the Top node
  local first_section
  for _, c in ipairs(info.parse_tree.contents) do
    if c.type == "section" and not info.ignore[c] then
      first_section = c
      break
    elseif c.type == "headline" then
      break
    end
  end
  local top = first_section and ox.data(first_section.contents, info) or ""
  if nw(top) then
    out[#out + 1] = "\n" .. top
  end
  out[#out + 1] = "@end ifnottex\n\n"
  out[#out + 1] = M.make_menu(info.parse_tree, info, true) or ""
  out[#out + 1] = "\n"
  out[#out + 1] = contents
  out[#out + 1] = "\n"
  if info.with_creator then
    out[#out + 1] = (info.creator or "") .. "\n"
  end
  out[#out + 1] = "@bye"
  return table.concat(out)
end
M.template = template

---------------------------------------------------------------------------
-- Transcoders
---------------------------------------------------------------------------

local T = {}
M.transcoders = T

T.template = template

T.bold = function(_, contents, info)
  return text_markup(contents or "", "bold", info)
end
T.italic = function(_, contents, info)
  return text_markup(contents or "", "italic", info)
end
T.underline = function(_, contents, info)
  return text_markup(contents or "", "underline", info)
end
T["strike-through"] = function(_, contents, info)
  return text_markup(contents or "", "strike-through", info)
end
T.code = function(el, _, info)
  return text_markup(el.value, "code", info)
end
T.verbatim = function(el, _, info)
  return text_markup(el.value, "verbatim", info)
end

T["center-block"] = function(el, contents)
  local lines = vim.split(contents or "", "\n", { plain = true })
  for i, l in ipairs(lines) do
    if l:find("%S") then
      lines[i] = "@center " .. l
    end
  end
  return prepend_anchor(table.concat(lines, "\n"), el)
end

T.clock = function(el, _, info)
  local value = ox.timestamp_translate(el.value) .. (el.duration and fmt(" (%s)", el.duration) or "")
  return "@noindent" .. "@strong{CLOCK:} " .. format1(info.texinfo_inactive_timestamp_format, value) .. "@*"
end

T.drawer = function(el, contents, info)
  local f = info.texinfo_format_drawer_function
  local output = type(f) == "function" and f(el.drawer_name, contents) or contents
  return prepend_anchor(output, el)
end

T["dynamic-block"] = function(el, contents)
  return prepend_anchor(contents, el)
end

local ENTITIES = {
  AElig = "@AE{}",
  aelig = "@ae{}",
  bull = "@bullet{}",
  bullet = "@bullet{}",
  copy = "@copyright{}",
  deg = "@textdegree{}",
  dots = "@dots{}",
  hellip = "@dots{}",
  equiv = "@equiv{}",
  euro = "@euro{}",
  EUR = "@euro{}",
  ge = "@geq{}",
  geq = "@geq{}",
  laquo = "@guillemetleft{}",
  iexcl = "@exclamdown{}",
  imath = "@dotless{i}",
  iquest = "@questiondown{}",
  jmath = "@dotless{j}",
  le = "@leq{}",
  leq = "@leq{}",
  lsaquo = "@guilsinglleft{}",
  mdash = "---",
  minus = "@minus{}",
  nbsp = "@tie{}",
  ndash = "--",
  OElig = "@OE{}",
  oelig = "@oe{}",
  ordf = "@ordf{}",
  ordm = "@ordm{}",
  pound = "@pound{}",
  raquo = "@guillemetright{}",
  rArr = "@result{}",
  Rightarrow = "@result{}",
  reg = "@registeredsymbol{}",
  rightarrow = "@arrow{}",
  to = "@arrow{}",
  rarr = "@arrow{}",
  rsaquo = "@guilsinglright{}",
  thorn = "@th{}",
  THORN = "@TH{}",
}

T.entity = function(el)
  local name = el.name
  if ENTITIES[name] then
    return ENTITIES[name]
  elseif name:sub(1, 1) == "_" then
    return fmt("@w{%s}", name:sub(2))
  end
  local e = entities[name]
  return e and e[6] or ("\\" .. name)
end

T["example-block"] = function(el, _, info)
  return prepend_anchor(fmt("@example\n%s@end example", sanitize_content(ox.format_code_default(el, info))), el)
end

T["export-block"] = function(el)
  if el.back_end_type == "TEXINFO" then
    return table.concat(element.remove_indentation(vim.split((el.value:gsub("\n$", "")), "\n", { plain = true })), "\n")
      .. "\n"
  end
end

T["export-snippet"] = function(el)
  local tr = (require("org.config").opts.export or {}).snippet_translation or {}
  if (tr[el.back_end] or el.back_end) == "texinfo" then
    return el.value
  end
end

T["fixed-width"] = function(el)
  local lines = element.remove_indentation(vim.split(sanitize_content(el.value), "\n", { plain = true }))
  return prepend_anchor(fmt("@example\n%s\n@end example", table.concat(lines, "\n")), el)
end

T["footnote-reference"] = function(el, _, info)
  local def = ox.get_footnote_definition(el, info)
  local data = ox.data(def, info)
  -- a footnote may not close on a line starting with "@end"; when it ends
  -- with a paragraph, the brace can follow the text
  local last = type(def) == "table" and def[#def] or nil
  if last and last.type == "paragraph" then
    data = trim(data)
  end
  return fmt("@footnote{%s}", data)
end

--- org-texinfo-format-headline-default-function
function M.format_headline(todo, _todo_type, priority, text, tags)
  return (todo and fmt("@strong{%s} ", todo) or "")
    .. (priority and fmt("@emph{#%s} ", priority) or "")
    .. (text or "")
    .. ((tags and #tags > 0) and (" :" .. table.concat(tags, ":") .. ":") or "")
end

T.headline = function(el, contents, info)
  if el.footnote_section_p or not_nil(ox.get_node_property("COPYING", el, true)) then
    return nil
  end
  local index = ox.get_node_property("INDEX", el, true)
  if not vim.tbl_contains({ "cp", "fn", "ky", "pg", "tp", "vr" }, index) then
    index = nil
  end
  local numbered = ox.numbered_headline_p(el, info)
  local notoc = ox.excluded_from_toc_p(el, info)
  local command
  if not ox.low_level_p(el, info) then
    local sections = sectioning_structure(info)
    local sec = sections[ox.get_relative_level(el, info)]
    if sec then
      if type(sec) ~= "table" or #sec ~= 4 then
        error(fmt("Invalid Texinfo class specification: %q", tostring(info.texinfo_class)), 0)
      end
      if not_nil(ox.get_node_property("APPENDIX", el, true)) then
        command = sec[4]
      elseif numbered then
        command = sec[1]
      elseif index then
        command = sec[2]
      elseif notoc then
        command = sec[3]
      else
        command = sec[2]
      end
    end
  end
  local todo = info.with_todo_keywords and el.todo_keyword and ox.data(el.todo_keyword, info) or nil
  local todo_type = todo and el.todo_type
  local tags = info.with_tags and ox.get_tags(el, info) or nil
  if tags and #tags == 0 then
    tags = nil
  end
  local priority = info.with_priority and el.priority or nil
  local text = command and sanitize_title_reference(el.title, info) or sanitize_title(el.title, info)
  local f = info.texinfo_format_headline_function
  local full = (type(f) == "function" and f or M.format_headline)(todo, todo_type, priority, text, tags)
  contents = "\n" .. (nw(contents) and ("\n" .. contents) or "") .. (index and fmt("\n@printindex %s\n", index) or "")
  local node = get_node(el, info)
  if not command then
    local kind = numbered and "enumerate" or "itemize"
    return (ox.first_sibling_p(el, info) and fmt("@%s\n", kind) or "")
      .. fmt("@item\n@anchor{%s}%s\n", node, full)
      .. contents
      .. (ox.last_sibling_p(el, info) and fmt("@end %s", kind) or "\n")
  end
  -- @subheading and friends still get an anchor for cross-references
  return fmt(notoc and "@anchor{%s}\n" or "@node %s\n", node) .. format1(command, full) .. contents
end

T["inline-src-block"] = function(el)
  return fmt("@code{%s}", sanitize_content(el.value))
end

--- org-texinfo-format-inlinetask-default-function
function M.format_inlinetask(todo, _todo_type, priority, title, tags, contents)
  local full = (todo and fmt("@strong{%s} ", todo) or "")
    .. (priority and fmt("#%s ", priority) or "")
    .. title
    .. ((tags and #tags > 0) and (":" .. table.concat(tags, ":") .. ":") or "")
  return fmt("@center %s\n\n%s\n", full, contents or "")
end

T.inlinetask = function(el, contents, info)
  local title = ox.data(el.title, info)
  local todo = info.with_todo_keywords and el.todo_keyword and ox.data(el.todo_keyword, info) or nil
  local tags = info.with_tags and ox.get_tags(el, info) or nil
  if tags and #tags == 0 then
    tags = nil
  end
  local priority = info.with_priority and el.priority or nil
  local f = info.texinfo_format_inlinetask_function
  return (type(f) == "function" and f or M.format_inlinetask)(todo, el.todo_type, priority, title, tags, contents)
end

local function compact_p(plain_list, info)
  return plain_list.list_type == "descriptive"
    and (not_nil(info.texinfo_compact_itemx) or not_nil(ox.read_attribute("attr_texinfo", plain_list, "compact")))
end

T.item = function(el, contents, info)
  local tag = el.tag
  local plain_list = el.parent
  local compact = compact_p(plain_list, info)
  if compact and ox.get_next_element(el, info) and #el.contents == 0 and el.post_blank == 1 then
    el.post_blank = 0
  end
  local prev = compact and ox.get_previous_element(el, info) or nil
  if prev and #prev.contents == 0 and prev.post_blank == 0 then
    return fmt("@itemx%s\n%s", tag and (" " .. ox.data(tag, info)) or "", contents or "")
  end
  local split = ox.read_attribute("attr_texinfo", plain_list, "sep")
  split = nw(split) and split or nil
  local items
  if tag then
    local t = ox.data(tag, info)
    if split then
      items = {}
      for _, part in ipairs(vim.split(t, split, { plain = true })) do
        part = part:gsub("^[ \t\n]+", ""):gsub("[ \t\n]+$", "")
        if part ~= "" then
          items[#items + 1] = part
        end
      end
    else
      items = { t }
    end
  end
  local head
  if not items or #items == 0 then
    head = "@item"
  else
    head = "@item " .. items[1]
    for i = 2, #items do
      head = head .. "\n@itemx " .. items[i]
    end
  end
  return fmt("%s\n%s", head, contents or "")
end

local INDEX_KEYWORDS = {
  CINDEX = "cindex",
  FINDEX = "findex",
  KINDEX = "kindex",
  PINDEX = "pindex",
  TINDEX = "tindex",
  VINDEX = "vindex",
}

T.keyword = function(el, _, info)
  local key, value = el.key, el.value or ""
  if key == "TEXINFO" then
    return value
  elseif INDEX_KEYWORDS[key] then
    return fmt("@%s %s", INDEX_KEYWORDS[key], value)
  elseif key == "TOC" then
    if value:match("%f[%w]tables%f[%W]") then
      return "@listoffloats " .. ox.translate("Table", "utf-8", info)
    elseif value:match("%f[%w]listings%f[%W]") then
      return "@listoffloats " .. ox.translate("Listing", "utf-8", info)
    end
  end
end

--- Does the installed makeinfo support @math / @displaymath?
--- (org-texinfo-supports-math-p; cached)
function M.supports_math_p()
  if M._supports_math ~= nil then
    return M._supports_math
  end
  local result = false
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local input = dir .. "/test.texi"
  local out = dir .. "/test.info"
  vim.fn.writefile({ "@setfilename " .. out, "@node Top", "@displaymath", "1 + 1 = 2", "@end displaymath" }, input)
  local ok, info = pcall(M.compile, input)
  if ok and info and vim.fn.filereadable(info) == 1 then
    result = table.concat(vim.fn.readfile(info), "\n"):find("1 + 1 = 2", 1, true) ~= nil
  end
  vim.fn.delete(dir, "rf")
  M._supports_math = result
  return result
end

local function with_math(info)
  local w = info.with_latex
  return w == true or w == "t" or (w == "detect" and M.supports_math_p())
end

T["latex-environment"] = function(el, _, info)
  if not with_math(info) then
    return nil
  end
  local lines = element.remove_indentation(vim.split((el.value:gsub("\n$", "")), "\n", { plain = true }))
  return prepend_anchor(table.concat({ "@displaymath", trim(table.concat(lines, "\n")), "@end displaymath" }, "\n"), el)
end

T["latex-fragment"] = function(el, _, info)
  if not with_math(info) then
    return nil
  end
  local value = table.concat(element.remove_indentation(vim.split(el.value, "\n", { plain = true })), "\n")
  local function bol(p)
    return value:find("^" .. p) or value:find("\n" .. p)
  end
  if bol("\\%[") or bol("%$%$") then
    return "\n@displaymath\n" .. trim(value:sub(3, -3)) .. "\n@end displaymath\n"
  elseif bol("%$") then
    return "@math{" .. trim(value:sub(2, -2)) .. "}"
  elseif bol("\\%(") then
    return "@math{" .. trim(value:sub(3, -3)) .. "}"
  end
  return value
end

T["line-break"] = function()
  return "@*\n"
end

--- @ref to a datum (org-texinfo--@ref).
local function ref(datum, description, info)
  local node = get_node(datum, info)
  -- colons confuse the Info reader, even within @asis
  local title = description and description:gsub(",", "@comma{}"):gsub("[ \t]*:+", "") or nil
  if not title then
    return fmt("@ref{%s}", node)
  end
  return fmt("@ref{%s, , %s}", node, title)
end

local function inline_image(link, info)
  local parent = element.parent_element(link)
  local label = parent.name and get_node(parent, info) or nil
  local caption = ox.get_caption(parent)
  local short = ox.get_caption(parent, true)
  local path = link.path
  local filename
  if path:match("^/") or path:match("^~") then
    filename = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  else
    filename = vim.fs.normalize(path):gsub("^%./", "")
  end
  local extension = filename:match("%.([^./]*)$")
  filename = sans_extension(filename)
  local attr = ox.read_attribute("attr_texinfo", parent)
  local image =
    fmt("@image{%s,%s,%s,%s,%s}", filename, attr.width or "", attr.height or "", attr.alt or "", extension or "")
  if caption or short then
    return wrap_float(image, info, ox.translate("Figure", "utf-8", info), label, caption, short)
  elseif label then
    return "@anchor{" .. label .. "}\n" .. image
  end
  return image
end

T.link = function(el, desc, info)
  local ltype = el.link_type
  local raw = el.path
  desc = (desc ~= nil and desc ~= "") and desc or nil
  local path = sanitize_content(ltype == "file" and ox.file_uri(raw) or (ltype .. ":" .. raw))
  local custom = ox.custom_protocol_maybe(el, desc, "texinfo", info)
  if custom then
    return custom
  end
  if ox.inline_image_p(el, M.inline_image_rules) then
    return inline_image(el, info)
  end
  if ltype == "radio" then
    local dest = ox.resolve_radio_link(el, info)
    if not dest then
      return desc
    end
    return ref(dest, desc, info)
  end
  if ltype == "custom-id" or ltype == "id" or ltype == "fuzzy" then
    local dest = ltype == "fuzzy" and ox.resolve_fuzzy_link(el, info) or ox.resolve_id_link(el, info)
    if not dest then
      return fmt(info.texinfo_link_with_unknown_path_format, path)
    elseif dest.type == "plain-text" then
      -- id link to another file
      if desc then
        return fmt("@uref{file://%s,%s}", dest.value, desc)
      end
      return fmt("@uref{file://%s}", dest.value)
    elseif dest.type == "headline" or (dest.type == "target" and dest.parent and dest.parent.type == "headline") then
      -- targets in headline titles cannot be anchors: refer to the headline
      return ref(element.lineage(dest, "headline", true), desc, info)
    end
    return ref(dest, desc, info)
  end
  if ltype == "mailto" then
    return fmt("@email{%s}", path .. (desc and (", " .. desc) or ""))
  end
  if path and desc then
    return fmt("@uref{%s, %s}", path, desc)
  elseif path then
    return fmt("@uref{%s}", path)
  end
  return format1(info.texinfo_link_with_unknown_path_format, desc or "")
end

T["node-property"] = function(el)
  return fmt("%s:%s", el.key, el.value and (" " .. el.value) or "")
end

T.paragraph = function(el, contents)
  -- stripped objects must not split the paragraph
  return prepend_anchor(((contents or ""):gsub("\n%s*\n", "\n")), el)
end

T["plain-list"] = function(el, contents, info)
  local attr = ox.read_attribute("attr_texinfo", el)
  local indic = attr.indic or info.texinfo_table_default_markup or "@asis"
  if indic:sub(1, 1) ~= "@" then
    indic = "@" .. indic
  end
  local table_type = attr["table-type"]
  local ltype = el.list_type
  local enum
  if ltype == "ordered" then
    if vim.tbl_contains(attr._keys, "enum") then
      enum = attr.enum
    else
      -- Texinfo only supports an initial counter
      local first = el.contents[1]
      enum = first and first.counter
    end
  end
  local list_type
  if ltype == "ordered" then
    list_type = "enumerate"
  elseif ltype == "unordered" then
    list_type = "itemize"
  elseif table_type == "ftable" or table_type == "vtable" then
    list_type = table_type
  else
    list_type = "table"
  end
  local head
  if ltype == "descriptive" then
    head = list_type .. " " .. indic
  elseif enum then
    head = fmt("%s %s", list_type, tostring(enum))
  else
    head = list_type
  end
  return prepend_anchor(fmt("@%s\n%s@end %s", head, contents or "", list_type), el)
end

--- Transcode a plain text string (org-texinfo-plain-text).
function M.plain_text(text, info, node)
  local output = sanitize_content(text)
  if info.with_smart_quotes and node then
    output = ox.activate_smart_quotes(output, "texinfo", info, node)
  end
  -- LaTeX -> @LaTeX{}, TeX -> @TeX{}
  output = output:gsub("LaTeX", "\0"):gsub("TeX", "@TeX{}"):gsub("%z", "@LaTeX{}")
  if info.with_special_strings then
    output = output:gsub("\\%-", "@-"):gsub("%.%.%.", "@dots{}")
  end
  if info.preserve_breaks then
    output = output:gsub("\\\\[ \t]*\n", "\n"):gsub("[ \t]*\n", " @*\n")
  end
  -- a sentence may end with a capital letter: "@." keeps the period
  -- ending it
  local out = {}
  local i, n = 1, #output
  local last = 1
  while i <= n do
    local c = output:sub(i, i)
    if c:match("[A-Z]") and output:sub(i + 1, i + 1):match("[.?!]") then
      local j = i + 2
      local nx = output:sub(j, j)
      local ok_end
      local function at_end(k)
        local ch = output:sub(k, k)
        if ch == " " then
          return k + 1
        elseif ch == "\n" or k > n then
          return k
        end
      end
      if nx == "]" or nx == ")" then
        ok_end = at_end(j + 1)
      elseif nx == "'" then
        ok_end = (output:sub(j + 1, j + 1) == "'" and at_end(j + 2)) or at_end(j + 1)
      end
      ok_end = ok_end or at_end(j)
      if ok_end then
        out[#out + 1] = output:sub(last, i)
        out[#out + 1] = "@"
        last = i + 1
        i = math.max(ok_end, i + 2)
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  out[#out + 1] = output:sub(last)
  return table.concat(out)
end

T["plain-text"] = function(text, info, node)
  return M.plain_text(text, info, node)
end

T.planning = function(el, _, info)
  local parts = {}
  local active, inactive = info.texinfo_active_timestamp_format, info.texinfo_inactive_timestamp_format
  if el.closed then
    parts[#parts + 1] = "@strong{CLOSED:} " .. format1(inactive, ox.timestamp_translate(el.closed))
  end
  if el.deadline then
    parts[#parts + 1] = "@strong{DEADLINE:} " .. format1(active, ox.timestamp_translate(el.deadline))
  end
  if el.scheduled then
    parts[#parts + 1] = "@strong{SCHEDULED:} " .. format1(active, ox.timestamp_translate(el.scheduled))
  end
  return "@noindent" .. table.concat(parts, " ") .. "@*"
end

T["property-drawer"] = function(_, contents)
  if nw(contents) then
    return fmt("@verbatim\n%s@end verbatim", contents)
  end
end

T["quote-block"] = function(el, contents)
  local attr = ox.read_attribute("attr_texinfo", el)
  return prepend_anchor(
    fmt(
      "@quotation%s\n%s%s\n@end quotation",
      attr.tag and (" " .. attr.tag) or "",
      contents or "",
      attr.author and ("\n@author " .. attr.author) or ""
    ),
    el
  )
end

T["radio-target"] = function(el, text, info)
  return fmt("@anchor{%s}%s", get_node(el, info), text or "")
end

T.section = function(el, contents, info)
  local parent = element.lineage(el, "headline")
  -- the first section is part of the Top node (see the template)
  if parent then
    local menu = not ox.excluded_from_toc_p(parent, info) and M.make_menu(parent, info) or ""
    return trim((contents or "") .. "\n" .. menu)
  end
end

T["special-block"] = function(el, contents)
  local opt = el.texinfo_options or ox.read_attribute("attr_texinfo", el, "options")
  local btype = el.block_type
  return prepend_anchor(fmt("@%s%s\n%s@end %s", btype, opt and (" " .. opt) or "", contents or "", btype), el)
end

T["src-block"] = function(el, _, info)
  local lisp = (el.language or ""):find("lisp", 1, true) ~= nil
  local code = sanitize_content(ox.format_code_default(el, info))
  local value = fmt(lisp and "@lisp\n%s@end lisp" or "@example\n%s@end example", code)
  local caption = ox.get_caption(el)
  local short = ox.get_caption(el, true)
  if caption or short then
    return wrap_float(value, info, ox.translate("Listing", "utf-8", info), el.name, caption, short)
  end
  return prepend_anchor(value, el)
end

T["statistics-cookie"] = function(el)
  return el.value
end

T.subscript = function(_, contents)
  return fmt("@math{_%s}", contents or "")
end

T.superscript = function(_, contents)
  return fmt("@math{^%s}", contents or "")
end

--- "{aaa} {bb}" from the widest cell of each column (org-texinfo-table-column-widths).
local function column_widths(tbl, info)
  local _, cols = ox.table_dimensions(tbl, info)
  local widths = {}
  for i = 1, cols do
    widths[i] = 0
  end
  for _, row in ipairs(tbl.contents) do
    if not info.ignore[row] then
      local idx = 0
      for _, cell in ipairs(row.contents or {}) do
        if not info.ignore[cell] then
          idx = idx + 1
          local w = vim.fn.strchars(trim(element.interpret(cell.contents)))
          widths[idx] = math.max(w, widths[idx] or 0)
        end
      end
    end
  end
  local parts = {}
  for i, w in ipairs(widths) do
    parts[i] = string.rep("a", w)
  end
  return "{" .. table.concat(parts, "} {") .. "}"
end

T.table = function(el, contents, info)
  if el.table_type == "table.el" then
    return prepend_anchor(fmt("@verbatim\n%s@end verbatim", ox.normalize_string(el.value)), el)
  end
  local col_width = ox.read_attribute("attr_texinfo", el, "columns")
  local columns = col_width and ("@columnfractions " .. col_width) or column_widths(el, info)
  local caption = ox.get_caption(el)
  local short = ox.get_caption(el, true)
  local s = fmt("@multitable %s\n%s@end multitable", columns, contents or "")
  if caption or short then
    return wrap_float(s, info, ox.translate("Table", "utf-8", info), el.name, caption, short)
  end
  return prepend_anchor(s, el)
end

T["table-cell"] = function(el, contents, info)
  local sci = info.texinfo_table_scientific_notation
  local out = contents or ""
  if contents and sci then
    local m, e = contents:match("^([-+]?%d[%d.]*)[eE]([-+]?%d+)$")
    if m then
      local k = 0
      out = sci:gsub("%%s", function()
        k = k + 1
        return k == 1 and m or e
      end)
    end
  end
  return out .. (ox.get_next_element(el, info) and "\n@tab " or "")
end

T["table-row"] = function(el, contents, info)
  -- rules are ignored: separators come from the borders of the rows
  if el.row_type ~= "standard" then
    return nil
  end
  local header = ox.table_row_group(el, info) == 1 and ox.table_has_header_p(element.lineage(el, "table"), info)
  local tag = header and "@headitem " or "@item "
  return tag .. (contents or "") .. "\n"
end

T.target = function(el, _, info)
  return fmt("@anchor{%s}", get_node(el, info))
end

T.timestamp = function(el, _, info)
  local value = M.plain_text(ox.timestamp_translate(el), info)
  local t = el.ts_type
  local f
  if t == "active" or t == "active-range" then
    f = info.texinfo_active_timestamp_format
  elseif t == "inactive" or t == "inactive-range" then
    f = info.texinfo_inactive_timestamp_format
  else
    f = info.texinfo_diary_timestamp_format
  end
  return format1(f, value)
end

T["verse-block"] = function(el, contents)
  return prepend_anchor(fmt("@display\n%s@end display", contents or ""), el)
end

---------------------------------------------------------------------------
-- Public functions
---------------------------------------------------------------------------

--- Quote KEY with @kbd{...} and @key{...} (org-texinfo-kbd-macro). Without
--- `noquote` the result is wrapped in @@texinfo:...@@ snippets, for use
--- in a macro:
---
--- ```lua
--- export = { global_macros = { kbd = function(key)
---   return require("org.export.texinfo").kbd_macro(key)
--- end } }
--- ```
---@param key string
---@param noquote? boolean
---@return string
function M.kbd_macro(key, noquote)
  local s = key:gsub("[%w]+", function(w)
    if vim.tbl_contains(QUOTED_KEYS, w) then
      return noquote and ("@key{" .. w .. "}") or ("@@texinfo:@key{@@" .. w .. "@@texinfo:}@@")
    end
  end)
  return fmt(noquote and "@kbd{%s}" or "@@texinfo:@kbd{@@%s@@texinfo:}@@", s)
end

--- Commands producing the Info file (org-texinfo-info-process).
function M.info_process()
  return tcfg().info_process or { "makeinfo --no-split %f" }
end

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- Compile a .texi file to Info (org-texinfo-compile). With `on_done`,
--- run asynchronously and call on_done(info|nil, err|nil); otherwise
--- return info, err.
---@param texi string
---@param on_done? fun(info: string|nil, err: string|nil)
function M.compile(texi, on_done)
  local full = vim.fn.fnamemodify(texi, ":p")
  local dir = vim.fn.fnamemodify(full, ":h")
  local base = vim.fn.fnamemodify(full, ":t:r")
  local out = dir .. "/" .. base .. ".info"
  local process = M.info_process()
  local mtime_before = vim.fn.getftime(out)
  local log = {}
  local function finish()
    if tcfg().remove_logfiles ~= false then
      for _, ext in ipairs(tcfg().logfiles_extensions or { "aux", "toc", "cp", "fn", "ky", "pg", "tp", "vr" }) do
        os.remove(dir .. "/" .. base .. "." .. ext)
      end
    end
    local produced = vim.fn.filereadable(out) == 1 and (mtime_before < 0 or vim.fn.getftime(out) >= mtime_before)
    if not produced then
      local text = table.concat(log, "\n")
      return nil, fmt("File %s wasn't produced%s", out, nw(text) and (":\n" .. text) or "")
    end
    return out
  end
  if type(process) == "function" then
    local ok, err = pcall(process, full)
    if not ok then
      log[#log + 1] = tostring(err)
    end
    if on_done then
      on_done(finish())
      return
    end
    return finish()
  end
  local cmds = {}
  for _, c in ipairs(process) do
    cmds[#cmds + 1] = c:gsub("%%F", shell_quote(full))
      :gsub("%%f", shell_quote(vim.fn.fnamemodify(full, ":t")))
      :gsub("%%b", shell_quote(base))
      :gsub("%%o", shell_quote(dir))
      :gsub("%%O", shell_quote(out))
  end
  if not on_done then
    for _, c in ipairs(cmds) do
      local res = vim.system({ vim.o.shell, vim.o.shellcmdflag, c }, { cwd = dir, text = true }):wait(600000)
      log[#log + 1] = (res.stdout or "") .. (res.stderr or "")
    end
    return finish()
  end
  local i = 0
  local function step()
    i = i + 1
    if i > #cmds then
      vim.schedule(function()
        on_done(finish())
      end)
      return
    end
    vim.system({ vim.o.shell, vim.o.shellcmdflag, cmds[i] }, { cwd = dir, text = true }, function(res)
      log[#log + 1] = (res.stdout or "") .. (res.stderr or "")
      step()
    end)
  end
  step()
end

---------------------------------------------------------------------------
-- Back-end
---------------------------------------------------------------------------

function M.options()
  local c = tcfg()
  local function v(name, default)
    if c[name] == nil then
      return default
    end
    return c[name]
  end
  return {
    { "texinfo_filename", "TEXINFO_FILENAME", nil, nil, "t" },
    { "texinfo_class", "TEXINFO_CLASS", nil, v("default_class", "info"), "t" },
    { "texinfo_header", "TEXINFO_HEADER", nil, nil, "newline" },
    { "texinfo_post_header", "TEXINFO_POST_HEADER", nil, nil, "newline" },
    { "subtitle", "SUBTITLE", nil, nil, "parse" },
    { "subauthor", "SUBAUTHOR", nil, nil, "newline" },
    { "texinfo_dircat", "TEXINFO_DIR_CATEGORY", nil, nil, "t" },
    { "texinfo_dirtitle", "TEXINFO_DIR_TITLE", nil, nil, "t" },
    { "texinfo_dirname", "TEXINFO_DIR_NAME", nil, nil, "t" },
    { "texinfo_dirdesc", "TEXINFO_DIR_DESC", nil, nil, "t" },
    { "texinfo_printed_title", "TEXINFO_PRINTED_TITLE", nil, nil, "t" },
    { "texinfo_classes", nil, nil, v("classes", M.classes) },
    { "texinfo_format_headline_function", nil, nil, v("format_headline_function", nil) },
    { "texinfo_node_description_column", nil, nil, v("node_description_column", 32) },
    { "texinfo_active_timestamp_format", nil, nil, v("active_timestamp_format", "@emph{%s}") },
    { "texinfo_inactive_timestamp_format", nil, nil, v("inactive_timestamp_format", "@emph{%s}") },
    { "texinfo_diary_timestamp_format", nil, nil, v("diary_timestamp_format", "@emph{%s}") },
    { "texinfo_link_with_unknown_path_format", nil, nil, v("link_with_unknown_path_format", "@indicateurl{%s}") },
    { "texinfo_tables_verbatim", nil, nil, v("tables_verbatim", false) },
    { "texinfo_table_scientific_notation", nil, nil, v("table_scientific_notation", nil) },
    { "texinfo_table_default_markup", nil, nil, v("table_default_markup", "@asis") },
    { "texinfo_text_markup_alist", nil, nil, v("text_markup_alist", {
      bold = "@strong{%s}",
      code = "code",
      italic = "@emph{%s}",
      verbatim = "samp",
    }) },
    { "texinfo_format_drawer_function", nil, nil, v("format_drawer_function", nil) },
    { "texinfo_format_inlinetask_function", nil, nil, v("format_inlinetask_function", nil) },
    { "texinfo_compact_itemx", nil, "compact-itemx", v("compact_itemx", false) },
    { "with_latex", nil, "tex", v("with_latex", ox.cfg().with_latex ~= false and "detect" or false) },
  }
end

M.backend = ox.define_backend("texinfo", {
  transcoders = T,
  options = M.options,
  filters = {
    headline = { section_blank_lines },
    section = { section_blank_lines },
    ["parse-tree"] = { normalize_headlines, separate_definitions },
    ["final-output"] = {
      function(s)
        return (s:gsub("\t", string.rep(" ", 8)))
      end,
    },
  },
})

return M

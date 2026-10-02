---@mod org.export.man Man page back-end (port of Emacs ox-man.el)
---
--- Writes a groff man(7) page: `.TH` from the title, date and
--- #+MAN_CLASS_OPTIONS (`:section-id`, `:release`, `:header`), `.SH` / `.SS`
--- sections for the first three headline levels, `.TP` lists for deeper
--- ones, `.IP` / `.TP` items, tbl(1) tables and verbatim blocks.
--- `compile()` turns the page into a PDF with `export.man.pdf_process`
--- (org-man-compile).

local ox = require("org.export.ox")
local element = require("org.export.element")
local entities = require("org.export.entities")

local M = {}

M.extension = "man"

local fmt = string.format
local nw = ox.nw
local trim = ox.trim

local function mcfg()
  return (require("org.config").opts.export or {}).man or {}
end

--- org-man-source-highlight-langs
M.source_highlight_langs = {
  ["emacs-lisp"] = "lisp",
  lisp = "lisp",
  clojure = "lisp",
  scheme = "scheme",
  c = "c",
  cc = "cpp",
  csharp = "csharp",
  d = "d",
  fortran = "fortran",
  cobol = "cobol",
  pascal = "pascal",
  ada = "ada",
  asm = "asm",
  perl = "perl",
  cperl = "perl",
  python = "python",
  ruby = "ruby",
  tcl = "tcl",
  lua = "lua",
  java = "java",
  javascript = "javascript",
  tex = "latex",
  ["shell-script"] = "sh",
  awk = "awk",
  diff = "diff",
  m4 = "m4",
  ocaml = "caml",
  caml = "caml",
  sql = "sql",
  sqlite = "sql",
  html = "html",
  css = "css",
  xml = "xml",
  bat = "bat",
  bison = "bison",
  clipper = "clipper",
  ldap = "ldap",
  opa = "opa",
  php = "php",
  postscript = "postscript",
  prolog = "prolog",
  properties = "properties",
  makefile = "makefile",
  tml = "tml",
  vbscript = "vbscript",
  xorg = "xorg",
}

--- org-man-pdf-process
M.PDF_PROCESS = {
  "tbl %f | eqn | groff -man | ps2pdf - > %b.pdf",
  "tbl %f | eqn | groff -man | ps2pdf - > %b.pdf",
  "tbl %f | eqn | groff -man | ps2pdf - > %b.pdf",
}

--- org-man-logfiles-extensions
M.LOGFILES_EXTENSIONS = { "log", "out", "toc" }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- (format "%s" v) of a string that may be nil.
local function str(v)
  if v == nil then
    return "nil"
  end
  return v
end

--- org-man--wrap-label: prepend the element's #+NAME.
local function wrap_label(el, output)
  local label = el.name
  if not output or not label or output == "" or label == "" then
    return output
  end
  return fmt("%s\n.br\n", label) .. output
end

--- org-man--protect-text: escape minus signs.
local function protect_text(text)
  return (text:gsub("%-", "\\-"))
end
M.protect_text = protect_text

--- org-man--protect-example: backslashes are written \e.
local function protect_example(text)
  return (text:gsub("\\", "\\e"))
end
M.protect_example = protect_example

local function remove_indentation(value)
  local ends = value:match("\n$")
  local lines = element.remove_indentation(vim.split((value:gsub("\n$", "")), "\n", { plain = true }))
  return table.concat(lines, "\n") .. (ends and "\n" or "")
end

--- org-split-string: split and drop empty parts.
local function split_nonempty(s, sep)
  local out = {}
  for _, part in ipairs(vim.split(s, sep, { plain = true })) do
    if part ~= "" then
      out[#out + 1] = part
    end
  end
  return out
end

--- (read (format "(%s)" s)) as a plist: { [":key"] = value }.
local function read_plist(s)
  local list = ox.read_sexp("(" .. (s or "") .. ")") or {}
  local out = {}
  for i = 1, #list - 1, 2 do
    if type(list[i]) == "string" then
      out[list[i]] = list[i + 1]
    end
  end
  return out
end

--- org-man--caption/label-string (tables have no :label property).
local function caption_label_string(el, info)
  local main = ox.get_caption(el)
  local short = ox.get_caption(el, true)
  if not main then
    return ""
  elseif short then
    return fmt("\\fR%s\\fP - \\fI\\P - %s\n", ox.data(short, info), ox.data(main, info))
  end
  return fmt("\\fR%s\\fP", ox.data(main, info))
end

--- Protect backslashes in plain text like org-man-plain-text: a backslash
--- not preceded by one and not followed by one of %$#&{}~^_\ becomes $\.
local PROTECTED_FOLLOW = {
  ["%"] = true,
  ["$"] = true,
  ["#"] = true,
  ["&"] = true,
  ["{"] = true,
  ["}"] = true,
  ["~"] = true,
  ["^"] = true,
  ["_"] = true,
  ["\\"] = true,
}
local function protect_backslashes(s)
  local out = {}
  local n = #s
  local start = 1
  local j = 1
  while j <= n do
    local c = s:sub(j, j)
    local bs -- index of the matched backslash
    if c ~= "\\" and s:sub(j + 1, j + 1) == "\\" then
      bs = j + 1
    elseif c == "\\" and j == 1 then
      bs = j
    end
    local matched = false
    if bs then
      local f = s:sub(bs + 1, bs + 1)
      if f == "" or f == "\n" or not PROTECTED_FOLLOW[f] then
        matched = true
        -- the match ends after the following character, if any
        local me = (f == "") and bs or (bs + 1)
        out[#out + 1] = s:sub(start, bs - 1) .. "$\\" .. s:sub(bs + 1, me)
        start = me + 1
        j = me + 1
      end
    end
    if not matched then
      j = j + 1
    end
  end
  out[#out + 1] = s:sub(start)
  return table.concat(out)
end
M.protect_backslashes = protect_backslashes

local function tmpname(prefix)
  return vim.fn.fnamemodify(vim.fn.tempname(), ":h") .. "/" .. prefix .. tostring(vim.uv.hrtime())
end

--- Highlight `code` with GNU source-highlight (org-man-source-highlight).
local function source_highlight(code, lst_lang)
  local infile = tmpname("srchilite")
  local outfile = tmpname("reshilite")
  local f = io.open(infile, "wb")
  if not f then
    return ""
  end
  f:write(code)
  f:close()
  vim.system({ "source-highlight", "-s", lst_lang, "-f", "groff_man", "-i", infile, "-o", outfile }):wait(60000)
  local result = ""
  local o = io.open(outfile, "r")
  if o then
    result = o:read("*a")
    o:close()
  end
  os.remove(infile)
  os.remove(outfile)
  return result
end

local function highlight_lang(el, info)
  local lang = el.language
  if not lang then
    return nil
  end
  return (info.man_source_highlight_langs or {})[lang]
end

---------------------------------------------------------------------------
-- Template (org-man-template)
---------------------------------------------------------------------------

local function template(contents, info)
  local title = info.with_title and ox.data(info.title, info) or nil
  local attr = read_plist(info.man_class_options)
  local section = attr[":section-id"]
  local release = attr[":release"]
  local header = attr[":header"]
  local date = info.with_date and ox.data(ox.get_date(info), info) or nil
  local out = {}
  out[#out + 1] = fmt('.TH "%s" "%s"', title or " ", type(section) == "string" and section or "1")
  out[#out + 1] = date and fmt(' "%s"', date) or ' ""'
  out[#out + 1] = release ~= nil and fmt(' "%s"', tostring(release)) or ' ""'
  if header ~= nil then
    out[#out + 1] = fmt(' "%s"', tostring(header))
  end
  out[#out + 1] = " \n"
  out[#out + 1] = contents
  return table.concat(out)
end
M.template = template

---------------------------------------------------------------------------
-- Transcoders
---------------------------------------------------------------------------

local T = {}

T.template = template

T.bold = function(_, contents)
  return fmt("\\fB%s\\fP", contents or "")
end

T["center-block"] = function(el, contents)
  contents = contents or ""
  local n = #vim.split(contents, "\n", { plain = true }) - 1
  return wrap_label(el, fmt(".ce %d\n.nf\n%s\n.fi", n, contents))
end

T.code = function(el)
  return fmt("\\fC%s\\fP", protect_text(el.value))
end

T.drawer = function(_, contents)
  return contents
end

T["dynamic-block"] = function(el, contents)
  return wrap_label(el, contents)
end

T.entity = function(el)
  local e = entities[el.name]
  return e and e[6] or nil
end

T["example-block"] = function(el, _, info)
  return wrap_label(el, fmt(".RS\n.nf\n%s\n.fi\n.RE", protect_example(ox.format_code_default(el, info))))
end

T["export-block"] = function(el)
  if el.back_end_type == "MAN" then
    return remove_indentation(el.value)
  end
end

T["export-snippet"] = function(el)
  local tr = (require("org.config").opts.export or {}).snippet_translation or {}
  if (tr[el.back_end] or el.back_end) == "man" then
    return el.value
  end
end

T["fixed-width"] = function(el)
  return wrap_label(el, fmt("\\fC\n%s\n\\fP", remove_indentation(el.value)))
end

T.headline = function(el, contents, info)
  local level = ox.get_relative_level(el, info)
  local section_fmt
  if level == 1 then
    section_fmt = '.SH "%s"\n%s'
  elseif level == 2 or level == 3 then
    section_fmt = '.SS "%s"\n%s'
  end
  local text = ox.data(el.title, info)
  if el.footnote_section_p then
    return nil
  elseif not section_fmt or ox.low_level_p(el, info) then
    local body = (ox.first_sibling_p(el, info) and ".RS\n" or "")
      .. ".TP\n.ft I\n"
      .. text
      .. "\n.ft\n"
      .. (contents or "")
      .. ".RE"
    if not ox.last_sibling_p(el, info) then
      return body
    end
    return (body:gsub("[ \t\n]*$", ""))
  end
  return fmt(section_fmt, text, str(contents))
end

T["inline-src-block"] = function(el, _, info)
  local code = el.value
  if info.man_source_highlight then
    local lst = highlight_lang(el, info)
    if lst then
      return source_highlight(code, lst)
    end
    return fmt(".RS\n.nf\n\\fC%s\\m[]\\fP\n.fi\n.RE\n", protect_example(code))
  end
  return ".RS\n.nf\n\\fC\n" .. protect_example(code) .. "\n\\fP\n.fi\n.RE\n"
end

T.italic = function(_, contents)
  return fmt("\\fI%s\\fP", contents or "")
end

local CHECKBOX = { on = "\\o'\\(sq\\(mu'", off = "\\(sq ", trans = "\\o'\\(sq\\(mi'" }

T.item = function(el, contents, info)
  local list_type = el.parent and el.parent.list_type
  local checkbox = CHECKBOX[el.checkbox or ""]
  local tag
  if el.tag then
    tag = fmt("\\fB%s\\fP", (checkbox or "") .. ox.data(el.tag, info))
  end
  if not tag and not checkbox then
    local bullet = trim(el.bullet or "")
    local marker
    if bullet == "-" then
      marker = "\\(em"
    elseif bullet == "*" then
      marker = "\\(bu"
    elseif list_type == "ordered" then
      marker = bullet .. " "
    else
      marker = "\\(dg"
    end
    return ".IP " .. marker .. " 4\n" .. trim(contents or " ")
  end
  return ".TP\n" .. (tag or (" " .. checkbox)) .. "\n" .. trim(contents or " ")
end

T.keyword = function(el)
  if el.key == "MAN" then
    return el.value
  end
  return nil
end

T["line-break"] = function()
  return "\n.br\n"
end

T.link = function(el, desc, info)
  local ltype = el.link_type
  local raw = el.path or ""
  desc = (desc ~= nil and desc ~= "") and desc or nil
  local path = ltype == "file" and ox.file_uri(raw) or (ltype .. ":" .. raw)
  local custom = ox.custom_protocol_maybe(el, desc, "man", info)
  if custom then
    return custom
  end
  if path and desc then
    return fmt("%s \\fBat\\fP \\fI%s\\fP", path, desc)
  end
  return fmt("\\fI%s\\fP", path)
end

T["node-property"] = function(el)
  -- the value is always a string in Emacs (possibly empty)
  return fmt("%s: %s", el.key, el.value or "")
end

T.paragraph = function(el, contents)
  local parent = el.parent
  if not parent then
    return nil
  end
  if parent.type == "section" then
    return ".PP\n" .. (contents or "")
  end
  return contents or ""
end

T["plain-list"] = function(_, contents)
  return contents
end

T["plain-text"] = function(text, info, node)
  local output = protect_backslashes(text)
  if info.with_smart_quotes then
    output = ox.activate_smart_quotes(output, "utf-8", info, node)
  end
  if info.preserve_breaks then
    -- "\\(\\\\\\\\\\)?[ \t]*\n" -> ".br\n"
    output = output:gsub("(\\*)([ \t]*)\n", function(bs)
      if #bs >= 2 then
        return bs:sub(1, #bs - 2) .. ".br\n"
      end
      return bs .. ".br\n"
    end)
  end
  return output
end

T["property-drawer"] = function(_, contents)
  if nw(contents) then
    return fmt(".RS\n.nf\n%s\n.fi\n.RE", contents)
  end
end

T["quote-block"] = function(el, contents)
  return wrap_label(el, fmt(".RS\n%s\n.RE", contents or ""))
end

T["radio-target"] = function(_, text)
  return text
end

T.section = function(_, contents)
  return contents
end

T["special-block"] = function(el, contents)
  return wrap_label(el, fmt("%s\n", contents or ""))
end

T["src-block"] = function(el, _, info)
  if not info.man_source_highlight then
    return fmt(".RS\n.nf\n\\fC%s\\fP\n.fi\n.RE\n", protect_example(ox.format_code_default(el, info)))
  end
  local lst = highlight_lang(el, info)
  if lst then
    return source_highlight(el.value, lst)
  end
  return fmt(".RS\n.nf\n\\fC%s\\m[]\\fP\n.fi\n.RE", protect_example(el.value))
end

T["statistics-cookie"] = function(el)
  return el.value
end

T["strike-through"] = function(_, contents)
  return fmt("\\fI%s\\fP", contents or "")
end

T.subscript = function(_, contents)
  return fmt("\\d\\s-2%s\\s+2\\u", contents or "")
end

T.superscript = function(_, contents)
  return fmt("\\u\\s-2%s\\s+2\\d", contents or "")
end

--- org-man-table--align-string
local function align_string(divider, tbl, info)
  local row
  for _, r in ipairs(tbl.contents or {}) do
    if not info.ignore[r] and r.row_type == "standard" then
      row = r
      break
    end
  end
  if not row then
    return ""
  end
  local out = {}
  for _, cell in ipairs(row.contents or {}) do
    if not info.ignore[cell] then
      local borders = ox.table_cell_borders(cell, info)
      local raw = ox.table_cell_width(cell, info)
      local width = ""
      if raw then
        local cm = math.floor(raw / 5)
        width = fmt("w(%dc)", cm < 1 and 1 or cm)
      end
      if borders.left and #out == 0 then
        out[#out + 1] = "|"
      end
      local a = ox.table_cell_alignment(cell, info)
      out[#out + 1] = (a == "left" and "l" or a == "right" and "r" or a == "center" and "c" or "") .. width .. divider
      if borders.right then
        out[#out + 1] = "|"
      end
    end
  end
  return table.concat(out)
end

--- Re-create an Org table without its affiliated keywords.
local function interpret_table(el)
  if el.table_type == "table.el" then
    return el.value or ""
  end
  local rows = {}
  for _, row in ipairs(el.contents or {}) do
    if row.row_type == "rule" then
      rows[#rows + 1] = "|-"
    else
      local cells = {}
      for _, cell in ipairs(row.contents or {}) do
        cells[#cells + 1] = " " .. element.interpret(cell.contents or {}) .. " |"
      end
      rows[#rows + 1] = "|" .. table.concat(cells)
    end
  end
  -- aligned like org-element-interpret-data (org-table-align)
  return require("org.export.org").align_table_lines(rows)
end
M.interpret_table = interpret_table

local function org_table(el, contents, info)
  local attr = ox.read_attribute("attr_man", el)
  local caption = (not attr["disable-caption"]) and caption_label_string(el, info) or nil
  local divider = attr.divider and "|" or " "
  local alignment = align_string(divider, el, info)
  local lines = split_nonempty(contents or "", "\n")
  local attr_list = {}
  if attr.expand then
    attr_list[#attr_list + 1] = "expand"
  end
  local placement = attr.placement
  if placement == "center" then
    attr_list[#attr_list + 1] = "center"
  elseif placement == "left" then
    -- nothing
  elseif info.man_tables_centered then
    attr_list[#attr_list + 1] = "center"
  else
    attr_list[#attr_list + 1] = ""
  end
  attr_list[#attr_list + 1] = attr.boxtype or "box"
  local table_format = attr_list[1] or ""
  for i = 2, #attr_list do
    table_format = table_format .. "," .. attr_list[i]
  end
  if #lines == 0 then
    return nil
  end
  local first_line = split_nonempty(lines[1], "\t")
  local head = ""
  if attr["title-line"] then
    head = string.rep("cb" .. divider, #first_line)
  end
  head = head .. "\n" .. alignment
  local body = {}
  for _, line in ipairs(lines) do
    if attr["long-cells"] then
      if line == "_" then
        body[#body + 1] = "_\n"
      else
        local cells = split_nonempty(line, "\t")
        for i, cell in ipairs(cells) do
          body[#body + 1] = fmt("T{\n%s\nT}\t", cell) .. (i == #cells and "\n" or "")
        end
      end
    else
      body[#body + 1] = line .. "\n"
    end
  end
  return ".TS\n "
    .. table_format
    .. ";\n"
    .. head
    .. ".\n"
    .. table.concat(body)
    .. ".TE\n"
    .. (caption and fmt('.TB "%s"', caption) or "")
end

T.table = function(el, contents, info)
  local verbatim = info.man_tables_verbatim
  if not verbatim and el.attr_man then
    local attr = read_plist(table.concat(el.attr_man, " "))
    verbatim = attr[":verbatim"]
  end
  if verbatim then
    return fmt(".nf\n\\fC%s\\fP\n.fi", protect_example(trim(interpret_table(el))))
  end
  return org_table(el, contents, info)
end

T["table-cell"] = function(el, contents, info)
  local sci = info.man_table_scientific_notation
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
  return out .. (ox.get_next_element(el, info) and "\t" or "")
end

T["table-row"] = function(el, contents, info)
  if el.row_type ~= "standard" then
    return nil
  end
  local first = (el.contents or {})[1]
  local borders = first and ox.table_cell_borders(first, info) or {}
  local function has(b)
    return borders[b]
  end
  return ((has("top") and has("above")) and "_\n" or "") .. (contents or "") .. (has("below") and "\n_" or "")
end

T.target = function(el, _, info)
  return fmt("\\fI%s\\fP", ox.get_reference(el, info))
end

T.timestamp = function()
  return ""
end

T.underline = function(_, contents)
  return fmt("\\fI%s\\fP", contents or "")
end

T.verbatim = function(el)
  return fmt("\\fI%s\\fP", protect_text(el.value))
end

T["verse-block"] = function(_, contents)
  return fmt(".RS\n.ft I\n%s\n.ft\n.RE", contents or "")
end

M.transcoders = T

---------------------------------------------------------------------------
-- Filters and back-end
---------------------------------------------------------------------------

--- org-man--remove-blank: no blank lines between elements (groff_man_style(7)).
local function remove_blank(tree, _, info)
  element.map(tree, "*", function(el)
    if element.ELEMENTS[el.type] then
      el.post_blank = 0
    end
  end, { ignore = info.ignore })
  return tree
end

function M.options()
  local c = mcfg()
  local function v(name, default)
    if c[name] == nil then
      return default
    end
    return c[name]
  end
  return {
    { "man_class", "MAN_CLASS", nil, nil, "t" },
    { "man_class_options", "MAN_CLASS_OPTIONS", nil, nil, "t" },
    { "man_header_extra", "MAN_HEADER", nil, nil, "newline" },
    { "man_tables_centered", nil, nil, v("tables_centered", true) },
    { "man_tables_verbatim", nil, nil, v("tables_verbatim", false) },
    { "man_table_scientific_notation", nil, nil, v("table_scientific_notation", "%sE%s") },
    { "man_source_highlight", nil, nil, v("source_highlight", false) },
    { "man_source_highlight_langs", nil, nil, v("source_highlight_langs", M.source_highlight_langs) },
  }
end

M.backend = ox.define_backend("man", {
  transcoders = T,
  options = M.options,
  filters = {
    ["parse-tree"] = { remove_blank },
  },
})

---------------------------------------------------------------------------
-- PDF (org-man-compile)
---------------------------------------------------------------------------

--- Commands producing the PDF (org-man-pdf-process).
function M.pdf_process()
  return mcfg().pdf_process or M.PDF_PROCESS
end

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- Process a man file into a PDF (org-man-compile). With `on_done`, run
--- asynchronously and call on_done(pdf|nil, err|nil); otherwise return
--- pdf, err.
---@param file string
---@param on_done? fun(pdf: string|nil, err: string|nil)
function M.compile(file, on_done)
  local full = vim.fn.fnamemodify(file, ":p")
  local dir = vim.fn.fnamemodify(full, ":h")
  local base = vim.fn.fnamemodify(full, ":t:r")
  local out = dir .. "/" .. base .. ".pdf"
  local process = M.pdf_process()
  local mtime_before = vim.fn.getftime(out)
  local log = {}
  local function finish()
    if mcfg().remove_logfiles ~= false then
      for _, ext in ipairs(mcfg().logfiles_extensions or M.LOGFILES_EXTENSIONS) do
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
  -- one pass, with a function: a `%` in a file name is neither a capture
  -- of the replacement nor a spec of a later substitution
  local spec = {
    F = shell_quote(full),
    f = shell_quote(vim.fn.fnamemodify(full, ":t")),
    b = shell_quote(base),
    o = shell_quote(dir),
    O = shell_quote(out),
  }
  local cmds = {}
  for _, c in ipairs(process) do
    cmds[#cmds + 1] = c:gsub("%%([FfboO])", spec)
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

return M

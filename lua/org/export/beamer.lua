---@mod org.export.beamer Beamer back-end (port of Emacs ox-beamer.el)
---
--- Derived from the LaTeX back-end, like Emacs: headlines at the frame
--- level (H:, `export.beamer.frame_level`) become frames, shallower ones
--- sections and deeper ones blocks. The BEAMER_env, BEAMER_act,
--- BEAMER_opt, BEAMER_col, BEAMER_ref and BEAMER_subtitle properties
--- control environments, overlays, options, columns and resumed frames.

local ox = require("org.export.ox")
local element = require("org.export.element")
local latex = require("org.export.latex")

local M = {}

M.extension = "tex"

local fmt = string.format
local nw = ox.nw
local trim = ox.trim

local function bcfg()
  return (require("org.config").opts.export or {}).beamer or {}
end

local function opt(name, default)
  local v = bcfg()[name]
  if v == nil then
    return default
  end
  return v
end

--- org-beamer-environments-default
M.environments_default = {
  { "block", "b", "\\begin{block}%a{%h}", "\\end{block}" },
  { "alertblock", "a", "\\begin{alertblock}%a{%h}", "\\end{alertblock}" },
  { "verse", "v", "\\begin{verse}%a %% %h", "\\end{verse}" },
  { "quotation", "q", "\\begin{quotation}%a %% %h", "\\end{quotation}" },
  { "quote", "Q", "\\begin{quote}%a %% %h", "\\end{quote}" },
  { "structureenv", "s", "\\begin{structureenv}%a %% %h", "\\end{structureenv}" },
  { "theorem", "t", "\\begin{theorem}%a[%h]%l", "\\end{theorem}" },
  { "definition", "d", "\\begin{definition}%a[%h]%l", "\\end{definition}" },
  { "example", "e", "\\begin{example}%a[%h]%l", "\\end{example}" },
  { "exampleblock", "E", "\\begin{exampleblock}%a{%h}%l", "\\end{exampleblock}" },
  { "proof", "p", "\\begin{proof}%a[%h]", "\\end{proof}" },
  { "onlyenv", "O", "\\begin{onlyenv}%a", "\\end{onlyenv}" },
  { "beamercolorbox", "o", "\\begin{beamercolorbox}%o{%h}", "\\end{beamercolorbox}" },
}

local VERBATIM = {
  code = true,
  ["example-block"] = true,
  ["fixed-width"] = true,
  ["inline-src-block"] = true,
  ["src-block"] = true,
  verbatim = true,
}

local function unbracket(open, close, s)
  if s:sub(1, #open) == open and s:sub(-#close) == close and #s >= #open + #close then
    return s:sub(#open + 1, #s - #close)
  end
  return s
end

--- org-beamer--normalize-argument
local function normalize_argument(argument, kind)
  if not argument:find("%S") then
    return ""
  end
  if kind == "action" then
    return fmt("<%s>", unbracket("<", ">", argument))
  elseif kind == "defaction" then
    return fmt("[<%s>]", unbracket("<", ">", unbracket("[", "]", argument)))
  end
  return fmt("[%s]", unbracket("[", "]", argument))
end
M.normalize_argument = normalize_argument

--- Overlay specification of an element starting with a beamer snippet.
local function has_overlay(el)
  local first = el.contents and el.contents[1]
  if first and first.type == "export-snippet" then
    local v = first.value
    if v:sub(1, 1) == "<" and v:sub(-1) == ">" then
      return v
    end
  end
end

local function prop(el, name)
  return el.props and el.props[name]
end

local function action_arg(action)
  return normalize_argument(action, action:match("^%[.*%]$") and "defaction" or "action")
end

--- org-fill-template
local function fill_template(template, alist)
  local keys = {}
  for k in pairs(alist) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return #a > #b
  end)
  for _, k in ipairs(keys) do
    local v = alist[k]
    template = template:gsub("%%" .. vim.pesc(k), function()
      return v
    end)
  end
  return template
end

local T = {}

T.bold = function(el, contents)
  return fmt("\\alert%s{%s}", has_overlay(el) or "", contents or "")
end

T["export-block"] = function(el)
  if el.back_end_type == "BEAMER" or el.back_end_type == "LATEX" then
    return table.concat(element.remove_indentation(vim.split((el.value:gsub("\n$", "")), "\n", { plain = true })), "\n")
      .. "\n"
  end
end

T["export-snippet"] = function(el, _, info)
  local tr = (require("org.config").opts.export or {}).snippet_translation or {}
  local backend = tr[el.back_end] or el.back_end
  local value = el.value
  if backend == "latex" then
    return value
  elseif backend == "beamer" and (ox.get_previous_element(el, info) or not value:match("^<.*>$")) then
    return value
  end
end

--- org-beamer--get-label
local function get_label(h, info)
  local o = prop(h, "BEAMER_OPT")
  if type(o) == "string" then
    local label = (("," .. o .. ","):match(",label=(.-),"))
    if label then
      if label:match("^{.*}$") then
        return label:sub(2, -2)
      end
      return label
    end
  end
  if info.latex_prefer_user_labels and prop(h, "CUSTOM_ID") then
    return prop(h, "CUSTOM_ID")
  end
  return "sec:" .. ox.get_reference(h, info)
end

local function is_frame_env(env)
  return env and (env:lower() == "frame" or env:lower() == "fullframe")
end

--- org-beamer--frame-level
local function frame_level(h, info)
  local chain = {}
  local p = h.parent
  while p do
    table.insert(chain, 1, p)
    p = p.parent
  end
  for _, parent in ipairs(chain) do
    if is_frame_env(prop(parent, "BEAMER_ENV")) then
      return ox.get_relative_level(parent, info)
    end
  end
  if is_frame_env(prop(h, "BEAMER_ENV")) then
    return ox.get_relative_level(h, info)
  end
  local sub = element.map(h, "headline", function(hl)
    if is_frame_env(prop(hl, "BEAMER_ENV")) then
      return ox.get_relative_level(hl, info)
    end
  end, { first_match = true, ignore = info.ignore })
  if sub then
    return sub
  end
  return info.headline_levels
end

local function format_section(h, contents, info)
  local protected = function(object, c, i)
    local code = ox.with_backend("beamer", object, c, i)
    if nw(code) then
      return "\\protect" .. code
    end
    return code
  end
  local tr = {}
  for _, t in ipairs({ "bold", "footnote-reference", "italic", "strike-through", "timestamp", "underline" }) do
    tr[t] = protected
  end
  local out = ox.with_backend(ox.create_backend("latex", tr), h, contents, info)
  local mode = prop(h, "BEAMER_ACT")
  if mode and out then
    local name = out:match("^\\(%a+)")
    if name then
      local after = out:sub(#name + 2)
      if after:match("^%*?{") or after:match("^%[.-%]{") then
        return "\\" .. name .. fmt("<%s>", mode) .. after
      end
    end
  end
  return out
end

local function format_frame(h, contents, info)
  contents = contents or ""
  local fragilep = element.map(h, VERBATIM, function(x)
    return x
  end, { first_match = true, ignore = info.ignore }) ~= nil
  local frame = "frame"
  if fragilep and (contents:find("\\begin{frame}", 1, true) or contents:find("\\end{frame}", 1, true)) then
    frame = info.beamer_frame_environment
    info.beamer_define_frame = true
  end
  local action = prop(h, "BEAMER_ACT")
  local act = action and action_arg(action) or ""
  local beamer_opt = prop(h, "BEAMER_OPT")
  local options = {}
  for _, o in ipairs(vim.split(info.beamer_frame_default_options or "", ",", { plain = true })) do
    if nw(o) then
      options[#options + 1] = o
    end
  end
  if beamer_opt then
    local inner = beamer_opt:match("^%[?(.-)%]?$") or beamer_opt
    for _, o in ipairs(vim.split(inner, ",", { plain = true })) do
      if nw(o) then
        options[#options + 1] = o
      end
    end
  end
  local all = {}
  local has_label = false
  for _, o in ipairs(options) do
    if o:match("^label=") then
      has_label = true
    end
  end
  if not vim.tbl_contains(options, "allowframebreaks") and not has_label then
    local label = get_label(h, info)
    all[#all + 1] = fmt(label:find(":", 1, true) and "label={%s}" or "label=%s", label)
  end
  if fragilep and not vim.tbl_contains(options, "fragile") then
    all[#all + 1] = "fragile"
  end
  vim.list_extend(all, options)
  local env = prop(h, "BEAMER_ENV")
  local title = (env and env:lower() == "fullframe") and "" or ox.data(h.title, info)
  local subtitle = prop(h, "BEAMER_SUBTITLE")
  local sub = ""
  if subtitle then
    sub = fmt("{%s}", ox.data(info.parser:parse_objects(subtitle, element.RESTRICTIONS.keyword), info))
  end
  local body = contents
  if fragilep then
    body = body:gsub("^(\n*)", "%1 ", 1)
  end
  return "\\begin{"
    .. frame
    .. "}"
    .. act
    .. normalize_argument(table.concat(all, ","), "option")
    .. fmt("{%s}", title)
    .. sub
    .. "\n"
    .. body
    .. "\\end{"
    .. frame
    .. "}"
end

local function find_env(environment, info)
  for _, e in ipairs(info.beamer_environments_extra or {}) do
    if e[1] == environment then
      return e
    end
  end
  for _, e in ipairs(M.environments_default) do
    if e[1] == environment then
      return e
    end
  end
end

local function format_block(h, contents, info)
  local column_width = prop(h, "BEAMER_COL")
  local env = prop(h, "BEAMER_ENV")
  local environment
  if not env and not column_width then
    environment = "block"
  elseif not env then
    environment = "column"
  else
    environment = env
  end
  local raw_title = h.raw_value or ""
  local env_format
  if environment ~= "column" and environment ~= "columns" then
    env_format = find_env(environment, info)
    if not env_format then
      error(fmt('Wrong block type at a headline named "%s"', raw_title), 0)
    end
  end
  local title = ox.data(h.title, info)
  local raw_options = prop(h, "BEAMER_OPT")
  local options = raw_options and normalize_argument(raw_options, "option") or ""
  local raw_action = prop(h, "BEAMER_ACT")
  local action = raw_action and action_arg(raw_action) or ""
  local parent = element.lineage(h, "headline")
  local parent_env = parent and prop(parent, "BEAMER_ENV")
  local in_columns = parent_env and parent_env:lower() == "columns"
  local prev = ox.get_previous_element(h, info)
  local nxt = ox.get_next_element(h, info)
  local start_columns = environment == "columns"
    or (column_width and not in_columns and (ox.first_sibling_p(h, info) or not (prev and prop(prev, "BEAMER_COL"))))
  local end_columns = environment == "columns"
    or (column_width and not in_columns and (ox.last_sibling_p(h, info) or not (nxt and prop(nxt, "BEAMER_COL"))))
  local out = {}
  if start_columns then
    if environment ~= "columns" then
      out[#out + 1] = "\\begin{columns}\n"
    else
      out[#out + 1] = fmt("\\begin{columns}%s\n", options)
    end
  end
  if column_width then
    out[#out + 1] = fmt("\\begin{column}%s%s{%s}\n", options, env_format and "" or action, column_width .. "\\columnwidth")
  end
  if env_format and env_format[3] then
    local alist
    if action == "" then
      alist = { a = "", A = "", R = "" }
    elseif action:sub(1, 1) == "[" and action:sub(-1) == "]" then
      alist = { A = normalize_argument(action, "defaction"), a = "", R = raw_action }
    else
      alist = { a = action, A = "", R = raw_action }
    end
    alist.o = options
    alist.O = raw_options or ""
    alist.h = title
    alist.r = raw_title
    alist.l = fmt("\\label{%s}", get_label(h, info))
    alist.H = raw_title == "" and "" or fmt("{%s}", raw_title)
    alist.U = raw_title == "" and "" or fmt("[%s]", raw_title)
    out[#out + 1] = fill_template(env_format[3], alist) .. "\n"
  end
  out[#out + 1] = contents or ""
  if env_format and env_format[4] then
    out[#out + 1] = env_format[4] .. "\n"
  end
  if column_width then
    out[#out + 1] = "\\end{column}\n"
  end
  if end_columns then
    out[#out + 1] = "\\end{columns}"
  end
  return table.concat(out)
end

T.headline = function(h, contents, info)
  if h.footnote_section_p then
    return nil
  end
  local level = ox.get_relative_level(h, info)
  local flevel = frame_level(h, info)
  local environment = nw(prop(h, "BEAMER_ENV")) or "block"
  local pre = string.rep("\n", h.pre_blank or 0)
  if environment == "againframe" then
    local ref = prop(h, "BEAMER_REF")
    if not nw(ref) then
      return nil
    end
    local s = "\\againframe"
    local overlay = prop(h, "BEAMER_ACT")
    if overlay then
      s = s .. action_arg(overlay)
    end
    local options = prop(h, "BEAMER_OPT")
    if options then
      s = s .. normalize_argument(options, "option")
    end
    local target
    local idref = ref:match("^id:(.*)$") or ref:match("^#(.*)$")
    if idref then
      target = ox.resolve_id_link({ path = idref, link_type = "custom-id" }, info)
    else
      target = ox.resolve_fuzzy_link(ref:sub(1, 1) == "*" and ref or ("*" .. ref), info)
    end
    return s .. fmt("{%s}", get_label(target, info))
  elseif environment == "appendix" then
    return "\\appendix" .. (prop(h, "BEAMER_ACT") or "") .. "\n" .. pre .. (contents or "")
  elseif environment == "ignoreheading" then
    return pre .. (contents or "")
  elseif environment == "note" or environment == "noteNH" then
    local s = "\\note"
    local overlay = prop(h, "BEAMER_ACT")
    if overlay then
      s = s .. action_arg(overlay)
    end
    local title = environment == "note" and (ox.data(h.title, info) .. "\n") or ""
    return s .. fmt("{%s}", title .. trim(contents or ""))
  elseif level == flevel then
    return format_frame(h, contents, info)
  elseif level < flevel then
    return format_section(h, contents, info)
  end
  return format_block(h, contents, info)
end

T.item = function(el, contents, info)
  local first = el.contents[1]
  local action = first and first.type == "paragraph" and has_overlay(first)
  local output = latex.transcoders.item(el, contents, info)
  if action and output:find("\\item", 1, true) then
    local a, b = output:find("\\item", 1, true)
    output = output:sub(1, b) .. action .. output:sub(b + 1)
    _ = a
  end
  return output
end

T.keyword = function(el, contents, info)
  local key, value = el.key, el.value
  if key == "BEAMER" then
    return value
  elseif key == "TOC" and value:match("%f[%w]headlines%f[%W]") then
    local depth = tonumber(value:match("%d+")) or info.with_toc
    local options = value:match("%[.-%]")
    return ((type(depth) == "number" and depth >= 0) and fmt("\\setcounter{tocdepth}{%s}\n", depth) or "")
      .. "\\tableofcontents"
      .. (options or "")
  end
  return ox.with_backend("latex", el, contents, info)
end

T.link = function(el, contents, info)
  local custom = ox.custom_protocol_maybe(el, contents, "beamer", info)
  if custom then
    return custom
  end
  local out = ox.with_backend("latex", el, contents, info)
  if not out then
    return out
  end
  local parent = element.parent_element(el)
  local overlay = parent and ox.read_attribute("attr_beamer", parent, "overlay")
  local target, rest = out:match("^\\hyperref%[(.-)%](.*)$")
  if target then
    return fmt("\\hyperlink%s{%s}", has_overlay(el) or "", target) .. rest
  end
  local a, b, kind, brace = out:find("\\include(graphics)([%[{]?)")
  if not a then
    a, b, kind, brace = out:find("\\include(svg)([%[{]?)")
  end
  if a then
    return out:sub(1, a - 1) .. "\\include" .. kind .. (overlay or "") .. brace .. out:sub(b + 1)
  end
  return out
end

T["plain-list"] = function(el, contents, info)
  local attributes = ox.read_attribute("attr_latex", el)
  local battr = ox.read_attribute("attr_beamer", el)
  for _, k in ipairs(battr._keys) do
    attributes[k] = battr[k]
  end
  local ltype = attributes.environment
    or (el.list_type == "ordered" and "enumerate" or (el.list_type == "descriptive" and "description" or "itemize"))
  local out = fmt(
    "\\begin{%s}%s%s\n%s\\end{%s}",
    ltype,
    normalize_argument(attributes.overlay or "", "defaction"),
    normalize_argument(attributes.options or "", "option"),
    contents or "",
    ltype
  )
  local label = latex.label(el, info)
  if nw(out) and label then
    return fmt("\\phantomsection\n\\label{%s}\n", label) .. out
  end
  return out
end

T["radio-target"] = function(el, text, info)
  return fmt("\\hypertarget%s{%s}{%s}", has_overlay(el) or "", ox.get_reference(el, info), text or "")
end

local function format_spec(info)
  local data = require("org.export.latex_data")
  local lang = info.language
  local plist = data.languages[lang]
  lang = plist and plist.lang_name or lang or ""
  local d = ox.get_date(info)
  return {
    a = info.with_author and ox.data(info.author, info) or "",
    t = info.with_title and ox.data(info.title, info) or "",
    s = info.with_title and ox.data(info.subtitle, info) or "",
    k = ox.data(latex.wrap_math_block(info.keywords_latex, info), info),
    d = ox.data(latex.wrap_math_block(info.description_latex, info), info),
    c = info.with_creator and (info.creator or "") or "",
    l = lang,
    L = (lang:gsub("(%w)(%w*)", function(x, y)
      return x:upper() .. y:lower()
    end)),
    D = type(d) == "string" and d or ox.data(d, info),
  }
end

local function format_spec_apply(s, spec)
  return (s:gsub("%%(.)", function(c)
    if c == "%" then
      return "%"
    end
    return spec[c] or ("%" .. c)
  end))
end

T.template = function(contents, info)
  local title = ox.data(info.title, info)
  local subtitle = ox.data(info.subtitle, info)
  local out = {}
  if info.time_stamp_file then
    out[#out + 1] = ox.format_time("%% Created %Y-%m-%d %a %H:%M\n")
  end
  local compiler = info.latex_compiler
  if compiler == "pdflatex" or compiler == "xelatex" or compiler == "lualatex" then
    out[#out + 1] = fmt("%% Intended LaTeX compiler: %s\n", compiler)
  end
  out[#out + 1] = latex.make_preamble(info)
  if info.beamer_define_frame then
    local e = info.beamer_frame_environment
    out[#out + 1] = fmt("\\newenvironment<>{%s}[1][]{\\begin{frame}#2[environment=%s,#1]}{\\end{frame}}\n", e, e)
  end
  for _, p in ipairs({
    { "beamer_theme", "\\usetheme" },
    { "beamer_color_theme", "\\usecolortheme" },
    { "beamer_font_theme", "\\usefonttheme" },
    { "beamer_inner_theme", "\\useinnertheme" },
    { "beamer_outer_theme", "\\useoutertheme" },
  }) do
    local theme = info[p[1]]
    if theme then
      local o = theme:match("%[.*%]")
      if not o then
        out[#out + 1] = p[2] .. fmt("{%s}\n", theme)
      else
        local a, b = theme:find("%[.*%]")
        out[#out + 1] = p[2] .. fmt("%s{%s}\n", o, trim(theme:sub(1, a - 1) .. theme:sub(b + 1)))
      end
    end
  end
  if type(info.section_numbers) == "number" then
    out[#out + 1] = fmt("\\setcounter{secnumdepth}{%d}\n", info.section_numbers)
  end
  local author = info.with_author and info.author and ox.data(info.author, info) or nil
  local email = info.with_email and ox.data(info.email, info) or nil
  if author and email and email ~= "" then
    out[#out + 1] = fmt("\\author{%s\\thanks{%s}}\n", author, email)
  elseif author or email then
    out[#out + 1] = fmt("\\author{%s}\n", author or email)
  end
  local date = info.with_date and ox.get_date(info) or nil
  out[#out + 1] = fmt("\\date{%s}\n", type(date) == "string" and date or ox.data(date, info))
  out[#out + 1] = fmt("\\title{%s}\n", title)
  if nw(subtitle) then
    out[#out + 1] = (info.beamer_subtitle_format:gsub("%%s", function()
      return subtitle
    end)) .. "\n"
  end
  if info.beamer_header then
    out[#out + 1] = info.beamer_header .. "\n"
  end
  if type(info.latex_hyperref_template) == "string" then
    out[#out + 1] = format_spec_apply(info.latex_hyperref_template, format_spec(info))
  end
  out[#out + 1] = "\\begin{document}\n\n"
  local tc = info.latex_title_command
  if info.with_title and title ~= "" and type(tc) == "string" then
    local command = tc
    if command:match("%%s") then
      command = command:gsub("%%s", function()
        return title
      end)
    end
    out[#out + 1] = ox.normalize_string(command)
  end
  local depth = info.with_toc
  if depth then
    out[#out + 1] = fmt(
      "\\begin{frame}%s{%s}\n",
      normalize_argument(info.beamer_outline_frame_options or "", "option"),
      info.beamer_outline_frame_title
    )
    if type(depth) == "number" and depth >= 0 then
      out[#out + 1] = fmt("\\setcounter{tocdepth}{%d}\n", depth)
    end
    out[#out + 1] = "\\tableofcontents\n\\end{frame}\n\n"
  end
  out[#out + 1] = contents
  out[#out + 1] = info.with_creator and ((info.creator or "") .. "\n") or ""
  out[#out + 1] = "\\end{document}"
  return table.concat(out)
end

M.transcoders = T

function M.options()
  return {
    { "headline_levels", nil, "H", opt("frame_level", 1) },
    { "latex_class", "LATEX_CLASS", nil, "beamer", "t" },
    { "beamer_subtitle_format", nil, nil, opt("subtitle_format", "\\subtitle{%s}") },
    {
      "beamer_column_view_format",
      "COLUMNS",
      nil,
      opt("column_view_format", "%45ITEM %10BEAMER_env(Env) %10BEAMER_act(Act) %4BEAMER_col(Col) %8BEAMER_opt(Opt)"),
    },
    { "beamer_theme", "BEAMER_THEME", nil, opt("theme", "default") },
    { "beamer_color_theme", "BEAMER_COLOR_THEME", nil, nil, "t" },
    { "beamer_font_theme", "BEAMER_FONT_THEME", nil, nil, "t" },
    { "beamer_inner_theme", "BEAMER_INNER_THEME", nil, nil, "t" },
    { "beamer_outer_theme", "BEAMER_OUTER_THEME", nil, nil, "t" },
    { "beamer_header", "BEAMER_HEADER", nil, nil, "newline" },
    { "beamer_environments_extra", nil, nil, opt("environments_extra", {}) },
    { "beamer_frame_default_options", nil, nil, opt("frame_default_options", "") },
    { "beamer_outline_frame_options", nil, nil, opt("outline_frame_options", "") },
    { "beamer_outline_frame_title", nil, nil, opt("outline_frame_title", "Outline") },
    { "beamer_frame_environment", nil, nil, opt("frame_environment", "orgframe") },
  }
end

M.backend = ox.define_backend("beamer", {
  parent = "latex",
  transcoders = T,
  options = M.options,
})

return M

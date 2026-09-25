---@mod org.export.latex LaTeX back-end (port of Emacs ox-latex.el)

local ox = require("org.export.ox")
local element = require("org.export.element")
local entities = require("org.export.entities")
local data = require("org.export.latex_data")

local M = {}

M.extension = "tex"

local nw = ox.nw
local trim = ox.trim
local fmt = string.format

local function lcfg()
  return (require("org.config").opts.export or {}).latex or {}
end

--- String replacement without pattern characters in the replacement.
local function replace_first(s, pat, repl)
  local a, b = s:find(pat)
  if not a then
    return s, false
  end
  return s:sub(1, a - 1) .. repl .. s:sub(b + 1), true
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function protect_text(text)
  return (text:gsub("([\\{}%$%%&_#~%^])", "\\%1"))
end
M.protect_text = protect_text

local function protect_texttt(text)
  local out = {}
  local i = 1
  while i <= #text do
    local two = text:sub(i, i + 1)
    local c = text:sub(i, i)
    if two == "--" then
      out[#out + 1] = "-{}-{}"
      i = i + 2
    elseif two == "<<" then
      out[#out + 1] = "<{}<{}"
      i = i + 2
    elseif two == ">>" then
      out[#out + 1] = ">{}>{}"
      i = i + 2
    elseif c == "\\" then
      out[#out + 1] = "\\textbackslash{}"
      i = i + 1
    elseif c == "~" then
      out[#out + 1] = "\\textasciitilde{}"
      i = i + 1
    elseif c == "^" then
      out[#out + 1] = "\\textasciicircum{}"
      i = i + 1
    elseif c:match("[{}%$%%&_#]") then
      out[#out + 1] = "\\" .. c
      i = i + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return "\\texttt{" .. table.concat(out) .. "}"
end
M.protect_texttt = protect_texttt

local function find_verb_separator(s)
  local ll = "~,./?;':\"|!@#%^&-_=+abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ<>()[]{}"
  for i = 1, #ll do
    local c = ll:sub(i, i)
    if not s:find(c, 1, true) then
      return c
    end
  end
end

local function text_markup(text, markup, info)
  local f = info.latex_text_markup_alist[markup]
  if f == nil then
    return text
  elseif f == "verb" then
    local sep = find_verb_separator(text)
    return "\\verb" .. sep .. text:gsub("\n", " ") .. sep
  elseif f == "protectedtexttt" then
    return protect_texttt(text)
  end
  return (f:gsub("%%s", function()
    return text
  end))
end
M.text_markup = text_markup

local MATH_ENVS = {
  "equation",
  "eqnarray",
  "math",
  "displaymath",
  "align",
  "gather",
  "multline",
  "flalign",
  "alignat",
  "xalignat",
  "xxalignat",
  "subequations",
  "dmath",
  "dseries",
  "dgroup",
  "darray",
  "empheq",
}
local function math_env_p(value)
  local env = (value or ""):match("^[ \t]*\\begin{([^}]+)}")
  if not env then
    return false
  end
  env = env:gsub("%*$", "")
  return vim.tbl_contains(MATH_ENVS, env)
end
M.math_env_p = math_env_p

local function caption_above_p(el, info)
  local above = info.latex_caption_above
  if type(above) ~= "table" then
    return above
  end
  local t = el.type == "link" and "image" or el.type
  return vim.tbl_contains(above, t)
end

function M.label(datum, info, force, full)
  local t = datum.type
  local user
  if t == "headline" or t == "inlinetask" then
    user = datum.props and datum.props.CUSTOM_ID
  elseif t == "target" then
    user = datum.value
  else
    user = datum.name or (datum.results and datum.results[1])
    if type(user) ~= "string" then
      user = nil
    end
  end
  local label
  if user or force then
    if user and info.latex_prefer_user_labels then
      label = user
    else
      local prefix = ""
      if t == "headline" then
        prefix = "sec:"
      elseif t == "table" then
        prefix = "tab:"
      elseif t == "latex-environment" then
        prefix = math_env_p(datum.value) and "eq:" or ""
      elseif t == "latex-matrices" then
        prefix = "eq:"
      elseif t == "paragraph" then
        prefix = datum.caption and "fig:" or ""
      elseif t == "src-block" then
        prefix = "lst:"
      end
      label = prefix .. ox.get_reference(datum, info)
    end
  end
  if not full then
    return label
  end
  if label then
    return fmt("\\label{%s}%s", label, t == "target" and "" or "\n")
  end
  return ""
end

local function environment_type(el)
  local value = el.value or ""
  local env = value:match("\\begin{([%w%*]+)}") or ""
  if math_env_p(value) then
    return "math"
  end
  for _, e in ipairs({ "table", "longtable", "tabular", "tabu", "longtabu" }) do
    if env:find(e, 1, true) then
      return "table"
    end
  end
  if env:find("figure", 1, true) then
    return "image"
  end
  for _, e in ipairs({ "lstlisting", "listing", "verbatim", "minted" }) do
    if env:find(e, 1, true) then
      return "src-block"
    end
  end
  return "special-block"
end

function M.caption_label_string(el, info)
  local label = M.label(el, info, nil, true)
  local main = ox.get_caption(el)
  local attr = ox.read_attribute("attr_latex", el)
  local t = el.type
  local backend = info.latex_src_block_backend
  local nonfloat = (vim.tbl_contains(attr._keys, "float") and not attr.float and main)
    or (t == "src-block" and not attr.float and (backend == "verbatim" or backend == nil))
  local short = ox.get_caption(el, true)
  if nw(attr.caption) then
    return attr.caption .. "\n"
  end
  if not main and label == "" then
    return ""
  end
  if not main then
    return label
  end
  local tt = t == "latex-environment" and environment_type(el) or t
  local env = ""
  if nonfloat then
    if tt == "paragraph" or tt == "image" or tt == "special-block" then
      env = "figure"
    elseif tt == "src-block" then
      env = (backend ~= "verbatim" and backend ~= nil) and "listing" or "figure"
    else
      env = tt
    end
  end
  return fmt(
    nonfloat and "\\captionof{%s}%s{%s%s}\n" or "\\caption%s%s{%s%s}\n",
    env,
    short and fmt("[%s]", ox.data(short, info)) or "",
    trim(label),
    ox.data(main, info)
  )
end

local function wrap_label(el, output, info)
  local label = M.label(el, info)
  if not (nw(output) and label) then
    return output
  end
  return fmt("\\phantomsection\n\\label{%s}\n", label) .. output
end

local function translate(s, info)
  return ox.translate(s, "latex", info)
end

local function make_option_string(options, sep)
  local parts = {}
  for _, pair in ipairs(options or {}) do
    local key = pair[1]
    local value = pair[2]
    parts[#parts + 1] = key .. (value and ("=" .. (value:find("[%[%]]") and fmt("{%s}", value) or value)) or "")
  end
  return table.concat(parts, sep or ",")
end
M.make_option_string = make_option_string

--- Footnote definitions of references inside ELEMENT as \footnotetext.
local function delayed_footnotes(el, info)
  local all = {}
  local function search(d)
    element.map(d, "footnote-reference", function(ref)
      if ox.footnote_first_reference_p(ref, info) then
        all[#all + 1] = ref
        if ref.fn_type == "standard" then
          search(ox.get_footnote_definition(ref, info))
        end
      end
    end, { ignore = info.ignore })
  end
  search(el)
  local out = {}
  for _, ref in ipairs(all) do
    local def = ox.get_footnote_definition(ref, info)
    out[#out + 1] = fmt(
      "\\footnotetext[%d]{%s%s}",
      ox.get_footnote_number(ref, info),
      trim(M.label(def, info, true, true)),
      trim(ox.data(def, info))
    )
  end
  return table.concat(out)
end

local function language_name(info)
  local lang = info.language
  local plist = data.languages[lang]
  return plist and plist.lang_name or lang
end

local function capitalize(s)
  return (s:gsub("(%w)(%w*)", function(a, b)
    return a:upper() .. b:lower()
  end))
end

local function format_spec(info)
  local lang = language_name(info) or ""
  return {
    a = info.with_author and ox.data(info.author, info) or "",
    t = info.with_title and ox.data(info.title, info) or "",
    s = info.with_title and ox.data(info.subtitle, info) or "",
    k = ox.data(M.wrap_math_block(info.keywords_latex, info), info),
    d = ox.data(M.wrap_math_block(info.description_latex, info), info),
    c = info.with_creator and (info.creator or "") or "",
    l = lang,
    L = capitalize(lang),
    D = (function()
      local d = ox.get_date(info)
      return type(d) == "string" and d or ox.data(d, info)
    end)(),
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

---------------------------------------------------------------------------
-- Math blocks and matrices (parse tree filters)
---------------------------------------------------------------------------

local function valid_math_object(o)
  if o.type == "entity" then
    local e = entities[o.name]
    return e and e[2] == true
  elseif o.type == "latex-fragment" then
    local v = o.value
    return v:sub(1, 2) == "\\(" or v:match("^%$[^%$]") ~= nil
  end
  return false
end

--- Merge contiguous math objects in latex-math-block pseudo objects.
function M.wrap_math_block(d, info)
  if d == nil then
    return nil
  end
  local objs = element.map(d, { entity = true, ["latex-fragment"] = true }, function(o)
    return o
  end, { with_affiliated = true })
  for _, object in ipairs(objs) do
    if object.parent and object.parent.type ~= "latex-math-block" and valid_math_object(object) then
      local sib = element.siblings(object) or (d.type == nil and d or nil)
      if sib then
        local idx
        for i, x in ipairs(sib) do
          if x == object then
            idx = i
          end
        end
        if idx then
          local block = element.node("latex-math-block", {})
          block.parent = object.parent
          local members = { object }
          local last = object
          if (object.post_blank or 0) == 0 then
            local k = idx + 1
            while sib[k] and valid_math_object(sib[k]) and not info.ignore[sib[k]] do
              members[#members + 1] = sib[k]
              last.post_blank = 1
              last = sib[k]
              k = k + 1
              if (last.post_blank or 0) > 0 then
                break
              end
            end
          end
          block.post_blank = last.post_blank
          for _, m in ipairs(members) do
            m.parent = block
          end
          block.contents = members
          sib[idx] = block
          for _ = 2, #members do
            table.remove(sib, idx + 1)
          end
        end
      end
    end
  end
  return d
end

--- Merge contiguous tables with :mode math into latex-matrices elements.
function M.wrap_matrices(tree, info)
  local tables = element.map(tree, "table", function(t)
    return t
  end, { ignore = info.ignore })
  for _, tbl in ipairs(tables) do
    if tbl.table_type == "org" and tbl.parent and tbl.parent.type ~= "latex-matrices" then
      local mode = ox.read_attribute("attr_latex", tbl, "mode") or info.latex_default_table_mode
      if mode == "inline-math" or mode == "math" then
        local caption = mode ~= "inline-math" and tbl.caption
        local name = mode ~= "inline-math" and tbl.name
        local markup = mode == "inline-math" and "inline" or ((caption or name) and "equation" or "math")
        local sib = element.siblings(tbl)
        local idx
        for i, x in ipairs(sib) do
          if x == tbl then
            idx = i
          end
        end
        local matrices = element.node("latex-matrices", { name = name, markup = markup })
        matrices.parent = tbl.parent
        local members = { tbl }
        local prev = tbl
        local k = idx + 1
        while (prev.post_blank or 0) == 0 and sib[k] and sib[k].type == "table" and sib[k].table_type == "org" do
          local m2 = ox.read_attribute("attr_latex", sib[k], "mode") or info.latex_default_table_mode
          if m2 ~= mode then
            break
          end
          members[#members + 1] = sib[k]
          prev = sib[k]
          k = k + 1
        end
        matrices.post_blank = prev.post_blank
        prev.post_blank = 0
        for _, m in ipairs(members) do
          m.name = nil
          m.caption = nil
          m.parent = matrices
        end
        matrices.contents = members
        sib[idx] = matrices
        for _ = 2, #members do
          table.remove(sib, idx + 1)
        end
      end
    end
  end
  return tree
end

---------------------------------------------------------------------------
-- Preamble and template
---------------------------------------------------------------------------

local COMPILERS = { pdflatex = true, xelatex = true, lualatex = true }

local function remove_packages(pkgs, info)
  local compiler = (info.latex_compiler or ""):lower()
  if not COMPILERS[compiler] then
    return pkgs
  end
  local out = {}
  for _, p in ipairs(pkgs) do
    if type(p) ~= "table" or not p[4] then
      out[#out + 1] = p
    else
      local ok = false
      for _, c in ipairs(p[4]) do
        if c:lower() == compiler then
          ok = true
        end
      end
      if ok then
        out[#out + 1] = p
      end
    end
  end
  return out
end

local function packages_to_string(pkgs, snippets, newline)
  local parts = {}
  for _, p in ipairs(pkgs) do
    if type(p) == "string" then
      parts[#parts + 1] = p
    elseif snippets and #p >= 3 and not p[3] then
      parts[#parts + 1] = fmt("%% Package %s omitted", p[2])
    elseif p[1] == "" then
      parts[#parts + 1] = fmt("\\usepackage{%s}", p[2])
    else
      parts[#parts + 1] = fmt("\\usepackage[%s]{%s}", p[1], p[2])
    end
  end
  local s = table.concat(parts, "\n")
  return newline and (s .. "\n") or s
end

--- org-splice-latex-header
function M.splice_header(tpl, def_pkg, pkg, snippets, extra)
  local ending = ""
  local a, b, no = tpl:find("\n?[ \t]*%[(N?O?%-?)DEFAULT%-PACKAGES%][ \t]*\n?")
  -- anchored at line start
  local s1, e1 = tpl:find("%[NO%-DEFAULT%-PACKAGES%][ \t]*\n?")
  local s2, e2 = tpl:find("%[DEFAULT%-PACKAGES%][ \t]*\n?")
  _ = a
  _ = b
  _ = no
  if s1 then
    local ls = s1
    while ls > 1 and tpl:sub(ls - 1, ls - 1):match("[ \t]") do
      ls = ls - 1
    end
    tpl = tpl:sub(1, ls - 1) .. tpl:sub(e1 + 1)
  elseif s2 then
    local ls = s2
    while ls > 1 and tpl:sub(ls - 1, ls - 1):match("[ \t]") do
      ls = ls - 1
    end
    local rpl = (#def_pkg > 0) and packages_to_string(def_pkg, snippets, true) or ""
    tpl = tpl:sub(1, ls - 1) .. rpl .. tpl:sub(e2 + 1)
  elseif #def_pkg > 0 then
    ending = packages_to_string(def_pkg, snippets)
  end
  local s3, e3 = tpl:find("%[NO%-PACKAGES%][ \t]*\n?")
  local s4, e4 = tpl:find("%[PACKAGES%][ \t]*\n?")
  if s3 then
    tpl = tpl:sub(1, s3 - 1) .. tpl:sub(e3 + 1)
  elseif s4 then
    local rpl = (#pkg > 0) and packages_to_string(pkg, snippets, true) or ""
    tpl = tpl:sub(1, s4 - 1) .. rpl .. tpl:sub(e4 + 1)
  elseif #pkg > 0 then
    ending = ending .. "\n" .. packages_to_string(pkg, snippets)
  end
  local s5, e5 = tpl:find("%[NO%-EXTRA%][ \t]*\n?")
  local s6, e6 = tpl:find("%[EXTRA%][ \t]*\n?")
  if s5 then
    tpl = tpl:sub(1, s5 - 1) .. tpl:sub(e5 + 1)
  elseif s6 then
    local rpl = extra and (extra .. "\n") or ""
    tpl = tpl:sub(1, s6 - 1) .. rpl .. tpl:sub(e6 + 1)
  elseif extra and extra:find("%S") then
    ending = ending .. "\n" .. extra
  end
  if ending:find("%S") then
    return tpl .. "\n" .. ending
  end
  return tpl
end

local function guess_inputenc(header)
  local cs = lcfg().inputenc or "utf8"
  local alist = lcfg().inputenc_alist or {}
  cs = alist[cs] or cs
  return (header:gsub("\\usepackage%[AUTO%]{inputenc}", function()
    return "\\usepackage[" .. cs .. "]{inputenc}"
  end))
end

local function guess_babel_language(header, info)
  local code = info.language
  local plist = data.languages[code] or {}
  local language = plist.babel
  local ini_only = plist.babel_ini_only
  local ini_alt = plist.babel_ini_alt
  if not ini_only and type(code) == "string" then
    local a, b, opts = header:find("\\usepackage%[([^%]]*)%]{babel}")
    if a then
      local options = vim.split(opts, ",[ \t]*")
      local new
      if vim.tbl_contains(options, language) then
        new = vim.tbl_filter(function(o)
          return o ~= "AUTO"
        end, options)
      elseif vim.tbl_contains(options, "AUTO") then
        new = options
      else
        new = vim.list_extend(vim.deepcopy(options), { language })
      end
      local mapped = {}
      for i, o in ipairs(new) do
        mapped[i] = o == "AUTO" and language or o
      end
      local repl = "\\usepackage[" .. table.concat(mapped, ", ") .. "]{babel}"
      header = header:sub(1, a - 1) .. repl .. header:sub(b + 1)
    end
  end
  local prov = header:match("\\babelprovide%[.-%]{(.-)}")
  if prov == "AUTO" then
    header = header:gsub("(\\babelprovide%[.-%]){AUTO}", function(pre)
      return pre .. "{" .. (ini_alt or language or ini_only or "") .. "}"
    end)
  end
  return header
end

local function guess_polyglossia_language(header, info)
  local language = info.language
  if type(language) ~= "string" then
    return header
  end
  local a, b, options = header:find("\\usepackage%[([^%]]-)%]{polyglossia}\n")
  if not a then
    return header
  end
  local langs = {}
  local seen = {}
  local list = vim.split((options:gsub("AUTO", language)), ",[ \t]*")
  for i = #list, 1, -1 do
    if not seen[list[i]] then
      seen[list[i]] = true
      langs[#langs + 1] = list[i]
    end
  end
  local main_set = header:find("\\setmainlanguage{.-}") ~= nil
  local out = { "\\usepackage{polyglossia}\n" }
  for _, l in ipairs(langs) do
    local plist = data.languages[language] or {}
    local variant = plist.polyglossia_variant
    local name = l == language and plist.polyglossia or l
    if main_set then
      out[#out + 1] = fmt("\\setotherlanguage{%s}\n", name)
    else
      main_set = true
      out[#out + 1] = fmt("\\setmainlanguage%s{%s}\n", variant and fmt("[variant=%s]", variant) or "", name)
    end
  end
  return header:sub(1, a - 1) .. table.concat(out) .. header:sub(b + 1)
end

function M.find_class(info, name)
  for _, c in ipairs(info.latex_classes) do
    if c[1] == name then
      return c
    end
  end
end

function M.make_preamble(info, template, snippet)
  local class = info.latex_class
  local class_template = template
  if not class_template then
    local c = M.find_class(info, class)
    if not c or type(c[2]) ~= "string" then
      error(fmt("Unknown LaTeX class `%s'", tostring(class)), 0)
    end
    local header = c[2]
    local opts = info.latex_class_options
    if opts then
      header = header:gsub("^[ \t]*\\documentclass(%[[^%]]*%])", function()
        return "\\documentclass" .. opts
      end, 1)
      if not header:find("\\documentclass" .. vim.pesc(opts), 1) then
        header = header:gsub("^([ \t]*\\documentclass)", "%1" .. opts:gsub("%%", "%%%%"), 1)
      end
    end
    local parts = {}
    if not snippet and info.latex_class_pre then
      parts[#parts + 1] = ox.normalize_string(info.latex_class_pre)
    end
    parts[#parts + 1] = ox.normalize_string(header)
    class_template = table.concat(parts)
  end
  local extra_parts = {}
  for _, x in ipairs({
    info.latex_header,
    (not snippet) and info.latex_header_extra or nil,
    ((not snippet) and info.latex_use_sans) and "\\renewcommand*\\familydefault{\\sfdefault}" or nil,
  }) do
    if x then
      extra_parts[#extra_parts + 1] = ox.normalize_string(x)
    end
  end
  local header = M.splice_header(
    class_template,
    remove_packages(info.latex_default_packages or data.default_packages, info),
    remove_packages(info.latex_packages or {}, info),
    snippet,
    table.concat(extra_parts)
  )
  return guess_polyglossia_language(guess_babel_language(guess_inputenc(ox.normalize_string(header)), info), info)
end

local function template(contents, info)
  local title = ox.data(info.title, info)
  local spec = format_spec(info)
  local out = {}
  if info.time_stamp_file then
    out[#out + 1] = ox.format_time("%% Created %Y-%m-%d %a %H:%M\n")
  end
  local compiler = info.latex_compiler
  if COMPILERS[compiler or ""] then
    out[#out + 1] = fmt("%% Intended LaTeX compiler: %s\n", compiler)
  end
  out[#out + 1] = M.make_preamble(info)
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
  local sub = info.subtitle
  local fsub = sub and info.latex_subtitle_format:gsub("%%s", function()
    return ox.data(sub, info)
  end)
  out[#out + 1] = fmt("\\title{%s%s}\n", title, info.latex_subtitle_separate and "" or (fsub or ""))
  if info.latex_subtitle_separate and sub then
    out[#out + 1] = fsub .. "\n"
  end
  if type(info.latex_hyperref_template) == "string" then
    out[#out + 1] = format_spec_apply(info.latex_hyperref_template, spec)
  end
  out[#out + 1] = "\\begin{document}\n\n"
  local tc = info.latex_title_command
  local command = type(tc) == "string" and format_spec_apply(tc, spec) or nil
  if info.with_title and title ~= "" and command then
    if command:match("%%s") then
      command = command:gsub("%%s", function()
        return title
      end)
    end
    out[#out + 1] = ox.normalize_string(command)
  end
  local depth = info.with_toc
  if depth then
    if type(depth) == "number" then
      out[#out + 1] = fmt("\\setcounter{tocdepth}{%d}\n", depth)
    end
    out[#out + 1] = info.latex_toc_command
  end
  out[#out + 1] = contents
  if info.with_creator then
    out[#out + 1] = (info.creator or "") .. "\n"
  end
  out[#out + 1] = "\\end{document}"
  return table.concat(out)
end
M.template = template

---------------------------------------------------------------------------
-- Transcoders
---------------------------------------------------------------------------

local T = {}

T.bold = function(_, contents, info)
  return text_markup(contents, "bold", info)
end
T.italic = function(_, contents, info)
  return text_markup(contents, "italic", info)
end
T.underline = function(_, contents, info)
  return text_markup(contents, "underline", info)
end
T["strike-through"] = function(_, contents, info)
  return text_markup(contents, "strike-through", info)
end
T.code = function(el, _, info)
  return text_markup(el.value, "code", info)
end
T.verbatim = function(el, _, info)
  return text_markup(el.value, "verbatim", info)
end

T["center-block"] = function(el, contents, info)
  return wrap_label(el, fmt("\\begin{center}\n%s\\end{center}", contents or ""), info)
end

T.clock = function(el, _, info)
  return "\\noindent"
    .. "\\textbf{CLOCK:} "
    .. fmt(info.latex_inactive_timestamp_format, ox.timestamp_translate(el.value) .. (el.duration and fmt(" (%s)", el.duration) or ""))
    .. "\\\\"
end

T.drawer = function(el, contents, info)
  local f = lcfg().format_drawer_function
  local output = type(f) == "function" and f(el.drawer_name, contents) or contents
  return wrap_label(el, output, info)
end

T["dynamic-block"] = function(el, contents, info)
  return wrap_label(el, contents, info)
end

T.entity = function(el)
  return (entities[el.name] or {})[1] or ("\\" .. el.name)
end

T["example-block"] = function(el, _, info)
  if nw(el.value) then
    local env = ox.read_attribute("attr_latex", el, "environment") or "verbatim"
    return wrap_label(el, fmt("\\begin{%s}\n%s\\end{%s}", env, ox.format_code_default(el, info), env), info)
  end
end

T["export-block"] = function(el)
  if el.back_end_type == "LATEX" or el.back_end_type == "TEX" then
    return table.concat(element.remove_indentation(vim.split((el.value:gsub("\n$", "")), "\n", { plain = true })), "\n")
      .. "\n"
  end
end

T["export-snippet"] = function(el)
  local tr = (require("org.config").opts.export or {}).snippet_translation or {}
  if (tr[el.back_end] or el.back_end) == "latex" then
    return el.value
  end
end

T["fixed-width"] = function(el, _, info)
  return wrap_label(
    el,
    fmt("\\begin{verbatim}\n%s\n\\end{verbatim}", table.concat(element.remove_indentation(vim.split(el.value, "\n", { plain = true })), "\n")),
    info
  )
end

T["footnote-reference"] = function(el, _, info)
  local label = el.label
  local prev = ox.get_previous_element(el, info)
  local sep = (prev and prev.type == "footnote-reference") and info.latex_footnote_separator or ""
  if not ox.footnote_first_reference_p(el, info) then
    return sep .. fmt(info.latex_footnote_defined_format, M.label(ox.get_footnote_definition(el, info), info, true))
  end
  local parent_el = element.parent_element(el)
  if
    element.lineage(el, { ["footnote-reference"] = true, ["footnote-definition"] = true, ["table-cell"] = true })
    or (parent_el and parent_el.type == "item")
  then
    return sep .. "\\footnotemark"
  end
  local def = ox.get_footnote_definition(el, info)
  local lbl = ""
  if label then
    local other = element.map(info.parse_tree, "footnote-reference", function(f)
      if f ~= el and f.label == label then
        return f
      end
    end, { first_match = true, ignore = info.ignore })
    if other then
      lbl = trim(M.label(def, info, true, true))
    end
  end
  local body = trim(ox.data(def, info))
  local cmd = info.latex_default_footnote_command
  local i = 0
  local s = cmd:gsub("%%s", function()
    i = i + 1
    return i == 1 and body or lbl
  end)
  return sep .. s .. delayed_footnotes(def, info)
end

--- Section format of a headline (org-latex--get-section-format).
local function section_format(h, info)
  local class = M.find_class(info, info.latex_class)
  if not class then
    return nil
  end
  local level = ox.get_relative_level(h, info)
  local numberedp = ox.numbered_headline_p(h, info)
  local sec
  if type(class[3]) == "function" then
    sec = class[3](level, numberedp)
  else
    sec = class[level + 2]
  end
  if not sec then
    return nil
  end
  if type(sec) == "string" then
    return sec .. "\n%s"
  end
  if #sec == 2 then
    -- (numbered . unnumbered) pairs have a %s in both strings;
    -- (numbered-open numbered-close) environments only in the first
    if sec[1]:find("%%s") and sec[2]:find("%%s") then
      return (numberedp and sec[1] or sec[2]) .. "\n%s"
    end
    if numberedp then
      return sec[1] .. "\n%s" .. sec[2]
    end
    return nil
  elseif #sec == 4 then
    if numberedp then
      return sec[1] .. "\n%s" .. sec[2]
    end
    return sec[3] .. "\n%s" .. sec[4]
  end
end

local section_backend = ox.create_backend("latex", {
  underline = function(_, c)
    return fmt("\\underline{%s}", c or "")
  end,
  code = function(o)
    return protect_texttt(o.value)
  end,
  verbatim = function(o)
    return protect_texttt(o.value)
  end,
})
local section_no_footnote_backend = ox.create_backend(section_backend, {
  ["footnote-reference"] = function()
    return nil
  end,
})

function M.format_headline(todo, _todo_type, priority, text, tags)
  local s = (todo and fmt("{\\bfseries\\sffamily %s} ", todo) or "")
    .. (priority and fmt("\\framebox{\\#%s} ", priority) or "")
    .. (text or "")
  if tags and #tags > 0 then
    local parts = {}
    for i, t in ipairs(tags) do
      parts[i] = protect_text(t)
    end
    s = s .. fmt("\\hfill{}\\textsc{%s}", table.concat(parts, ":"))
  end
  return s
end

local function format_headline(info, ...)
  local f = lcfg().format_headline_function
  if type(f) == "function" then
    return f(...)
  end
  return M.format_headline(...)
end

--- Apply a two-slot format ("%s" title, "%s" contents).
local function format2(f, a, b)
  local i = 0
  return (f:gsub("%%s", function()
    i = i + 1
    if i == 1 then
      return a
    elseif i == 2 then
      return b
    end
    return "%s"
  end))
end

T.headline = function(el, contents, info)
  if el.footnote_section_p then
    return nil
  end
  contents = contents or ""
  local level = ox.get_relative_level(el, info)
  local unnumbered_type = ox.get_node_property("UNNUMBERED", el, true)
  local numberedp = ox.numbered_headline_p(el, info)
  local section_fmt = section_format(el, info)
  local text = ox.data_with_backend(el.title, section_backend, info)
  local text_nf = ox.data_with_backend(el.title, section_no_footnote_backend, info)
  local todo = info.with_todo_keywords and el.todo_keyword or nil
  local todo_type = todo and el.todo_type
  local tags = info.with_tags and ox.get_tags(el, info) or nil
  if tags and #tags == 0 then
    tags = nil
  end
  local priority = info.with_priority and el.priority or nil
  local full = format_headline(info, todo, todo_type, priority, text, tags, info)
  local full_nf = format_headline(info, todo, todo_type, priority, text_nf, tags, info)
  local hlabel = M.label(el, info, true, true)
  local pre = string.rep("\n", el.pre_blank or 0)
  if not section_fmt or ox.low_level_p(el, info) then
    local body = (ox.first_sibling_p(el, info) and fmt("\\begin{%s}\n", numberedp and "enumerate" or "itemize") or "")
      .. "\\item"
      .. ((full and full:match("^[ \t]*%[")) and "\\relax" or "")
      .. " "
      .. full
      .. "\n"
      .. hlabel
      .. pre
      .. contents
    if not ox.last_sibling_p(el, info) then
      return body
    end
    return (body:gsub("[ \t\n]*$", "")) .. fmt("\n\\end{%s}", numberedp and "enumerate" or "itemize")
  end
  local opt_title = format_headline(
    info,
    todo,
    todo_type,
    priority,
    ox.data_with_backend(ox.get_alt_title(el), section_backend, info),
    info.with_tags == true and tags or nil,
    info
  )
  -- local TOC end
  local first = el.contents[1]
  if first and first.type == "section" then
    local stop = element.map(first, "keyword", function(k)
      if k.key == "TOC" and k.value:lower():match("%f[%w]headlines%f[%W]") and k.value:lower():match("%f[%w]local%f[%W]") then
        return fmt("\\stopcontents[level-%d]", level)
      end
    end, { first_match = true, ignore = info.ignore })
    if stop then
      contents = contents .. stop
    end
  end
  local section_kw = section_fmt:match("^\\(.-){")
  local need_alt
  if not section_kw then
    need_alt = false
  elseif section_kw:match("%*$") then
    if info.latex_toc_include_unnumbered then
      need_alt = unnumbered_type ~= "notoc"
    else
      need_alt = unnumbered_type == "toc"
    end
  else
    need_alt = not (full == full_nf and full == opt_title)
  end
  if full_nf ~= full and full == opt_title then
    opt_title = full_nf
  end
  if need_alt then
    local new_fmt = section_fmt
    local extra = ""
    if section_kw:match("%*$") then
      extra = fmt("\\addcontentsline{toc}{%s}{%s}\n", section_kw:gsub("%*$", ""), opt_title)
    else
      local alt = opt_title:gsub("%[", "("):gsub("%]", ")")
      new_fmt = "\\" .. section_kw .. "[" .. alt:gsub("%%", "%%%%") .. "]" .. section_fmt:sub(#section_kw + 2)
    end
    return format2(new_fmt, full, hlabel .. extra .. pre .. contents)
  end
  return format2(section_fmt, full, hlabel .. pre .. contents)
end

T["horizontal-rule"] = function(el, _, info)
  local attr = ox.read_attribute("attr_latex", el)
  local prev = ox.get_previous_element(el, info)
  local nl = (prev and (prev.post_blank or 0) == 0) and "\n" or ""
  return nl .. wrap_label(el, fmt("\\noindent\\rule{%s}{%s}", attr.width or "\\textwidth", attr.thickness or "0.5pt"), info)
end

local function langs_lookup(list, lang)
  for _, x in ipairs(list or {}) do
    if x[1] == lang then
      return x[2]
    end
  end
end

T["inline-src-block"] = function(el, _, info)
  local code, lang = el.value, el.language
  local backend = info.latex_src_block_backend
  if backend == "minted" and lang then
    local mlang = langs_lookup(info.latex_minted_langs, lang) or lang:lower()
    local options = make_option_string(info.latex_minted_options)
    return fmt("\\mintinline%s{%s}{%s}", options == "" and "" or fmt("[%s]", options), mlang, code)
  elseif backend == "listings" and lang then
    local llang = langs_lookup(info.latex_listings_langs, lang) or lang
    local sep = find_verb_separator(code)
    local options = make_option_string(vim.list_extend(vim.deepcopy(info.latex_listings_options or {}), { { "language", llang } }))
    return fmt("\\lstinline[%s]", options) .. sep .. code .. sep
  end
  return text_markup(code, "code", info)
end

T.inlinetask = function(el, contents, info)
  local title = ox.data(el.title, info)
  local todo = info.with_todo_keywords and el.todo_keyword or nil
  local tags = info.with_tags and ox.get_tags(el, info) or nil
  if tags and #tags == 0 then
    tags = nil
  end
  local priority = info.with_priority and el.priority or nil
  contents = (M.label(el, info) or "") .. (contents or "")
  local f = lcfg().format_inlinetask_function
  if type(f) == "function" then
    return f(todo, el.todo_type, priority, title, tags, contents, info)
  end
  local full = (todo and fmt("\\textbf{\\textsf{\\textsc{%s}}} ", todo) or "")
    .. (priority and fmt("\\framebox{\\#%s} ", priority) or "")
    .. title
  if tags then
    local p = {}
    for i, t in ipairs(tags) do
      p[i] = protect_text(t)
    end
    full = full .. fmt("\\hfill{}\\textsc{%s}", ":" .. table.concat(p, ":") .. ":")
  end
  return "\\begin{center}\n"
    .. "\\fbox{\n"
    .. "\\begin{minipage}[c]{.6\\linewidth}\n"
    .. full
    .. "\n\n"
    .. (nw(contents) and ("\\rule[.8em]{\\linewidth}{2pt}\n\n" .. contents) or "")
    .. "\\end{minipage}\n"
    .. "}\n"
    .. "\\end{center}"
end

T.item = function(el, contents, info)
  local list = el.parent
  local orderedp = list.list_type == "ordered"
  local level = 0
  local p = el.parent
  while p and (p.type == "plain-list" or p.type == "item") do
    if p.type == "plain-list" and p.list_type == "ordered" then
      level = level + 1
    end
    p = p.parent
  end
  local count = el.counter
  local counter = (count and level < 5) and fmt("\\setcounter{enum%s}{%s}\n", ({ "i", "ii", "iii", "iv" })[level] or "", count - 1)
    or ""
  local checkbox = ({ on = "$\\boxtimes$", off = "$\\square$", trans = "$\\boxminus$" })[el.checkbox or ""]
  local tag = el.tag and ox.data(el.tag, info) or nil
  local tag_fn = tag and delayed_footnotes(el.tag, info) or ""
  local head
  if checkbox and tag then
    head = fmt(orderedp and "{%s %s} %s" or "[{%s %s}] %s", checkbox, tag, tag_fn)
  elseif checkbox or tag then
    head = fmt(orderedp and "{%s} %s" or "[{%s}] %s", checkbox or tag, tag_fn)
  elseif contents and contents:match("^[ \t]*%[") then
    local e = el.contents[1]
    local o = e and e.type == "paragraph" and e.contents[1]
    if not (o and o.type == "export-snippet" and o.back_end == "latex") then
      head = "\\relax "
    else
      head = " "
    end
  else
    head = " "
  end
  return counter .. "\\item" .. head .. (contents and trim(contents) or "")
end

T.keyword = function(el, _, info)
  local key, value = el.key, el.value
  if key == "LATEX" then
    return value
  elseif key == "INDEX" then
    return fmt("\\index{%s}", value)
  elseif key == "TOC" then
    local low = value:lower()
    if low:match("%f[%w]headlines%f[%W]") then
      local localp = low:match("%f[%w]local%f[%W]") ~= nil
      local parent = element.lineage(el, "headline")
      local level = (localp and parent) and ox.get_relative_level(parent, info) or 0
      local n = value:match("%f[%d](%d+)%f[%D]")
      local depth = n and fmt("\\setcounter{tocdepth}{%d}", tonumber(n) + level) or nil
      if localp and parent then
        return fmt("\\startcontents[level-%d]\n\\printcontents[level-%d]{}{0}{%s}", level, level, depth or "")
      end
      return (depth and (depth .. "\n") or "") .. "\\tableofcontents"
    elseif low:match("%f[%w]tables%f[%W]") then
      return "\\listoftables"
    elseif low:match("%f[%w]listings%f[%W]") then
      local b = info.latex_src_block_backend
      if b == nil then
        return "\\listoffigures"
      elseif b == "minted" or b == "engraved" then
        return "\\listoflistings"
      end
      return "\\lstlistoflistings"
    end
  end
end

T["latex-environment"] = function(el, _, info)
  if not info.with_latex then
    return nil
  end
  local lines = element.remove_indentation(vim.split((el.value:gsub("\n$", "")), "\n", { plain = true }))
  local value = table.concat(lines, "\n") .. "\n"
  local t = environment_type(el)
  local caption = t == "math" and M.label(el, info, nil, true) or M.caption_label_string(el, info)
  local above = t == "math" or caption_above_p(el, info)
  if not (el.name or el.caption) then
    return value
  end
  if above then
    local nl = value:find("\n")
    return value:sub(1, nl) .. caption .. value:sub(nl + 1)
  end
  -- before the last line
  local last_nl = value:sub(1, -2):match(".*()\n")
  if last_nl then
    return value:sub(1, last_nl) .. caption .. value:sub(last_nl + 1)
  end
  return caption .. value
end

T["latex-fragment"] = function(el)
  local v = el.value
  if v:match("^%$[^%$]") then
    return v:sub(2, -2)
  elseif v:sub(1, 2) == "\\(" then
    return v:sub(3, -3)
  end
  return v
end

T["latex-math-block"] = function(_, contents)
  if nw(contents) then
    return fmt("\\(%s\\)", trim(contents))
  end
end

T["latex-matrices"] = function(el, contents, info)
  if el.markup == "inline" then
    return fmt("\\(%s\\)", contents)
  elseif el.markup == "equation" then
    local caption = M.caption_label_string(el, info)
    local above = caption_above_p(el, info)
    return "\\begin{equation}\n" .. (above and caption or "") .. contents .. ((not above) and caption or "") .. "\\end{equation}"
  end
  return fmt("\\[\n%s\\]", contents)
end

T["line-break"] = function()
  return "\\\\\n"
end

M.inline_image_rules = {
  file = { "pdf", "jpeg", "jpg", "png", "ps", "eps", "tikz", "pgf", "svg" },
  https = { "jpeg", "jpg", "png", "ps", "eps", "tikz", "pgf", "svg" },
}

local function inline_image(link, info)
  local parent = element.parent_element(link)
  local path = link.path
  if path:match("^/") or path:match("^~") then
    path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  end
  local filetype = path:match("%.([%w]+)$")
  filetype = filetype and filetype:lower()
  local caption = M.caption_label_string(parent, info)
  local above = caption_above_p(link, info)
  local attr = ox.read_attribute("attr_latex", parent)
  local float
  local lone = true
  for _, node in ipairs(parent.contents) do
    if not info.ignore[node] then
      if node.type == "plain-text" and not nw(node.value) then
        -- ignore blanks
      elseif node ~= link and not (link.parent and link.parent ~= parent and node == link.parent) then
        lone = false
      end
    end
  end
  local f = attr.float
  if not lone then
    float = nil
  elseif f == "wrap" then
    float = "wrap"
  elseif f == "sideways" then
    float = "sideways"
  elseif f == "multicolumn" then
    float = "multicolumn"
  elseif f == "t" then
    float = "figure"
  elseif vim.tbl_contains(attr._keys, "float") and not f then
    float = "nonfloat"
  elseif f then
    float = f
  elseif parent.caption or nw(attr.caption) then
    float = "figure"
  else
    float = "nonfloat"
  end
  local placement
  if attr.placement then
    placement = attr.placement
  elseif float == "wrap" then
    placement = "{l}{0.5\\textwidth}"
  elseif float == "figure" then
    placement = fmt("[%s]", info.latex_default_figure_position)
  else
    placement = ""
  end
  local center
  if link.parent and link.parent.type == "link" then
    center = false
  elseif vim.tbl_contains(attr._keys, "center") then
    center = attr.center
  else
    center = info.latex_images_centered
  end
  local comment = attr["comment-include"] and "%" or ""
  local scale = float == "wrap" and "" or (attr.scale or info.latex_image_default_scale)
  local width
  if nw(scale) then
    width = ""
  elseif attr.width then
    width = attr.width
  elseif attr.height then
    width = ""
  elseif float == "wrap" then
    width = "0.48\\textwidth"
  else
    width = info.latex_image_default_width
  end
  local height
  if nw(scale) then
    height = ""
  elseif attr.height then
    height = attr.height
  elseif attr.width or float == "figure" or float == "wrap" then
    height = ""
  else
    height = info.latex_image_default_height
  end
  local options = attr.options or info.latex_image_default_option
  options = options:match("^%[(.*)%]$") or options
  local code
  if filetype == "tikz" or filetype == "pgf" then
    code = fmt("\\input{%s}", path)
    if nw(options) then
      code = fmt("\\begin{tikzpicture}[%s]\n%s\n\\end{tikzpicture}", options, code)
    end
    if nw(scale) then
      code = fmt("\\scalebox{%s}{%s}", scale, code)
    elseif nw(width) or nw(height) then
      code = fmt("\\resizebox{%s}{%s}{%s}", nw(width) and width or "!", nw(height) and height or "!", code)
    end
  else
    if nw(scale) then
      options = options .. ",scale=" .. scale
    else
      if nw(width) then
        options = options .. ",width=" .. width
      end
      if nw(height) then
        options = options .. ",height=" .. height
      end
    end
    local so = link.search_option
    if so and filetype == "pdf" and so:match("^%d+$") and not options:find("page=", 1, true) then
      options = options .. ",page=" .. so
    end
    local optstr = ""
    if nw(options) then
      optstr = options:sub(1, 1) == "," and fmt("[%s]", options:sub(2)) or fmt("[%s]", options)
    end
    local p = path
    if filetype == "svg" and p:find("[\128-\255]") then
      p = "\\detokenize{" .. p .. "}"
    end
    code = fmt("\\includegraphics%s{%s}", optstr, p)
    if filetype == "svg" then
      code = code:gsub("^\\includegraphics", "\\includesvg"):gsub("%.svg}", "}")
    end
  end
  local cap_above = above and caption or ""
  local cap_below = above and "" or caption
  local c = center and "\\centering" or ""
  if type(float) == "string" and not ({ wrap = 1, sideways = 1, multicolumn = 1, figure = 1, nonfloat = 1 })[float] then
    return fmt("\\begin{%s}%s\n%s%s\n%s%s\n%s\\end{%s}", float, placement, cap_above, c, comment, code, cap_below, float)
  elseif float == "wrap" then
    return fmt("\\begin{wrapfigure}%s\n%s%s\n%s%s\n%s\\end{wrapfigure}", placement, cap_above, c, comment, code, cap_below)
  elseif float == "sideways" then
    return fmt("\\begin{sidewaysfigure}\n%s%s\n%s%s\n%s\\end{sidewaysfigure}", cap_above, c, comment, code, cap_below)
  elseif float == "multicolumn" then
    return fmt("\\begin{figure*}%s\n%s%s\n%s%s\n%s\\end{figure*}", placement, cap_above, c, comment, code, cap_below)
  elseif float == "figure" then
    return fmt("\\begin{figure}%s\n%s%s\n%s%s\n%s\\end{figure}", placement, cap_above, c, comment, code, cap_below)
  elseif center then
    return fmt("\\begin{center}\n%s%s\n%s\\end{center}", cap_above, code, cap_below)
  end
  return (above and caption or "") .. code .. (above and caption or "")
end

T.link = function(el, desc, info)
  local ltype = el.link_type
  local raw = el.path
  desc = (desc ~= nil and desc ~= "") and desc or nil
  local imagep = ox.inline_image_p(el, info.latex_inline_image_rules)
  local path
  if ltype == "file" then
    path = protect_text(ox.file_uri(raw))
  else
    path = protect_text(ltype .. ":" .. raw)
  end
  local custom = ox.custom_protocol_maybe(el, desc, "latex", info)
  if custom then
    return custom
  end
  if imagep then
    return inline_image(el, info)
  end
  if ltype == "radio" then
    local dest = ox.resolve_radio_link(el, info)
    if not dest then
      return desc
    end
    return fmt("\\hyperref[%s]{%s}", ox.get_reference(dest, info), desc or "")
  end
  if ltype == "custom-id" or ltype == "fuzzy" or ltype == "id" then
    local dest = ltype == "fuzzy" and ox.resolve_fuzzy_link(el, info, { "latex-matrices" }) or ox.resolve_id_link(el, info)
    if dest.type == "plain-text" then
      if desc then
        return fmt("\\href{%s}{%s}", dest.value, desc)
      end
      return fmt("\\url{%s}", dest.value)
    elseif dest.type == "headline" then
      local label = M.label(dest, info, true)
      if not desc and ox.numbered_headline_p(dest, info) then
        return fmt(info.latex_reference_command, label)
      end
      return fmt("\\hyperref[%s]{%s}", label, desc or ox.data(dest.title, info))
    else
      local ref = M.label(dest, info, true)
      if not desc then
        return fmt(info.latex_reference_command, ref)
      end
      return fmt("\\hyperref[%s]{%s}", ref, desc)
    end
  end
  if ltype == "coderef" then
    local f = ox.get_coderef_format(path, desc)
    local r = ox.resolve_coderef(raw, info)
    return (f:gsub("%%s", function()
      return tostring(r)
    end))
  end
  if path and desc then
    return fmt("\\href{%s}{%s}", path, desc)
  elseif path then
    return fmt("\\url{%s}", path)
  end
  return fmt(info.latex_link_with_unknown_path_format, desc or "")
end

T["node-property"] = function(el)
  return fmt("%s:%s", el.key, el.value and (" " .. el.value) or "")
end

T.paragraph = function(_, contents)
  return ((contents or ""):gsub("\n[ \t\n]*\n", "\n"))
end

T["plain-list"] = function(el, contents, info)
  local attr = ox.read_attribute("attr_latex", el)
  local env = attr.environment
    or (el.list_type == "ordered" and "enumerate" or (el.list_type == "descriptive" and "description" or "itemize"))
  return wrap_label(el, fmt("\\begin{%s}%s\n%s\\end{%s}", env, attr.options or "", contents or "", env), info)
end

--- Verse block plain text rules (org-latex--plain-text-verse-block).
local function verse_text(output, node)
  local verse = node and element.lineage(node, "verse-block")
  if not verse or element.lineage(node, "footnote-reference") then
    return output
  end
  local lin = ox.read_attribute("attr_latex", verse, "lines")
  local lit = ox.read_attribute("attr_latex", verse, "literal")
  local s = output:gsub("[ \t]*\\\\[ \t]*\n", "\\\\\n"):gsub("[ \t]*\n", "\\\\\n")
  if not lit then
    -- several empty lines: a single stanza break
    s = s:gsub("\\\\\n([ \t]*\\\\\n)+", lin and "\\\\!\n\n" or "\n\n")
  else
    s = s:gsub("\n[ \t]*\\\\\n", "\n\\vspace*{\\baselineskip}\n"):gsub("^[ \t]*\\\\\n", "\\vspace*{\\baselineskip}\n")
  end
  s = s:gsub("\n([ \t]+)", function(ws)
    return fmt("\n\\hspace*{%d\\fontdimen2\\font}", #ws)
  end)
  s = s:gsub("^([ \t]+)", function(ws)
    return fmt("\\hspace*{%d\\fontdimen2\\font}", #ws)
  end)
  return s
end

function M.plain_text(text, info, node)
  local specialp = info.with_special_strings
  local out = {}
  local i = 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == "\\" then
      local nxt = text:sub(i + 1, i + 1)
      if specialp and nxt == "-" then
        out[#out + 1] = "\\"
      else
        out[#out + 1] = "$\\backslash$"
      end
    elseif c == "~" then
      out[#out + 1] = "\\textasciitilde{}"
    elseif c == "^" then
      out[#out + 1] = "\\^{}"
    elseif c:match("[%%%$#&{}_]") then
      out[#out + 1] = "\\" .. c
    else
      out[#out + 1] = c
    end
    i = i + 1
  end
  local output = table.concat(out)
  -- LaTeX -> \LaTeX{}, TeX -> \TeX{}
  output = output:gsub("%f[%w]LaTeX%f[%W]", "\\LaTeX{}"):gsub("%f[%w\\]TeX%f[%W]", "\\TeX{}")
  if info.with_smart_quotes and node then
    output = ox.activate_smart_quotes(output, "latex", info, node)
  end
  if specialp then
    output = output:gsub("%.%.%.", "\\ldots{}")
  end
  if info.preserve_breaks then
    output = output:gsub("[ \t]*\\\\[ \t]*\n", "\n"):gsub("[ \t]*\n", "\\\\\n")
  end
  output = output:gsub("\n([ \t]*)%[", "\n%1{[}"):gsub("^([ \t]*)%[", "%1{[}")
  output = verse_text(output, node)
  return output
end

T["plain-text"] = function(text, info, node)
  return M.plain_text(text, info, node)
end

T.planning = function(el, _, info)
  local parts = {}
  if el.closed then
    parts[#parts + 1] = "\\textbf{CLOSED:} " .. fmt(info.latex_inactive_timestamp_format, ox.timestamp_translate(el.closed))
  end
  if el.deadline then
    parts[#parts + 1] = "\\textbf{DEADLINE:} " .. fmt(info.latex_active_timestamp_format, ox.timestamp_translate(el.deadline))
  end
  if el.scheduled then
    parts[#parts + 1] = "\\textbf{SCHEDULED:} " .. fmt(info.latex_active_timestamp_format, ox.timestamp_translate(el.scheduled))
  end
  return "\\noindent" .. table.concat(parts, " ") .. "\\\\"
end

T["property-drawer"] = function(_, contents)
  if nw(contents) then
    return fmt("\\begin{verbatim}\n%s\\end{verbatim}", contents)
  end
end

T["quote-block"] = function(el, contents, info)
  local env = ox.read_attribute("attr_latex", el, "environment") or info.latex_default_quote_environment
  local options = ox.read_attribute("attr_latex", el, "options") or ""
  return wrap_label(el, fmt("\\begin{%s}%s\n%s\\end{%s}", env, options, contents or "", env), info)
end

T["radio-target"] = function(el, text, info)
  return fmt("\\label{%s}%s", ox.get_reference(el, info), text or "")
end

T.section = function(_, contents)
  return contents
end

T["special-block"] = function(el, contents, info)
  local t = el.block_type
  local opt = ox.read_attribute("attr_latex", el, "options")
  local caption = M.caption_label_string(el, info)
  local above = caption_above_p(el, info)
  return fmt("\\begin{%s}%s\n", t, opt or "")
    .. (above and caption or "")
    .. (contents or "")
    .. ((not above) and caption or "")
    .. fmt("\\end{%s}", t)
end

local function code_with_refs(el, retain_labels)
  local code, refs = ox.unravel_code(el)
  local max_width = 0
  for _, l in ipairs(vim.split(code, "\n", { plain = true })) do
    max_width = math.max(max_width, vim.fn.strdisplaywidth(l))
  end
  return ox.format_code(code, function(loc, _, ref)
    if ref then
      return loc .. string.rep(" ", max_width - #loc + 6) .. fmt("(%s)", ref)
    end
    return loc
  end, nil, retain_labels and refs or nil)
end

T["src-block"] = function(el, _, info)
  if not nw(el.value) then
    return nil
  end
  local lang = el.language
  local caption = el.caption
  local above = caption_above_p(el, info)
  local label = el.name
  local customs = lcfg().custom_lang_environments or {}
  local custom_env = lang and customs[lang]
  local num_start = ox.get_loc(el, info)
  local retain = el.retain_labels
  local attributes = ox.read_attribute("attr_latex", el)
  local float = attributes.float
  local backend = info.latex_src_block_backend
  if backend == "engraved" then
    -- engrave-faces needs Emacs faces: fall back to verbatim
    backend = "verbatim"
  end
  if backend == "verbatim" or not lang or (backend ~= "minted" and backend ~= "listings" and not custom_env) then
    local cap = M.caption_label_string(el, info)
    local verbatim = fmt("\\begin{verbatim}\n%s\\end{verbatim}", ox.format_code_default(el, info))
    if float == "multicolumn" then
      return fmt(
        "\\begin{figure*}[%s]\n%s%s\n%s\\end{figure*}",
        info.latex_default_figure_position,
        above and cap or "",
        verbatim,
        above and "" or cap
      )
    elseif caption then
      return (above and cap or "") .. verbatim .. (above and "" or ("\n" .. cap))
    end
    return verbatim
  elseif custom_env and backend ~= "minted" and backend ~= "listings" then
    local cap = M.caption_label_string(el, info)
    local formatted = ox.format_code_default(el, info)
    if custom_env:match("^[%w]+$") then
      return fmt("\\begin{%s}\n%s\\end{%s}\n", custom_env, (above and cap or "") .. formatted .. ((not above) and cap or ""), custom_env)
    end
    return (custom_env:gsub("%%(.)", function(c)
      return ({
        s = formatted,
        c = caption and ox.data(ox.get_caption(el), info) or "",
        f = float or "",
        l = M.label(el, info) or "",
        o = attributes.options or "",
      })[c] or ("%" .. c)
    end))
  elseif backend == "minted" then
    local cap = M.caption_label_string(el, info)
    local placement = (attributes.placement and attributes.placement:gsub("^%[(.*)%]$", "%1")) or info.latex_default_figure_position
    local multicol = float == "multicolumn"
    local open, close = "", ""
    if caption or multicol then
      open = "\\begin{listing" .. (multicol and "*" or "") .. "}[" .. placement .. "]\n" .. (above and cap or "")
      close = "\n" .. (above and "" or cap) .. "\\end{listing" .. (multicol and "*" or "") .. "}"
    elseif float == "t" then
      open = "\\begin{listing}[" .. placement .. "]\n"
      close = "\n\\end{listing}"
    end
    local options = vim.deepcopy(info.latex_minted_options or {})
    local has_linenos = false
    for _, o in ipairs(options) do
      if o[1] == "linenos" then
        has_linenos = true
      end
    end
    if num_start and not has_linenos then
      options = vim.list_extend({ { "linenos" }, { "firstnumber", tostring(num_start + 1) } }, options)
    end
    local opts = make_option_string(options) .. (attributes.options and ("," .. attributes.options) or "")
    local mlang = langs_lookup(info.latex_minted_langs, lang) or lang:lower()
    return open .. fmt("\\begin{minted}[%s]{%s}\n%s\\end{minted}", opts, mlang, code_with_refs(el, retain)) .. close
  else
    local llang = langs_lookup(info.latex_listings_langs, lang) or lang
    local caption_str
    if caption then
      local main = ox.get_caption(el)
      local secondary = ox.get_caption(el, true)
      if not secondary then
        caption_str = fmt("{%s}", ox.data(main, info))
      else
        caption_str = fmt("{[%s]%s}", ox.data(secondary, info), ox.data(main, info))
      end
    end
    local lst = vim.deepcopy(info.latex_listings_options or {})
    local opts = vim.deepcopy(lst)
    local has = function(k)
      for _, o in ipairs(lst) do
        if o[1] == k then
          return true
        end
      end
      return false
    end
    if not float and vim.tbl_contains(attributes._keys, "float") then
      -- no float
    elseif float == "multicolumn" then
      opts[#opts + 1] = { "float", "*" }
    elseif float and not has("float") then
      opts[#opts + 1] = { "float", info.latex_default_figure_position }
    end
    if not info.latex_listings_src_omit_language then
      opts[#opts + 1] = { "language", llang }
    end
    if label then
      opts[#opts + 1] = { "label", M.label(el, info) }
    end
    if caption_str then
      opts[#opts + 1] = { "caption", caption_str }
      opts[#opts + 1] = { "captionpos", above and "t" or "b" }
    end
    if not has("numbers") then
      if not num_start then
        opts[#opts + 1] = { "numbers", "none" }
      else
        opts[#opts + 1] = { "firstnumber", tostring(num_start + 1) }
        opts[#opts + 1] = { "numbers", "left" }
      end
    end
    return fmt(
      "\\begin{lstlisting}[%s]\n%s\\end{lstlisting}",
      make_option_string(opts) .. (attributes.options and ("," .. attributes.options) or ""),
      code_with_refs(el, retain)
    )
  end
end

T["statistics-cookie"] = function(el)
  return (el.value:gsub("%%", "\\%%"))
end

T.subscript = function(_, contents)
  return fmt("\\textsubscript{%s}", contents or "")
end

T.superscript = function(_, contents)
  return fmt("\\textsuperscript{%s}", contents or "")
end

local function align_string(tbl, info, math)
  local a = ox.read_attribute("attr_latex", tbl, "align")
  if a then
    return a
  end
  local row
  for _, r in ipairs(tbl.contents) do
    if r.row_type == "standard" and not info.ignore[r] then
      row = r
      break
    end
  end
  if not row then
    return ""
  end
  local align = {}
  for _, cell in ipairs(row.contents) do
    if not info.ignore[cell] then
      local borders = ox.table_cell_borders(cell, info)
      if borders.left and #align == 0 then
        align[#align + 1] = "|"
      end
      if math then
        align[#align + 1] = "c"
      else
        align[#align + 1] = ({ left = "l", right = "r", center = "c" })[ox.table_cell_alignment(cell, info)]
      end
      if borders.right then
        align[#align + 1] = "|"
      end
    end
  end
  return table.concat(align)
end

local function decorate_table(tbl_str, attr, caption, above, info)
  local float = attr.float
  local env
  if not float and vim.tbl_contains(attr._keys, "float") then
    env = nil
  elseif float == "sidewaystable" or float == "sideways" then
    env = "sidewaystable"
  elseif float == "multicolumn" then
    env = "table*"
  elseif float == "t" then
    env = "table"
  elseif float then
    env = float
  elseif nw(caption) then
    env = "table"
  end
  local placement = attr.placement or fmt("[%s]", info.latex_default_figure_position)
  local center
  if vim.tbl_contains(attr._keys, "center") then
    center = attr.center
  else
    center = info.latex_tables_centered
  end
  local fontsize = attr.font and (attr.font .. "\n") or nil
  local pre, post
  if env then
    pre = fmt("\\begin{%s}%s\n", env, placement) .. (above and caption or "") .. (center and "\\centering\n" or "") .. (fontsize or "")
    post = (above and "" or ("\n" .. caption)) .. fmt("\n\\end{%s}", env)
  elseif caption and caption ~= "" then
    pre = (center and "\\begin{center}\n" or "")
      .. (above and caption or "")
      .. ((fontsize and center) and fontsize or (fontsize and ("{" .. fontsize) or ""))
    post = (above and "" or ("\n" .. caption)) .. (center and "\n\\end{center}" or "") .. ((fontsize and not center) and "}" or "")
  elseif center then
    pre = "\\begin{center}\n" .. (fontsize or "")
    post = "\n\\end{center}"
  elseif fontsize then
    pre = "{" .. fontsize
    post = "}"
  else
    pre, post = "", ""
  end
  return pre .. tbl_str .. post
end

local function org_table(tbl, contents, info)
  local attr = ox.read_attribute("attr_latex", tbl)
  local alignment = align_string(tbl, info)
  local opt = attr.options
  local env = attr.environment or info.latex_default_table_environment
  local width = ""
  if attr.width then
    if env == "tabular" or env == "longtable" then
      width = ""
    elseif env == "tabu" or env == "longtabu" then
      width = fmt(attr.spread and " spread %s " or " to %s ", attr.width)
    else
      width = fmt("{%s}", attr.width)
    end
  end
  local caption = M.caption_label_string(tbl, info)
  local above = caption_above_p(tbl, info)
  if env == "longtable" or env == "longtabu" then
    local fontsize = attr.font and (attr.font .. "\n") or nil
    return (fontsize and ("{" .. fontsize) or "")
      .. fmt("\\begin{%s}%s{%s}\n", env, width, alignment)
      .. ((above and nw(caption)) and (caption .. "\\\\\n") or "")
      .. contents
      .. (((not above) and nw(caption)) and (caption .. "\\\\\n") or "")
      .. fmt("\\end{%s}", env)
      .. (fontsize and "}" or "")
  end
  local output = fmt("\\begin{%s}%s%s{%s}\n%s\\end{%s}", env, opt and fmt("[%s]", opt) or "", width, alignment, contents, env)
  return decorate_table(output, attr, caption, above, info)
end

local function math_table(tbl, info)
  local attr = ox.read_attribute("attr_latex", tbl)
  local env = attr.environment or info.latex_default_table_environment
  local macros = { bordermatrix = "\\cr", qbordermatrix = "\\cr", kbordermatrix = "\\\\" }
  local rows = {}
  for _, row in ipairs(tbl.contents) do
    if not info.ignore[row] then
      if row.row_type == "rule" then
        rows[#rows + 1] = "\\hline"
      else
        local cells = {}
        for _, cell in ipairs(row.contents) do
          if not info.ignore[cell] then
            cells[#cells + 1] = element.interpret(cell.contents)
          end
        end
        rows[#rows + 1] = table.concat(cells, "&") .. (macros[env] or "\\\\") .. "\n"
      end
    end
  end
  local contents = table.concat(rows)
  local body
  if env == "array" or env == "tabular" then
    body = fmt("\\begin{%s}{%s}\n%s\\end{%s}", env, align_string(tbl, info, true), contents, env)
  elseif macros[env] then
    body = fmt("\\%s%s{\n%s}", env, attr["math-arguments"] or "", contents)
  else
    body = fmt("\\begin{%s}\n%s\\end{%s}", env, contents, env)
  end
  return (attr["math-prefix"] or "") .. body .. (attr["math-suffix"] or "")
end

T.table = function(el, contents, info)
  if el.table_type == "table.el" then
    local attr = ox.read_attribute("attr_latex", el)
    local out = "\\begin{verbatim}\n" .. el.value .. "\\end{verbatim}"
    return decorate_table(out, attr, M.caption_label_string(el, info), caption_above_p(el, info), info)
  end
  local mode = ox.read_attribute("attr_latex", el, "mode") or info.latex_default_table_mode
  if mode == "verbatim" then
    local rows = {}
    for _, r in ipairs(el.contents) do
      if r.row_type == "rule" then
        rows[#rows + 1] = "|-"
      else
        local cells = {}
        for _, c in ipairs(r.contents) do
          cells[#cells + 1] = " " .. element.interpret(c.contents) .. " |"
        end
        rows[#rows + 1] = "|" .. table.concat(cells)
      end
    end
    return fmt("\\begin{verbatim}\n%s\n\\end{verbatim}", require("org.export.org").align_table_lines(rows))
  elseif mode == "math" or mode == "inline-math" then
    return math_table(el, info)
  elseif mode == "tabbing" then
    local attr_align = ox.read_attribute("attr_latex", el, "align")
    local align = attr_align
    if not align then
      local count = 0
      for _, r in ipairs(el.contents) do
        if r.row_type == "standard" then
          count = #r.contents
          break
        end
      end
      local sep = fmt("\\hspace{%s\\textwidth} \\= ", tostring((1.0 / count) - 0.01))
      align = string.rep(sep, count) .. "\\kill"
    end
    return fmt("\\begin{%s}\n%s\n%s\\end{%s}", "tabbing", align, contents or "", "tabbing")
  end
  return org_table(el, contents or "", info) .. delayed_footnotes(el, info)
end

T["table-cell"] = function(el, contents, info)
  local mode = ox.read_attribute("attr_latex", element.lineage(el, "table"), "mode")
  local sci = info.latex_table_scientific_notation
  local out = contents or ""
  if contents and sci then
    local m, e = contents:match("^([-+]?%d[%d.]*)[eE]([-+]?%d+)$")
    if m then
      out = fmt(sci, m, e)
    end
  end
  if ox.get_next_element(el, info) then
    out = out .. (mode == "tabbing" and " \\> " or " & ")
  end
  return out
end

T["table-row"] = function(el, contents, info)
  local tbl = el.parent
  local attr = ox.read_attribute("attr_latex", tbl)
  local booktabs
  if vim.tbl_contains(attr._keys, "booktabs") then
    booktabs = attr.booktabs
  else
    booktabs = info.latex_tables_booktabs
  end
  local env = attr.environment or info.latex_default_table_environment
  local longtable = env == "longtable" or env == "longtabu"
  if el.row_type == "rule" then
    if not booktabs then
      return "\\hline"
    elseif not ox.get_previous_element(el, info) then
      return "\\toprule"
    elseif not ox.get_next_element(el, info) then
      return "\\bottomrule"
    elseif longtable and ox.table_row_ends_header_p(ox.get_previous_element(el, info), info) then
      return ""
    end
    return "\\midrule"
  end
  info.latex_table_head_cache = info.latex_table_head_cache or {}
  if ox.table_row_in_header_p(el, info) then
    local cache = info.latex_table_head_cache
    if cache[tbl] then
      cache[tbl] = cache[tbl] .. "\\\\\n" .. (contents or "")
    else
      cache[tbl] = contents or ""
    end
  end
  local s = ((booktabs and not ox.get_previous_element(el, info)) and "\\toprule\n" or "") .. (contents or "") .. "\\\\\n"
  if longtable and ox.table_row_ends_header_p(el, info) then
    local _, columns = ox.table_dimensions(element.lineage(el, "table"), info)
    s = s
      .. fmt(
        "%s\n\\endfirsthead\n\\multicolumn{%d}{l}{%s} \\\\\n%s\n%s \\\\\n\n%s\n\\endhead\n%s\\multicolumn{%d}{r}{%s} \\\\\n\\endfoot\n\\endlastfoot",
        booktabs and "\\midrule" or "\\hline",
        columns,
        translate("Continued from previous page", info),
        (not ox.table_row_starts_header_p(el, info)) and "" or (booktabs and "\\toprule\n" or "\\hline\n"),
        info.latex_table_head_cache[tbl] or "",
        booktabs and "\\midrule" or "\\hline",
        booktabs and "\\midrule" or "\\hline",
        columns,
        translate("Continued on next page", info)
      )
  elseif booktabs and not ox.get_next_element(el, info) then
    s = s .. "\\bottomrule"
  end
  return s
end

T.target = function(el, _, info)
  return fmt("\\label{%s}", M.label(el, info))
end

T.timestamp = function(el, _, info)
  local value = M.plain_text(ox.timestamp_translate(el), info)
  local t = el.ts_type
  local f
  if t == "active" or t == "active-range" then
    f = info.latex_active_timestamp_format
  elseif t == "inactive" or t == "inactive-range" then
    f = info.latex_inactive_timestamp_format
  else
    f = info.latex_diary_timestamp_format
  end
  return (f:gsub("%%s", function()
    return value
  end))
end

T["verse-block"] = function(el, contents, info)
  local lin = ox.read_attribute("attr_latex", el, "lines")
  local latcode = ox.read_attribute("attr_latex", el, "latexcode")
  local cent = ox.read_attribute("attr_latex", el, "center")
  local attr = (cent and "[\\versewidth]" or "") .. (lin and fmt("\n\\poemlines{%s}", lin) or "") .. (latcode and fmt("\n%s", latcode) or "")
  local lit = ox.read_attribute("attr_latex", el, "literal")
  local vw = ox.read_attribute("attr_latex", el, "versewidth")
  local vwidth = vw and fmt("\\settowidth{\\versewidth}{%s}\n", vw) or ""
  local linreset = lin and "\n\\poemlines{0}" or ""
  contents = contents or ""
  local body = lit and contents or ((contents:gsub("^[ \t\n]*", ""):gsub("[ \t\n]*$", "")) .. "\n")
  return wrap_label(el, fmt("%s\\begin{verse}%s\n%s\\end{verse}%s", vwidth, attr, body, linreset), info)
end

T.citation = function(el, _, info)
  return require("org.export.cite").export_citation(el, info, "latex")
end

T.template = template

M.transcoders = T

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

function M.options()
  local c = lcfg()
  local function v(name, default)
    if c[name] == nil then
      return default
    end
    return c[name]
  end
  return {
    { "latex_class", "LATEX_CLASS", nil, v("default_class", "article"), "t" },
    { "latex_class_options", "LATEX_CLASS_OPTIONS", nil, nil, "t" },
    { "latex_header", "LATEX_HEADER", nil, nil, "newline" },
    { "latex_header_extra", "LATEX_HEADER_EXTRA", nil, nil, "newline" },
    { "latex_class_pre", "LATEX_CLASS_PRE", nil, nil, "newline" },
    { "description_latex", "DESCRIPTION", nil, nil, "parse" },
    { "keywords_latex", "KEYWORDS", nil, nil, "parse" },
    { "subtitle", "SUBTITLE", nil, nil, "parse" },
    { "latex_active_timestamp_format", nil, nil, v("active_timestamp_format", "\\textit{%s}") },
    { "latex_caption_above", nil, nil, v("caption_above", { "table" }) },
    { "latex_classes", nil, nil, v("classes", data.classes) },
    { "latex_default_figure_position", nil, nil, v("default_figure_position", "htbp") },
    { "latex_default_table_environment", nil, nil, v("default_table_environment", "tabular") },
    { "latex_default_quote_environment", nil, nil, v("default_quote_environment", "quote") },
    { "latex_default_table_mode", nil, nil, v("default_table_mode", "table") },
    { "latex_default_footnote_command", "LATEX_FOOTNOTE_COMMAND", nil, v("default_footnote_command", "\\footnote{%s%s}") },
    { "latex_diary_timestamp_format", nil, nil, v("diary_timestamp_format", "\\textit{%s}") },
    { "latex_footnote_defined_format", nil, nil, v("footnote_defined_format", "\\textsuperscript{\\ref{%s}}") },
    { "latex_footnote_separator", nil, nil, v("footnote_separator", "\\textsuperscript{,}\\,") },
    { "latex_hyperref_template", nil, nil, v("hyperref_template", data.hyperref_template), "t" },
    { "latex_image_default_scale", nil, nil, v("image_default_scale", "") },
    { "latex_image_default_height", nil, nil, v("image_default_height", "") },
    { "latex_image_default_option", nil, nil, v("image_default_option", "") },
    { "latex_image_default_width", nil, nil, v("image_default_width", ".9\\linewidth") },
    { "latex_images_centered", nil, nil, v("images_centered", true) },
    { "latex_inactive_timestamp_format", nil, nil, v("inactive_timestamp_format", "\\textit{%s}") },
    { "latex_inline_image_rules", nil, nil, v("inline_image_rules", M.inline_image_rules) },
    { "latex_link_with_unknown_path_format", nil, nil, v("link_with_unknown_path_format", "\\texttt{%s}") },
    { "latex_src_block_backend", nil, nil, v("src_block_backend", "verbatim") },
    { "latex_listings_langs", nil, nil, v("listings_langs", data.listings_langs) },
    { "latex_listings_options", nil, nil, v("listings_options", {}) },
    { "latex_listings_src_omit_language", nil, nil, v("listings_src_omit_language", false) },
    { "latex_minted_langs", nil, nil, v("minted_langs", data.minted_langs) },
    { "latex_minted_options", nil, nil, v("minted_options", {}) },
    { "latex_prefer_user_labels", nil, nil, v("prefer_user_labels", false) },
    { "latex_reference_command", nil, nil, v("reference_command", "\\ref{%s}") },
    { "latex_subtitle_format", nil, nil, v("subtitle_format", "\\\\\\medskip\n\\large %s") },
    { "latex_subtitle_separate", nil, nil, v("subtitle_separate", false) },
    { "latex_table_scientific_notation", nil, nil, v("table_scientific_notation", nil) },
    { "latex_tables_booktabs", nil, nil, v("tables_booktabs", false) },
    { "latex_tables_centered", nil, nil, v("tables_centered", true) },
    { "latex_text_markup_alist", nil, nil, v("text_markup_alist", {
      bold = "\\textbf{%s}",
      code = "protectedtexttt",
      italic = "\\emph{%s}",
      ["strike-through"] = "\\sout{%s}",
      underline = "\\uline{%s}",
      verbatim = "protectedtexttt",
    }) },
    { "latex_title_command", nil, nil, v("title_command", "\\maketitle") },
    { "latex_toc_command", nil, nil, v("toc_command", "\\tableofcontents\n\n") },
    { "latex_toc_include_unnumbered", nil, nil, v("toc_include_unnumbered", false) },
    { "latex_compiler", "LATEX_COMPILER", nil, v("compiler", "pdflatex") },
    { "latex_use_sans", nil, "latex-use-sans", v("use_sans", false) },
    { "latex_default_packages", nil, nil, v("default_packages", data.default_packages) },
    { "latex_packages", nil, nil, v("packages", {}) },
    { "date", "DATE", nil, "\\today", "parse" },
  }
end

local function image_filter(tree, _, info)
  return ox.insert_image_links(tree, info, info.latex_inline_image_rules)
end

local function clean_line_breaks(s)
  -- \end{...} \\ or a lone \\ at line start is invalid
  local out = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do
    local l = line:gsub("(\\end{[%w%*]+})[ \t]*\\\\[ \t]*$", "%1")
    if l:match("^[ \t]*\\\\[ \t]*$") then
      l = ""
    end
    out[#out + 1] = l
  end
  local r = table.concat(out, "\n")
  if not s:match("\n$") then
    r = r:sub(1, -2)
  end
  return r
end

M.backend = ox.define_backend("latex", {
  transcoders = T,
  options = M.options,
  filters = {
    options = {
      function(info)
        for _, prop in ipairs({ "author", "date", "title" }) do
          if type(info[prop]) == "table" then
            M.wrap_math_block(info[prop], info)
          end
        end
        return info
      end,
    },
    paragraph = {
      function(s)
        return clean_line_breaks(s)
      end,
    },
    ["verse-block"] = {
      function(s)
        return clean_line_breaks(s)
      end,
    },
    ["parse-tree"] = {
      function(tree, _, info)
        return M.wrap_math_block(tree, info)
      end,
      function(tree, _, info)
        return M.wrap_matrices(tree, info)
      end,
      image_filter,
    },
  },
})

---------------------------------------------------------------------------
-- PDF compilation (org-latex-compile)
---------------------------------------------------------------------------

--- Commands used to compile (org-latex-pdf-process).
function M.pdf_process()
  local p = lcfg().pdf_process
  if p then
    return p
  end
  if vim.fn.executable("latexmk") == 1 and vim.fn.executable("perl") == 1 then
    return { "latexmk -f -pdf -%latex -interaction=nonstopmode -output-directory=%o %f" }
  end
  return {
    "%latex -interaction nonstopmode -output-directory %o %f",
    "%latex -interaction nonstopmode -output-directory %o %f",
    "%latex -interaction nonstopmode -output-directory %o %f",
  }
end

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- Compile `texfile` to PDF. With `on_done`, run asynchronously and call
--- on_done(pdf|nil, err|nil, warnings); otherwise return pdf, err.
function M.compile(texfile, on_done)
  local lines = vim.fn.readfile(texfile, "", 2)
  local compiler
  for _, l in ipairs(lines) do
    local c = l:match("^%%.*(pdflatex)") or l:match("^%%.*(xelatex)") or l:match("^%%.*(lualatex)")
    if c then
      compiler = c
    end
  end
  compiler = compiler or lcfg().compiler or "pdflatex"
  local process = M.pdf_process()
  local dir = vim.fn.fnamemodify(texfile, ":p:h")
  local base = vim.fn.fnamemodify(texfile, ":t:r")
  local out = dir .. "/" .. base .. ".pdf"
  local bib = lcfg().bib_compiler or "bibtex"
  if type(process) == "function" then
    local ok, err = pcall(process, texfile)
    local pdf = vim.fn.filereadable(out) == 1 and out or nil
    if on_done then
      on_done(pdf, not ok and tostring(err) or nil)
      return
    end
    return pdf, not ok and tostring(err) or nil
  end
  local cmds = {}
  for _, c in ipairs(process) do
    local s = c:gsub("%%latex", shell_quote(compiler))
      :gsub("%%bibtex", shell_quote(bib))
      :gsub("%%bib", shell_quote(bib))
      :gsub("%%F", shell_quote(vim.fn.fnamemodify(texfile, ":p")))
      :gsub("%%f", shell_quote(vim.fn.fnamemodify(texfile, ":t")))
      :gsub("%%b", shell_quote(base))
      :gsub("%%o", shell_quote(dir))
      :gsub("%%O", shell_quote(out))
    cmds[#cmds + 1] = s
  end
  local mtime_before = vim.fn.getftime(out)
  local log = {}
  local function finish()
    local produced = vim.fn.filereadable(out) == 1 and vim.fn.getftime(out) >= mtime_before
    local text = table.concat(log, "\n")
    if lcfg().remove_logfiles ~= false then
      for _, ext in ipairs(lcfg().logfiles_extensions or data.logfiles_extensions) do
        for _, f in ipairs(vim.fn.glob(dir .. "/" .. base .. ".*" .. ext, false, true)) do
          if f:match(vim.pesc(base) .. "%.?%d*%." .. vim.pesc(ext) .. "$") then
            os.remove(f)
          end
        end
        os.remove(dir .. "/" .. base .. "." .. ext)
      end
    end
    local warnings = {}
    if text:match("\n!") and not text:match("\n![^\n]*Unicode character") then
      warnings = "error"
    else
      for _, w in ipairs(data.known_warnings) do
        local re = vim.regex(w[1])
        if re:match_str(text) then
          warnings[#warnings + 1] = w[2]
        end
      end
    end
    local err
    if not produced then
      err = "PDF file " .. out .. " wasn't produced. See the compilation log."
    end
    return produced and out or nil, err, warnings, text
  end
  if not on_done then
    for _, c in ipairs(cmds) do
      local res = vim.system({ vim.o.shell, vim.o.shellcmdflag, c }, { cwd = dir, text = true }):wait(600000)
      log[#log + 1] = (res.stdout or "") .. (res.stderr or "")
    end
    local pdf, err, warnings, text = finish()
    return pdf, err, warnings, text
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

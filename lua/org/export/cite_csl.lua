---@mod org.export.cite_csl The "csl" citation processor (port of Emacs oc-csl.el)
---
--- Renders citations and bibliographies with a CSL style through the Lua
--- port of citeproc-el (`org.export.csl.*`). The default style is the
--- bundled Chicago author-date style, the default locale en-US; output is
--- HTML for HTML back-ends, LaTeX for LaTeX back-ends and Org markup
--- (exported again by the back-end) for the others.

local U = require("org.export.csl.util")
local R = require("org.export.csl.regex")

local P = {}

local function cite()
  return require("org.export.cite")
end

local function ox()
  return require("org.export.ox")
end

local function copt(name, default)
  local c = (require("org.config").opts.export or {}).cite or {}
  local v = c[name]
  if v == nil then
    return default
  end
  return v
end

local ETC_DIR = (function()
  local src = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fn.fnamemodify(src, ":p:h:h:h:h")
  return root .. "/etc/csl"
end)()
P.ETC_DIR = ETC_DIR

P.DEFAULT_LATEX_PREAMBLE = [[\usepackage{calc}
\newlength{\cslhangindent}
\setlength{\cslhangindent}{[CSL-HANGINDENT]}
\newlength{\csllabelsep}
\setlength{\csllabelsep}{[CSL-LABELSEP]}
\newlength{\csllabelwidth}
\setlength{\csllabelwidth}{[CSL-LABELWIDTH-PER-CHAR] * [CSL-MAXLABEL-CHARS]}
\newenvironment{cslbibliography}[2] % 1st arg. is hanging-indent, 2nd entry spacing.
 {% By default, paragraphs are not indented.
  \setlength{\parindent}{0pt}
  % Hanging indent is turned on when first argument is 1.
  \ifodd #1
  \let\oldpar\par
  \def\par{\hangindent=\cslhangindent\oldpar}
  \fi
  % Set entry spacing based on the second argument.
  \setlength{\parskip}{\parskip +  #2\baselineskip}
 }%
 {}
\newcommand{\cslblock}[1]{#1\hfill\break}
\newcommand{\cslleftmargin}[1]{\parbox[t]{\csllabelsep + \csllabelwidth}{#1}}
\newcommand{\cslrightinline}[1]
  {\parbox[t]{\linewidth - \csllabelsep - \csllabelwidth}{#1}\break}
\newcommand{\cslindent}[1]{\hspace{\cslhangindent}#1}
\newcommand{\cslbibitem}[2]
  {\leavevmode\vadjust pre{\hypertarget{citeproc_bib_item_#1}{}}#2}
\makeatletter
\newcommand{\cslcitation}[2]
 {\protect\hyper@linkstart{cite}{citeproc_bib_item_#1}#2\hyper@linkend}
\makeatother]]

local LABELS = {
  { "bk.", "book" },
  { "bks.", "book" },
  { "book", "book" },
  { "chap.", "chapter" },
  { "chaps.", "chapter" },
  { "chapter", "chapter" },
  { "col.", "column" },
  { "cols.", "column" },
  { "column", "column" },
  { "figure", "figure" },
  { "fig.", "figure" },
  { "figs.", "figure" },
  { "folio", "folio" },
  { "fol.", "folio" },
  { "fols.", "folio" },
  { "number", "number" },
  { "no.", "number" },
  { "nos.", "number" },
  { "line", "line" },
  { "l.", "line" },
  { "ll.", "line" },
  { "note", "note" },
  { "n.", "note" },
  { "nn.", "note" },
  { "opus", "opus" },
  { "op.", "opus" },
  { "opp.", "opus" },
  { "page", "page" },
  { "p", "page" },
  { "p.", "page" },
  { "pp.", "page" },
  { "paragraph", "paragraph" },
  { "para.", "paragraph" },
  { "paras.", "paragraph" },
  { "\\P", "paragraph" },
  { "¶", "paragraph" },
  { "\\P\\P", "paragraph" },
  { "¶¶", "paragraph" },
  { "part", "part" },
  { "pt.", "part" },
  { "pts.", "part" },
  { "§", "section" },
  { "\\S", "section" },
  { "§§", "section" },
  { "\\S\\S", "section" },
  { "section", "section" },
  { "sec.", "section" },
  { "secs.", "section" },
  { "sub verbo", "sub verbo" },
  { "s.v.", "sub verbo" },
  { "s.vv.", "sub verbo" },
  { "verse", "verse" },
  { "v.", "verse" },
  { "vv.", "verse" },
  { "volume", "volume" },
  { "vol.", "volume" },
  { "vols.", "volume" },
}

local LABEL_RE = (function()
  local alts = {}
  for _, l in ipairs(LABELS) do
    alts[#alts + 1] = l[1]
  end
  -- longest first, like the alternatives regexp-opt builds
  table.sort(alts, function(a, b)
    local la, lb = U.len(a), U.len(b)
    if la ~= lb then
      return la > lb
    end
    return a < b
  end)
  local q = {}
  for i, a in ipairs(alts) do
    q[i] = a:gsub("[%.%*%+%?%^%$%[%]\\]", "\\%0")
  end
  return "\\(?:^\\|[[:space:]]\\)\\("
    .. table.concat(q, "\\|")
    .. "\\)[[:digit:]]*\\(?:\\>\\|$\\|[[:space:]]\\|"
    .. U.char(0xA0)
    .. "\\)"
end)()

local function label_of(s)
  for _, l in ipairs(LABELS) do
    if l[1] == s then
      return l[2]
    end
  end
end

--- CSL cite styles (:cite-styles)
P.cite_styles = {
  {
    { "author", "a" },
    { "bare", "b" },
    { "caps", "c" },
    { "full", "f" },
    { "bare-caps", "bc" },
    { "caps-full", "cf" },
    { "bare-caps-full", "bcf" },
  },
  { { "noauthor", "na" }, { "bare", "b" }, { "caps", "c" }, { "bare-caps", "bc" } },
  { { "year", "y" }, { "bare", "b" } },
  { { "text", "t" }, { "caps", "c" }, { "full", "f" }, { "caps-full", "cf" } },
  { { "nil" }, { "bare", "b" }, { "caps", "c" }, { "bare-caps", "bc" } },
  { { "nocite", "n" } },
  { { "title", "ti" }, { "bare", "b" } },
  { { "bibentry", "b" }, { "bare", "b" } },
  { { "locators", "l" }, { "bare", "b" } },
}

---------------------------------------------------------------------------
-- Processor state
---------------------------------------------------------------------------

local function output_format(info)
  local o = ox()
  if o.derived_backend_p(info.back_end, "html") then
    return "html"
  elseif o.derived_backend_p(info.back_end, "latex") then
    return "org-latex"
  end
  return "org"
end
P.output_format = output_format

--- org-cite-csl--style-file
local function style_file(info)
  local style = cite().bibliography_style(info)
  if not style then
    return ETC_DIR .. "/chicago-author-date.csl"
  end
  local expanded = require("org.utils").expand_vars(style)
  if expanded:match("^/") or expanded:match("^%a:[/\\]") then
    return expanded
  end
  local dir = info.input_file and vim.fn.fnamemodify(info.input_file, ":p:h") or vim.fn.getcwd()
  local local_file = dir .. "/" .. style
  if vim.uv.fs_stat(local_file) then
    return vim.fs.normalize(local_file)
  end
  local styles_dir = copt("csl_styles_dir", nil)
  if styles_dir then
    local f = vim.fn.expand(styles_dir) .. "/" .. style
    if vim.uv.fs_stat(f) then
      return vim.fs.normalize(f)
    end
  end
  error(string.format('CSL style file not found: "%s"', style), 0)
end

--- org-cite-csl--locale-getter
local function locale_getter()
  local S = require("org.export.csl.style")
  local dir = copt("csl_locales_dir", nil)
  return function(loc)
    if dir then
      local ok, res = pcall(S.locale_getter_from_dir(vim.fn.expand(dir)), loc)
      if ok and res then
        return res
      end
    end
    return S.locale_getter_from_dir(ETC_DIR)(loc)
  end
end

--- org-cite-csl--processor
local function processor(info)
  if info.cite_citeproc_processor then
    return info.cite_citeproc_processor
  end
  local B = require("org.export.csl.bib")
  local proc = require("org.export.csl.proc")
  local files = {}
  for _, f in ipairs(info.bibliography or {}) do
    files[#files + 1] = cite().bibliography_path(f, info)
  end
  local getter = B.itemgetter_from_any(files, not copt("csl_bibtex_titles_to_sentence_case", true))
  local p = proc.create(style_file(info), getter, locale_getter(), info.language or "en_US")
  info.cite_citeproc_processor = p
  return p
end

local function note_style_p(info)
  return require("org.export.csl.style").cite_note(processor(info).style)
end

local function superscript_p(info)
  return require("org.export.csl.style").cite_superscript_p(processor(info).style)
end

local function nocite_p(citation, info)
  local name = cite().citation_style(citation, info)[1]
  return name == "nocite" or name == "n"
end

--- org-cite-csl--create-structure-params
local function structure_params(citation, info)
  local st = cite().citation_style(citation, info)
  local name, v = st[1], st[2]
  local function is(x, ...)
    for _, y in ipairs({ ... }) do
      if x == y then
        return true
      end
    end
    return false
  end
  if is(name, "author", "a") then
    local t = { mode = "author-only" }
    if is(v, "bare", "b") then
      t.suppress_affixes = true
    elseif is(v, "caps", "c") then
      t.capitalize_first = true
    elseif is(v, "full", "f") then
      t.ignore_et_al = true
    elseif is(v, "bare-caps", "bc") then
      t.suppress_affixes, t.capitalize_first = true, true
    elseif is(v, "bare-full", "bf") then
      t.suppress_affixes, t.ignore_et_al = true, true
    elseif is(v, "caps-full", "cf") then
      t.capitalize_first, t.ignore_et_al = true, true
    elseif is(v, "bare-caps-full", "bcf") then
      t.suppress_affixes, t.capitalize_first, t.ignore_et_al = true, true, true
    end
    return t
  elseif is(name, "noauthor", "na") then
    local t = { mode = "suppress-author" }
    if is(v, "bare", "b") then
      t.suppress_affixes = true
    elseif is(v, "caps", "c") then
      t.capitalize_first = true
    elseif is(v, "bare-caps", "bc") then
      t.suppress_affixes, t.capitalize_first = true, true
    end
    return t
  elseif is(name, "year", "y") then
    return { mode = "year-only", suppress_affixes = is(v, "bare", "b") or nil }
  elseif is(name, "bibentry", "b") then
    return { mode = "bib-entry", suppress_affixes = is(v, "bare", "b") or nil }
  elseif is(name, "locators", "l") then
    return { mode = "locator-only", suppress_affixes = is(v, "bare", "b") or nil }
  elseif is(name, "title", "ti") then
    return { mode = "title-only", suppress_affixes = is(v, "bare", "b") or nil }
  elseif is(name, "text", "t") then
    local t = { mode = "textual" }
    if is(v, "caps", "c") then
      t.capitalize_first = true
    elseif is(v, "full", "f") then
      t.ignore_et_al = true
    elseif is(v, "caps-full", "cf") then
      t.ignore_et_al, t.capitalize_first = true, true
    end
    return t
  end
  local t = {}
  if is(v, "caps", "c") then
    t.capitalize_first = true
  elseif is(v, "bare", "b") then
    t.suppress_affixes = true
  elseif is(v, "bare-caps", "bc") then
    t.suppress_affixes, t.capitalize_first = true, true
  end
  return t
end

local function has_print_bibliography(info)
  local element = require("org.export.element")
  local found = false
  element.map(info.parse_tree, "keyword", function(k)
    if k.key == "PRINT_BIBLIOGRAPHY" then
      found = true
    end
  end, { ignore = info.ignore })
  return found
end

--- org-cite-csl--no-citelinks-p
local function no_citelinks_p(info)
  if not copt("csl_link_cites", true) then
    return true
  end
  local backends = copt("csl_no_citelinks_backends", { "ascii" })
  if #backends > 0 and ox().derived_backend_p(info.back_end, unpack(backends)) then
    return true
  end
  return not has_print_bibliography(info)
end

local function interpret(data)
  if data == nil then
    return ""
  end
  return require("org.export.element").interpret(data)
end

local function parse_objects(s, affix, info)
  local element = require("org.export.element")
  local R_ = element.RESTRICTIONS[affix and "citation-reference" or "paragraph"]
  return info.parser:parse_objects(s, R_, nil)
end

--- org-cite-csl--parse-reference
local function parse_reference(reference, info)
  local label, location_start, locator_start, location, locator, prefix, suffix
  local text = interpret(reference.suffix)
  local cps = U.codepoints(text)
  local b, md = R.search(LABEL_RE, cps, 0)
  local suffix_set = false
  if b then
    location_start = b
    label = label_of(md:str(1))
    local p = md:e(1)
    while cps[p + 1] and (R.test("[[:space:]]", U.char(cps[p + 1])) or cps[p + 1] == 0xA0) do
      p = p + 1
    end
    locator_start = p
  else
    local d = R.search("[[:digit:]]", cps, 0)
    if d then
      location_start = d
      label = "page"
      locator_start = d
    else
      suffix = reference.suffix
      suffix_set = true
    end
  end
  if not suffix_set then
    -- the last comma or digit after the location start
    local found_pos, is_digit
    for k = #cps, location_start + 1, -1 do
      local c = cps[k]
      if c == 44 then
        found_pos, is_digit = k - 1, false
        break
      elseif c >= 48 and c <= 57 then
        found_pos, is_digit = k - 1, true
        break
      end
    end
    if found_pos then
      local point = is_digit and found_pos + 1 or found_pos
      location = U.from_codepoints(cps, location_start + 1, point)
      locator = U.trim(U.from_codepoints(cps, locator_start + 1, point))
      suffix = parse_objects(U.from_codepoints(cps, found_pos + 2, #cps), true, info)
    end
  end
  prefix = cite().concat(
    reference.prefix,
    location_start and parse_objects(U.from_codepoints(cps, 1, location_start), true, info) or nil
  )
  local fmt = output_format(info)
  local function export(data)
    if data == nil or (type(data) == "table" and data.type == nil and #data == 0) then
      return nil
    end
    local s
    if fmt == "org" then
      s = interpret(data)
    else
      s = ox().data(data, info)
    end
    s = U.trim(s or "")
    if s == "" then
      return nil
    end
    return s
  end
  return {
    { "id", reference.key },
    { "prefix", export(prefix) },
    { "suffix", export(suffix) },
    { "locator", locator },
    { "label", label },
    { "location", location },
  }
end

--- org-cite-csl--create-structure
local function create_structure(citation, info)
  local C = cite()
  local cites = {}
  for i, r in ipairs(C.get_references(citation)) do
    cites[i] = parse_reference(r, info)
  end
  local footnote = C.inside_footnote_p(citation)
  if citation.prefix and cites[1] then
    local p = U.assoc(cites[1], "prefix")
    p[2] = interpret(citation.prefix) .. " " .. (p[2] or "")
  end
  if citation.suffix and cites[#cites] then
    local p = U.assoc(cites[#cites], "suffix")
    p[2] = (p[2] or "") .. " " .. interpret(citation.suffix)
  end
  if not footnote and note_style_p(info) then
    C.adjust_note(citation, info)
    footnote = C.wrap_citation(citation, info)
  end
  if superscript_p(info) then
    C.set_previous_post_blank(citation, 0, info)
  end
  local params = structure_params(citation, info)
  return require("org.export.csl.proc").citation_create({
    note_index = footnote and ox().get_footnote_number(footnote, info) or nil,
    cites = cites,
    mode = params.mode,
    suppress_affixes = params.suppress_affixes,
    capitalize_first = params.capitalize_first,
    ignore_et_al = params.ignore_et_al,
  })
end

--- org-cite-csl--bibliography-filter
local function bibliography_filter(props)
  local result = {}
  local i = 1
  while props and i <= #props do
    local k = props[i]
    if type(k) == "table" and k.keyword then
      local value = props[i + 1]
      if type(value) ~= "string" then
        value = nil
      else
        i = i + 1
      end
      local key = k.keyword:sub(2)
      if value then
        if key == "keyword" or key == "notkeyword" or key == "nottype" or key == "notcsltype" or key == "filter" then
          for _, v in ipairs(R.split(value, ",", false)) do
            table.insert(result, 1, { key, v })
          end
        elseif key == "type" or key == "csltype" then
          if value:find(",", 1, true) then
            error(
              string.format('The "%s" print_bibliography option does not support comma-separated values', k.keyword),
              0
            )
          end
          table.insert(result, 1, { key, value })
        end
      end
    end
    i = i + 1
  end
  return result
end

--- org-cite-csl--rendered-bibliographies: { outputs = { {props, output}... }, params }
local function rendered_bibliographies(info)
  if info.cite_citeproc_rendered_bibliographies then
    return info.cite_citeproc_rendered_bibliographies
  end
  local C = cite()
  local element = require("org.export.element")
  local plists, filters = {}, {}
  element.map(info.parse_tree, "keyword", function(k)
    if k.key == "PRINT_BIBLIOGRAPHY" then
      local props = C.parse_as_plist(k.value) or {}
      plists[#plists + 1] = props
      filters[#filters + 1] = bibliography_filter(props)
    end
  end, { ignore = info.ignore })
  local proc = require("org.export.csl.proc")
  local p = processor(info)
  proc.add_subbib_filters(filters, p)
  local bibs, params = proc.render_bib(p, output_format(info), no_citelinks_p(info) or nil)
  local outputs = {}
  if type(bibs) == "table" then
    for i, props in ipairs(plists) do
      if bibs[i] ~= nil then
        outputs[#outputs + 1] = { props, bibs[i] }
      end
    end
  end
  local result = { outputs = outputs, params = params or {} }
  info.cite_citeproc_rendered_bibliographies = result
  return result
end

--- org-cite-csl--rendered-citations: map citation -> output
local function rendered_citations(info)
  if info.cite_citeproc_rendered_citations then
    return info.cite_citeproc_rendered_citations
  end
  local C = cite()
  local proc = require("org.export.csl.proc")
  local citations = C.list_citations(info)
  local p = processor(info)
  local normal, nocite_ids = {}, {}
  for _, c in ipairs(citations) do
    if nocite_p(c, info) then
      nocite_ids = U.concat(C.get_references(c, true), nocite_ids)
    else
      normal[#normal + 1] = c
    end
  end
  local structures = {}
  for i, c in ipairs(normal) do
    structures[i] = create_structure(c, info)
  end
  proc.append_citations(structures, p)
  if #nocite_ids > 0 then
    proc.add_uncited(nocite_ids, p)
  end
  rendered_bibliographies(info)
  local rendered = proc.render_citations(p, output_format(info), no_citelinks_p(info) or nil)
  local result = {}
  local k = 1
  for _, c in ipairs(citations) do
    if nocite_p(c, info) then
      result[c] = ""
    else
      result[c] = rendered[k]
      k = k + 1
    end
  end
  info.cite_citeproc_rendered_citations = result
  return result
end

local function aget(al, k)
  return U.aget(al, k)
end

--- org-cite-csl--generate-latex-preamble
local function latex_preamble(info)
  local params = rendered_bibliographies(info).params
  local max = aget(params, "max-offset") or 0
  local result = copt("csl_latex_preamble", nil) or P.DEFAULT_LATEX_PREAMBLE
  local function sub(ph, rep)
    local a, b = result:find(ph, 1, true)
    if a then
      result = result:sub(1, a - 1) .. rep .. result:sub(b + 1)
    end
  end
  sub("[CSL-HANGINDENT]", copt("csl_latex_hanging_indent", "1.5em"))
  sub("[CSL-LABELSEP]", copt("csl_latex_label_separator", "0.6em"))
  sub("[CSL-LABELWIDTH-PER-CHAR]", copt("csl_latex_label_width_per_char", "0.45em"))
  sub("[CSL-MAXLABEL-CHARS]", U.num_str(max))
  return result
end

--- org-cite-csl--generate-html-head
local function html_head(info)
  local params = rendered_bibliographies(info).params
  local parts = {}
  if aget(params, "second-field-align") then
    local max = aget(params, "max-offset") or 0
    local w = copt("csl_html_label_width_per_char", "0.6em")
    local num = w:match("^[ \t]*([-+]?%d*%.?%d+)") or "0"
    local unit = w:sub((w:find(num, 1, true) or 1) + #num)
    parts[#parts + 1] = string.format(
      "<style>.csl-left-margin{float: left; padding-right: 0em;}\n .csl-right-inline{margin: 0 0 0 %d%s;}</style>",
      math.floor(max * (tonumber(num) or 0)),
      unit
    )
  end
  if aget(params, "hanging-indent") then
    local h = copt("csl_html_hanging_indent", "1.5em")
    parts[#parts + 1] = string.format("<style>.csl-entry{text-indent: -%s; margin-left: %s;}</style>", h, h)
  end
  local s = table.concat(parts)
  return s ~= "" and s or nil
end

---------------------------------------------------------------------------
-- Export capability
---------------------------------------------------------------------------

function P.export_citation(citation, _, _, info)
  local output = rendered_citations(info)[citation]
  if output_format(info) ~= "org" then
    return output
  end
  if output == nil or output == "" then
    return nil
  end
  local data = parse_objects(output, false, info)
  if #data == 0 then
    return nil
  end
  return data
end

local function parse_elements(s, info)
  local lines = vim.split(s, "\n", { plain = true })
  local data = info.parser:parse(lines)
  local contents = data.contents or {}
  if #contents == 0 then
    return nil
  end
  if #contents == 1 and contents[1].type == "section" then
    local out = contents[1].contents or {}
    for _, c in ipairs(out) do
      c.parent = nil
    end
    return out
  end
  error("Headlines cannot replace a keyword", 0)
end

function P.export_bibliography(_, _, _, props, _, info)
  local fmt = output_format(info)
  local outputs = rendered_bibliographies(info).outputs
  local output
  for _, o in ipairs(outputs) do
    if vim.deep_equal(o[1], props or {}) then
      output = o[2]
      break
    end
  end
  if fmt == "html" then
    if not info.html_head_csl_styles_added then
      local head = html_head(info)
      if head then
        local cur = info.html_head
        if type(cur) == "function" then
          local f = cur
          info.html_head = function(i)
            return (f(i) or "") .. head
          end
        else
          info.html_head = (cur or "") .. head
        end
      end
      info.html_head_csl_styles_added = true
    end
    return output
  elseif fmt == "org-latex" then
    return output
  end
  if output == nil then
    return nil
  end
  return parse_elements(output, info)
end

function P.finalize(output, _, _, _, _, info)
  if output_format(info) ~= "org-latex" then
    return output
  end
  local b = output:find("\\begin{document}", 1, true)
  if not b then
    return output
  end
  return output:sub(1, b - 1) .. latex_preamble(info) .. output:sub(b)
end

return {
  export_citation = P.export_citation,
  export_bibliography = P.export_bibliography,
  export_finalizer = P.finalize,
  cite_styles = P.cite_styles,
  internal = P,
}

---@mod org.export.csl.style CSL styles, locales and terms
--- (port of citeproc-style.el, citeproc-locale.el and citeproc-term.el)

local U = require("org.export.csl.util")
local X = require("org.export.csl.xml")
local R = require("org.export.csl.regex")

local M = {}

local aget = U.aget

---------------------------------------------------------------------------
-- Terms
---------------------------------------------------------------------------

local TERM_FIELDS = { "name", "form", "number", "gender", "gender_form", "match" }

--- citeproc-term--compare: 1 if t1 precedes t2, -1 if it succeeds, 0 if equal.
function M.term_compare(t1, t2)
  if not t2 then
    return 1
  elseif not t1 then
    return -1
  end
  for _, f in ipairs(TERM_FIELDS) do
    local s1, s2 = t1[f] or "", t2[f] or ""
    if s1 < s2 then
      return 1
    elseif s1 > s2 then
      return -1
    end
  end
  return 0
end

local function term_list_sort(tl)
  return U.stable_sort(tl, function(x, y)
    return M.term_compare(x, y) == 1
  end)
end

--- citeproc-term-list-update: TL1 updated with TL2 (TL2 wins on ties).
function M.term_list_update(tl1, tl2)
  tl1 = term_list_sort(tl1)
  tl2 = term_list_sort(tl2)
  local result = {}
  local i, j = 1, 1
  while i <= #tl1 or j <= #tl2 do
    local t1, t2 = tl1[i], tl2[j]
    local cmp = M.term_compare(t1, t2)
    if cmp == 1 then
      table.insert(result, 1, t1)
      i = i + 1
    elseif cmp == -1 then
      table.insert(result, 1, t2)
      j = j + 1
    else
      table.insert(result, 1, t2)
      i = i + 1
      j = j + 1
    end
  end
  return result
end

local function text_of(el)
  if type(el) == "string" then
    return el
  end
  if type(el) == "table" and type(el[1]) == "string" then
    return el[1]
  end
  return nil
end

--- citeproc-term--from-xml-frag
local function term_from_xml(el)
  local attrs = el.attrs
  local term = {
    name = aget(attrs, "name"),
    form = aget(attrs, "form") or "long",
    gender = aget(attrs, "gender"),
    match = aget(attrs, "match"),
    gender_form = aget(attrs, "gender-form"),
  }
  if #el == 1 and type(el[1]) == "string" then
    term.text = el[1]
    return { term }
  end
  term.text = text_of(el[1])
  term.number = "single"
  local multi = vim.deepcopy(term)
  multi.text = text_of(el[2])
  multi.number = "multiple"
  return { term, multi }
end

local function termlist_from_xml(children)
  local out = {}
  for _, c in ipairs(children) do
    if type(c) == "table" and c.tag == "term" then
      for _, t in ipairs(term_from_xml(c)) do
        out[#out + 1] = t
      end
    end
  end
  return out
end

--- citeproc-term-text-from-terms
function M.term_text_from_terms(term, terms)
  for _, t in ipairs(terms or {}) do
    if t.name == term then
      return t.text
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Locales
---------------------------------------------------------------------------

local DEFAULT_VARIANTS = {
  af = "ZA",
  ca = "AD",
  cs = "CZ",
  cy = "GB",
  da = "DK",
  en = "US",
  el = "GR",
  et = "EE",
  fa = "IR",
  he = "IR",
  ja = "JP",
  km = "KH",
  ko = "KR",
  nb = "NO",
  nn = "NO",
  sl = "SI",
  sr = "RS",
  sv = "SE",
  uk = "UA",
  vi = "VN",
  zh = "CN",
}
local SIMPLE_LOCALES = { la = true, eu = true, ar = true }

local function extend_locale(loc)
  return loc .. "-" .. (DEFAULT_VARIANTS[loc] or U.upcase(loc))
end

local function compatible_locales(l1, l2)
  return not (l1 and l2) or U.starts_with(l2, l1) or U.starts_with(l1, l2)
end

local xml_cache = {}

--- Parse an XML file (cached by name and modification time).
function M.parse_xml_file(file)
  local st = vim.uv.fs_stat(file)
  local key = file
  local c = xml_cache[key]
  if c and st and c.mtime == st.mtime.sec and c.size == st.size then
    return vim.deepcopy(c.tree)
  end
  local fd = io.open(file, "rb")
  if not fd then
    error(string.format("Cannot read %s", file), 0)
  end
  local content = fd:read("*a")
  fd:close()
  local tree = X.remove_comments(X.parse(content))
  if st then
    xml_cache[key] = { mtime = st.mtime.sec, size = st.size, tree = tree, content = content }
  end
  return vim.deepcopy(tree), content
end

--- citeproc-locale-getter-from-dir
function M.locale_getter_from_dir(dir)
  local default_file = dir .. "/locales-en-US.xml"
  return function(loc)
    local ext = (SIMPLE_LOCALES[loc] or loc:find("-", 1, true)) and loc or extend_locale(loc)
    local file = dir .. "/locales-" .. ext .. ".xml"
    if vim.fn.filereadable(file) == 1 then
      return (M.parse_xml_file(file))
    end
    if vim.fn.filereadable(default_file) ~= 1 then
      error(string.format("The default CSL locale file %s doesn't exist or is unreadable", default_file), 0)
    end
    return (M.parse_xml_file(default_file))
  end
end

---------------------------------------------------------------------------
-- Styles
---------------------------------------------------------------------------

--- citeproc-style-parse: year-suffix usage and the parsed style.
function M.parse(style)
  local content
  if style:find("<", 1, true) then
    content = style
  else
    local _, c = M.parse_xml_file(style)
    content = c
    if not content then
      local fd = io.open(style, "rb")
      content = fd and fd:read("*a") or ""
      if fd then
        fd:close()
      end
    end
  end
  local ys = R.test('variable="year-suffix"', content)
  return ys, X.remove_comments(X.parse(content))
end

local function elements(el)
  return X.elements(el)
end

--- citeproc-lib-named-parts-to-alist
local function named_parts(el)
  local out = {}
  for _, c in ipairs(elements(el)) do
    local attrs = c.attrs
    out[#out + 1] = { aget(attrs, "name"), U.aremove(attrs, "name") }
  end
  return out
end
M.named_parts = named_parts

function M.update_locale_date(style, frag)
  local attrs = frag.attrs
  local form = aget(attrs, "form")
  local fmt = { attrs = attrs, parts = named_parts(frag) }
  if form == "text" then
    if not style.date_text then
      style.date_text = fmt
    end
  elseif not style.date_numeric then
    style.date_numeric = fmt
  end
end

--- citeproc-style--update-locale
function M.update_locale(style, frag)
  for _, c in ipairs(elements(frag)) do
    if c.tag == "style-options" then
      style.locale_opts = U.concat(style.locale_opts, c.attrs)
    elseif c.tag == "date" then
      M.update_locale_date(style, c)
    elseif c.tag == "terms" then
      local parsed = termlist_from_xml(c)
      if style.terms and #style.terms > 0 then
        style.terms = M.term_list_update(parsed, style.terms)
      else
        style.terms = parsed
      end
    end
  end
end

local function compile(tree)
  return require("org.export.csl.render").compile(tree)
end

--- citeproc-style--parse-layout-and-sort-frag
local function layout_and_sort(frag)
  local kids = elements(frag)
  local sort_p = kids[1] and kids[1].tag == "sort"
  local layout_el = kids[sort_p and 2 or 1]
  local out =
    { opts = frag.attrs, layout = layout_el and compile(layout_el), layout_attrs = layout_el and layout_el.attrs }
  if sort_p then
    out.sort = compile(kids[1])
    local orders = {}
    for _, k in ipairs(elements(kids[1])) do
      orders[#orders + 1] = aget(k.attrs, "sort") ~= "descending"
    end
    out.sort_orders = orders
  end
  return out
end

--- citeproc-create-style-from-locale
function M.create_from_locale(parsed, year_suffix, locale)
  local style = {
    opts = parsed.attrs,
    uses_ys_var = year_suffix,
    locale = locale or aget(parsed.attrs, "default-locale"),
    macros = {},
    terms = nil,
    locale_opts = {},
    bib_opts = {},
    cite_opts = {},
  }
  local locale_loaded = false
  for _, it in ipairs(elements(parsed)) do
    if it.tag == "info" then
      for _, x in ipairs(elements(it)) do
        if x.tag == "category" and x.attrs[1] and x.attrs[1][1] == "citation-format" then
          style.category = x.attrs[1][2]
          break
        end
      end
    elseif it.tag == "locale" then
      local lang = aget(it.attrs, "lang")
      if compatible_locales(lang, locale) and not locale_loaded then
        M.update_locale(style, it)
        locale_loaded = true
      end
    elseif it.tag == "citation" then
      local r = layout_and_sort(it)
      style.cite_opts = r.opts or {}
      style.cite_layout = r.layout
      style.cite_layout_attrs = r.layout_attrs or {}
      style.cite_sort = r.sort
      style.cite_sort_orders = r.sort_orders
    elseif it.tag == "bibliography" then
      local r = layout_and_sort(it)
      style.bib_opts = r.opts or {}
      style.bib_layout = r.layout
      style.bib_sort = r.sort
      style.bib_sort_orders = r.sort_orders
    elseif it.tag == "macro" then
      local name = it.attrs[1] and it.attrs[1][2]
      local el = { tag = "macro", attrs = {} }
      for _, c in ipairs(it) do
        el[#el + 1] = c
      end
      style.macros[name] = compile(el)
    end
  end
  return style
end

local OPT_DEFAULTS = {
  { "cite_opts", "near-note-distance", "5" },
  { "locale_opts", "punctuation-in-quote", "false" },
  { "locale_opts", "limit-day-ordinals-to-day-1", "false" },
  { "bib_opts", "hanging-indent", "false" },
  { "bib_opts", "line-spacing", "1" },
  { "bib_opts", "entry-spacing", "1" },
  { "opts", "initialize-with-hyphen", "true" },
  { "opts", "demote-non-dropping-particle", "display-and-sort" },
}

local function set_opt(style, slot, opt, value)
  style[slot] = U.acons(opt, value, style[slot])
end

--- citeproc-style--set-opt-defaults
function M.set_opt_defaults(style)
  for _, d in ipairs(OPT_DEFAULTS) do
    local slot, option, value = d[1], d[2], d[3]
    if not aget(style[slot], option) then
      style[slot] = U.acons(option, value, style[slot])
    end
  end
  local cite_opts = style.cite_opts
  local collapse = aget(cite_opts, "collapse")
  if collapse and collapse ~= "citation-number" then
    local layout_dl = aget(style.cite_layout_attrs, "delimiter")
    if not aget(cite_opts, "cite-group-delimiter") then
      set_opt(style, "cite_opts", "cite-group-delimiter", ", ")
    end
    if not aget(cite_opts, "after-collapse-delimiter") then
      set_opt(style, "cite_opts", "after-collapse-delimiter", layout_dl)
    end
    if
      (collapse == "year-suffix" or collapse == "year-suffix-ranged")
      and aget(cite_opts, "year-suffix-delimiter") == nil
    then
      set_opt(style, "cite_opts", "year-suffix-delimiter", layout_dl)
    end
  end
end

--- citeproc-create-style
function M.create(style_file, locale_getter, locale, force_locale)
  local ys, parsed = M.parse(style_file)
  local default_locale = aget(parsed.attrs, "default-locale")
  local preferred = force_locale and locale or (default_locale or locale or "en-US")
  local act_parsed = locale_getter(preferred)
  local act_locale = aget(act_parsed.attrs, "lang")
  local style = M.create_from_locale(parsed, ys, act_locale)
  M.update_locale(style, act_parsed)
  M.set_opt_defaults(style)
  style.locale = locale or act_locale
  return style
end

function M.cite_note(style)
  return style.category == "note"
end

function M.cite_superscript_p(style)
  return aget(style.cite_layout_attrs, "vertical-align") == "sup"
end

--- citeproc-style-global-opts
function M.global_opts(style, layout)
  if layout == "bib" then
    return U.concat(style.bib_opts, style.opts)
  end
  return U.concat(style.cite_opts, style.opts)
end

--- citeproc-style-bib-opts-to-formatting-params
function M.bib_opts_to_formatting_params(bib_opts)
  local result = {}
  local keys =
    { ["hanging-indent"] = true, ["line-spacing"] = true, ["entry-spacing"] = true, ["second-field-align"] = true }
  for _, p in ipairs(bib_opts or {}) do
    if type(p) == "table" and keys[p[1]] then
      local v = p[2]
      local val
      if v == "true" then
        val = true
      elseif v == "false" then
        val = nil
      elseif v == "flush" or v == "margin" then
        val = v
      else
        val = U.to_number(v)
      end
      result[#result + 1] = { p[1], val }
    end
  end
  if not aget(result, "second-field-align") then
    table.insert(result, 1, { "second-field-align", nil })
  end
  return result
end

return M

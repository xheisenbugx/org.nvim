---@mod org.export.csl.render CSL rendering elements
--- (port of citeproc-context.el, citeproc-generic-elements.el,
--- citeproc-choose.el, citeproc-macro.el, citeproc-name.el,
--- citeproc-date.el, citeproc-number.el, citeproc-prange.el and the
--- sort-key part of citeproc-sort.el)
---
--- A style element is compiled into a function of the rendering context.
--- Most return a typed value `{ c = rich_text, t = type }` where the type
--- is "text-only", "empty-vars" or "present-var"; `false` stands for an
--- Emacs nil value.

local U = require("org.export.csl.util")
local R = require("org.export.csl.regex")
local rt = require("org.export.csl.rt")
local S = require("org.export.csl.style")

local M = {}

local aget, acons = U.aget, U.acons

--- Emacs nil inside a list is stored as false.
local function nf(x)
  if x == nil then
    return false
  end
  return x
end

local function typed(c, t)
  if c == false then
    c = nil
  end
  return { c = c, t = t }
end
M.typed = typed

local function tcar(v)
  if type(v) == "table" and not v.splice then
    return v.c
  end
  return nil
end

local function tcdr(v)
  if type(v) == "table" and not v.splice then
    return v.t
  end
  return nil
end

---------------------------------------------------------------------------
-- Context
---------------------------------------------------------------------------

--- citeproc-context-create
function M.context_create(vars, style, mode, render_mode, no_external_links)
  return {
    vars = vars,
    macros = style.macros,
    terms = style.terms,
    date_text = style.date_text,
    date_numeric = style.date_numeric,
    opts = S.global_opts(style, mode),
    locale = style.locale,
    locale_opts = style.locale_opts,
    mode = mode,
    render_mode = render_mode,
    render_year_suffix = not style.uses_ys_var,
    no_external_links = no_external_links,
  }
end

local SHORT_LONG = { title = "title-short", ["container-title"] = "container-title-short" }

--- citeproc-var-value
function M.var_value(var, ctx, form)
  local vals = ctx.vars
  if form == "short" or (var == "title" and aget(vals, "use-short-title")) then
    local short = SHORT_LONG[var]
    local sv = short and aget(vals, short)
    if short and sv then
      return sv
    end
    return aget(vals, var)
  end
  local val = aget(vals, var)
  if val and ((var == "locator" and M.var_value("label", ctx) == "page") or var == "page") then
    local fmt = aget(ctx.opts, "page-range-format")
    local sep = S.term_text_from_terms("page-range-delimiter", ctx.terms) or "–"
    return rt.from_str(M.prange_render(val, fmt, sep))
  end
  return val
end

function M.term_get_text(term, ctx)
  return S.term_text_from_terms(term, ctx.terms)
end

local FORM_FALLBACK = { ["verb-short"] = "verb", symbol = "short", verb = "long", short = "long" }

--- citeproc-term-inflected-text
function M.term_inflected_text(term, form, number, ctx)
  local matches = {}
  for _, t in ipairs(ctx.terms or {}) do
    if t.name == term then
      matches[#matches + 1] = t
    end
  end
  if #matches == 0 then
    return nil
  end
  local match
  while not match and form do
    for _, t in ipairs(matches) do
      if t.form == form and (not t.number or t.number == number) then
        match = t
        break
      end
    end
    if not match then
      form = FORM_FALLBACK[form]
    end
  end
  return match and match.text or nil
end

function M.term_get_gender(term, ctx)
  for _, t in ipairs(ctx.terms or {}) do
    if t.name == term and t.gender and t.form == "long" then
      return t.gender
    end
  end
  return nil
end

--- citeproc-rt-quote (on a list of rich texts)
local function rt_quote(rts, ctx)
  local oq = M.term_get_text("open-quote", ctx)
  local cq = M.term_get_text("close-quote", ctx)
  local oiq = M.term_get_text("open-inner-quote", ctx)
  local ciq = M.term_get_text("close-inner-quote", ctx)
  local function q(s)
    return (s or ""):gsub("[%^%$%.%*%+%?%[%]\\]", "\\%0")
  end
  local re = string.format("\\(%s\\|%s\\|%s\\|%s\\)", q(oq), q(cq), q(oiq), q(ciq))
  local out = { oq }
  for _, r in ipairs(rt.replace_all_sim({ { oq, oiq }, { cq, ciq }, { oiq, oq }, { ciq, cq } }, re, rts)) do
    out[#out + 1] = r
  end
  out[#out + 1] = cq
  return out
end

--- citeproc-s-capitalize-first
local function capitalize_first(s)
  if U.blank(s) then
    return s
  end
  local done = false
  return U.map_words(s, function(w)
    if done then
      return nil
    end
    done = true
    if U.lowercase_p(w) then
      return U.capitalize_word(w)
    end
  end)
end
M.capitalize_first = capitalize_first

local function capitalize_all(s)
  if U.blank(s) then
    return s
  end
  return U.map_words(s, function(w)
    if U.lowercase_p(w) then
      return U.capitalize_word(w)
    end
  end)
end

local function sentence_case(s)
  if U.blank(s) then
    return s
  end
  local first = true
  return U.map_words(s, function(w)
    local r
    if U.uppercase_p(w) then
      r = U.capitalize_word(w)
    elseif first and U.lowercase_p(w) then
      r = U.capitalize_word(w)
    end
    first = false
    return r
  end)
end

local STOPWORDS = U.set({
  "a",
  "according to",
  "across",
  "afore",
  "after",
  "against",
  "ahead of",
  "along",
  "alongside",
  "amid",
  "amidst",
  "among",
  "amongst",
  "an",
  "and",
  "anenst",
  "apart from",
  "apropos",
  "around",
  "as",
  "as regards",
  "aside",
  "astride",
  "at",
  "athwart",
  "atop",
  "back to",
  "barring",
  "because of",
  "before",
  "behind",
  "below",
  "beneath",
  "beside",
  "besides",
  "between",
  "beyond",
  "but",
  "by",
  "c",
  "ca",
  "circa",
  "close to",
  "d'",
  "de",
  "despite",
  "down",
  "due to",
  "during",
  "et",
  "except",
  "far from",
  "for",
  "forenenst",
  "from",
  "given",
  "in",
  "inside",
  "instead of",
  "into",
  "lest",
  "like",
  "modulo",
  "near",
  "next",
  "nor",
  "of",
  "off",
  "on",
  "onto",
  "or",
  "out",
  "outside of",
  "over",
  "per",
  "plus",
  "prior to",
  "pro",
  "pursuant\n    to",
  "qua",
  "rather than",
  "regardless of",
  "sans",
  "since",
  "so",
  "such as",
  "than",
  "that of",
  "the",
  "through",
  "throughout",
  "thru",
  "thruout",
  "till",
  "to",
  "toward",
  "towards",
  "under",
  "underneath",
  "until",
  "unto",
  "up",
  "upon",
  "v.",
  "van",
  "versus",
  "via",
  "vis-à-vis",
  "von",
  "vs.",
  "where as",
  "with",
  "within",
  "without",
  "yet",
})

--- citeproc-s-title-case
local function title_case(s)
  if U.blank(s) then
    return s
  end
  local first = true
  local after_colon = false
  return U.map_words(s, function(w, span, cps)
    local r
    local nextc = cps[span[2]]
    if not (first or after_colon) and STOPWORDS[U.downcase(w)] and (w ~= "A" or nextc == nil or nextc ~= 46) then
      r = U.downcase(w)
    elseif U.lowercase_p(w) then
      r = U.capitalize_word(w)
    end
    first = false
    if nextc ~= nil then
      after_colon = nextc == 58 or nextc == 46
    end
    return r
  end)
end

--- citeproc-rt-textcased
local function textcased(rts, case, ctx)
  if case == "uppercase" then
    return rt.map_strings(U.upcase, rts, true)
  elseif case == "lowercase" then
    return rt.map_strings(U.downcase, rts, true)
  end
  local fn
  if case == "capitalize-first" then
    fn = capitalize_first
  elseif case == "capitalize-all" then
    fn = capitalize_all
  elseif case == "sentence" then
    fn = sentence_case
  elseif case == "title" then
    local locale = ctx and ctx.locale
    local language = ctx and M.var_value("language", ctx)
    if
      (language and U.starts_with(language, "en")) or (not language and (not locale or U.starts_with(locale, "en")))
    then
      fn = title_case
    else
      return rts
    end
  else
    return rts
  end
  local out = {}
  for i, r in ipairs(rts) do
    out[i] = rt.change_case(r, fn)
  end
  return out
end

--- citeproc-rt-join-formatted
function M.join_formatted(attrs, rts, ctx)
  local result = {}
  for i = 1, rts.n or #rts do
    local r = rts[i]
    if r ~= nil and r ~= false then
      result[#result + 1] = r
    end
  end
  local text_case = aget(attrs, "text-case")
  if text_case then
    result = textcased(result, text_case, ctx)
  end
  if aget(attrs, "strip-periods") == "true" then
    result = rt.strip_periods(result)
  end
  if aget(attrs, "quotes") == "true" then
    result = rt_quote(result, ctx)
  end
  local node = { rt.select_attrs(attrs, rt.EXT_FORMAT_ATTRS) }
  for _, r in ipairs(result) do
    node[#node + 1] = r
  end
  if aget(attrs, "delimiter") and #node > 2 then
    return node
  end
  return rt.simplify_shallow(node)
end

--- citeproc-rt-format-single
function M.format_single(attrs, r, ctx)
  if r == nil or r == false or r == "" then
    return nil
  end
  return M.join_formatted(attrs, { r }, ctx)
end

local function combined_type(values)
  local all_text, any_present = true, false
  for i = 1, values.n or #values do
    local t = tcdr(values[i])
    if t ~= "text-only" then
      all_text = false
    end
    if t == "present-var" then
      any_present = true
    end
  end
  if all_text then
    return "text-only"
  elseif any_present then
    return "present-var"
  end
  return "empty-vars"
end

local function cars(values)
  local out = { n = values.n or #values }
  for i = 1, out.n do
    out[i] = tcar(values[i])
  end
  return out
end

--- citeproc-rt-typed-join
function M.typed_join(attrs, values, ctx)
  return typed(M.join_formatted(attrs, cars(values), ctx), combined_type(values))
end

--- citeproc-context-int-link-attrval
function M.int_link_attrval(style, internal_links, mode, cite_pos)
  local note = S.cite_note(style)
  if
    (internal_links and internal_links ~= "auto" and internal_links ~= "bib-links")
    or (note and mode == "bib" and (not internal_links or internal_links == "auto"))
  then
    return nil
  end
  if note and internal_links ~= "bib-links" then
    return cite_pos == "first" and "bib-item-no" or "cited-item-no"
  end
  return mode == "cite" and "cited-item-no" or "bib-item-no"
end

local STOP = {}

--- citeproc-context-maybe-stop-rendering
function M.maybe_stop_rendering(trigger, ctx, result, var)
  if
    trigger == aget(ctx.vars, "stop-rendering-at")
    and (not var or var == trigger)
    and tcdr(result) == "present-var"
  then
    local r = tcar(result)
    if type(r) ~= "table" then
      r = { {}, r }
    end
    r[1] = acons("stopped-rendering", true, r[1])
    error({ [STOP] = true, value = rt.render_affixes(r) }, 0)
  end
  return result
end

--- citeproc-render-varlist-in-rt
function M.render_varlist_in_rt(vars, style, mode, render_mode, internal_links, no_external_links)
  local unprocessed = aget(vars, "unprocessed-with-id")
  if unprocessed then
    return { {}, "NO_ITEM_DATA:" .. unprocessed }
  end
  local ctx = M.context_create(vars, style, mode, render_mode, no_external_links)
  local layout = mode == "cite" and style.cite_layout or style.bib_layout
  if not layout then
    return "[NO BIBLIOGRAPHY LAYOUT IN CSL STYLE]"
  end
  local ok, rendered = pcall(layout, ctx)
  if not ok then
    if type(rendered) == "table" and rendered[STOP] then
      rendered = rendered.value
    else
      error(rendered, 0)
    end
  end
  if mode == "bib" and not no_external_links then
    local found
    for _, v in ipairs(rt.LINKED_VARS) do
      local p = U.assoc(vars, v)
      if p then
        found = p
        break
      end
    end
    if found then
      local rendered_vars = U.set(rt.rendered_vars(rendered))
      local inter = false
      for _, v in ipairs(rt.LINKED_VARS) do
        if rendered_vars[v] then
          inter = true
        end
      end
      if not inter then
        rt.link_title(rendered, (rt.LINK_PREFIX[found[1]] or "") .. tostring(aget(vars, found[1])))
      end
    end
  end
  local attr = M.int_link_attrval(style, internal_links, mode, aget(vars, "position"))
  if attr then
    local val = { attr, aget(vars, "citation-number") }
    if type(rendered) == "table" then
      local a = {}
      for _, p in ipairs(rendered[1]) do
        a[#a + 1] = p
      end
      a[#a + 1] = val
      rendered[1] = a
    elseif type(rendered) == "string" then
      rendered = { { val }, rendered }
    end
  end
  local ys = aget(vars, "year-suffix")
  if ys then
    return (rt.add_year_suffix(rendered, style.uses_ys_var and "" or ys))
  end
  return rendered
end

---------------------------------------------------------------------------
-- Splicing
---------------------------------------------------------------------------

local function splice_into(body)
  local out = { n = 0 }
  for i = 1, body.n or #body do
    local elt = body[i]
    if type(elt) == "table" and elt.splice then
      for j = 1, elt.n or #elt do
        out.n = out.n + 1
        out[out.n] = elt[j]
      end
    else
      out.n = out.n + 1
      out[out.n] = nf(elt)
    end
  end
  return out
end

local function add_splice_tag(list)
  local n = list.n or #list
  if n > 1 then
    local s = { splice = true, n = n }
    for i = 1, n do
      s[i] = list[i]
    end
    return s
  end
  local v = list[1]
  if v == nil then
    return false
  end
  return v
end

---------------------------------------------------------------------------
-- Generic elements
---------------------------------------------------------------------------

local E = {}
M.elements = E

function E.layout(attrs, ctx, body)
  if ctx.mode ~= "bib" then
    attrs = {}
  end
  local spliced = splice_into(body)
  local suffix = aget(attrs, "suffix")
  local wo_suffix = U.aremove(attrs, "suffix")
  local rendered = cars(spliced)
  if aget(ctx.opts, "second-field-align") and rendered.n > 1 then
    local rest = { { { "display", "right-inline" } } }
    for i = 2, rendered.n do
      rest[#rest + 1] = nf(rendered[i])
    end
    rendered = { { { { "display", "left-margin" } }, nf(rendered[1]) }, rest, n = 2 }
  end
  local affixed = rt.render_affixes(rt.dedup(M.join_formatted(wo_suffix, rendered, ctx)))
  local last_elt = type(affixed) == "table" and affixed[#affixed] or nil
  local last_display = type(last_elt) == "table"
    and #last_elt[1] > 0
    and (function()
      for _, p in ipairs(last_elt[1]) do
        if type(p) == "table" and p[1] == "display" then
          return true
        end
      end
      return false
    end)()
  if suffix then
    if last_display then
      local n = {}
      for i = 1, #last_elt do
        n[i] = last_elt[i]
      end
      n[#n + 1] = suffix
      affixed[#affixed] = n
    elseif type(affixed) == "table" then
      affixed[#affixed + 1] = suffix
    elseif affixed == nil then
      affixed = nil
    else
      affixed = affixed .. suffix
    end
  end
  return affixed
end

function E.group(attrs, ctx, body)
  local spliced = splice_into(body)
  local t = combined_type(spliced)
  local c
  if t == "text-only" or t == "present-var" then
    c = M.join_formatted(attrs, cars(spliced), ctx)
  end
  return typed(c, t)
end

local URL_PREFIX_RE = "https?://\\S *\\'"

function E.text(attrs, ctx)
  local content
  local ty = "text-only"
  local value = aget(attrs, "value")
  local variable = aget(attrs, "variable")
  local term = aget(attrs, "term")
  local macro = aget(attrs, "macro")
  local prefix = aget(attrs, "prefix")
  local form = aget(attrs, "form")
  if value then
    content = value
  elseif variable then
    local val = M.var_value(variable, ctx, form)
    content = val
    if val then
      ty = "present-var"
      attrs = acons("rendered-var", variable, attrs)
      if not ctx.no_external_links and U.set(rt.LINKED_VARS)[variable] then
        local target = (rt.LINK_PREFIX[variable] or "") .. rt.to_plain(content)
        if prefix then
          local b = R.search(URL_PREFIX_RE, prefix)
          if b then
            content = U.substring(prefix, b) .. rt.to_plain(content)
            attrs = acons("prefix", U.substring(prefix, 0, b), attrs)
          end
        end
        attrs = acons("href", target, attrs)
      end
    elseif variable ~= "year-suffix" then
      ty = "empty-vars"
    end
  elseif term then
    local f = form or "long"
    local plural = aget(attrs, "plural")
    local number = (not plural or plural == "false") and "single" or "multiple"
    local cont = M.term_inflected_text(term, f, number, ctx)
    if term == "no date" then
      ty = "present-var"
      content = { { { "rendered-var", "issued" } }, nf(cont) }
    else
      content = cont
    end
  elseif macro then
    local v = M.macro_output(macro, ctx)
    content = tcar(v)
    ty = tcdr(v)
  end
  local result = typed(M.format_single(attrs, content, ctx), ty)
  return M.maybe_stop_rendering("title", ctx, result, variable or true)
end

function E.macro(attrs, ctx, body)
  local spliced = splice_into(body)
  local val = M.typed_join(attrs, spliced, ctx)
  if val.t == "empty-vars" then
    return typed(nil, "text-only")
  end
  return val
end

function M.macro_output(name, ctx)
  local fn = ctx.macros and ctx.macros[name]
  if not fn then
    error(string.format("There is no macro called `%s' in style", tostring(name)), 0)
  end
  return fn(ctx)
end

function M.macro_output_as_text(name, ctx)
  return rt.to_plain(rt.render_affixes(tcar(M.macro_output(name, ctx))))
end

---------------------------------------------------------------------------
-- Conditions (cs:choose)
---------------------------------------------------------------------------

local NUMERIC_RE =
  "\\`[[:alpha:]]?[[:digit:]]+[[:alpha:]]*\\(\\( *\\([,&-]\\|--\\) *\\)?[[:alpha:]]?[[:digit:]]+[[:alpha:]]*\\)?\\'"

--- citeproc-lib-numeric-p
function M.numeric_p(val)
  if type(val) == "number" then
    return true
  end
  return type(val) == "string" and R.test(NUMERIC_RE, val)
end

local function eval_elementary(ty, param, ctx)
  if ty == "variable" then
    local v = M.var_value(param, ctx)
    return v ~= nil and v ~= false
  elseif ty == "type" then
    return param == M.var_value("type", ctx)
  elseif ty == "locator" then
    return param == M.var_value("label", ctx)
  elseif ty == "is-numeric" then
    return M.numeric_p(M.var_value(param, ctx))
  elseif ty == "is-uncertain-date" then
    local dates = M.var_value(param, ctx)
    return type(dates) == "table" and dates[1] ~= nil and dates[1].circa and true or false
  elseif ty == "position" then
    if ctx.mode ~= "cite" then
      return false
    end
    if param == "near-note" and M.var_value("near-note", ctx) then
      return true
    end
    local pos = M.var_value("position", ctx)
    return param == pos
      or (param == "subsequent" and (pos == "ibid" or pos == "ibid-with-locator"))
      or (param == "ibid" and pos == "ibid-with-locator")
  elseif ty == "disambiguate" then
    return M.var_value("disambiguate", ctx) and true or false
  end
  return false
end

--- citeproc-choose-eval-conditions
function M.eval_conditions(attrs, ctx)
  local values = {}
  local match = "all"
  for _, p in ipairs(attrs) do
    if type(p) == "table" then
      if p[1] == "match" then
        match = p[2]
      else
        for _, param in ipairs(R.split(p[2], " ", false)) do
          values[#values + 1] = eval_elementary(p[1], param, ctx)
        end
      end
    end
  end
  if match == "all" then
    for _, v in ipairs(values) do
      if not v then
        return false
      end
    end
    return true
  elseif match == "any" then
    for _, v in ipairs(values) do
      if v then
        return true
      end
    end
    return false
  elseif match == "none" then
    for _, v in ipairs(values) do
      if v then
        return false
      end
    end
    return true
  end
  return false
end

---------------------------------------------------------------------------
-- Labels
---------------------------------------------------------------------------

local function var_plural_p(var, ctx)
  local content = rt.to_plain(M.var_value(var, ctx))
  if var == "number-of-pages" or var == "number-of-volumes" then
    return U.to_number(content) > 1
  end
  local and_term = M.term_get_text("and", ctx) or ""
  local q = and_term:gsub("[%^%$%.%*%+%?%[%]\\]", "\\%0")
  return R.test("[[:digit:]] *\\([-,;–&—―]+\\|[,;]? *" .. q .. "\\) *[a-zA-Z]?[[:digit:]]", content)
end

function E.label(attrs, ctx)
  local variable = aget(attrs, "variable")
  local form = aget(attrs, "form")
  local plural = aget(attrs, "plural")
  local label = variable
  local number
  if label == "editortranslator" or (label and M.var_value(label, ctx)) then
    form = form or "long"
    if variable == "locator" then
      variable = M.var_value("label", ctx)
    end
    if plural == "never" then
      number = "single"
    elseif plural == "always" then
      number = "multiple"
    else
      number = var_plural_p(label, ctx) and "multiple" or "single"
    end
    if label == "locator" and ctx.mode == "cite" then
      attrs = acons("rendered-locator-label", true, attrs)
    end
    return typed(M.format_single(attrs, M.term_inflected_text(variable, form, number, ctx), ctx), "text-only")
  end
  return typed(nil, "text-only")
end

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------

local function nil_or_num(s)
  if s == nil then
    return 0
  end
  return U.to_number(s)
end

local function render_et_al(attrs, ctx)
  if ctx.render_mode == "sort" then
    return ""
  end
  local term = aget(attrs, "term") or "et-al"
  return M.format_single(attrs, M.term_get_text(term, ctx), ctx)
end

--- citeproc-name--conc-nps
local function conc_nps(...)
  local nonnils = {}
  for i = 1, select("#", ...) do
    local x = select(i, ...)
    if x ~= nil and x ~= false then
      nonnils[#nonnils + 1] = x
    end
  end
  if #nonnils > 1 then
    local len = #nonnils
    local particle = nonnils[len - 1]
    local pstr = type(particle) == "table" and particle[2] or particle
    if type(pstr) == "string" and U.ends_with(pstr, "ʼ") then
      local family = nonnils[len]
      return { { {}, particle, family } }
    end
  end
  return nonnils
end

local LCG_RE = "^\\(\\cl\\|\\cy\\|\\cg\\|ʼ\\)*$"

local function lat_cyr_greek_p(name_alist)
  for _, p in ipairs(name_alist) do
    local v = p[2]
    if type(v) == "table" then
      v = v[2]
    end
    if type(v) == "string" and not R.test(LCG_RE, v) then
      return false
    end
  end
  return true
end

local function initialize_hyphenated(name, suffix, remove_hyphens)
  local inner = U.trim(suffix)
  local parts = {}
  for _, p in ipairs(R.split(name, "-", false)) do
    parts[#parts + 1] = U.substring(p, 0, math.min(1, U.len(p)))
  end
  return table.concat(parts, remove_hyphens and inner or (inner .. "-"))
end

--- citeproc-name--initialize
local function initialize(names, suffix, remove_hyphens)
  local trimmed = U.trim(suffix)
  local parts = {}
  for _, it in ipairs(R.split(names, " +", false)) do
    if R.test("-", it) then
      parts[#parts + 1] = initialize_hyphenated(it, suffix, remove_hyphens)
    else
      parts[#parts + 1] = U.substring(it, 0, math.min(1, U.len(it)))
    end
  end
  return table.concat(parts, suffix) .. trimmed
end

local function initials_add_suffix(suffix, names)
  suffix = U.trim(suffix)
  local out = {}
  for _, x in ipairs(R.slice_by_matches(names, "[ \\-]", 0, true)) do
    if x[2] and R.test("^[[:alpha:]]$", x[1]) then
      out[#out + 1] = x[1] .. suffix
    else
      out[#out + 1] = x[1]
    end
  end
  return table.concat(out)
end

local function show_givenname_level(id, ctx)
  local sg = aget(ctx.vars, "show-given-names")
  return aget(sg, id)
end

local function parts_w_sep(c1, c2, sep, ctx)
  local joined = M.join_formatted({ { "delimiter", " " } }, c1, ctx)
  local none = true
  for i = 1, c2.n or #c2 do
    local x = c2[i]
    if type(x) == "table" and x[2] ~= nil and x[2] ~= false then
      none = false
    end
  end
  if none then
    return joined
  end
  return M.join_formatted(
    { { "delimiter", sep } },
    { joined, M.join_formatted({ { "delimiter", " " } }, c2, ctx), n = 2 },
    ctx
  )
end

--- citeproc-name--render-formatted
local function render_formatted(name_alist, attrs, sort_o, ctx)
  local gopts = ctx.opts
  local f = aget(name_alist, "family")
  local g_un = aget(name_alist, "given")
  local s = aget(name_alist, "suffix")
  local d = aget(name_alist, "dropping-particle")
  local n = aget(name_alist, "non-dropping-particle")
  local nid = aget(name_alist, "name-id")
  local all = U.concat(attrs, gopts)
  local sort_sep = aget(all, "sort-separator") or ", "
  local init = aget(all, "initialize") ~= "false"
  local init_with = aget(all, "initialize-with")
  local form = aget(all, "form")
  local name_form = aget(all, "name-form")
  local dnd = aget(gopts, "demote-non-dropping-particle")
  local id = type(nid) == "table" and nid[2] or nil
  local show_given = show_givenname_level(id, ctx)
  if show_given then
    form = "long"
  else
    form = form or name_form or "long"
  end
  local rmode = ctx.render_mode
  if lat_cyr_greek_p(name_alist) then
    local g
    if g_un == nil or (show_given and show_given == 2) then
      g = g_un
    elseif init_with and init then
      g = {
        rt.attrs(g_un) or {},
        initialize(rt.first_content(g_un), init_with, aget(gopts, "initialize-with-hyphen") == "false"),
      }
    elseif init_with then
      g = { rt.attrs(g_un) or {}, initials_add_suffix(init_with, rt.first_content(g_un)) }
    else
      g = g_un
    end
    if form == "long" then
      if sort_o then
        if dnd == "never" or (dnd == "sort-only" and rmode == "display") then
          return parts_w_sep(conc_nps(n, f), { g, d, s, n = 3 }, sort_sep, ctx)
        end
        return parts_w_sep({ f }, { g, d, n, s, n = 4 }, sort_sep, ctx)
      end
      local list = { n = 1 }
      list[1] = g
      for _, x in ipairs(conc_nps(d, n, f)) do
        list.n = list.n + 1
        list[list.n] = x
      end
      list.n = list.n + 1
      list[list.n] = s
      return M.join_formatted({ { "delimiter", " " } }, list, ctx)
    end
    return M.join_formatted({ { "delimiter", " " } }, conc_nps(n, f), ctx)
  end
  if form == "long" then
    return M.join_formatted({ { "delimiter", " " } }, { f, g_un, n = 2 }, ctx)
  end
  return f
end

--- citeproc-name--format-nameparts
local function format_nameparts(name_alist, part_attrs, ctx)
  local given_attrs = aget(part_attrs, "given")
  local family_attrs = aget(part_attrs, "family")
  -- an empty attribute list is Emacs nil
  if given_attrs and #given_attrs == 0 then
    given_attrs = nil
  end
  if family_attrs and #family_attrs == 0 then
    family_attrs = nil
  end
  local out = {}
  for _, p in ipairs(name_alist or {}) do
    local part, content = p[1], p[2]
    local v
    if given_attrs and (part == "given" or part == "dropping-particle") then
      v = M.format_single(given_attrs, content, ctx)
    elseif family_attrs and (part == "family" or part == "non-dropping-particle") then
      v = M.format_single(family_attrs, content, ctx)
    else
      v = { {}, nf(content) }
    end
    out[#out + 1] = { part, v }
  end
  return out
end

local FORMAT_PLUS_AFFIXES = U.concat({ "prefix", "suffix" }, rt.FORMAT_ATTRS)

local function render_name(name, attrs, part_attrs, sort_o, ctx)
  local fattrs = rt.select_attrs(attrs, FORMAT_PLUS_AFFIXES)
  return M.format_single(
    acons("name-id", aget(name, "name-id"), fattrs),
    render_formatted(format_nameparts(name, part_attrs, ctx), attrs, sort_o, ctx),
    ctx
  )
end

--- citeproc-name--render-names
local function render_names(names, attrs, et_al_attrs, part_attrs, ctx)
  local all = U.concat(attrs, ctx.opts)
  local sort_o = ctx.render_mode == "sort" and "all" or aget(all, "name-as-sort-order")
  local count = #(names or {})
  local first = render_name(names[1] or {}, attrs, part_attrs, sort_o, ctx)
  if count == 1 then
    return first
  end
  local delimiter = aget(all, "delimiter") or aget(all, "name-delimiter") or ", "
  local add_names = aget(all, "add-names") or 0
  local position = M.var_value("position", ctx)
  local et_al_min = aget(all, "et-al-min")
  local et_al_use_first = aget(all, "et-al-use-first")
  if position ~= nil and position ~= "first" then
    et_al_min = aget(all, "et-al-subsequent-min") or et_al_min
    et_al_use_first = aget(all, "et-al-subsequent-use-first") or et_al_use_first
  end
  et_al_min = aget(all, "names-min") or et_al_min
  et_al_use_first = aget(all, "names-use-first") or et_al_use_first
  local et_al_use_last = aget(all, "names-use-last") == "true" or aget(all, "et-al-use-last") == "true"
  local et_al_min_val = aget(ctx.vars, "ignore-et-al") and 100 or nil_or_num(et_al_min)
  local use_first_val = add_names + nil_or_num(et_al_use_first)
  local et_al = et_al_min and et_al_use_first and count >= et_al_min_val and use_first_val < count
  local middle_end = et_al and use_first_val or (count - 1)
  local sort_latters = sort_o == "all"
  local middle
  if middle_end >= 2 then
    local ms = {}
    for k = 2, middle_end do
      ms[#ms + 1] = render_name(names[k], attrs, part_attrs, sort_latters, ctx)
    end
    ms.n = middle_end - 1
    middle = M.join_formatted({ { "delimiter", delimiter }, { "prefix", delimiter } }, ms, ctx)
  end
  local last_after_inverted = sort_latters or (sort_o == "first" and middle == nil)
  local last_delim = et_al and aget(all, "delimiter-precedes-et-al")
    or (not et_al and aget(all, "delimiter-precedes-last"))
  if last_delim == false then
    last_delim = nil
  end
  local last_pref = " "
  if
    ((not last_delim or last_delim == "contextual") and middle_end > 1)
    or last_delim == "always"
    or (last_delim == "after-inverted-name" and last_after_inverted)
  then
    last_pref = delimiter
  end
  local last
  local and_ = aget(all, "and")
  if et_al then
    if et_al_use_last then
      last = M.join_formatted(
        nil,
        { delimiter, "… ", render_name(names[count], attrs, part_attrs, sort_latters, ctx), n = 3 },
        ctx
      )
    else
      last = render_et_al(acons("prefix", last_pref, et_al_attrs), ctx)
    end
  elseif and_ then
    local and_str = and_ == "text" and M.term_get_text("and", ctx) or "&"
    last = M.join_formatted(
      { { "prefix", last_pref } },
      { and_str, " ", render_name(names[count], attrs, part_attrs, sort_latters, ctx), n = 3 },
      ctx
    )
  else
    last =
      M.join_formatted(nil, { delimiter, render_name(names[count], attrs, part_attrs, sort_latters, ctx), n = 2 }, ctx)
  end
  return M.join_formatted(U.aremove(attrs, "delimiter"), { first, middle, last, n = 3 }, ctx)
end

--- citeproc-name--render-var
local function render_var(var, attrs, part_attrs, et_al_attrs, with_label, label_before, label_attrs, ctx, ed_trans)
  local add_names = M.var_value("add-names", ctx)
  if add_names then
    local v = aget(add_names, var)
    if v then
      attrs = acons("add-names", v, attrs)
    end
  end
  local value = M.var_value(var, ctx)
  local rendered = render_names(value or {}, attrs, et_al_attrs, part_attrs, ctx)
  if type(rendered) ~= "table" then
    rendered = { {}, nf(rendered) }
  end
  rendered[1] = acons("rendered-names", nil, rendered[1])
  label_attrs = acons("variable", ed_trans and "editortranslator" or var, label_attrs)
  local plural = aget(label_attrs, "plural")
  if not plural or plural == "contextual" then
    label_attrs = acons("plural", #(value or {}) > 1 and "always" or "never", label_attrs)
  end
  if with_label then
    local label = tcar(E.label(label_attrs, ctx))
    local list = label_before and { label, rendered, n = 2 } or { rendered, label, n = 2 }
    return M.join_formatted({ { "rendered-var", var } }, list, ctx)
  end
  rendered[1] = acons("rendered-var", var, rendered[1])
  return rendered
end
M.name_render_var = render_var

--- citeproc-name-render-vars
function M.name_render_vars(
  varstring,
  attrs,
  name_attrs,
  part_attrs,
  et_al_attrs,
  with_label,
  label_before,
  label_attrs,
  ctx
)
  local vars = R.split(varstring or "", " ", false)
  local present = {}
  for _, v in ipairs(vars) do
    if M.var_value(v, ctx) then
      present[#present + 1] = v
    end
  end
  local ed_trans = false
  local has = U.set(present)
  if has.editor and has.translator and #present == 2 then
    local function ids(v)
      local out = {}
      for _, nm in ipairs(M.var_value(v, ctx) or {}) do
        out[#out + 1] = aget(nm, "name-id")
      end
      return out
    end
    if vim.deep_equal(ids("editor"), ids("translator")) then
      present = { "editor" }
      ed_trans = true
    end
  end
  if not aget(attrs, "delimiter") then
    local nd = aget(ctx.opts, "names-delimiter")
    if nd then
      attrs = acons("delimiter", nd, attrs)
    end
  end
  if #present > 0 then
    local rendered = {}
    for _, v in ipairs(present) do
      rendered[#rendered + 1] =
        render_var(v, name_attrs, part_attrs, et_al_attrs, with_label, label_before, label_attrs, ctx, ed_trans)
    end
    return typed(M.join_formatted(attrs, rendered, ctx), "present-var")
  end
  return typed(nil, "empty-vars")
end

local compile

--- citeproc-style--transform-names
local function compile_names(frag)
  local names_attrs = frag.attrs
  local vars = aget(names_attrs, "variable")
  local name_attrs, name_parts, et_al_attrs, label_attrs
  local is_label, label_before = false, false
  local substs = {}
  for _, it in ipairs(frag) do
    if type(it) == "table" then
      if it.tag == "name" then
        name_attrs = it.attrs
        name_parts = S.named_parts(it)
        label_before = true
      elseif it.tag == "et-al" then
        et_al_attrs = it.attrs
      elseif it.tag == "label" then
        is_label = true
        label_attrs = it.attrs
        label_before = false
      elseif it.tag == "substitute" then
        substs = {}
        for _, x in ipairs(it) do
          if type(x) == "table" then
            if x.tag == "names" then
              local v = aget(x.attrs, "variable")
              substs[#substs + 1] = function(ctx)
                return M.name_render_vars(
                  v,
                  names_attrs,
                  name_attrs,
                  name_parts,
                  et_al_attrs,
                  is_label,
                  label_before,
                  label_attrs,
                  ctx
                )
              end
            else
              substs[#substs + 1] = compile(x)
            end
          end
        end
      end
    end
  end
  return function(ctx)
    if M.var_value("suppress-author", ctx) then
      return typed(nil, "empty-vars")
    end
    local count = aget(name_attrs, "form") == "count"
    local val = M.name_render_vars(
      vars,
      names_attrs,
      name_attrs,
      name_parts,
      et_al_attrs,
      is_label,
      label_before,
      label_attrs,
      ctx
    )
    local result
    if tcar(val) then
      result = val
    else
      local evaluated = {}
      for i, s in ipairs(substs) do
        evaluated[i] = s(ctx)
      end
      for _, e in ipairs(evaluated) do
        if type(e) == "table" and (e.splice or tcar(e)) then
          local cont = e.splice and "splice" or tcar(e)
          result = typed({ { { "subst", true } }, cont }, tcdr(e))
          break
        end
      end
      result = result or typed(nil, "empty-vars")
    end
    local final = result
    if count then
      local number = rt.count_names(tcar(result))
      final = typed(number == 0 and "" or tostring(number), tcdr(result))
    end
    return M.maybe_stop_rendering("names", ctx, final)
  end
end

---------------------------------------------------------------------------
-- Dates
---------------------------------------------------------------------------

--- citeproc-date-parse: CSL-JSON date to a list of date structs.
function M.date_parse(rep)
  local parts = rep and rep["date-parts"]
  if type(parts) ~= "table" then
    return nil
  end
  local out = {}
  for _, dp in ipairs(parts) do
    local nums = {}
    for i = 1, 3 do
      local x = dp[i]
      if type(x) == "string" then
        x = U.to_number(x)
      end
      nums[i] = x
    end
    out[#out + 1] = { year = nums[1], month = nums[2], day = nums[3], season = rep.season, circa = rep.circa }
  end
  if #out == 0 then
    return nil
  end
  return out
end

local function partattrs_for_sort(part_attrs)
  local has = {}
  for _, p in ipairs(part_attrs) do
    has[p[1]] = true
  end
  local out = {}
  if has.year then
    out[#out + 1] = { "year", { { "form", "long" } } }
  end
  if has.month then
    out[#out + 1] = { "month", { { "form", "numeric-leading-zeros" } } }
  end
  if has.day then
    out[#out + 1] = { "day", { { "form", "numeric-leading-zeros" } } }
  end
  return out
end

local function renders_with_attrs_p(date, part_attrs)
  local parts = {}
  for _, p in ipairs(part_attrs) do
    parts[p[1]] = true
  end
  return parts.year or (parts.month and date.month) or (parts.day and date.day)
end

local function localized_attrs(attrs, part_attrs, ctx)
  local form = aget(attrs, "form")
  local date_parts = aget(attrs, "date-parts")
  local loc = form == "text" and ctx.date_text or ctx.date_numeric
  local loc_attrs = loc and loc.attrs or {}
  local loc_parts = loc and loc.parts or {}
  if date_parts == "year" then
    loc_parts = U.afilter(loc_parts, function(p)
      return p[1] == "year"
    end)
  elseif date_parts == "year-month" then
    loc_parts = U.afilter(loc_parts, function(p)
      return p[1] == "year" or p[1] == "month"
    end)
  end
  local parts = {}
  for _, p in ipairs(loc_parts) do
    parts[#parts + 1] = { p[1], U.concat(aget(part_attrs, p[1]), p[2]) }
  end
  return U.concat(attrs, loc_attrs), parts
end

local function render_year(d, attrs, ctx)
  local form = aget(attrs, "form")
  local year = d.year or 0
  local s = U.num_str(math.abs(year))
  local era
  if year > 999 then
    era = ""
  elseif year > 0 then
    era = M.term_get_text("ad", ctx) or ""
  else
    era = M.term_get_text("bc", ctx) or ""
  end
  if form == "short" then
    s = U.substring(s, math.max(0, U.len(s) - 2))
  end
  return M.format_single(attrs, s .. era, ctx)
end

local function render_month(d, attrs, ctx)
  local month = d.month
  if not month then
    return nil
  end
  local form = aget(attrs, "form")
  local pref = d.season and "season-" or "month-"
  local text
  if form == "numeric" then
    text = U.num_str(month)
  elseif form == "numeric-leading-zeros" then
    text = string.format("%02d", month)
  elseif form == "short" then
    text = M.term_inflected_text(pref .. string.format("%02d", month), "short", nil, ctx)
  else
    text = M.term_inflected_text(pref .. string.format("%02d", month), "long", nil, ctx)
  end
  return M.format_single(attrs, text, ctx)
end

local format_as_ordinal

local function render_day(d, attrs, ctx)
  local day = d.day
  if not day then
    return nil
  end
  local form = aget(attrs, "form")
  local text
  if form == "numeric-leading-zeros" then
    text = string.format("%02d", day)
  elseif form == "ordinal" and (day == 1 or aget(ctx.locale_opts, "limit-day-ordinals-to-day-1") ~= "true") then
    text = format_as_ordinal(U.num_str(day), "month-" .. string.format("%02d", d.month or 0), ctx)
  else
    text = U.num_str(day)
  end
  return M.format_single(attrs, text, ctx)
end

local function render_parts(d, part_attrs, ctx, no_last_suffix)
  local result = { n = 0 }
  for _, p in ipairs(part_attrs) do
    local v
    if p[1] == "year" then
      v = render_year(d, p[2], ctx)
    elseif p[1] == "month" then
      v = render_month(d, p[2], ctx)
    elseif p[1] == "day" then
      v = render_day(d, p[2], ctx)
    end
    result.n = result.n + 1
    result[result.n] = nf(v)
  end
  if no_last_suffix and result.n > 0 then
    local last = result[result.n]
    if type(last) == "table" then
      local n = { U.aremove(last[1], "suffix") }
      for i = 2, #last do
        n[i] = last[i]
      end
      result[result.n] = n
    end
  end
  return result
end

local function render_date(d, attrs, part_attrs, ctx)
  if M.var_value("suppress-date", ctx) then
    return M.format_single(attrs, "<suppressed-date>", ctx)
  end
  return M.join_formatted(attrs, render_parts(d, part_attrs, ctx), ctx)
end

local function date_gran(d)
  if d.day then
    return 2
  elseif d.month then
    return 1
  end
  return 0
end

local function attrs_gran(part_attrs)
  if U.assoc(part_attrs, "day") then
    return 2
  elseif U.assoc(part_attrs, "month") then
    return 1
  end
  return 0
end

local function render_range_parts(d1, d2, part_attrs, sep, ctx)
  local out = { n = 0 }
  local function add(v)
    out.n = out.n + 1
    out[out.n] = nf(v)
  end
  for _, it in ipairs(part_attrs) do
    if it.group then
      local a = render_parts(d1, it, ctx, true)
      for i = 1, a.n do
        add(a[i])
      end
      add(sep)
      local b = render_parts(d2, it, ctx)
      for i = 1, b.n do
        add(b[i])
      end
    elseif it[1] == "year" then
      add(render_year(d1, it[2], ctx))
    elseif it[1] == "month" then
      add(render_month(d1, it[2], ctx))
    elseif it[1] == "day" then
      add(render_day(d1, it[2], ctx))
    end
  end
  return out
end

local function group_of(list)
  local g = { group = true }
  for _, x in ipairs(list) do
    g[#g + 1] = x
  end
  return g
end

local function render_range(d1, d2, attrs, part_attrs, ctx)
  if M.var_value("suppress-date", ctx) then
    return M.format_single(attrs, "", ctx)
  end
  local gran = math.min(date_gran(d1), attrs_gran(part_attrs))
  local unit = ({ "year", "month", "day" })[gran + 1]
  local sep = aget(aget(part_attrs, unit), "range-delimiter") or "–"
  local groups
  if d1.year ~= d2.year then
    groups = { group_of(part_attrs) }
  elseif d1.month ~= d2.month then
    local year_part = U.assoc(part_attrs, "year")
    local wo_year = U.aremove(part_attrs, "year")
    if part_attrs[1] and part_attrs[1][1] == "year" then
      groups = { year_part, group_of(wo_year) }
    elseif part_attrs[#part_attrs] and part_attrs[#part_attrs][1] == "year" then
      groups = { group_of(wo_year), year_part }
    else
      groups = { group_of(wo_year) }
    end
  else
    groups = {}
    for _, it in ipairs(part_attrs) do
      if it[1] == "day" then
        groups[#groups + 1] = group_of({ it })
      else
        groups[#groups + 1] = it
      end
    end
  end
  return M.join_formatted(attrs, render_range_parts(d1, d2, groups, sep, ctx), ctx)
end

function E.date(attrs, ctx, body)
  local var = aget(attrs, "variable")
  local form = aget(attrs, "form")
  local dates = M.var_value(var, ctx)
  local d1 = type(dates) == "table" and dates[1] or nil
  local d2 = type(dates) == "table" and dates[2] or nil
  local parts = {}
  for i = 1, body.n or #body do
    if type(body[i]) == "table" then
      parts[#parts + 1] = body[i]
    end
  end
  local result
  if d1 then
    if form then
      attrs, parts = localized_attrs(attrs, parts, ctx)
    end
    if ctx.render_mode == "sort" then
      parts = partattrs_for_sort(parts)
    end
    if renders_with_attrs_p(d1, parts) then
      attrs = acons("rendered-var", var, attrs)
      if d2 then
        result = typed(render_range(d1, d2, attrs, parts, ctx), "present-var")
      else
        result = typed(render_date(d1, attrs, parts, ctx), "present-var")
      end
    else
      result = typed(nil, "empty-vars")
    end
  else
    result = typed(nil, "empty-vars")
  end
  return M.maybe_stop_rendering("issued", ctx, result, var)
end

E["date-part"] = function(attrs)
  return { aget(attrs, "name"), attrs }
end

---------------------------------------------------------------------------
-- Numbers
---------------------------------------------------------------------------

local SEP_ALT = "\\([,&-–—―]\\|--\\)"
local NUM_EXTRACT_RE = "\\`\\([[:alpha:]]?[[:digit:]]+[[:alpha:]]*\\)\\(?:\\(?: *"
  .. SEP_ALT
  .. " *\\)\\([[:alpha:]]?[[:digit:]]+[[:alpha:]]*\\)\\)?\\'"

--- citeproc-number-extract: the groups, or nil
function M.number_extract(val)
  local m = R.match(NUM_EXTRACT_RE, val)
  if not m then
    return nil
  end
  -- trailing unmatched groups are dropped (match-data)
  local out = {}
  local last = 0
  for k = 1, 3 do
    if m[k] ~= nil then
      last = k
    end
  end
  for k = 1, last do
    out[k] = m[k]
  end
  out.n = last
  return out
end

local NUMSEP = { ["&"] = " & ", [","] = ", ", ["-"] = "-", ["--"] = "-", ["—"] = "-", ["―"] = "-" }

local function arabic_to_roman(n)
  local vals = {
    { 1000, "M" },
    { 900, "CM" },
    { 500, "D" },
    { 400, "CD" },
    { 100, "C" },
    { 90, "XC" },
    { 50, "L" },
    { 40, "XL" },
    { 10, "X" },
    { 9, "IX" },
    { 5, "V" },
    { 4, "IV" },
    { 1, "I" },
  }
  local out = {}
  for _, v in ipairs(vals) do
    while n >= v[1] do
      out[#out + 1] = v[2]
      n = n - v[1]
    end
  end
  return table.concat(out)
end

local function tail(s, len)
  local l = U.len(s)
  if len and len < l then
    return U.substring(s, l - len)
  end
  return s
end

local ORD_MATCH = { ["last-two-digits"] = 2, ["last-digit"] = 1 }

local function ordinal_matches_p(s, gender, term)
  if gender ~= term.gender_form then
    return false
  end
  local match = term.match
  local name = term.name
  if not match then
    match = name:sub(9, 9) == "0" and "last-digit" or "last-two-digits"
  end
  local num = tail(name, 2)
  local l = ORD_MATCH[match]
  return tail(s, l) == tail(num, l)
end

format_as_ordinal = function(s, term, ctx)
  local terms = ctx.terms or {}
  local padded = U.len(s) == 1 and ("0" .. s) or s
  local gender = M.term_get_gender(term, ctx)
  local matches = {}
  for _, t in ipairs(terms) do
    if t.name and t.name:sub(1, 8) == "ordinal-" and ordinal_matches_p(padded, gender, t) then
      matches[#matches + 1] = t
    end
  end
  local chosen
  if #matches == 0 then
    local ords = {}
    for _, t in ipairs(terms) do
      if t.name == "ordinal" then
        ords[#ords + 1] = t
      end
    end
    for _, t in ipairs(ords) do
      if t.gender_form == gender then
        chosen = t
        break
      end
    end
    chosen = chosen or ords[1]
  else
    local first, second = matches[1], matches[2]
    if second then
      chosen = first.name:sub(9, 9) == "0" and second or first
    else
      chosen = first
    end
  end
  return s .. (chosen and chosen.text or "")
end

local function format_as_long_ordinal(s, term, ctx)
  local num = U.to_number(s)
  if num > 10 then
    return format_as_ordinal(s, term, ctx)
  end
  if U.len(s) == 1 then
    s = "0" .. s
  end
  local name = "long-ordinal-" .. s
  local gender = M.term_get_gender(term, ctx)
  for _, t in ipairs(ctx.terms or {}) do
    if t.name == name and t.gender_form == gender then
      return t.text
    end
  end
  return M.term_get_text(name, ctx)
end

local function number_format(s, form, term, ctx)
  if R.test("[[:alpha:]]", s) then
    return s
  end
  if form == "roman" then
    return U.downcase(arabic_to_roman(U.to_number(s)))
  elseif form == "ordinal" then
    return format_as_ordinal(s, term, ctx)
  elseif form == "long-ordinal" then
    return format_as_long_ordinal(s, term, ctx)
  end
  return s
end

--- citeproc-number-var-value
function M.number_var_value(value, variable, form, ctx)
  if value == nil or value == false then
    return nil
  end
  if type(value) == "number" then
    return U.num_str(value)
  end
  if type(value) ~= "string" then
    return value
  end
  local it = M.number_extract(value)
  if not it then
    return value
  end
  local first = number_format(it[1], form, variable, ctx)
  if it.n > 1 then
    return first .. (NUMSEP[it[2]] or "") .. (number_format(it[3], form, variable, ctx) or "")
  end
  return first
end

function E.number(attrs, ctx)
  local var = aget(attrs, "variable")
  local form = aget(attrs, "form")
  local value = M.var_value(var, ctx)
  if not value then
    return typed(nil, "empty-var")
  end
  return typed(
    M.format_single(acons("rendered-var", var, attrs), M.number_var_value(value, var, form, ctx), ctx),
    "present-var"
  )
end

---------------------------------------------------------------------------
-- Page ranges (citeproc-prange.el)
---------------------------------------------------------------------------

local function compare_strings(a, b)
  local ca, cb = U.codepoints(a), U.codepoints(b)
  local n = math.max(#ca, #cb)
  for i = 1, n do
    if ca[i] ~= cb[i] then
      return i
    end
  end
  return n + 1
end

local function fill_copy(s1, s2)
  local l1, l2 = U.len(s1), U.len(s2)
  if l1 >= l2 then
    return s1
  end
  return U.substring(s2, 0, l2 - l1) .. s1
end

local function end_significant(start, e, len)
  local first = math.min(math.max(1, 1 + U.len(e) - len), compare_strings(start, e))
  return U.substring(e, first - 1)
end

local function end_chicago(start, e, _, ed15)
  local len = U.len(start)
  if len < 3 or U.substring(start, -2) == "00" then
    return e
  elseif U.substring(start, -2, -1) == "0" then
    return end_significant(start, e, 1)
  elseif ed15 and len == 4 then
    local min_two = end_significant(start, e, 2)
    if U.len(min_two) > 2 then
      return e
    end
    return min_two
  end
  return end_significant(start, e, 2)
end

local PRANGE_FORMATTERS = {
  chicago = function(s, e, p)
    return end_chicago(s, e, p, true)
  end,
  ["chicago-15"] = function(s, e, p)
    return end_chicago(s, e, p, true)
  end,
  ["chicago-16"] = function(s, e, p)
    return end_chicago(s, e, p)
  end,
  minimal = function(s, e)
    return end_significant(s, e, 1)
  end,
  ["minimal-two"] = function(s, e)
    return end_significant(s, e, 2)
  end,
  expanded = function(_, e, p)
    return (p or "") .. e
  end,
}

local PRANGE_RE =
  "\\([[:digit:]]*[[:alpha:]]\\)?\\([[:digit:]]+\\)\\( ?\\)\\([-–—]+\\)\\( ?\\)\\([[:digit:]]*[[:alpha:]]\\)?\\([[:digit:]]+\\)"

--- citeproc-prange-render
function M.prange_render(p, format, sep)
  if type(p) ~= "string" then
    return p
  end
  local cps = U.codepoints(p)
  local pos = 0
  while true do
    local b, md = R.search(PRANGE_RE, cps, pos)
    if not b then
      break
    end
    local start_pref, start_num = md:str(1), md:str(2)
    local orig_dash = md:str(4)
    local orig_sep = (md:str(3) or "") .. orig_dash .. (md:str(5) or "")
    local end_pref, end_num = md:str(6), md:str(7)
    local e = (end_pref or "") .. end_num
    local old = orig_sep .. e
    local new
    if start_pref ~= end_pref then
      new = orig_dash .. e
    elseif start_num == end_num then
      new = ""
    elseif not format or U.len(end_num) > U.len(start_num) then
      new = sep .. e
    else
      local f = PRANGE_FORMATTERS[format]
      if not f then
        error(string.format("Unknown page range format: %s", tostring(format)), 0)
      end
      new = sep .. f(start_num, fill_copy(end_num, start_num), end_pref)
    end
    local match_end = md:e(0)
    if new ~= old then
      local old_len = U.len(old)
      local head = U.from_codepoints(cps, 1, match_end - old_len)
      local rest = U.from_codepoints(cps, match_end + 1, #cps)
      local new_cps = U.codepoints(head .. new)
      pos = #new_cps
      cps = U.codepoints(head .. new .. rest)
    else
      pos = match_end
    end
  end
  return U.from_codepoints(cps)
end

---------------------------------------------------------------------------
-- Sort keys
---------------------------------------------------------------------------

local function fill_left(s, len)
  s = s or ""
  local l = U.len(s)
  if l >= len then
    return s
  end
  return string.rep("0", len - l) .. s
end

local function date_as_key(d)
  if not d then
    return ""
  end
  return U.num_str(5000 + (d.year or 0)) .. fill_left(U.num_str(d.month or 0), 2) .. fill_left(U.num_str(d.day or 0), 2)
end

local function name_var_key(var, ctx)
  return rt.to_plain(rt.render_affixes(render_var(var, {
    { "form", "long" },
    { "name-as-sort-order", "all" },
    { "et-al-min", nil },
    { "et-al-use-first", "0" },
    { "delimiter", "; " },
  }, nil, nil, false, false, nil, ctx)))
end

function E.key(attrs, ctx)
  local macro = aget(attrs, "macro")
  local var = aget(attrs, "variable")
  local global = U.afilter(attrs, function(p)
    return p[1] == "names-min" or p[1] == "names-use-first" or p[1] == "names-use-last"
  end)
  if var then
    if rt.NUMBER_VAR_SET[var] then
      return fill_left(M.number_var_value(M.var_value(var, ctx), var, "numeric", ctx), 5)
    elseif rt.DATE_VAR_SET[var] then
      local dates = M.var_value(var, ctx) or {}
      local key = date_as_key(dates[1])
      if dates[2] then
        key = key .. "–" .. date_as_key(dates[2])
      end
      return key
    elseif rt.NAME_VAR_SET[var] then
      return name_var_key(var, ctx)
    end
    return rt.to_plain(M.var_value(var, ctx))
  end
  local new_ctx = {
    vars = ctx.vars,
    macros = ctx.macros,
    terms = ctx.terms,
    date_text = ctx.date_text,
    date_numeric = ctx.date_numeric,
    opts = U.concat(global, ctx.opts),
    mode = ctx.mode,
    render_mode = "sort",
    render_year_suffix = nil,
  }
  return M.macro_output_as_text(macro, new_ctx)
end

function E.sort(_, _, body)
  local out = {}
  for i = 1, body.n or #body do
    out[i] = body[i]
  end
  return out
end

--- citeproc-sort--compare-keys
function M.compare_keys(k1, k2, desc)
  if k1 == k2 then
    return 0
  elseif U.blank(k1) then
    return -1
  elseif U.blank(k2) then
    return 1
  end
  return (k1 < k2 and 1 or -1) * (desc and -1 or 1)
end

--- citeproc-lib-lex-compare with citeproc-sort--compare-keys
function M.compare_keylists(l1, l2, orders)
  local result
  local i = 1
  local has_orders = orders ~= nil and #orders > 0
  while i <= #(l1 or {}) and not result do
    local desc = has_orders and not orders[i] or false
    local c = M.compare_keys(l1[i], l2 and l2[i], desc)
    if c ~= 0 then
      result = c
    end
    i = i + 1
  end
  return result == 1
end

--- citeproc-sort--render-keys
function M.render_keys(style, vars, mode)
  local ctx = M.context_create(vars, style, mode, "sort")
  local sort = mode == "cite" and style.cite_sort or style.bib_sort
  if sort then
    return sort(ctx)
  end
  return nil
end

---------------------------------------------------------------------------
-- Compilation
---------------------------------------------------------------------------

compile = function(tree)
  if type(tree) ~= "table" then
    return function()
      return tree
    end
  end
  local tag = tree.tag
  local attrs = tree.attrs or {}
  if tag == "names" then
    return compile_names(tree)
  end
  local kids = {}
  for _, c in ipairs(tree) do
    kids[#kids + 1] = compile(c)
  end
  local function eval_kids(ctx)
    local out = { n = #kids }
    for i, k in ipairs(kids) do
      local v = k(ctx)
      if v == nil then
        v = false
      end
      out[i] = v
    end
    return out
  end
  if tag == "choose" then
    return function(ctx)
      local vals = eval_kids(ctx)
      for i = 1, vals.n do
        local v = vals[i]
        if type(v) == "table" and v.ok then
          return v.value
        end
      end
      return typed(nil, "text-only")
    end
  elseif tag == "if" or tag == "else-if" then
    return function(ctx)
      if M.eval_conditions(attrs, ctx) then
        return { ok = true, value = add_splice_tag(splice_into(eval_kids(ctx))) }
      end
      return false
    end
  elseif tag == "else" then
    return function(ctx)
      return { ok = true, value = add_splice_tag(splice_into(eval_kids(ctx))) }
    end
  end
  local fn = E[tag]
  if not fn then
    error(string.format("Unsupported CSL element: %s", tostring(tag)), 0)
  end
  return function(ctx)
    return fn(attrs, ctx, eval_kids(ctx))
  end
end
M.compile = compile

return M

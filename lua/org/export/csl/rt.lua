---@mod org.export.csl.rt Rich text (port of citeproc-rt.el)
---
--- A rich text is nil/false, a string, or a node `{ attrs, content... }`
--- where `attrs` is an association list (an empty table is Emacs nil,
--- `{ false }` is Emacs `(nil)`) and missing contents are `false`.

local U = require("org.export.csl.util")
local R = require("org.export.csl.regex")
local X = require("org.export.csl.xml")

local M = {}

M.FORMAT_ATTRS = {
  "font-variant",
  "font-style",
  "font-weight",
  "text-decoration",
  "vertical-align",
  "font-variant",
  "display",
  "rendered-var",
  "name-id",
  "quotes",
  "cited-item-no",
  "bib-item-no",
  "rendered-names",
  "href",
  "stopped-rendering",
  "rendered-locator-label",
}
M.EXT_FORMAT_ATTRS = U.concat({ "prefix", "suffix", "delimiter", "subst", "quotes" }, M.FORMAT_ATTRS)

M.DATE_VARS = { "accessed", "available-date", "event-date", "issued", "original-date", "submitted", "locator-date" }
M.NAME_VARS = {
  "author",
  "chair",
  "collection-editor",
  "compiler",
  "composer",
  "container-author",
  "contributor",
  "curator",
  "director",
  "editor",
  "editorial-director",
  "editor-translator",
  "executive-producer",
  "guest",
  "host",
  "illustrator",
  "interviewer",
  "narrator",
  "organizer",
  "original-author",
  "performer",
  "producer",
  "recipient",
  "reviewed-author",
  "script-writer",
  "series-creator",
  "translator",
}
M.NUMBER_VARS = {
  "chapter-number",
  "citation-number",
  "collection-number",
  "edition",
  "first-reference-note-number",
  "issue",
  "number",
  "number-of-pages",
  "number-of-volumes",
  "page",
  "page-first",
  "part-number",
  "printing-number",
  "section",
  "supplement-number",
  "version",
  "volume",
}
M.LINKED_VARS = { "DOI", "PMCID", "PMID", "URL" }
M.LINK_PREFIX = {
  DOI = "https://doi.org/",
  PMID = "https://www.ncbi.nlm.nih.gov/pubmed/",
  PMCID = "https://www.ncbi.nlm.nih.gov/pmc/articles/",
}
M.DATE_VAR_SET = U.set(M.DATE_VARS)
M.NAME_VAR_SET = U.set(M.NAME_VARS)
M.NUMBER_VAR_SET = U.set(M.NUMBER_VARS)

---------------------------------------------------------------------------
-- Basics
---------------------------------------------------------------------------

local function node_p(x)
  return type(x) == "table"
end
M.node_p = node_p

--- listp: nil or a node
local function listp(x)
  return x == nil or x == false or type(x) == "table"
end
M.listp = listp

--- (cons attrs contents)
local function mk(attrs, contents)
  local n = { attrs or {} }
  for i = 1, #(contents or {}) do
    n[i + 1] = contents[i]
  end
  -- keep explicit holes
  if contents and contents.n then
    for i = 1, contents.n do
      if contents[i] == nil then
        n[i + 1] = false
      end
    end
  end
  return n
end
M.mk = mk

--- (cdr rt) as an array
local function contents(rt)
  local out = {}
  if node_p(rt) then
    for i = 2, #rt do
      out[#out + 1] = rt[i]
    end
  end
  return out
end
M.contents = contents

--- (car rt)
function M.attrs(rt)
  if node_p(rt) then
    return rt[1]
  end
  return nil
end

--- The first content element (citeproc-rt-first-content).
function M.first_content(rt)
  if node_p(rt) then
    return rt[2]
  end
  return rt
end

--- Is the attribute list Emacs nil (as opposed to `(nil)` or a real list)?
local function attrs_nil(a)
  return a == nil or #a == 0
end
M.attrs_nil = attrs_nil

local aget = U.aget

--- citeproc-rt-to-plain
function M.to_plain(rt)
  if rt == nil or rt == false then
    return ""
  end
  if node_p(rt) then
    local out = {}
    for i = 2, #rt do
      out[#out + 1] = M.to_plain(rt[i])
    end
    return table.concat(out)
  end
  return tostring(rt)
end

--- citeproc-rt-select-attrs
function M.select_attrs(attrs, keep)
  local set = U.set(keep)
  local out = {}
  for _, p in ipairs(attrs or {}) do
    if type(p) == "table" and set[p[1]] then
      out[#out + 1] = p
    end
  end
  return out
end

local function is_string(x)
  return type(x) == "string"
end

--- citeproc-rt-join-strings on a node's contents
local function join_strings(rt)
  if not node_p(rt) then
    return rt
  end
  local out = { rt[1] }
  for i = 2, #rt do
    local x = rt[i]
    if is_string(x) and is_string(out[#out]) and #out > 1 then
      out[#out] = out[#out] .. x
    else
      out[#out + 1] = x
    end
  end
  return out
end
M.join_strings = join_strings

--- citeproc-rt-formatting-empty-p
local function formatting_empty_p(rt)
  if not node_p(rt) then
    return false
  end
  local a = rt[1]
  local first = a[1]
  if not first then
    return true
  end
  return first[1] == "delimiter" and #a == 1 and #rt == 2
end
M.formatting_empty_p = formatting_empty_p

--- citeproc-rt-splice-unformatted
local function splice_unformatted(rt)
  if node_p(rt) and not aget(rt[1], "delimiter") then
    local out = { rt[1] }
    for i = 2, #rt do
      local it = rt[i]
      if formatting_empty_p(it) then
        for j = 2, #it do
          out[#out + 1] = it[j]
        end
      else
        out[#out + 1] = it
      end
    end
    return out
  end
  return rt
end
M.splice_unformatted = splice_unformatted

--- citeproc-rt-reduce-content
local function reduce_content(rt)
  if not node_p(rt) then
    return rt
  end
  if #rt < 2 then
    return nil
  end
  if attrs_nil(rt[1]) and #rt == 2 then
    local c = rt[2]
    if c == false then
      return nil
    end
    return c
  end
  return rt
end
M.reduce_content = reduce_content

function M.simplify_shallow(rt)
  return reduce_content(join_strings(splice_unformatted(rt)))
end

function M.simplify_deep(rt)
  if not node_p(rt) then
    return rt
  end
  local n = { rt[1] }
  for i = 2, #rt do
    local s = M.simplify_deep(rt[i])
    if s == nil then
      s = false
    end
    n[i] = s
  end
  return reduce_content(join_strings(splice_unformatted(n)))
end

--- citeproc-rt-format
function M.format(rt, fun, skip_nocase)
  if rt == nil or rt == false then
    return nil
  end
  if node_p(rt) then
    if skip_nocase and aget(rt[1], "nocase") then
      return rt
    end
    local n = { rt[1] }
    for i = 2, #rt do
      local v = M.format(rt[i], fun, skip_nocase)
      if v == nil then
        v = false
      end
      n[i] = v
    end
    return n
  end
  return fun(rt)
end

--- citeproc-rt-map-strings (on a list of rich texts)
function M.map_strings(fun, rts, skip_nocase)
  local out = {}
  for i = 1, #rts do
    local v = M.format(rts[i], fun, skip_nocase)
    if v == nil then
      v = false
    end
    out[i] = v
  end
  return out
end

function M.replace_all_sim(replacements, regex, rts)
  return M.map_strings(function(x)
    return R.replace(regex, function(match)
      for _, p in ipairs(replacements) do
        if p[1] == match then
          return p[2]
        end
      end
      return match
    end, x, { case_fold = true })
  end, rts)
end

function M.strip_periods(rts)
  return M.map_strings(function(x)
    return U.replace(".", "", x)
  end, rts)
end

--- citeproc-rt-length (characters)
function M.length(rt)
  if rt == nil or rt == false then
    return 0
  end
  if node_p(rt) then
    local n = 0
    for i = 2, #rt do
      n = n + M.length(rt[i])
    end
    return n
  end
  return U.len(tostring(rt))
end

local function update_from_plain_1(rt, p, start, skip_nocase)
  if rt == nil or rt == false then
    return nil, start
  end
  if node_p(rt) then
    if skip_nocase and aget(rt[1], "nocase") then
      return rt, start + M.length(rt)
    end
    local act = start
    local n = { rt[1] }
    for i = 2, #rt do
      local updated
      updated, act = update_from_plain_1(rt[i], p, act, skip_nocase)
      if updated == nil then
        updated = false
      end
      n[i] = updated
    end
    return n, act
  end
  local e = start + U.len(tostring(rt))
  if e > #p then
    error("Args out of range in citeproc-rt-update-from-plain", 0)
  end
  return U.from_codepoints(p, start + 1, e), e
end

--- citeproc-rt-update-from-plain
function M.update_from_plain(rt, plain, skip_nocase)
  local r = update_from_plain_1(rt, U.codepoints(plain), 0, skip_nocase)
  return r
end

--- citeproc-rt-change-case
function M.change_case(rt, case_fun)
  local plain = M.to_plain(rt)
  return M.update_from_plain(rt, case_fun(plain), true)
end

---------------------------------------------------------------------------
-- Italics flip-flop
---------------------------------------------------------------------------

local function in_italics_p(rt)
  return node_p(rt) and aget(rt[1], "font-style") == "italic"
end
M.in_italics_p = in_italics_p

local function pred_counts_tree(rt, pred)
  if node_p(rt) then
    local children = {}
    local max
    for i = 2, #rt do
      local cv = pred_counts_tree(rt[i], pred)
      children[#children + 1] = cv
      local count = type(cv) == "table" and cv[1] or cv
      local v = count + (pred(rt[i]) and 1 or 0)
      if max == nil or v > max then
        max = v
      end
    end
    max = max or 0
    local out = { max }
    for _, c in ipairs(children) do
      out[#out + 1] = c
    end
    return out
  end
  return 0
end

local function flip_italics(rt)
  if listp(rt) and rt then
    if in_italics_p(rt) then
      local n = { U.aremove(rt[1], "font-style") }
      for i = 2, #rt do
        n[i] = rt[i]
      end
      return n
    end
    local n = { U.acons("font-style", "italic", rt[1]) }
    for i = 2, #rt do
      n[i] = rt[i]
    end
    return n
  elseif rt == nil or rt == false then
    return { { { "font-style", "italic" } } }
  end
  return { { { "font-style", "italic" } }, rt }
end

local function flipflop_1(rt, tree)
  local rt_italic = in_italics_p(rt)
  if not listp(rt) or type(tree) ~= "table" or (tree[1] + (rt_italic and 1 or 0)) < 2 then
    return rt
  end
  if rt == nil or rt == false then
    return rt
  end
  if rt_italic then
    local n = { U.aremove(rt[1], "font-style") }
    for i = 2, #rt do
      n[i] = flipflop_1(flip_italics(rt[i]), tree[i])
    end
    return n
  end
  local n = { rt[1] }
  for i = 2, #rt do
    n[i] = flipflop_1(rt[i], tree[i])
  end
  return n
end

function M.italics_flipflop(rt)
  if rt and node_p(rt) and #rt > 1 then
    local tree = pred_counts_tree(rt, in_italics_p)
    if tree[1] + (in_italics_p(rt) and 1 or 0) > 1 then
      return flipflop_1(rt, tree)
    end
  end
  return rt
end

---------------------------------------------------------------------------
-- HTML input
---------------------------------------------------------------------------

local FROM_HTML = {
  { "i", nil, { "font-style", "italic" } },
  { "b", nil, { "font-weight", "bold" } },
  { "span", { { "style", "font-variant:small-caps;" } }, { "font-variant", "small-caps" } },
  { "sc", nil, { "font-variant", "small-caps" } },
  { "sup", nil, { "vertical-align", "sup" } },
  { "sub", nil, { "vertical-align", "sub" } },
  { "span", { { "class", "nocase" } }, { "nocase", true } },
  { "span", { { "class", "underline" } }, { "text-decoration", "underline" } },
}

local function attrs_equal(a, b)
  a, b = a or {}, b or {}
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i][1] ~= b[i][1] or a[i][2] ~= b[i][2] then
      return false
    end
  end
  return true
end

local function from_html(h)
  if type(h) == "table" then
    local attr
    for _, e in ipairs(FROM_HTML) do
      if e[1] == h.tag and attrs_equal(e[2], h.attrs) then
        attr = e[3]
        break
      end
    end
    local n = { attr and { { attr[1], attr[2] } } or { false } }
    for _, c in ipairs(h) do
      n[#n + 1] = from_html(c)
    end
    return n
  end
  return h
end

--- citeproc-rt-from-str
function M.from_str(s)
  if type(s) == "string" and R.test("</[[:alnum:]]+>", s) then
    local stripped = X.parse_html_fragment(s)
    if #stripped == 1 then
      return from_html(stripped[1])
    end
    local n = { {} }
    for _, c in ipairs(stripped) do
      n[#n + 1] = from_html(c)
    end
    return n
  end
  return s
end

---------------------------------------------------------------------------
-- Punctuation in quotes
---------------------------------------------------------------------------

local function cquote_pstns_1(rt, offset)
  if listp(rt) then
    local pstns = {}
    local act = offset
    if rt then
      for i = 2, #rt do
        local p, nxt = cquote_pstns_1(rt[i], act)
        for _, x in ipairs(p) do
          pstns[#pstns + 1] = x
        end
        act = nxt
      end
    end
    if rt and aget(rt[1], "quotes") == "true" then
      table.insert(pstns, 1, act - 1)
    end
    return pstns, act
  end
  return {}, offset + U.len(tostring(rt))
end

function M.punct_in_quote(rt)
  local pstns = cquote_pstns_1(rt, 1)
  if #pstns == 0 then
    return rt
  end
  table.sort(pstns, function(a, b)
    return a > b
  end)
  local cps = U.codepoints(M.to_plain(rt))
  for _, pos in ipairs(pstns) do
    -- point at pos + 1 (1-based buffer): char after is cps[pos + 1]
    local after = cps[pos + 1]
    if (after == 44 or after == 46) and pos >= 1 then
      cps[pos], cps[pos + 1] = cps[pos + 1], cps[pos]
    end
  end
  return M.update_from_plain(rt, U.from_codepoints(cps))
end

---------------------------------------------------------------------------
-- Tree search and transformation
---------------------------------------------------------------------------

function M.find_first_node(rt, pred)
  if pred(rt) then
    return rt
  end
  if node_p(rt) then
    for i = 2, #rt do
      local found = M.find_first_node(rt[i], pred)
      if found then
        return found
      end
    end
  end
  return nil
end

--- citeproc-rt-transform-first: returns result, success
function M.transform_first(rt, pred, transform)
  if pred(rt) then
    return transform(rt), true
  end
  if node_p(rt) then
    local success = false
    local n = { rt[1] }
    for i = 2, #rt do
      if success then
        n[i] = rt[i]
      else
        local r, s = M.transform_first(rt[i], pred, transform)
        if r == nil then
          r = false
        end
        n[i] = r
        success = s
      end
    end
    return n, success
  end
  return rt, false
end

function M.add_year_suffix(rt, ys)
  return M.transform_first(rt, function(node)
    return node_p(node) and M.DATE_VAR_SET[aget(node[1], "rendered-var")] ~= nil
  end, function(node)
    local content = node[2]
    if content == "<suppressed-date>" then
      return { node[1], ys }
    end
    local full = ys
    if type(content) == "string" and not R.test("[[:digit:]]$", content) then
      full = "-" .. ys
    end
    local n = {}
    for i = 1, #node do
      n[i] = node[i]
    end
    n[#n + 1] = { { { "rendered-var", "year-suffix" } }, full }
    return n
  end)
end

function M.replace_first_names(rt, replacement)
  return M.transform_first(rt, function(node)
    return node_p(node) and U.assoc(node[1], "rendered-names") ~= nil
  end, function()
    return replacement
  end)
end

function M.count_names(rt)
  if node_p(rt) then
    if aget(rt[1], "name-id") ~= nil then
      return 1
    end
    local n = 0
    for i = 2, #rt do
      n = n + M.count_names(rt[i])
    end
    return n
  end
  return 0
end

---------------------------------------------------------------------------
-- Spaces and punctuation culling
---------------------------------------------------------------------------

local DEL = "\127"

--- citeproc-s-cull-spaces-puncts (replacements keep the length, using
--- DEL characters that are removed afterwards)
function M.cull_string(s)
  s = U.replace_all_seq(s, {
    { "  ", " " .. DEL },
    { ";;", ";" .. DEL },
    { "...", "." .. DEL .. DEL },
    { ",,", "," .. DEL },
    { "..", "." .. DEL },
  })
  s = R.replace("\\([:;!?]\\):", "\\1" .. DEL, s)
  s = R.replace("\\([:.;!?]\\)\\.", "\\1" .. DEL, s)
  s = R.replace("\\([:;!]\\)!", DEL .. "!", s)
  s = R.replace("\\([:;?]\\)\\?", DEL .. "?", s)
  s = R.replace("\\.\\([”’‹›«»]\\)\\.", ".\\1" .. DEL, s)
  s = R.replace(",\\([”’‹›«»]\\),", ",\\1" .. DEL, s)
  return s
end

function M.cull_spaces_puncts(rt)
  local plain = M.to_plain(rt)
  local updated = M.update_from_plain(rt, M.cull_string(plain))
  return M.format(updated, function(x)
    return (x:gsub(DEL .. "+", ""))
  end)
end

---------------------------------------------------------------------------
-- Affixes, deduplication, finalization
---------------------------------------------------------------------------

function M.render_affixes(rt, shallow)
  if not node_p(rt) then
    return rt
  end
  local attrs = rt[1]
  local rendered = {}
  for i = 2, #rt do
    if shallow then
      rendered[#rendered + 1] = rt[i]
    else
      local r = M.render_affixes(rt[i])
      if r ~= nil and r ~= false then
        rendered[#rendered + 1] = r
      end
    end
  end
  if #rendered == 0 then
    return nil
  end
  local delimiter = aget(attrs, "delimiter")
  local prefix = aget(attrs, "prefix")
  local suffix = aget(attrs, "suffix")
  local display = aget(attrs, "display")
  local delimited
  if delimiter then
    delimited = {}
    for k, r in ipairs(rendered) do
      if k > 1 then
        delimited[#delimited + 1] = delimiter
      end
      delimited[#delimited + 1] = r
    end
  else
    delimited = rendered
  end
  if suffix or prefix then
    local outer = {}
    local inner = M.select_attrs(attrs, M.FORMAT_ATTRS)
    if display then
      outer = { { "display", display } }
      inner = U.aremove(inner, "display")
    end
    local out = { outer }
    if prefix then
      out[#out + 1] = prefix
    end
    out[#out + 1] = mk(inner, delimited)
    if suffix then
      out[#out + 1] = suffix
    end
    return out
  end
  return mk(M.select_attrs(attrs, M.FORMAT_ATTRS), delimited)
end

local dedup_multi

local function dedup_single(rt, substs)
  if not node_p(rt) then
    return rt, {}, {}
  end
  local attrs = rt[1]
  local subst = aget(attrs, "subst")
  local var = aget(attrs, "rendered-var")
  if var then
    for _, s in ipairs(substs) do
      if s == var then
        return nil, {}, {}
      end
    end
  end
  local new_c, s, v = dedup_multi(contents(rt), substs)
  local new_attrs = U.afilter(attrs, function(p)
    return not (type(p) == "table" and (p[1] == "subst" or p[1] == "rendered-vars"))
  end)
  local out = { new_attrs }
  for i = 1, new_c.n or #new_c do
    local x = new_c[i]
    if x == nil then
      x = false
    end
    out[#out + 1] = x
  end
  local vs = U.concat(v, var and { var } or nil)
  if subst then
    return out, vs, vs
  end
  return out, s, vs
end

dedup_multi = function(cs, substs)
  local out = { n = 0 }
  local all_s, all_v = {}, {}
  local cur_substs = substs
  for i = 1, #cs do
    local c, s1, v1 = dedup_single(cs[i], cur_substs)
    out.n = out.n + 1
    out[out.n] = c
    cur_substs = U.concat(cur_substs, s1)
    all_s = U.concat(all_s, s1)
    all_v = U.concat(all_v, v1)
  end
  return out, all_s, all_v
end

--- citeproc-rt-dedup
function M.dedup(rt)
  local r = dedup_single(rt, {})
  return r
end

--- citeproc-rt-finalize
function M.finalize(rt, punct_in_quote)
  local r = rt
  if punct_in_quote then
    r = M.punct_in_quote(r)
  end
  r = M.simplify_deep(M.italics_flipflop(r))
  return M.format(r, function(x)
    return U.replace("ʼ", "’", x)
  end)
end

local function attr_values(r, attr)
  if not node_p(r) then
    return {}
  end
  local out = {}
  local val = aget(r[1], attr)
  if val ~= nil then
    out[1] = val
  end
  for i = 2, #r do
    for _, x in ipairs(attr_values(r[i], attr)) do
      out[#out + 1] = x
    end
  end
  return out
end

function M.rendered_name_ids(r)
  return attr_values(r, "name-id")
end

function M.rendered_vars(r)
  return attr_values(r, "rendered-var")
end

function M.rendered_date_vars(r)
  local out = {}
  for _, v in ipairs(M.rendered_vars(r)) do
    if M.DATE_VAR_SET[v] then
      out[#out + 1] = v
    end
  end
  return out
end

function M.rendered_name_vars(r)
  local out = {}
  for _, v in ipairs(M.rendered_vars(r)) do
    if M.NAME_VAR_SET[v] then
      out[#out + 1] = v
    end
  end
  return out
end

--- Structural equality (Emacs `equal`) of rich texts and values.
function M.equal(a, b)
  if a == b then
    return true
  end
  if (a == nil or a == false) and (b == nil or b == false) then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  local na, nb = #a, #b
  if na ~= nb then
    return false
  end
  for i = 1, na do
    if not M.equal(a[i], b[i]) then
      return false
    end
  end
  for k, v in pairs(a) do
    if type(k) ~= "number" and not M.equal(v, b[k]) then
      return false
    end
  end
  for k, v in pairs(b) do
    if type(k) ~= "number" and not M.equal(v, a[k]) then
      return false
    end
  end
  return true
end

function M.subsequent_author_substitute(bib, s)
  local prev
  local out = {}
  for i, it in ipairs(bib) do
    local author = M.find_first_node(it, function(x)
      return node_p(x) and U.assoc(x[1], "rendered-names") ~= nil
    end)
    if M.equal(author, prev) then
      out[i] = (M.replace_first_names(it, s))
    else
      out[i] = it
      prev = author
    end
  end
  return out
end

--- citeproc-rt-link-title: adds an href to the rendered title in place.
function M.link_title(r, target)
  M.transform_first(r, function(node)
    return node_p(node) and aget(node[1], "rendered-var") == "title"
  end, function(node)
    node[1] = U.acons("href", target, node[1])
    return node[1]
  end)
end

local function locator_p(r)
  return node_p(r) and aget(r[1], "rendered-var") == "locator"
end

local function locator_label_p(r)
  return node_p(r) and aget(r[1], "rendered-locator-label")
end

function M.add_locator_label_position(r)
  local result
  if not node_p(r) then
    result = nil
  elseif locator_p(r) then
    result = "locator"
  elseif locator_label_p(r) then
    result = "label"
  else
    local first, second
    local i = 2
    while i <= #r and not (first and second) do
      local cur = r[i]
      i = i + 1
      local order = M.add_locator_label_position(cur)
      if order == "label-first" then
        first, second = "label", "locator"
      elseif order == "locator-first" then
        first, second = "locator", "label"
      elseif order == "label-only" or order == "label" then
        if first then
          second = "label"
        else
          first = "label"
        end
      elseif order == "locator-only" or order == "locator" then
        if first then
          second = "locator"
        else
          first = "locator"
        end
      end
    end
    if not first then
      result = nil
    elseif not second then
      result = first == "locator" and "locator-only" or "label-only"
    else
      result = first == "locator" and "locator-first" or "label-first"
    end
  end
  if result then
    r[1] = U.acons("l-l-pos", result, r[1])
  end
  return result
end

local function locator_w_label_1(r, llpos)
  if locator_label_p(r) or locator_p(r) then
    return r
  end
  local attrs = r[1]
  local local_llpos = aget(attrs, "l-l-pos")
  local out = { attrs }
  local nb = 0
  if (llpos == "locator-first" and local_llpos == "label-only") or (llpos == "label-first" and local_llpos == "locator-only") then
    nb = 1
  end
  local i = 2
  while i <= #r and nb < 2 do
    local cur = r[i]
    i = i + 1
    local cur_ll = node_p(cur) and aget(cur[1], "l-l-pos")
    if cur_ll then
      if llpos == "locator-only" or cur_ll == "label-first" or cur_ll == "locator-first" then
        nb = nb + 2
      else
        nb = nb + 1
      end
      out[#out + 1] = locator_w_label_1(cur, llpos)
    elseif nb == 1 then
      out[#out + 1] = cur
    end
  end
  return out
end

function M.locator_w_label(r)
  local ll = M.add_locator_label_position(r)
  if ll then
    return locator_w_label_1(r, ll)
  end
  return r
end

return M

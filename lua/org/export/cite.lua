---@mod org.export.cite Citations in export (port of Emacs oc.el export
--- parts and the oc-basic, oc-natbib, oc-biblatex and oc-bibtex processors)
---
--- The engine calls `store` once the export options are known, `process`
--- once the parse tree is complete (citations and #+PRINT_BIBLIOGRAPHY
--- keywords are replaced with the processor's output, as raw strings), and
--- `finalize` on the final output.

local ox = require("org.export.ox")
local element = require("org.export.element")
local utils = require("org.utils")

local M = {}

local fmt = string.format
local nw = ox.nw
local trim = ox.trim

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------

local function ccfg()
  return ((require("org.config").opts.export or {}).cite) or {}
end

local function opt(name, default)
  local v = ccfg()[name]
  if v == nil then
    return default
  end
  return v
end

M.DEFAULT_NOTE_RULES = {
  ["en-us"] = { "inside", "outside", "after" },
  fr = { "adaptive", "same", "before" },
}

M.DEFAULT_REGION = {
  af = "za",
  ca = "ad",
  cs = "cz",
  cy = "gb",
  da = "dk",
  el = "gr",
  et = "ee",
  fa = "ir",
  he = "ir",
  ja = "jp",
  km = "kh",
  ko = "kr",
  nb = "no",
  nn = "no",
  sl = "si",
  sr = "rs",
  sv = "se",
  uk = "ua",
  vi = "vn",
  zh = "cn",
}

M.BIBLATEX_STYLES = {
  { "author", "caps", "Citeauthor*", nil, false },
  { "author", "full", "citeauthor", nil, false },
  { "author", "caps-full", "Citeauthor", nil, false },
  { "author", nil, "citeauthor*", nil, false },
  { "locators", "bare", "notecite", nil, false },
  { "locators", "caps", "Pnotecite", nil, false },
  { "locators", "bare-caps", "Notecite", nil, false },
  { "locators", nil, "pnotecite", nil, false },
  { "noauthor", "bare", "cite*", nil, false },
  { "noauthor", nil, "autocite*", nil, false },
  { "nocite", nil, "nocite", nil, true },
  { "text", "caps", "Textcite", "Textcites", false },
  { "text", nil, "textcite", "textcites", false },
  { nil, "bare", "cite", "cites", false },
  { nil, "caps", "Autocite", "Autocites", false },
  { nil, "bare-caps", "Cite", "Cites", false },
  { nil, nil, "autocite", "autocites", false },
}

M.BIBLATEX_SHORTCUTS = {
  a = "author",
  b = "bare",
  bc = "bare-caps",
  c = "caps",
  cf = "caps-full",
  f = "full",
  l = "locators",
  n = "nocite",
  na = "noauthor",
  t = "text",
}

---------------------------------------------------------------------------
-- Tree helpers
---------------------------------------------------------------------------

local function text(s)
  return element.text(s, nil)
end

local function raw(s)
  return { type = "raw", value = s, contents = {}, post_blank = 0 }
end
M.raw = raw

local function index_in(list, node)
  for i, x in ipairs(list or {}) do
    if x == node then
      return i
    end
  end
end

local function insert_before(new, node)
  local list = element.siblings(node)
  local i = index_in(list, node)
  if not i then
    return
  end
  new.parent = node.parent
  table.insert(list, i, new)
end

local function replace_node(old, new)
  local list = element.siblings(old)
  local i = index_in(list, old)
  if i then
    new.parent = old.parent
    list[i] = new
  end
end

local function adopt(parent, node)
  node.parent = parent
  parent.contents = parent.contents or {}
  parent.contents[#parent.contents + 1] = node
end

--- org-cite--set-post-blank
local function set_post_blank(datum, blanks)
  if datum.type == "plain-text" then
    datum.value = datum.value:gsub("[ \t\n]+$", "") .. string.rep(" ", blanks)
  else
    datum.post_blank = blanks
  end
end

local function set_previous_post_blank(datum, blanks, info)
  local prev = ox.get_previous_element(datum, info)
  if prev then
    set_post_blank(prev, blanks)
  end
end

--- org-cite-concat: flatten strings, nodes and secondary strings.
function M.concat(...)
  local out = {}
  local n = select("#", ...)
  for i = 1, n do
    local d = select(i, ...)
    if d == nil or d == false then
      -- skip
    elseif type(d) == "string" then
      out[#out + 1] = text(d)
    elseif d.type ~= nil then
      out[#out + 1] = d
    else
      for _, x in ipairs(d) do
        if type(x) == "string" then
          out[#out + 1] = text(x)
        else
          out[#out + 1] = x
        end
      end
    end
  end
  return out
end

function M.mapconcat(fn, data, sep)
  if not data or #data == 0 then
    return nil
  end
  local result = M.concat(fn(data[1]))
  for i = 2, #data do
    result = M.concat(result, sep, fn(data[i]))
  end
  return result
end

local function make_node(type, contents)
  local n = { type = type, contents = contents, post_blank = 0 }
  for _, c in ipairs(contents) do
    c.parent = n
  end
  return n
end

function M.emphasize(type, ...)
  return make_node(type, M.concat(...))
end

function M.make_paragraph(...)
  return make_node("paragraph", M.concat(...))
end

--- Emacs `capitalize`: first letter of each word upper case, the rest lower.
local function capitalize_string(s)
  return (s:gsub("([%w\128-\255])([%w\128-\255]*)", function(a, b)
    return a:upper() .. b:lower()
  end))
end

function M.capitalize(str)
  if type(str) == "string" then
    return capitalize_string(str)
  elseif str and str.type == "raw" then
    return raw(capitalize_string(str.value))
  end
  error("must be either a string or raw string object")
end

---------------------------------------------------------------------------
-- Generic tools (oc.el)
---------------------------------------------------------------------------

function M.get_references(citation, keys_only)
  if keys_only then
    local keys = {}
    for i, r in ipairs(citation.contents) do
      keys[i] = r.key
    end
    return keys
  end
  return citation.contents
end

function M.main_affixes(citation)
  local refs = M.get_references(citation)
  local source = #refs == 1 and refs[1] or citation
  return source.prefix, source.suffix
end

local function not_nil(s)
  if s == nil or s == "nil" then
    return nil
  end
  return s
end

--- Style pair { name, variant } of a citation (org-cite-citation-style).
function M.citation_style(citation, info)
  local function separate(s)
    if s == nil then
      return nil, nil
    end
    local a, b = s:match("^(.-)/(.*)$")
    if not a then
      return s, nil
    end
    return a, nw(b)
  end
  local ln, lv = separate(citation.style)
  local ce = info.cite_export
  local gn, gv = separate(type(ce) == "table" and ce[3] or nil)
  if nw(ln) then
    return { not_nil(ln), lv }
  end
  return { not_nil(gn), lv or gv }
end

--- Read a "#+CITE_EXPORT" declaration (org-cite-read-processor-declaration).
function M.read_processor_declaration(s)
  local tokens = {}
  local pos = 1
  while true do
    local ws = s:match("^[ \t]*", pos)
    pos = pos + #ws
    if pos > #s then
      break
    end
    local tok
    if s:sub(pos, pos) == '"' then
      local close = s:find('"', pos + 1, true)
      if not close then
        error(fmt("Invalid cite export processor declaration: %q", s), 0)
      end
      tok = s:sub(pos + 1, close - 1)
      pos = close + 1
    else
      tok = s:match("^[^ \t]+", pos)
      pos = pos + #tok
    end
    tokens[#tokens + 1] = tok
  end
  if #tokens == 0 then
    return nil
  end
  if #tokens > 3 then
    error(fmt("Trailing garbage following cite export processor declaration %q", s), 0)
  end
  return { tokens[1], not_nil(tokens[2]), not_nil(tokens[3]) }
end

--- Processors available for export.
M.processors = {}

local function normalize_triplet(p)
  if type(p) == "string" then
    return { p, nil, nil }
  end
  if type(p) == "table" then
    return { p[1], p[2], p[3] }
  end
end

--- org-cite-store-export-processor
function M.store_export_processor(info)
  local value = info.cite_export
  local processor
  if value == nil or value == "" then
    value = opt("export_processors", { t = { "basic" } })
  end
  if value == false or value == "" then
    processor = nil
  elseif type(value) == "string" then
    processor = M.read_processor_declaration(value)
  elseif type(value) == "table" then
    if value[1] ~= nil and type(value[1]) == "string" then
      -- a single triplet
      processor = normalize_triplet(value)
    else
      local backend = info.back_end
      local candidates = {}
      for key, p in pairs(value) do
        if key ~= "t" and key ~= true and ox.derived_backend_p(backend, key) then
          candidates[#candidates + 1] = { key, p }
        end
      end
      table.sort(candidates, function(a, b)
        if a[1] == b[1] then
          return false
        end
        return ox.derived_backend_p(a[1], b[1])
      end)
      local chosen = candidates[1] and candidates[1][2] or value.t or value[true]
      processor = chosen and normalize_triplet(chosen) or nil
    end
  end
  if processor then
    local name = processor[1]
    if not M.processors[name] then
      error(fmt("Unknown processor %s", name), 0)
    end
    if not M.processors[name].export_citation then
      error(fmt("Processor %s is unable to handle citation export", name), 0)
    end
  end
  info.cite_export = processor
end

--- org-cite-list-bibliography-files: file names as written (relative
--- names are relative to the exported file's directory).
function M.list_bibliography_files(info)
  local files, seen = {}, {}
  local function add(f)
    if f and f ~= "" and not seen[f] then
      seen[f] = true
      files[#files + 1] = f
    end
  end
  for _, v in ipairs((info.keywords or {}).BIBLIOGRAPHY or {}) do
    add((trim(v):gsub('^"(.*)"$', "%1")))
  end
  for _, f in ipairs(opt("global_bibliography", {})) do
    add(f)
  end
  return files
end

--- Absolute name of a bibliography file.
function M.bibliography_path(file, info)
  if file:match("^/") or file:match("^~") or file:match("^%a:[/\\]") then
    return vim.fs.normalize(vim.fn.expand(file))
  end
  local dir = info.input_file and vim.fn.fnamemodify(info.input_file, ":p:h") or vim.fn.getcwd()
  return vim.fs.normalize(dir .. "/" .. file)
end

function M.store(info)
  info.bibliography = M.list_bibliography_files(info)
  M.store_export_processor(info)
end

function M.bibliography_style(info)
  local ce = info.cite_export
  return type(ce) == "table" and ce[2] or nil
end

--- Parse a string as a property list (org-cite--parse-as-plist).
function M.parse_as_plist(s)
  if s == nil then
    return nil
  end
  local results = {}
  local pos = 1
  local value_flag = false
  local ws = s:match("^[ \t]*", pos)
  pos = pos + #ws
  while pos <= #s do
    local c = s:sub(pos, pos)
    if c == ":" then
      local tok = s:match("^[^ \t]+", pos)
      results[#results + 1] = { keyword = tok }
      pos = pos + #tok
      value_flag = true
    elseif not value_flag then
      local tok = s:match("^[^ \t]*", pos)
      pos = pos + math.max(#tok, 1)
    elseif c == '"' then
      local close = s:find('"', pos + 1, true)
      if close then
        results[#results + 1] = s:sub(pos + 1, close - 1)
        pos = close + 1
      else
        local tok = s:match("^[^ \t]+", pos)
        results[#results + 1] = tok
        pos = pos + #tok
      end
      value_flag = false
    else
      local tok = s:match("^[^ \t]+", pos)
      results[#results + 1] = tok
      pos = pos + #tok
      value_flag = false
    end
    ws = s:match("^[ \t]*", pos)
    pos = pos + #ws
  end
  return results
end

--- Citations of the document in reading order, following footnotes
--- (org-cite-list-citations).
function M.list_citations(info)
  if info.citations then
    return info.citations
  end
  local cites = {}
  local tree = info.parse_tree
  local defs
  local function find_definition(label)
    defs = defs
      or element.map(tree, "footnote-definition", function(d)
        return d
      end, { ignore = info.ignore })
    for _, d in ipairs(defs) do
      if d.label == label then
        return d.contents
      end
    end
  end
  local function search(data)
    if not data then
      return
    end
    element.map(data, { citation = true, ["footnote-reference"] = true }, function(d)
      if d.type == "citation" then
        cites[#cites + 1] = d
      elseif d.fn_type == "inline" then
        -- traversed by map
      else
        search(find_definition(d.label))
      end
    end, { ignore = info.ignore, no_recursion = { ["footnote-definition"] = true }, with_affiliated = true })
  end
  search(tree)
  info.citations = cites
  return cites
end

function M.list_keys(info)
  local keys, seen = {}, {}
  for _, c in ipairs(M.list_citations(info)) do
    for _, r in ipairs(c.contents) do
      if not seen[r.key] then
        seen[r.key] = true
        keys[#keys + 1] = r.key
      end
    end
  end
  return keys
end

--- Stable sort (Emacs `sort`).
local function stable_sort(list, less)
  local out = vim.list_slice(list)
  for i = 2, #out do
    local v = out[i]
    local j = i - 1
    while j >= 1 and less(v, out[j]) do
      out[j + 1] = out[j]
      j = j - 1
    end
    out[j + 1] = v
  end
  return out
end

function M.key_number(key, info, predicate)
  local keys = M.list_keys(info)
  if predicate then
    keys = stable_sort(keys, predicate)
  end
  for i, k in ipairs(keys) do
    if k == key then
      return i
    end
  end
end

function M.inside_footnote_p(citation, strict)
  local fn = element.lineage(citation, { ["footnote-definition"] = true, ["footnote-reference"] = true })
  if not fn then
    return nil
  end
  if strict then
    local c = citation.parent.contents
    if not (#c == 1 and c[1] == citation) then
      return nil
    end
  end
  return fn
end

--- Wrap an anonymous inline footnote around CITATION (org-cite-wrap-citation).
function M.wrap_citation(citation, info)
  local footnote = {
    type = "footnote-reference",
    label = nil,
    fn_type = "inline",
    post_blank = citation.post_blank or 0,
    contents = {},
  }
  set_previous_post_blank(citation, 0, info)
  insert_before(footnote, citation)
  element.extract(citation)
  adopt(footnote, citation)
  return footnote
end

local function note_rule(info)
  local lang = info.language or "en"
  local parts = vim.split(lang, "[-_]")
  local language, region
  if #parts == 1 then
    language = parts[1]
    region = M.DEFAULT_REGION[language] or language
  elseif #parts == 2 then
    language, region = parts[1], parts[2]
  else
    error(fmt("Invalid language identifier: %s", lang), 0)
  end
  local rules = opt("note_rules", M.DEFAULT_NOTE_RULES)
  return rules[(language .. "-" .. region):lower()] or rules[language:lower()] or { "adaptive", "outside", "after" }
end

--- Match org-cite-adjust-note's previous-punct-re at the end of S.
--- Returns { m0, g1 = {s, e}, g2 = {s, e}, g3 = {s, e} } (1-based, inclusive).
local function previous_punct_match(s, punct)
  local n = #s
  local pos = n
  local r = {}
  local k = pos
  while k >= 1 and s:sub(k, k):match("[ \t\n]") do
    k = k - 1
  end
  if k < pos then
    r.g3 = { k + 1, pos }
  end
  pos = k
  local start = pos + 1
  if pos >= 1 and s:sub(pos, pos) == '"' then
    r.g2 = { pos, pos }
    local q = pos - 1
    while q >= 1 and s:sub(q, q):match("[ \t\n]") do
      q = q - 1
    end
    start = q + 1
    pos = q
  end
  if pos >= 1 and punct[s:sub(pos, pos)] then
    local b = pos - 1
    while b >= 1 and s:sub(b, b):match("[ \t\n]") do
      b = b - 1
    end
    -- blanks before the punctuation belong to group 1 only when the
    -- quote group does not already own them
    r.g1 = { b + 1, pos }
    start = b + 1
  end
  r.m0 = start
  return r
end

local function substr(s, g)
  return s:sub(g[1], g[2])
end

--- org-cite--insert-at-split
local function insert_at_split(s, citation, split)
  local pb = citation.post_blank or 0
  if pb > 0 then
    insert_before(text(string.rep(" ", pb)), citation)
  end
  element.extract(citation)
  citation.post_blank = 0
  insert_before(citation, s)
  local first = s.value:sub(1, split - 1)
  local last = s.value:sub(split):gsub("[ \t\n]+$", "")
  if nw(first) then
    insert_before(text(first), citation)
  end
  s.value = last
end

--- org-cite--move-punct-before
local function move_punct_before(punct, citation, s, info)
  if s.value == punct then
    element.extract(s)
  else
    s.value = s.value:sub(#punct + 1)
  end
  set_previous_post_blank(citation, 0, info)
  insert_before(text(string.rep(" ", citation.post_blank or 0) .. punct), citation)
end

local TERMINALS = {
  citation = true,
  code = true,
  entity = true,
  ["export-snippet"] = true,
  ["footnote-reference"] = true,
  ["line-break"] = true,
  ["latex-fragment"] = true,
  link = true,
  ["plain-text"] = true,
  ["radio-target"] = true,
  ["statistics-cookie"] = true,
  timestamp = true,
  verbatim = true,
}

--- Move the note number and punctuation around a citation (org-cite-adjust-note).
function M.adjust_note(citation, info, rule, punct_list)
  if not opt("adjust_note_numbers", true) then
    return
  end
  rule = rule or note_rule(info)
  local marks = {}
  for _, m in ipairs(punct_list or opt("punctuation_marks", { ".", ",", ";", ":", "!", "?" })) do
    marks[m] = true
  end
  local next_ = ox.get_next_element(citation, info)
  local final_punct
  if next_ and next_.type == "plain-text" then
    local ws, p = next_.value:match("^([ \t\n]*)(.)")
    if p and marks[p] then
      final_punct = ws .. p
    end
  end
  local prev_el = ox.get_previous_element(citation, info)
  local previous
  if prev_el then
    local found = element.map(prev_el, TERMINALS, function(x)
      return x
    end, { ignore = info.ignore, no_recursion = { citation = true, subscript = true, superscript = true } })
    previous = found[#found]
  end
  local punct, quote, spacing
  local m
  if previous and previous.type == "plain-text" then
    m = previous_punct_match(previous.value, marks)
    punct = m.g1 and substr(previous.value, m.g1) or nil
    quote = m.g2 and '"' or nil
    spacing = m.g3 and substr(previous.value, m.g3) or nil
  end
  if not (quote or ((punct ~= nil) ~= (final_punct ~= nil))) then
    return
  end
  -- phase 1: punctuation rule
  if quote then
    local p1 = rule[1]
    if p1 == "inside" or (p1 == "adaptive" and not spacing) then
      if not punct and final_punct then
        local s = previous.value
        previous.value = s:sub(1, m.g2[1] - 1) .. final_punct .. '"' .. s:sub(m.g2[2] + 1)
        next_.value = next_.value:sub(#final_punct + 1)
        punct = final_punct
        final_punct = nil
        m = previous_punct_match(previous.value, marks)
      end
    elseif p1 == "outside" or (p1 == "adaptive" and spacing) then
      if punct and not final_punct then
        local s = previous.value
        previous.value = s:sub(1, m.g1[1] - 1) .. s:sub(m.g1[2] + 1)
        if next_ and next_.type == "plain-text" then
          next_.value = punct .. next_.value
        elseif next_ then
          insert_before(text(punct), next_)
        else
          adopt(citation.parent, text(punct))
        end
        next_ = ox.get_next_element(citation, info)
        final_punct = punct
        punct = nil
        m = previous_punct_match(previous.value, marks)
      end
    else
      error("Invalid punctuation rule", 0)
    end
  end
  -- phase 2: citation location
  local number, order = rule[2], rule[3]
  if number == "same" then
    if punct and final_punct then
      number = "outside"
    elseif punct then
      number = "inside"
    elseif final_punct then
      number = "outside"
    else
      number = nil
    end
  end
  if number == nil then
    return
  elseif number == "inside" and order == "after" then
    if quote then
      insert_at_split(previous, citation, m.g2[1])
    elseif final_punct then
      move_punct_before(final_punct, citation, next_, info)
    end
  elseif number == "inside" and order == "before" then
    if punct or quote then
      insert_at_split(previous, citation, m.m0)
    end
  elseif number == "outside" and order == "after" then
    if final_punct then
      move_punct_before(final_punct, citation, next_, info)
    end
  elseif number == "outside" and order == "before" then
    if punct and not quote then
      insert_at_split(previous, citation, m.m0)
    end
  else
    error("Invalid punctuation rule", 0)
  end
end

---------------------------------------------------------------------------
-- Bibliography files
---------------------------------------------------------------------------

local MONTHS = {
  jan = "January",
  feb = "February",
  mar = "March",
  apr = "April",
  may = "May",
  jun = "June",
  jul = "July",
  aug = "August",
  sep = "September",
  oct = "October",
  nov = "November",
  dec = "December",
}

--- Parse BibTeX/BibLaTeX text. Returns { [key] = entry alist-table }.
function M.parse_bibtex(content)
  local entries = {}
  local strings = {}
  for k, v in pairs(MONTHS) do
    strings[k] = v
  end
  local pos = 1
  local n = #content
  local function skip_ws()
    local ws = content:match("^[%s]*", pos)
    pos = pos + #ws
  end
  local function balanced(open, close)
    -- pos at `open`; returns inner text
    local depth = 0
    local start = pos
    while pos <= n do
      local c = content:sub(pos, pos)
      if c == "\\" then
        pos = pos + 2
      else
        if c == open then
          depth = depth + 1
        elseif c == close then
          depth = depth - 1
          if depth == 0 then
            pos = pos + 1
            return content:sub(start + 1, pos - 2)
          end
        end
        pos = pos + 1
      end
    end
    return content:sub(start + 1)
  end
  local function quoted()
    -- pos at '"'; braces protect inner quotes
    local start = pos + 1
    pos = pos + 1
    local depth = 0
    while pos <= n do
      local c = content:sub(pos, pos)
      if c == "\\" then
        pos = pos + 2
      elseif c == "{" then
        depth = depth + 1
        pos = pos + 1
      elseif c == "}" then
        depth = depth - 1
        pos = pos + 1
      elseif c == '"' and depth <= 0 then
        pos = pos + 1
        return content:sub(start, pos - 2)
      else
        pos = pos + 1
      end
    end
    return content:sub(start)
  end
  local function value()
    local parts = {}
    while true do
      skip_ws()
      local c = content:sub(pos, pos)
      if c == "{" then
        parts[#parts + 1] = balanced("{", "}")
      elseif c == '"' then
        parts[#parts + 1] = quoted()
      else
        local word = content:match("^[^%s,#}%)=]+", pos) or ""
        pos = pos + #word
        if word:match("^%d+$") then
          parts[#parts + 1] = word
        elseif word ~= "" then
          parts[#parts + 1] = strings[word:lower()] or word
        end
      end
      skip_ws()
      if content:sub(pos, pos) == "#" then
        pos = pos + 1
      else
        break
      end
    end
    return table.concat(parts)
  end
  while pos <= n do
    local at = content:find("@", pos, true)
    if not at then
      break
    end
    pos = at + 1
    local etype = content:match("^[%w_%-]+", pos)
    if not etype then
      goto continue
    end
    pos = pos + #etype
    skip_ws()
    local open = content:sub(pos, pos)
    if open ~= "{" and open ~= "(" then
      goto continue
    end
    local close = open == "{" and "}" or ")"
    local lt = etype:lower()
    if lt == "comment" or lt == "preamble" then
      balanced(open, close)
      goto continue
    end
    pos = pos + 1
    if lt == "string" then
      skip_ws()
      local name = content:match("^[^%s=]+", pos) or ""
      pos = pos + #name
      skip_ws()
      if content:sub(pos, pos) == "=" then
        pos = pos + 1
        strings[name:lower()] = value()
      end
      skip_ws()
      if content:sub(pos, pos) == close then
        pos = pos + 1
      end
      goto continue
    end
    do
      skip_ws()
      local key = content:match("^[^%s,]+", pos) or ""
      pos = pos + #key
      local entry = { { "id", key }, { "type", etype } }
      while pos <= n do
        skip_ws()
        local c = content:sub(pos, pos)
        if c == "," then
          pos = pos + 1
        elseif c == close then
          pos = pos + 1
          break
        else
          local field = content:match("^[^%s=,}%)]+", pos)
          if not field then
            pos = pos + 1
          else
            pos = pos + #field
            skip_ws()
            if content:sub(pos, pos) == "=" then
              pos = pos + 1
              local v = value():gsub("[ \t\n]+", " ")
              entry[#entry + 1] = { field:lower(), v }
            end
          end
        end
      end
      if key ~= "" then
        entries[key] = entry
      end
    end
    ::continue::
  end
  return entries
end

--- Parse CSL-JSON. Returns { [key] = entry }.
function M.parse_json(content)
  local ok, items = pcall(vim.json.decode, content)
  if not ok or type(items) ~= "table" then
    error("Malformed CSL-JSON bibliography", 0)
  end
  local entries = {}
  for _, item in ipairs(items) do
    local entry = {}
    for field, v in pairs(item) do
      if field == "author" or field == "editor" then
        local names = {}
        for _, p in ipairs(v) do
          names[#names + 1] = (p.family or "") .. " " .. (p.given or "")
        end
        entry[#entry + 1] = { field, table.concat(names, " and ") }
      elseif field == "issued" then
        local date = v["date-parts"] or v.literal or v.raw
        local year
        if type(date) == "table" then
          local y = date[1] and date[1][1]
          year = type(y) == "number" and tostring(y) or y
        elseif type(date) == "string" then
          year = date:match("(%d%d%d%d)") or date
        end
        entry[#entry + 1] = { "year", year }
      else
        entry[#entry + 1] = { field, type(v) == "number" and tostring(v) or v }
      end
    end
    if item.id then
      entries[tostring(item.id)] = entry
    end
  end
  return entries
end

local file_cache = {}

--- Parsed bibliography: list of { file, entries } (org-cite-basic--parse-bibliography).
function M.parse_bibliography(info)
  if info.cite_basic_bibliography then
    return info.cite_basic_bibliography
  end
  local results = {}
  for _, f in ipairs(info.bibliography or {}) do
    local path = M.bibliography_path(f, info)
    local real = vim.uv.fs_realpath(path) or path
    local st = vim.uv.fs_stat(real)
    if st then
      local cached = file_cache[real]
      local mtime = st.mtime.sec * 1e9 + st.mtime.nsec
      if not cached or cached.mtime ~= mtime then
        local lines = utils.readfile(real) or {}
        local content = table.concat(lines, "\n")
        local ext = real:match("%.([^./]+)$")
        local entries
        if ext == "json" then
          entries = M.parse_json(content)
        elseif ext == "bib" or ext == "bibtex" then
          entries = M.parse_bibtex(content)
        else
          error(fmt("Unknown bibliography extension: %q", tostring(ext)), 0)
        end
        cached = { mtime = mtime, entries = entries }
        file_cache[real] = cached
      end
      results[#results + 1] = { real, cached.entries }
    end
  end
  info.cite_basic_bibliography = results
  return results
end

---------------------------------------------------------------------------
-- basic processor (oc-basic.el)
---------------------------------------------------------------------------

local basic = {}

local function latex_p(info)
  return ox.derived_backend_p(info.back_end, "latex")
end

function basic.get_entry(key, info)
  for _, f in ipairs(M.parse_bibliography(info)) do
    local e = f[2][key]
    if e then
      return e
    end
  end
end

local function assq(entry, field)
  for _, kv in ipairs(entry) do
    if kv[1] == field then
      return kv[2]
    end
  end
end

--- Field value: a string, a raw string (LaTeX back-ends) or nil.
function basic.get_field(field, entry_or_key, info, want_raw)
  local entry = entry_or_key
  if type(entry_or_key) == "string" then
    entry = basic.get_entry(entry_or_key, info)
  end
  local value = entry and assq(entry, field)
  if value ~= nil and type(value) ~= "string" then
    error(fmt("Non-string bibliography field value: %s", vim.inspect(value)), 0)
  end
  if value and not want_raw and latex_p(info) then
    return raw(value)
  end
  return value
end

function basic.shorten_names(names)
  local s, is_raw
  if type(names) == "string" then
    s = names
  elseif names and names.type == "raw" then
    s = names.value
    is_raw = true
  end
  if not s then
    return nil
  end
  local out = {}
  for _, name in ipairs(vim.split(s, " and ", { plain = true })) do
    if #name == 1 then
      out[#out + 1] = ""
    else
      out[#out + 1] = vim.split(name, ", ", { plain = true })[1]
    end
  end
  local r = table.concat(out, ", ")
  return is_raw and raw(r) or r
end

function basic.number_to_suffix(n)
  local result = {}
  while true do
    table.insert(result, 1, n % 26)
    n = math.floor(n / 26)
    if n == 0 then
      break
    elseif n < 27 then
      table.insert(result, 1, n - 1)
      break
    elseif n == 27 then
      table.insert(result, 1, 0)
      table.insert(result, 1, 0)
      break
    end
  end
  local chars = {}
  for i, x in ipairs(result) do
    chars[i] = string.char(97 + x)
  end
  return table.concat(chars)
end

function basic.get_author(entry_or_key, info, want_raw)
  return basic.get_field("author", entry_or_key, info, want_raw)
    or basic.get_field("editor", entry_or_key, info, want_raw)
end

function basic.get_year(entry_or_key, info, no_suffix)
  local author = basic.get_author(entry_or_key, info, true)
  local year = basic.get_field("year", entry_or_key, info, true)
  if not year then
    local date = basic.get_field("date", entry_or_key, info, true)
    if type(date) == "string" then
      year = date:match("^(%d%d%d%d)%f[%D]") or date:match("^(%d%d%d%d)$")
    end
  end
  local key = type(entry_or_key) == "string" and entry_or_key or assq(entry_or_key, "id")
  info.cite_basic_author_date_cache = info.cite_basic_author_date_cache or {}
  local cache = info.cite_basic_author_date_cache
  local ck = tostring(author) .. "\0" .. tostring(year)
  local hit = cache[ck]
  if not hit then
    -- the alist only ever holds the first key (like Emacs)
    cache[ck] = { { key, "" } }
    return year
  end
  local suffix
  for _, kv in ipairs(hit) do
    if kv[1] == key then
      suffix = kv[2]
    end
  end
  suffix = suffix or basic.number_to_suffix(#hit - 1)
  if no_suffix then
    return year
  end
  return (year or "") .. suffix
end

--- Parse LaTeX fragments and entities in strings nested in objects, then
--- drop remaining braces (org-cite-basic--print-bibtex-string).
function basic.print_bibtex_string(data, info)
  if latex_p(info) then
    return data
  end
  local R = { ["latex-fragment"] = true, entity = true }
  local function walk(list, nested)
    local i = 1
    while i <= #list do
      local x = list[i]
      if x.type == "plain-text" and nested then
        local parsed = info.parser:parse_objects(x.value, R, x.parent)
        for _, p in ipairs(parsed) do
          p.parent = x.parent
          if p.type == "plain-text" then
            p.value = p.value:gsub("[{}]", "")
          end
        end
        table.remove(list, i)
        for k, p in ipairs(parsed) do
          table.insert(list, i + k - 1, p)
        end
        i = i + #parsed
      else
        if x.type ~= "plain-text" and x.contents then
          walk(x.contents, true)
        end
        i = i + 1
      end
    end
  end
  walk(data, false)
  return data
end

function basic.key_number(key, info)
  return M.key_number(key, info, basic.field_less_p(opt("basic_sorting_field", "author"), info))
end

function basic.print_entry(entry, style, info)
  local author = basic.get_author(entry, info)
  local title = basic.get_field("title", entry, info)
  local from = basic.get_field("publisher", entry, info)
    or basic.get_field("journal", entry, info)
    or basic.get_field("institution", entry, info)
    or basic.get_field("school", entry, info)
  local data
  if style == "plain" then
    local year = basic.get_year(entry, info, true)
    data = M.concat(basic.shorten_names(author), ". ", title, from and M.concat(", ", from), ", ", year, ".")
  elseif style == "numeric" then
    local n = basic.key_number(assq(entry, "id"), info)
    local year = basic.get_year(entry, info, true)
    data = M.concat(
      fmt("[%d] ", n),
      author,
      ", ",
      M.emphasize("italic", title),
      from and M.concat(", ", from),
      ", ",
      year,
      "."
    )
  else
    local year = basic.get_year(entry, info)
    data = M.concat(author, " (", year, "). ", M.emphasize("italic", title), from and M.concat(", ", from), ".")
  end
  return basic.print_bibtex_string(data, info)
end

function basic.format_author_year(citation, format_cite, format_ref, info)
  return ox.data(
    format_cite(
      citation.prefix,
      M.mapconcat(function(ref)
        local k = ref.key
        return format_ref(
          ref.prefix,
          basic.get_author(k, info) or "??",
          basic.get_year(k, info) or "????",
          ref.suffix
        )
      end, M.get_references(citation), opt("basic_author_year_separator", ", ")),
      citation.suffix
    ),
    info
  )
end

function basic.citation_numbers(citation, info)
  local numbers = {}
  for _, k in ipairs(M.get_references(citation, true)) do
    numbers[#numbers + 1] = basic.key_number(k, info)
  end
  table.sort(numbers)
  local last = table.remove(numbers, 1)
  local result = { tostring(last) }
  while #numbers > 0 do
    local current = table.remove(numbers, 1)
    local nxt = numbers[1]
    if nxt and current == last + 1 and current == nxt - 1 then
      if result[#result] ~= "-" then
        result[#result + 1] = "-"
      end
    elseif result[#result] == "-" then
      result[#result + 1] = tostring(current)
    else
      result[#result + 1] = fmt(", %d", current)
    end
    last = current
  end
  return table.concat(result)
end

function basic.field_less_p(field, info)
  if not field then
    return nil
  end
  return function(a, b)
    local x = basic.get_field(field, a, info, true) or "nil"
    local y = basic.get_field(field, b, info, true) or "nil"
    return x:lower() < y:lower()
  end
end

function basic.export_citation(citation, style, _, info)
  local name, variant = style[1], style[2]
  local function has_variant(t)
    if t == "bare" then
      return variant == "bare" or variant == "bare-caps" or variant == "b" or variant == "bc"
    end
    return variant == "caps" or variant == "bare-caps" or variant == "c" or variant == "bc"
  end
  if name == "author" or name == "a" then
    local caps = variant == "caps" or variant == "c"
    return basic.format_author_year(citation, function(p, c, s)
      return M.concat(p, c, s)
    end, function(prefix, author, _, suffix)
      return M.concat(prefix, caps and M.capitalize(author) or author, suffix)
    end, info)
  elseif name == "noauthor" or name == "na" then
    local bare = has_variant("bare")
    return basic.format_author_year(citation, function(prefix, contents, suffix)
      return M.concat(not bare and "(" or nil, prefix, contents, suffix, not bare and ")" or nil)
    end, function(prefix, _, year, suffix)
      return M.concat(prefix, year, suffix)
    end, info)
  elseif name == "nocite" or name == "n" then
    return nil
  elseif name == "text" or name == "note" or name == "t" or name == "ft" then
    if (name == "note" or name == "ft") and not M.inside_footnote_p(citation) then
      M.adjust_note(citation, info)
      M.wrap_citation(citation, info)
    end
    local bare, caps = has_variant("bare"), has_variant("caps")
    return basic.format_author_year(citation, function(p, c, s)
      return M.concat(p, c, s)
    end, function(p, a, y, s)
      return M.concat(p, caps and M.capitalize(a) or a, bare and " " or " (", y, not bare and ")" or nil, s)
    end, info)
  elseif name == "numeric" or name == "nb" then
    local prefix, suffix = M.main_affixes(citation)
    return ox.data(M.concat("(", prefix, basic.citation_numbers(citation, info), suffix, ")"), info)
  end
  local bare, caps = has_variant("bare"), has_variant("caps")
  return basic.format_author_year(citation, function(p, c, s)
    return M.concat(not bare and "(" or nil, p, c, s, not bare and ")" or nil)
  end, function(p, a, y, s)
    return M.concat(p, caps and M.capitalize(a) or a, ", ", y, s)
  end, info)
end

function basic.export_bibliography(keys, _, style, _, backend, info)
  local entries = {}
  local sorted = keys
  local pred = basic.field_less_p(opt("basic_sorting_field", "author"), info)
  if pred then
    sorted = stable_sort(keys, pred)
  end
  for _, k in ipairs(sorted) do
    local e = basic.get_entry(k, info)
    if e then
      entries[#entries + 1] = e
    end
  end
  local out = {}
  for _, entry in ipairs(entries) do
    out[#out + 1] = ox.data(
      M.make_paragraph(
        ox.derived_backend_p(backend, "latex") and raw("\\noindent\n") or nil,
        basic.print_entry(entry, style, info)
      ),
      info
    )
  end
  return table.concat(out, "\n")
end

M.basic = basic
M.processors.basic = {
  export_citation = basic.export_citation,
  export_bibliography = basic.export_bibliography,
}

---------------------------------------------------------------------------
-- natbib and bibtex processors
---------------------------------------------------------------------------

local function data_trim(d, info)
  return trim(ox.data(d, info))
end

local function file_sans_extension(f)
  return (f:gsub("%.[^./]*$", ""))
end

local natbib = {}

function natbib.command(style)
  local name, v = style[1], style[2]
  if name == "author" or name == "a" then
    if v == "caps" or v == "c" then
      return "\\Citeauthor"
    elseif v == "full" or v == "f" then
      return "\\citeauthor*"
    end
    return "\\citeauthor"
  elseif name == "noauthor" or name == "na" then
    if v == "bare" or v == "b" then
      return "\\citeyear"
    end
    return "\\citeyearpar"
  elseif name == "nocite" or name == "n" then
    return "\\nocite"
  end
  local base = (name == "text" or name == "t") and "t" or "p"
  local map = {
    bare = "\\citeal" .. base,
    b = "\\citeal" .. base,
    caps = "\\Cite" .. base,
    c = "\\Cite" .. base,
    full = "\\cite" .. base .. "*",
    f = "\\cite" .. base .. "*",
    ["bare-caps"] = "\\Citeal" .. base,
    bc = "\\Citeal" .. base,
    ["bare-full"] = "\\citeal" .. base .. "*",
    bf = "\\citeal" .. base .. "*",
    ["caps-full"] = "\\Cite" .. base .. "*",
    cf = "\\Cite" .. base .. "*",
    ["bare-caps-full"] = "\\Citeal" .. base .. "*",
    bcf = "\\Citeal" .. base .. "*",
  }
  return map[v or ""] or ("\\cite" .. base)
end

function natbib.export_citation(citation, style, _, info)
  local prefix, suffix = M.main_affixes(citation)
  local opts = (prefix and fmt("[%s]", data_trim(prefix, info)) or "")
    .. (suffix and fmt("[%s]", data_trim(suffix, info)) or (prefix and "[]" or ""))
  return natbib.command(style) .. opts .. fmt("{%s}", table.concat(M.get_references(citation, true), ","))
end

function natbib.export_bibliography(_, files, style)
  local names = {}
  for i, f in ipairs(files) do
    names[i] = file_sans_extension(f)
  end
  return fmt("\\bibliographystyle{%s}\n", style or opt("natbib_bibliography_style", "unsrtnat"))
    .. fmt("\\bibliography{%s}", table.concat(names, ","))
end

function natbib.finalize(output)
  local b = output:find("\\begin{document}", 1, true)
  if not b then
    return output
  end
  local before = output:sub(1, b - 1)
  if before:find("\\usepackage%b[]{natbib}") or before:find("\\usepackage{natbib}", 1, true) then
    return output
  end
  local options = opt("natbib_options", {})
  local o = #options > 0 and fmt("[%s]", table.concat(options, ",")) or ""
  return before .. fmt("\\usepackage%s{natbib}\n", o) .. output:sub(b)
end

M.processors.natbib = {
  export_citation = natbib.export_citation,
  export_bibliography = natbib.export_bibliography,
  export_finalizer = natbib.finalize,
}

local bibtex = {}

function bibtex.export_citation(citation, style, _, info)
  local name = style[1]
  local _, suffix = M.main_affixes(citation)
  return fmt(
    "\\%s%s{%s}",
    (name == "nocite" or name == "n") and "nocite" or "cite",
    suffix and fmt("[%s]", data_trim(suffix, info)) or "",
    table.concat(M.get_references(citation, true), ",")
  )
end

function bibtex.export_bibliography(_, files, style)
  local names = {}
  for i, f in ipairs(files) do
    names[i] = file_sans_extension(f)
  end
  return fmt("\\bibliographystyle{%s}\n", style or opt("bibtex_bibliography_style", "plain"))
    .. fmt("\\bibliography{%s}", table.concat(names, ","))
end

M.processors.bibtex = {
  export_citation = bibtex.export_citation,
  export_bibliography = bibtex.export_bibliography,
}

---------------------------------------------------------------------------
-- biblatex processor
---------------------------------------------------------------------------

local biblatex = {}

function biblatex.package_options(initial, style)
  local no_style = {}
  if initial then
    local s = initial:match("^%[(.*)%]$") or initial
    for _, o in ipairs(vim.split(s, ",", { trimempty = true })) do
      o = trim(o)
      if o ~= "" and not (o:match("^bibstyle") or o:match("^citestyle") or o:match("^style")) then
        no_style[#no_style + 1] = o
      end
    end
  end
  local style_opts = {}
  if style then
    local kv = style:match("^[^,=]+=[^,]+,[^=]+=[^,]+$") ~= nil
    local a, b = style:match("^(.-)/(.*)$")
    if not a then
      style_opts[1] = kv and style or ("style=" .. style)
    else
      style_opts = { "bibstyle=" .. a, "citestyle=" .. b }
    end
  end
  local all = vim.list_extend(no_style, style_opts)
  if #all > 0 then
    return "[" .. table.concat(all, ",") .. "]"
  end
  return ""
end

local function multicite_p(citation)
  local refs = M.get_references(citation)
  if #refs <= 1 then
    return false
  end
  for _, r in ipairs(refs) do
    if r.prefix or r.suffix then
      return true
    end
  end
  return false
end

local function atomic_arguments(refs, info, no_opt)
  local keys = {}
  for i, r in ipairs(refs) do
    keys[i] = r.key
  end
  local mandatory = fmt("{%s}", table.concat(keys, ","))
  if no_opt then
    return mandatory
  end
  local origin = #refs == 1 and refs[1] or refs[1].parent
  local prefix, suffix = origin.prefix, origin.suffix
  return (prefix and fmt("[%s]", data_trim(prefix, info)) or "")
    .. (suffix and fmt("[%s]", data_trim(suffix, info)) or (prefix and "[]" or ""))
    .. mandatory
end

local function multi_arguments(citation, info)
  local gp, gs = citation.prefix, citation.suffix
  local s = (gp and fmt("(%s)", data_trim(gp, info)) or "")
    .. (gs and fmt("(%s)", data_trim(gs, info)) or (gp and "()" or ""))
  for _, r in ipairs(M.get_references(citation)) do
    s = s .. atomic_arguments({ r }, info)
  end
  return s
end

function biblatex.export_citation(citation, style, _, info)
  local shortcuts = opt("biblatex_style_shortcuts", M.BIBLATEX_SHORTCUTS)
  local name = style[1] and (shortcuts[style[1]] or style[1]) or nil
  local variant = style[2] and (shortcuts[style[2]] or style[2]) or nil
  local candidates = {}
  local style_match = false
  local chosen
  for _, s in ipairs(opt("biblatex_styles", M.BIBLATEX_STYLES)) do
    if s[1] == name and s[2] == variant then
      chosen = s
      break
    elseif s[1] == nil and s[2] == nil then
      if #candidates == 0 then
        table.insert(candidates, 1, s)
      end
    elseif s[1] == name and s[2] == nil then
      table.insert(candidates, 1, s)
      style_match = true
    elseif s[1] == nil and s[2] == variant then
      if not style_match then
        table.insert(candidates, 1, s)
      end
    end
  end
  chosen = chosen or candidates[1]
  if not chosen then
    error("Missing default style or variant in export.cite.biblatex_styles", 0)
  end
  local cmd, multi, no_opt = chosen[3], chosen[4], chosen[5]
  if multi and multicite_p(citation) then
    return fmt("\\%s%s", multi, multi_arguments(citation, info))
  end
  return fmt("\\%s%s", cmd, atomic_arguments(M.get_references(citation), info, no_opt))
end

function biblatex.export_bibliography(_, _, _, props)
  local s = "\\printbibliography"
  if props and #props > 0 then
    local results = {}
    local key
    for _, d in ipairs(props) do
      if type(d) == "table" and d.keyword then
        if key then
          results[#results + 1] = key
        end
        key = d.keyword:sub(2)
      else
        local parts = {}
        for _, v in ipairs(vim.split(d, ",", { trimempty = true })) do
          parts[#parts + 1] = (key or "nil") .. "=" .. v
        end
        results[#results + 1] = table.concat(parts, ",")
        key = nil
      end
    end
    s = s .. "[" .. table.concat(results, ",") .. "]"
  end
  return s
end

function biblatex.finalize(output, _, files, style)
  local b = output:find("\\begin{document}", 1, true)
  if not b then
    return output
  end
  local before, after = output:sub(1, b - 1), output:sub(b)
  -- last \usepackage[...]{biblatex} before \begin{document}
  local last_s, last_e, last_opts
  local pos = 1
  while true do
    local s, e = before:find("\\usepackage", pos, true)
    if not s then
      break
    end
    local opts = before:match("^(%b[])", e + 1)
    local k = e + 1 + (opts and #opts or 0)
    if before:sub(k, k + 9) == "{biblatex}" then
      last_s, last_e, last_opts = s, k + 9, opts
    end
    pos = e + 1
  end
  local point
  if not last_s then
    local ins = fmt("\\usepackage%s{biblatex}\n", biblatex.package_options(opt("biblatex_options", nil), style))
    before = before .. ins
    point = #before + 1
  elseif not last_opts then
    -- (search-forward "{"): options land after the first brace, like Emacs
    local brace = before:find("{", last_s, true)
    before = before:sub(1, brace) .. biblatex.package_options(nil, style) .. before:sub(brace + 1)
    point = (before:find("\n", brace, true) or #before) + 1
  else
    local new = biblatex.package_options(last_opts, style)
    local os = last_s + #"\\usepackage"
    before = before:sub(1, os - 1) .. new .. before:sub(os + #last_opts)
    point = (before:find("\n", last_s, true) or #before) + 1
  end
  local text_all = before .. after
  local res = {}
  for _, f in ipairs(files) do
    res[#res + 1] = fmt("\\addbibresource%s{%s}", f:match("^%a[%w+.-]*://") and "[location=remote]" or "", f)
  end
  local ins = table.concat(res, "\n") .. "\n"
  return text_all:sub(1, point - 1) .. ins .. text_all:sub(point)
end

M.processors.biblatex = {
  export_citation = biblatex.export_citation,
  export_bibliography = biblatex.export_bibliography,
  export_finalizer = biblatex.finalize,
}

---------------------------------------------------------------------------
-- Export interface
---------------------------------------------------------------------------

--- Emacs parses leading blanks after "[cite:" and trailing blanks before
--- "]" as part of the citation markup, not of the affixes.
local function normalize_affixes(citation)
  local ref1 = citation.contents[1]
  local first = citation.prefix and citation.prefix[1] or (ref1 and ref1.prefix and ref1.prefix[1])
  if first and first.type == "plain-text" then
    first.value = first.value:gsub("^[ \t\n]+", "")
    local owner = citation.prefix or citation.contents[1].prefix
    if first.value == "" then
      table.remove(owner, 1)
      if #owner == 0 then
        if citation.prefix then
          citation.prefix = nil
        else
          citation.contents[1].prefix = nil
        end
      end
    end
  end
  local lastref = citation.contents[#citation.contents]
  local owner = citation.suffix or (lastref and lastref.suffix)
  local last = owner and owner[#owner]
  if last and last.type == "plain-text" then
    last.value = last.value:gsub("[ \t\n]+$", "")
    if last.value == "" then
      table.remove(owner, #owner)
      if #owner == 0 then
        if citation.suffix then
          citation.suffix = nil
        else
          lastref.suffix = nil
        end
      end
    end
  end
end

function M.export_citation_now(citation, info)
  local ce = info.cite_export
  if not ce then
    return nil
  end
  local p = M.processors[ce[1]]
  return p.export_citation(citation, M.citation_style(citation, info), info.back_end and info.back_end.name, info)
end

function M.export_bibliography(keyword, info)
  local ce = info.cite_export
  if not ce then
    return nil
  end
  local p = M.processors[ce[1]]
  if not p.export_bibliography then
    return nil
  end
  return p.export_bibliography(
    M.list_keys(info),
    info.bibliography or {},
    M.bibliography_style(info),
    M.parse_as_plist(keyword.value),
    info.back_end,
    info
  )
end

--- org-cite-process-citations + org-cite-process-bibliography
function M.process(info)
  local cites = M.list_citations(info)
  for _, c in ipairs(cites) do
    normalize_affixes(c)
  end
  for _, cite in ipairs(cites) do
    local replacement = M.export_citation_now(cite, info)
    local blanks = cite.post_blank or 0
    if replacement == nil then
      set_previous_post_blank(cite, blanks, info)
    else
      local previous = ox.get_previous_element(cite, info)
      if previous and previous.type == "plain-text" and nw(previous.value) and previous.value:match('"$') then
        set_previous_post_blank(cite, 1, info)
      end
      if type(replacement) == "string" then
        insert_before(raw(trim(replacement) .. string.rep(" ", blanks)), cite)
      elseif replacement.type ~= nil then
        set_post_blank(replacement, blanks)
        insert_before(replacement, cite)
      else
        local last
        for _, d in ipairs(replacement) do
          last = d
          insert_before(d, cite)
        end
        if last then
          set_post_blank(last, blanks)
        end
      end
    end
    element.extract(cite)
  end
  local keywords = element.map(info.parse_tree, "keyword", function(k)
    if k.key == "PRINT_BIBLIOGRAPHY" then
      return k
    end
  end, { ignore = info.ignore })
  for _, keyword in ipairs(keywords) do
    local replacement = M.export_bibliography(keyword, info)
    local blanks = keyword.post_blank or 0
    if replacement == nil then
      set_previous_post_blank(keyword, blanks, info)
      element.extract(keyword)
    elseif type(replacement) == "string" then
      replace_node(keyword, raw((ox.normalize_string(replacement) or "") .. string.rep("\n", blanks)))
    elseif replacement.type ~= nil then
      set_post_blank(replacement, blanks)
      replace_node(keyword, replacement)
    else
      local last
      for _, d in ipairs(replacement) do
        last = d
        insert_before(d, keyword)
      end
      if last then
        set_post_blank(last, blanks)
      end
      element.extract(keyword)
    end
  end
end

--- org-cite-finalize-export
function M.finalize(output, info)
  local ce = info.cite_export
  if not ce then
    return output
  end
  local p = M.processors[ce[1]]
  if not p.export_finalizer then
    return output
  end
  local files = info.bibliography or {}
  return p.export_finalizer(output, M.list_keys(info), files, M.bibliography_style(info), info.back_end, info)
end

--- Transcoder for citations left in the tree: citations are replaced
--- by `process`, so this only happens when no processor applies.
function M.export_citation(el, info, backend)
  return nil
end

return M

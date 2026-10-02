---@mod org.bibtex BibTeX entries as Org headlines (ol-bibtex)
---
--- A headline holds a BibTeX entry in its properties: the entry type in
--- `bibtex.type_property_name` (BTYPE), the key in `bibtex.key_property`
--- (CUSTOM_ID) and each field in a property of its name (TITLE, AUTHOR,
--- ...), optionally prefixed with `bibtex.prefix`. Commands convert
--- between such headlines and BibTeX text, check them for missing fields,
--- and `bibtex:` links and links stored in `.bib` files point at entries.

local config = require("org.config")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

--- Entries read from BibTeX text, waiting to be written as headlines
--- (org-bibtex-entries). Each is a list of { field, value } pairs whose
--- first two are `type` and `key`.
---@type table[]
M.entries = {}

local function opts()
  return config.opts.bibtex or {}
end

--- BibTeX entry types with required and optional fields (org-bibtex-types).
--- A nested list is a choice between fields.
M.TYPES = {
  {
    "article",
    "An article from a journal or magazine",
    { "author", "title", "journal", "year" },
    { "volume", "number", "pages", "month", "note", "doi" },
  },
  {
    "book",
    "A book with an explicit publisher",
    { { "editor", "author" }, "title", "publisher", "year" },
    { { "volume", "number" }, "series", "address", "edition", "month", "note", "doi" },
  },
  {
    "booklet",
    "A work that is printed and bound, but without a named publisher or sponsoring institution.",
    { "title" },
    { "author", "howpublished", "address", "month", "year", "note", "doi", "url" },
  },
  {
    "conference",
    "",
    { "author", "title", "booktitle", "year" },
    { "editor", "pages", "organization", "publisher", "address", "month", "note", "doi", "url" },
  },
  {
    "inbook",
    "A part of a book, which may be a chapter (or section or whatever) and/or a range of pages.",
    { { "author", "editor" }, "title", { "chapter", "pages" }, "publisher", "year" },
    { "crossref", { "volume", "number" }, "series", "type", "address", "edition", "month", "note", "doi" },
  },
  {
    "incollection",
    "A part of a book having its own title.",
    { "author", "title", "booktitle", "publisher", "year" },
    {
      "crossref",
      "editor",
      { "volume", "number" },
      "series",
      "type",
      "chapter",
      "pages",
      "address",
      "edition",
      "month",
      "note",
      "doi",
    },
  },
  {
    "inproceedings",
    "An article in a conference proceedings",
    { "author", "title", "booktitle", "year" },
    {
      "crossref",
      "editor",
      { "volume", "number" },
      "series",
      "pages",
      "address",
      "month",
      "organization",
      "publisher",
      "note",
      "doi",
    },
  },
  {
    "manual",
    "Technical documentation.",
    { "title" },
    { "author", "organization", "address", "edition", "month", "year", "note", "doi", "url" },
  },
  {
    "mastersthesis",
    "A Master’s thesis.",
    { "author", "title", "school", "year" },
    { "type", "address", "month", "note", "doi", "url" },
  },
  {
    "misc",
    "Use this type when nothing else fits.",
    {},
    { "author", "title", "howpublished", "month", "year", "note", "doi", "url" },
  },
  {
    "phdthesis",
    "A PhD thesis.",
    { "author", "title", "school", "year" },
    { "type", "address", "month", "note", "doi", "url" },
  },
  {
    "proceedings",
    "The proceedings of a conference.",
    { "title", "year" },
    { "editor", { "volume", "number" }, "series", "address", "month", "organization", "publisher", "note", "doi" },
  },
  {
    "techreport",
    "A report published by a school or other institution.",
    { "author", "title", "institution", "year" },
    { "type", "address", "month", "note", "doi", "url" },
  },
  {
    "unpublished",
    "A document having an author and title, but not formally published.",
    { "author", "title", "note" },
    { "month", "year", "doi", "url" },
  },
}

--- BibTeX fields and their descriptions (org-bibtex-fields).
M.FIELDS = {
  address = "Usually the address of the publisher or other type of institution.  For major publishing houses, van Leunen recommends omitting the information entirely.  For small publishers, on the other hand, you can help the reader by giving the complete address.",
  annote = "An annotation.  It is not used by the standard bibliography styles, but may be used by others that produce an annotated bibliography.",
  author = "The name(s) of the author(s), in the format described in the LaTeX book.  Remember, all names are separated with the and keyword, and not commas.",
  booktitle = "Title of a book, part of which is being cited.  See the LaTeX book for how to type titles.  For book entries, use the title field instead.",
  chapter = "A chapter (or section or whatever) number.",
  crossref = "The database key of the entry being cross referenced.",
  doi = "The digital object identifier.",
  edition = "The edition of a book for example, 'Second'.  This should be an ordinal, and should have the first letter capitalized, as shown here; the standard styles convert to lower case when necessary.",
  editor = "Name(s) of editor(s), typed as indicated in the LaTeX book.  If there is also an author field, then the editor field gives the editor of the book or collection in which the reference appears.",
  howpublished = "How something strange has been published.  The first word should be capitalized.",
  institution = "The sponsoring institution of a technical report.",
  journal = "A journal name.",
  key = "Used for alphabetizing, cross-referencing, and creating a label when the author information is missing.  This field should not be confused with the key that appears in the \\cite command and at the beginning of the database entry.",
  month = "The month in which the work was published or, for an unpublished work, in which it was written.  You should use the standard three-letter abbreviation,",
  note = "Any additional information that can help the reader.  The first word should be capitalized.",
  number = "Any additional information that can help the reader.  The first word should be capitalized.",
  organization = "The organization that sponsors a conference or that publishes a manual.",
  pages = "One or more page numbers or range of numbers, such as 42-111 or 7,41,73-97 or 43+ (the ‘+’ in this last example indicates pages following that don’t form simple range). BibTEX requires double dashes for page ranges (--).",
  publisher = "The publisher’s name.",
  school = "The name of the school where a thesis was written.",
  series = "The name of a series or set of books.  When citing an entire book, the title field gives its title and an optional series field gives the name of a series or multi-volume set in which the book is published.",
  title = "The work’s title, typed as explained in the LaTeX book.",
  type = "The type of a technical report for example, 'Research Note'.",
  url = "Uniform resource locator.",
  volume = "The volume of a journal or multi-volume book.",
  year = "The year of publication or, for an unpublished work, the year it was written.  Generally it should consist of four numerals, such as 1984, although the standard styles can handle any year whose last four nonpunctuation characters are numerals, such as '(about 1984)'",
}

local function type_spec(name)
  for _, t in ipairs(M.TYPES) do
    if t[1] == name then
      return t
    end
  end
end

local function type_names()
  local out = {}
  for i, t in ipairs(M.TYPES) do
    out[i] = t[1]
  end
  return out
end

local function flatten(list, out)
  out = out or {}
  for _, f in ipairs(list or {}) do
    if type(f) == "table" then
      flatten(f, out)
    else
      out[#out + 1] = f
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Headline properties
---------------------------------------------------------------------------

local function headline_at(bufnr, lnum)
  return files.get_buffer(bufnr):headline_at(lnum)
end

--- A field of the headline (org-bibtex-get): NAME, else PREFIX NAME.
local function get(hl, name)
  local v = hl:get_property(name:upper(), false)
  local prefix = opts().prefix
  if v == nil and prefix then
    v = hl:get_property(prefix .. name:upper(), false)
  end
  return v and vim.trim(v) or nil
end
M.get = get

--- The property name of a field (org-bibtex-put): upper-cased, with the
--- prefix unless it is the key property.
local function prop_name(field)
  local prop = field:upper()
  if prop ~= (opts().key_property or "CUSTOM_ID") then
    prop = (opts().prefix or "") .. prop
  end
  return prop
end

--- Set a field of the headline at `lnum` (org-bibtex-put).
local function put(bufnr, lnum, field, value)
  local hl = headline_at(bufnr, lnum)
  require("org.edit").set_property(bufnr, hl and hl.line or lnum, prop_name(field), value)
end

--- Characters that cannot be in tags (org-tag--invalid-char-re).
local function clean_tag(kw)
  return (kw:gsub("[ \t]+", "_"):gsub("[^%w_@#%%\128-\255]", ""))
end

--- Turn `tag` on for the headline at `lnum` (org-toggle-tag ... 'on).
local function tag_on(bufnr, lnum, tag)
  local hl = headline_at(bufnr, lnum)
  if not hl or tag == "" or vim.tbl_contains(hl.tags, tag) then
    return
  end
  local tags = vim.deepcopy(hl.tags)
  tags[#tags + 1] = tag
  require("org.edit").update_headline(bufnr, hl.line, { tags = tags })
end

--- Properties of the drawer of `hl` as { name, value } in the order of
--- org-entry-properties (last first), with CATEGORY.
local function drawer_properties(hl)
  local out = {}
  local r = hl.properties_range
  local has_category = false
  if r then
    local parser = require("org.parser")
    for i = r[2] - 1, r[1] + 1, -1 do
      local k, v = parser.parse_property_line(hl.file.lines[i])
      if k then
        out[#out + 1] = { k, v or "" }
        has_category = has_category or k:upper() == "CATEGORY"
      end
    end
  end
  if not has_category then
    table.insert(out, 1, { "CATEGORY", hl:get_category() or "" })
  end
  return out
end

---------------------------------------------------------------------------
-- Headline -> BibTeX
---------------------------------------------------------------------------

--- The BibTeX entry of headline `hl` as a string (org-bibtex-headline), or
--- nil when it has no entry type.
function M.headline_entry(hl)
  local o = opts()
  local id = get(hl, o.key_property or "CUSTOM_ID")
  local btype = get(hl, o.type_property_name or "btype")
  if not btype then
    return nil
  end
  local tags
  if o.tags_are_keywords then
    local skip = {}
    for _, t in ipairs(vim.list_extend(vim.deepcopy(o.tags or {}), o.no_export_tags or {})) do
      skip[t] = true
    end
    tags = {}
    for _, t in ipairs(o.inherit_tags and hl:get_tags() or hl.tags) do
      if not skip[t] then
        tags[#tags + 1] = t
      end
    end
  end
  local fields = {}
  if o.export_arbitrary_fields and o.prefix then
    local prefix = o.prefix:lower()
    local type_prop = (o.prefix .. (o.type_property_name or "btype")):lower()
    for _, kv in ipairs(drawer_properties(hl)) do
      local key = kv[1]:lower()
      if key:find(prefix, 1, true) and key ~= type_prop then
        local name = prefix == "" and key or key:gsub(vim.pesc(prefix), "")
        fields[#fields + 1] = { name, kv[2] }
      end
    end
  else
    local spec = type_spec(btype)
    local names = spec and flatten(spec[4], flatten(spec[3])) or {}
    for _, f in ipairs(names) do
      local v = get(hl, f)
      if v == nil and f == "title" then
        v = hl.title
      end
      if v then
        fields[#fields + 1] = { f, v }
      end
    end
  end
  local parts = {}
  for i, kv in ipairs(fields) do
    parts[i] = string.format("  %s={%s}", kv[1], kv[2])
  end
  local lines =
    vim.split(string.format("@%s{%s,\n%s\n}\n", btype, id or "nil", table.concat(parts, ",\n")), "\n", { plain = true })
  if tags and #tags > 0 then
    local joined = table.concat(tags, ", ")
    local done = false
    for i, l in ipairs(lines) do
      local lower = l:lower()
      local ks = lower:find("keywords", 1, true)
      if ks and l:find("=", ks, true) then
        local open = l:find("{", l:find("=", ks, true), true)
        local close = open and l:match(".*()}")
        if open and close and close > open then
          lines[i] = l:sub(1, close - 1) .. ", " .. joined .. l:sub(close)
          done = true
          break
        end
      end
    end
    if not done then
      table.insert(lines, 2, "  keywords={" .. joined .. "},")
    end
  end
  return table.concat(lines, "\n")
end

--- org-bibtex: write the entries of every headline of the buffer to a
--- BibTeX file (default: the Org file with a .bib extension).
---@param filename? string
function M.export(filename)
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local dir = name ~= "" and vim.fn.fnamemodify(name, ":p:h") or vim.fn.getcwd()
  if not filename then
    local default = name ~= "" and (vim.fn.fnamemodify(name, ":t:r") .. ".bib") or ""
    filename = utils.input({ prompt = "BibTeX file: ", default = default, completion = "file" })
    if not filename or vim.trim(filename) == "" then
      return
    end
  end
  filename = utils.expand(vim.trim(filename), dir)
  local out = {}
  for _, hl in ipairs(files.get_buffer(bufnr).headlines) do
    local ok, entry = pcall(M.headline_entry, hl)
    if not ok then
      pcall(vim.api.nvim_win_set_cursor, 0, { hl.line, 0 })
      utils.notify(string.format("BibTeX error at %q", hl.title))
      return
    end
    if entry then
      out[#out + 1] = entry
    end
  end
  local text = table.concat(out, "\n")
  local fh = io.open(filename, "wb")
  if not fh then
    utils.error("Cannot write " .. filename)
    return
  end
  fh:write(text)
  fh:close()
  utils.notify(string.format("Successfully exported %d BibTeX entries to %s", #out, filename))
  return filename, #out
end

--- org-bibtex-export-to-kill-ring: copy the entry of the headline at the
--- cursor to the unnamed register.
function M.export_to_kill_ring()
  local bufnr = vim.api.nvim_get_current_buf()
  local hl = headline_at(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  local entry = hl and M.headline_entry(hl)
  if not entry then
    utils.warn("No BibTeX entry here (the headline has no " .. (opts().type_property_name or "btype") .. ")")
    return
  end
  vim.fn.setreg('"', entry)
  return entry
end

---------------------------------------------------------------------------
-- Keys (bibtex-generate-autokey)
---------------------------------------------------------------------------

--- bibtex-autokey-transcriptions: (Lua pattern or literal, replacement)
--- applied in turn to names and title words.
local TRANSCRIPTIONS = {
  { { "\\aa" }, "a" },
  { { "\\AA" }, "A" },
  { { '\\"a', '"a', "\\ae" }, "ae" },
  { { '\\"A', '"A', "\\AE" }, "Ae" },
  { { "\\i" }, "i" },
  { { "\\j" }, "j" },
  { { "\\l" }, "l" },
  { { "\\L" }, "L" },
  { { "\\oe", '\\"o', '"o', "\\o" }, "oe" },
  { { "\\OE", '\\"O', '"O', "\\O" }, "Oe" },
  { { '\\"s', '"s', "\\3" }, "ss" },
  { { '\\"u', '"u' }, "ue" },
  { { '\\"U', '"U' }, "Ue" },
  {
    { "\\-", "\\`", "\\'", "\\^", "\\~", "\\=", "\\.", "\\u", "\\v", "\\H", "\\t", "\\c", "\\d", "\\b" },
    "",
  },
  { { "~" }, " " },
}

local function transcribe(s)
  for _, rule in ipairs(TRANSCRIPTIONS) do
    -- one left-to-right pass per rule, longest alternative first at each
    -- position, like the regexp-opt of Emacs
    local out, i = {}, 1
    while i <= #s do
      local hit
      for _, lit in ipairs(rule[1]) do
        if s:sub(i, i + #lit - 1) == lit and (not hit or #lit > #hit) then
          hit = lit
        end
      end
      if hit then
        out[#out + 1] = rule[2]
        i = i + #hit
      else
        out[#out + 1] = s:sub(i, i)
        i = i + 1
      end
    end
    s = table.concat(out)
  end
  s = s:gsub("[ \t\n]*\\?[ \t\n]+", " ")
  s = s:gsub("[`'\"{}#]", "")
  return s
end

--- bibtex-autokey-abbrev
local function abbrev(s, len)
  if type(len) ~= "number" or #s <= math.abs(len) then
    return s
  elseif len == 0 then
    return ""
  elseif len < 0 then
    return s:sub(1, -len)
  end
  local k = s:lower():find("[^aeiou]", len)
  return k and s:sub(1, k) or s
end

local function is_upper(c)
  return c:match("^%u") ~= nil or (c:byte() or 0) >= 128
end

--- bibtex-autokey-demangle-name: the last name of a full name.
local function demangle_name(full, s)
  local name = full:match("(%u[^, ]*)[^,]*,")
  if not name then
    name = full:match("([^, ]*),")
  end
  if not name then
    -- "First von Last": the capital word after lower-case words
    local words = vim.split(full, " +", { trimempty = true })
    for i = 2, #words do
      if words[i - 1]:match("^%l") and words[i]:match("^%u") then
        name = words[i]
        break
      end
    end
  end
  if not name then
    name = full:match("([^ ]+) *$")
  end
  if not name then
    error(string.format("Name `%s' is incorrectly formed", full), 0)
  end
  return s.name_case(abbrev(name, s.name_length))
end

local AUTOKEY_DEFAULTS = {
  names = 1,
  names_stretch = 0,
  additional_names = "",
  name_case = string.lower,
  name_length = nil,
  name_separator = "",
  year_length = 2,
  titlewords = 5,
  titlewords_stretch = 2,
  titleword_case = string.lower,
  titleword_length = 5,
  titleword_separator = "_",
  name_year_separator = "",
  year_title_separator = ":_",
}

--- Fields of a BibTeX entry text: { type, key, fields = { {name, raw} } }.
local function parse_entry_at(text, at)
  local etype, p = text:match("^@[ \t]*([%w_%-]+)[ \t\n]*()", at)
  if not etype then
    return nil
  end
  local open = text:sub(p, p)
  if open ~= "{" and open ~= "(" then
    return nil
  end
  local close = open == "{" and "}" or ")"
  local lt = etype:lower()
  if lt == "string" or lt == "comment" or lt == "preamble" then
    return nil
  end
  local pos = p + 1
  local key
  key, pos = text:match(close == "}" and "^[ \t\n]*([^%s,}]*)[ \t\n]*()" or "^[ \t\n]*([^%s,)]*)[ \t\n]*()", pos)
  local entry = { type = etype, key = key, fields = {} }
  local n = #text
  while pos <= n do
    local ws = text:match("^[%s,]*", pos)
    pos = pos + #ws
    local c = text:sub(pos, pos)
    if c == close or c == "" or c == "@" then
      break
    end
    local field, after = text:match('^([^%s=,{}()"]+)[ \t\n]*=[ \t\n]*()', pos)
    if not field then
      break
    end
    pos = after
    -- the raw value: up to a comma or the closing delimiter outside braces
    -- and quotes
    local depth, quote, s = 0, false, pos
    while pos <= n do
      local ch = text:sub(pos, pos)
      if ch == "\\" then
        pos = pos + 1
      elseif ch == "{" then
        depth = depth + 1
      elseif ch == "}" then
        if depth == 0 then
          break
        end
        depth = depth - 1
      elseif ch == '"' and depth == 0 then
        quote = not quote
      elseif (ch == "," or ch == close) and depth == 0 and not quote then
        break
      end
      pos = pos + 1
    end
    entry.fields[#entry.fields + 1] = { field, vim.trim(text:sub(s, pos - 1)) }
  end
  return entry, pos
end

--- Entries of BibTeX text, in order.
function M.parse_text(text)
  local out = {}
  local init = 1
  while true do
    local at = text:find("@", init, true)
    if not at then
      break
    end
    local entry, stop = parse_entry_at(text, at)
    if entry then
      entry.start = at
      out[#out + 1] = entry
      init = math.max(stop or at + 1, at + 1)
    else
      init = at + 1
    end
  end
  return out
end

--- Content of a field: the raw value without its outer braces or quotes.
local function field_text(entry, pattern)
  for _, f in ipairs(entry.fields) do
    local name = f[1]:lower()
    for _, p in ipairs(type(pattern) == "table" and pattern or { pattern }) do
      if name == p then
        local v = f[2]
        if v:match("^{.*}$") or v:match('^".*"$') then
          v = v:sub(2, -2)
        end
        return v
      end
    end
  end
  return nil
end

--- bibtex-generate-autokey for a parsed entry, with settings `s` (the
--- bibtex-autokey-* variables; Emacs defaults when nil).
function M.autokey(entry, s)
  s = vim.tbl_extend("force", AUTOKEY_DEFAULTS, s or {})
  -- names: the first author or editor field of the entry
  local names_raw
  for _, f in ipairs(entry.fields) do
    local n = f[1]:lower()
    if n == "author" or n == "editor" then
      names_raw = field_text(entry, n)
      break
    end
  end
  local names = ""
  names_raw = transcribe(names_raw or "")
  if names_raw ~= "" then
    local list = {}
    local rest = names_raw
    while true do
      local a, b = rest:lower():find("[ \t\n]+and[ \t\n]+")
      if not a then
        list[#list + 1] = rest
        break
      end
      list[#list + 1] = rest:sub(1, a - 1)
      rest = rest:sub(b + 1)
    end
    for i, full in ipairs(list) do
      list[i] = demangle_name(full, s)
    end
    local additional = ""
    if type(s.names) == "number" and #list > s.names + s.names_stretch then
      list = vim.list_slice(list, 1, s.names)
      additional = s.additional_names
    end
    names = table.concat(list, s.name_separator) .. additional
  end
  -- year: of the date or year field
  local ystr = field_text(entry, { "date" }) or field_text(entry, { "year" }) or ""
  ystr = transcribe(ystr)
  local year = ystr:match("^(%d%d%d%d)%-%d%d") or ystr:match("^(%d%d%d%d)$")
  year = year or ystr:match("(%d%d%d%d)[^%w]*$")
  if not year then
    error(string.format("Year or date field `%s' invalid", ystr), 0)
  end
  year = year:sub(math.max(1, #year - s.year_length + 1))
  -- title words up to a terminator
  local title = transcribe(field_text(entry, "title") or "")
  local term = title:find("[.!?:;]") or title:find("--", 1, true)
  local term2 = title:find("--", 1, true)
  if term2 and (not term or term2 < term) then
    term = term2
  end
  if term then
    title = title:sub(1, term - 1)
  end
  local ignore = {
    A = true,
    An = true,
    On = true,
    The = true,
    Eine = true,
    Ein = true,
    Der = true,
    Die = true,
    Das = true,
  }
  local words, extra = {}, {}
  local counter = 0
  local pos = 1
  local limit = type(s.titlewords) == "number" and (s.titlewords + s.titlewords_stretch) or math.huge
  while counter < limit do
    local a, b = title:find("[%w\128-\255]+", pos)
    if not a then
      break
    end
    local word = title:sub(a, b)
    pos = b + 1
    local first = word:sub(1, 1)
    if not ignore[word] and is_upper(first) and word:match("^[%w\128-\255]+$") then
      counter = counter + 1
      if type(s.titlewords) ~= "number" or counter <= s.titlewords then
        words[#words + 1] = word
      else
        extra[#extra + 1] = word
      end
    end
  end
  if not title:find("[%w\128-\255]", pos) then
    vim.list_extend(words, extra)
  end
  for i, w in ipairs(words) do
    words[i] = s.titleword_case(abbrev(w, s.titleword_length))
  end
  local tpart = table.concat(words, s.titleword_separator)
  local key = names
  if names ~= "" and year ~= "" then
    key = key .. s.name_year_separator
  end
  key = key .. year
  if not (names == "" and year == "") and tpart ~= "" then
    key = key .. s.year_title_separator
  end
  return key .. tpart
end

--- org-bibtex-autokey: set the key of the headline at `lnum`, generated
--- (`bibtex.autogen_keys`) or asked for.
local function set_key(bufnr, lnum)
  local o = opts()
  local key_prop = o.key_property or "CUSTOM_ID"
  local key
  if o.autogen_keys then
    local hl = headline_at(bufnr, lnum)
    local entry = M.parse_text(M.headline_entry(hl) or "")[1]
    local ok, k = pcall(M.autokey, entry or { fields = {} })
    if not ok then
      utils.error(tostring(k))
      return
    end
    key = k
    if key_prop == "ID" and require("org.id").find(key) then
      utils.warn("Another entry has the same ID")
    end
  else
    key = utils.input({ prompt = "id: " })
    if key == nil then
      return
    end
  end
  put(bufnr, lnum, key_prop, key)
end

---------------------------------------------------------------------------
-- Checking and creating entries
---------------------------------------------------------------------------

--- org-bibtex-ask: read a field, showing its description. nil when empty.
local function ask(field)
  local desc = M.FIELDS[field]
  if not desc then
    error("Field:" .. field .. " is not known", 0)
  end
  vim.api.nvim_echo({ { desc, "Comment" } }, false, {})
  local v = utils.input({ prompt = field .. ": " })
  if v and #v > 0 then
    return v
  end
end

--- org-bibtex-fleshout: ask for the missing required fields (and the
--- optional ones with `optional`) of the headline at `lnum`.
local function fleshout(bufnr, lnum, btype, optional, as_title)
  local spec = type_spec(btype)
  local list = {}
  for _, f in ipairs(spec and spec[3] or {}) do
    if not (as_title and f == "title") then
      list[#list + 1] = f
    end
  end
  if optional then
    vim.list_extend(list, spec and spec[4] or {})
  end
  for _, field in ipairs(list) do
    if type(field) == "table" then
      local present
      for _, f in ipairs(field) do
        if not present and get(headline_at(bufnr, lnum), f) then
          present = f
        end
      end
      if not present then
        present = utils.input_complete("Field: ", field)
        if not present then
          return
        end
        present = present:lower()
      end
      field = present
    end
    if not get(headline_at(bufnr, lnum), field) then
      local value = ask(field)
      if value then
        put(bufnr, lnum, field, value)
      end
    end
  end
  if spec and not get(headline_at(bufnr, lnum), opts().key_property or "CUSTOM_ID") then
    set_key(bufnr, lnum)
  end
end

--- org-bibtex-check: ask for the missing required fields of the entry at
--- the cursor; with a count (C-u) for the optional ones too.
---@param optional? boolean
function M.check(optional, bufnr, lnum)
  if optional == nil then
    optional = vim.v.count > 0
  end
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local hl = headline_at(bufnr, lnum or vim.api.nvim_win_get_cursor(0)[1])
  if not hl then
    return
  end
  local btype = get(hl, opts().type_property_name or "btype")
  if btype then
    fleshout(bufnr, hl.line, btype, optional, opts().treat_headline_as_title ~= false)
  end
end

--- org-bibtex-check-all: check every headline of the buffer.
function M.check_all(optional)
  if optional == nil then
    optional = vim.v.count > 0
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local i = 1
  while true do
    local hls = files.get_buffer(bufnr).headlines
    local hl = hls[i]
    if not hl then
      return
    end
    M.check(optional, bufnr, hl.line)
    i = i + 1
  end
end

--- Insert a new headline after the cursor line (org-insert-heading at the
--- end of that line) with `title`; returns its line.
local function new_heading(title)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  require("org.structure").insert_heading_at_point({ pos = { row, #line }, split = false })
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
  vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { cur .. (title or "") })
  return lnum
end

--- org-bibtex-create: a new headline for a BibTeX entry, asking for its
--- type, title and required fields (with a count, the optional ones too).
--- With `update`, the entry data goes to the headline at the cursor.
---@param optional? boolean
---@param update? boolean
function M.create(optional, update)
  if optional == nil then
    optional = vim.v.count > 0
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local cur = headline_at(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  local default = update and cur and get(cur, opts().type_property_name or "btype") or nil
  local btype = require("org.ui").choose({
    prompt = "Type: ",
    title = "BibTeX entry type",
    items = type_names(),
    default = default,
  })
  if btype == nil then
    return
  end
  if not type_spec(btype) then
    utils.error("Type::" .. btype .. " is not known")
    return
  end
  local lnum
  if update then
    if not cur then
      utils.warn("Before first headline at position " .. vim.api.nvim_win_get_cursor(0)[1])
      return
    end
    lnum = cur.line
  else
    local title = ask("title")
    lnum = new_heading(title)
    put(bufnr, lnum, "TITLE", title or "")
  end
  put(bufnr, lnum, opts().type_property_name or "btype", btype)
  fleshout(bufnr, lnum, btype, optional, not update)
  for _, tag in ipairs(opts().tags or {}) do
    tag_on(bufnr, lnum, tag)
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
  return lnum
end

--- org-bibtex-create-in-current-entry
function M.create_in_current_entry(optional)
  return M.create(optional, true)
end

---------------------------------------------------------------------------
-- BibTeX -> headlines
---------------------------------------------------------------------------

--- An entry of `org-bibtex-entries` from a parsed entry (org-bibtex-read):
--- delimiters stripped, white space collapsed.
local function to_pairs(entry)
  local function clean(v)
    for _, pair in ipairs({ { '"', '"' }, { "{", "}" } }) do
      if #v > 1 and v:sub(1, 1) == pair[1] and v:sub(-1) == pair[2] then
        v = v:sub(2, -2)
      end
    end
    return (v:gsub("[%s\n\r]+", " "))
  end
  local out = { { "type", clean(entry.type) }, { "key", clean(entry.key or "") } }
  for _, f in ipairs(entry.fields) do
    out[#out + 1] = { f[1]:lower(), clean(f[2]) }
  end
  return out
end

local function value_of(pairs_, name)
  for _, p in ipairs(pairs_) do
    if p[1] == name then
      return p[2]
    end
  end
end

--- org-bibtex-read: read the BibTeX entry at the cursor (or before it) of
--- the current buffer. Returns the entries read so far.
function M.read(bufnr, lnum)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local offset = 0
  for i = 1, lnum - 1 do
    offset = offset + #lines[i] + 1
  end
  local eol = offset + #(lines[lnum] or "") + 1
  local found
  for _, e in ipairs(M.parse_text(text)) do
    if e.start <= eol then
      found = e
    end
  end
  if found then
    table.insert(M.entries, 1, to_pairs(found))
  end
  return M.entries
end

--- Read every entry of `text` in front of the entries; returns how many.
local function read_text(text)
  local parsed = M.parse_text(text)
  for i = #parsed, 1, -1 do
    table.insert(M.entries, 1, to_pairs(parsed[i]))
  end
  return #parsed
end

--- org-bibtex-read-buffer: read all entries of a buffer (asked for).
function M.read_buffer(buf)
  if buf == nil then
    local name = utils.input({ prompt = "Buffer: ", completion = "buffer" })
    if not name or name == "" then
      return
    end
    buf = vim.fn.bufnr(name)
    if buf < 0 then
      utils.error("No such buffer: " .. name)
      return
    end
  end
  local n = read_text(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  utils.notify(string.format("Parsed %d entries", n))
  return n
end

--- org-bibtex-read-file: read all entries of a file (asked for).
function M.read_file(file)
  if file == nil then
    file = utils.input({ prompt = "File: ", completion = "file" })
    if not file or vim.trim(file) == "" then
      return
    end
  end
  file = utils.expand(vim.trim(file), vim.fn.getcwd())
  local lines = utils.readfile(file)
  if not lines then
    utils.error("Cannot read " .. file)
    return
  end
  local n = read_text(table.concat(lines, "\n"))
  utils.notify(string.format("Parsed %d entries", n))
  return n
end

--- org-bibtex-write: a headline from the first read entry, after the
--- cursor line; with `update`, its data goes to the headline at the
--- cursor. Without `noindent` the properties are aligned.
---@param noindent? boolean
---@param update? boolean
function M.write(noindent, update)
  if #M.entries == 0 then
    utils.error("No entries in ‘org-bibtex-entries’")
    return
  end
  local entry = table.remove(M.entries, 1)
  local o = opts()
  local bufnr = vim.api.nvim_get_current_buf()
  local edit = require("org.edit")
  local key_prop = o.key_property or "CUSTOM_ID"
  local tags = {}
  local props = {}
  local function add(field, value)
    props[#props + 1] = { prop_name(field), value or "nil" }
  end
  add("TITLE", value_of(entry, "title"))
  add(o.type_property_name or "btype", (value_of(entry, "type") or ""):lower())
  for _, p in ipairs(entry) do
    local k = p[1]
    if k == "key" then
      add(key_prop, p[2])
    elseif k == "keywords" and o.tags_are_keywords then
      for _, kw in ipairs(vim.split(p[2], ", *")) do
        tags[#tags + 1] = clean_tag(kw)
      end
    elseif k ~= "title" and k ~= "type" then
      add(k, p[2])
    end
  end
  vim.list_extend(tags, o.tags or {})
  local lnum
  if update then
    local hl = headline_at(bufnr, vim.api.nvim_win_get_cursor(0)[1])
    if not hl then
      utils.warn("Before first headline")
      return
    end
    lnum = hl.line
    for _, p in ipairs(props) do
      edit.set_property(bufnr, lnum, p[1], p[2])
    end
  else
    local fmt = o.headline_format_function
    local title
    if type(fmt) == "function" then
      local fields = {}
      for _, p in ipairs(entry) do
        fields[p[1]] = p[2]
      end
      title = fmt(fields)
    else
      title = value_of(entry, "title")
    end
    lnum = new_heading(title or "")
    local hl = headline_at(bufnr, lnum)
    local indent = noindent and "" or edit.body_indent(hl and hl.level or 1)
    local drawer = { indent .. ":PROPERTIES:" }
    for _, p in ipairs(props) do
      drawer[#drawer + 1] = noindent and (":" .. p[1] .. ": " .. p[2]) or edit.property_line(indent, p[1], p[2])
    end
    drawer[#drawer + 1] = indent .. ":END:"
    vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, drawer)
  end
  for _, t in ipairs(tags) do
    tag_on(bufnr, lnum, t)
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
  return lnum
end

--- org-bibtex-yank: write the BibTeX entry in the unnamed register as a
--- headline; with a count (C-u), into the headline at the cursor.
function M.yank(update)
  if update == nil then
    update = vim.v.count > 0
  end
  local text = vim.fn.getreg('"')
  local parsed = M.parse_text(text)
  local last = parsed[#parsed]
  if not last then
    utils.error("Yanked text does not appear to contain a BibTeX entry")
    return
  end
  table.insert(M.entries, 1, to_pairs(last))
  return M.write(nil, update)
end

--- org-bibtex-import-from-file: every entry of a BibTeX file as headlines
--- after the cursor.
function M.import_from_file(file)
  if file == nil then
    file = utils.input({ prompt = "File: ", completion = "file" })
    if not file or vim.trim(file) == "" then
      return
    end
  end
  local n = M.read_file(file)
  local bufnr = vim.api.nvim_get_current_buf()
  for _ = 1, n or 0 do
    local lnum = M.write()
    if not lnum then
      return
    end
    local hl = headline_at(bufnr, lnum)
    local stop = hl and hl.properties_range and hl.properties_range[2] or lnum
    vim.api.nvim_buf_set_lines(bufnr, stop, stop, false, { "" })
    vim.api.nvim_win_set_cursor(0, { stop + 1, 0 })
  end
end

--- org-bibtex-search: agenda search for entries matching `text`.
function M.search(text)
  if text == nil then
    text = utils.input({ prompt = "Search string: " })
    if text == nil then
      return
    end
  end
  local o = opts()
  local match = string.format("%s +{:%s%s:}", text, o.prefix or "", o.type_property_name or "btype")
  require("org.agenda").open({
    type = "search",
    match = match,
    header = "Bib search results:",
    search_view_always_boolean = true,
  })
  return match
end

---------------------------------------------------------------------------
-- Links
---------------------------------------------------------------------------

--- Settings of the description of links to entries
--- (org-create-file-search-in-bibtex).
local LINK_DESCRIPTION = {
  names = 1,
  names_stretch = 1,
  name_case = function(s)
    return s
  end,
  name_separator = " & ",
  additional_names = " et al.",
  year_length = 4,
  name_year_separator = " ",
  titlewords = 3,
  titleword_separator = " ",
  titleword_case = function(s)
    return s
  end,
  titleword_length = nil,
  year_title_separator = ": ",
}

--- The entry of a BibTeX buffer at line `lnum`.
local function entry_at(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")
  local eol = 0
  for i = 1, lnum do
    eol = eol + #(lines[i] or "") + 1
  end
  local found
  for _, e in ipairs(M.parse_text(text)) do
    if e.start <= eol then
      found = e
    end
  end
  return found
end

--- A link to the BibTeX entry at the cursor of a `.bib` buffer
--- (org-bibtex-store-link): `file:FILE::KEY` described by its authors,
--- year and title.
function M.store_link(bufnr, lnum)
  local entry = entry_at(bufnr, lnum)
  if not entry or not entry.key or entry.key == "" then
    return nil
  end
  local ok, desc = pcall(M.autokey, entry, LINK_DESCRIPTION)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local path = utils.abbreviate(name)
  local link = "file:" .. path .. "::" .. entry.key
  local pairs_ = to_pairs(entry)
  local extra = { key = entry.key, type = "bibtex", btype = entry.type, link = link }
  for _, f in ipairs({
    "author",
    "doi",
    "editor",
    "title",
    "booktitle",
    "journal",
    "publisher",
    "pages",
    "url",
    "year",
    "month",
    "address",
    "volume",
    "number",
    "annote",
    "series",
    "abstract",
  }) do
    extra[f] = value_of(pairs_, f) or ("[no " .. (f == "annote" and "annotation" or f) .. "]")
  end
  extra.description = ok and desc or nil
  return { link = link, desc = ok and desc or nil, extra = extra }
end

--- Search `key` in a BibTeX buffer (org-execute-file-search-in-bibtex):
--- the cursor goes to the entry `@type{key,` at the top of the window.
--- Returns true in a BibTeX buffer (the search is done there).
function M.file_search(key)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "bib" and not vim.api.nvim_buf_get_name(bufnr):match("%.bib$") then
    return false
  end
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local s = l:find("@%a+[ \t]*{[ \t]*" .. vim.pesc(key) .. "[ \t]*,")
    if s then
      vim.api.nvim_win_set_cursor(0, { i, s - 1 })
      pcall(vim.cmd, "normal! zt")
      break
    end
  end
  return true
end

return M

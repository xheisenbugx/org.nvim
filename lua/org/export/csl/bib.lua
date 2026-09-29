---@mod org.export.csl.bib Bibliography input for the CSL processor
--- (ports of parsebib's reader, citeproc-bibtex.el, citeproc-biblatex.el
--- and citeproc-itemgetters.el; CSL-JSON is read keeping key order)

local U = require("org.export.csl.util")
local R = require("org.export.csl.regex")

local M = {}

M.JSON_FALSE = ":json-false"

local aget = U.aget

---------------------------------------------------------------------------
-- JSON (objects become ordered alists)
---------------------------------------------------------------------------

local function json_decode(s)
  local pos = 1
  local n = #s
  local value

  local function skip()
    pos = s:match("^[ \t\r\n]*()", pos)
  end

  local function str()
    -- at the opening quote
    pos = pos + 1
    local out = {}
    while pos <= n do
      local c = s:sub(pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(out)
      elseif c == "\\" then
        local e = s:sub(pos + 1, pos + 1)
        pos = pos + 2
        if e == "u" then
          local hex = s:sub(pos, pos + 3)
          pos = pos + 4
          local cp = tonumber(hex, 16) or 63
          if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
            local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
            if lo and lo >= 0xDC00 and lo <= 0xDFFF then
              cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
              pos = pos + 6
            end
          end
          out[#out + 1] = U.char(cp)
        else
          out[#out + 1] = ({ b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" })[e] or e
        end
      else
        local run = s:match('^[^"\\]+', pos)
        out[#out + 1] = run
        pos = pos + #run
      end
    end
    error("Malformed JSON string", 0)
  end

  value = function()
    skip()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local obj = {}
      skip()
      if s:sub(pos, pos) == "}" then
        pos = pos + 1
        return obj
      end
      while true do
        skip()
        if s:sub(pos, pos) ~= '"' then
          error("Malformed JSON object", 0)
        end
        local k = str()
        skip()
        if s:sub(pos, pos) ~= ":" then
          error("Malformed JSON object", 0)
        end
        pos = pos + 1
        local v = value()
        obj[#obj + 1] = { k, v }
        skip()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "}" then
          return obj
        elseif d ~= "," then
          error("Malformed JSON object", 0)
        end
      end
    elseif c == "[" then
      pos = pos + 1
      local arr = {}
      skip()
      if s:sub(pos, pos) == "]" then
        pos = pos + 1
        return arr
      end
      while true do
        arr[#arr + 1] = value()
        skip()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "]" then
          return arr
        elseif d ~= "," then
          error("Malformed JSON array", 0)
        end
      end
    elseif c == '"' then
      return str()
    elseif s:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif s:sub(pos, pos + 4) == "false" then
      -- json.el reads false as the (non-nil) keyword :json-false
      pos = pos + 5
      return M.JSON_FALSE
    elseif s:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" then
        error("Malformed JSON", 0)
      end
      pos = pos + #num
      return tonumber(num)
    end
  end

  return value()
end
M.json_decode = json_decode

---------------------------------------------------------------------------
-- BibTeX reader (parsebib-parse-bib-buffer with :expand-strings t)
---------------------------------------------------------------------------

local IDENT = "^[^\"@\\#%%',={}() \t\n\f]+"
local KEY = "^[^\"#%%',={} \t\n\f]+"

local EXCLUDED = { file = true, url = true, doi = true }

--- Parse BibTeX text: returns entries (ordered: key -> field alist with
--- "=key=", "=type=" first) and @String definitions.
function M.parse_bibtex(content, strings)
  local entries = U.ordered()
  strings = strings or {}
  local pos = 1
  local n = #content

  local function skip_ws()
    pos = content:match("^[ \t\n\r\f]*()", pos)
  end

  local function delimited(open, close)
    -- at `open`
    local start = pos
    local depth = 1
    pos = pos + 1
    while depth > 0 and pos <= n do
      local c = content:sub(pos, pos)
      if c == "\\" then
        pos = pos + 1
      elseif c == open then
        depth = depth + 1
      elseif c == close then
        depth = depth - 1
      end
      pos = pos + 1
    end
    if depth ~= 0 then
      error("Opening " .. open .. " has no closing " .. close, 0)
    end
    return content:sub(start, pos - 1)
  end

  local function quoted()
    local start = pos
    pos = pos + 1
    while pos <= n do
      local q = content:find('"', pos, true)
      if not q then
        error("Opening \" has no closing \"", 0)
      end
      pos = q + 1
      if content:sub(q - 1, q - 1) ~= "\\" then
        return content:sub(start, q)
      end
    end
    error("Opening \" has no closing \"", 0)
  end

  local function value()
    skip_ws()
    local c = content:sub(pos, pos)
    if c == "{" then
      return delimited("{", "}")
    elseif c == '"' then
      return quoted()
    end
    local id = content:match(IDENT, pos)
    if not id then
      error("Expected {, \" or identifier", 0)
    end
    pos = pos + #id
    return id
  end

  local function composed()
    local vals = { value() }
    while true do
      skip_ws()
      if content:sub(pos, pos) == "#" then
        pos = pos + 1
        vals[#vals + 1] = value()
      else
        break
      end
    end
    return vals
  end

  local function post_process(name, parts)
    local post = not EXCLUDED[name:lower()]
    local out = {}
    for _, str in ipairs(parts) do
      if post then
        str = R.replace("[[:space:]\t\n\f]+", " ", str)
      end
      local exp = post and strings[str]
      if exp then
        out[#out + 1] = exp
      else
        local m = R.match('\\`["{]\\(.*?\\)["}]\\\'', str)
        out[#out + 1] = m and m[1] or str
      end
    end
    return table.concat(out)
  end

  local function assignment()
    skip_ws()
    local id = content:match(IDENT, pos)
    if not id then
      error("Malformed key=value assignment", 0)
    end
    pos = pos + #id
    skip_ws()
    if content:sub(pos, pos) ~= "=" then
      error("Malformed key=value assignment", 0)
    end
    pos = pos + 1
    return id, composed()
  end

  while true do
    -- an @ at the start of a line, after optional blanks
    local at
    local search = pos
    while true do
      local a = content:find("@", search, true)
      if not a then
        break
      end
      local bol = content:sub(1, a - 1):match("[^\n]*$")
      if bol:match("^[ \t]*$") then
        at = a
        break
      end
      search = a + 1
    end
    if not at then
      break
    end
    pos = at + 1
    local item = content:match(IDENT, pos)
    if not item then
      break
    end
    local litem = item:lower()
    pos = pos + #item
    skip_ws()
    local ok, err = pcall(function()
      if litem == "comment" then
        local c = content:sub(pos, pos)
        if c == "{" then
          delimited("{", "}")
        elseif c == '"' then
          quoted()
        else
          local nl = content:find("\n", pos, true) or n
          pos = nl + 1
        end
      elseif litem == "preamble" then
        local c = content:sub(pos, pos)
        if c == "{" then
          delimited("{", "}")
        elseif c == "(" then
          delimited("(", ")")
        else
          quoted()
        end
      elseif litem == "string" then
        local open = content:sub(pos, pos)
        local close = open == "(" and ")" or "}"
        pos = pos + 1
        local id, vals = assignment()
        skip_ws()
        if content:sub(pos, pos) == close then
          pos = pos + 1
        end
        strings[id] = post_process(id, vals)
      else
        local open = content:sub(pos, pos)
        if open ~= "{" and open ~= "(" then
          error("Malformed entry definition", 0)
        end
        local close = open == "(" and ")" or "}"
        pos = pos + 1
        skip_ws()
        local key = content:match(KEY, pos)
        if not key then
          error("Malformed entry definition", 0)
        end
        pos = pos + #key
        skip_ws()
        if content:sub(pos, pos) ~= "," then
          error("Malformed entry definition", 0)
        end
        pos = pos + 1
        local fields = {}
        local id, vals = assignment()
        table.insert(fields, 1, { id, vals })
        while true do
          skip_ws()
          if content:sub(pos, pos) ~= "," then
            break
          end
          pos = pos + 1
          local save = pos
          local ok2, fid, fvals = pcall(assignment)
          if ok2 then
            table.insert(fields, 1, { fid, fvals })
          else
            pos = save
            break
          end
        end
        skip_ws()
        if content:sub(pos, pos) ~= close then
          error("Malformed entry definition", 0)
        end
        pos = pos + 1
        local entry = { { "=key=", key }, { "=type=", item } }
        for _, f in ipairs(fields) do
          entry[#entry + 1] = { f[1], post_process(f[1], f[2]) }
        end
        entries:put(key, entry)
      end
    end)
    if not ok then
      error(string.format("Malformed bibliography: %s", tostring(err)), 0)
    end
  end
  return entries, strings
end

--- Resolve crossref fields: fields of the parent missing in the child
--- are added (a simplified form of parsebib's biblatex inheritance).
local NO_INHERIT = U.set({
  "ids",
  "crossref",
  "xref",
  "entryset",
  "entrysubtype",
  "execute",
  "label",
  "options",
  "presort",
  "related",
  "relatedoptions",
  "relatedstring",
  "relatedtype",
  "shorthand",
  "shorthandintro",
  "sortkey",
  "=key=",
  "=type=",
})

function M.expand_xrefs(entries)
  entries:each(function(key, fields)
    local xref = aget(fields, "crossref")
    if xref then
      local src = entries:get(xref)
      if src then
        local have = {}
        for _, f in ipairs(fields) do
          have[f[1]:lower()] = true
        end
        local new = vim.list_slice(fields)
        for _, f in ipairs(src) do
          if not NO_INHERIT[f[1]:lower()] and not have[f[1]:lower()] then
            new[#new + 1] = f
          end
        end
        entries:put(key, new)
      end
    end
  end)
end

---------------------------------------------------------------------------
-- BibTeX values to CSL (citeproc-bibtex.el)
---------------------------------------------------------------------------

local COMM_LETTER = {
  ["`A"] = "À",
  ["'A"] = "Á",
  ["^A"] = "Â",
  ["~A"] = "Ã",
  ['"A'] = "Ä",
  rA = "Å",
  cC = "Ç",
  vC = "Č",
  ["'C"] = "Ć",
  ["`E"] = "È",
  ["'E"] = "É",
  ["^E"] = "Ê",
  ['"E'] = "Ë",
  ["`I"] = "Ì",
  ["'I"] = "Í",
  ["^I"] = "Î",
  ['"I'] = "Ï",
  ["~N"] = "Ñ",
  ["`O"] = "Ò",
  ["'O"] = "Ó",
  ["^O"] = "Ô",
  ["~O"] = "Õ",
  ['"O'] = "Ö",
  cS = "Ş",
  vS = "Š",
  ["`U"] = "Ù",
  ["'U"] = "Ú",
  ["^U"] = "Û",
  ['"U'] = "Ü",
  ["'Y"] = "Ý",
  ["`a"] = "à",
  ["'a"] = "á",
  ["^a"] = "â",
  ["~a"] = "ã",
  ['"a'] = "ä",
  ra = "å",
  cc = "ç",
  vc = "č",
  ["'c"] = "ć",
  ["`e"] = "è",
  ["'e"] = "é",
  ["^e"] = "ê",
  ['"e'] = "ë",
  ["`i"] = "ì",
  ["'i"] = "í",
  ["^i"] = "î",
  ['"i'] = "ï",
  ["~n"] = "ñ",
  ["`o"] = "ò",
  ["'o"] = "ó",
  ["^o"] = "ô",
  ["~o"] = "õ",
  ['"o'] = "ö",
  vr = "ř",
  cs = "ş",
  vs = "š",
  ["`u"] = "ù",
  ["'u"] = "ú",
  ["^u"] = "û",
  ['"u'] = "ü",
  ["'y"] = "ý",
  ['"y'] = "ÿ",
  Ho = "ő",
  HO = "Ő",
  Hu = "ű",
  HU = "Ű",
  vz = "ž",
  vZ = "Ž",
}

local TO_UCS = { l = "ł", L = "Ł", o = "ø", O = "Ø", AA = "Å", aa = "å", AE = "Æ", ae = "æ", ss = "ß", i = "ı" }

local DECODE_RE = table.concat({
  "{\\\\\\(?1:['`^~=.\"]\\)[[:space:]]*\\(?2:[[:alpha:]]\\)}",
  "{\\\\\\(?1:[Hruckv]\\)[[:space:]]+\\(?2:[[:alpha:]]\\)}",
  "{\\\\\\(?1:AA\\|AE\\|aa\\|ae\\|ss\\|[LOilo]\\)[[:space:]]*}",
  "\\\\\\(?1:['`^~=.\"Hruckv]\\)[[:space:]]*{\\(?2:[[:alpha:]]\\)}",
  "\\\\\\(?1:[Hruckv]\\)[[:space:]]+\\(?2:[[:alpha:]]\\)",
  "\\\\\\(?1:['`^~=.\"]\\)[[:space:]]*\\(?2:[[:alpha:]]\\)",
  "\\\\\\(?1:AA\\|AE\\|aa\\|ae\\|ss\\|[LOilo]\\)\\b",
}, "\\|")

--- citeproc-bt--decode
function M.decode(s)
  return R.replace(DECODE_RE, function(x, md)
    local command = md:str(1)
    local letter = md:str(2)
    if letter then
      return COMM_LETTER[(command or "") .. letter] or ("\\" .. x)
    end
    return TO_UCS[command] or x
  end, s)
end

local COMMAND_RE = "\\\\[a-zA-Z]+{\\(\\(?:.\\|\n\\)*?\\)}"
local COMMAND_WO_ARG_RE = "\\\\[a-zA-Z]+\\>"
local BRACES_RE = "\\(\\`\\|[^\\\\]\\){\\(\\(?:\\(?:.\\|\n\\)*?[^\\\\]\\)?\\)}"

--- citeproc-bt--process-brackets
function M.process_brackets(s, lhb, rhb)
  local result = s
  while true do
    local b, md = R.search(COMMAND_RE, result)
    if b then
      local cps = U.codepoints(result)
      result = U.from_codepoints(cps, 1, b) .. (md:str(1) or "") .. U.from_codepoints(cps, md:e(0) + 1, #cps)
    else
      b, md = R.search(COMMAND_WO_ARG_RE, result)
      if b then
        local cps = U.codepoints(result)
        result = U.from_codepoints(cps, 1, b) .. U.from_codepoints(cps, md:e(0) + 1, #cps)
      else
        b, md = R.search(BRACES_RE, result)
        if b then
          local cps = U.codepoints(result)
          result = U.from_codepoints(cps, 1, b)
            .. (md:str(1) or "")
            .. (lhb or "")
            .. (md:str(2) or "")
            .. (rhb or "")
            .. U.from_codepoints(cps, md:e(0) + 1, #cps)
        else
          break
        end
      end
    end
  end
  return U.replace("\\}", "}", U.replace("\\{", "{", result))
end

local function preprocess(s)
  if s:sub(1, 1) == '"' and s:sub(-1) == '"' and #s >= 2 then
    s = s:sub(2, -2)
  end
  return U.replace("\\&", "&", s)
end

--- citeproc-bt--to-csl
function M.bt_to_csl(s, with_nocase)
  if not s or #s == 0 then
    return s
  end
  s = preprocess(s)
  s = M.decode(s)
  s = M.process_brackets(s, with_nocase and '<span class="nocase">' or nil, with_nocase and "</span>" or nil)
  s = U.replace_all_seq(s, { { "\n", " " }, { "~", " " }, { "--", "–" } })
  return U.trim(s)
end

local DROPPING = U.set({ "dela", "il", "sen", "z", "ze" })

local function parse_family(f)
  local result = {}
  local family
  if #f > 1 then
    local firsts = vim.list_slice(f, 1, #f - 1)
    local particle = {}
    while #firsts > 0 and U.lowercase_p(firsts[1]) do
      table.insert(particle, 1, table.remove(firsts, 1))
    end
    if #particle > 0 then
      local kind = DROPPING[particle[1]] and "dropping-particle" or "non-dropping-particle"
      local rev = {}
      for i = #particle, 1, -1 do
        rev[#rev + 1] = particle[i]
      end
      table.insert(result, 1, { kind, rev })
    end
    family = firsts
    family[#family + 1] = f[#f]
  else
    family = f
  end
  table.insert(result, 1, { "family", family })
  return result
end

--- citeproc-bt--to-csl-name
local function to_csl_name(name)
  local tokens = {}
  for _, t in ipairs(R.slice_by_matches(name, "\\(,\\|[[:space:]]+\\)")) do
    if not U.blank_str(t) then
      tokens[#tokens + 1] = t
    end
  end
  local parts = { {} }
  for _, t in ipairs(tokens) do
    if t == "," then
      parts[#parts + 1] = {}
    else
      table.insert(parts[#parts], t)
    end
  end
  local nonempty = {}
  for _, p in ipairs(parts) do
    if #p > 0 then
      nonempty[#nonempty + 1] = p
    end
  end
  parts = nonempty
  local result = {}
  local family
  if #parts <= 1 then
    local nm = parts[1] or {}
    local idx
    for i, t in ipairs(nm) do
      if U.lowercase_p(t) then
        idx = i
        break
      end
    end
    if idx then
      family = vim.list_slice(nm, idx)
      if idx > 1 then
        table.insert(result, 1, { "given", vim.list_slice(nm, 1, idx - 1) })
      end
    else
      family = { nm[#nm] }
      if #nm > 1 then
        table.insert(result, 1, { "given", vim.list_slice(nm, 1, #nm - 1) })
      end
    end
  elseif #parts == 2 then
    family = parts[1]
    table.insert(result, 1, { "given", parts[2] })
  else
    family = parts[1]
    table.insert(result, 1, { "suffix", parts[2] })
    table.insert(result, 1, { "given", parts[3] })
  end
  local all = parse_family(family)
  for _, p in ipairs(result) do
    all[#all + 1] = p
  end
  local out = {}
  for _, p in ipairs(all) do
    out[#out + 1] = { p[1], table.concat(p[2], " ") }
  end
  return out
end

--- citeproc-bt--parse-attr-val-field
local function parse_attr_val_field(f)
  local bracketless = f:gsub("[{}]", "")
  local split = {}
  for _, x in ipairs(R.split(bracketless, "=", false)) do
    local t = x:gsub("^ +", ""):gsub(" +$", "")
    if t ~= "" then
      split[#split + 1] = t
    end
  end
  local function strim(x)
    return (x:gsub('^[ "]+', ""):gsub('[ "]+$', ""))
  end
  local first_attr = strim(table.remove(split, 1))
  local rev = {}
  for i = #split, 1, -1 do
    rev[#rev + 1] = split[i]
  end
  local result = { { nil, strim(table.remove(rev, 1)) } }
  for _, elt in ipairs(rev) do
    local cps = U.codepoints(elt)
    local p = #cps - 2
    local found = false
    while p > 0 and not found do
      if cps[p + 1] == 44 then
        found = true
      else
        p = p - 1
      end
    end
    if not found then
      error(string.format('Could not parse biblatex key-value list "%s"', f), 0)
    end
    local key = U.trim(U.from_codepoints(cps, p + 2, #cps))
    local val = strim(U.from_codepoints(cps, 1, p))
    result[1][1] = key
    table.insert(result, 1, { nil, val })
  end
  result[1][1] = first_attr
  return result
end

local function ext_desc_to_csl_name(name)
  local parsed = parse_attr_val_field(name)
  local dropping = aget(parsed, "useprefix") == "false"
  local out = {}
  for _, it in ipairs(parsed) do
    local k = it[1]
    if k == "family" or k == "given" or k == "suffix" then
      out[#out + 1] = it
    elseif k == "prefix" then
      out[#out + 1] = { dropping and "dropping-particle" or "non-dropping-particle", it[2] }
    end
  end
  return out
end

--- citeproc-bt--to-csl-names
function M.to_csl_names(n)
  local out = {}
  for _, x in ipairs(R.split(n, "\\band\\b", false)) do
    local trimmed = U.trim(x)
    if trimmed == "" then
      out[#out + 1] = { { "family", "" } }
    elseif trimmed:find("=", 1, true) then
      out[#out + 1] = ext_desc_to_csl_name(trimmed)
    elseif trimmed:sub(1, 1) == "{" and trimmed:sub(-1) == "}" then
      out[#out + 1] = { { "literal", M.bt_to_csl(trimmed:sub(2, -2)) } }
    else
      out[#out + 1] = to_csl_name(M.bt_to_csl(trimmed))
    end
  end
  return out
end

local MONTHS = { jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6, jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12 }

--- citeproc-bt--to-csl-date
function M.bt_to_csl_date(year, month)
  local m = R.match("[[:digit:]]+", year or "")
  if not m then
    error(string.format("Couldn't parse year: '%s'%s as a date", tostring(year), month and (" and month: '" .. month .. "'") or ""), 0)
  end
  local y = U.to_number(m[0])
  local mo = month and MONTHS[U.downcase(month)]
  local date = { y }
  if mo then
    date[2] = mo
  end
  return { { "date-parts", { date } } }
end

---------------------------------------------------------------------------
-- biblatex entries to CSL (citeproc-biblatex.el)
---------------------------------------------------------------------------

local BLT_TYPES = {
  article = "article-journal",
  book = "book",
  periodical = "book",
  booklet = "pamphlet",
  bookinbook = "chapter",
  misc = "article",
  other = "article",
  standard = "legislation",
  collection = "book",
  conference = "paper-conference",
  dataset = "dataset",
  electronic = "webpage",
  inbook = "chapter",
  incollection = "chapter",
  inreference = "entry-encyclopedia",
  inproceedings = "paper-conference",
  manual = "book",
  mastersthesis = "thesis",
  mvbook = "book",
  mvcollection = "book",
  mvproceedings = "book",
  mvreference = "book",
  online = "webpage",
  patent = "patent",
  phdthesis = "thesis",
  proceedings = "book",
  reference = "book",
  report = "report",
  software = "software",
  suppbook = "chapter",
  suppcollection = "chapter",
  techreport = "report",
  thesis = "thesis",
  unpublished = "manuscript",
  www = "webpage",
  artwork = "graphic",
  audio = "song",
  commentary = "book",
  image = "figure",
  jurisdiction = "legal_case",
  legislation = "bill",
  legal = "treaty",
  letter = "personal_communication",
  movie = "motion_picture",
  music = "song",
  performance = "speech",
  review = "review",
  video = "motion_picture",
  data = "dataset",
  letters = "personal_communication",
  newsarticle = "article-newspaper",
}

local function blt_type(ty, subtype)
  if ty == "article" or ty == "periodical" or ty == "supperiodical" then
    if subtype == "magazine" then
      return "article-magazine"
    elseif subtype == "newspaper" then
      return "article-newspaper"
    end
    return "article-journal"
  end
  return BLT_TYPES[ty]
end

local REFTYPE_GENRE = {
  mastersthesis = "Master's thesis",
  phdthesis = "PhD thesis",
  mathesis = "Master's thesis",
  resreport = "research report",
  techreport = "technical report",
  patreqfr = "French patent request",
  patenteu = "European patent",
  patentus = "U.S. patent",
}

local ARTICLE_TYPES = U.set({ "article", "periodical", "suppperiodical", "review" })
local CHAPTER_TYPES = U.set({ "inbook", "incollection", "inproceedings", "inreference", "bookinbook" })
local COLLECTION_TYPES = U.set({
  "book",
  "collection",
  "proceedings",
  "reference",
  "mvbook",
  "mvcollection",
  "mvproceedings",
  "mvreference",
  "bookinbook",
  "inbook",
  "incollection",
  "inproceedings",
  "inreference",
  "suppbook",
  "suppcollection",
})

local NAMES_ALIST = {
  { "author", "author" },
  { "editor", "editor" },
  { "bookauthor", "container-author" },
  { "translator", "translator" },
}
local EDITORTYPE = {
  organizer = "organizer",
  director = "director",
  compiler = "compiler",
  editor = "editor",
  collaborator = "contributor",
}
local DATES_ALIST = { { "eventdate", "event-date" }, { "origdate", "original-date" }, { "urldate", "accessed" } }
local PUBLISHER_FIELDS = { "school", "institution", "organization", "howpublished", "publisher" }
local ETYPE_BASEURL = {
  arxiv = "https://arxiv.org/abs/",
  jstor = "https://www.jstor.org/stable/",
  pubmed = "https://www.ncbi.nlm.nih.gov/pubmed/",
  googlebooks = "https://books.google.com?id=",
}
local STANDARD_ALIST = {
  { "volume", "volume" },
  { "part", "part" },
  { "edition", "edition" },
  { "version", "version" },
  { "volumes", "number-of-volumes" },
  { "pagetotal", "number-of-pages" },
  { "chapter", "chapter-number" },
  { "pages", "page" },
  { "origpublisher", "original-publisher" },
  { "venue", "event-place" },
  { "origlocation", "original-publisher-place" },
  { "address", "publisher-place" },
  { "doi", "DOI" },
  { "isbn", "ISBN" },
  { "issn", "ISSN" },
  { "pmid", "PMID" },
  { "pmcid", "PMCID" },
  { "library", "call-number" },
  { "abstract", "abstract" },
  { "annotation", "annote" },
  { "annote", "annote" },
  { "pubstate", "status" },
  { "language", "language" },
  { "version", "version" },
  { "keywords", "keyword" },
  { "label", "citation-label" },
}
local TITLE_ALIST = { { "eventtitle", "event-title" }, { "origtitle", "original-title" }, { "series", "collection-title" } }

local TITLECASE_LANGIDS = U.set({
  "american",
  "british",
  "canadian",
  "english",
  "australian",
  "newzealand",
  "USenglish",
  "UKenglish",
})

local LANGID_TO_LANG = {
  english = "en-US",
  USenglish = "en-US",
  american = "en-US",
  british = "en-GB",
  UKenglish = "en-GB",
  canadian = "en-US",
  australian = "en-GB",
  newzealand = "en-GB",
  afrikaans = "af-ZA",
  arabic = "ar",
  basque = "eu",
  bulgarian = "bg-BG",
  catalan = "ca-AD",
  croatian = "hr-HR",
  czech = "cs-CZ",
  danish = "da-DK",
  dutch = "nl-NL",
  estonian = "et-EE",
  finnish = "fi-FI",
  canadien = "fr-CA",
  acadian = "fr-CA",
  french = "fr-FR",
  francais = "fr-FR",
  austrian = "de-AT",
  naustrian = "de-AT",
  german = "de-DE",
  germanb = "de-DE",
  ngerman = "de-DE",
  greek = "el-GR",
  polutonikogreek = "el-GR",
  hebrew = "he-IL",
  hungarian = "hu-HU",
  icelandic = "is-IS",
  italian = "it-IT",
  japanese = "ja-JP",
  latvian = "lv-LV",
  lithuanian = "lt-LT",
  magyar = "hu-HU",
  mongolian = "mn-MN",
  norsk = "nb-NO",
  nynorsk = "nn-NO",
  farsi = "fa-IR",
  polish = "pl-PL",
  brazil = "pt-BR",
  brazilian = "pt-BR",
  portugues = "pt-PT",
  portuguese = "pt-PT",
  romanian = "ro-RO",
  russian = "ru-RU",
  serbian = "sr-RS",
  serbianc = "sr-RS",
  slovak = "sk-SK",
  slovene = "sl-SL",
  spanish = "es-ES",
  swedish = "sv-SE",
  thai = "th-TH",
  turkish = "tr-TR",
  ukrainian = "uk-UA",
  vietnamese = "vi-VN",
  latin = "la",
}

--- citeproc-s-sentence-case-title
function M.sentence_case_title(s, omit_nocase)
  if U.blank(s) then
    return s
  end
  local sliced = R.slice_by_matches(s, '\\(<span class="nocase">\\|</span>\\|: +["\'“‘]*[[:alpha:]]\\)')
  local protect = 0
  local first = true
  local out = {}
  for _, slice in ipairs(sliced) do
    local r
    if slice == '<span class="nocase">' then
      protect = protect + 1
      r = not omit_nocase and slice or nil
    elseif slice == "</span>" then
      protect = protect - 1
      r = not omit_nocase and slice or nil
    elseif R.test("^: +[\"'“‘]*[[:alpha:]]", slice) then
      first = false
      r = slice
    elseif protect > 0 then
      first = false
      r = slice
    elseif not first then
      r = U.downcase(slice)
    else
      first = false
      local b = R.search("[[:alpha:]]", slice)
      if b then
        local cps = U.codepoints(slice)
        r = U.from_codepoints(cps, 1, b)
          .. U.upcase(U.char(cps[b + 1]))
          .. U.downcase(U.from_codepoints(cps, b + 2, #cps))
      else
        r = slice
      end
    end
    if r then
      out[#out + 1] = r
    end
  end
  return table.concat(out)
end

local function blt_to_csl_title(s, with_nocase, sent_case)
  if sent_case then
    return M.sentence_case_title(M.bt_to_csl(s, true), not with_nocase)
  end
  return M.bt_to_csl(s, with_nocase)
end

local function parse_blt_date(d)
  local t = d:find("T", 1, true)
  if t then
    d = d:sub(1, t - 1)
  end
  local out = {}
  for _, it in ipairs(R.split(d, "-", false)) do
    local v = U.to_number(it)
    if v == 0 then
      error(string.format("Couldn't parse '%s' as a date", d), 0)
    end
    out[#out + 1] = v
  end
  return out
end

--- citeproc-blt--to-csl-date
function M.blt_to_csl_date(d)
  local parts = {}
  for _, s in ipairs(R.split(d, "/", false)) do
    parts[#parts + 1] = parse_blt_date(s)
  end
  return { { "date-parts", parts } }
end

--- citeproc-blt-entry-to-csl
function M.blt_entry_to_csl(entry, omit_nocase, no_sentcase_wo_langid)
  local b = {}
  for _, p in ipairs(entry) do
    if p[2] ~= "" then
      b[#b + 1] = { p[1]:lower(), p[2] }
    end
  end
  local ty = (aget(b, "=type=") or ""):lower()
  local subtype = aget(b, "entrysubtype")
  local csl_type = blt_type(ty, subtype)
  local is_article = ARTICLE_TYPES[ty]
  local is_periodical = ty == "periodical"
  local is_chapter = CHAPTER_TYPES[ty]
  local langid = aget(b, "langid")
  local sent_case = (langid and TITLECASE_LANGIDS[langid]) or (langid == nil and not no_sentcase_wo_langid)
  local with_nocase = not omit_nocase
  local result = {}
  local function push(k, v)
    table.insert(result, 1, { k, v })
  end
  local function get_title(v)
    local val = aget(b, v)
    if val then
      return blt_to_csl_title(val, with_nocase, sent_case)
    end
  end
  local function get_standard(v)
    local val = aget(b, v)
    if val then
      return M.bt_to_csl(val)
    end
  end
  if langid then
    push("language", LANGID_TO_LANG[langid])
  end
  push("type", csl_type)
  local reftype = aget(b, "type")
  if reftype then
    push("genre", REFTYPE_GENRE[reftype] or M.bt_to_csl(reftype))
  end
  push("blt-type", ty)
  local editortype, editor = aget(b, "editortype"), aget(b, "editor")
  if editortype and editor and EDITORTYPE[editortype] then
    push(EDITORTYPE[editortype], M.to_csl_names(editor))
  end
  local editoratype, editora = aget(b, "editoratype"), aget(b, "editora")
  if editoratype and editora and EDITORTYPE[editoratype] then
    push(EDITORTYPE[editoratype], M.to_csl_names(editora))
  end
  local issued
  if aget(b, "date") then
    issued = M.blt_to_csl_date(aget(b, "date"))
  elseif aget(b, "year") then
    issued = M.bt_to_csl_date(aget(b, "year"), aget(b, "month"))
  end
  if issued then
    push("issued", issued)
  end
  local number = aget(b, "number")
  if number then
    if COLLECTION_TYPES[ty] then
      push("collection-number", number)
    elseif is_article then
      local issue = aget(b, "issue")
      push("issue", issue and (number .. ", " .. issue) or number)
    else
      push("number", number)
    end
  end
  local maintitle = get_title("maintitle")
  local title
  if is_periodical then
    title = get_title("issuetitle")
  elseif maintitle and not is_chapter then
    title = maintitle
  else
    title = get_title("title")
  end
  local subtitle = get_title(is_periodical and "issuesubtitle" or ((maintitle and not is_chapter) and "mainsubtitle" or "subtitle"))
  local title_addon = get_title((maintitle and not is_chapter) and "maintitleaddon" or "titleaddon")
  local volume_title = maintitle and get_title(is_chapter and "booktitle" or "title")
  local volume_subtitle = maintitle and get_title(is_chapter and "booksubtitle" or "subtitle")
  local volume_title_addon = maintitle and get_title(is_chapter and "booktitleaddon" or "titleaddon")
  local container_title = (is_periodical and get_title("title"))
    or (is_chapter and maintitle)
    or (is_chapter and get_title("booktitle"))
    or get_title("journaltitle")
    or get_title("journal")
  local container_subtitle = (is_periodical and get_title("subtitle"))
    or (is_chapter and get_title("mainsubtitle"))
    or (is_chapter and get_title("booksubtitle"))
    or get_title("journalsubtitle")
  local container_title_addon = (is_periodical and get_title("titleaddon"))
    or (is_chapter and get_title("maintitleaddon"))
    or (is_chapter and get_title("booktitleaddon"))
  local container_title_short = (is_periodical and not maintitle and get_title("titleaddon")) or get_title("shortjournal")
  local title_short = ((not maintitle or is_chapter) and get_title("shorttitle"))
    or ((subtitle or title_addon) and not maintitle and title)
  if title then
    push("title", title .. (subtitle and (": " .. subtitle) or "") .. (title_addon and (". " .. title_addon) or ""))
  end
  if title_short then
    push("title-short", title_short)
  end
  if volume_title then
    push(
      "volume-title",
      volume_title .. (volume_subtitle and (": " .. volume_subtitle) or "") .. (volume_title_addon and (". " .. volume_title_addon) or "")
    )
  end
  if container_title then
    push(
      "container-title",
      container_title
        .. (container_subtitle and (": " .. container_subtitle) or "")
        .. (container_title_addon and (". " .. container_title_addon) or "")
    )
  end
  if container_title_short then
    push("container-title-short", container_title_short)
  end
  local pubs = {}
  for _, f in ipairs(PUBLISHER_FIELDS) do
    local v = get_standard(f)
    if v then
      pubs[#pubs + 1] = v
    end
  end
  if #pubs > 0 then
    push("publisher", table.concat(pubs, "; "))
  end
  local place = get_standard("location") or get_standard("address")
  if place then
    push(ty == "patent" and "jurisdiction" or "publisher-place", place)
  end
  local url = aget(b, "url")
  if url then
    url = U.replace("\\", "", url)
  else
    local etype = aget(b, "eprinttype") or aget(b, "archiveprefix")
    local eprint = aget(b, "eprint")
    local base = etype and ETYPE_BASEURL[etype]
    if etype and eprint and base then
      url = base .. eprint
    end
  end
  if url then
    push("URL", url)
  end
  local note, addendum = get_standard("note"), get_standard("addendum")
  if note and addendum then
    push("note", note .. ". " .. addendum)
  elseif note or addendum then
    push("note", note or addendum)
  end
  local rest = {}
  local function rpush(k, v)
    table.insert(rest, 1, { k, v })
  end
  for _, p in ipairs(b) do
    local k, v = p[1], p[2]
    local sk = aget(STANDARD_ALIST, k)
    if sk and aget(result, sk) == nil then
      rpush(sk, M.bt_to_csl(v))
    end
    local nk = aget(NAMES_ALIST, k)
    if nk and aget(result, nk) == nil then
      rpush(nk, M.to_csl_names(v))
    end
    local dk = aget(DATES_ALIST, k)
    if dk and aget(result, dk) == nil then
      rpush(dk, M.blt_to_csl_date(v))
    end
    local tk = aget(TITLE_ALIST, k)
    if tk then
      rpush(tk, blt_to_csl_title(v, with_nocase, sent_case))
    end
  end
  return U.concat(result, rest)
end

---------------------------------------------------------------------------
-- Item getter (citeproc-hash-itemgetter-from-any)
---------------------------------------------------------------------------

local function readfile(f)
  local fd = io.open(f, "rb")
  if not fd then
    error(string.format("Cannot read bibliography file %s", f), 0)
  end
  local c = fd:read("*a")
  fd:close()
  return c
end

--- A getter for the bibliography `files`: called with "itemids" it lists
--- the ids, called with a list of ids it returns an alist of items.
function M.itemgetter_from_any(files, no_sentcase_wo_langid)
  local cache = U.ordered()
  local bt_entries = U.ordered()
  local bt_strings = {}
  for _, file in ipairs(files) do
    local ext = file:match("%.([^./]+)$")
    if ext == "json" then
      local items = json_decode(readfile(file))
      for _, item in ipairs(items or {}) do
        local id = aget(item, "id")
        if id ~= nil then
          cache:put(U.num_str(id), item)
        end
      end
    elseif ext == "bib" or ext == "bibtex" then
      local entries = M.parse_bibtex(readfile(file), bt_strings)
      entries:each(function(k, v)
        bt_entries:put(k, v)
      end)
    else
      error(string.format("Unknown bibliography extension: %q", tostring(ext)), 0)
    end
  end
  M.expand_xrefs(bt_entries)
  bt_entries:each(function(key, entry)
    local ok, res = pcall(M.blt_entry_to_csl, entry, nil, no_sentcase_wo_langid)
    if not ok then
      error(string.format("Couldn't parse the bib(la)tex entry with key '%s', the error was: %s", key, tostring(res)), 0)
    end
    cache:put(key, res)
  end)
  return function(x)
    if x == "itemids" then
      return vim.list_slice(cache.keys)
    end
    local out = {}
    for _, id in ipairs(x) do
      out[#out + 1] = { id, cache:get(id) }
    end
    return out
  end
end

return M

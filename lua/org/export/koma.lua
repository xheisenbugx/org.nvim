---@mod org.export.koma KOMA-Script letter back-end (port of Emacs ox-koma-letter.el)
---
--- Derived from the LaTeX back-end, like Emacs: the document is a scrlttr2
--- letter. Keywords (LCO, FROM_ADDRESS, TO_ADDRESS, PHONE_NUMBER, URL,
--- FROM_LOGO, PLACE, LOCATION, SUBJECT, OPENING, CLOSING, SIGNATURE) and
--- headlines tagged with a special tag (to, from, closing, location,
--- after_closing, ps, encl, cc, after_letter) fill the letter variables;
--- other headlines only contribute their contents (the first untagged one
--- can be the opening).

local ox = require("org.export.ox")
local element = require("org.export.element")
local latex = require("org.export.latex")
local data = require("org.export.latex_data")

local M = {}

M.extension = "tex"

local fmt = string.format
local nw = ox.nw
local trim = ox.trim

--- Default of the in-buffer sentinels ('koma-letter:empty): the setting
--- was not made in the buffer. A table (options defaults are deep-copied),
--- recognised by its field.
local EMPTY = { koma_letter_empty = true }
M.EMPTY = EMPTY

local function empty_p(v)
  return type(v) == "table" and v.koma_letter_empty == true
end

--- org-koma-letter-special-tags-in-letter
M.special_tags_in_letter = { "to", "from", "closing", "location" }
--- org-koma-letter-special-tags-after-closing
M.special_tags_after_closing = { "after_closing", "ps", "encl", "cc" }
--- org-koma-letter-special-tags-as-macro
M.special_tags_as_macro = { "ps", "encl", "cc" }
--- org-koma-letter-special-tags-after-letter
M.special_tags_after_letter = { "after_letter" }

--- The class installed by ox-koma-letter in org-latex-classes.
M.default_class = { "default-koma-letter", "\\documentclass[11pt]{scrlttr2}" }

local function kcfg()
  return (require("org.config").opts.export or {}).koma_letter or {}
end

local function opt(name, default)
  local v = kcfg()[name]
  if v == nil then
    return default
  end
  return v
end

--- org-koma-letter--get-value: strings as is, functions called.
local function get_value(v)
  if type(v) == "function" then
    return v()
  end
  return v
end

--- nil for nil, false, "" and empty secondary strings / lists.
local function present(v)
  if v == nil or v == false or v == "" then
    return nil
  end
  if type(v) == "table" and v.type == nil and #v == 0 then
    return nil
  end
  return v
end

--- (format "%s" v) of a string that may be nil.
local function str(v)
  if v == nil or v == false then
    return "nil"
  end
  return v
end

local function contains(list, x)
  for _, y in ipairs(list or {}) do
    if y == x then
      return true
    end
  end
  return false
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- org-koma-letter--get-tagged-contents: trimmed contents of the last
--- headline tagged `key`, nil when blank.
local function get_tagged_contents(key, info)
  for _, entry in ipairs(info.koma_special_contents or {}) do
    if entry[1] == key then
      local v = entry[2]
      return v and nw(trim(v)) and trim(v) or nil
    end
  end
  return nil
end

--- org-koma-letter--special-contents-inline
local function special_contents_inline(keywords, info)
  local out = {}
  for _, key in ipairs(keywords or {}) do
    key = tostring(key)
    local value = get_tagged_contents(key, info)
    if not value then
      out[#out + 1] = ""
    elseif contains(info.koma_special_tags_as_macro, key) then
      out[#out + 1] = fmt("\\%s{%s}\n", key, value)
    else
      out[#out + 1] = value
    end
  end
  return table.concat(out, "\n")
end

--- org-koma-letter--add-latex-newlines
local function add_latex_newlines(s)
  local t = trim(s or "")
  if not nw(t) then
    return nil
  end
  return (t:gsub("\n", "\\\\\n"))
end
M.add_latex_newlines = add_latex_newlines

--- org-koma-letter--special-tag: first tag of `h` that is special.
local function special_tag(h, info)
  local specials = {}
  for _, k in ipairs({
    "koma_special_tags_in_letter",
    "koma_special_tags_after_closing",
    "koma_special_tags_after_letter",
  }) do
    for _, t in ipairs(info[k] or {}) do
      specials[#specials + 1] = tostring(t)
    end
  end
  for _, tag in ipairs(ox.get_tags(h, info)) do
    if contains(specials, tag) then
      return tag
    end
  end
  return nil
end

--- org-koma-letter--keyword-or-headline
local function keyword_or_headline(key, pred, info)
  local keyword_candidate = present(info[key])
  local headline_candidate
  if info.koma_with_headline_opening and (info.koma_special_headings or not keyword_candidate) then
    headline_candidate = element.map(info.parse_tree, "headline", function(h)
      if pred(h, info) then
        return h.title or {}
      end
    end, { first_match = true, ignore = info.ignore })
  end
  return ox.data(headline_candidate or keyword_candidate or "", info)
end

--- org-latex--format-spec (with the title from the subject when needed).
local function format_spec(info, title)
  local lang = info.language
  local plist = data.languages[lang]
  lang = plist and plist.lang_name or lang or ""
  local date = ox.get_date(info)
  return {
    t = title,
    a = info.with_author and ox.data(info.author, info) or "",
    s = info.with_title and ox.data(info.subtitle, info) or "",
    k = ox.data(info.keywords_latex, info),
    d = ox.data(info.description_latex, info),
    c = info.with_creator and (info.creator or "") or "",
    l = lang,
    L = (lang:gsub("(%w)(%w*)", function(a, b)
      return a:upper() .. b:lower()
    end)),
    D = type(date) == "string" and date or ox.data(date, info),
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
-- Settings (org-koma-letter--build-settings)
---------------------------------------------------------------------------

local function build_settings(scope, info)
  local function check_scope(setting)
    local v = info["koma_inbuffer_" .. setting:gsub("-", "_")]
    if scope == "global" then
      return empty_p(v)
    end
    return not empty_p(v)
  end
  local function heading_or_key_value(heading, key, scoped)
    local heading_val = get_tagged_contents(heading, info)
    local key_val = type(info[key]) == "string" and nw(info[key]) and info[key] or nil
    local scopedp = check_scope(scoped or heading)
    if (key_val and scopedp) or heading_val then
      if not (scope == "global" and heading_val) then
        if scopedp then
          return key_val
        end
        return heading_val
      end
    end
    return nil
  end
  local function bool(v)
    return (v and v ~= "") and "true" or "false"
  end
  local out = {}
  -- Name
  local author = present(info.author)
  if author and check_scope("author") then
    out[#out + 1] = fmt("\\setkomavar{fromname}{%s}\n", ox.data(author, info))
  end
  -- From
  local from = heading_or_key_value("from", "koma_from_address")
  if from then
    out[#out + 1] = fmt("\\setkomavar{fromaddress}{%s}\n", str(add_latex_newlines(from)))
  end
  -- Email
  local email = present(info.email)
  if email and check_scope("email") then
    out[#out + 1] = fmt("\\setkomavar{fromemail}{%s}\n", email)
  end
  if check_scope("with-email") then
    out[#out + 1] = fmt("\\KOMAoption{fromemail}{%s}\n", bool(info.with_email))
  end
  -- Phone number
  local phone = info.koma_phone_number
  if type(phone) == "string" and nw(phone) and check_scope("phone-number") then
    out[#out + 1] = fmt("\\setkomavar{fromphone}{%s}\n", phone)
  end
  if check_scope("with-phone") then
    out[#out + 1] = fmt("\\KOMAoption{fromphone}{%s}\n", bool(info.koma_with_phone))
  end
  -- URL
  local url = info.koma_url
  if type(url) == "string" and nw(url) and check_scope("url") then
    out[#out + 1] = fmt("\\setkomavar{fromurl}{%s}\n", url)
  end
  if check_scope("with-url") then
    out[#out + 1] = fmt("\\KOMAoption{fromurl}{%s}\n", bool(info.koma_with_url))
  end
  -- From logo
  local logo = info.koma_from_logo
  if type(logo) == "string" and nw(logo) and check_scope("from-logo") then
    out[#out + 1] = fmt("\\setkomavar{fromlogo}{%s}\n", logo)
  end
  if check_scope("with-from-logo") then
    out[#out + 1] = fmt("\\KOMAoption{fromlogo}{%s}\n", bool(info.koma_with_from_logo))
  end
  -- Signature
  local heading_val = info.koma_with_headline_opening and get_tagged_contents("closing", info) or nil
  local signature = type(info.koma_signature) == "string" and nw(info.koma_signature) and info.koma_signature or nil
  local signature_scope = check_scope("signature")
  if ((signature and signature_scope) or heading_val) and not (scope == "global" and heading_val) then
    out[#out + 1] = fmt("\\setkomavar{signature}{%s}\n", str(signature_scope and signature or heading_val))
  end
  -- Back address
  if check_scope("with-backaddress") then
    out[#out + 1] = fmt("\\KOMAoption{backaddress}{%s}\n", bool(info.koma_with_backaddress))
  end
  -- Place
  local with_place_set = check_scope("with-place")
  local place_set = check_scope("place")
  if (with_place_set and place_set) or (scope == "buffer" and (with_place_set or place_set)) then
    local place = ""
    if info.koma_with_place and info.koma_with_place ~= "" then
      place = str(info.koma_place)
    end
    out[#out + 1] = fmt("\\setkomavar{place}{%s}\n", place)
  end
  -- Location
  local location = heading_or_key_value("location", "koma_location")
  if location then
    out[#out + 1] = fmt("\\setkomavar{location}{%s}\n", location)
  end
  -- Folding marks
  if check_scope("with-foldmarks") then
    local marks = info.koma_with_foldmarks
    if type(marks) == "table" and #marks > 0 then
      local s = {}
      for _, m in ipairs(marks) do
        s[#s + 1] = tostring(m)
      end
      out[#out + 1] = fmt("\\KOMAoptions{foldmarks=true,foldmarks=%s}\n", table.concat(s))
    elseif marks and marks ~= "" and type(marks) ~= "table" then
      out[#out + 1] = "\\KOMAoptions{foldmarks=true}\n"
    else
      out[#out + 1] = "\\KOMAoptions{foldmarks=false}\n"
    end
  end
  return table.concat(out)
end

---------------------------------------------------------------------------
-- Template (org-koma-letter-template)
---------------------------------------------------------------------------

local COMPILERS = { pdflatex = true, xelatex = true, lualatex = true }

local function template(contents, info)
  local out = {}
  if info.time_stamp_file then
    out[#out + 1] = ox.format_time("%% Created %Y-%m-%d %a %H:%M\n")
  end
  if COMPILERS[info.latex_compiler or ""] then
    out[#out + 1] = fmt("%% Intended LaTeX compiler: %s\n", info.latex_compiler)
  end
  out[#out + 1] = latex.make_preamble(info)
  -- settings: global variables, then LCO files, then in-buffer settings
  out[#out + 1] = build_settings("global", info)
  for file in (info.koma_lco or ""):gmatch("%S+") do
    out[#out + 1] = fmt("\\LoadLetterOption{%s}\n", file)
  end
  out[#out + 1] = build_settings("buffer", info)
  local date = ox.get_date(info)
  out[#out + 1] = fmt("\\date{%s}\n", type(date) == "string" and date or ox.data(date, info))
  -- hyperref, document start, subject and title
  local with_subject = info.koma_with_subject
  if type(with_subject) == "table" and #with_subject == 0 then
    with_subject = false
  end
  local with_title = info.with_title
  local title_as_subject = with_subject and info.koma_with_title_as_subject
  local subject_s = nw(ox.data(present(info.koma_subject), info)) and ox.data(info.koma_subject, info) or nil
  local title_s = nil
  if with_title then
    local t = ox.data(present(info.title), info)
    title_s = nw(t) and t or nil
  end
  local subject, title
  if with_subject then
    if title_as_subject then
      subject = subject_s or title_s
    else
      subject = subject_s
    end
  end
  if with_title then
    if title_as_subject then
      title = subject_s and title_s or nil
    else
      title = title_s
    end
  end
  local spec = format_spec(info, title or subject or "")
  if with_subject and with_subject ~= true then
    local v = with_subject
    if type(v) == "table" then
      local parts = {}
      for _, x in ipairs(v) do
        parts[#parts + 1] = tostring(x)
      end
      v = table.concat(parts, ",")
    end
    out[#out + 1] = fmt("\\KOMAoption{subject}{%s}\n", tostring(v))
  end
  if type(info.latex_hyperref_template) == "string" then
    out[#out + 1] = format_spec_apply(info.latex_hyperref_template, spec)
  end
  out[#out + 1] = "\\begin{document}\n\n"
  if subject then
    out[#out + 1] = fmt("\\setkomavar{subject}{%s}\n", subject)
  end
  if title then
    out[#out + 1] = fmt("\\setkomavar{title}{%s}\n", title)
  end
  if nw(title) or nw(subject) then
    out[#out + 1] = "\n"
  end
  -- letter start
  local keyword_val = present(info.koma_to_address)
  local heading_val = get_tagged_contents("to", info)
  local to
  if info.koma_special_headings then
    to = heading_val or keyword_val
  else
    to = keyword_val or heading_val
  end
  out[#out + 1] = fmt("\\begin{letter}{%%\n%s}\n\n", str(add_latex_newlines(to or "\\mbox{}")))
  -- opening
  out[#out + 1] = fmt(
    "\\opening{%s}\n\n",
    keyword_or_headline("koma_opening", function(h, i)
      return not special_tag(h, i)
    end, info)
  )
  out[#out + 1] = contents
  -- closing
  out[#out + 1] = fmt(
    "\\closing{%s}\n",
    keyword_or_headline("koma_closing", function(h, i)
      return special_tag(h, i) == "closing"
    end, info)
  )
  out[#out + 1] = special_contents_inline(info.koma_special_tags_after_closing, info)
  out[#out + 1] = "\n\\end{letter}\n"
  out[#out + 1] = special_contents_inline(info.koma_special_tags_after_letter, info)
  out[#out + 1] = "\n\\end{document}"
  return table.concat(out)
end
M.template = template

---------------------------------------------------------------------------
-- Transcoders
---------------------------------------------------------------------------

local T = {}

T.template = template

T["export-block"] = function(el)
  if el.back_end_type == "KOMA-LETTER" or el.back_end_type == "LATEX" then
    return table.concat(element.remove_indentation(vim.split((el.value:gsub("\n$", "")), "\n", { plain = true })), "\n")
      .. "\n"
  end
end

T["export-snippet"] = function(el)
  local tr = (require("org.config").opts.export or {}).snippet_translation or {}
  local be = tr[el.back_end] or el.back_end
  if be == "latex" or be == "koma-letter" then
    return el.value
  end
end

T.keyword = function(el, contents, info)
  if el.key == "KOMA-LETTER" then
    return el.value
  end
  return ox.with_backend("latex", el, contents, info)
end

--- Special headlines are not exported: their contents are kept for the
--- template (org-koma-letter-special-contents).
T.headline = function(el, contents, info)
  local tag = special_tag(el, info)
  if not tag then
    return contents
  end
  info.koma_special_contents = info.koma_special_contents or {}
  table.insert(info.koma_special_contents, 1, { tag, contents })
  return ""
end

M.transcoders = T

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

--- org-latex-classes with the "default-koma-letter" class added.
local function classes()
  local c = (require("org.config").opts.export or {}).latex or {}
  local list = vim.deepcopy(c.classes or data.classes)
  for _, x in ipairs(list) do
    if x[1] == M.default_class[1] then
      return list
    end
  end
  list[#list + 1] = vim.deepcopy(M.default_class)
  return list
end

function M.options()
  return {
    { "latex_class", "LATEX_CLASS", nil, opt("default_class", "default-koma-letter"), "t" },
    { "latex_classes", nil, nil, classes },
    { "koma_lco", "LCO", nil, opt("class_option_file", "NF") },
    {
      "author",
      "AUTHOR",
      nil,
      function()
        local a = kcfg().author
        if a == nil then
          return ox.user_full_name()
        end
        return get_value(a) or nil
      end,
      "parse",
    },
    { "koma_from_address", "FROM_ADDRESS", nil, opt("from_address", ""), "newline" },
    { "koma_phone_number", "PHONE_NUMBER", nil, opt("phone_number", "") },
    { "koma_url", "URL", nil, opt("url", "") },
    { "koma_from_logo", "FROM_LOGO", nil, opt("from_logo", "") },
    {
      "email",
      "EMAIL",
      nil,
      function()
        local e = kcfg().email
        if e == nil then
          return ox.cfg().email or ""
        end
        return get_value(e) or nil
      end,
      "t",
    },
    { "koma_to_address", "TO_ADDRESS", nil, nil, "newline" },
    { "koma_place", "PLACE", nil, opt("place", "") },
    { "koma_location", "LOCATION", nil, opt("location", "") },
    { "koma_subject", "SUBJECT", nil, nil, "parse" },
    { "koma_opening", "OPENING", nil, opt("opening", ""), "parse" },
    { "koma_closing", "CLOSING", nil, opt("closing", ""), "parse" },
    { "koma_signature", "SIGNATURE", nil, opt("signature", ""), "newline" },
    { "koma_special_headings", nil, "special-headings", opt("prefer_special_headings", false) },
    { "koma_special_tags_as_macro", nil, nil, M.special_tags_as_macro },
    { "koma_special_tags_in_letter", nil, nil, M.special_tags_in_letter },
    { "koma_special_tags_after_closing", nil, "after-closing-order", M.special_tags_after_closing },
    { "koma_special_tags_after_letter", nil, "after-letter-order", M.special_tags_after_letter },
    { "koma_with_backaddress", nil, "backaddress", opt("use_backaddress", false) },
    { "with_email", nil, "email", opt("use_email", false) },
    { "koma_with_foldmarks", nil, "foldmarks", opt("use_foldmarks", true) },
    { "koma_with_phone", nil, "phone", opt("use_phone", false) },
    { "koma_with_url", nil, "url", opt("use_url", false) },
    { "koma_with_from_logo", nil, "from-logo", opt("use_from_logo", false) },
    { "koma_with_place", nil, "place", opt("use_place", true) },
    { "koma_with_subject", nil, "subject", opt("subject_format", true) },
    { "koma_with_title_as_subject", nil, "title-subject", opt("prefer_subject", false) },
    { "koma_with_headline_opening", nil, nil, opt("headline_is_opening_maybe", true) },
    -- non-sentinel values when a setting happened in the buffer
    { "koma_inbuffer_author", "AUTHOR", nil, EMPTY },
    { "koma_inbuffer_from", "FROM", nil, EMPTY },
    { "koma_inbuffer_email", "EMAIL", nil, EMPTY },
    { "koma_inbuffer_phone_number", "PHONE_NUMBER", nil, EMPTY },
    { "koma_inbuffer_url", "URL", nil, EMPTY },
    { "koma_inbuffer_from_logo", "FROM_LOGO", nil, EMPTY },
    { "koma_inbuffer_place", "PLACE", nil, EMPTY },
    { "koma_inbuffer_location", "LOCATION", nil, EMPTY },
    { "koma_inbuffer_signature", "SIGNATURE", nil, EMPTY },
    { "koma_inbuffer_with_backaddress", nil, "backaddress", EMPTY },
    { "koma_inbuffer_with_email", nil, "email", EMPTY },
    { "koma_inbuffer_with_foldmarks", nil, "foldmarks", EMPTY },
    { "koma_inbuffer_with_phone", nil, "phone", EMPTY },
    { "koma_inbuffer_with_url", nil, "url", EMPTY },
    { "koma_inbuffer_with_from_logo", nil, "from-logo", EMPTY },
    { "koma_inbuffer_with_place", nil, "place", EMPTY },
  }
end

M.backend = ox.define_backend("koma-letter", {
  parent = "latex",
  transcoders = T,
  options = M.options,
})

--- Compile the .tex file of a letter to PDF (org-latex-compile).
M.compile = latex.compile

return M

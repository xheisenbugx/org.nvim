---@mod org.lint.helpers org-lint: helpers shared by the checkers

local util = require("org.lint.util")
local data = require("org.lint.data")

local trim = util.trim
local nw = util.nw
local COMMON_HEADER_VALUES = data.COMMON_HEADER_VALUES
local LANG_HEADER_ARGS = data.LANG_HEADER_ARGS

---------------------------------------------------------------------------
-- Checker helpers
---------------------------------------------------------------------------

local function map_type(doc, t)
  local out = {}
  local set = type(t) == "table" and t or { [t] = true }
  for _, el in ipairs(doc.elements) do
    if set[el.type] then
      out[#out + 1] = el
    end
  end
  return out
end

local function map_objects(doc, t)
  local out = {}
  for _, o in ipairs(doc.objects) do
    if o.type == t then
      out[#out + 1] = o
    end
  end
  return out
end

local function aff_value(el, key)
  local v
  for _, a in ipairs(el.aff) do
    if a.key == key then
      v = a
    end
  end
  return v
end

local function aff_values(el, key)
  local out = {}
  for _, a in ipairs(el.aff) do
    if a.key == key then
      out[#out + 1] = a.value
    end
  end
  return out
end

--- Report at the start of an element.
local function at_begin(el, msg)
  return { el.begin, el.begin == el.post and el.col or 1, msg }
end

local function at_post(el, msg)
  return { el.post, el.post == el.begin and el.col or 1, msg }
end

local function at_obj(o, msg)
  return { o.lnum, o.col, msg }
end

--- `org-lint--collect-duplicates`
local function collect_duplicates(items, key_of, pos_of, msg_of)
  local keys, originals, reports = {}, {}, {}
  local seen_orig = {}
  for _, it in ipairs(items) do
    local key = key_of(it)
    if key ~= nil then
      local id = type(key) == "table" and table.concat(key, "\0") or key
      if keys[id] then
        if not seen_orig[id] then
          seen_orig[id] = true
          originals[#originals + 1] = { id = id, key = key }
        end
        table.insert(reports, 1, { pos = pos_of(it, key), key = key })
      else
        keys[id] = pos_of(it, key)
      end
    end
  end
  for _, o in ipairs(originals) do
    table.insert(reports, 1, { pos = keys[o.id], key = o.key })
  end
  local out = {}
  for _, r in ipairs(reports) do
    out[#out + 1] = { r.pos[1], r.pos[2], msg_of(r.key) }
  end
  return out
end

--- `org-babel-balanced-split` on "[ \t]:".
local function balanced_split(str)
  local result, partial = {}, {}
  local i, n = 1, #str
  local function flush()
    if #partial > 0 then
      result[#result + 1] = table.concat(partial)
      partial = {}
    end
  end
  while i <= n do
    local ch = str:sub(i, i)
    local prev = i > 1 and str:sub(i - 1, i - 1) or nil
    if (prev == " " or prev == "\t") and ch == ":" then
      table.remove(partial)
      flush()
      i = i + 1
    elseif ch == "(" or ch == "[" then
      local openings = { ch }
      local j = i + 1
      while #openings > 0 and j <= n do
        local cj = str:sub(j, j)
        if cj == "[" or cj == "(" then
          openings[#openings + 1] = cj
        elseif cj == "]" then
          if openings[#openings] == "[" then
            table.remove(openings)
          end
        elseif cj == ")" then
          if openings[#openings] == "(" then
            table.remove(openings)
          end
        end
        j = j + 1
      end
      if #openings == 0 then
        partial[#partial + 1] = str:sub(i, j - 1)
        i = j
      else
        partial[#partial + 1] = ch
        i = i + 1
      end
    elseif ch == '"' and prev ~= "\\" then
      local j = i + 1
      local close
      while j <= n do
        if str:sub(j, j) == '"' and str:sub(j - 1, j - 1) ~= "\\" then
          close = j
          break
        end
        j = j + 1
      end
      if close then
        partial[#partial + 1] = str:sub(i, close)
        i = close + 1
      else
        partial[#partial + 1] = ch
        i = i + 1
      end
    else
      partial[#partial + 1] = ch
      i = i + 1
    end
  end
  flush()
  return result
end

--- `org-babel-read` with Lisp evaluation inhibited.
local function babel_read(cell)
  if not nw(cell) then
    return cell
  end
  local t = trim(cell)
  if not t:match("%s") and cell:match("^[0-9e%.%+ %-]+$") then
    local n = tonumber(t)
    if n then
      return n
    end
  end
  local q = cell:match('^%s*"(.*)"%s*$')
  if q and not q:find('[^\\]"') and not q:match('^"') then
    return (q:gsub("\\(.)", "%1"))
  end
  return cell
end

--- `org-babel-parse-header-arguments` (no-eval): list of { name, value }
--- where `name` keeps its leading colon.
local function parse_header_args(str)
  if not nw(str) then
    return {}
  end
  local raw = balanced_split(str)
  local out = {}
  for idx, arg in ipairs(raw) do
    if idx > 1 then
      arg = ":" .. arg
    end
    local name, value = arg:match("^([^ \f\t\n\r\v]+)[ \f\t\n\r\v]+([^ \f\t\n\r\v]+.*)$")
    if name then
      out[#out + 1] = { name = name, value = babel_read((value:gsub("[ \f\t\n\r\v]+$", ""))) }
    else
      out[#out + 1] = { name = (arg:gsub("[ \f\t\n\r\v]+$", "")), value = nil }
    end
  end
  -- org-babel-parse-multiple-vars: split ":var a=1 b=2" in several :var
  local expanded = {}
  for _, h in ipairs(out) do
    if h.name == ":var" and type(h.value) == "string" then
      local ok, parts = pcall(function()
        local res = {}
        for _, v in ipairs(balanced_split(" :" .. h.value:gsub("([%s])([%w_%-]+=)", "%1:%2"))) do
          res[#res + 1] = trim(v)
        end
        return res
      end)
      if ok and #parts > 1 then
        for _, v in ipairs(parts) do
          expanded[#expanded + 1] = { name = ":var", value = v }
        end
      else
        expanded[#expanded + 1] = h
      end
    else
      expanded[#expanded + 1] = h
    end
  end
  return expanded
end

local function header_values_for(lang)
  local out = {}
  for _, e in ipairs(lang and LANG_HEADER_ARGS[lang] or {}) do
    out[#out + 1] = e
  end
  for _, e in ipairs(COMMON_HEADER_VALUES) do
    out[#out + 1] = e
  end
  return out
end

local function assoc_values(list, name)
  for _, e in ipairs(list) do
    if e[1] == name then
      return e[2]
    end
  end
  return nil
end

local function expand_home(path)
  if path:sub(1, 1) == "~" then
    local user, rest = path:match("^~([^/]*)(.*)$")
    if user == "" then
      return (vim.uv.os_homedir() or "~") .. rest
    end
  end
  return path
end

local function file_exists(doc, path)
  if path == nil or path == "" then
    return false
  end
  local p = expand_home(path)
  if not p:match("^/") and not p:match("^%a:[/\\]") then
    p = (doc.dir or vim.fn.getcwd()) .. "/" .. p
  end
  return vim.uv.fs_stat(p) ~= nil
end

local function is_remote(path)
  return path:match("^/[%w%-_%.]+:") ~= nil or path:match("^/%a+:[^/]*:") ~= nil
end

local function is_url(path)
  return path:match("^%a[%w+%.%-]*://") ~= nil
end

local function strip_quotes(s)
  local q = s:match('^"(.*)"$')
  return q or s
end

local function prev_sibling(el)
  local p = el.parent
  if not p then
    return nil
  end
  local prev
  for _, c in ipairs(p.children) do
    if c == el then
      return prev
    end
    prev = c
  end
end

local function ancestor(el, t)
  local p = el.parent
  while p do
    if p.type == t then
      return p
    end
    p = p.parent
  end
end

local function headline_of(el)
  return el.type == "headline" and el or ancestor(el, "headline")
end

local function headline_properties(doc, h)
  local props = {}
  if not h or not h.cbegin then
    return props
  end
  for _, sec in ipairs(h.children) do
    if sec.type == "section" then
      for _, c in ipairs(sec.children) do
        if c.type == "property-drawer" then
          for _, np in ipairs(c.children) do
            if np.key then
              props[np.key:upper()] = np.value
            end
          end
        end
      end
    end
  end
  return props
end

--- Resolve a fuzzy search like `org-export-resolve-fuzzy-link`.
local function search_cells_index(doc)
  if doc._cells then
    return doc._cells
  end
  local idx = {}
  local function add(kind, words)
    idx[kind .. "\0" .. table.concat(words, "\0")] = true
  end
  local function split(s)
    local w = {}
    for x in s:gmatch("%S+") do
      w[#w + 1] = x
    end
    return w
  end
  for _, el in ipairs(doc.elements) do
    if el.type == "headline" then
      local t = el.raw_value:gsub("%[%d*%%%]", " "):gsub("%[%d*/%d*%]", " ")
      local words = split(t:upper())
      add("headline", words)
      add("other", words)
    else
      local name = aff_value(el, "NAME")
      local res = aff_value(el, "RESULTS")
      local n = (name and name.value) or (res and res.value)
      if n and n ~= "" then
        add("other", split(n))
      end
    end
  end
  for _, o in ipairs(doc.objects) do
    if o.type == "target" then
      add("target", split(o.value:upper()))
    end
  end
  doc._cells = idx
  return idx
end

local function resolve_fuzzy(doc, path)
  local idx = search_cells_index(doc)
  local function split(s)
    local w = {}
    for x in s:gmatch("%S+") do
      w[#w + 1] = x
    end
    return w
  end
  if path:sub(1, 1) == "*" then
    return idx["headline\0" .. table.concat(split(path:sub(2):upper()), "\0")] or false
  end
  local w = split(path)
  local up = split(path:upper())
  return idx["target\0" .. table.concat(w, "\0")]
    or idx["other\0" .. table.concat(w, "\0")]
    or idx["target\0" .. table.concat(up, "\0")]
    or idx["other\0" .. table.concat(up, "\0")]
    or false
end

local function local_ids(doc)
  if doc._ids then
    return doc._ids
  end
  local ids = {}
  for _, h in ipairs(map_type(doc, "headline")) do
    local props = headline_properties(doc, h)
    if props.ID then
      ids[props.ID] = h
    end
    if props.CUSTOM_ID then
      ids[props.CUSTOM_ID] = h
    end
  end
  doc._ids = ids
  return ids
end

-- Languages whose Emacs editing mode has no same-named Vim filetype
-- (true: known without a filetype).
local LANG_MODES = {
  ["emacs-lisp"] = true,
  elisp = true,
  org = true,
  calc = true,
  authinfo = true,
  cfengine = true,
  cfengine3 = true,
  makefile = "make",
  screen = "sh",
  shell = "sh",
  sqlite = "sql",
  asymptote = "asy",
  C = "c",
  ["C++"] = "cpp",
  ["c++"] = "cpp",
  D = "d",
  R = "r",
}

--- Language known to Babel or with an editing mode (a Vim filetype),
--- like `org-babel-execute:LANG' or `org-src-get-lang-mode-if-bound'.
local known_cache = {}
local function known_language_uncached(lang)
  local mode = LANG_MODES[lang]
  if mode == true then
    return true
  end
  local ok, langs = pcall(require, "org.babel.langs")
  if ok and lang == lang:lower() and langs.family(lang) ~= "generic" then
    return true
  end
  local sok, syntax = pcall(require, "org.syntax")
  if sok and syntax.lang_aliases[lang] then
    return true
  end
  local ft = mode or lang
  return #vim.api.nvim_get_runtime_file("syntax/" .. ft .. ".vim", false) > 0
    or #vim.api.nvim_get_runtime_file("syntax/" .. ft .. ".lua", false) > 0
    or #vim.api.nvim_get_runtime_file("ftplugin/" .. ft .. ".vim", false) > 0
    or #vim.api.nvim_get_runtime_file("ftplugin/" .. ft .. ".lua", false) > 0
end

local function known_language(lang)
  local cfg = require("org.config").opts
  if (cfg.babel and cfg.babel.languages or {})[lang] then
    return true
  end
  if known_cache[lang] == nil then
    known_cache[lang] = known_language_uncached(lang) and true or false
  end
  return known_cache[lang]
end

local function src_headers(el)
  local out = {}
  for _, h in ipairs(parse_header_args(el.parameters)) do
    out[#out + 1] = h
  end
  for _, v in ipairs(aff_values(el, "HEADER")) do
    for _, h in ipairs(parse_header_args(v)) do
      out[#out + 1] = h
    end
  end
  return out
end

local function call_headers(o)
  local out = {}
  for _, h in ipairs(parse_header_args(o.inside_header)) do
    out[#out + 1] = h
  end
  for _, h in ipairs(parse_header_args(o.end_header)) do
    out[#out + 1] = h
  end
  return out
end

--- Babel-header carriers: { datum, lnum, col, language, headers }.
local function babel_data(doc, with_keywords)
  local out = {}
  for _, el in ipairs(doc.elements) do
    if el.type == "src-block" then
      out[#out + 1] = {
        el = el,
        lnum = el.post,
        col = 1,
        lang = el.language,
        headers = src_headers(el),
        kind = "src-block",
      }
    elseif el.type == "babel-call" then
      out[#out + 1] = { el = el, lnum = el.post, col = 1, headers = call_headers(el), kind = "babel-call" }
    elseif with_keywords and el.type == "keyword" and el.key == "PROPERTY" then
      local lang, rest = el.value:match("^header%-args:(%S+)%+ *(.*)$")
      if not lang then
        rest = el.value:match("^header%-args%+ *(.*)$")
      end
      if not rest then
        lang, rest = el.value:match("^header%-args:(%S+) *(.*)$")
      end
      if not rest then
        rest = el.value:match("^header%-args *(.*)$")
      end
      if rest then
        out[#out + 1] = {
          el = el,
          lnum = el.post,
          col = 1,
          lang = lang,
          headers = parse_header_args(rest),
          kind = "keyword",
        }
      end
    elseif with_keywords and el.type == "node-property" and el.key then
      local k = el.key:upper()
      local lang = k:match("^HEADER%-ARGS:(%S+)")
      if lang or k:match("^HEADER%-ARGS") then
        if lang then
          lang = el.key:match("^[^:]+:(%S+)")
        end
        out[#out + 1] = {
          el = el,
          lnum = el.post,
          col = 1,
          lang = lang,
          headers = parse_header_args(el.value),
          kind = "node-property",
        }
      end
    end
  end
  for _, o in ipairs(doc.objects) do
    if o.type == "inline-src-block" then
      out[#out + 1] = {
        el = o,
        lnum = o.lnum,
        col = o.col,
        lang = o.language,
        headers = parse_header_args(o.parameters),
        kind = "inline-src-block",
      }
    elseif o.type == "inline-babel-call" then
      out[#out + 1] = { el = o, lnum = o.lnum, col = o.col, headers = call_headers(o), kind = "inline-babel-call" }
    end
  end
  table.sort(out, function(x, y)
    if x.lnum ~= y.lnum then
      return x.lnum < y.lnum
    end
    return x.col < y.col
  end)
  return out
end

local function priority_bounds(doc)
  local p = doc.file and doc.file:priorities()
    or { highest = require("org.config").opts.priority_highest, lowest = require("org.config").opts.priority_lowest }
  local function val(x)
    x = tostring(x)
    return tonumber(x) or x:byte()
  end
  return val(p.highest), val(p.lowest)
end

local function footnote_section_name()
  local s = require("org.config").opts.footnote_section
  if s == nil then
    return "Footnotes"
  end
  return s or nil
end

local function coderef_resolves(doc, ref)
  for _, el in ipairs(map_type(doc, { ["src-block"] = true, ["example-block"] = true })) do
    local fmt = el.label_fmt or require("org.config").opts.coderef_label_format or "(ref:%s)"
    local label = fmt:gsub("%%s", function()
      return ref
    end)
    for l in (trim(el.value or "") .. "\n"):gmatch("([^\n]*)\n") do
      local s = l:find(label, 1, true)
      while s do
        if l:sub(s + #label):match("^[ \t]*$") then
          return true
        end
        s = l:find(label, s + 1, true)
      end
    end
  end
  return false
end

local function links(doc, t)
  local out = {}
  for _, o in ipairs(doc.objects) do
    if o.type == "link" and (not t or o.link_type == t) then
      out[#out + 1] = o
    end
  end
  return out
end

--- org-duration-p, with the units of `duration_units`.
local function duration_p(s)
  return require("org.duration").p(s)
end

return {
  map_type = map_type,
  map_objects = map_objects,
  aff_value = aff_value,
  aff_values = aff_values,
  at_begin = at_begin,
  at_post = at_post,
  at_obj = at_obj,
  collect_duplicates = collect_duplicates,
  parse_header_args = parse_header_args,
  header_values_for = header_values_for,
  assoc_values = assoc_values,
  expand_home = expand_home,
  file_exists = file_exists,
  is_remote = is_remote,
  is_url = is_url,
  strip_quotes = strip_quotes,
  prev_sibling = prev_sibling,
  ancestor = ancestor,
  headline_of = headline_of,
  headline_properties = headline_properties,
  resolve_fuzzy = resolve_fuzzy,
  local_ids = local_ids,
  known_language = known_language,
  babel_data = babel_data,
  priority_bounds = priority_bounds,
  footnote_section_name = footnote_section_name,
  coderef_resolves = coderef_resolves,
  links = links,
  duration_p = duration_p,
}

---@mod org.export.ox.links Links (resolving, images, coderefs), references and ordinals
---
--- Part of org.export.ox, which loads it: the functions are fields of
--- that module.

local element = require("org.export.element")
local utils = require("org.utils")
local M = require("org.export.ox")

local trim = M.trim

---------------------------------------------------------------------------
-- Links
---------------------------------------------------------------------------

--- Custom link export functions (config links.types[type].export).
function M.custom_protocol_maybe(link, desc, backend_name, info)
  local t = link.link_type
  if t == "coderef" or t == "custom-id" or t == "fuzzy" or t == "radio" then
    return nil
  end
  local spec = require("org.links").link_type(t)
  if type(spec) == "table" and type(spec.export) == "function" then
    local ok, r = pcall(spec.export, link.path, desc, backend_name, info)
    if ok then
      return r
    end
  end
  if t == "doi" then
    -- org-link-doi-export
    local uri = ((require("org.config").opts.links or {}).doi_server_url or "https://doi.org/") .. link.path
    if backend_name == "html" then
      return string.format('<a href="%s">%s</a>', uri, desc or uri)
    elseif backend_name == "latex" or backend_name == "beamer" then
      return desc and string.format("\\href{%s}{%s}", uri, desc) or string.format("\\url{%s}", uri)
    elseif backend_name == "ascii" then
      if not desc then
        return "<" .. uri .. ">"
      end
      return "[" .. desc .. "]" .. (info and info.ascii_links_to_notes and "" or (" (<" .. uri .. ">)"))
    end
    return uri
  end
  if t == "info" then
    return M.info_link_export(link.path, desc, backend_name)
  end
  return nil
end

--- org-info-emacs-documents
local INFO_EMACS_DOCUMENTS = {}
for d in
  (
    "ada-mode auth autotype bovine calc ccmode cl dbus dired-x ebrowse ede ediff edt efaq-w32 efaq eglot eieio "
    .. "eintr elisp emacs-gnutls emacs-mime emacs epa erc ert eshell eudc eww flymake forms gnus htmlfontify "
    .. "idlwave ido info mairix-el message mh-e modus-themes newsticker nxml-mode octave-mode org pcl-cvs pgg "
    .. "rcirc reftex remember sasl sc semantic ses sieve smtpmail speedbar srecode todo-mode tramp transient url "
    .. "use-package vhdl-mode vip viper vtable widget wisent woman"
  ):gmatch("%S+")
do
  INFO_EMACS_DOCUMENTS[d] = true
end

--- org-info-other-documents
local INFO_OTHER_DOCUMENTS = {
  dir = "https://www.gnu.org/manual/manual.html",
  libc = "https://www.gnu.org/software/libc/manual/html_mono/libc.html",
  make = "https://www.gnu.org/software/make/manual/make.html",
}

--- Export an info: link (ol-info org-info-export): HTML and Texinfo only.
function M.info_link_export(path, desc, backend_name)
  -- org-info--link-file-node: "manual#node" or "manual::node"
  local file, node = (path or ""):match("^([^#:]*)[#:]:?(.*)$")
  file = trim(file or path or "")
  node = trim(node or "")
  file = file ~= "" and file or "dir"
  node = node ~= "" and node or "Top"
  if backend_name == "texinfo" then
    return string.format("@ref{%s,%s,,%s,}", node, desc or "", file)
  elseif backend_name == "html" then
    local other = (require("org.config").opts.links or {}).info_other_documents or INFO_OTHER_DOCUMENTS
    local url = other[file]
      or (INFO_EMACS_DOCUMENTS[file] and ("https://www.gnu.org/software/emacs/manual/html_mono/" .. file .. ".html"))
      or (file .. ".html")
    -- org-info--expand-node-name (HTML Xref Node Name Expansion)
    local parts = {}
    for _, c in ipairs(vim.fn.split(node:gsub("[ \t\n\r]+", " "), "\\zs")) do
      if c == " " then
        parts[#parts + 1] = "-"
      elseif c:match("^[%w]$") then
        parts[#parts + 1] = c
      else
        parts[#parts + 1] = string.format("_%04x", vim.fn.char2nr(c))
      end
    end
    local n = table.concat(parts)
    if n:match("^%d") then
      n = "g_t" .. n
    end
    return string.format('<a href="%s#%s">%s</a>', url, n, desc or path)
  end
  return nil
end

function M.get_coderef_format(path, desc)
  if not desc then
    return "%s"
  end
  local s, e = desc:find("(" .. path .. ")", 1, true)
  if s then
    return (desc:sub(1, s - 1):gsub("%%", "%%%%")) .. "%s" .. (desc:sub(e + 1):gsub("%%", "%%%%"))
  end
  return (desc:gsub("%%", "%%%%"))
end

M.DEFAULT_IMAGE_EXT = {
  "png",
  "jpeg",
  "jpg",
  "gif",
  "tiff",
  "tif",
  "xbm",
  "xpm",
  "pbm",
  "pgm",
  "ppm",
  "webp",
  "avif",
  "svg",
}

--- rules: { [type] = { ext... } }
function M.inline_image_p(link, rules)
  if #link.contents > 0 then
    return false
  end
  rules = rules or { file = M.DEFAULT_IMAGE_EXT }
  local exts = rules[link.link_type]
  if not exts then
    return false
  end
  local ext = (link.path or ""):match("%.([%w]+)$")
  if not ext then
    return false
  end
  ext = ext:lower()
  for _, e in ipairs(exts) do
    if e == ext then
      return true
    end
  end
  return false
end

--- Links whose description is a plain image link become nested image
--- links (org-export-insert-image-links).
function M.insert_image_links(data, info, rules)
  rules = rules or { file = M.DEFAULT_IMAGE_EXT }
  local parser = info.parser
  element.map(data, "link", function(l)
    if #l.contents == 1 and l.contents[1].type == "plain-text" then
      local text = trim(l.contents[1].value)
      local t, path = text:match("^<?([%w%+%-]+):([^%s>]+)>?$")
      if t and rules[t] then
        local ext = path:match("%.([%w]+)$")
        if ext and vim.tbl_contains(rules[t], ext:lower()) then
          local node = parser:parse_objects(text, { link = true })[1]
          if node and node.type == "link" then
            node.parent = l
            node.post_blank = 0
            l.contents = { node }
          end
        end
      end
    end
  end, { ignore = info.ignore, with_affiliated = true })
  return data
end

--- Resolve a coderef: its line number or the label itself.
function M.resolve_coderef(ref, info)
  local r = element.map(info.parse_tree, { ["example-block"] = true, ["src-block"] = true }, function(el)
    local value = trim(el.value or "")
    local fmt = el.label_fmt or require("org.config").opts.coderef_label_format or "(ref:%s)"
    local pat = vim.pesc(fmt):gsub("%%%%s", utils.gsub_escape(vim.pesc(ref)))
    local lines = vim.split(value, "\n", { plain = true })
    for i = #lines, 1, -1 do
      if lines[i]:find(pat .. "[ \t]*$") then
        if el.use_labels then
          return ref
        end
        return (M.get_loc(el, info) or 0) + i
      end
    end
  end, { ignore = info.ignore, first_match = true })
  if r == nil then
    M.broken_link(ref)
  end
  return r
end

local function split_words(s)
  return vim.split(s, "%s+", { trimempty = true })
end

local function upcase_list(l)
  local out = {}
  for i, v in ipairs(l) do
    out[i] = v:upper()
  end
  return out
end

--- Search cells of a datum (org-export-search-cells), as strings.
function M.search_cells(datum)
  local t = datum.type
  if t == nil then
    return {}
  end
  if t == "headline" then
    local raw = (datum.raw_value or ""):gsub("%[%d*%%%]", " "):gsub("%[%d*/%d*%]", " ")
    local title = table.concat(upcase_list(split_words(raw)), " ")
    local out = { "headline\0" .. title, "other\0" .. title }
    if datum.props and datum.props.CUSTOM_ID then
      out[#out + 1] = "custom-id\0" .. datum.props.CUSTOM_ID
    end
    return out
  elseif t == "target" then
    return { "target\0" .. table.concat(upcase_list(split_words(datum.value)), " ") }
  else
    local name = datum.name or (datum.results and datum.results[1])
    if name and type(name) == "string" then
      return { "other\0" .. table.concat(split_words(name), " ") }
    end
  end
  return {}
end

function M.string_to_search_cell(s)
  local c = s:sub(1, 1)
  if c == "*" then
    return { "headline\0" .. table.concat(upcase_list(split_words(s:sub(2))), " ") }
  elseif c == "#" then
    return { "custom-id\0" .. s:sub(2) }
  end
  local words = split_words(s)
  local w = table.concat(words, " ")
  local W = table.concat(upcase_list(words), " ")
  local out = {}
  local seen = {}
  for _, cell in ipairs({ "target\0" .. w, "other\0" .. w, "target\0" .. W, "other\0" .. W }) do
    if not seen[cell] then
      seen[cell] = true
      out[#out + 1] = cell
    end
  end
  return out
end

function M.resolve_fuzzy_link(link, info, pseudo)
  local path = type(link) == "string" and link or link.path
  local cells = M.string_to_search_cell(path)
  local cache = info.resolve_fuzzy_cache
  if not cache then
    cache = {}
    local types = { target = true }
    for k in pairs(element.ELEMENTS) do
      types[k] = true
    end
    for _, p in ipairs(pseudo or {}) do
      types[p] = true
    end
    element.map(info.parse_tree, types, function(d)
      for _, cell in ipairs(M.search_cells(d)) do
        cache[cell] = cache[cell] or {}
        table.insert(cache[cell], d)
      end
    end, { ignore = info.ignore })
    info.resolve_fuzzy_cache = cache
  end
  local matches = {}
  for _, cell in ipairs(cells) do
    for _, d in ipairs(cache[cell] or {}) do
      matches[#matches + 1] = d
    end
  end
  if #matches == 0 then
    M.broken_link(path)
  end
  for _, d in ipairs(matches) do
    if d.type ~= "headline" then
      return d
    end
  end
  return matches[1]
end

function M.resolve_id_link(link, info)
  local id = link.path
  local cache = info.id_local_cache
  if not cache then
    cache = {}
    element.map(info.parse_tree, "headline", function(h)
      local props = h.props or {}
      if props.ID and not cache[props.ID] then
        cache[props.ID] = h
      end
      if props.CUSTOM_ID and not cache[props.CUSTOM_ID] then
        cache[props.CUSTOM_ID] = h
      end
    end, { ignore = info.ignore })
    info.id_local_cache = cache
  end
  if cache[id] then
    return cache[id]
  end
  -- external file with that ID
  if link.link_type == "id" then
    local ok, loc = pcall(function()
      return require("org.id").find(id)
    end)
    if ok and loc then
      local file = type(loc) == "table" and (loc.file or loc[1]) or loc
      if type(file) == "string" then
        local base = info.input_file and vim.fn.fnamemodify(info.input_file, ":p:h") or vim.fn.getcwd()
        return { type = "plain-text", value = M.relative_path(file, base), external = true }
      end
    end
  end
  M.broken_link(id)
end

function M.resolve_radio_link(link, info)
  local function clean(s)
    return trim((s:gsub("%s+", " "))):lower()
  end
  local path = clean(link.path)
  return element.map(info.parse_tree, "radio-target", function(r)
    if clean(r.value) == path then
      return r
    end
  end, { ignore = info.ignore, first_match = true })
end

function M.resolve_link(link, info)
  if type(link) == "string" then
    local node = info.parser:parse_objects("[[" .. link .. "]]", { link = true })[1]
    link = node
  end
  local t = link.link_type
  if t == "custom-id" or t == "id" then
    return M.resolve_id_link(link, info)
  elseif t == "fuzzy" then
    return M.resolve_fuzzy_link(link, info)
  end
  M.broken_link(link.path)
end

function M.file_uri(filename)
  if filename:match("^//") then
    return "file:" .. filename
  end
  if not (utils.is_absolute(filename) or filename:match("^~")) then
    return filename
  end
  -- forward slashes, as expand-file-name gives on Windows
  local full = vim.fs.normalize(vim.fn.fnamemodify(utils.expand_vars(filename), ":p"))
  return (full:match("^/") and "file://" or "file:///") .. full
end

---------------------------------------------------------------------------
-- References and ordinals
---------------------------------------------------------------------------

--- Unique reference for a datum. Emacs generates random "orgXXXXXXX"
--- references; here they are derived from the datum's position so that
--- exports are reproducible.
function M.get_reference(datum, info)
  local refs = info.internal_references
  if refs.by_datum[datum] then
    return refs.by_datum[datum]
  end
  -- references already used by other published files (:crossrefs)
  if info.crossrefs then
    for _, c in ipairs(M.search_cells(datum)) do
      local r = info.crossrefs[c]
      if r and not refs.used[r] then
        refs.used[r] = true
        refs.by_datum[datum] = r
        return r
      end
    end
  end
  refs.n = refs.n + 1
  local key = (datum.type or "secondary") .. ":" .. refs.n .. ":" .. table.concat(M.search_cells(datum), "|")
  local h = utils.sha256(key)
  local ref = "org" .. h:sub(1, 7)
  local k = 8
  while refs.used[ref] do
    ref = "org" .. h:sub(k, k + 6)
    k = k + 1
  end
  refs.used[ref] = true
  refs.by_datum[datum] = ref
  return ref
end

function M.get_ordinal(el, info, types, predicate)
  if el.type == "target" then
    el = element.lineage(el, {
      ["footnote-definition"] = true,
      ["footnote-reference"] = true,
      headline = true,
      item = true,
      table = true,
    })
    if not el then
      return nil
    end
  end
  local t = el.type
  if t == "headline" then
    return M.get_headline_number(el, info)
  elseif t == "item" then
    -- item number within its list(s)
    local nums = {}
    local it = el
    while it and it.type == "item" do
      local list = it.parent
      local n = 0
      for _, x in ipairs(list.contents) do
        n = x.counter or (n + 1)
        if x == it then
          break
        end
      end
      table.insert(nums, 1, n)
      it = element.lineage(list, "item")
    end
    return nums
  elseif t == "footnote-definition" or t == "footnote-reference" then
    return M.get_footnote_number(el, info)
  end
  local want = { [t] = true }
  local key = { t }
  for _, x in ipairs(types or {}) do
    want[x] = true
    key[#key + 1] = x
  end
  -- one walk numbers every element of these types for this predicate:
  -- mapping the tree for each table or figure is quadratic
  local tree = info.parse_tree
  local cache = info.ordinal_cache
  if not cache or cache.tree ~= tree or cache.ignore ~= info.ignore then
    cache = { tree = tree, ignore = info.ignore, by_pred = setmetatable({}, { __mode = "k" }) }
    info.ordinal_cache = cache
  end
  local pkey = predicate or cache
  key = table.concat(key, "\0")
  local by_key = cache.by_pred[pkey]
  if not by_key then
    -- a predicate seen once may be a closure made for this call: walk
    -- up to the element only, and number everything when it comes back
    cache.by_pred[pkey] = {}
    local counter = 0
    return element.map(tree, want, function(x)
      if x == el then
        if not predicate or predicate(x, info) then
          return counter + 1
        end
        return nil
      end
      if not predicate or predicate(x, info) then
        counter = counter + 1
      end
    end, { ignore = info.ignore, first_match = true })
  end
  local ordinals = by_key[key]
  if not ordinals then
    ordinals = {}
    local counter = 0
    element.map(tree, want, function(x)
      if not predicate or predicate(x, info) then
        counter = counter + 1
        ordinals[x] = counter
      end
    end, { ignore = info.ignore })
    cache.by_pred[pkey][key] = ordinals
  end
  return ordinals[el]
end

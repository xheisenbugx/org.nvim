---@mod org.extensions.hugo.export Exporting Hugo posts (ox-hugo's commands)
---
--- A post is either a whole file (the per-file flow: `#+title`,
--- `#+hugo_base_dir`, `#+hugo_section`, ...) or a subtree with an
--- `EXPORT_FILE_NAME` property (the per-subtree flow), which inherits the
--- `EXPORT_HUGO_*` properties of its parents. `export_wim` exports the post
--- at the cursor, all posts of the file, or the file; the result goes to
--- `<base_dir>/content/<section>/[<bundle>/]<name>.md`.

local ox = require("org.export.ox")
local fm = require("org.extensions.hugo.front_matter")

local M = {}

local fmt = string.format
local nw = ox.nw

local function utils()
  return require("org.utils")
end

local function backend()
  return require("org.extensions.hugo.backend")
end

local function opts()
  return require("org.extensions").opts("hugo") or require("org.extensions.hugo").defaults
end

--- Properties a post inherits from its parents
--- (org-hugo--selective-property-inheritance), without the EXPORT_ prefix.
local INHERITED = {}
for _, k in ipairs({
  "HUGO_FRONT_MATTER_FORMAT",
  "HUGO_PREFER_HYPHEN_IN_TAGS",
  "HUGO_PRESERVE_FILLING",
  "HUGO_DELETE_TRAILING_WS",
  "HUGO_ALLOW_SPACES_IN_TAGS",
  "HUGO_SECTION",
  "HUGO_SECTION_FRAG",
  "HUGO_BUNDLE",
  "HUGO_BASE_DIR",
  "HUGO_BASE_CONTENT_FOLDER",
  "HUGO_CODE_FENCE",
  "HTML_CONTAINER",
  "HTML_CONTAINER_CLASS",
  "HUGO_MENU",
  "HUGO_CUSTOM_FRONT_MATTER",
  "HUGO_DRAFT",
  "HUGO_ISCJKLANGUAGE",
  "KEYWORDS",
  "HUGO_MARKUP",
  "HUGO_OUTPUTS",
  "HUGO_TAGS",
  "HUGO_CATEGORIES",
  "HUGO_SERIES",
  "HUGO_TYPE",
  "HUGO_LAYOUT",
  "HUGO_WEIGHT",
  "HUGO_RESOURCES",
  "HUGO_FRONT_MATTER_KEY_REPLACE",
  "HUGO_DATE_FORMAT",
  "HUGO_WITH_LOCALE",
  "HUGO_LOCALE",
  "HUGO_PAIRED_SHORTCODES",
  "DATE",
  "HUGO_PUBLISHDATE",
  "HUGO_EXPIRYDATE",
  "HUGO_LASTMOD",
  "HUGO_SLUG",
  "HUGO_AUTO_SET_LASTMOD",
  "LANGUAGE",
  "AUTHOR",
  "OPTIONS",
}) do
  INHERITED[k] = true
end
M.INHERITED = INHERITED

---------------------------------------------------------------------------
-- Posts in a file
---------------------------------------------------------------------------

--- Headlines with their own non-empty EXPORT_FILE_NAME: the posts of the
--- per-subtree flow.
---@param file org.File
---@return org.Headline[]
function M.posts(file)
  local out = {}
  for _, h in ipairs(file.headlines) do
    if nw(h.properties.EXPORT_FILE_NAME) then
      out[#out + 1] = h
    end
  end
  return out
end

--- The post a headline belongs to: itself or its nearest ancestor with an
--- EXPORT_FILE_NAME (org-hugo--get-valid-subtree).
---@param h org.Headline|nil
---@return org.Headline|nil
function M.post_of(h)
  while h do
    if nw(h.properties.EXPORT_FILE_NAME) then
      return h
    end
    h = h.parent
  end
  return nil
end

--- `PROP` of `h` joined with the values of its parents, `sep` between
--- them (org-hugo--entry-get-concat).
---@param h org.Headline|nil
---@param key string
---@param sep string
---@return string|nil
local function entry_concat(h, key, sep)
  if not h or h:get_property(key, true) == nil then
    return nil
  end
  local here = h.properties[key]
  local parent = entry_concat(h.parent, key, sep)
  if here then
    local s = ""
    if parent then
      s = (sep ~= "" and parent:sub(-#sep) == sep) and "" or sep
    end
    return (parent or "") .. s .. here
  end
  return parent
end

--- The bundle of a post: EXPORT_HUGO_BUNDLE of it and its parents.
local function bundle_of(h)
  return entry_concat(h, "EXPORT_HUGO_BUNDLE", "/")
end

--- Slug of a post headline (org-hugo--heading-get-slug, without the
--- section): `bundle` for an `index` / `_index` page, `bundle/file` for
--- another page of a bundle, else the file name.
---@param h org.Headline
---@return string|nil
function M.post_slug(h)
  local file = nw(h.properties.EXPORT_FILE_NAME)
  if not file then
    return nil
  end
  local bundle = nw(h:get_property("EXPORT_HUGO_BUNDLE", true))
  if bundle and (file == "index" or file == "_index") then
    return bundle
  elseif bundle then
    return bundle:gsub("/+$", "") .. "/" .. file
  end
  return file
end

--- Anchor of a headline in the index of a file (see the back-end's
--- `anchor`): a post's page or bundle name, CUSTOM_ID, slug or MD5.
local function heading_anchor(h)
  local slug = M.post_slug(h)
  if slug then
    return vim.fn.fnamemodify(slug, ":t"), true
  end
  if nw(h.properties.CUSTOM_ID) then
    return h.properties.CUSTOM_ID, false
  end
  local title = h:plain_title()
  local s = nw(title) and nw(fm.slug(title, true))
  return s or vim.fn.sha256(title):sub(1, 6), false
end

--- Index of the link destinations of a file: headline titles, CUSTOM_IDs,
--- IDs, `<<targets>>` and `#+name`s, each with the post it is in (`post`,
--- the post's page or bundle name for `relref`) and its anchor.
---@param lines string[]
---@param filename? string
---@return table
function M.link_index(lines, filename, _)
  local file = require("org.parser").parse(lines, filename)
  local index = { title = {}, custom_id = {}, id = {}, target = {}, name = {} }
  local function post_ref(h)
    local p = M.post_of(h)
    local slug = p and M.post_slug(p)
    return slug and vim.fn.fnamemodify(slug, ":t") or nil
  end
  for _, h in ipairs(file.headlines) do
    local anchor, is_post = heading_anchor(h)
    local entry = {
      post = post_ref(h),
      anchor = anchor,
      is_post = is_post,
      headline = true,
      title = h:plain_title(),
    }
    local t = entry.title
    if index.title[t] == nil then
      index.title[t] = entry
    end
    if nw(h.properties.CUSTOM_ID) then
      index.custom_id[h.properties.CUSTOM_ID] = entry
    end
    if nw(h.properties.ID) then
      index.id[h.properties.ID] = entry
    end
  end
  for i, l in ipairs(lines) do
    local h = file:headline_at(i)
    local post = h and post_ref(h) or nil
    for name in l:gmatch("<<([^<>\n]-)>>") do
      if not name:match("^<") and index.target[name] == nil then
        index.target[name] = { post = post, anchor = backend().target_anchor(name) }
      end
    end
    local name = l:match("^[ \t]*#%+[Nn][Aa][Mm][Ee]:[ \t]*(.-)[ \t]*$")
    if name and name ~= "" and index.name[name] == nil then
      index.name[name] = { post = post }
    end
  end
  index.file = file
  return index
end

--- Where an ID of another file is, for `{{< relref >}}`: { ref, anchor,
--- is_post }, `ref` being the post's name or the file's path as `.md`.
---@param id string
---@param info table
---@return table|nil
function M.find_id(id, info)
  local ok, loc = pcall(function()
    return require("org.id").find(id)
  end)
  if not ok or not loc or not loc.filename then
    return nil
  end
  local lines = loc.bufnr and vim.api.nvim_buf_get_lines(loc.bufnr, 0, -1, false) or utils().readfile(loc.filename)
  if not lines then
    return nil
  end
  local entry = M.link_index(lines, loc.filename).id[id]
  local base = info and info.input_file and vim.fn.fnamemodify(info.input_file, ":p:h") or vim.fn.getcwd()
  local rel = ox.relative_path(loc.filename, base):gsub("%.[Oo][Rr][Gg]$", ".md")
  if not entry then
    return { ref = rel }
  end
  return { ref = entry.post or rel, anchor = entry.anchor, is_post = entry.is_post }
end

--- Level and index of a post among the posts at its level under the same
--- parent (org-hugo--get-post-subtree-coordinates), for `auto` weights.
local function coordinates(h, file)
  local index = 1
  local from, to = 1, math.huge
  if h.parent then
    from, to = h.parent.line, h.parent.end_line
  end
  for _, o in ipairs(file.headlines) do
    if
      o ~= h
      and o.level == h.level
      and o.line < h.line
      and o.line > from
      and o.line <= to
      and nw(o.properties.EXPORT_FILE_NAME)
    then
      index = index + 1
    end
  end
  return { h.level, index }
end

--- The tags of a post (ALLTAGS): inherited ones first, then its own; a
--- tag given twice is kept where it is last.
local function all_tags(h)
  local list = vim.list_extend(h:get_inherited_tags(), h.tags)
  local last = {}
  for i, t in ipairs(list) do
    last[t] = i
  end
  local out = {}
  for i, t in ipairs(list) do
    if last[t] == i then
      out[#out + 1] = t
    end
  end
  return out
end

--- Context of a subtree post for the back-end: its properties with
--- inheritance, planning, TODO state, tags, section and bundle.
---@param h org.Headline
---@param file org.File
---@return table
function M.subtree_context(h, file)
  local props = {}
  local options = vim.list_extend(vim.deepcopy(ox.all_options(backend().backend)), ox.global_options())
  for _, o in ipairs(options) do
    local k = o[2]
    if k and k ~= "TITLE" then
      local key = "EXPORT_" .. k
      local v
      if INHERITED[k] then
        v = h:get_property(key, true)
      else
        v = h.properties[key]
      end
      if v ~= nil then
        props[key] = v
      end
    end
  end
  local own_opts = h.properties.EXPORT_OPTIONS
  local inh_opts = h:get_property("EXPORT_OPTIONS", true)
  props.EXPORT_OPTIONS = inh_opts ~= own_opts and inh_opts or nil
  local section = h:get_property("EXPORT_HUGO_SECTION", true)
  local frag = h:get_property("EXPORT_HUGO_SECTION_FRAG", true)
  local ctx = {
    props = props,
    headline_line = h.line,
    todo = h.todo,
    done = h:is_done(),
    closed = h.planning.closed and h.planning.closed:to_string() or nil,
    scheduled = h.planning.scheduled and h.planning.scheduled:to_string() or nil,
    tags = all_tags(h),
    coord = coordinates(h, file),
    bundle = nw(bundle_of(h)),
    section_prop = section,
    file_name = h.properties.EXPORT_FILE_NAME,
  }
  if section or nw(frag) then
    ctx.section_frag = nw(frag) and entry_concat(h, "EXPORT_HUGO_SECTION_FRAG", "/") or nil
  end
  return ctx
end

---------------------------------------------------------------------------
-- Front matter
---------------------------------------------------------------------------

--- Hugo date from an Org date or an RFC 3339 string
--- (org-hugo--format-date): RFC 3339 strings are kept, Org dates are
--- formatted with `date_format` (a colon is put into the zone offset).
---@param raw string|nil
---@param info table
---@return string|nil, integer|nil time
function M.hugo_date(raw, info)
  if type(raw) == "table" then
    raw = ox.data_with_backend(raw, "org", info)
  end
  if type(raw) ~= "string" then
    return nil
  end
  raw = vim.trim(raw)
  if raw == "" then
    return nil
  end
  local y, m, d, rest = raw:match("(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
  if not y then
    return nil
  end
  local hh, mm = rest:match("^[^%d]-(%d%d?):(%d%d)")
  local time = os.time({
    year = tonumber(y),
    month = tonumber(m),
    day = tonumber(d),
    hour = tonumber(hh) or 0,
    min = tonumber(mm) or 0,
    sec = 0,
  })
  if fm.is_date(raw) then
    return raw, time
  end
  local s = require("org.date").format_time_string(info.hugo_date_format or opts().date_format, time)
  s = s:gsub("([+-]%d%d)(%d%d)$", "%1:%2")
  return s, time
end

--- The title without markup (org-hugo--get-sanitized-title): emphasis
--- markers dropped, `---`, `--` and `...` as typographic characters.
local function sanitized_title(info)
  if not (info.with_title and info.title) then
    return nil
  end
  local function raw(el, contents)
    return contents or el.value
  end
  local plain = ox.create_backend("md", {
    bold = raw,
    italic = raw,
    underline = raw,
    ["strike-through"] = raw,
    code = raw,
    verbatim = raw,
    ["plain-text"] = function(t)
      return t
    end,
    link = function(el, contents)
      return contents or el.raw_link
    end,
    entity = function(el)
      return (require("org.export.entities")[el.name] or {})[6] or ("\\" .. el.name)
    end,
    timestamp = function(el)
      return ox.interpret_timestamp(el)
    end,
  })
  local title = ox.data_with_backend(info.title, plain, info)
  title = title:gsub("%-%-%-([^-])", "—%1"):gsub("%-%-%-$", "—")
  title = title:gsub("%-%-([^-])", "–%1"):gsub("%-%-$", "–")
  title = title:gsub("%.%.%.", "…")
  return title
end

--- Language of the post (org-hugo--get-lang).
local function lang(info)
  local l = nw(info.hugo_locale) or vim.env.LANGUAGE or vim.env.LC_ALL or vim.env.LANG
  if type(l) == "string" then
    l = l:match("^([a-z]+_[A-Z]+)") or l
  end
  return nw(l)
end

local function weights(info, ctx)
  local out = {}
  local function calc()
    return ctx.coord and (1000 * ctx.coord[1] + ctx.coord[2]) or nil
  end
  for _, kv in ipairs(fm.parse_arguments(info.hugo_weight)) do
    local key, value = kv[1], kv[2]
    local k, v
    if value == nil then
      k = "weight"
      if key == "auto" then
        v = calc()
      else
        v = tonumber(key)
      end
    else
      k = key == "page" and "weight" or (key .. "_weight")
      if value == "auto" then
        v = calc()
      elseif type(value) == "number" then
        v = value
      else
        error(fmt("Invalid weight %s", vim.inspect(value)), 0)
      end
    end
    table.insert(out, 1, { k, v })
  end
  return out
end

local MENU_PROPS = { "title", "parent", "weight", "post", "pre", "identifier", "url", "name" }

local function menu(info, ctx, title)
  local args = fm.parse_arguments(info.hugo_menu)
  local name = fm.arg(args, "menu")
  if name == nil then
    return nil
  end
  local over = fm.parse_arguments(info.hugo_menu_override)
  local params = {}
  local has = {}
  for _, p in ipairs(MENU_PROPS) do
    local v, found = fm.arg(over, p)
    if not found then
      v, found = fm.arg(args, p)
    end
    if found then
      params[#params + 1] = { p, v }
      has[p] = true
    end
  end
  if not has.identifier then
    table.insert(params, 1, { "identifier", fm.slug(title or "") })
  end
  if not has.weight and ctx.coord then
    table.insert(params, 1, { "weight", 1000 * ctx.coord[1] + ctx.coord[2] })
  end
  local outer = fm.map({ { tostring(name), fm.map(params) } })
  outer.quote_keys = true
  return outer
end

local function resources(info)
  local list = { kind = "array", maps = true }
  local by_src = {}
  local cur
  for _, kv in ipairs(fm.parse_arguments(info.hugo_resources)) do
    local key, value = kv[1], kv[2]
    if key == "src" then
      cur = by_src[tostring(value)]
      if not cur then
        cur = fm.map({ { "src", value } })
        by_src[tostring(value)] = cur
        list[#list + 1] = cur
      end
    elseif cur then
      if key == "title" or key == "name" then
        cur.entries[#cur.entries + 1] = { key, value }
      else
        local params
        for _, e in ipairs(cur.entries) do
          if e[1] == "params" then
            params = e[2]
          end
        end
        if not params then
          params = fm.map()
          cur.entries[#cur.entries + 1] = { "params", params }
        end
        params.entries[#params.entries + 1] = { key, fm.from_lisp(value) }
      end
    end
  end
  for _, r in ipairs(list) do
    if not fm.arg(r.entries, "src") then
      error("`src' must be set for the `resources'", 0)
    end
  end
  return list
end

local function custom(info)
  local out = {}
  for _, kv in ipairs(fm.parse_arguments(info.hugo_custom_front_matter)) do
    out[#out + 1] = { kv[1], fm.from_lisp(kv[2]) }
  end
  return out
end

local function array(list)
  if not list or #list == 0 then
    return nil
  end
  local a = fm.array()
  for i, v in ipairs(list) do
    a[i] = v
  end
  return a
end

local function split_words(s)
  if not nw(s) then
    return nil
  end
  return vim.split(vim.trim(s), "%s+")
end

local function unquote(s)
  s = nw(s)
  if s and #s > 1 and s:sub(1, 1) == '"' and s:sub(-1) == '"' then
    return s:sub(2, -2)
  end
  return s
end

--- The lastmod date (org-hugo--format-date :hugo-lastmod): HUGO_LASTMOD,
--- or now with `auto_set_lastmod` unless the post's date is less than
--- `suppress_lastmod_period` seconds old.
local function lastmod(info, date_time)
  local set = M.hugo_date(info.hugo_lastmod, info)
  if set then
    return set
  end
  if not backend().truthy(info.hugo_auto_set_lastmod) then
    return nil
  end
  local now = os.time()
  local s = require("org.date").format_time_string(info.hugo_date_format or opts().date_format, now)
  s = s:gsub("([+-]%d%d)(%d%d)$", "%1:%2")
  local period = tonumber(opts().suppress_lastmod_period) or 0
  if period == 0 then
    return s
  end
  if not date_time then
    return nil
  end
  if os.difftime(now, date_time) >= math.abs(period) then
    return s
  end
  return nil
end

--- The front matter of a post (org-hugo--get-front-matter).
---@param info table
---@return string
function M.front_matter(info)
  local ctx = info.hugo_ctx or {}
  local be = backend()
  local format = (info.hugo_front_matter_format == "yaml") and "yaml" or "toml"
  local authors
  if info.with_author and info.author then
    local raw = type(info.author) == "table" and ox.data(info.author, info) or info.author
    if nw(raw) then
      authors = {}
      local seen = {}
      for a in raw:gmatch("[^,\n]+") do
        a = vim.trim(a)
        if a ~= "" and not seen[a] then
          seen[a] = true
          authors[#authors + 1] = a
        end
      end
    end
  end
  local section = nw(type(info.hugo_section) == "string" and info.hugo_section or nil) or ""
  local aliases
  for _, a in ipairs(split_words(info.hugo_aliases) or {}) do
    aliases = aliases or {}
    if not a:find("/", 1, true) then
      a = "/" .. section:gsub("/*$", "/") .. a
    end
    aliases[#aliases + 1] = a
  end
  -- draft: the TODO state of a subtree post, else HUGO_DRAFT
  local draft
  if ctx.todo then
    draft = ctx.done and "false" or "true"
  elseif info.hugo_draft ~= nil then
    draft = be.booleanize(info.hugo_draft)
  else
    draft = "false"
  end
  local all_tags = ctx.tags or (not info.export_options.subtree and info.filetags) or {}
  local plain_tags, cat_tags = {}, {}
  for _, t in ipairs(all_tags) do
    if t:sub(1, 1) == "@" then
      cat_tags[#cat_tags + 1] = t
    else
      plain_tags[#plain_tags + 1] = t
    end
  end
  local tags = fm.delim_list(info.hugo_tags) or be.process_tags(plain_tags, info)
  local categories = fm.delim_list(info.hugo_categories)
  if not categories then
    categories = {}
    for _, c in ipairs(be.process_tags(cat_tags, info)) do
      categories[#categories + 1] = (c:gsub("^@", ""))
    end
  end
  local date, date_time = M.hugo_date(ctx.closed, info)
  if not date then
    date, date_time = M.hugo_date(info.date, info)
  end
  local title = nw(sanitized_title(info))
  local headless = be.truthy(info.hugo_headless) and "true" or nil
  local data = {
    { "title", title },
    { "audio", unquote(info.hugo_audio) },
    { "author", array(authors) },
    { "description", nw(type(info.description) == "string" and info.description or nil) },
    { "date", date },
    { "publishDate", M.hugo_date(ctx.scheduled, info) or M.hugo_date(info.hugo_publishdate, info) },
    { "expiryDate", M.hugo_date(info.hugo_expirydate, info) },
    { "aliases", array(aliases) },
    { "images", array(fm.delim_list(info.hugo_images)) },
    { "isCJKLanguage", be.truthy(info.hugo_iscjklanguage) or nil },
    { "keywords", array(fm.delim_list(info.hugo_keywords)) },
    { "layout", nw(info.hugo_layout) },
    { "lastmod", lastmod(info, date_time) },
    { "linkTitle", nw(info.hugo_linktitle) },
    { "markup", nw(info.hugo_markup) },
    { "outputs", array(split_words(info.hugo_outputs)) },
    { "series", array(fm.delim_list(info.hugo_series)) },
    { "slug", nw(info.hugo_slug) },
    { "tags", array(tags) },
    { "categories", array(categories) },
    { "type", nw(info.hugo_type) },
    { "url", nw(info.hugo_url) },
    { "videos", array(fm.delim_list(info.hugo_videos)) },
    { "draft", draft },
    { "headless", headless },
    { "creator", info.with_creator and nw(info.creator) or nil },
    { "locale", be.truthy(info.hugo_with_locale) and lang(info) or nil },
  }
  vim.list_extend(data, weights(info, ctx))
  vim.list_extend(data, custom(info))
  data[#data + 1] = { "menu", menu(info, ctx, title) }
  data[#data + 1] = { "resources", resources(info) }
  -- HUGO_FRONT_MATTER_KEY_REPLACE: old>new (new "nil" removes the key)
  if nw(info.hugo_front_matter_key_replace) then
    -- (like ox-hugo, the last pair first, each renaming the first key it
    -- finds: "tags>categories categories>tags" swaps them)
    local pairs_ = {}
    for pair in info.hugo_front_matter_key_replace:gmatch("%S+") do
      table.insert(pairs_, 1, pair)
    end
    for _, pair in ipairs(pairs_) do
      local old, new = pair:match("^([^>]+)>([^>]+)$")
      if old then
        for _, kv in ipairs(data) do
          if kv[1] == old then
            if new == "nil" then
              kv[2] = nil
            else
              kv[1] = new
            end
            break
          end
        end
      end
    end
  end
  return fm.encode(data, format)
end

---------------------------------------------------------------------------
-- Exporting
---------------------------------------------------------------------------

local function buffer_of(o)
  local bufnr = o.bufnr or 0
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return bufnr
end

--- Is a tag of `tags` an exclude tag of the file?
local function excluded(tags, lines, filename)
  local ex = { noexport = true }
  local kw = ox.collect_keywords(lines, filename and vim.fn.fnamemodify(filename, ":p:h") or nil, nil, nil, filename)
  local list = kw.EXCLUDE_TAGS
  if list then
    ex = {}
    for _, v in ipairs(list) do
      for t in v:gmatch("%S+") do
        ex[t] = true
      end
    end
  elseif (require("org.config").opts.export or {}).exclude_tags then
    ex = {}
    for _, t in ipairs(require("org.config").opts.export.exclude_tags) do
      ex[t] = true
    end
  end
  for _, t in ipairs(tags) do
    if ex[t] then
      return t
    end
  end
  return nil
end

--- Export one post to its file (or a buffer). `h` is the post headline
--- (nil: the whole file). Returns the output path.
---@param bufnr integer
---@param h org.Headline|nil
---@param o table { to_buffer?, visible_only?, index?, file? }
---@return string|nil path, string|nil text
function M.export_post(bufnr, h, o)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local filename = vim.api.nvim_buf_get_name(bufnr)
  filename = filename ~= "" and filename or nil
  local file = o.file or require("org.parser").parse(lines, filename)
  local ctx
  if h then
    ctx = M.subtree_context(h, file)
  else
    ctx = {}
  end
  ctx.index = o.index or M.link_index(lines, filename)
  ctx.to_buffer = o.to_buffer
  local text, info = ox.export_as("hugo", lines, {
    filename = filename,
    bufnr = bufnr,
    subtree_line = h and h.line or nil,
    visible_only = o.visible_only,
    ext = { hugo_ctx = ctx },
  })
  if o.to_buffer then
    return nil, text
  end
  local name
  if h then
    name = h.properties.EXPORT_FILE_NAME
  else
    name = info.keywords.EXPORT_FILE_NAME and info.keywords.EXPORT_FILE_NAME[1]
      or (filename and vim.fn.fnamemodify(filename, ":t:r"))
      or "index"
  end
  name = vim.fn.fnamemodify(vim.trim(name), ":t"):gsub("%.md$", "")
  local out = info.hugo_pub_dir .. "/" .. name .. ".md"
  vim.fn.mkdir(info.hugo_pub_dir, "p")
  local fd, err = io.open(out, "wb")
  if not fd then
    error(fmt("cannot write %s: %s", out, tostring(err)), 0)
  end
  fd:write(text)
  fd:close()
  return out
end

--- Run `fn` and report its error; returns its results.
local function protected(fn)
  local ok, a, b = pcall(fn)
  if not ok then
    utils().error("[hugo] " .. tostring(a))
    return nil
  end
  return a, b
end

--- The post headline at `line`, or nil.
local function post_at(file, line)
  return M.post_of(file:headline_at(line))
end

local function commented(h)
  while h do
    if h.commented then
      return h
    end
    h = h.parent
  end
  return nil
end

--- Export the whole file as one post (org-hugo--export-file-to-md): it
--- needs a `#+title` keyword.
---@param o? { bufnr?: integer, open?: boolean, visible_only?: boolean, noerror?: boolean }
---@return string|nil path
function M.export_file(o)
  o = o or {}
  local bufnr = buffer_of(o)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local filename = vim.api.nvim_buf_get_name(bufnr)
  local kw = ox.collect_keywords(lines, nil, nil, nil, filename ~= "" and filename or nil)
  local name = filename ~= "" and vim.fn.fnamemodify(filename, ":t") or vim.fn.bufname(bufnr)
  if not kw.TITLE then
    local msg =
      fmt("[hugo] %s: the entire file is attempted to be exported, but it is missing the #+title keyword", name)
    if o.noerror then
      utils().notify(msg)
    else
      utils().error(msg)
    end
    return nil
  end
  local tags = fm.delim_list(table.concat(kw.HUGO_TAGS or {}, "\n")) or {}
  local ex = excluded(tags, lines, filename)
  if ex then
    utils().notify(fmt("[hugo] %s was not exported as it is tagged with an exclude tag `%s'", name, ex))
    return nil
  end
  local out = protected(function()
    return M.export_post(bufnr, nil, o)
  end)
  if out then
    utils().notify("[hugo] Exported to " .. out)
    if o.open then
      vim.ui.open(out)
    end
  end
  return out
end

--- Export one subtree post (org-hugo--export-subtree-to-md); commented
--- posts and posts with an exclude tag are skipped.
---@return string|nil path
local function export_subtree(bufnr, h, o)
  local file = o.file
  local c = commented(h)
  if c then
    if c == h then
      utils().notify(fmt("[hugo] `%s' was not exported as it is commented out", h.title))
    else
      utils().notify(
        fmt("[hugo] `%s' was not exported as one of its parent subtrees `%s' is commented out", h.title, c.title)
      )
    end
    return nil
  end
  local ex = excluded(h:get_tags(), file.lines, file.filename)
  if ex then
    utils().notify(fmt("[hugo] `%s' was not exported as it is tagged with an exclude tag `%s'", h.title, ex))
    return nil
  end
  return protected(function()
    return M.export_post(bufnr, h, o)
  end)
end

--- Export what is meant (org-hugo-export-wim-to-md): the post subtree at
--- the cursor, all post subtrees with `all`, or the whole file when it has
--- no post subtrees. Returns the path (a list of paths with `all`).
---@param o? { bufnr?: integer, line?: integer, all?: boolean, open?: boolean, visible_only?: boolean, noerror?: boolean }
---@return string|string[]|nil
function M.export_wim(o)
  o = o or {}
  local bufnr = buffer_of(o)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local filename = vim.api.nvim_buf_get_name(bufnr)
  filename = filename ~= "" and filename or nil
  local file = require("org.parser").parse(lines, filename)
  local posts = M.posts(file)
  if #posts == 0 then
    return M.export_file(o)
  end
  local eo = vim.tbl_extend("force", o, { file = file, index = M.link_index(lines, filename) })
  if o.all then
    local out = {}
    local start = vim.uv.hrtime()
    for _, h in ipairs(posts) do
      local p = export_subtree(bufnr, h, eo)
      if p then
        out[#out + 1] = p
      end
    end
    local name = filename and vim.fn.fnamemodify(filename, ":t") or vim.fn.bufname(bufnr)
    utils().notify(
      fmt(
        "[hugo] Exported %d subtree%s from %s in %.3fs",
        #out,
        #out == 1 and "" or "s",
        name,
        (vim.uv.hrtime() - start) / 1e9
      )
    )
    return out
  end
  local line = o.line
  if not line then
    line = vim.api.nvim_get_current_buf() == bufnr and vim.api.nvim_win_get_cursor(0)[1] or 1
  end
  local h = post_at(file, line)
  if not h then
    utils().warn("Point is not in a valid Hugo post subtree; move to one and try again")
    return nil
  end
  local out = export_subtree(bufnr, h, eo)
  if out then
    utils().notify(fmt("[hugo] Exported `%s' to %s", h.title, out))
    if o.open then
      vim.ui.open(out)
    end
  end
  return out
end

--- Export to a temporary Markdown buffer (org-hugo-export-as-md): the
--- post subtree at the cursor with `subtree`, else the whole file.
---@param o? { bufnr?: integer, line?: integer, subtree?: boolean, visible_only?: boolean, hidden?: boolean }
---@return integer|nil buffer
function M.export_as_buffer(o)
  o = o or {}
  local bufnr = buffer_of(o)
  local h
  if o.subtree then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local filename = vim.api.nvim_buf_get_name(bufnr)
    local file = require("org.parser").parse(lines, filename ~= "" and filename or nil)
    local line = o.line or vim.api.nvim_win_get_cursor(0)[1]
    h = post_at(file, line) or file:headline_at(line)
  end
  local _, text = protected(function()
    return M.export_post(bufnr, h, { to_buffer = true, visible_only = o.visible_only })
  end)
  if not text then
    return nil
  end
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split((text:gsub("\n$", "")), "\n", { plain = true }))
  -- (a markdown ftplugin may fail, e.g. without its treesitter parser)
  pcall(vim.api.nvim_set_option_value, "filetype", "markdown", { buf = buf })
  pcall(vim.api.nvim_buf_set_name, buf, "*Org Hugo Export* #" .. buf)
  vim.bo[buf].modified = false
  local show = (require("org.config").opts.export or {}).show_temporary_export_buffer ~= false
  if show and not o.hidden then
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, buf)
  end
  return buf
end

--- Export the file as one post, even when it has post subtrees
--- (org-hugo-export-to-md), or the subtree at the cursor with `subtree`.
---@param o? { bufnr?: integer, line?: integer, subtree?: boolean, open?: boolean, visible_only?: boolean }
---@return string|nil
function M.export_to_md(o)
  o = o or {}
  if o.subtree then
    local bufnr = buffer_of(o)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local filename = vim.api.nvim_buf_get_name(bufnr)
    filename = filename ~= "" and filename or nil
    local file = require("org.parser").parse(lines, filename)
    local line = o.line or vim.api.nvim_win_get_cursor(0)[1]
    local h = post_at(file, line)
    if h then
      local out = export_subtree(bufnr, h, { file = file, index = M.link_index(lines, filename) })
      if out and o.open then
        vim.ui.open(out)
      end
      return out
    end
  end
  return M.export_file(o)
end

--- Whether a buffer is set up for Hugo (a base dir in a keyword, a
--- property or the options), for exporting on save.
---@param bufnr integer
---@return boolean
function M.has_base_dir(bufnr)
  if nw(opts().base_dir) then
    return true
  end
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if
      l:match("^[ \t]*#%+[Hh][Uu][Gg][Oo]_[Bb][Aa][Ss][Ee]_[Dd][Ii][Rr]:") or l:match("^[ \t]*:EXPORT_HUGO_BASE_DIR:")
    then
      return true
    end
  end
  return false
end

return M

---@mod org.export.publish Publishing (port of Emacs ox-publish.el)
---
--- Projects are configured in `export.publish.projects` (the equivalent
--- of `org-publish-project-alist`). Each project is a table whose keys are
--- the Emacs plist properties with `_` instead of `-` (`base_directory`,
--- `publishing_directory`, `publishing_function`, `recursive`, ...); any
--- other key (`with_toc`, `html_postamble`, ...) is passed to the export
--- as an option, like Emacs does. A project with `components` is a
--- meta-project publishing other projects.

local utils = require("org.utils")

local M = {}

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------

local function pcfg()
  local e = require("org.config").opts.export or {}
  return e.publish or {}
end

--- Keys of a project that are not export options.
local PUBLISH_KEYS = {
  name = true,
  base_directory = true,
  base_extension = true,
  publishing_directory = true,
  publishing_function = true,
  preparation_function = true,
  completion_function = true,
  recursive = true,
  exclude = true,
  include = true,
  components = true,
  auto_sitemap = true,
  sitemap_filename = true,
  sitemap_title = true,
  sitemap_style = true,
  sitemap_sort_files = true,
  sitemap_sort_folders = true,
  sitemap_ignore_case = true,
  sitemap_format_entry = true,
  sitemap_function = true,
  makeindex = true,
  body_only = true,
}

--- Timestamp directory (org-publish-timestamp-directory).
function M.timestamp_directory()
  local d = pcfg().timestamp_directory or (vim.fn.stdpath("data") .. "/org-timestamps/")
  d = vim.fn.fnamemodify(vim.fn.expand(d), ":p")
  if not d:match("/$") then
    d = d .. "/"
  end
  return d
end

local function use_timestamps()
  local v = pcfg().use_timestamps_flag
  if M._force then
    return false
  end
  return v == nil and true or v
end

local function list_skipped()
  local v = pcfg().list_skipped_files
  return v == nil and true or v
end

--- Projects as a list of { name, plist } (org-publish-project-alist).
--- A map is ordered by project name; a list keeps its order (each
--- element needs a `name`).
function M.projects()
  local projects = pcfg().projects or {}
  local out = {}
  if vim.islist(projects) then
    for _, p in ipairs(projects) do
      out[#out + 1] = { p.name, p }
    end
  else
    local names = vim.tbl_keys(projects)
    table.sort(names)
    for _, n in ipairs(names) do
      out[#out + 1] = { n, projects[n] }
    end
  end
  return out
end

local function find_project(name)
  for _, p in ipairs(M.projects()) do
    if p[1] == name then
      return p
    end
  end
end

local function prop(project, key, default)
  local v = project[2][key]
  if v == nil then
    return default
  end
  return v
end

---------------------------------------------------------------------------
-- Paths
---------------------------------------------------------------------------

--- Absolute, symlink-resolved file name (like file-truename), so that
--- cache keys and project lookups agree whatever the spelling.
local function expand(path, base)
  path = vim.fn.expand(path)
  if not path:match("^/") and base then
    path = base:gsub("/$", "") .. "/" .. path
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local real = vim.uv.fs_realpath(path)
  if real then
    return real
  end
  local dir = vim.uv.fs_realpath(vim.fn.fnamemodify(path, ":h"))
  if dir then
    return dir .. "/" .. vim.fn.fnamemodify(path, ":t")
  end
  return path
end

local function as_dir(path)
  return path:match("/$") and path or (path .. "/")
end

local function relative(path, base)
  return require("org.export.ox").relative_path(path, base)
end

local function mtime(path)
  local target = vim.uv.fs_realpath(path) or path
  local st = vim.uv.fs_stat(target)
  if not st then
    error("No such file: " .. path, 0)
  end
  return st.mtime.sec + st.mtime.nsec / 1e9
end

local function now()
  local t = vim.uv.clock_gettime("realtime")
  return t.sec + t.nsec / 1e9
end

local function truename(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

local function is_dir(path)
  local st = vim.uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

---------------------------------------------------------------------------
-- Cache (org-publish-cache)
---------------------------------------------------------------------------

M.cache = nil

local function cache_file(project_name)
  return M.timestamp_directory() .. project_name .. ".cache"
end

function M.write_cache_file(free)
  if not M.cache then
    error("write_cache_file called, but no cache present", 0)
  end
  local file = M.cache[":cache-file:"]
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  local fd = assert(io.open(file, "w"))
  fd:write(vim.json.encode(M.cache))
  fd:close()
  if free then
    M.cache = nil
  end
end

function M.initialize_cache(project_name)
  local dir = M.timestamp_directory()
  vim.fn.mkdir(dir, "p")
  if not is_dir(dir) then
    error("Org publish timestamp: " .. dir .. " is not a directory", 0)
  end
  if M.cache and M.cache[":project:"] == project_name then
    return M.cache
  end
  local file = cache_file(project_name)
  local content = utils.readfile(file)
  local ok, decoded = false, nil
  if content then
    ok, decoded = pcall(vim.json.decode, table.concat(content, "\n"))
  end
  if ok and type(decoded) == "table" then
    M.cache = decoded
  else
    M.cache = { [":project:"] = project_name, [":cache-file:"] = file }
    M.write_cache_file()
  end
  return M.cache
end

function M.reset_cache()
  M.cache = nil
end

--- Remove all files in the timestamp directory.
function M.remove_all_timestamps()
  local dir = M.timestamp_directory()
  if is_dir(dir) then
    for name, t in vim.fs.dir(dir) do
      if t == "file" and not name:match("^%.") then
        os.remove(dir .. name)
      end
    end
    M.reset_cache()
  end
end

local function cache_get(key)
  if not M.cache then
    error("cache_get called, but no cache present", 0)
  end
  return M.cache[key]
end

local function cache_set(key, value)
  if not M.cache then
    error("cache_set called, but no cache present", 0)
  end
  M.cache[key] = value
  return value
end

--- org-publish-timestamp-filename
local function timestamp_key(filename, pub_dir, pub_func)
  local fname = type(pub_func) == "string" and pub_func or (pub_func and "function" or "")
  return "X" .. vim.fn.sha256(filename .. "::" .. (pub_dir or "") .. "::" .. fname)
end

--- Files included by `filename` (#+INCLUDE keywords).
local function included_mtimes(filename)
  local out = {}
  if not filename:match("%.org$") then
    return out
  end
  local dir = vim.fn.fnamemodify(filename, ":h")
  for _, l in ipairs(utils.readfile(filename) or {}) do
    local v = l:match("^[ \t]*#%+[Ii][Nn][Cc][Ll][Uu][Dd][Ee]:[ \t]*(.-)[ \t]*$")
    if v then
      local f = v:match('^"(.-)"') or v:match("^(%S+)")
      if f then
        f = f:gsub("::.*$", "")
        local full = expand(f, dir)
        local ok, t = pcall(mtime, full)
        if ok then
          out[#out + 1] = t
        end
      end
    end
  end
  return out
end

--- org-publish-cache-file-needs-publishing
function M.file_needs_publishing(filename, pub_dir, pub_func)
  local pstamp = cache_get(timestamp_key(filename, pub_dir, pub_func))
  if pstamp == nil then
    return true
  end
  if pstamp < mtime(filename) then
    return true
  end
  for _, t in ipairs(included_mtimes(filename)) do
    if pstamp < t then
      return true
    end
  end
  return false
end

local function update_timestamp(filename, pub_dir, pub_func)
  cache_set(timestamp_key(filename, pub_dir, pub_func), now())
end

function M.cache_get_file_property(filename, property, default, no_create, project_name)
  if project_name then
    M.initialize_cache(project_name)
  end
  local props = cache_get(filename)
  if props == nil then
    if not no_create then
      cache_set(filename, { [property] = default })
    end
    return default
  end
  if M.file_needs_publishing(filename) then
    -- the file (or an included one) changed: the cached data is stale
    cache_set(filename, vim.empty_dict())
    update_timestamp(filename)
    return default
  end
  if props[property] ~= nil then
    return props[property]
  end
  return default
end

function M.cache_set_file_property(filename, property, value, project_name)
  if project_name then
    M.initialize_cache(project_name)
  end
  local props = cache_get(filename)
  if props then
    props[property] = value
    return value
  end
  M.cache_get_file_property(filename, property, value, nil, project_name)
  return value
end

---------------------------------------------------------------------------
-- Projects and files
---------------------------------------------------------------------------

--- org-publish-expand-projects: splice components.
function M.expand_projects(projects)
  local rest = vim.list_slice(projects)
  local out, seen = {}, {}
  while #rest > 0 do
    local p = table.remove(rest, 1)
    local comps = p[2].components
    if comps then
      local add = {}
      for _, c in ipairs(comps) do
        add[#add + 1] = find_project(c) or error(string.format("Unknown component %q in project %q", c, p[1]), 0)
      end
      rest = vim.list_extend(add, rest)
    elseif not seen[p[1]] then
      seen[p[1]] = true
      out[#out + 1] = p
    end
  end
  return out
end

local function match_ext(name, extension)
  if extension == "any" then
    return true
  end
  return vim.regex("^[^.].*\\.\\(" .. extension .. "\\)$"):match_str(name) ~= nil
end

--- org-publish-get-base-files
function M.get_base_files(project)
  local base_dir = as_dir(expand(prop(project, "base_directory")))
  local extension = prop(project, "base_extension", "org")
  local files = {}
  if is_dir(base_dir) then
    if not prop(project, "recursive") then
      for name in vim.fs.dir(base_dir) do
        local full = base_dir .. name
        if match_ext(name, extension) and not is_dir(full) then
          files[#files + 1] = full
        end
      end
      table.sort(files)
    else
      local function walk(dir, depth)
        if depth > 100 then
          error("Apparent cycle of symbolic links for " .. base_dir, 0)
        end
        local names = {}
        for name in vim.fs.dir(dir) do
          names[#names + 1] = name
        end
        table.sort(names)
        for _, name in ipairs(names) do
          local full = dir .. name
          if is_dir(full) then
            walk(full .. "/", depth + 1)
          elseif match_ext(name, extension) then
            files[#files + 1] = full
          end
        end
      end
      walk(base_dir, 0)
    end
  end
  local out, seen = {}, {}
  local function add(f)
    if not seen[f] then
      seen[f] = true
      out[#out + 1] = f
    end
  end
  local exclude = prop(project, "exclude")
  local re = exclude and vim.regex(exclude)
  for _, f in ipairs(files) do
    if not (re and re:match_str(relative(f, base_dir))) then
      add(f)
    end
  end
  if prop(project, "auto_sitemap") then
    add(expand(prop(project, "sitemap_filename", "sitemap.org"), base_dir))
  end
  for _, f in ipairs(prop(project, "include", {})) do
    add(expand(f, base_dir))
  end
  return out
end

--- org-publish-get-project-from-filename
function M.get_project_from_filename(filename, up)
  filename = expand(filename)
  local project
  for _, p in ipairs(M.projects()) do
    if not p[2].components and p[2].base_directory then
      local base = expand(p[2].base_directory)
      local included = false
      for _, f in ipairs(p[2].include or {}) do
        if truename(expand(f, base)) == truename(filename) then
          included = true
        end
      end
      local ok
      if included then
        ok = true
      else
        local ex = p[2].exclude
        local extension = p[2].base_extension or "org"
        if ex and vim.regex(ex):match_str(relative(filename, base)) then
          ok = false
        elseif not (extension == "any" or extension == vim.fn.fnamemodify(filename, ":e")) then
          ok = false
        else
          ok = vim.tbl_contains(M.get_base_files(p), filename)
        end
      end
      if ok then
        project = p
        break
      end
    end
  end
  if not project or not up then
    return project
  end
  local function parent(pr)
    for _, p in ipairs(M.projects()) do
      if vim.tbl_contains(p[2].components or {}, pr[1]) then
        return parent(p)
      end
    end
    return pr
  end
  return parent(project)
end

---------------------------------------------------------------------------
-- Publishing functions
---------------------------------------------------------------------------

--- Lines of a file: those of a loaded buffer when there is one.
local function file_lines(filename)
  local bufnr = vim.fn.bufnr(filename)
  if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), bufnr
  end
  return utils.readfile(filename) or {}, nil
end

--- org-export-output-file-name with a publishing directory.
function M.output_file_name(filename, lines, extension, pub_dir)
  local base
  for _, l in ipairs(lines) do
    local v = l:match("^[ \t]*#%+[Ee][Xx][Pp][Oo][Rr][Tt]_[Ff][Ii][Ll][Ee]_[Nn][Aa][Mm][Ee]:[ \t]+(%S.-)[ \t]*$")
    if v then
      base = v
      break
    end
  end
  base = base or vim.fn.fnamemodify(filename, ":t"):gsub("%.gpg$", "")
  base = vim.fn.fnamemodify(base, ":r") .. extension
  local out
  if pub_dir then
    out = as_dir(pub_dir) .. vim.fn.fnamemodify(base, ":t")
  else
    out = expand(base, vim.fn.fnamemodify(filename, ":h"))
  end
  if truename(out) == truename(filename) then
    out = out .. extension
  end
  return out
end

--- Export options of a project: every key that is not a publishing one.
local function ext_options(plist)
  local ext = {}
  for k, v in pairs(plist) do
    if not PUBLISH_KEYS[k] then
      ext[k] = v
    end
  end
  if plist.base_directory then
    ext.base_directory = as_dir(expand(plist.base_directory))
  end
  return ext
end

--- Index entries of an exported file (org-publish-collect-index).
local function collect_index(info)
  local element = require("org.export.element")
  local file = truename(info.input_file)
  local entries, seen = {}, {}
  element.map(info.parse_tree, "keyword", function(k)
    if k.key == "INDEX" then
      local parent = element.lineage(k, "headline")
      local target = vim.NIL
      if parent then
        local p = parent.props or {}
        if p.ID then
          target = { "id", p.ID }
        elseif p.CUSTOM_ID then
          target = { "custom-id", p.CUSTOM_ID }
        else
          target = { "name", ((parent.raw_value or ""):gsub("%[%d+%%%]", ""):gsub("%[%d+/%d+%]", "")) }
        end
      end
      local e = { k.value, file, target }
      local key = vim.inspect(e)
      if not seen[key] then
        seen[key] = true
        entries[#entries + 1] = e
      end
    end
  end, { ignore = info.ignore })
  M.cache_set_file_property(file, "index", entries)
end

--- Store the references used by a published file (org-publish--store-crossrefs).
local function store_crossrefs(info)
  local ox = require("org.export.ox")
  local crossrefs = vim.empty_dict()
  for datum, ref in pairs(info.internal_references.by_datum or {}) do
    for _, cell in ipairs(ox.search_cells(datum)) do
      crossrefs[cell] = ref
    end
  end
  M.cache_set_file_property(truename(info.input_file), "crossrefs", crossrefs)
end

--- Publish an Org file with a back-end (org-publish-org-to).
---@param backend string
---@param filename string
---@param extension string with the leading dot
---@param plist table project properties
---@param pub_dir? string
---@param ext_extra? table extra export options
function M.org_to(backend, filename, extension, plist, pub_dir, ext_extra)
  if pub_dir then
    vim.fn.mkdir(pub_dir, "p")
  end
  local ox = require("org.export.ox")
  local lines, bufnr = file_lines(filename)
  local output = M.output_file_name(filename, lines, extension, pub_dir)
  local ext = ext_options(plist)
  for k, v in pairs(ext_extra or {}) do
    ext[k] = v
  end
  ext.output_file = output
  if M.cache then
    local cr = M.cache_get_file_property(truename(filename), "crossrefs", nil, true)
    if type(cr) == "table" then
      ext.crossrefs = cr
    end
  end
  M.install_crossrefs()
  local text, info = ox.export_as(backend, lines, { filename = filename, bufnr = bufnr, body_only = plist.body_only, ext = ext })
  if M.cache then
    store_crossrefs(info)
    collect_index(info)
  end
  if not text:match("\n$") then
    text = text .. "\n"
  end
  vim.fn.mkdir(vim.fn.fnamemodify(output, ":h"), "p")
  local fd = assert(io.open(output, "w"))
  fd:write(text)
  fd:close()
  return output
end

--- Copy a file without transformation (org-publish-attachment).
function M.attachment(_, filename, pub_dir)
  vim.fn.mkdir(pub_dir, "p")
  local output = as_dir(pub_dir) .. vim.fn.fnamemodify(filename, ":t")
  if truename(vim.fn.fnamemodify(filename, ":h")) ~= truename(pub_dir) then
    assert(vim.uv.fs_copyfile(filename, output))
  end
  return output
end

local function html_ext()
  local h = (require("org.config").opts.export or {}).html or {}
  return h.extension or "html"
end

--- Named publishing functions (the org-*-publish-to-* functions).
M.functions = {
  html = function(plist, filename, pub_dir)
    return M.org_to("html", filename, "." .. (plist.html_extension or html_ext()), plist, pub_dir)
  end,
  latex = function(plist, filename, pub_dir)
    return M.org_to("latex", filename, ".tex", plist, pub_dir)
  end,
  pdf = function(plist, filename, pub_dir)
    local tex = M.org_to("latex", filename, ".tex", plist, vim.fn.fnamemodify(filename, ":h"))
    local pdf, err = require("org.export.latex").compile(tex)
    if not pdf then
      error(err or ("PDF file was not produced from " .. tex), 0)
    end
    local target = as_dir(pub_dir) .. vim.fn.fnamemodify(pdf, ":t")
    if truename(pdf) ~= truename(target) then
      vim.fn.mkdir(pub_dir, "p")
      assert(vim.uv.fs_rename(pdf, target))
    end
    return target
  end,
  beamer = function(plist, filename, pub_dir)
    return M.org_to("beamer", filename, ".tex", plist, pub_dir)
  end,
  md = function(plist, filename, pub_dir)
    return M.org_to("md", filename, ".md", plist, pub_dir)
  end,
  gfm = function(plist, filename, pub_dir)
    return M.org_to("gfm", filename, ".md", plist, pub_dir)
  end,
  ascii = function(plist, filename, pub_dir)
    return M.org_to("ascii", filename, ".txt", plist, pub_dir, { ascii_charset = "ascii" })
  end,
  latin1 = function(plist, filename, pub_dir)
    return M.org_to("ascii", filename, ".txt", plist, pub_dir, { ascii_charset = "latin1" })
  end,
  utf8 = function(plist, filename, pub_dir)
    return M.org_to("ascii", filename, ".txt", plist, pub_dir, { ascii_charset = "utf-8" })
  end,
  org = function(plist, filename, pub_dir)
    return M.org_to("org", filename, ".org", plist, pub_dir)
  end,
  attachment = function(plist, filename, pub_dir)
    return M.attachment(plist, filename, pub_dir)
  end,
}

local function resolve_function(f)
  if type(f) == "function" then
    return f, "function"
  end
  local fn = M.functions[f]
  if not fn then
    error("Unknown publishing function: " .. tostring(f), 0)
  end
  return fn, f
end

local function run_hooks(fun, plist)
  if type(fun) == "function" then
    fun(plist)
  elseif type(fun) == "table" then
    for _, f in ipairs(fun) do
      f(plist)
    end
  end
end

--- org-publish-needed-p
local function needed_p(filename, pub_dir, pub_func_name)
  local rtn = not use_timestamps() or M.file_needs_publishing(filename, pub_dir, pub_func_name)
  if rtn then
    utils.notify(string.format("Publishing file %s using `%s'", filename, pub_func_name))
  elseif list_skipped() then
    utils.notify("Skipping unmodified file " .. filename)
  end
  return rtn
end

--- Publish FILENAME from PROJECT (org-publish-file).
function M.publish_file(filename, project, no_cache)
  filename = expand(filename)
  project = project or M.get_project_from_filename(filename)
  if not project then
    error(string.format("File %q is not part of any known project", vim.fn.fnamemodify(filename, ":~")), 0)
  end
  local plist = project[2]
  local pf = prop(project, "publishing_function", "html")
  if not pf then
    error("No publishing function chosen", 0)
  end
  local fns = (type(pf) == "table") and pf or { pf }
  local base_dir = plist.base_directory or error(string.format("Project %q does not have :base-directory defined", project[1]), 0)
  base_dir = as_dir(expand(base_dir))
  local pub_base = plist.publishing_directory
    or error(string.format("Project %q does not have :publishing-directory defined", project[1]), 0)
  pub_base = as_dir(expand(pub_base))
  local pub_dir = vim.fn.fnamemodify(expand(relative(filename, base_dir), pub_base), ":h") .. "/"
  if not no_cache then
    M.initialize_cache(project[1])
  end
  local outputs = {}
  for _, f in ipairs(fns) do
    local fn, name = resolve_function(f)
    if needed_p(filename, pub_base, name) then
      local output = fn(plist, filename, pub_dir)
      update_timestamp(filename, pub_base, name)
      update_timestamp(filename)
      outputs[#outputs + 1] = output
      for _, h in ipairs(require("org.export.ox").as_list(pcfg().after_publishing_hook)) do
        h(filename, output)
      end
    end
  end
  M.write_cache_file()
  return outputs
end

---------------------------------------------------------------------------
-- Site map
---------------------------------------------------------------------------

--- Value of an export keyword of FILE (org-publish-find-property for the
--- keywords used by site maps).
function M.find_property(file, keyword, project)
  file = expand(file, project and project[2].base_directory and expand(project[2].base_directory) or nil)
  if is_dir(file) or vim.fn.filereadable(file) == 0 then
    return nil
  end
  local ox = require("org.export.ox")
  local kw = ox.collect_keywords(file_lines(file), vim.fn.fnamemodify(file, ":h"))
  local values = kw[keyword:upper()]
  if not values then
    return nil
  end
  return values
end

--- org-publish-find-title
function M.find_title(file, project)
  file = expand(file, expand(project[2].base_directory))
  local cached = M.cache_get_file_property(file, "title", nil, true, project[1])
  if cached then
    return cached
  end
  local values = M.find_property(file, "TITLE", project)
  local title
  if values then
    local element = require("org.export.element")
    local parsed = element.new({}):parse_objects(table.concat(values, " "), element.RESTRICTIONS.keyword)
    title = element.interpret(parsed)
  else
    title = vim.fn.fnamemodify(file, ":t:r")
  end
  return M.cache_set_file_property(file, "title", title, project[1])
end

--- org-publish-find-date: time (seconds) of FILE's DATE or modification.
function M.find_date(file, project)
  file = expand(file, expand(project[2].base_directory))
  local cached = M.cache_get_file_property(file, "date", nil, true, project[1])
  if cached then
    return cached
  end
  local date
  if is_dir(file) then
    date = mtime(file)
  else
    local values = M.find_property(file, "DATE", project)
    if values then
      local element = require("org.export.element")
      local text = table.concat(values, " ")
      local p = element.new({})
      for i = 1, #text do
        local ts = p:parse_timestamp(text, i)
        if ts and ts.year_start then
          date = require("org.export.ox").timestamp_time(ts)
          break
        end
      end
    end
    date = date or mtime(file)
  end
  return M.cache_set_file_property(file, "date", date, project[1])
end

--- org-publish-sitemap-default-entry
function M.sitemap_default_entry(entry, style, project)
  if not entry:match("/$") then
    return string.format("[[file:%s][%s]]", entry, M.find_title(entry, project))
  elseif style == "tree" then
    return vim.fn.fnamemodify(entry:gsub("/$", ""), ":t")
  end
  return entry
end

--- Org syntax of a list as returned by org-list-to-lisp (org-list-to-org):
--- { "unordered", { "item" }, { "item", sublist } }.
function M.list_to_org(list, depth)
  depth = depth or 0
  local out = {}
  local indent = string.rep("  ", depth)
  for i = 2, #list do
    local item = list[i]
    out[#out + 1] = indent .. "- " .. item[1]
    if item[2] then
      local sub = M.list_to_org(item[2], depth + 1)
      if sub ~= "" then
        out[#out + 1] = sub
      end
    end
  end
  return table.concat(out, "\n")
end

--- org-publish-sitemap-default
function M.sitemap_default(title, list)
  return "#+TITLE: " .. title .. "\n\n" .. M.list_to_org(list)
end

local function files_to_list(files, project, style, format_entry)
  local root = as_dir(expand(project[2].base_directory))
  if style == "list" then
    local l = { "unordered" }
    for _, f in ipairs(files) do
      l[#l + 1] = { format_entry(relative(f, root) .. (f:match("/$") and "/" or ""), style, project) }
    end
    return l
  elseif style == "tree" then
    local files_only, dirs = {}, {}
    for _, f in ipairs(files) do
      if f:match("/$") then
        dirs[#dirs + 1] = f
      else
        files_only[#files_only + 1] = f
      end
    end
    local function subtree(dir)
      local l = { "unordered" }
      for _, f in ipairs(files_only) do
        if vim.fn.fnamemodify(f, ":h") .. "/" == dir then
          l[#l + 1] = { format_entry(relative(f, root), style, project) }
        end
      end
      for _, sub in ipairs(dirs) do
        if vim.fn.fnamemodify(sub:gsub("/$", ""), ":h") .. "/" == dir then
          l[#l + 1] = { format_entry(relative(sub, root) .. "/", style, project), subtree(sub) }
        end
      end
      return l
    end
    return subtree(root)
  end
  error("Unknown site-map style: `" .. tostring(style) .. "'", 0)
end

--- Stable merge sort with `pred(a, b)` meaning "a goes first".
local function stable_sort(list, pred)
  if #list <= 1 then
    return list
  end
  local mid = math.floor(#list / 2)
  local a = stable_sort(vim.list_slice(list, 1, mid), pred)
  local b = stable_sort(vim.list_slice(list, mid + 1), pred)
  local out, i, j = {}, 1, 1
  while i <= #a and j <= #b do
    if pred(b[j], a[i]) and not pred(a[i], b[j]) then
      out[#out + 1] = b[j]
      j = j + 1
    else
      out[#out + 1] = a[i]
      i = i + 1
    end
  end
  for k = i, #a do
    out[#out + 1] = a[k]
  end
  for k = j, #b do
    out[#out + 1] = b[k]
  end
  return out
end

--- Generate the site map of PROJECT (org-publish-sitemap).
function M.sitemap(project, sitemap_filename)
  local root = as_dir(expand(project[2].base_directory))
  sitemap_filename = expand(sitemap_filename or "sitemap.org", root)
  local title = prop(project, "sitemap_title") or ("Sitemap for project " .. project[1])
  local style = prop(project, "sitemap_style", "tree")
  local builder = prop(project, "sitemap_function", M.sitemap_default)
  local format_entry = prop(project, "sitemap_format_entry", M.sitemap_default_entry)
  local sort_folders = prop(project, "sitemap_sort_folders", pcfg().sitemap_sort_folders or "ignore")
  local sort_files = prop(project, "sitemap_sort_files", pcfg().sitemap_sort_files or "alphabetically")
  local ignore_case = prop(project, "sitemap_ignore_case", pcfg().sitemap_sort_ignore_case or false)
  local function org_file_p(f)
    return f:match("%.org$") ~= nil
  end
  local function key(f)
    if org_file_p(f) then
      return vim.fn.fnamemodify(f, ":h") .. "/" .. M.find_title(f, project)
    end
    return f
  end
  local function pred(a, b)
    local retval = true
    if sort_files == "alphabetically" then
      local A, B = key(a), key(b)
      if ignore_case then
        A, B = A:lower(), B:lower()
      end
      retval = A <= B
    elseif sort_files == "chronologically" or sort_files == "anti-chronologically" then
      local ad, bd = M.find_date(a, project), M.find_date(b, project)
      if sort_files == "chronologically" then
        retval = not (bd < ad)
      else
        retval = not (ad < bd)
      end
    elseif sort_files == nil or sort_files == false then
      retval = false
    else
      error("Invalid sort value " .. tostring(sort_files), 0)
    end
    if sort_folders == "first" or sort_folders == "last" then
      local ad, bd = a:match("/$") ~= nil, b:match("/$") ~= nil
      if ad and not bd then
        retval = sort_folders == "first"
      elseif bd and not ad then
        retval = sort_folders == "last"
      end
    end
    return retval
  end
  utils.notify("Generating sitemap for " .. title)
  local files = {}
  for _, f in ipairs(M.get_base_files(project)) do
    if f ~= sitemap_filename then
      files[#files + 1] = f
    end
  end
  if not (style == "list" and sort_folders == "ignore") then
    local dirs, seen = {}, { [root] = true }
    for _, f in ipairs(files) do
      local d = vim.fn.fnamemodify(f, ":h") .. "/"
      if not seen[d] then
        seen[d] = true
        dirs[#dirs + 1] = d
      end
    end
    files = vim.list_extend(dirs, files)
  end
  if sort_files or sort_folders ~= "ignore" then
    files = stable_sort(files, pred)
  end
  local text = builder(title, files_to_list(files, project, style, format_entry))
  local fd = assert(io.open(sitemap_filename, "w"))
  fd:write(text)
  fd:close()
  return sitemap_filename
end

---------------------------------------------------------------------------
-- Index
---------------------------------------------------------------------------

--- Build theindex.inc (and theindex.org) from the cached index entries
--- (org-publish-index-generate-theindex).
function M.generate_theindex(project, directory)
  directory = as_dir(expand(directory))
  local base = as_dir(truename(expand(project[2].base_directory)))
  local full = {}
  local seen = {}
  for _, file in ipairs(M.get_base_files(project)) do
    local index = M.cache_get_file_property(truename(file), "index", nil, true, project[1]) or {}
    for _, term in ipairs(index) do
      local k = vim.inspect(term)
      if not seen[k] then
        seen[k] = true
        full[#full + 1] = term
      end
    end
  end
  full = stable_sort(full, function(a, b)
    return a[1]:lower() < b[1]:lower()
  end)
  local out = {}
  local current_letter, last_entry
  for _, idx in ipairs(full) do
    local entry = vim.split(idx[1], "!", { trimempty = true })
    local letter = entry[1]:sub(1, 1):upper()
    local file = relative(idx[2], base)
    if letter ~= current_letter then
      out[#out + 1] = "* " .. letter .. "\n"
    end
    local rank
    if last_entry and vim.deep_equal(entry, last_entry) then
      rank = #entry - 1
    else
      rank = #entry
      for n = 1, #entry do
        if not last_entry or entry[n] ~= last_entry[n] then
          rank = n - 1
          break
        end
      end
    end
    local len = #entry - rank
    for n = 0, len - 1 do
      local text
      if n ~= len - 1 then
        text = entry[rank + n + 1]
      else
        local target = idx[3]
        local dest
        if type(target) ~= "table" then
          dest = "file:" .. file
        elseif target[1] == "id" then
          dest = "id:" .. target[2]
        elseif target[1] == "custom-id" then
          dest = string.format("file:%s::#%s", file, target[2])
        else
          dest = string.format("file:%s::*%s", file, target[2])
        end
        text = string.format("[[%s][%s]]", dest, entry[#entry])
      end
      out[#out + 1] = string.rep(" ", (rank + n) * 2) .. "  - " .. text .. "\n"
    end
    current_letter, last_entry = letter, entry
  end
  local fd = assert(io.open(directory .. "theindex.inc", "w"))
  fd:write(table.concat(out))
  fd:close()
  local index_org = directory .. "theindex.org"
  if vim.fn.filereadable(index_org) == 0 then
    local f2 = assert(io.open(index_org, "w"))
    f2:write('#+TITLE: Index\n\n#+INCLUDE: "theindex.inc"\n\n')
    f2:close()
  end
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

--- Publish every file of PROJECTS (org-publish-projects).
function M.publish_projects(projects)
  for _, project in ipairs(M.expand_projects(projects)) do
    local plist = project[2]
    run_hooks(plist.preparation_function, plist)
    M.initialize_cache(project[1])
    if plist.auto_sitemap then
      M.sitemap(project, plist.sitemap_filename or "sitemap.org")
    end
    local theindex = expand("theindex.org", expand(plist.base_directory))
    for _, file in ipairs(M.get_base_files(project)) do
      if file ~= theindex then
        M.publish_file(file, project, true)
      end
    end
    if plist.makeindex then
      M.generate_theindex(project, plist.base_directory)
      M.publish_file(theindex, project, true)
    end
    run_hooks(plist.completion_function, plist)
    M.write_cache_file()
  end
end

local function with_force(force, fn)
  local saved = M._force
  M._force = force and true or false
  local ok, err = pcall(fn)
  M._force = saved
  M._publishing = nil
  if not ok then
    error(err, 0)
  end
end

--- Run `fn` in the background when `async` (one step at a time on the
--- event loop), else now.
local function run(async, fn)
  if not async then
    return fn()
  end
  vim.schedule(function()
    local ok, err = pcall(fn)
    if not ok then
      utils.error("Publishing failed: " .. tostring(err))
    else
      utils.notify("Publishing done")
    end
  end)
end

--- Publish a project (org-publish). FORCE publishes every file.
---@param project string|table project name, or { name, plist }
function M.publish_project(project, force, async)
  if type(project) == "string" then
    project = find_project(project) or error("Unknown project " .. project, 0)
  end
  run(async, function()
    with_force(force, function()
      M._publishing = true
      M.publish_projects({ project })
    end)
  end)
end
M.publish = M.publish_project

--- Publish all projects (org-publish-all). FORCE removes all timestamps.
function M.publish_all(force, async)
  run(async, function()
    if force then
      M.remove_all_timestamps()
    end
    with_force(force, function()
      M._publishing = true
      M.publish_projects(M.projects())
    end)
  end)
end

--- Publish the current buffer's file (org-publish-current-file).
function M.publish_current_file(force, async)
  local file = vim.api.nvim_buf_get_name(0)
  run(async, function()
    with_force(force, function()
      M._publishing = true
      M.publish_file(file)
    end)
  end)
end

--- Publish the project of the current file (org-publish-current-project).
function M.publish_current_project(force, async)
  local file = vim.api.nvim_buf_get_name(0)
  local project = M.get_project_from_filename(file, true)
  if not project then
    error(string.format("File %s is not part of any known project", file), 0)
  end
  M.publish_project(project, force, async)
end

---------------------------------------------------------------------------
-- Links to other files (used by the HTML back-end)
---------------------------------------------------------------------------

--- Convert FILENAME to be relative to the project's base directory
--- (org-publish-file-relative-name).
function M.file_relative_name(filename, info)
  local base = info and info.base_directory
  if base and (filename:match("^/") or filename:match("^~")) then
    local abs = expand(filename)
    base = as_dir(expand(base))
    if abs:sub(1, #base) == base then
      return relative(abs, base)
    end
  end
  return filename
end

local function search_headline(file, search)
  local lines = utils.readfile(file)
  if not lines then
    error(string.format("No such file: %q", file), 0)
  end
  local parser = require("org.parser")
  local f = parser.parse(lines, file)
  local title = search:match("^%*(.*)$")
  local exact = title and vim.trim(title) or vim.trim(search)
  local function clean(s)
    return vim.trim((s:gsub("%[%d*%%%]", ""):gsub("%[%d*/%d*%]", "")))
  end
  local hl = f:find_headline(function(h)
    return clean(h:plain_title()) == clean(exact) or h:plain_title() == exact
  end)
  if hl then
    return hl
  end
  if not title then
    -- targets and named elements are valid destinations, but not headlines
    for _, l in ipairs(lines) do
      if l:find("<<" .. search .. ">>", 1, true) or l:match("^[ \t]*#%+[Nn][Aa][Mm][Ee]:[ \t]*" .. vim.pesc(search) .. "[ \t]*$") then
        return false
      end
    end
  end
  require("org.export.ox").broken_link(search)
end

--- Reference of the element matching SEARCH in FILE
--- (org-publish-resolve-external-link, with PREFER-CUSTOM like ox-html):
--- the CUSTOM_ID of a headline when it has one; while publishing, the
--- reference the target file uses (or will use) for it; else
--- "MissingReference".
function M.resolve_external_link(search, file, info)
  if info and info.input_file and not (file:match("^/") or file:match("^~")) then
    file = expand(file, vim.fn.fnamemodify(info.input_file, ":p:h"))
  else
    file = expand(file)
  end
  if search:match("^#") then
    return search:sub(2)
  end
  local hl = search_headline(file, search)
  if hl then
    local cid = hl.properties and hl.properties.CUSTOM_ID
    if cid and cid:match("%S") then
      return cid
    end
  end
  if not M.cache or not M._publishing then
    utils.notify(string.format("Reference %q in file %q cannot be resolved without publishing", search, file))
    return "MissingReference"
  end
  local ox = require("org.export.ox")
  local filename = truename(file)
  local crossrefs = M.cache_get_file_property(filename, "crossrefs", nil, true)
  if type(crossrefs) ~= "table" or vim.islist(crossrefs) then
    crossrefs = vim.empty_dict()
  end
  local cells = ox.string_to_search_cell(search)
  for _, c in ipairs(cells) do
    if crossrefs[c] then
      return crossrefs[c]
    end
  end
  -- unknown yet: create the reference the target will use when published
  local used = {}
  for _, r in pairs(crossrefs) do
    used[r] = true
  end
  local h = vim.fn.sha256(filename .. "::" .. search)
  local k = 1
  local ref = "org" .. h:sub(k, k + 6)
  while used[ref] do
    k = k + 1
    ref = "org" .. h:sub(k, k + 6)
  end
  for _, c in ipairs(cells) do
    crossrefs[c] = ref
  end
  M.cache_set_file_property(filename, "crossrefs", crossrefs)
  return ref
end

---------------------------------------------------------------------------
-- Cross references in org.export.ox
---------------------------------------------------------------------------

--- Make `ox.get_reference` reuse the references of `info.crossrefs`
--- (search cell -> reference), like `org-export-get-reference` does with
--- `:crossrefs`, unless the engine already supports it.
function M.install_crossrefs()
  local ox = require("org.export.ox")
  if ox.supports_crossrefs or M._crossrefs_installed then
    return
  end
  M._crossrefs_installed = true
  local orig = ox.get_reference
  ox.get_reference = function(datum, info)
    local refs = info.internal_references
    local crossrefs = info.crossrefs
    if crossrefs and refs and not refs.by_datum[datum] and datum.type then
      for _, cell in ipairs(ox.search_cells(datum)) do
        local r = crossrefs[cell]
        if r and not refs.used[r] then
          refs.used[r] = true
          refs.by_datum[datum] = r
          return r
        end
      end
    end
    return orig(datum, info)
  end
end

return M

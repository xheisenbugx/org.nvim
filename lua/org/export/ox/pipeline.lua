---@mod org.export.ox.pipeline The export pipeline (`export_as`)
---
--- Part of org.export.ox, which loads it: the functions are fields of
--- that module.

local element = require("org.export.element")
local M = require("org.export.ox")

local trim = M.trim
local cfg = M.cfg
local apply_filters = M.apply_filters

---------------------------------------------------------------------------
-- Export
---------------------------------------------------------------------------

--- org-display-custom-times of an exported buffer: its C-c C-x C-t toggle,
--- else `#+STARTUP: customtime`, else `display_custom_times`.
local function custom_times_p(bufnr, file)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].org_custom_times ~= nil then
    return vim.b[bufnr].org_custom_times == true
  end
  if file.settings.startup.customtime then
    return true
  end
  return require("org.config").opts.display_custom_times == true
end

--- Lines of the subtree at `line` for export: { lines, props, title }.
local function subtree_region(lines, line, todo)
  local parser = require("org.parser")
  local s = math.min(line, #lines)
  while s >= 1 and not lines[s]:match("^%*+ ") do
    s = s - 1
  end
  if s < 1 then
    return nil
  end
  local parts = parser.parse_headline_line(lines[s], todo)
  local level = parts.level
  local e = s + 1
  while e <= #lines do
    local st = lines[e]:match("^(%*+) ")
    if st and #st <= level then
      break
    end
    e = e + 1
  end
  -- the export starts after the planning line and the property drawer
  local b = s + 1
  local props = {}
  local kw = lines[b] and lines[b]:match("^[ \t]*(%u+):")
  if kw == "SCHEDULED" or kw == "DEADLINE" or kw == "CLOSED" then
    b = b + 1
  end
  if lines[b] and lines[b]:match("^[ \t]*:[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Ii][Ee][Ss]:[ \t]*$") then
    local k = b + 1
    while k < e and not lines[k]:match("^[ \t]*:[Ee][Nn][Dd]:[ \t]*$") do
      local key, value = lines[k]:match("^[ \t]*:(%S+):[ \t]*(.-)[ \t]*$")
      if key then
        props[key:upper()] = value
      end
      k = k + 1
    end
    b = k + 1
  end
  return {
    lines = vim.list_slice(lines, b, e - 1),
    props = props,
    title = parts.title,
    line = s,
    first = b,
    last = e - 1,
  }
end

--- `lines` without the ones hidden in a buffer's current window (closed
--- folds), for visible-only export. `lines[1]` is buffer line `first`
--- (default 1), so a subtree slice is checked against its own lines.
function M.visible_lines(bufnr, lines, first)
  local off = (first or 1) - 1
  local win
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      win = w
      break
    end
  end
  if not win then
    return lines
  end
  local out = {}
  vim.api.nvim_win_call(win, function()
    local i = 1
    while i <= #lines do
      local fc = vim.fn.foldclosed(i + off)
      if fc == -1 then
        out[#out + 1] = lines[i]
        i = i + 1
      else
        -- a folded headline stays visible, its contents are hidden; a fold
        -- opened above the slice (folded subtree root) hides everything
        if fc == i + off and lines[i]:match("^%*+ ") then
          out[#out + 1] = lines[i]
        end
        i = vim.fn.foldclosedend(i + off) - off + 1
      end
    end
  end)
  return out
end

local export_as

--- Export Org lines to a string with `backend`.
---@param backend string|table
---@param lines string[]
---@param opts? table { filename, bufnr, subtree_line, body_only, visible_only, ext, hooks, no_babel, no_babel_eval }
---@return string output, table info
function M.export_as(backend, lines, opts)
  opts = opts or {}
  -- #+BIND: sets the options for this export (org-export-get-environment)
  local restore
  if cfg().allow_bind_keywords then
    local dir = opts.filename and vim.fn.fnamemodify(opts.filename, ":p:h") or vim.fn.getcwd()
    restore = require("org.export.bind").install(M.collect_keywords(lines, dir, nil, nil, opts.filename))
  end
  if not restore then
    return export_as(backend, lines, opts)
  end
  local ok, out, info = pcall(export_as, backend, lines, opts)
  restore()
  if not ok then
    error(out, 0)
  end
  return out, info
end

function export_as(backend, lines, opts)
  backend = M.get_backend(backend)
  if not backend then
    error("Unknown export back-end", 0)
  end
  local c = cfg()
  local parser_mod = require("org.parser")
  local filename = opts.filename
  local dir = filename and vim.fn.fnamemodify(filename, ":p:h") or vim.fn.getcwd()
  local file0 = parser_mod.parse(lines, filename)
  local todo = file0.settings.todo
  M.display_custom_times = custom_times_p(opts.bufnr, file0)
  local hooks = c.hooks or {}
  -- before-processing hook (org-export-before-processing-functions)
  for _, f in ipairs(M.as_list(hooks.before_processing)) do
    local r = f(backend.name, lines)
    if type(r) == "table" then
      lines = r
    end
  end
  -- keywords are read from the whole buffer
  local keywords = M.collect_keywords(lines, dir, nil, nil, filename)
  local subtree
  if opts.subtree_line then
    subtree = subtree_region(lines, opts.subtree_line, todo)
  end
  local work = subtree and subtree.lines or lines
  if opts.visible_only and opts.bufnr then
    -- org-export-as parses the narrowed subtree with visible-only too
    work = M.visible_lines(opts.bufnr, work, subtree and subtree.first or 1)
  end
  local expand_env = true
  -- extensions' preprocessors (e.g. #+transclude:), before #+INCLUDE
  work = require("org.export.hooks").preprocess(work, {
    dir = dir,
    filename = filename,
    bufnr = opts.bufnr,
    backend = backend.name,
  })
  local has_include = false
  for _, l in ipairs(work) do
    if l:match("^[ \t]*#%+[Ii][Nn][Cc][Ll][Uu][Dd][Ee]:") then
      has_include = true
      break
    end
  end
  work = M.expand_includes(work, dir, { includer = filename, expand_env = expand_env, todo = todo })
  if has_include then
    -- options and macros are read after #+INCLUDE expansion
    -- (org-export--annotate-info), so included files can define them
    local full = work
    if subtree then
      full = vim.list_slice(lines, 1, subtree.first - 1)
      vim.list_extend(full, work)
      vim.list_extend(full, lines, subtree.last + 1)
    end
    keywords = M.collect_keywords(full, dir, nil, nil, filename)
  end
  work = M.delete_comment_trees(work, todo)
  -- Babel
  local babel_cfg = require("org.config").opts.babel or {}
  if babel_cfg.evaluate_on_export and not opts.no_babel then
    -- opts.no_babel_eval: keep the results already in the buffer (the
    -- live preview), but still apply :exports
    local ok, res = false, nil
    if not opts.no_babel_eval then
      ok, res = pcall(function()
        return require("org.babel").export_evaluate(opts.bufnr, work)
      end)
    end
    if ok and type(res) == "table" then
      work = res
    end
    work = M.babel_process(work, { filename = filename })
  end
  -- before-parsing hook
  for _, f in ipairs(M.as_list(hooks.before_parsing)) do
    local r = f(backend.name, work)
    if type(r) == "table" then
      work = r
    end
  end
  -- radio targets
  local radio = {}
  for _, l in ipairs(work) do
    for r in l:gmatch("<<<([^<>\n]-)>>>") do
      radio[#radio + 1] = r
    end
  end
  local link_types = vim.deepcopy(element.DEFAULT_LINK_TYPES)
  local extra_types = {}
  for t in pairs((require("org.config").opts.links or {}).types or {}) do
    extra_types[t] = true
  end
  local abbrevs = vim.tbl_extend(
    "force",
    (require("org.config").opts.links or {}).abbreviations or {},
    file0.settings.link_abbrevs or {}
  )
  local ctx = {
    keywords = keywords,
    filename = filename,
    babel = babel_cfg.evaluate_on_export and not opts.no_babel and true or false,
  }
  local expander = M.macro_expander(ctx)
  local popts = {
    todo = todo,
    link_types = link_types,
    extra_link_types = extra_types,
    abbrevs = abbrevs,
    radio = radio,
    macro = expander,
    no_final_newline = opts.no_final_newline,
    footnote_section = c.footnote_section or require("org.config").opts.footnote_section,
    inlinetask_min_level = c.inlinetask_min_level or 15,
    alpha = require("org.lists").opt("allow_alphabetical"),
    term = ({ ["."] = "%.", [")"] = "%)" })[require("org.lists").opt("ordered_item_terminator")],
  }
  local parser = element.new(popts)
  -- {{{property(NAME[,search])}}}: the headline being parsed, or a searched one
  local pfile
  ctx.property_lookup = function(name, loc, p)
    if loc and M.nw(loc) then
      pfile = pfile or parser_mod.parse(work, filename)
      loc = trim(loc)
      local hl
      if loc:match("^#") then
        hl = pfile:find_by_custom_id(loc:sub(2))
      elseif loc:match("^id:") then
        hl = pfile:find_by_id(loc:sub(4))
      else
        local t = trim((loc:gsub("^%*", "")))
        hl = pfile:find_headline(function(h)
          return h:plain_title() == t
        end)
      end
      if not hl then
        error("Macro property failed: cannot find location " .. loc, 0)
      end
      if name == "ITEM" then
        return hl:plain_title()
      end
      return hl:get_property(name, false)
    end
    local h = p and p.current_headline
    if h then
      if name == "ITEM" then
        return h.raw_value
      elseif name == "TODO" then
        return h.todo_keyword
      elseif name == "PRIORITY" then
        return h.priority
      end
      return h.props and h.props[name]
    end
    -- before the first child of an exported subtree, point is in the
    -- subtree's own entry (org-entry-get nil NAME 'selective)
    local root = subtree and file0:headline_on(subtree.line)
    if root then
      return root:get_property(name)
    end
    return file0.settings.properties[name]
  end
  local function parse_secondary(s)
    return parser:parse_objects(s, element.RESTRICTIONS.keyword)
  end
  local info = M.environment({
    keywords = keywords,
    backend = backend,
    subtree_props = subtree and subtree.props or nil,
    subtree_title = subtree and subtree.title or nil,
    ext = opts.ext,
    parse_secondary = parse_secondary,
  })
  info.back_end = backend
  info.translate = M.all_transcoders(backend)
  info.exported_data = {}
  info.export_options = { subtree = subtree ~= nil, body_only = opts.body_only, visible_only = opts.visible_only }
  info.input_file = filename
  info.input_buffer = opts.bufnr
  info.keywords = keywords
  info.parser = parser
  info.internal_references = { n = 0, used = {}, by_datum = {} }
  info.table_header_cache = {}
  info.table_row_group_cache = {}
  info.table_cell_width_cache = {}
  info.table_cell_alignment_cache = {}
  info.table_row_index_cache = {}
  info.smart_quote_cache = {}
  info.subtree_props = subtree and subtree.props or nil
  if subtree then
    -- org-export--missing-definitions: a definition outside the exported
    -- subtree is read from the widened buffer (org-footnote-get-definition)
    info.widened_footnote = function(label)
      local head = "[fn:" .. label .. "]"
      for i, l in ipairs(lines) do
        if l:sub(1, #head) == head then
          local j = i + 1
          while j <= #lines and not (lines[j]:match("^%*+ ") or lines[j]:match("^%[fn:[%w_-]+%]")) do
            j = j + 1
          end
          return element.map(parser:parse(vim.list_slice(lines, i, j - 1)), "footnote-definition", function(d)
            return d.label == label and d or nil
          end, { first_match = true })
        end
      end
    end
  end
  info.todo_done = function(k)
    return todo:is_done(k)
  end
  info.options_filters = {}
  -- filters: back-end first, then user filters (config export.filters)
  local filters = M.all_filters(backend)
  for k, v in pairs(c.filters or {}) do
    filters[k] = filters[k] or {}
    vim.list_extend(filters[k], M.as_list(v))
  end
  -- also accept keys with underscores (plain_text) for hyphenated types
  local norm = {}
  for k, v in pairs(filters) do
    norm[k:gsub("_", "-")] = v
  end
  info.filters = norm
  -- citations: bibliography and processor
  local cite_ok, cite = pcall(require, "org.export.cite")
  if not cite_ok then
    cite = nil
  end
  if info.with_cite_processors and cite then
    cite.store(info)
  end
  -- options filters
  for _, f in ipairs(info.filters.options or {}) do
    local r = f(info, backend.name)
    if type(r) == "table" then
      info = r
    end
  end
  -- parse
  local tree = parser:parse(work)
  -- ALT_TITLE
  element.map(tree, { headline = true, inlinetask = true }, function(h)
    if h.props and h.props.ALT_TITLE then
      h.alt_title = parser:parse_objects(h.props.ALT_TITLE, element.RESTRICTIONS.headline, h)
    end
  end)
  M.prune_tree(tree, info)
  M.remove_uninterpreted(tree, info)
  for _, key in ipairs({ "title", "date", "author", "subtitle" }) do
    if type(info[key]) == "table" and info[key].type == nil then
      M.remove_uninterpreted(info[key], info)
    end
  end
  if info.expand_links then
    element.map(tree, "link", function(l)
      if l.link_type == "file" then
        l.path = M.expand_env(l.path)
      end
    end, { with_affiliated = true })
  end
  tree = apply_filters(info.filters["parse-tree"], tree, info)
  M.collect_tree_properties(tree, info)
  if info.with_cite_processors and cite then
    cite.process(info)
  end
  -- transcode (the tree doesn't change from here: footnote numbers can be
  -- computed once)
  info.footnote_index_cache = nil
  info.footnote_index_ready = true
  local body = M.normalize_string(M.data(tree, info) or "") or ""
  local inner = info.translate.inner_template
  local full = apply_filters(info.filters.body, inner and inner(body, info) or body, info)
  local template = info.translate.template
  local output = (template and not opts.body_only) and template(full, info) or full
  if info.with_cite_processors and cite then
    output = cite.finalize(output, info)
  end
  output = apply_filters(info.filters["final-output"], output, info)
  return output, info
end

function M.as_list(v)
  if v == nil then
    return {}
  end
  if type(v) == "function" then
    return { v }
  end
  return v
end

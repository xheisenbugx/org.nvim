---@mod org.extensions.ql org-ql: query language, search views and dynamic blocks
---
--- Enable with `extensions = { ql = {} }` (see `:h org-extensions-ql`).
---
--- ```lua
--- local ql = require("org.extensions.ql")
--- ql.select("agenda", '(and (todo "NEXT") (tags "work"))', { sort = "priority" })
--- ql.search("todo:NEXT tags:work", { files = "buffer" })
--- ```

local query = require("org.extensions.ql.query")
local utils = require("org.utils")

local M = {}

M.query = query

M.defaults = {
  --- Files a search looks in when none are given: "agenda" (the agenda
  --- files), "buffer" (the current buffer), "all" (every loaded org
  --- buffer) or a list of files and globs.
  files = "agenda",
  --- Predicate of bare words in plain queries (org-ql-default-predicate).
  default_predicate = "rifle",
  --- Sort of searches without `:sort` (nil = file order).
  sort = nil,
  --- Named views for `:Org ql_view` (org-ql-views): name -> { query,
  --- files?, sort?, title?, super_groups? }. Views saved from a search
  --- buffer (`save_view_key`) are added from `views_file`.
  views = {},
  --- Where saved views are kept (JSON); false to not save views.
  views_file = vim.fn.stdpath("data") .. "/org/ql-views.json",
  --- Key in search buffers that saves the search as a view (org-ql's
  --- C-x C-s in its view buffers); false for none.
  save_view_key = "<C-x><C-s>",
  --- Also search COMMENT and ARCHIVE subtrees, as org-ql does. Off, they
  --- are skipped like in the agenda.
  include_hidden = false,
  --- A repeating timestamp matches a date range when one of its
  --- occurrences falls in it (org-ql only looks at the timestamp itself).
  expand_repeaters = true,
  --- Remember results per headline until its file changes.
  cache = true,
}

local function opts()
  return require("org.extensions").opts("ql") or M.defaults
end

local function compile(q)
  return opts().cache ~= false and query.compile_cached(q) or query.compile(q)
end

---------------------------------------------------------------------------
-- Files
---------------------------------------------------------------------------

local function loaded_org_files()
  local files = require("org.files")
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" then
      out[#out + 1] = files.get_buffer(b)
    end
  end
  return out
end

--- Resolve a files argument to org.File objects: "agenda", "buffer",
--- "all", a buffer number, a path or glob, an org.File, or a list of those.
---@param spec any
---@return org.File[]
function M.files(spec)
  local files = require("org.files")
  spec = spec == nil and opts().files or spec
  if spec == "agenda" then
    return files.agenda_files()
  elseif spec == "buffer" or spec == 0 then
    return { files.get_buffer(vim.api.nvim_get_current_buf()) }
  elseif spec == "all" then
    return loaded_org_files()
  elseif type(spec) == "number" then
    return { files.get_buffer(spec) }
  elseif type(spec) == "table" and spec.headlines then
    return { spec }
  end
  local out, seen = {}, {}
  local function add(f)
    if f and not seen[f] then
      seen[f] = true
      out[#out + 1] = f
    end
  end
  for _, s in ipairs(type(spec) == "table" and spec or { spec }) do
    if type(s) == "string" and s ~= "agenda" and s ~= "buffer" and s ~= "all" then
      for _, p in ipairs(utils.glob_org_files({ s })) do
        add(files.get(p))
      end
    else
      for _, f in ipairs(M.files(s)) do
        add(f)
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Selecting
---------------------------------------------------------------------------

--- Headlines of `files` matching `q` (org-ql-select). COMMENT and ARCHIVE
--- subtrees are skipped, as in the agenda, unless `include_hidden` is set.
---@param files any see `M.files`
---@param q string|table query
---@param o? { sort?: any, action?: fun(hl: org.Headline): any, include_hidden?: boolean }
---@return any[] headlines, or the results of `action`
function M.select(files, q, o)
  o = o or {}
  local pred = compile(q)
  local out = {}
  local all = o.include_hidden
  if all == nil then
    all = opts().include_hidden
  end
  require("org.agenda.items").each_headline(M.files(files), { all = all }, function(hl)
    if pred(hl) then
      out[#out + 1] = hl
    end
  end)
  query.sort(out, o.sort == nil and opts().sort or o.sort)
  if o.action then
    return vim.tbl_map(o.action, out)
  end
  return out
end

local function query_string(q)
  if type(q) == "string" then
    return q
  end
  return vim.inspect(q, { newline = " ", indent = "" })
end

---------------------------------------------------------------------------
-- Agenda views
---------------------------------------------------------------------------

--- The `ql` agenda block type: `{ type = "ql", query = ..., sort = ... }`.
local function source(block, ctx, lopts)
  if not require("org.extensions").enabled("ql") then
    return { error = "The ql extension is not enabled (:h org-extensions-ql)" }
  end
  local q = block.query or block.match
  if q == nil or q == "" then
    return { error = "org-ql block without a query" }
  end
  local pred, err = query.try_compile(q, opts().cache ~= false)
  if not pred then
    return { error = "Invalid query: " .. tostring(err) }
  end
  lopts.all = block.include_hidden
  if lopts.all == nil then
    lopts.all = opts().include_hidden
  end
  local items = require("org.agenda.items").tags(ctx.files, pred, false, lopts)
  local sort = block.sort
  if sort == nil then
    sort = opts().sort
  end
  query.sort(items, sort, function(it)
    return it.headline
  end)
  local header = { { { "Query: ", "OrgAgendaHeader" }, { query_string(q), "OrgAgendaFilter" } } }
  if block.title then
    header = { { { block.title, "OrgAgendaHeader" } }, header[1] }
  end
  return { items = items, kind = "tags", header = header, sorted = sort ~= nil }
end
M.source = source

--- Open search results in an agenda buffer (org-ql-search).
---@param q string|table query
---@param o? { files?: any, sort?: any, title?: string, super_groups?: table }
function M.search(q, o)
  o = o or {}
  local pred, err = query.try_compile(q)
  if not pred then
    utils.error("Invalid query: " .. tostring(err))
    return
  end
  local spec = o.files == nil and opts().files or o.files
  local block = {
    type = "ql",
    query = q,
    sort = o.sort,
    title = o.title,
    super_groups = o.super_groups,
    include_hidden = o.include_hidden,
    key = "ql:" .. query_string(q),
    -- what `save_view` stores
    files_spec = spec,
  }
  local open_opts = {}
  if spec == "buffer" or spec == 0 or type(spec) == "number" then
    local buf = (spec == "buffer" or spec == 0) and vim.api.nvim_get_current_buf() or spec
    if not utils.is_org(buf) then
      utils.error("Not an org buffer")
      return
    end
    open_opts.restrict = { bufnr = buf }
    -- the buffer searched, for `save_view` (the current one changes later)
    block.files_spec = buf
  elseif spec ~= "agenda" then
    local list = {}
    for _, f in ipairs(M.files(spec)) do
      if f.filename then
        list[#list + 1] = f.filename
      end
    end
    block.files = list
  end
  require("org.agenda").open(block, open_opts)
end

local function ask_query(prompt)
  local q = utils.input({ prompt = prompt or "Query: " })
  if q == nil or vim.trim(q) == "" then
    return nil
  end
  return q
end

--- `:Org ql_search [query]` in the default files (prompts without a query).
function M.search_command(args)
  local q = args and vim.trim(args) ~= "" and args or ask_query()
  if q then
    M.search(q)
  end
end

--- `:Org ql_search_buffer [query]` in the current buffer.
function M.search_buffer_command(args)
  local q = args and vim.trim(args) ~= "" and args or ask_query("Query (buffer): ")
  if q then
    M.search(q, { files = "buffer" })
  end
end

---------------------------------------------------------------------------
-- Saved views
---------------------------------------------------------------------------

local function views_file()
  local f = opts().views_file
  return type(f) == "string" and f ~= "" and vim.fs.normalize(f) or nil
end

--- Views saved from search buffers (name -> view).
---@return table<string, table>
function M.saved_views()
  local f = views_file()
  if not f or vim.fn.filereadable(f) == 0 then
    return {}
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(f), "\n"))
  if not ok or type(data) ~= "table" then
    utils.warn("org-ql: cannot read " .. f)
    return {}
  end
  return data
end

--- The configured views over the saved ones.
---@return table<string, table>
function M.views()
  return vim.tbl_extend("force", M.saved_views(), opts().views or {})
end

--- Save a view under `name` in `views_file` (org-ql-view-save).
---@param name string
---@param v table { query, files?, sort?, title? }
function M.save_view(name, v)
  local f = views_file()
  if not f then
    utils.error("org-ql: views_file is off")
    return false
  end
  local ok, encoded = pcall(vim.json.encode, v)
  if not ok then
    utils.error("org-ql: this view can't be saved (a Lua function in it?)")
    return false
  end
  local all = M.saved_views()
  all[name] = vim.json.decode(encoded)
  vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(all) }, f)
  utils.notify("Saved org-ql view " .. name)
  return true
end

-- The ql block of the agenda view shown in the current buffer.
local function current_block()
  local st = require("org.agenda.view").state
  local v = st and st.view
  if not v then
    return nil
  end
  local blocks = v.blocks or { v }
  for _, b in ipairs(blocks) do
    if type(b) == "table" and (b.type == "ql" or b.type == "org-ql" or b.type == "org_ql") then
      return b
    end
  end
end

--- Save the search of the current agenda buffer as a named view.
---@param name? string prompted for when not given
function M.save_view_command(name)
  local b = current_block()
  if not b then
    utils.warn("Not an org-ql search buffer")
    return
  end
  if type(b.query) ~= "string" and type(b.query) ~= "table" then
    return
  end
  if not name or vim.trim(name) == "" then
    name = utils.input({ prompt = "Save view as: ", default = b.title })
  end
  if not name or vim.trim(name) == "" then
    return
  end
  local files = b.files_spec
  if type(files) == "number" then
    -- a buffer search is saved with its file
    local fname = vim.api.nvim_buf_is_valid(files) and vim.api.nvim_buf_get_name(files) or ""
    files = fname ~= "" and { fname } or nil
  end
  M.save_view(vim.trim(name), {
    query = b.query,
    sort = b.sort,
    title = b.title or vim.trim(name),
    files = files,
  })
end

--- Open a named view of `views` (org-ql-view); prompts without a name.
---@param name? string
function M.view(name)
  local views = M.views()
  if not name or vim.trim(name) == "" then
    local names = vim.tbl_keys(views)
    table.sort(names)
    if #names == 0 then
      utils.warn("No org-ql views defined (extensions.ql.views)")
      return
    end
    name = utils.select(names, { prompt = "View" })
    if not name then
      return
    end
  end
  name = vim.trim(name)
  local v = views[name]
  if not v then
    utils.error("No org-ql view: " .. name)
    return
  end
  M.search(v.query, {
    files = v.files,
    sort = v.sort,
    title = v.title or name,
    super_groups = v.super_groups,
    include_hidden = v.include_hidden,
  })
end

--- Entries with timestamps of `kind` in the last `days` days, newest
--- first (org-ql-view-recent-items). `kind` is ts, ts-active,
--- ts-inactive, clocked, closed, deadline, planning or scheduled.
---@param days? integer default 7
---@param kind? string default "ts"
function M.recent_items(days, kind)
  days = tonumber(days) or 7
  kind = kind or "ts"
  if not query.is_predicate(kind) then
    utils.error("org-ql: unknown timestamp type " .. kind)
    return
  end
  M.search(string.format("(%s :from %d :to today)", kind, -days), {
    sort = { "date", "reverse" },
    title = string.format("Recent items (%s, %d days)", kind, days),
  })
end

--- `:Org ql_recent_items [days] [type]`.
function M.recent_items_command(args)
  local days, kind = (args or ""):match("^%s*(%S*)%s*(%S*)")
  M.recent_items(tonumber(days), kind ~= "" and kind or nil)
end

---------------------------------------------------------------------------
-- Find, refile, sparse tree
---------------------------------------------------------------------------

local function label(hl, with_file)
  local olp = hl:outline_path()
  olp[#olp + 1] = hl:plain_title()
  local s = table.concat(olp, "/")
  if hl.todo then
    s = hl.todo .. " " .. s
  end
  if with_file and hl.file.filename then
    s = s .. " (" .. vim.fn.fnamemodify(hl.file.filename, ":t") .. ")"
  end
  return s
end

-- Pick one of the headlines matching `q` in `files`.
local function pick(files, q, prompt, exclude)
  local ok, hls = pcall(M.select, files, q)
  if not ok then
    utils.error("Invalid query: " .. tostring(hls))
    return nil
  end
  if exclude then
    hls = vim.tbl_filter(function(hl)
      return not exclude(hl)
    end, hls)
  end
  if #hls == 0 then
    utils.warn("No entries match " .. query_string(q))
    return nil
  end
  local many = #M.files(files) > 1
  return utils.select(hls, {
    prompt = prompt,
    format_item = function(hl)
      return label(hl, many)
    end,
  })
end

local function jump(hl)
  vim.cmd("normal! m'")
  if hl.file.bufnr and vim.api.nvim_buf_is_valid(hl.file.bufnr) then
    vim.api.nvim_set_current_buf(hl.file.bufnr)
    vim.api.nvim_win_set_cursor(0, { hl.line, 0 })
  else
    utils.open_file(hl.file.filename, hl.line)
  end
  pcall(require("org.fold").show_context, hl.line, "ancestors")
end

--- Jump to an entry matching a query (org-ql-find). Searches the current
--- buffer, or the agenda files outside an org buffer or with `files`.
---@param q? string|table prompted for when not given
---@param files? any see `M.files`
function M.find(q, files)
  if files == nil then
    files = utils.is_org(0) and "buffer" or "agenda"
  end
  q = q or ask_query("Find: ")
  if not q then
    return
  end
  local hl = pick(files, q, "Find")
  if hl then
    jump(hl)
  end
end

--- `:Org ql_find [query]` in the buffer; `:Org ql_find_agenda [query]`.
function M.find_command(args)
  M.find(args and vim.trim(args) ~= "" and args or nil)
end

function M.find_agenda_command(args)
  M.find(args and vim.trim(args) ~= "" and args or nil, "agenda")
end

--- Refile the subtree at the cursor under an entry matching a query in the
--- agenda files and the buffer (org-ql-refile).
---@param q? string|table prompted for when not given
function M.refile(q)
  if not utils.is_org(0) then
    utils.error("Not an org buffer")
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local src = require("org.files").get_buffer(buf):headline_at(vim.api.nvim_win_get_cursor(0)[1])
  if not src then
    utils.warn("Not in an entry")
    return
  end
  q = q or ask_query("Refile to: ")
  if not q then
    return
  end
  local fname = src.file.filename
  local hl = pick({ "agenda", buf }, q, "Refile to", function(h)
    -- not into the subtree being moved
    return (h.file == src.file or (fname and h.file.filename == fname))
      and h.line >= src.line
      and h.line <= src.end_line
  end)
  if not hl then
    return
  end
  local olp = hl:outline_path()
  olp[#olp + 1] = hl:plain_title()
  require("org.refile").refile(nil, {
    count = 0,
    dest = { filename = hl.file.filename, lnum = hl.line, olp = olp, level = hl.level, label = label(hl) },
  })
end

function M.refile_command(args)
  M.refile(args and vim.trim(args) ~= "" and args or nil)
end

--- Show the entries of the buffer matching a query as a sparse tree
--- (org-ql-sparse-tree). Returns the number of matches.
---@param q? string|table prompted for when not given
---@return integer|nil
function M.sparse_tree(q)
  if not utils.is_org(0) then
    utils.error("Not an org buffer")
    return
  end
  q = q or ask_query("Sparse tree: ")
  if not q then
    return
  end
  local pred, err = query.try_compile(q, opts().cache ~= false)
  if not pred then
    utils.error("Invalid query: " .. tostring(err))
    return
  end
  return #require("org.agenda.sparse").headlines(pred, query_string(q))
end

function M.sparse_tree_command(args)
  M.sparse_tree(args and vim.trim(args) ~= "" and args or nil)
end

---------------------------------------------------------------------------
-- Dynamic block
---------------------------------------------------------------------------

local COLUMN_HEADERS = {
  heading = "Heading",
  todo = "Todo",
  priority = "P",
  deadline = "Deadline",
  scheduled = "Scheduled",
  closed = "Closed",
}

-- Columns of `:columns`: "(heading todo (property \"K\") (priority \"P\"))".
local function parse_columns(v)
  if v == nil or v == true then
    return { { kind = "heading" }, { kind = "todo" } }
  end
  local list = type(v) == "table" and v or query.read_sexp(tostring(v))
  if type(list) ~= "table" then
    list = { list }
  end
  local cols = {}
  for _, c in ipairs(list) do
    if type(c) == "string" then
      cols[#cols + 1] = { kind = c:lower() }
    elseif type(c) == "table" then
      if type(c[1]) == "table" then
        -- ((property "name") "Header")
        cols[#cols + 1] = { kind = tostring(c[1][1]):lower(), arg = c[1][2], header = c[2] }
      elseif tostring(c[1]):lower() == "property" then
        cols[#cols + 1] = { kind = "property", arg = c[2], header = c[3] }
      else
        cols[#cols + 1] = { kind = tostring(c[1]):lower(), header = c[2] }
      end
    end
  end
  return cols
end

local function cell(hl, col, ts_format, bufname)
  local k = col.kind
  if k == "heading" then
    local title = hl:plain_title()
    local search = "*" .. title
    local target = search
    if hl.file.filename and hl.file.filename ~= bufname then
      target = "file:" .. hl.file.filename .. "::" .. search
    end
    return "[[" .. target:gsub("[%[%]]", "\\%0") .. "][" .. title .. "]]"
  elseif k == "todo" then
    return hl.todo or ""
  elseif k == "priority" then
    return hl.priority or ""
  elseif k == "deadline" or k == "scheduled" or k == "closed" then
    local ts = hl.planning and hl.planning[k]
    return ts and ts:strftime(ts_format) or ""
  elseif k == "property" then
    return col.arg and hl:get_property(tostring(col.arg)) or ""
  end
  error("unknown org-ql column: " .. tostring(k), 0)
end

--- Writer of `#+BEGIN: org-ql :query ... :columns ... :sort ... :take N`
--- blocks: a table of the matching entries of the buffer.
function M.dblock(params, ctx)
  if not require("org.extensions").enabled("ql") then
    error("the ql extension is not enabled", 0)
  end
  local q = params.query
  if q == nil or q == true or q == "" then
    error("org-ql block needs a :query", 0)
  end
  local sort = params.sort
  if type(sort) == "string" and sort:match("^%(") then
    sort = query.read_sexp(sort)
  end
  local files = params.files and M.files(params.files) or { require("org.files").get_buffer(ctx.bufnr) }
  local hls = M.select(files, q, { sort = sort or false })
  local take = tonumber(params.take)
  if take and take > 0 then
    hls = vim.list_slice(hls, 1, take)
  elseif take and take < 0 then
    hls = vim.list_slice(hls, math.max(#hls + take + 1, 1), #hls)
  end
  local cols = parse_columns(params.columns)
  local ts_format = type(params["ts-format"]) == "string" and params["ts-format"] or "%Y-%m-%d"
  local bufname = vim.api.nvim_buf_get_name(ctx.bufnr)
  local lines = {}
  local head = {}
  for _, c in ipairs(cols) do
    local h = c.header or (c.kind == "property" and tostring(c.arg or "")) or COLUMN_HEADERS[c.kind] or c.kind
    head[#head + 1] = tostring(h)
  end
  lines[#lines + 1] = "| " .. table.concat(head, " | ") .. " |"
  lines[#lines + 1] = "|-"
  for _, hl in ipairs(hls) do
    local cells = {}
    for _, c in ipairs(cols) do
      cells[#cells + 1] = (cell(hl, c, ts_format, bufname):gsub("|", "\\vert{}"))
    end
    lines[#lines + 1] = "| " .. table.concat(cells, " | ") .. " |"
  end
  local tbl = require("org.table")
  return tbl.render(tbl.parse(lines))
end

---------------------------------------------------------------------------
-- Extension
---------------------------------------------------------------------------

M.actions = {
  ql_search = { "org.extensions.ql", "search_command", desc = "org-ql search in the agenda files" },
  ql_search_buffer = { "org.extensions.ql", "search_buffer_command", desc = "org-ql search in the buffer" },
  ql_view = { "org.extensions.ql", "view", desc = "Open an org-ql view" },
  ql_find = { "org.extensions.ql", "find_command", desc = "org-ql: jump to a matching entry" },
  ql_find_agenda = { "org.extensions.ql", "find_agenda_command", desc = "org-ql: jump to a matching agenda entry" },
  ql_refile = { "org.extensions.ql", "refile_command", desc = "org-ql: refile under a matching entry" },
  ql_sparse_tree = { "org.extensions.ql", "sparse_tree_command", desc = "org-ql sparse tree" },
  ql_recent_items = { "org.extensions.ql", "recent_items_command", desc = "org-ql: recently dated entries" },
}

M.commands = {
  ql_search = { "org.extensions.ql", "search_command", desc = "org-ql search: :Org ql_search <query>" },
  ql_search_buffer = {
    "org.extensions.ql",
    "search_buffer_command",
    desc = "org-ql search in the buffer: :Org ql_search_buffer <query>",
  },
  ql_view = { "org.extensions.ql", "view", desc = "Open an org-ql view: :Org ql_view [name]" },
  ql_save_view = {
    "org.extensions.ql",
    "save_view_command",
    desc = "Save the org-ql search of the agenda buffer: :Org ql_save_view [name]",
  },
  ql_find = { "org.extensions.ql", "find_command", desc = "Jump to an entry: :Org ql_find <query>" },
  ql_find_agenda = {
    "org.extensions.ql",
    "find_agenda_command",
    desc = "Jump to an agenda entry: :Org ql_find_agenda <query>",
  },
  ql_refile = { "org.extensions.ql", "refile_command", desc = "Refile under an entry: :Org ql_refile <query>" },
  ql_sparse_tree = { "org.extensions.ql", "sparse_tree_command", desc = "Sparse tree: :Org ql_sparse_tree <query>" },
  ql_recent_items = {
    "org.extensions.ql",
    "recent_items_command",
    desc = "Recently dated entries: :Org ql_recent_items [days] [ts|clocked|closed|...]",
  },
}

-- buffer -> { lhs, previous mapping or {} } of the save key, restored by
-- teardown
local buf_keys = {}

-- In search buffers, `save_view_key` saves the search as a view; in other
-- agenda buffers the key keeps its meaning.
local function on_refresh(buf)
  local key = require("org.extensions").enabled("ql") and opts().save_view_key
  if not key or vim.b[buf].org_ql_keys or not current_block() then
    return
  end
  vim.b[buf].org_ql_keys = true
  local prev = vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg(key, "n", false, true)
  end)
  buf_keys[buf] = { key, prev }
  vim.keymap.set("n", key, function()
    if current_block() then
      utils.run(M.save_view_command)
    elseif type(prev) == "table" and prev.callback then
      prev.callback()
    end
  end, { buffer = buf, desc = "org-ql: save search as a view" })
end

function M.setup()
  local lazy = require("org.lazy")
  -- the agenda modules load on the first agenda, not at startup
  lazy.on_load("org.agenda.render", "ql", function(render)
    render.sources.ql = source
    render.sources["org-ql"] = source
    render.sources.org_ql = source
  end)
  lazy.on_load("org.dblock", "ql", function(dblock)
    dblock.register("org-ql", M.dblock)
  end)
  lazy.on_load("org.agenda.view", "ql", function(view)
    view.refresh_hooks.ql = on_refresh
  end)
  query.clear_cache()
end

--- Undo `setup`: agenda buffers get their save key back. The block type
--- and the dynamic block stay registered, to say the extension is off.
function M.teardown()
  local lazy = require("org.lazy")
  lazy.if_loaded("org.agenda.view", "ql", function(view)
    view.refresh_hooks.ql = nil
  end)
  -- the agenda source and the org-ql block stay registered (pending hooks
  -- included): they report the extension as off
  for buf, k in pairs(buf_keys) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.b[buf].org_ql_keys = nil
      vim.api.nvim_buf_call(buf, function()
        pcall(vim.keymap.del, "n", k[1], { buffer = buf })
        if k[2].lhs then
          pcall(vim.fn.mapset, "n", false, k[2])
        end
      end)
    end
  end
  buf_keys = {}
end

function M.health(h, o)
  local f = views_file()
  if f then
    h.info("org-ql saved views: " .. f)
  end
  for name, v in pairs(M.views()) do
    local ok, err = query.try_compile(v.query or "")
    if ok then
      h.ok("org-ql view " .. name)
    else
      h.error("org-ql view " .. name .. ": " .. tostring(err))
    end
  end
  local ok, err = query.try_compile("(todo)")
  if not ok then
    h.error("org-ql: " .. tostring(err))
  end
end

return M

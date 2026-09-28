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
  --- files?, sort?, title?, super_groups? }.
  views = {},
}

local function opts()
  return require("org.extensions").opts("ql") or M.defaults
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
--- subtrees are skipped, as in the agenda.
---@param files any see `M.files`
---@param q string|table query
---@param o? { sort?: any, action?: fun(hl: org.Headline): any }
---@return any[] headlines, or the results of `action`
function M.select(files, q, o)
  o = o or {}
  local pred = query.compile(q)
  local out = {}
  require("org.agenda.items").each_headline(M.files(files), {}, function(hl)
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
  local pred, err = query.try_compile(q)
  if not pred then
    return { error = "Invalid query: " .. tostring(err) }
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
    key = "ql:" .. query_string(q),
  }
  local open_opts = {}
  if spec == "buffer" or spec == 0 or type(spec) == "number" then
    local buf = (spec == "buffer" or spec == 0) and vim.api.nvim_get_current_buf() or spec
    if not utils.is_org(buf) then
      utils.error("Not an org buffer")
      return
    end
    open_opts.restrict = { bufnr = buf }
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

--- Open a named view of `views` (org-ql-view); prompts without a name.
---@param name? string
function M.view(name)
  local views = opts().views or {}
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
  M.search(v.query, { files = v.files, sort = v.sort, title = v.title or name, super_groups = v.super_groups })
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
}

M.commands = {
  ql_search = { "org.extensions.ql", "search_command", desc = "org-ql search: :Org ql_search <query>" },
  ql_search_buffer = {
    "org.extensions.ql",
    "search_buffer_command",
    desc = "org-ql search in the buffer: :Org ql_search_buffer <query>",
  },
  ql_view = { "org.extensions.ql", "view", desc = "Open an org-ql view: :Org ql_view [name]" },
}

function M.setup()
  local render = require("org.agenda.render")
  render.sources.ql = source
  render.sources["org-ql"] = source
  render.sources.org_ql = source
  require("org.dblock").register("org-ql", M.dblock)
end

function M.health(h, o)
  for name, v in pairs(o.views or {}) do
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

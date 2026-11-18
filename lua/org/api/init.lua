---@mod org.api The public Lua API
---
--- A small, stable façade over org.nvim for other plugins and user
--- configs: files, headlines and their changes, agenda queries, capture,
--- links, the clock and events. It follows semantic versioning of its own
--- (`api.version`), separate from the plugin's release: within a major
--- version, functions, fields and event payloads are only added, never
--- removed or changed. Modules outside `org.api` are internal and may
--- change in any release. See |org-api|.
---
--- ```lua
--- local api = require("org.api")
--- for _, h in ipairs(api.headlines({ match = "+work/TODO" })) do
---   print(h.file, h.line, h.title)
--- end
--- ```

-- Not compiled by the JIT, like org.agenda.items: a query makes a handle
-- per headline in short, branchy code (its dates, tags, properties), whose
-- traces mostly abort or fill the machine-code area, which on macOS arm64
-- flushes every trace in Neovim (see "Performance budgets" in
-- CONTRIBUTING.md). Interpreted, its timings stay steady: compiled, it
-- was 10-30% faster in a fresh Neovim, but a view's build sometimes took
-- twice as long after a flush.
if jit then
  jit.off(true, true)
end

local H = require("org.api.headline")
local files = require("org.files")
local utils = require("org.utils")

--- A buffer argument: 0 or nil is the current buffer.
---@param bufnr integer? 0 or nil for the current buffer
---@return integer
local function resolve_buf(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local M = {}

--- Version of the API (`MAJOR.MINOR.PATCH`). A new MINOR adds functions,
--- fields or events; a new MAJOR may break code written for an older one.
M.version = "1.3.0"

--- Does this API provide `version` ("1", "1.0" or "1.0.0")? True when the
--- major versions are equal and this one is not older.
---@param version string
---@return boolean
function M.has(version)
  local function parts(v)
    local a, b, c = tostring(v):match("^(%d+)%.?(%d*)%.?(%d*)$")
    if not a then
      return nil
    end
    return { tonumber(a), tonumber(b) or 0, tonumber(c) or 0 }
  end
  -- M.version is always a valid version
  local want, have = parts(version), assert(parts(M.version))
  if not want or want[1] ~= have[1] then
    return false
  end
  for i = 2, 3 do
    if have[i] ~= want[i] then
      return have[i] > want[i]
    end
  end
  return true
end

M.Headline = H.Headline
M.agenda = require("org.api.agenda")

--- Turn what the API accepts as a date (a string, a table with year,
--- month and day, a Unix time) into an |org.api.Date|.
---@param value any
---@return org.api.Date|nil date, string|nil err
function M.date(value)
  local d, err = H.to_date(value)
  if not d then
    return nil, err
  end
  return H.date(d)
end

--- The day org considers today (org-today): before `extend_today_until`
--- o'clock it is still the day before. Since API 1.3.
---@return org.api.Date
function M.today()
  return H.date(require("org.date").today()) --[[@as org.api.Date]]
end

--- The dates a timestamp falls on from day `from` to day `to` (any dates
--- the API accepts; both included), as the agenda lists it: the timestamp
--- itself when it has no repeater, else every repetition (`+1w`, `.+1d`
--- and `++1m` all repeat from the timestamp). A range counts as its
--- start. nil and an error past
--- 5,000 occurrences. Since API 1.3.
---@param value any
---@param from any
---@param to any
---@return org.api.Date[]|nil dates, string|nil err
function M.occurrences(value, from, to)
  local d, err = H.to_date(value)
  if not d then
    return nil, err
  end
  local f, t
  f, err = H.to_date(from)
  if not f then
    return nil, err
  end
  t, err = H.to_date(to)
  if not t then
    return nil, err
  end
  local occ, more = require("org.date").occurrences(d, f:days(), t:days())
  if more then
    local function ymd(x)
      return string.format("%04d-%02d-%02d", x.year, x.month, x.day)
    end
    return nil, string.format("more than %d occurrences from %s to %s: ask for fewer days", #occ, ymd(f), ymd(t))
  end
  local out = {}
  for i, o in ipairs(occ) do
    out[i] = H.date(o)
  end
  return out
end

--- The last warning or error among collected messages.
local function last_problem(msgs)
  for i = #msgs, 1, -1 do
    if msgs[i].level >= vim.log.levels.WARN then
      return msgs[i].msg
    end
  end
end

--- Call `fn(...)` without prompting (`utils.noninteractive`), then save
--- the buffers it changed as |org-api-saving| says: a buffer is saved when
--- it had no unsaved changes before (`opts.save` true: always, false:
--- never). Returns whether it worked, the collected messages and fn's
--- (first) result, or the error when it failed (also when a save failed).
---@param opts { save?: boolean }
---@param fn function
---@return boolean ok, { msg: string, level: integer }[] msgs, any res
local function change(opts, fn, ...)
  local before = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      before[b] = { tick = vim.api.nvim_buf_get_changedtick(b), modified = vim.bo[b].modified }
    end
  end
  local ok, msgs, res = utils.noninteractive(fn, ...)
  if not ok then
    return false, msgs, res
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) or ""
    local was = before[b]
    if name ~= "" and vim.bo[b].modified and (not was or was.tick ~= vim.api.nvim_buf_get_changedtick(b)) then
      local save = opts.save
      if save == nil then
        save = not (was and was.modified)
      end
      if save then
        local saved, err = utils.save_buffer(b)
        if not saved then
          return false, msgs, "could not save " .. name .. ": " .. tostring(err)
        end
      end
    end
  end
  return true, msgs, res
end

---------------------------------------------------------------------------
-- Files
---------------------------------------------------------------------------

---@class org.api.File
---@field file string|nil absolute path (nil for a buffer without a file)
---@field bufnr integer|nil the buffer it was read from, when loaded
---@field title string `#+TITLE`, or the file name without extension
---@field category string
---@field filetags string[] `#+FILETAGS`
---@field properties table<string, string> file-level properties (property drawer before the first headline)
---@field todo_keywords org.api.TodoKeywords the keywords in effect in the file
---@field headlines org.api.Headline[] every headline, in document order

---@class org.api.TodoKeywords
---@field todo string[] the not-done keywords
---@field done string[] the done keywords
---@field all string[] every keyword, in the order they are defined (org-todo-keywords-1). Since API 1.3

---@param todo org.TodoConfig
---@return org.api.TodoKeywords
local function keywords_of(todo)
  local kws = { todo = {}, done = {}, all = {} }
  for _, name in ipairs(todo:names()) do
    kws.all[#kws.all + 1] = name
    table.insert(todo:is_done(name) and kws.done or kws.todo, name)
  end
  return kws
end

---@param f org.File
---@return org.api.File
local function file_data(f)
  local memo = H.batch()
  return {
    file = f.filename,
    bufnr = f.bufnr,
    title = f:title(),
    category = f:category(),
    filetags = vim.deepcopy(f.settings.filetags or {}),
    properties = vim.deepcopy(f.properties or {}),
    todo_keywords = keywords_of(f.settings.todo),
    headlines = vim.tbl_map(function(hl)
      return H.new(hl, memo)
    end, f.headlines),
  }
end

--- Absolute paths of the agenda files (`agenda_files`).
---@return string[]
function M.agenda_files()
  return files.agenda_file_paths()
end

--- The TODO keywords in effect: of the `todo_keywords` option without an
--- argument, else of a file (a path) or a buffer (a number, 0 the current
--- one), its `#+TODO` lines included. nil and an error when the file
--- can't be read or the buffer isn't an org buffer. Since API 1.3.
---@param where? string|integer
---@return org.api.TodoKeywords|nil keywords, string|nil err
function M.todo_keywords(where)
  if where == nil then
    return keywords_of(require("org.todo_keywords").global())
  elseif type(where) == "number" then
    local bufnr = resolve_buf(where)
    if not vim.api.nvim_buf_is_valid(bufnr) or not utils.is_org(bufnr) then
      return nil, ("buffer %d is not an org buffer"):format(bufnr)
    end
    return keywords_of(files.get_buffer(bufnr).settings.todo)
  end
  local path = utils.expand(where)
  local f = files.get(path)
  if not f then
    return nil, "cannot read " .. path
  end
  return keywords_of(f.settings.todo)
end

--- Read org files: one path gives one |org.api.File| (nil and an error
--- when it can't be read), a list of paths (globs and directories too) a
--- list, and no argument the agenda files. A file loaded in a buffer is
--- read from the buffer, unsaved changes included.
---@param paths? string|string[]
---@return org.api.File|org.api.File[]|nil, string|nil err
function M.load(paths)
  if type(paths) == "string" then
    local path = utils.expand(paths)
    local f = files.get(path)
    if not f then
      return nil, "cannot read " .. path
    end
    return file_data(f)
  end
  return vim.tbl_map(file_data, M.agenda.files(paths))
end

--- The org file of a buffer (default: the current one), or nil when it
--- isn't an org buffer.
---@param bufnr? integer
---@return org.api.File|nil
function M.current(bufnr)
  bufnr = resolve_buf(bufnr)
  if not utils.is_org(bufnr) then
    return nil
  end
  return file_data(files.get_buffer(bufnr))
end

---------------------------------------------------------------------------
-- Headlines
---------------------------------------------------------------------------

--- The cursor `{ row, col }` (1-based row, 0-based byte column) of a
--- buffer: of the current window when it shows the buffer, else of the
--- first window showing it (in this tab page first). A buffer no window
--- shows has no cursor: nil and an error.
---@param bufnr integer
---@return integer[]|nil cursor, string|nil err
local function buffer_cursor(bufnr)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    win = vim.fn.bufwinid(bufnr)
    if win == -1 then
      win = vim.fn.win_findbuf(bufnr)[1]
    end
  end
  if not win then
    return nil, ("buffer %d is not shown in a window: there is no cursor, give a line"):format(bufnr)
  end
  return vim.api.nvim_win_get_cursor(win)
end

--- The headline containing a line: `opts.bufnr` (default current) and
--- `opts.lnum` (default the cursor line: of the current window when it
--- shows the buffer, else of the first window showing it), or `opts.file`
--- and `opts.lnum`. nil and an error for a buffer no window shows without
--- `opts.lnum`.
---@param opts? { bufnr?: integer, file?: string, lnum?: integer }
---@return org.api.Headline|nil, string|nil err
function M.headline_at(opts)
  opts = opts or {}
  local f
  local lnum = opts.lnum
  if opts.file then
    f = files.get(opts.file)
    lnum = lnum or 1
  else
    local bufnr = resolve_buf(opts.bufnr)
    if not lnum then
      local cur, err = buffer_cursor(bufnr)
      if not cur then
        return nil, err
      end
      lnum = cur[1]
    end
    f = files.get_buffer(bufnr)
  end
  local hl = f and f:headline_at(lnum)
  return hl and H.new(hl) or nil
end

--- Find a headline by its ID property, in the current buffer, where the ID
--- database says, then in every file org knows (like `id:` links).
---@param id string
---@return org.api.Headline|nil
function M.find_by_id(id)
  local loc = require("org.id").find(id)
  if not loc then
    return nil
  end
  local f = loc.bufnr and files.get_buffer(loc.bufnr) or files.get(loc.filename)
  local hl = f and f:find_by_id(id)
  return hl and H.new(hl) or nil
end

---@class org.api.Query
---@field files? string|string[] files, globs or directories (default: the agenda files)
---@field match? string a tags/property match as in agenda tag searches: `+work-urgent`, `PRIORITY="A"`, `+proj/TODO|NEXT`
---@field todo? string|string[]|boolean a keyword or one of a list; true: a not-done keyword; false: no keyword
---@field done? boolean in a done state (true) or not (false)
---@field tags? string|string[] all of these tags, inherited ones included
---@field property? table<string, string|boolean|fun(value: string|nil): boolean> property values (inheritance per `use_property_inheritance`); true: set; false: unset
---@field level? integer|{ min?: integer, max?: integer }
---@field title? string text the title contains (ignoring case)
---@field id? string
---@field archived? boolean include (true, default) or skip (false) ARCHIVE-tagged subtrees: the heading's own tag or an ancestor's (org-in-archived-heading-p), not `#+FILETAGS: :ARCHIVE:`
---@field filter? fun(h: org.api.Headline): boolean
---@field bufnr? integer a buffer to read instead of `files` (also one without a file; 0 is the current one). Since API 1.3
---@field within? org.api.Headline only the subtree of this headline, it included (`files` and `bufnr` are then ignored). Since API 1.3
---@field agenda? boolean only the entries the agenda views look at (org-agenda-skip): not in a COMMENT subtree (per `agenda.skip_comment_trees`), an ARCHIVE-tagged one or a file tagged ARCHIVE in its `#+FILETAGS:`, and not skipped by `agenda.skip_function_global`. Since API 1.3
---@field planned? boolean with a SCHEDULED or DEADLINE date (true), or neither (false). Since API 1.3
---@field fields? string[] fill only these of the fields a query computes per headline (`all_tags`, `properties`, `scheduled`, `deadline`, `closed`, `effort`, `category`, `outline_path`, `priority_value`); the others are always there. For big queries that need few of them. Since API 1.3

---@class org.api.RangeQuery: org.api.Query
---@field from? any the first day (any date the API accepts); default: no limit
---@field to? any the last day; default: no limit

local function as_list(v)
  if v == nil then
    return nil
  end
  return type(v) == "table" and v or { v }
end

--- `s` in lower case, letters beyond ASCII too (`ÉTÉ` → `été`).
---@param s string
---@return string
local function lower(s)
  if s:find("[\128-\255]") then
    return vim.fn.tolower(s)
  end
  return s:lower()
end

--- The parsed files a query reads (`within`, `bufnr`, else `files`), and
--- with `within` the lines of the subtree.
---@param query org.api.Query
---@return org.File[]|nil files, integer[]|nil range, string|nil err
local function query_files(query)
  if query.within ~= nil then
    local hl, err = H.find(query.within)
    if not hl then
      return nil, nil, err
    end
    return { hl.file }, { hl.line, hl.end_line }
  end
  if query.bufnr ~= nil then
    local bufnr = resolve_buf(query.bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) or not utils.is_org(bufnr) then
      return nil, nil, ("buffer %d is not an org buffer"):format(bufnr)
    end
    return { files.get_buffer(bufnr) }
  end
  return M.agenda.files(query.files)
end

--- Call `fn(hl)` for each parsed headline that meets every condition of
--- `query` but its `filter` (which takes a handle), in file order.
---@param query org.api.Query
---@param fn fun(hl: org.Headline)
---@return boolean|nil ok, string|nil err
local function each_headline(query, fn)
  local pred
  if query.match and query.match ~= "" then
    local err
    pred, err = require("org.agenda.search").try_compile(query.match)
    if not pred then
      return nil, err
    end
  end
  local todo = query.todo
  local todo_set
  if type(todo) == "string" or type(todo) == "table" then
    todo_set = {}
    for _, k in ipairs(type(todo) == "table" and todo or { todo }) do
      todo_set[k] = true
    end
  end
  local tags = as_list(query.tags)
  local level = query.level
  local title = query.title and lower(query.title)
  local function keep(hl)
    if query.archived == false then
      local h = hl
      while h do
        if h:is_archived() then
          return false
        end
        h = h.parent
      end
    end
    if todo_set and not (hl.todo and todo_set[hl.todo]) then
      return false
    elseif todo == true and not hl:is_todo() then
      return false
    elseif todo == false and hl.todo then
      return false
    end
    if query.done ~= nil and hl:is_done() ~= query.done then
      return false
    end
    if query.planned ~= nil and ((hl.planning.scheduled or hl.planning.deadline) ~= nil) ~= query.planned then
      return false
    end
    if type(level) == "number" and hl.level ~= level then
      return false
    elseif
      type(level) == "table" and ((level.min and hl.level < level.min) or (level.max and hl.level > level.max))
    then
      return false
    end
    if title and not lower(hl.title):find(title, 1, true) then
      return false
    end
    if query.id and hl.properties.ID ~= query.id then
      return false
    end
    if tags then
      local all = {}
      for _, t in ipairs(hl:get_tags()) do
        all[t] = true
      end
      for _, t in ipairs(tags) do
        if not all[t] then
          return false
        end
      end
    end
    for name, want in pairs(query.property or {}) do
      local v = hl:get_property(name)
      if type(want) == "function" then
        if not want(v) then
          return false
        end
      elseif want == true then
        if v == nil or v == "" then
          return false
        end
      elseif want == false then
        if v ~= nil and v ~= "" then
          return false
        end
      elseif v ~= tostring(want) then
        return false
      end
    end
    if pred and not pred(hl) then
      return false
    end
    return true
  end
  local fs, range, err = query_files(query)
  if not fs then
    return nil, err
  end
  local function visit(hl)
    if range and (hl.line < range[1] or hl.line > range[2]) then
      return
    end
    if keep(hl) then
      fn(hl)
    end
  end
  if query.agenda then
    -- a subtree skip is asked about the headlines the query matches only,
    -- as org-agenda-skip runs after the matcher (`candidate`)
    require("org.agenda.items").each_headline(fs, {
      candidate = function(hl)
        return not (range and (hl.line < range[1] or hl.line > range[2])) and keep(hl)
      end,
    }, visit)
  else
    for _, f in ipairs(fs) do
      for _, hl in ipairs(f.headlines) do
        visit(hl)
      end
    end
  end
  return true
end

--- Headlines matching every given condition of `query`, in file order.
---@param query? org.api.Query
---@return org.api.Headline[]|nil headlines, string|nil err
function M.headlines(query)
  query = query or {}
  local memo, err = H.batch(query.fields)
  if not memo then
    return nil, err
  end
  local out = {}
  local ok
  ok, err = each_headline(query, function(hl)
    local h = H.new(hl, memo)
    if not query.filter or query.filter(h) then
      out[#out + 1] = h
    end
  end)
  if not ok then
    return nil, err
  end
  return out
end

--- The day numbers of a range query's `from` and `to` (nil: no limit).
---@param query org.api.RangeQuery
---@return integer|nil from, integer|nil to, string|nil err
local function day_range(query)
  local out = {}
  for i, k in ipairs({ "from", "to" }) do
    if query[k] ~= nil then
      local d, err = H.to_date(query[k])
      if not d then
        return nil, nil, err
      end
      out[i] = d:days()
    end
  end
  return out[1], out[2]
end

--- `fn(hl)` for the headlines of a range query, with the handle `h(hl)`
--- that makes (once) the handle of `hl` an entry points to, or returns
--- false when the query's filter leaves it out.
---@param query org.api.Query
---@param fn fun(hl: org.Headline, h: fun(): org.api.Headline|false)
---@return boolean|nil ok, string|nil err
local function each_with_handle(query, fn)
  local memo, err = H.batch(query.fields)
  if not memo then
    return nil, err
  end
  return each_headline(query, function(hl)
    local handle
    fn(hl, function()
      if handle == nil then
        handle = H.new(hl, memo)
        if query.filter and not query.filter(handle) then
          handle = false
        end
      end
      return handle
    end)
  end)
end

---@class org.api.Clock
---@field start org.api.Date
---@field end org.api.Date|nil nil while the clock runs
---@field minutes integer the time between its timestamps (until now while it runs), not its `=> H:MM` text, as org-clock-sum counts it; 0 for one that ends before it starts or whose start has no time
---@field running boolean
---@field line integer the CLOCK line
---@field headline org.api.Headline the entry it clocks (one handle per entry)

--- The CLOCK lines of the headlines matching `query` (their own, not
--- those of their children), in file order; with `from` / `to`, those
--- that ran on one of those days. Since API 1.3.
---@param query? org.api.RangeQuery
---@return org.api.Clock[]|nil clocks, string|nil err
function M.clocks(query)
  query = query or {}
  local from, to, err = day_range(query)
  if err then
    return nil, err
  end
  local date = require("org.date")
  local parser = require("org.parser")
  local now = date.now()
  local now_time = now:to_time()
  -- year * 10000 + month * 100 + day compares like days, without
  -- computing day numbers for the clocks out of the range
  local function key(d)
    return d.year * 10000 + d.month * 100 + d.day
  end
  local from_key = from and key(date.from_days(from)) or -math.huge
  local to_key = to and key(date.from_days(to)) or math.huge
  local out = {}
  -- the Unix times of the dates, shared
  local times = H.batch()
  local ok
  ok, err = each_with_handle(query, function(hl, handle)
    for _, c in ipairs(hl.clocks) do
      local s, e = c.start, c["end"]
      if key(s) <= to_key and key(e or now) >= from_key then
        local h = handle()
        if not h then
          return
        end
        -- from the timestamps, like org-clock-sum (and the clock table),
        -- with the Unix times the dates have anyway
        local sd = H.date(s, nil, times) --[[@as org.api.Date]]
        local ed = e and H.date(e, nil, times) or nil
        local minutes = 0
        if not e then
          minutes = math.floor((now_time - sd.timestamp) / 60)
        elseif ed and s:has_time() and e:has_time() then
          minutes = math.floor((ed.timestamp - sd.timestamp) / 60)
        elseif s:has_time() then
          -- an end without a time: org-clock-sum takes the start's
          minutes = math.floor(date.elapsed_minutes(s, assert(parser.clock_end(c))))
        end
        out[#out + 1] = {
          start = sd,
          ["end"] = ed,
          minutes = math.max(minutes, 0),
          running = e == nil,
          line = c.line,
          headline = h,
        }
      end
    end
  end)
  if not ok then
    return nil, err
  end
  return out
end

---@class org.api.Completion
---@field date org.api.Date when it was marked done
---@field type "closed"|"state"|"note"|"last_repeat" where that is written: the CLOSED date, a `- State "DONE" ... [date]` log line (a change to a done keyword), a `- CLOSING NOTE [date]` line, or the LAST_REPEAT property (a repeating entry's last repeat)
---@field headline org.api.Headline the entry (one handle per entry)

--- When the headlines matching `query` were marked done: their CLOSED
--- date, the log lines org-habit reads (changes to a done keyword, and
--- closing notes per `log_note_headings.done`), and their LAST_REPEAT
--- property; with `from` / `to`, those on one of those days. Entries in
--- file order; an entry's CLOSED date first, then its log lines as they
--- are written, then LAST_REPEAT. Since API 1.3.
---@param query? org.api.RangeQuery
---@return org.api.Completion[]|nil completions, string|nil err
function M.completed(query)
  query = query or {}
  local from, to, err = day_range(query)
  if err then
    return nil, err
  end
  local date = require("org.date")
  from, to = from or -math.huge, to or math.huge
  local out = {}
  local times = H.batch()
  -- the log lines org-habit-parse-todo reads, as habits read them
  local habits = require("org.agenda.habits")
  local closing_note = habits.done_note_pattern()
  local ok
  ok, err = each_with_handle(query, function(hl, handle)
    local function add(kind, d)
      if not d then
        return true
      end
      local n = d:days()
      if n < from or n > to then
        return true
      end
      local h = handle()
      if not h then
        return false
      end
      out[#out + 1] = { date = H.date(d, nil, times), type = kind, headline = h }
      return true
    end
    if not add("closed", hl.planning.closed) then
      return
    end
    local done = hl.file.settings.todo
    local lines = hl.file.lines
    -- the entry as org-habit-parse-todo reads it (org-entry-end-position)
    for i = hl.line + 1, hl:entry_end() do
      local line = lines[i]
      local kind = "state"
      local kw, ts = line:match(habits.STATE_LOG)
      if not (kw and done:is_done(kw)) then
        kind, ts = "note", closing_note and line:match(closing_note) or nil
      end
      if ts and not add(kind, date.parse(ts)) then
        return
      end
    end
    local lr = hl.properties.LAST_REPEAT
    add("last_repeat", lr and date.parse(lr))
  end)
  if not ok then
    return nil, err
  end
  return out
end

---------------------------------------------------------------------------
-- Symbols
---------------------------------------------------------------------------

---@class org.api.Position
---@field line integer 0-based line
---@field character integer 0-based byte column

---@class org.api.Range
---@field start org.api.Position
---@field end org.api.Position

---@class org.api.Symbol
---@field name string the headline's plain title, or the src block's, table's or target's name
---@field detail string `TODO [#A] :tag:` for a headline, "src block", "table", "target" or "radio target"
---@field kind integer `vim.lsp.protocol.SymbolKind` value
---@field range org.api.Range the whole subtree / block / table / target
---@field selectionRange org.api.Range the title or name
---@field children org.api.Symbol[] (empty for a symbol without any)
---@field type "headline"|"src_block"|"table"|"target"|"radio_target"
---@field lnum integer 1-based first line
---@field end_lnum integer 1-based last line
---@field level integer|nil a headline's level

---@class org.api.SymbolsOpts
---@field src_blocks? boolean named src blocks (default true)
---@field tables? boolean named tables (default true)
---@field targets? boolean `<<targets>>` and `<<<radio targets>>>` (default false)
---@field kinds? table<string, string|integer> symbol kinds by `heading`, `todo`, `done`, `src_block`, `table`, `target` (`vim.lsp.protocol.SymbolKind` names or values)

--- Options of `symbols()` / `symbol_path()`: the `lsp` extension's
--- `document_symbols` and `symbol_kinds` when it is on, under `opts`.
---@param opts org.api.SymbolsOpts|nil
---@return table
local function symbol_opts(opts)
  local lsp = require("org.extensions").opts("lsp") or {}
  local ds = lsp.document_symbols or {}
  local o = vim.tbl_extend(
    "force",
    { src_blocks = ds.src_blocks, tables = ds.tables, targets = ds.targets, kinds = lsp.symbol_kinds },
    opts or {}
  )
  o.foreign = nil
  return o
end

--- The outline of an org buffer (default current) as a tree of LSP
--- `DocumentSymbol`s (0-based lines, byte columns): headlines, each
--- covering its subtree, with named src blocks and tables (and targets
--- with `opts.targets`) as children of their entry. Text the
--- `transclusion` extension inserted is left out. nil and an error for a
--- buffer that isn't an org buffer.
---@param bufnr? integer
---@param opts? org.api.SymbolsOpts
---@return org.api.Symbol[]|nil symbols, string|nil err
function M.symbols(bufnr, opts)
  bufnr = resolve_buf(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not utils.is_org(bufnr) then
    return nil, ("buffer %d is not an org buffer"):format(bufnr)
  end
  return require("org.symbols").buffer(bufnr, symbol_opts(opts))
end

--- The headline symbols (without children) from the outermost to the
--- innermost one containing a line: breadcrumbs for a winbar or
--- statusline. `opts.win` takes the buffer and cursor line of a window
--- (`vim.g.statusline_winid` in a 'winbar' expression); else `opts.bufnr`
--- (default current) and `opts.lnum` (default its cursor line). Only the
--- headline's ancestors are looked at, so it is cheap to call on every
--- redraw. An empty list before the first headline; nil and an error for
--- a buffer that isn't an org buffer.
---@param opts? { win?: integer, bufnr?: integer, lnum?: integer, kinds?: table<string, string|integer> }
---@return org.api.Symbol[]|nil path, string|nil err
function M.symbol_path(opts)
  opts = opts or {}
  local bufnr, lnum = opts.bufnr, opts.lnum
  if opts.win and opts.win ~= 0 then
    if not vim.api.nvim_win_is_valid(opts.win) then
      return nil, ("window %d is not valid"):format(opts.win)
    end
    bufnr = vim.api.nvim_win_get_buf(opts.win)
    lnum = lnum or vim.api.nvim_win_get_cursor(opts.win)[1]
  end
  bufnr = resolve_buf(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not utils.is_org(bufnr) then
    return nil, ("buffer %d is not an org buffer"):format(bufnr)
  end
  if not lnum then
    local cur, err = buffer_cursor(bufnr)
    if not cur then
      return nil, err
    end
    lnum = cur[1]
  end
  local sym = require("org.symbols")
  local o = symbol_opts({ kinds = opts.kinds })
  o.foreign = sym.foreign(bufnr)
  return sym.path(files.get_buffer(bufnr), lnum, o)
end

---------------------------------------------------------------------------
-- Capture
---------------------------------------------------------------------------

---@class org.api.CaptureOpts
---@field key? string a template key of `capture.templates`
---@field template? string|table template text, or a whole template table (as in `capture.templates`)
---@field target? string with a template text: the file (default `default_notes_file`)
---@field headline? string with a template text: the headline to file under
---@field olp? string[] with a template text: the outline path to file under
---@field type? string with a template text: entry (default), item, checkitem, table-line, plain
---@field datetree? boolean|table with a template text: file in a date tree
---@field values? table<string|integer, any> answers to the `%^` prompts, by label or position
---@field initial? string the text of `%i`
---@field date? any the capture date (`%t`, date trees, `time_prompt`)

---@class org.api.CaptureResult
---@field file string|nil
---@field bufnr integer|nil the buffer it was stored in (nil when the template's `kill_buffer` closed it)
---@field line integer first line of the stored text
---@field headline org.api.Headline|nil the captured entry (entry templates)

--- Capture without a capture window: the template is filled in (prompts
--- `%^{...}` take `opts.values`, else their default or nothing), stored
--- and saved at once, and `OrgCaptureAfterFinalize` fires.
---@param opts org.api.CaptureOpts
---@return org.api.CaptureResult|nil result, string|nil err
function M.capture(opts)
  opts = opts or {}
  local capture = require("org.capture")
  local tpl
  local template = opts.template
  if opts.key then
    tpl = capture.get_template(opts.key)
    if not tpl then
      return nil, "no capture template for key: " .. opts.key
    end
  elseif type(template) == "table" then
    tpl = vim.deepcopy(template)
  elseif type(template) == "string" then
    tpl = {
      template = template,
      target = opts.target,
      headline = opts.headline,
      olp = opts.olp,
      type = opts.type,
      datetree = opts.datetree,
    }
  else
    return nil, "capture needs a template key or a template"
  end
  tpl = vim.tbl_extend("force", tpl, { immediate_finish = true, jump_to_captured = false })
  local d
  if opts.date ~= nil then
    local err
    d, err = H.to_date(opts.date)
    if not d then
      return nil, err
    end
  end
  local ok, msgs, bufnr, line, path = utils.noninteractive(capture.capture, tpl, {
    initial = opts.initial,
    date = d,
    answers = opts.values,
    noninteractive = true,
  })
  if not ok then
    return nil, tostring(bufnr)
  end
  if not bufnr then
    return nil, last_problem(msgs) or "nothing was captured"
  end
  -- the template's kill_buffer closes a buffer the capture loaded: the
  -- entry is saved, read it from the file
  local loaded = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
  local name = loaded and vim.api.nvim_buf_get_name(bufnr) or path or ""
  local file = name ~= "" and vim.fs.normalize(name) or nil
  local result = { file = file, bufnr = loaded and bufnr or nil, line = line }
  if (tpl.type or "entry") == "entry" then
    local f = loaded and files.get_buffer(bufnr) or (file and files.get(file)) or nil
    local hl = f and f:headline_on(line)
    result.headline = hl and H.new(hl) or nil
  end
  return result
end

---------------------------------------------------------------------------
-- Links
---------------------------------------------------------------------------

M.links = {}

---@class org.api.Link
---@field link string the target, as inside `[[...]]`
---@field desc string|nil

--- Add a link to the stored links (offered by the link prompt, <prefix>li).
---@param link string
---@param desc? string
---@return org.api.Link
function M.links.store(link, desc)
  local s = require("org.links").store(link, desc)
  return { link = s.link, desc = s.desc }
end

--- Compute and store a link to a headline (a handle) or a location
--- `{ bufnr, lnum }` (default: the cursor, see `headline_at`), like
--- <prefix>ls (an `id:` link when `links.use_id` asks for it, which may
--- create the ID: its file is saved like other API changes).
---@param where? org.api.Headline|{ bufnr?: integer, lnum?: integer }
---@param opts? { save?: boolean }
---@return org.api.Link|nil link, string|nil err
function M.links.store_location(where, opts)
  local loc = {}
  if where and getmetatable(where) == H.Headline then
    local bufnr, hl, err = H.resolve(where)
    if not bufnr or not hl then
      return nil, err
    end
    loc = { bufnr = bufnr, lnum = hl.line }
  elseif type(where) == "table" then
    loc = { bufnr = where.bufnr ~= 0 and where.bufnr or nil, lnum = where.lnum }
  end
  -- the current buffer's cursor is the current window's (link_to_location
  -- reads it); another buffer's is in a window showing it
  if loc.bufnr and not loc.lnum and loc.bufnr ~= vim.api.nvim_get_current_buf() then
    local cur, err = buffer_cursor(loc.bufnr)
    if not cur then
      return nil, err
    end
    loc.lnum, loc.col = cur[1], cur[2] + 1
  end
  local links = require("org.links")
  local ok, msgs, l = change(opts or {}, links.link_to_location, {
    bufnr = loc.bufnr,
    lnum = loc.lnum,
    col = loc.col,
    interactive = false,
  })
  if not ok then
    return nil, tostring(l)
  end
  if not l then
    return nil, last_problem(msgs) or "no link can be stored for this location"
  end
  return M.links.store(l.link, l.desc)
end

--- The stored links, most recent first.
---@return org.api.Link[]
function M.links.stored()
  return vim.tbl_map(function(s)
    return { link = s.link, desc = s.desc }
  end, require("org.links").stored)
end

--- A bracket link `[[link][desc]]`, escaped.
---@param link string
---@param desc? string
---@return string
function M.links.format(link, desc)
  return require("org.links").format(link, desc)
end

--- Insert a link at the cursor, or at `opts.bufnr` / `opts.row` /
--- `opts.col` (1-based row, 0-based byte column; the missing ones from the
--- buffer's cursor, see `headline_at`), written for that buffer like
--- <prefix>li writes it (file links per `links.file_path_type`). Returns
--- the inserted text, or nil and an error.
---@param link string
---@param desc? string
---@param opts? { bufnr?: integer, row?: integer, col?: integer }
---@return string|nil text, string|nil err
function M.links.insert(link, desc, opts)
  opts = opts or {}
  local links = require("org.links")
  local bufnr = resolve_buf(opts.bufnr)
  local row, col = opts.row, opts.col
  if not row or not col then
    local cur, err = buffer_cursor(bufnr)
    if not cur then
      return nil, err
    end
    row, col = row or cur[1], col or cur[2]
  end
  local text = links.format_for_buffer(link, desc, { bufnr = bufnr }) or ""
  -- a description keeps its line breaks, as in Emacs (org-link-make-string)
  vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, vim.split(text, "\n", { plain = true }))
  return text
end

---@class org.api.ResolvedLink
---@field type string link type: file, id, http, https, custom-id, heading, fuzzy, coderef, ...
---@field path string the part after `type:` (the whole target for internal links)
---@field target string the target with link abbreviations expanded
---@field search string|nil the search option after `::`; for internal links the search itself (`*Heading`, `#id`, `(ref)`, text)
---@field file string|nil the file it points to, when it points into a file
---@field line integer|nil the line it points to, when found
---@field headline org.api.Headline|nil the headline on that line, when it points to one
---@field url string|nil the address of a web or mail link

--- Find what a link points to without following it, the way following
--- it finds it (`org.links`: the same reading of the target and the same
--- search, ignoring case and blanks: `*Heading`, `#custom-id`, `(coderef)`,
--- `<<target>>`, `#+NAME:`, headline titles, text). `link` is a target or
--- a bracket link; internal links are looked up in `opts.bufnr` (default
--- current). Not resolved: `/regexp/` searches, and what
--- `links.search_functions`, org-ctags or a BibTeX file would answer.
---@param link string
---@param opts? { bufnr?: integer }
---@return org.api.ResolvedLink|nil resolved, string|nil err
function M.links.resolve(link, opts)
  opts = opts or {}
  local links = require("org.links")
  local bufnr = resolve_buf(opts.bufnr)
  local target = link
  if link:match("^%s*%[%[") then
    local b = links.parse_links(vim.trim(link), { bracket_only = true })[1]
    if b and b.start_col == 1 and b.end_col == #vim.trim(link) then
      target = b.target
    end
  end
  local l = links.read_target(target, bufnr)
  local out = { type = l.type, path = l.path, target = l.target }
  -- the line `search` finds in `src`, as following the link finds it (a
  -- BibTeX file looks for the key's entry instead: not resolved)
  local function locate(src, search, sopts, name)
    if not src or (name or ""):match("%.bib$") then
      return
    end
    local lnum = links.search_location(search, src, sopts)
    if lnum then
      local hl = src.file and src.file:headline_on(lnum)
      out.line, out.headline = lnum, hl and H.new(hl) or nil
    end
  end
  local t = l.type
  if t == "id" then
    local loc, id, option = links.find_id_link(l.path)
    out.search = option
    if not loc then
      return nil, "cannot find entry with ID " .. id
    end
    local src = links.search_source(loc.bufnr, loc.filename)
    local f = src and src.file
    local hl = f and f:find_by_id(id)
    out.file = f and f.filename or loc.filename
    if option then
      -- searched within the entry's subtree (org-id-open narrows to it)
      locate(src, option, { range = hl and { hl.line, hl.end_line } or nil })
    else
      out.line = hl and hl.line or loc.lnum or 1
      out.headline = hl and H.new(hl) or nil
    end
  elseif t == "file" or t == "file+sys" or t == "file+emacs" or t == "attachment" then
    local path, search = l.path:match("^(.-)::(.*)$")
    path = path or l.path
    out.search = search
    local full
    if t == "attachment" then
      full = require("org.attach").resolve_attachment(path, { bufnr = bufnr })
    end
    full = (t ~= "attachment" or full) and links.file_link_path(full or path, bufnr) or nil
    out.file = full and vim.fs.normalize(full) or nil
    if out.file and search and search ~= "" and utils.exists(out.file) and not utils.is_dir(out.file) then
      if search:match("^%d+$") then
        out.line = tonumber(search)
      else
        locate(links.search_source(nil, out.file), search, nil, out.file)
      end
    end
  elseif t == "custom-id" or t == "heading" or t == "fuzzy" or t == "coderef" then
    out.search = l.target
    local name = vim.api.nvim_buf_get_name(bufnr)
    out.file = name ~= "" and vim.fs.normalize(name) or nil
    locate(links.search_source(bufnr), out.search, nil, vim.bo[bufnr].filetype == "bib" and ".bib" or name)
  elseif links.URL_SCHEMES[t] then
    out.url = l.target
  end
  return out
end

---------------------------------------------------------------------------
-- Clock
---------------------------------------------------------------------------

M.clock = {}

---@class org.api.ClockStatus
---@field title string the task as the statusline names it
---@field file string|nil
---@field start org.api.Date
---@field minutes integer minutes of the running clock
---@field clocked integer `minutes` plus the earlier time the statusline counts (`clock.mode_line_total`)
---@field effort integer|nil the Effort in minutes
---@field overrun boolean `clocked` reached the effort
---@field headline org.api.Headline|nil the clocked entry, when found

--- The running clock, or nil when no clock runs.
---@return org.api.ClockStatus|nil
function M.clock.status()
  local clock = require("org.clock")
  local a = clock.active()
  if not a then
    return nil
  end
  local out = {
    title = a.title,
    file = a.path ~= "" and a.path or nil,
    start = H.date(a.start),
    minutes = a.minutes,
    clocked = a.clocked,
    effort = a.effort,
    overrun = a.overrun,
  }
  local ok, bufnr, lnum = pcall(clock.find_open_clock)
  if ok and bufnr and lnum then
    local hl = files.get_buffer(bufnr):headline_at(lnum)
    out.headline = hl and H.new(hl) or nil
  end
  return out
end

--- Is a clock running?
---@return boolean
function M.clock.is_running()
  return require("org.clock").state ~= nil
end

--- Stop the running clock (org-clock-out), wherever it runs. Returns the
--- clocked minutes. The entry's file is saved like other API changes.
---@param opts? { note?: string, save?: boolean }
---@return integer|nil minutes, string|nil err
function M.clock.clock_out(opts)
  opts = opts or {}
  local status = M.clock.status()
  if not status then
    return nil, "no clock is running"
  end
  if status.headline then
    return status.headline:clock_out(opts)
  end
  local ok, msgs, minutes = change(opts, require("org.clock").clock_out, { note = false, quiet = true })
  if not ok then
    return nil, tostring(minutes)
  end
  return minutes, minutes == nil and last_problem(msgs) or nil
end

--- Cancel the running clock (org-clock-cancel): its CLOCK line is removed
--- and the file saved like other API changes.
---@param opts? { save?: boolean }
---@return boolean|nil ok, string|nil err
function M.clock.cancel(opts)
  if not M.clock.is_running() then
    return nil, "no clock is running"
  end
  local ok, msgs, res = change(opts or {}, require("org.clock").clock_cancel)
  if not ok then
    return nil, tostring(res)
  end
  if not res then
    return nil, last_problem(msgs) or "the clock was not cancelled"
  end
  return true
end

---------------------------------------------------------------------------
-- The session server
---------------------------------------------------------------------------

--- The session server (|org-remote|): with `remote.enabled`, one running
--- Neovim takes the requests of other processes, so they change its
--- buffers instead of the files behind its back.
M.remote = {}

--- The address of the session server: `$ORG_NVIM_SERVER`, else the
--- `remote.address` option, else `org.nvim.sock` in the per-user runtime
--- directory.
---@return string
function M.remote.address()
  return require("org.remote").address()
end

--- Is this Neovim the session server?
---@return boolean
function M.remote.is_server()
  return require("org.remote").is_server()
end

--- Is a session server running (this Neovim or another one)?
---@return boolean
function M.remote.reachable()
  local remote = require("org.remote")
  if remote.is_server() then
    return true
  end
  if remote.disabled_by_env() then
    return false
  end
  return remote.request("ping") ~= nil
end

--- Call the org.api function `name` ("capture", "clock.status",
--- "headlines", ...) with `...` in the session server, and return its
--- results. It runs in this Neovim when it is the server, when none is
--- running, or when the server waits for input. Arguments and results
--- cross as plain data: functions in them are dropped, and a headline
--- handle comes back as its fields, without methods.
---@param name string
---@param ... any
---@return any ...
function M.remote.call(name, ...)
  local remote = require("org.remote")
  local fn = remote.api_function(name)
  if not fn then
    return nil, "no org.api function " .. tostring(name)
  end
  if not remote.is_server() and not remote.disabled_by_env() then
    local res, err, reason = remote.request("api", { name = name, args = remote.pack(...) })
    if type(res) == "table" then
      return remote.unpack(res)
    end
    if reason == "failed" then
      return nil, err
    end
  end
  return fn(...)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

--- The User autocmds org fires, with the fields of their `data`. Listen
--- with `api.on()` or `nvim_create_autocmd("User", { pattern = name })`.
M.events = {
  OrgTodoStateChange = "TODO state changed: bufnr, lnum, from, to, state, done, repeated",
  OrgTodoRepeat = "a repeating task was marked done and moved on: bufnr, lnum, from, to, state, done, repeated",
  OrgPriorityChanged = "priority changed: bufnr, lnum, file, from, to",
  OrgTagsChanged = "own tags changed: bufnr, lnum, file, from, to",
  OrgPropertyChanged = "property set: bufnr, lnum, name, value",
  OrgClockIn = "clock started: bufnr, lnum, title",
  OrgClockOut = "clock stopped: path, title, minutes, removed",
  OrgClockCancel = "clock cancelled: path, title",
  OrgCaptureAfterFinalize = "capture stored (or aborted): bufnr, line (aborted)",
  OrgRefile = "subtree refiled: bufnr, lnum, file, title, source_bufnr, source_file, copy",
  OrgArchive = "subtree about to leave its file for the archive: bufnr, lnum, title, archive_file",
  OrgArchiveFinalize = "archived copy in place: bufnr, lnum, title, archive_file",
  OrgFileLoaded = "file read from disk or buffer parsed for the first time: file, bufnr, source",
}

--- Call `fn(data, ev)` on the User autocmd `event` (a name of
--- `api.events`). Returns the autocmd id (remove it with `api.off`).
---@param event string
---@param fn fun(data: table, ev: table)
---@param opts? { once?: boolean, group?: integer|string }
---@return integer id
function M.on(event, fn, opts)
  opts = opts or {}
  return vim.api.nvim_create_autocmd("User", {
    pattern = event,
    once = opts.once,
    group = opts.group,
    desc = "org.api: " .. event,
    callback = function(ev)
      fn(ev.data or {}, ev)
    end,
  })
end

--- Remove a listener added with `api.on`.
---@param id integer
function M.off(id)
  pcall(vim.api.nvim_del_autocmd, id)
end

return M

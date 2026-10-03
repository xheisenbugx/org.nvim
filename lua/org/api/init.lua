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

local H = require("org.api.headline")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

--- Version of the API (`MAJOR.MINOR.PATCH`). A new MINOR adds functions,
--- fields or events; a new MAJOR may break code written for an older one.
M.version = "1.0.0"

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
  local want, have = parts(version), parts(M.version)
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
---@field todo_keywords { todo: string[], done: string[] } the keywords in effect in the file
---@field headlines org.api.Headline[] every headline, in document order

---@param f org.File
---@return org.api.File
local function file_data(f)
  local todo = f.settings.todo
  local kws = { todo = {}, done = {} }
  for _, name in ipairs(todo:names()) do
    table.insert(todo:is_done(name) and kws.done or kws.todo, name)
  end
  return {
    file = f.filename,
    bufnr = f.bufnr,
    title = f:title(),
    category = f:category(),
    filetags = vim.deepcopy(f.settings.filetags or {}),
    properties = vim.deepcopy(f.properties or {}),
    todo_keywords = kws,
    headlines = vim.tbl_map(H.new, f.headlines),
  }
end

--- Absolute paths of the agenda files (`agenda_files`).
---@return string[]
function M.agenda_files()
  return files.agenda_file_paths()
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
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not utils.is_org(bufnr) then
    return nil
  end
  return file_data(files.get_buffer(bufnr))
end

---------------------------------------------------------------------------
-- Headlines
---------------------------------------------------------------------------

--- The headline containing a line: `opts.bufnr` (default current) and
--- `opts.lnum` (default the cursor line), or `opts.file` and `opts.lnum`.
---@param opts? { bufnr?: integer, file?: string, lnum?: integer }
---@return org.api.Headline|nil
function M.headline_at(opts)
  opts = opts or {}
  local f
  local lnum = opts.lnum
  if opts.file then
    f = files.get(opts.file)
    lnum = lnum or 1
  else
    local bufnr = (opts.bufnr == nil or opts.bufnr == 0) and vim.api.nvim_get_current_buf() or opts.bufnr
    if not lnum then
      local win = vim.fn.bufwinid(bufnr)
      lnum = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or 1
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
---@field archived? boolean include (true, default) or skip (false) ARCHIVE-tagged subtrees
---@field filter? fun(h: org.api.Headline): boolean

local function as_list(v)
  if v == nil then
    return nil
  end
  return type(v) == "table" and v or { v }
end

--- Headlines matching every given condition of `query`, in file order.
---@param query? org.api.Query
---@return org.api.Headline[]|nil headlines, string|nil err
function M.headlines(query)
  query = query or {}
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
    for _, k in ipairs(as_list(todo)) do
      todo_set[k] = true
    end
  end
  local tags = as_list(query.tags)
  local level = query.level
  local title = query.title and query.title:lower()
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
    if type(level) == "number" and hl.level ~= level then
      return false
    elseif
      type(level) == "table" and ((level.min and hl.level < level.min) or (level.max and hl.level > level.max))
    then
      return false
    end
    if title and not hl.title:lower():find(title, 1, true) then
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
  local out = {}
  for _, f in ipairs(M.agenda.files(query.files)) do
    for _, hl in ipairs(f.headlines) do
      if keep(hl) then
        local h = H.new(hl)
        if not query.filter or query.filter(h) then
          out[#out + 1] = h
        end
      end
    end
  end
  return out
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
---@field bufnr integer
---@field line integer first line of the stored text
---@field headline org.api.Headline|nil the captured entry (entry templates)

--- The last warning or error among collected messages.
local function last_problem(msgs)
  for i = #msgs, 1, -1 do
    if msgs[i].level >= vim.log.levels.WARN then
      return msgs[i].msg
    end
  end
end

--- Capture without a capture window: the template is filled in (prompts
--- `%^{...}` take `opts.values`, else their default or nothing), stored
--- and saved at once, and `OrgCaptureAfterFinalize` fires.
---@param opts org.api.CaptureOpts
---@return org.api.CaptureResult|nil result, string|nil err
function M.capture(opts)
  opts = opts or {}
  local capture = require("org.capture")
  local tpl
  if opts.key then
    tpl = capture.get_template(opts.key)
    if not tpl then
      return nil, "no capture template for key: " .. opts.key
    end
  elseif type(opts.template) == "table" then
    tpl = vim.deepcopy(opts.template)
  elseif type(opts.template) == "string" then
    tpl = {
      template = opts.template,
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
  local ok, msgs, bufnr, line = utils.noninteractive(capture.capture, tpl, {
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
  local name = vim.api.nvim_buf_get_name(bufnr)
  local result = { file = name ~= "" and vim.fs.normalize(name) or nil, bufnr = bufnr, line = line }
  if (tpl.type or "entry") == "entry" then
    local hl = files.get_buffer(bufnr):headline_on(line)
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
--- `{ bufnr, lnum }` (default: the cursor), like <prefix>ls (an `id:` link
--- when `id.link_to_org_use_id` asks for it, which may create the ID).
---@param where? org.api.Headline|{ bufnr?: integer, lnum?: integer }
---@return org.api.Link|nil link, string|nil err
function M.links.store_location(where)
  local loc = {}
  if where and getmetatable(where) == H.Headline then
    local bufnr, hl, err = H.resolve(where)
    if not bufnr or not hl then
      return nil, err
    end
    loc = { bufnr = bufnr, lnum = hl.line }
  elseif type(where) == "table" then
    loc = { bufnr = where.bufnr, lnum = where.lnum }
  end
  local links = require("org.links")
  local ok, msgs, l = utils.noninteractive(links.link_to_location, {
    bufnr = loc.bufnr,
    lnum = loc.lnum,
    interactive = false,
  })
  if not ok then
    return nil, tostring(msgs)
  end
  if not l then
    return nil, "no link can be stored for this location"
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

--- Insert a link at the cursor of the current window, or at
--- `opts.bufnr` / `opts.row` / `opts.col` (1-based row, 0-based byte
--- column), written for that buffer like <prefix>li writes it (file links
--- per `links.file_path_type`). Returns the inserted text.
---@param link string
---@param desc? string
---@param opts? { bufnr?: integer, row?: integer, col?: integer }
---@return string
function M.links.insert(link, desc, opts)
  opts = opts or {}
  local links = require("org.links")
  local bufnr = (opts.bufnr == nil or opts.bufnr == 0) and vim.api.nvim_get_current_buf() or opts.bufnr
  local row, col = opts.row, opts.col
  if not row or not col then
    local win = vim.fn.bufwinid(bufnr)
    local cur = win ~= -1 and vim.api.nvim_win_get_cursor(win) or { 1, 0 }
    row, col = row or cur[1], col or cur[2]
  end
  local text = links.format_for_buffer(link, desc, { bufnr = bufnr }) or ""
  vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, { text })
  return text
end

---@class org.api.ResolvedLink
---@field type string link type: file, id, http, https, custom-id, heading, fuzzy, coderef, ...
---@field path string the part after `type:` (the whole target for internal links)
---@field target string the target with link abbreviations expanded
---@field search string|nil the search option after `::`
---@field file string|nil the file it points to, when it points into a file
---@field line integer|nil the line it points to, when found
---@field headline org.api.Headline|nil the headline it points to, when found
---@field url string|nil the address of a web or mail link

--- Find what a link points to without following it. `link` is a target or
--- a bracket link; internal links (`*Heading`, `#custom-id`, fuzzy text)
--- are looked up in `opts.bufnr` (default current). File searches find
--- a line number, `*heading`, `#custom-id`, `<<target>>` or a headline
--- title; regexp searches are not resolved.
---@param link string
---@param opts? { bufnr?: integer }
---@return org.api.ResolvedLink|nil resolved, string|nil err
function M.links.resolve(link, opts)
  opts = opts or {}
  local links = require("org.links")
  local bufnr = (opts.bufnr == nil or opts.bufnr == 0) and vim.api.nvim_get_current_buf() or opts.bufnr
  local target = link:match("^%[%[(.-)%]%[.-%]%]$") or link:match("^%[%[(.-)%]%]$")
  target = target and links.unescape(target) or link
  local file = utils.is_org(bufnr) and files.get_buffer(bufnr) or nil
  local expanded = links.expand_abbrev(target, file)
  local l = links.classify({ target = expanded })
  local out = { type = l.type, path = l.path, target = expanded }
  local function locate(f, search)
    if not f then
      return
    end
    out.file = f.filename
    if not search or search == "" then
      return
    end
    local hl
    local n = tonumber(search)
    if n then
      out.line = n
      return
    elseif search:sub(1, 1) == "#" then
      hl = f:find_by_custom_id(search:sub(2))
    elseif search:sub(1, 1) == "*" then
      hl = f:find_by_title(vim.trim(search:sub(2)))
    elseif search:match("^/.*/$") or search:match("^%(.*%)$") then
      return
    else
      for i, line in ipairs(f.lines) do
        if line:find("<<" .. search .. ">>", 1, true) then
          out.line = i
          return
        end
      end
      hl = f:find_by_title(search)
    end
    if hl then
      out.line = hl.line
      out.headline = H.new(hl)
    end
  end
  local t = l.type
  if t == "id" then
    local id, search = l.path:match("^(.-)::(.*)$")
    id = id or l.path
    out.search = search
    local loc = require("org.id").find(id)
    if not loc then
      return nil, "cannot find entry with ID " .. id
    end
    local f = loc.bufnr and files.get_buffer(loc.bufnr) or files.get(loc.filename)
    out.file = loc.filename
    local hl = f and f:find_by_id(id)
    out.line = hl and hl.line or loc.lnum
    out.headline = hl and H.new(hl) or nil
  elseif t == "file" or t == "file+sys" or t == "file+emacs" or t == "attachment" then
    local path, search = l.path:match("^(.-)::(.*)$")
    path = path or l.path
    out.search = search
    local full
    if t == "attachment" then
      full = require("org.attach").resolve_attachment(path, { bufnr = bufnr })
    else
      full = links.resolve_path(path, bufnr)
    end
    out.file = full and vim.fs.normalize(full) or nil
    if out.file and search and utils.exists(out.file) and not utils.is_dir(out.file) then
      locate(files.get(out.file), search)
    end
  elseif t == "custom-id" or t == "heading" or t == "fuzzy" or t == "coderef" then
    out.search = t == "custom-id" and ("#" .. l.path) or t == "heading" and ("*" .. l.path) or l.path
    if t ~= "coderef" then
      locate(file, out.search)
    end
  elseif links.URL_SCHEMES[t] then
    out.url = expanded
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
  local ok, msgs, minutes = utils.noninteractive(require("org.clock").clock_out, { note = false, quiet = true })
  if not ok then
    return nil, tostring(minutes)
  end
  return minutes, minutes == nil and last_problem(msgs) or nil
end

--- Cancel the running clock (org-clock-cancel): its CLOCK line is removed.
---@return boolean|nil ok, string|nil err
function M.clock.cancel()
  if not M.clock.is_running() then
    return nil, "no clock is running"
  end
  local ok, _, res = utils.noninteractive(require("org.clock").clock_cancel)
  if not ok then
    return nil, tostring(res)
  end
  return true
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

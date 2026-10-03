---@mod org.api.headline Headline handles of the public API
---
--- A handle is a plain table of fields (a snapshot taken when it was made)
--- with methods. The methods find the headline again in its file (by its
--- ID when it has one, else by an extmark that follows its line while the
--- file is loaded, never by a guess), run the same code as the keys and
--- actions, and refresh the fields. See |org-api-headlines|.

local files = require("org.files")
local utils = require("org.utils")

local M = {}

---@class org.api.Date
---@field year integer
---@field month integer
---@field day integer
---@field hour integer|nil
---@field min integer|nil
---@field end_hour integer|nil end of a time range within the day
---@field end_min integer|nil
---@field active boolean `<...>` (true) or `[...]` (false)
---@field repeater { type: string, value: integer, unit: string }|nil e.g. `+1w`
---@field warning { type: string, value: integer, unit: string }|nil e.g. `-3d`
---@field date string `YYYY-MM-DD`
---@field time string|nil `HH:MM`
---@field timestamp integer Unix time (local time zone; midnight without a time)
---@field text string the timestamp as org writes it, e.g. `<2026-10-02 Fri 10:00 +1w>`
---@field raw string the timestamp as written in the file, a range `<...>--<...>` whole (`text` when unknown)

---@class org.api.Headline
---@field title string headline text without TODO keyword, priority and tags
---@field plain_title string `title` with links replaced by their descriptions and statistics cookies removed
---@field raw string the whole headline line
---@field level integer
---@field todo string|nil TODO keyword
---@field todo_type "todo"|"done"|nil
---@field done boolean
---@field priority string|nil priority cookie value (`A`, `10`), nil without one
---@field tags string[] own tags
---@field all_tags string[] own and inherited tags (file tags included), per `use_tag_inheritance`
---@field properties table<string, string> own properties (property drawer), names upper-cased
---@field scheduled org.api.Date|nil
---@field deadline org.api.Date|nil
---@field closed org.api.Date|nil
---@field file string|nil absolute path of the file (nil for a buffer without one)
---@field line integer line of the headline
---@field end_line integer last line of the subtree
---@field id string|nil the ID property
---@field category string
---@field outline_path string[] titles of the ancestors
---@field archived boolean has the ARCHIVE tag
---@field commented boolean a COMMENT headline
local Headline = {}
Headline.__index = Headline
M.Headline = Headline

---------------------------------------------------------------------------
-- Dates
---------------------------------------------------------------------------

--- The raw text of the `kind` planning timestamp of `hl`, as written (a
--- range `<...>--<...>` whole), found like the parser finds it.
local function planning_raw(hl, kind)
  local l = hl.planning_line and hl.file.lines[hl.planning_line]
  local key = kind:upper() .. ":"
  local s = l and l:find(key, 1, true)
  if not s then
    return nil
  end
  local rest = l:sub(s + #key)
  local item = require("org.date").parse_all(rest)[1]
  if item and rest:sub(1, item.start_col - 1):match("^%s*$") then
    return item.raw
  end
end

--- Plain-data date of an org.date timestamp.
---@param d table|nil
---@param raw? string
---@return org.api.Date|nil
function M.date(d, raw)
  if not d then
    return nil
  end
  local text = d:to_string()
  return {
    year = d.year,
    month = d.month,
    day = d.day,
    hour = d.hour,
    min = d.hour and (d.min or 0) or nil,
    end_hour = d.end_hour,
    end_min = d.end_hour and (d.end_min or 0) or nil,
    active = d.active ~= false,
    repeater = d.repeater and { type = d.repeater.type, value = d.repeater.value, unit = d.repeater.unit } or nil,
    warning = d.warning and { type = d.warning.type, value = d.warning.value, unit = d.warning.unit } or nil,
    date = d:to_date_string(),
    time = d.hour and string.format("%02d:%02d", d.hour, d.min or 0) or nil,
    timestamp = d:to_time(),
    text = text,
    raw = raw or text,
  }
end

--- `v` as an integer (a number or a numeric string), or nil.
local function integer(v)
  if type(v) == "string" then
    v = tonumber(v)
  end
  if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge or v ~= math.floor(v) then
    return nil
  end
  return v
end

local SPEC_TYPES = {
  repeater = { ["+"] = true, ["++"] = true, [".+"] = true },
  warning = { ["-"] = true, ["--"] = true },
}

--- `{ value, unit }` of a repeater, warning or habit maximum, or nil.
local function interval(s)
  local value = type(s) == "table" and integer(s.value)
  if value and value >= 0 and type(s.unit) == "string" and s.unit:match("^[hdwmy]$") then
    return { value = value, unit = s.unit }
  end
end

--- A copy of a repeater or warning `{ type, value, unit }` (a repeater
--- also with a habit's `max = { value, unit }`), or nil and an error when
--- it isn't one.
local function date_spec(s, what)
  local out = interval(s)
  local max = out and what == "repeater" and s.max ~= nil and interval(s.max)
  if not out or not SPEC_TYPES[what][s.type] or max == nil then
    return nil, "invalid date: the " .. what .. " " .. vim.inspect(s) .. " is not { type, value, unit }"
  end
  out.type, out.max = s.type, max or nil
  return out
end

--- An org.date timestamp from a table with year, month, day and optionally
--- hour, min, end_hour, end_min, active, repeater and warning. Fields out
--- of range roll over like os.time (day 32 of October is November 1, hour
--- 25 is 1:00 the next day); fields that aren't integers, an end time that
--- isn't a time of the day and years outside 1-9999 are errors.
local function date_from_table(v)
  local date = require("org.date")
  if v.year == nil or v.month == nil or v.day == nil then
    return nil, "a date needs year, month and day"
  end
  local f = {}
  for _, k in ipairs({ "year", "month", "day", "hour", "min", "end_hour", "end_min" }) do
    if v[k] ~= nil then
      f[k] = integer(v[k])
      if not f[k] then
        return nil, "invalid date: " .. k .. " is " .. vim.inspect(v[k]) .. ", not an integer"
      end
    end
  end
  local months = f.year * 12 + f.month - 1
  local minutes = f.hour and f.hour * 60 + (f.min or 0) or 0
  local days = date.days_from_civil(math.floor(months / 12), months % 12 + 1, 1) + f.day - 1
  local y, m, d = date.civil_from_days(days + math.floor(minutes / 1440))
  if y < 1 or y > 9999 then
    return nil, "invalid date: the year " .. y .. " is out of range"
  end
  local t = { year = y, month = m, day = d, active = v.active }
  if f.hour then
    minutes = minutes % 1440
    t.hour, t.min = math.floor(minutes / 60), minutes % 60
    if f.end_hour then
      t.end_hour, t.end_min = f.end_hour, f.end_min or 0
      if t.end_hour < 0 or t.end_min < 0 or t.end_min > 59 or t.end_hour * 60 + t.end_min > 1440 then
        return nil, string.format("invalid date: the end time %d:%02d is not a time of the day", t.end_hour, t.end_min)
      end
    end
  end
  for _, what in ipairs({ "repeater", "warning" }) do
    if v[what] ~= nil then
      local s, err = date_spec(v[what], what)
      if not s then
        return nil, err
      end
      t[what] = s
    end
  end
  return date.Date.new(t)
end

--- An org.date timestamp from what the API accepts as a date: an org.date
--- object, an |org.api.Date| (or any table with year, month, day and
--- optionally hour, min; see `date_from_table`), a Unix time, or a string:
--- a timestamp (`<2026-10-02 Fri>`, `2026-10-02 10:00`) or anything the
--- date prompt reads (`+2d`, `fri`, `10/5`).
---@param v any
---@return table|nil date, string|nil err
function M.to_date(v)
  local date = require("org.date")
  if v == nil then
    return nil, "no date"
  end
  if type(v) == "number" then
    local ok, d = false, nil
    if v == v and v ~= math.huge and v ~= -math.huge then
      ok, d = pcall(date.from_time, v, true)
    end
    if not ok or not d or not d.year or d.year < 1 or d.year > 9999 then
      return nil, "invalid date: " .. tostring(v)
    end
    return d
  elseif type(v) == "table" then
    if getmetatable(v) == date.Date then
      return v
    end
    return date_from_table(v)
  elseif type(v) == "string" then
    local s = vim.trim(v)
    local d = date.parse(s)
    if not d and not s:match("^[<%[]") then
      d = date.parse("<" .. s .. ">")
    end
    d = d or date.read_date((s:gsub("^[<%[]", ""):gsub("[>%]]$", "")))
    if not d then
      return nil, "invalid date: " .. v
    end
    -- a timestamp's day 29-31 that its month doesn't have rolls over
    -- (2026-02-30 is March 2), as at the date prompt
    if d.day > date.days_in_month(d.year, d.month) then
      local y, m, day = date.civil_from_days(date.days_from_civil(d.year, d.month, 1) + d.day - 1)
      d = d:clone({ year = y, month = m, day = day })
    end
    return d
  end
  return nil, "invalid date: " .. tostring(v)
end

---------------------------------------------------------------------------
-- Following headlines
---------------------------------------------------------------------------

-- While a handle's file is loaded in a buffer, an extmark follows its
-- headline's line through every edit, yours and the API's: from after the
-- line's first character (left gravity) to its end (right gravity). Lines
-- added or removed around it move it; edits inside the line leave its
-- start after the first star. Replacing the line (org rewrites a headline
-- line to change its keyword or tags) or deleting it puts the start at
-- column 0 for good, and a deletion collapses the mark. A handle read
-- from disk gets its mark when that version of the file is read into a
-- buffer; reading a buffer again (:e!) or unloading it drops its marks.
local ns = vim.api.nvim_create_namespace("org.api.headlines")

--- Private state of the live handles (weak keys: it goes with the handle):
--- `bufnr` the buffer of a handle without a file; `file`, `id`, `raw`,
--- `title` and `line` what identified its headline when last read;
--- `mark` `{ bufnr, extmark }` following that line; `stat` the version of
--- the file on disk `line` was read from (for a handle read from disk);
--- `gone` once the entry was archived; `proxy` a userdata whose finalizer
--- queues the mark for deletion when the handle is collected.
local priv = setmetatable({}, { __mode = "k" })

--- Marks of collected handles, deleted at the next call (the collector
--- may run where buffers can't be changed).
local dead = {}

local function flush_dead()
  if #dead == 0 then
    return
  end
  local list = dead
  dead = {}
  for _, m in ipairs(list) do
    if vim.api.nvim_buf_is_valid(m[1]) then
      pcall(vim.api.nvim_buf_del_extmark, m[1], ns, m[2])
    end
  end
end

local function state(self)
  local p = priv[self]
  if not p then
    p = {}
    priv[self] = p
  end
  return p
end

local function unmark(p)
  local m = p.mark
  p.mark = nil
  if m and vim.api.nvim_buf_is_valid(m[1]) then
    pcall(vim.api.nvim_buf_del_extmark, m[1], ns, m[2])
  end
end

--- Follow line `lnum` of `bufnr`, whose text is `line`, with the mark.
local function mark(p, bufnr, lnum, line)
  if p.mark and p.mark[1] ~= bufnr then
    unmark(p)
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, math.min(1, #line), {
    id = p.mark and p.mark[2] or nil,
    end_row = lnum - 1,
    end_col = #line,
    right_gravity = false,
    end_right_gravity = true,
  })
  if not ok then
    unmark(p)
    return
  end
  p.mark = { bufnr, id }
  if not p.proxy then
    local proxy = newproxy(true)
    getmetatable(proxy).__gc = function()
      if p.mark then
        dead[#dead + 1] = p.mark
      end
    end
    p.proxy = proxy
  end
end

--- Where the mark puts the headline in `bufnr`: its line, and how sure
--- that is. "same": the line was only edited inside (the mark's start is
--- still after the first star: a deleted line takes it to column 0 for
--- good). "gone": the line was deleted (the mark collapsed). "replaced":
--- the line was replaced, by org rewriting it (a TODO keyword, tags, a
--- statistics cookie) or by other text after it was deleted, which an
--- extmark can't tell apart. nil without a mark there.
---@return integer|nil lnum, string|nil how
local function marked(p, bufnr)
  local m = p.mark
  if not m or m[1] ~= bufnr then
    return nil
  end
  local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, ns, m[2], { details = true })
  if not ok or not pos or not pos[1] then
    p.mark = nil
    return nil
  end
  local r1, c1, d = pos[1], pos[2], pos[3] or {}
  if c1 > 0 then
    -- only stars before it, not the end of a line it was joined to
    local line = vim.api.nvim_buf_get_lines(bufnr, r1, r1 + 1, false)[1] or ""
    return r1 + 1, line:sub(1, c1):match("^%**$") and "same" or "replaced"
  elseif (d.end_row or r1) == r1 and (d.end_col or 0) == 0 then
    return r1 + 1, "gone"
  end
  return r1 + 1, "replaced"
end

--- Does no other headline of `f` have the plain title `title`?
local function unique_title(f, title)
  local n = 0
  for _, h in ipairs(f.headlines) do
    if h:plain_title() == title then
      n = n + 1
      if n > 1 then
        return false
      end
    end
  end
  return n == 1
end

--- The version of a file on disk (mtime and size), nil when it's missing.
local function stat_of(path)
  local st = path and vim.uv.fs_stat(path)
  return st and string.format("%d.%d:%d", st.mtime.sec, st.mtime.nsec, st.size) or nil
end

--- The version a file read from disk was parsed from (files.get() has
--- just checked it), once per parse.
local parsed_stats = setmetatable({}, { __mode = "k" })
local function parsed_stat(file)
  local s = parsed_stats[file]
  if s == nil then
    s = stat_of(file.filename) or false
    parsed_stats[file] = s
  end
  return s or nil
end

--- Does the handle's line still hold its headline? Known only for a
--- handle read from disk, while the file has that version and its buffer,
--- if loaded, has no changes.
local function trusted(p, bufnr)
  if not p.stat or (bufnr and vim.bo[bufnr].modified) then
    return false
  end
  return stat_of(p.file) == p.stat
end

local group = vim.api.nvim_create_augroup("org.api.headlines", { clear = true })

-- the buffer's text is read again or freed: its marks follow nothing
vim.api.nvim_create_autocmd({ "BufReadPre", "BufUnload" }, {
  group = group,
  callback = function(ev)
    if next(priv) == nil then
      return
    end
    for _, p in pairs(priv) do
      if p.mark and p.mark[1] == ev.buf then
        p.mark = nil
      end
    end
    pcall(vim.api.nvim_buf_clear_namespace, ev.buf, ns, 0, -1)
  end,
})

-- a file is read into a buffer: the handles read from this version of it
-- follow their headlines from now on
vim.api.nvim_create_autocmd("BufReadPost", {
  group = group,
  callback = function(ev)
    if next(priv) == nil then
      return
    end
    flush_dead()
    local now = stat_of(vim.api.nvim_buf_get_name(ev.buf))
    local here = {}
    for _, p in pairs(priv) do
      if now and p.stat == now and not p.mark and not p.gone then
        if here[p.file] == nil then
          here[p.file] = utils.find_buffer(p.file) == ev.buf
        end
        local line = here[p.file] and vim.api.nvim_buf_get_lines(ev.buf, p.line - 1, p.line, false)[1]
        if line and line == p.raw then
          mark(p, ev.buf, p.line, line)
        end
      end
    end
  end,
})

---------------------------------------------------------------------------
-- Making handles
---------------------------------------------------------------------------

local function fill(self, hl)
  flush_dead()
  for k in pairs(self) do
    self[k] = nil
  end
  local file = hl.file
  self.title = hl.title
  self.plain_title = hl:plain_title()
  self.raw = hl.raw
  self.level = hl.level
  self.todo = hl.todo
  self.done = hl:is_done()
  self.todo_type = hl.todo and (self.done and "done" or "todo") or nil
  self.priority = hl.priority
  self.tags = vim.deepcopy(hl.tags)
  self.all_tags = hl:get_tags()
  self.properties = vim.deepcopy(hl.properties)
  self.scheduled = M.date(hl.planning.scheduled, planning_raw(hl, "scheduled"))
  self.deadline = M.date(hl.planning.deadline, planning_raw(hl, "deadline"))
  self.closed = M.date(hl.planning.closed, planning_raw(hl, "closed"))
  self.file = file.filename
  self.line = hl.line
  self.end_line = hl.end_line
  self.id = hl.properties.ID
  self.category = hl:get_category()
  self.outline_path = hl:outline_path()
  self.archived = hl:is_archived()
  self.commented = hl.commented and true or false
  local p = state(self)
  p.bufnr = not file.filename and file.bufnr or nil
  p.file, p.id, p.raw, p.title, p.line = file.filename, self.id, hl.raw, self.plain_title, hl.line
  p.gone, p.stat = nil, nil
  local b = file.bufnr
  if b and vim.api.nvim_buf_is_loaded(b) and files.cached_buffer(b) == file then
    mark(p, b, hl.line, hl.raw)
  else
    unmark(p)
    if not b and file.filename then
      p.stat = parsed_stat(file)
    end
  end
  return self
end

--- A handle for a parsed headline.
---@param hl org.Headline
---@return org.api.Headline
function M.new(hl)
  return fill(setmetatable({}, Headline), hl)
end

---------------------------------------------------------------------------
-- Finding the headline again
---------------------------------------------------------------------------

--- What identifies a handle's headline (a copy of a handle has only its
--- fields).
local function identity(self)
  return priv[self] or { file = self.file, id = self.id, raw = self.raw, title = self.plain_title, line = self.line }
end

--- The buffer of the handle's file, loaded (hidden) when needed.
---@return integer|nil bufnr, string|nil err
local function buffer_of(self)
  local p = identity(self)
  if not p.file then
    if p.bufnr and vim.api.nvim_buf_is_valid(p.bufnr) then
      return p.bufnr
    end
    return nil, "the buffer of this headline is gone"
  end
  local b = utils.find_buffer(p.file)
  if b then
    return b
  end
  if not utils.exists(p.file) then
    return nil, "file not found: " .. p.file
  end
  local ok, res = pcall(utils.load_buffer, p.file)
  if not ok then
    return nil, "cannot load " .. p.file .. ": " .. tostring(res)
  end
  return res
end

local MOVED = "the headline moved; get a new handle: "

--- The handle's current headline in the parsed file `f` (from buffer
--- `bufnr` when it's loaded). Its ID decides when it has one (no entry
--- with it is an error, never another entry); otherwise its mark, or its
--- line while the file is still the version it was read from, or, when
--- neither knows, the one headline with its text. A headline that can't
--- be told apart is an error instead of a guess.
---@param f org.File
---@param bufnr? integer
---@return org.Headline|nil hl, string|nil err
local function locate(self, f, bufnr)
  flush_dead()
  local p = identity(self)
  if p.gone then
    return nil, "headline not found (it was archived): " .. p.raw
  end
  local lnum, how = marked(p, bufnr)
  if not how and trusted(p, bufnr) then
    lnum, how = p.line, "recorded"
  end
  local at = how and how ~= "gone" and f:headline_on(lnum) or nil
  if how == "recorded" and not (at and at.raw == p.raw) then
    at, how = nil, nil
  elseif at and how == "replaced" and not (at:plain_title() == p.title and unique_title(f, p.title)) then
    -- maybe another headline took its place
    at = nil
  end
  local hl
  if p.id then
    if at and at.properties.ID == p.id then
      hl = at
    else
      local n = 0
      for _, h in ipairs(f.headlines) do
        if h.properties.ID == p.id then
          hl, n = h, n + 1
        end
      end
      if n == 0 then
        return nil, "headline not found: no entry has the ID " .. p.id .. " (get a new handle)"
      elseif n > 1 then
        return nil, MOVED .. "several entries have the ID " .. p.id
      end
    end
  elseif at then
    hl = at
  elseif how == nil or how == "replaced" then
    -- nothing tells where it went: the one headline with its text
    for _, h in ipairs(f.headlines) do
      if h.raw == p.raw then
        if hl then
          return nil, MOVED .. p.raw
        end
        hl = h
      end
    end
    if not hl then
      return nil, "headline not found (it was changed or removed): " .. p.raw
    end
  else
    -- its line was deleted, or holds no headline any more
    return nil, MOVED .. p.raw
  end
  -- follow it from here
  if priv[self] and bufnr and not (how == "same" and lnum == hl.line) and files.cached_buffer(bufnr) == f then
    p.line, p.raw, p.title, p.stat = hl.line, hl.raw, hl:plain_title(), nil
    mark(p, bufnr, hl.line, hl.raw)
  end
  return hl
end

--- The buffer and current headline of a handle, or nil, nil and an error.
---@return integer|nil bufnr
---@return org.Headline|nil hl
---@return string|nil err
function M.resolve(self)
  local bufnr, err = buffer_of(self)
  if not bufnr then
    return nil, nil, err
  end
  local hl
  hl, err = locate(self, files.get_buffer(bufnr), bufnr)
  if not hl then
    return nil, nil, err
  end
  return bufnr, hl
end

--- The current headline of a handle, read from its buffer when loaded,
--- else from disk (nothing is loaded).
---@return org.Headline|nil hl, string|nil err
function M.find(self)
  local p = identity(self)
  local f
  if p.file then
    f = files.get(p.file)
  else
    f = p.bufnr and vim.api.nvim_buf_is_valid(p.bufnr) and files.get_buffer(p.bufnr) or nil
  end
  if not f then
    return nil, "cannot read " .. (p.file or "the buffer of this headline")
  end
  return locate(self, f, f.bufnr)
end

--- The last warning or error among collected messages.
local function last_problem(msgs)
  for i = #msgs, 1, -1 do
    if msgs[i].level >= vim.log.levels.WARN then
      return msgs[i].msg
    end
  end
end

--- The loaded buffers: whether each has unsaved changes, and its text's
--- version.
local function snapshot()
  local s = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      s[b] = { modified = vim.bo[b].modified, tick = vim.api.nvim_buf_get_changedtick(b) }
    end
  end
  return s
end

--- Save the files a change touched: the buffers of files it changed and
--- left unsaved (the headline's, a refile destination, the archive file,
--- the file whose clock a clock-in stopped). All of them or none: by
--- default none when one had unsaved changes before the change (`save`
--- true saves all, false none), so your edits aren't written behind your
--- back and an entry that moved to another file is never written out of
--- its file while it's only in a buffer there. The headline's own buffer
--- `own` goes last: when a save fails, it isn't written.
---@param own integer
---@param before table<integer, { modified: boolean, tick: integer }>
---@param save boolean|nil
---@return boolean|nil ok, string|nil err
local function save_touched(own, before, save)
  local touched, own_touched = {}, false
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local was = before[b]
    if
      vim.api.nvim_buf_is_loaded(b)
      and vim.bo[b].modified
      and vim.bo[b].buftype == ""
      and vim.api.nvim_buf_get_name(b) ~= ""
      and (not was or was.tick ~= vim.api.nvim_buf_get_changedtick(b))
    then
      if save == nil and was and was.modified then
        save = false
      end
      if b == own then
        own_touched = true
      else
        touched[#touched + 1] = b
      end
    end
  end
  if save == false then
    return true
  end
  if own_touched then
    touched[#touched + 1] = own
  end
  for _, b in ipairs(touched) do
    local ok, err = utils.save_buffer(b)
    if not ok then
      return nil, "could not save " .. vim.api.nvim_buf_get_name(b) .. ": " .. tostring(err)
    end
  end
  return true
end

--- Run `fn(target, hl)` on the handle's headline without prompting, then
--- save the files it touched (see `save_touched` and |org-api-saving|)
--- and refresh the handle from the line `fn` returns as its second value
--- (default: where the headline moved to; false: none). `fn` returns nil
--- for a failure. Returns fn's first value, or nil and an error message.
---@param opts? { save?: boolean }
---@return any res, string|nil err
function M.edit(self, opts, fn)
  opts = opts or {}
  local bufnr, hl, err = M.resolve(self)
  if not bufnr or not hl then
    return nil, err
  end
  local before = snapshot()
  local marks = require("org.marks")
  local mark = marks.set(bufnr, hl.line)
  local ok, msgs, res, where = utils.noninteractive(fn, { bufnr = bufnr, lnum = hl.line }, hl)
  local lnum = mark and mark:lnum()
  marks.del(mark)
  if not ok then
    return nil, tostring(res)
  end
  if res == nil then
    return nil, last_problem(msgs) or "the change was not made"
  end
  local wbuf = bufnr
  if type(where) == "table" then
    wbuf, lnum = where.bufnr, where.lnum
  end
  if where ~= false and lnum and vim.api.nvim_buf_is_valid(wbuf) then
    local now = files.get_buffer(wbuf):headline_on(lnum)
    if now then
      fill(self, now)
    end
  end
  local saved
  saved, err = save_touched(bufnr, before, opts.save)
  if not saved then
    return nil, err
  end
  return res
end

---------------------------------------------------------------------------
-- Methods
---------------------------------------------------------------------------

--- Read the headline again from its file.
---@return org.api.Headline|nil self, string|nil err
function Headline:reload()
  local hl, err = M.find(self)
  if not hl then
    return nil, err
  end
  return fill(self, hl)
end

--- The value of a property, special properties (`TODO`, `ALLTAGS`, ...)
--- included. `inherit` nil follows `use_property_inheritance`.
---@param name string
---@param inherit? boolean
---@return string|nil
function Headline:get_property(name, inherit)
  local hl = M.find(self)
  if not hl then
    return nil
  end
  return hl:get_property(name, inherit)
end

--- Change the TODO state (nil or "" removes the keyword), with the logging,
--- blocking, repeaters and statistics of C-c C-t. A note the logging asks
--- for is `opts.note`, else only the time is recorded.
---@param state string|nil
---@param opts? { note?: string, force?: boolean, save?: boolean }
---@return org.api.Headline|nil self, string|nil err
function Headline:set_todo(state, opts)
  opts = opts or {}
  local res, err = M.edit(self, opts, function(t)
    return require("org.todo").change_state(t, state or "", {
      note = opts.note,
      inhibit_note = opts.note == nil,
      force = opts.force,
    })
  end)
  return res and self, err
end

--- Is `tag` a name org reads back as a tag (see `tags.valid`)?
local function valid_tag(tag)
  return require("org.tags").valid(tag)
end

--- true, or nil and an error naming the first invalid tag of `tags`.
local function check_tags(tags)
  if type(tags) ~= "table" then
    return nil, "invalid tags: " .. vim.inspect(tags) .. ' (a list or a string such as ":a:b:")'
  end
  for _, t in ipairs(tags) do
    if not valid_tag(t) then
      return nil, "invalid tag " .. vim.inspect(t) .. " (letters, digits, _ @ # %)"
    end
  end
  return true
end

--- Replace the own tags. Tag names that org wouldn't read back as tags
--- (see `valid_tag`) are an error.
---@param tags string[]|string a list, or a string such as `":a:b:"`
---@param opts? { save?: boolean }
---@return org.api.Headline|nil self, string|nil err
function Headline:set_tags(tags, opts)
  local tagmod = require("org.tags")
  if type(tags) == "string" then
    tags = tagmod.parse_input(tags)
  end
  tags = tags or {}
  local ok, err = check_tags(tags)
  if not ok then
    return nil, err
  end
  local res
  res, err = M.edit(self, opts, function(t)
    return tagmod.set_tags(t, tags)
  end)
  return res and self, err
end

--- Add a tag to or remove it from the own tags the headline has now (not
--- the `tags` field, which may be older), like org-toggle-tag with `on`
--- or `off`. No change when it already has or lacks the tag.
local function toggle_tag(self, tag, on, opts)
  local ok, err = check_tags({ tag })
  if not ok then
    return nil, err
  end
  local res
  res, err = M.edit(self, opts, function(t, hl)
    if vim.tbl_contains(hl.tags, tag) == on then
      return true
    end
    local tags = vim.tbl_filter(function(x)
      return x ~= tag
    end, hl.tags)
    if on then
      tags[#tags + 1] = tag
    end
    return require("org.tags").set_tags(t, tags)
  end)
  return res and self, err
end

--- Add one tag to the own tags.
---@param tag string
---@param opts? { save?: boolean }
---@return org.api.Headline|nil self, string|nil err
function Headline:add_tag(tag, opts)
  return toggle_tag(self, tag, true, opts)
end

--- Remove one tag from the own tags.
---@param tag string
---@param opts? { save?: boolean }
---@return org.api.Headline|nil self, string|nil err
function Headline:remove_tag(tag, opts)
  return toggle_tag(self, tag, false, opts)
end

--- Set the priority (`"A"`, `"10"`, a number), or remove it with nil.
---@param priority string|integer|nil
---@param opts? { save?: boolean }
---@return org.api.Headline|nil self, string|nil err
function Headline:set_priority(priority, opts)
  local res, err = M.edit(self, opts, function(t)
    local prio = require("org.priority")
    if not prio.enabled() then
      -- removing fails too, like (org-priority 'remove)
      return nil
    end
    if priority == nil or priority == "" or priority == " " then
      prio.set(t, " ")
      return true
    end
    return prio.set(t, priority)
  end)
  return res and self, err
end

--- Set a property (nil removes it). `TODO`, `PRIORITY`, `SCHEDULED` and
--- `DEADLINE` change the entry like org-entry-put.
---@param name string
---@param value string|nil
---@param opts? { save?: boolean }
---@return org.api.Headline|nil self, string|nil err
function Headline:set_property(name, value, opts)
  local props = require("org.properties")
  local res, err = M.edit(self, opts, function(t)
    if value == nil then
      return props.delete_property(t, name)
    end
    return props.set_property(t, name, tostring(value))
  end)
  return res and self, err
end

local function plan(self, kind, value, opts)
  opts = opts or {}
  local d
  if value ~= nil and value ~= false then
    local err
    d, err = M.to_date(value)
    if not d then
      return nil, err
    end
  end
  local res, err = M.edit(self, opts, function(t)
    -- removing a date the entry doesn't have is no failure
    return require("org.timestamps").plan_date(t, kind, d, { note = opts.note or false }) or (d == nil or nil)
  end)
  return res and self, err
end

--- Schedule the entry (C-c C-s): nil removes the date. The old repeater
--- stays unless the new date has one. See `M.to_date` for the accepted
--- dates.
---@param value any|nil
---@param opts? { note?: string, save?: boolean }
---@return org.api.Headline|nil self, string|nil err
function Headline:schedule(value, opts)
  return plan(self, "scheduled", value, opts)
end

Headline.set_scheduled = Headline.schedule

--- Set the deadline (C-c C-d): nil removes it. (Not `deadline()`: that
--- name is the field.)
---@param value any|nil
---@param opts? { note?: string, save?: boolean }
---@return org.api.Headline|nil self, string|nil err
function Headline:set_deadline(value, opts)
  return plan(self, "deadline", value, opts)
end

--- Start the clock on the entry (org-clock-in). A clock running elsewhere
--- is stopped first.
---@param opts? { save?: boolean }
---@return org.api.Headline|nil self, string|nil err
function Headline:clock_in(opts)
  local clock = require("org.clock")
  local res, err = M.edit(self, opts, function(t)
    if clock.is_clocked_headline(t.bufnr, t.lnum) then
      return true
    end
    return clock.clock_in(t, { no_count = true })
  end)
  return res and self, err
end

--- Stop the clock when it runs on this entry (org-clock-out).
---@param opts? { note?: string, save?: boolean }
---@return integer|nil minutes, string|nil err
function Headline:clock_out(opts)
  opts = opts or {}
  local clock = require("org.clock")
  return M.edit(self, opts, function(t)
    if not clock.is_clocked_headline(t.bufnr, t.lnum) then
      utils.warn("The clock is not running on this entry")
      return nil
    end
    return clock.clock_out({ note = opts.note or false, quiet = true })
  end)
end

--- Is the running clock on this entry?
---@return boolean
function Headline:is_clocked_in()
  if not require("org.clock").state then
    return false
  end
  local bufnr, hl = M.resolve(self)
  if not bufnr or not hl then
    return false
  end
  return require("org.clock").is_clocked_headline(bufnr, hl.line)
end

--- Where a refile destination puts entries, as a refile target.
---@return table|nil dest, string|nil err
local function refile_dest(dest)
  if type(dest) == "string" then
    dest = { file = dest }
  end
  if type(dest) ~= "table" then
    return nil, "invalid refile destination"
  end
  if getmetatable(dest) == Headline then
    local bufnr, hl, err = M.resolve(dest)
    if not bufnr or not hl then
      return nil, err
    end
    return {
      bufnr = bufnr,
      filename = dest.file,
      lnum = hl.line,
      label = hl:plain_title(),
      path = hl:plain_title(),
    }
  end
  local path = dest.file and utils.expand(dest.file)
  if not path then
    return nil, "a refile destination needs a file or a headline"
  end
  path = vim.fs.normalize(path)
  if dest.headline then
    local f = files.get(path)
    local hl = f and f:find_by_title(dest.headline)
    if not hl then
      return nil, "no headline " .. vim.inspect(dest.headline) .. " in " .. path
    end
    return { filename = path, lnum = hl.line, label = hl:plain_title(), path = hl:plain_title() }
  end
  return { filename = path, label = vim.fn.fnamemodify(path, ":t"), path = vim.fn.fnamemodify(path, ":t") }
end

--- Move the subtree under another headline or to the top level of a file
--- (org-refile). `dest`: a headline handle, a file path, or
--- `{ file = path, headline = "Title" | { "Outline", "Path" } }`.
--- `opts.copy` keeps the original (org-refile-copy), `opts.prepend` makes
--- it the first child. The handle then points to the moved entry.
---@param dest org.api.Headline|string|{ file: string, headline?: string|string[] }
---@param opts? { copy?: boolean, prepend?: boolean, note?: string, save?: boolean }
---@return org.api.Headline|nil self, string|nil err
function Headline:refile(dest, opts)
  opts = opts or {}
  local d, derr = refile_dest(dest)
  if not d then
    return nil, derr
  end
  d.prepend = opts.prepend
  local res, err = M.edit(self, opts, function(t)
    local dbuf, dline = require("org.refile").refile(t, { dest = d, copy = opts.copy, note = opts.note or false })
    if not dbuf then
      return nil
    end
    if opts.copy then
      -- the handle stays on the original
      return true
    end
    return true, { bufnr = dbuf, lnum = dline }
  end)
  return res and self, err
end

--- Archive the subtree (org-archive-subtree, per `archive_location`).
--- Returns the archive file; the handle no longer points to an entry.
---@param opts? { save?: boolean }
---@return string|nil archive_file, string|nil err
function Headline:archive(opts)
  local res, err = M.edit(self, opts, function(t)
    local abuf = require("org.archive").archive_subtree(t)
    if not abuf then
      return nil
    end
    local name = vim.api.nvim_buf_get_name(abuf)
    return name ~= "" and vim.fs.normalize(name) or true, false
  end)
  if res then
    -- an archived copy with the same text or ID is not this handle's entry
    local p = state(self)
    p.gone = true
    unmark(p)
  end
  return res, err
end

--- Open the headline in a window and put the cursor on it. Also
--- `h["goto"](h)`: `goto` is a LuaJIT keyword, so `h:goto()` can't be
--- written.
---@param opts? { split?: "split"|"vsplit"|"tab" }
---@return org.api.Headline|nil self, string|nil err
function Headline:open(opts)
  opts = opts or {}
  local bufnr, hl, err = M.resolve(self)
  if not bufnr or not hl then
    return nil, err
  end
  if self.file then
    utils.open_file(self.file, hl.line, { split = opts.split, reuse_win = opts.split == nil })
  else
    if opts.split then
      vim.cmd(({ split = "split", vsplit = "vsplit", tab = "tab split" })[opts.split] or "split")
    end
    utils.set_current_buf(bufnr)
    vim.api.nvim_win_set_cursor(0, { hl.line, 0 })
    vim.cmd("normal! zv")
  end
  fill(self, hl)
  return self
end

Headline["goto"] = Headline.open

--- The ID property, or nil.
---@return string|nil
function Headline:get_id()
  local hl = M.find(self)
  if not hl then
    return nil
  end
  return hl.properties.ID
end

--- The ID property, created when missing (org-id-get-create).
---@param opts? { save?: boolean }
---@return string|nil id, string|nil err
function Headline:add_id(opts)
  return M.edit(self, opts, function(t)
    return require("org.id").get_create(t, false)
  end)
end

Headline.id_get_or_create = Headline.add_id

--- The parent headline, or nil at the top level.
---@return org.api.Headline|nil
function Headline:parent()
  local hl = M.find(self)
  if not hl then
    return nil
  end
  return hl.parent and M.new(hl.parent) or nil
end

--- The direct children.
---@return org.api.Headline[]
function Headline:children()
  local hl = M.find(self)
  if not hl then
    return {}
  end
  return vim.tbl_map(M.new, hl.children)
end

return M

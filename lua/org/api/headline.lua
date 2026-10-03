---@mod org.api.headline Headline handles of the public API
---
--- A handle is a plain table of fields (a snapshot taken when it was made)
--- with methods. The methods find the headline again in its file (by its
--- line, then its ID, then its text), run the same code as the keys and
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

-- private state of handles: { bufnr } (a buffer without a file)
local priv = setmetatable({}, { __mode = "k" })

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
-- Making handles
---------------------------------------------------------------------------

local function fill(self, hl)
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
  priv[self] = { bufnr = not file.filename and file.bufnr or nil }
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

--- The buffer of the handle's file, loaded (hidden) when needed.
---@return integer|nil bufnr, string|nil err
local function buffer_of(self)
  local p = priv[self] or {}
  if not self.file then
    if p.bufnr and vim.api.nvim_buf_is_valid(p.bufnr) then
      return p.bufnr
    end
    return nil, "the buffer of this headline is gone"
  end
  local b = utils.find_buffer(self.file)
  if b then
    return b
  end
  if not utils.exists(self.file) then
    return nil, "file not found: " .. self.file
  end
  local ok, res = pcall(utils.load_buffer, self.file)
  if not ok then
    return nil, "cannot load " .. self.file .. ": " .. tostring(res)
  end
  return res
end

--- The current headline of a handle in the parsed file `f`: on its line
--- when that still holds it, else the one with its ID, else the nearest
--- one with the same headline text.
---@param f org.File
---@return org.Headline|nil
local function locate(self, f)
  local hl = f:headline_on(self.line)
  if hl and hl.raw == self.raw then
    return hl
  end
  if self.id then
    hl = f:find_by_id(self.id)
    if hl then
      return hl
    end
  end
  local best
  for _, h in ipairs(f.headlines) do
    if h.raw == self.raw and (not best or math.abs(h.line - self.line) < math.abs(best.line - self.line)) then
      best = h
    end
  end
  return best
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
  local hl = locate(self, files.get_buffer(bufnr))
  if not hl then
    return nil, nil, "headline not found (it was changed or removed): " .. self.raw
  end
  return bufnr, hl
end

--- The current headline of a handle, read from its buffer when loaded,
--- else from disk (nothing is loaded).
---@return org.Headline|nil hl, string|nil err
function M.find(self)
  local f
  if self.file then
    f = files.get(self.file)
  else
    local b = (priv[self] or {}).bufnr
    f = b and vim.api.nvim_buf_is_valid(b) and files.get_buffer(b) or nil
  end
  if not f then
    return nil, "cannot read " .. (self.file or "the buffer of this headline")
  end
  local hl = locate(self, f)
  if not hl then
    return nil, "headline not found (it was changed or removed): " .. self.raw
  end
  return hl
end

--- The last warning or error among collected messages.
local function last_problem(msgs)
  for i = #msgs, 1, -1 do
    if msgs[i].level >= vim.log.levels.WARN then
      return msgs[i].msg
    end
  end
end

--- Run `fn(target, hl)` on the handle's headline without prompting, then
--- save its file (see |org-api-saving|) and refresh the handle from the
--- line `fn` returns as its second value (default: where the headline
--- moved to). `fn` returns nil for a failure. Returns fn's first value, or
--- nil and an error message.
---@param opts? { save?: boolean }
---@return any res, string|nil err
function M.edit(self, opts, fn)
  opts = opts or {}
  local bufnr, hl, err = M.resolve(self)
  if not bufnr or not hl then
    return nil, err
  end
  -- buffers with unsaved changes before the change aren't saved; the change
  -- may land in another buffer than the headline's (refile)
  local was_modified = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
      was_modified[b] = true
    end
  end
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
  for _, b in ipairs(vim.fn.uniq({ bufnr, wbuf })) do
    local save = opts.save
    if save == nil then
      save = not was_modified[b]
    end
    if save and vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) ~= "" then
      local saved, err = utils.save_buffer(b)
      if not saved then
        return nil, "could not save " .. vim.api.nvim_buf_get_name(b) .. ": " .. tostring(err)
      end
    end
  end
  if where ~= false and lnum and vim.api.nvim_buf_is_valid(wbuf) then
    local now = files.get_buffer(wbuf):headline_on(lnum)
    if now then
      fill(self, now)
    end
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

--- Is `tag` a name org reads back as a tag (org-tag-re `[[:alnum:]_@#%]`):
--- ASCII letters and digits, `_`, `@`, `#`, `%`, and letters and digits of
--- other scripts (no punctuation, symbols or emoji)?
local function valid_tag(tag)
  if type(tag) ~= "string" or tag == "" then
    return false
  end
  local i = 1
  while i <= #tag do
    local c = tag:byte(i)
    local n = c < 0x80 and 1 or c >= 0xF0 and 4 or c >= 0xE0 and 3 or c >= 0xC2 and 2 or 0
    local ch = n > 0 and tag:sub(i, i + n - 1) or ""
    if n == 1 then
      if not ch:match("^[%w_@#%%]$") then
        return false
      end
    elseif n == 0 or c > 0xF4 or #ch ~= n or not ch:match("^.[\128-\191]+$") then
      return false -- not UTF-8
    else
      -- Vim's character class: 2 a word character, above 3 a script's
      -- letters; 0 blanks, 1 punctuation and symbols, 3 emoji
      local class = vim.fn.charclass(ch)
      if class < 2 or class == 3 then
        return false
      end
    end
    i = i + n
  end
  return true
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

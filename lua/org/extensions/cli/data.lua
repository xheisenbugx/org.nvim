---@mod org.extensions.cli.data JSON data of the `org` command line
---
--- Turns headlines, timestamps and clocks into the plain tables `org ...
--- --json` prints (see `org schema` and `:h org-extensions-cli-json`).
--- Missing values are `vim.NIL` (JSON null), so every key of a schema is
--- always present.

local M = {}

local NULL = vim.NIL

--- `v`, or JSON null.
local function nn(v)
  if v == nil then
    return NULL
  end
  return v
end
M.nn = nn

--- An absolute, normalized path (or null).
function M.path(p)
  if not p or p == "" then
    return NULL
  end
  return vim.fs.normalize(vim.fn.fnamemodify(p, ":p"))
end

local function hm(h, m)
  return string.format("%02d:%02d", h, m or 0)
end

--- A date as ISO 8601: `2026-10-02`, or `2026-10-02T10:00` with a time
--- (local time, no offset).
---@param d table org.date
---@return string
function M.iso(d)
  local s = string.format("%04d-%02d-%02d", d.year, d.month, d.day)
  if d.hour then
    s = s .. "T" .. hm(d.hour, d.min)
  end
  return s
end

--- ISO date of a day number.
function M.iso_day(days)
  if not days then
    return NULL
  end
  local d = require("org.date").from_days(days)
  return string.format("%04d-%02d-%02d", d.year, d.month, d.day)
end

--- `HH:MM` of a number of minutes after midnight.
function M.hm(minutes)
  if not minutes then
    return NULL
  end
  return hm(math.floor(minutes / 60), minutes % 60)
end

--- A timestamp: its org text and its parts.
---@param d table|nil org.date
---@return table|userdata Timestamp or null
function M.timestamp(d)
  if type(d) ~= "table" or not d.year then
    return NULL
  end
  local end_iso
  if d.range_end then
    end_iso = M.iso(d.range_end)
  elseif d.end_hour then
    end_iso = string.format("%04d-%02d-%02dT%s", d.year, d.month, d.day, hm(d.end_hour, d.end_min))
  end
  local r, w = d.repeater, d.warning
  local repeater
  if r then
    repeater = r.type .. r.value .. r.unit
    if r.max then
      repeater = repeater .. "/" .. r.max.value .. r.max.unit
    end
  end
  return {
    raw = d:to_string(),
    date = d:to_date_string(),
    time = d.hour and hm(d.hour, d.min) or NULL,
    end_time = d.end_hour and hm(d.end_hour, d.end_min) or NULL,
    start = M.iso(d),
    ["end"] = nn(end_iso),
    active = d.active ~= false,
    repeater = nn(repeater),
    warning = w and (w.type .. w.value .. w.unit) or NULL,
  }
end

--- A list that encodes as a JSON array even when empty.
local function list(t)
  return t or {}
end

--- The summary of a headline (the `Headline` schema).
---@param hl org.Headline
---@return table
function M.headline(hl)
  local p = hl.planning or {}
  local todo_type = NULL
  if hl.todo then
    todo_type = hl:is_done() and "done" or "todo"
  end
  return {
    file = M.path(hl.file.filename),
    line = hl.line,
    end_line = hl.end_line,
    level = hl.level,
    id = nn(hl.properties.ID),
    custom_id = nn(hl.properties.CUSTOM_ID),
    todo = nn(hl.todo),
    todo_type = todo_type,
    priority = nn(hl.priority),
    title = hl:plain_title(),
    raw_title = hl.title,
    tags = list(hl:get_tags()),
    local_tags = list(vim.deepcopy(hl.tags)),
    category = nn(hl:get_category()),
    outline_path = list(hl:outline_path()),
    scheduled = M.timestamp(p.scheduled),
    deadline = M.timestamp(p.deadline),
    closed = M.timestamp(p.closed),
    archived = hl:is_archived(),
    commented = hl.commented and true or false,
  }
end

--- A duration in minutes as `H:MM`.
local function duration(minutes)
  return require("org.date").duration_to_string(minutes or 0)
end
M.duration = duration

--- The full data of a headline (the `Entry` schema): the summary plus
--- properties, effort, clocks, plain timestamps, body text and, with
--- `opts.children`, the child entries.
---@param hl org.Headline
---@param opts? { children?: boolean }
function M.entry(hl, opts)
  opts = opts or {}
  local d = M.headline(hl)
  local props = vim.empty_dict()
  for k, v in pairs(hl.properties or {}) do
    props[k] = v
  end
  d.properties = props
  local ok, effort = pcall(require("org.properties").effort_minutes, hl)
  d.effort_minutes = ok and nn(effort) or NULL
  local entries, running = {}, false
  for _, c in ipairs(hl.clocks or {}) do
    entries[#entries + 1] = {
      start = M.timestamp(c.start),
      ["end"] = M.timestamp(c["end"]),
      minutes = nn(c.minutes),
      line = c.line,
    }
    running = running or c["end"] == nil
  end
  local own = hl:clocked_minutes(nil, nil, false)
  local subtree = hl:clocked_minutes(nil, nil, true)
  d.clock = {
    count = #entries,
    running = running,
    minutes = own,
    total = duration(own),
    subtree_minutes = subtree,
    subtree_total = duration(subtree),
    entries = entries,
  }
  local stamps = {}
  for _, t in ipairs(hl.timestamps or {}) do
    stamps[#stamps + 1] = M.timestamp(t.date)
  end
  d.timestamps = stamps
  local body = hl:body_lines()
  d.body = table.concat(body, "\n")
  if opts.children then
    local children = {}
    for _, c in ipairs(hl.children or {}) do
      children[#children + 1] = M.entry(c, opts)
    end
    d.children = children
  else
    d.children = NULL
  end
  return d
end

return M

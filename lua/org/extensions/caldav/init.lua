---@mod org.extensions.caldav Two-way sync with CalDAV calendars
---
--- Enable with `extensions = { caldav = { calendars = { ... } } }` (see
--- `:h org-extensions-caldav`). Each calendar is a collection of a CalDAV
--- server tied to org files: its events become headings of the `inbox` file, entries of the
--- files become events, and changes travel both ways on `:Org caldav_sync`
--- (the model of Emacs's org-caldav). The parts: `http` (WebDAV through
--- curl), `ical` (components as fields), `entry` (org entries as fields)
--- and `sync`.

local MOD = "org.extensions.caldav"

local M = {}

--- See :h org-extensions-stability (scripts/extension_report.lua measures it).
M.stability = "experimental"

M.defaults = {
  --- The calendars: `{ name = "Personal", url = "https://.../personal/",
  --- user = "me", password = { "pass", "show", "dav" }, inbox =
  --- "~/org/calendar.org" }`. `url` is the calendar's collection
  --- (`:Org caldav_discover` lists them). `password` and `token` (a bearer
  --- token instead of user and password) are a string, a function, or a
  --- command whose first line of output is used. `inbox` is the file new
  --- events are added to, or `{ file = ..., headline = ... }`; `files` are
  --- more org files whose entries are sent. The options below `calendars`
  --- that say "per calendar" can be set in a calendar too.
  calendars = {},
  --- "twoway", "pull" (the calendar's changes only come to org) or "push"
  --- (org's changes only go to the calendar). Per calendar.
  direction = "twoway",
  --- Who wins when the same field changed on both sides: "local" (org, as
  --- org-caldav) or "remote". Per calendar.
  conflict = "local",
  --- What happens to an entry whose event was deleted in the calendar:
  --- "ask", "always" (delete it) or "never". Per calendar.
  delete_local = "ask",
  --- What happens to an event whose entry was deleted in org: "ask",
  --- "always" (delete it) or "never". Per calendar.
  delete_remote = "ask",
  --- Sync entries with a TODO keyword as tasks (VTODO). Per calendar.
  todos = false,
  --- Events that ended more than this many days ago are not picked up
  --- (false: everything). Per calendar.
  past_days = 30,
  --- Days ahead the occurrences of a repeating event are listed for, when
  --- its rule is one a repeater can't say.
  recurrence_days = 90,
  --- Minutes between syncs in the background (0: only `caldav_sync`).
  interval = 0,
  --- Save the org files a sync changed.
  save = true,
  --- Zone the timestamps are in (an IANA name); nil = the system's.
  timezone = nil,
  --- Extra TZID -> IANA zone names, for zones a calendar doesn't define.
  tz_aliases = {},
  --- Where the state of each calendar's last sync is kept.
  state_dir = vim.fn.stdpath("data") .. "/org/caldav",
  --- The program requests are sent with, and extra arguments for it.
  curl = { "curl" },
  --- Seconds before a request is given up.
  timeout = 60,
}

M.actions = {
  caldav_sync = { MOD, "sync", desc = "Sync the CalDAV calendars with their org files" },
  caldav_discover = { MOD, "discover", desc = "List the calendars of the CalDAV accounts" },
}

---@return table
function M.opts()
  return require("org.extensions").opts("caldav") or M.defaults
end

local function utils()
  return require("org.utils")
end

--- An option of calendar `c`: its own, else the extension's.
---@param c org.caldav.Calendar
---@param name string
---@return any
function M.opt(c, name)
  local v = c[name]
  if v == nil then
    v = M.opts()[name]
  end
  return v
end

--- The configured calendars (those with a url).
---@return org.caldav.Calendar[]
function M.calendars()
  local out = {}
  for i, c in ipairs(M.opts().calendars or {}) do
    if type(c) == "table" and type(c.url) == "string" and c.url ~= "" then
      c.name = c.name or ("calendar" .. i)
      out[#out + 1] = c
    end
  end
  return out
end

--- Names of the calendars (`:Org caldav_sync` completion).
---@return string[]
function M.calendar_names()
  return vim.tbl_map(function(c)
    return c.name
  end, M.calendars())
end

--- The inbox of a calendar: the file new events go to, and the heading
--- they go under (nil: the top level).
---@param c org.caldav.Calendar
---@return { file: string, headline?: string }|nil
function M.inbox_of(c)
  local inbox = c.inbox
  if type(inbox) == "string" and inbox ~= "" then
    return { file = utils().expand(inbox) }
  elseif type(inbox) == "table" and type(inbox.file) == "string" and inbox.file ~= "" then
    return { file = utils().expand(inbox.file), headline = inbox.headline }
  end
  return nil
end

--- What two spellings of one file have in common: its real path (links
--- and, where the file system folds case, the case it has on disk),
--- lower-cased on Windows.
---@param path string
---@return string
function M.same_file(path)
  local real = vim.uv.fs_realpath(path)
  local key = real and vim.fs.normalize(real) or path
  return vim.fn.has("win32") == 1 and key:lower() or key
end

--- The org files of a calendar, the inbox first.
---@param c org.caldav.Calendar
---@return string[]|nil paths, string|nil err
function M.files_of(c)
  local out, seen = {}, {}
  local inbox = M.inbox_of(c)
  if inbox then
    out[1] = inbox.file
    seen[M.same_file(inbox.file)] = true
  end
  for _, f in ipairs(c.files or {}) do
    local path = utils().expand(f)
    if not seen[M.same_file(path)] then
      if not vim.uv.fs_stat(path) and not utils().find_buffer(path) then
        return nil, path .. " not found"
      end
      seen[M.same_file(path)] = true
      out[#out + 1] = path
    end
  end
  if #out == 0 then
    return nil, "it has no inbox (the org file its events go to)"
  end
  return out, nil
end

--- The IANA name of the zone timestamps are in, when it can be told: the
--- `timezone` option, `$TZ`, or what `/etc/localtime` links to.
---@return string|nil
function M.zone_name()
  local parser = require("org.extensions.ics.parser")
  local name = M.opts().timezone
  if name then
    return parser.system_zone(name) and name or nil
  end
  local tz = (vim.env.TZ or ""):gsub("^:", "")
  if tz ~= "" then
    return parser.system_zone(tz) and tz or nil
  end
  local link = vim.uv.fs_realpath("/etc/localtime")
  local zone = link and link:match("zoneinfo/(.+)$")
  return zone and parser.system_zone(zone) and zone or nil
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

--- Action `caldav_sync`: sync every calendar now.
---@param done? fun(results: table[]|nil) called when all finished
---@param only? string only the calendar of that name
function M.sync(done, only)
  require("org.extensions.caldav.sync").run(only, { done = type(done) == "function" and done or nil })
end

--- `:Org caldav_sync [NAME]`.
---@param args? string
function M.sync_command(args)
  local name = vim.trim(args or "")
  M.sync(nil, name ~= "" and name or nil)
end

--- The text `caldav_discover` shows for the calendars found at `url`.
---@param url string
---@param found org.caldav.Collection[]
---@return string[]
function M.discover_lines(url, found)
  local lines = { "CalDAV calendars at " .. url, "" }
  if #found == 0 then
    lines[#lines + 1] = "None found. Give the address your provider documents for CalDAV."
  end
  local words = { VEVENT = "events", VTODO = "tasks", VJOURNAL = "journal" }
  for _, col in ipairs(found) do
    local holds = {}
    for _, comp in ipairs(col.components) do
      holds[#holds + 1] = words[comp] or comp:lower()
    end
    lines[#lines + 1] = col.name
    lines[#lines + 1] = "  url    " .. col.url
    lines[#lines + 1] = "  holds  " .. (#holds > 0 and table.concat(holds, ", ") or "?")
    lines[#lines + 1] = ""
  end
  return lines
end

--- Action `caldav_discover`: list the calendars of the account of each
--- configured calendar (`name`: of that one; or a URL, asked with the
--- credentials of the first calendar on that server), in a scratch
--- window. `done(lines)` is called instead when given.
---@param name? string
---@param done? fun(lines: string[])
function M.discover(name, done)
  local http = require("org.extensions.caldav.http")
  local u = utils()
  name = name and vim.trim(name) ~= "" and vim.trim(name) or nil
  ---@type org.caldav.Calendar[]
  local targets = {}
  if name and name:match("^https?://") then
    local like
    for _, c in ipairs(M.calendars()) do
      if http.origin(c.url) == http.origin(name) then
        like = c
        break
      end
    end
    local t = vim.deepcopy(like or {})
    t.name, t.url = like and like.name or name, name
    targets[1] = t
  else
    local seen = {}
    for _, c in ipairs(M.calendars()) do
      local key = http.origin(c.url) .. "\0" .. (c.user or "")
      if (name == nil and not seen[key]) or c.name == name then
        seen[key] = true
        targets[#targets + 1] = c
      end
    end
  end
  if #targets == 0 then
    u.warn(name and ("caldav: no calendar named " .. name) or "caldav: no calendars (set extensions.caldav.calendars)")
    return
  end
  u.run(function()
    local lines = {}
    for _, c in ipairs(targets) do
      local found, err = http.discover(c)
      if found then
        vim.list_extend(lines, M.discover_lines(c.url, found))
      else
        vim.list_extend(lines, { "CalDAV calendars at " .. c.url, "", "Failed: " .. (err or "?"), "" })
      end
    end
    if type(done) == "function" then
      return done(lines)
    end
    vim.cmd("botright new")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
    vim.bo[buf].modifiable = false
    pcall(vim.api.nvim_buf_set_name, buf, "CalDAV calendars")
    vim.keymap.set("n", "q", "<Cmd>close<CR>", { buffer = buf, nowait = true, desc = "org: close" })
    vim.keymap.set("n", "<Esc>", "<Cmd>close<CR>", { buffer = buf, nowait = true, desc = "org: close" })
  end)
end

--- `:Org caldav_discover [NAME|URL]`.
---@param args? string
function M.discover_command(args)
  M.discover(args)
end

M.commands = {
  caldav_sync = {
    MOD,
    "sync_command",
    desc = "Sync the CalDAV calendars: :Org caldav_sync [calendar]",
    complete = function()
      return M.calendar_names()
    end,
  },
  caldav_discover = {
    MOD,
    "discover_command",
    desc = "List the calendars of a CalDAV account: :Org caldav_discover [calendar|url]",
    complete = function()
      return M.calendar_names()
    end,
  },
}

---------------------------------------------------------------------------
-- Extension
---------------------------------------------------------------------------

local timer

local function stop_timer()
  if timer then
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
    timer = nil
  end
end

-- the timer's sync: never raises (an error would repeat every time)
local function tick()
  pcall(function()
    require("org.extensions.caldav.sync").run(nil, { auto = true })
  end)
end
M._tick = tick

---@param o table
function M.setup(o)
  require("org.extensions.caldav.http").forget_secrets()
  require("org.extensions.caldav.sync").reset()
  stop_timer()
  local minutes = tonumber(o.interval) or 0
  if minutes > 0 and #M.calendars() > 0 then
    timer = assert(vim.uv.new_timer())
    timer:start(minutes * 60000, minutes * 60000, vim.schedule_wrap(tick))
  end
end

function M.teardown()
  stop_timer()
  require("org.extensions.caldav.http").forget_secrets()
end

local CHOICES = {
  direction = { "twoway", "pull", "push" },
  conflict = { "local", "remote" },
  delete_local = { "ask", "always", "never" },
  delete_remote = { "ask", "always", "never" },
}

-- the keys of a calendar (setup() only checks the extension's own options)
local KEYS = {
  "name",
  "url",
  "user",
  "password",
  "token",
  "auth",
  "headers",
  "inbox",
  "files",
  "direction",
  "conflict",
  "delete_local",
  "delete_remote",
  "todos",
  "past_days",
}

---@param h table vim.health
---@param o table
function M.health(h, o)
  local cals = M.calendars()
  if #cals == 0 then
    h.warn("caldav: no calendars (set extensions.caldav.calendars)")
    return
  end
  local exe = (o.curl or {})[1] or "curl"
  if vim.fn.executable(exe) == 1 then
    h.ok("caldav: " .. exe .. " found")
  else
    h.error("caldav: " .. exe .. " not found: the calendars can't be reached")
  end
  local sync = require("org.extensions.caldav.sync")
  local owner = {}
  for _, c in ipairs(cals) do
    local problems = {}
    if not c.url:match("^https?://") then
      problems[#problems + 1] = "its url is not an http(s) address"
    end
    if not c.token and not c.user and not next(c.headers or {}) then
      h.info(
        string.format(
          "caldav: %s: no user or token (fine for a server that asks for none, or with curl --netrc)",
          c.name
        )
      )
    end
    local paths, err = M.files_of(c)
    if not paths then
      problems[#problems + 1] = err
    end
    for _, path in ipairs(paths or {}) do
      local key = M.same_file(path)
      if owner[key] and owner[key] ~= c.name then
        problems[#problems + 1] = string.format("%s is also a file of %s", utils().abbreviate(path), owner[key])
      end
      owner[key] = c.name
    end
    for key in pairs(c) do
      if not vim.tbl_contains(KEYS, key) then
        problems[#problems + 1] = string.format("%s is not an option of a calendar", tostring(key))
      end
    end
    for name, choices in pairs(CHOICES) do
      local v = M.opt(c, name)
      if not vim.tbl_contains(choices, v) then
        problems[#problems + 1] =
          string.format("%s = %s is not one of %s", name, vim.inspect(v), table.concat(choices, ", "))
      end
    end
    if #problems > 0 then
      table.sort(problems)
      h.error(string.format("caldav: %s: %s", c.name, table.concat(problems, "; ")))
    else
      local st = sync.load_state(c)
      local last = sync.last[c.name]
      local n = vim.tbl_count(st.items)
      if last and last.result.failed then
        h.warn(string.format("caldav: %s: the last sync failed: %s", c.name, last.result.failed))
      elseif st.synced then
        h.ok(string.format("caldav: %s: %d synced, last on %s", c.name, n, os.date("%Y-%m-%d %H:%M", st.synced)))
      else
        h.info(string.format("caldav: %s: not synced yet (run :Org caldav_sync)", c.name))
      end
    end
  end
  if o.timezone and not require("org.extensions.ics.parser").system_zone(o.timezone) then
    h.warn("caldav: timezone " .. o.timezone .. " is not in the system time zone database")
  elseif not M.zone_name() then
    -- (Windows has no $TZ or /etc/localtime to tell it by)
    h.info("caldav: the name of your time zone isn't known, so a new repeating event is sent in UTC; set `timezone`")
  end
end

return M

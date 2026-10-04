---@mod org.agenda.index The agenda index (|org-agenda-index|)
---
--- Most of the time of a first agenda view over many files goes into
--- parsing them: reading each file, then its headlines and sections. The
--- index keeps what that parse finds (the parts of each headline and of
--- its section, see parser.LAZY_FIELDS) in a file under stdpath("cache"),
--- so a later session only reads the files, finds their outline and fills
--- in the rest; and it parses the agenda files in the background, a few at
--- a time, so that the first agenda view finds them parsed already.
---
--- Nothing here decides what the agenda shows. An entry is used only for
--- the same file contents (mtime, ctime and size, the number of lines, each
--- headline's line and text) parsed under the same settings (the parser's
--- code, the options it reads, the file's TODO keywords); anything else is
--- a miss, and the file is parsed as without the index. A loaded buffer is
--- always parsed from the buffer (org.files). Watchers on the agenda
--- directories only make the background parse changed files again early.

local utils = require("org.utils")
local uv = vim.uv

local M = {}

-- Bumped when what an entry holds changes.
local VERSION = 1
-- Main-loop time for one slice of background parsing, and the pause
-- between slices (typing goes in between).
local SLICE_MS, PAUSE_MS = 8, 2
-- Files stat-ed or read at the same time in the background.
local IN_FLIGHT = 8
-- A save waits for this long after the last change.
local SAVE_DELAY = 2000
-- The entries are let go this long after their last use.
local RELEASE_DELAY = 60000
-- Entries of files no agenda has used for this long are dropped on save.
local PRUNE_SECONDS = 30 * 86400
-- Changes reported by a watcher are collected for this long.
local DEBOUNCE_MS = 200

local has_buffer, sbuf = pcall(require, "string.buffer")

-- Keys of the encoded headline records, sent as indices (string.buffer's
-- `dict`): part of the format, so of the signature.
local DICT = {
  "_l",
  "_r",
  "active",
  "clocks",
  "commented",
  "date",
  "day",
  "drawers",
  "end",
  "end_col",
  "end_hour",
  "end_min",
  "first_inactive",
  "hour",
  "in_title",
  "line",
  "logbook",
  "min",
  "minutes",
  "month",
  "name",
  "planning",
  "planning_line",
  "priority",
  "properties",
  "properties_extend",
  "properties_range",
  "property_base",
  "range_end",
  "repeater",
  "start",
  "start_col",
  "tags",
  "timestamps",
  "title",
  "todo",
  "type",
  "unit",
  "value",
  "warning",
  "year",
  "closed",
  "deadline",
  "scheduled",
  "max",
}

---@class org.agenda.index.Entry
---@field ms integer mtime seconds
---@field mn integer mtime nanoseconds
---@field cs integer ctime seconds
---@field cn integer ctime nanoseconds
---@field s integer size
---@field n integer number of lines
---@field k string the file's TODO keywords
---@field t integer when an agenda last used it (os.time())
---@field d string the encoded headline records

local S = {
  ---@type table<string, org.agenda.index.Entry>|nil path -> entry, nil until loaded
  entries = nil,
  sig = nil, ---@type string|nil the signature the entries were made under
  dirty = false,
  -- the background queue: paths to stat, then to read, then to parse
  queue = {}, ---@type string[]
  head = 1,
  queued = {}, ---@type table<string, boolean>
  stated = {}, ---@type { path: string, st: uv.fs_stat.result|nil }[]
  ready = {}, ---@type { path: string, st: uv.fs_stat.result, data: string }[]
  in_flight = 0,
  gen = 0, -- bumped by stop(): what was in flight before is dropped
  saving = 0, -- background saves not done yet
  warming = false,
  pump_timer = nil, ---@type uv.uv_timer_t|nil
  save_timer = nil, ---@type uv.uv_timer_t|nil
  release_timer = nil, ---@type uv.uv_timer_t|nil
  poll_timer = nil, ---@type uv.uv_timer_t|nil
  debounce_timer = nil, ---@type uv.uv_timer_t|nil
  known = {}, ---@type table<string, boolean> the agenda files the background knows
  watchers = {}, ---@type table<string, uv.uv_fs_event_t> directory -> watcher
  polled = {}, ---@type table<string, boolean> directories polled instead
  changed = {}, ---@type table<string, boolean> paths reported by watchers
  rescan = false, -- a watcher saw a file come or go
  announce = false, -- say when the queue is done (a rebuild)
  stats = { hits = 0, misses = 0, indexed = 0, saved = nil, error = nil },
}

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

--- `agenda.index` (false: off). Without the table (an `agenda` table set
--- wholesale, as tests do) the index is off.
---@return table
local function opts()
  local agenda = require("org.config").opts.agenda
  local o = type(agenda) == "table" and agenda.index or nil
  if type(o) ~= "table" then
    return { enabled = false }
  end
  return o
end

--- Whether the index is on (`agenda.index.enabled`).
---@return boolean
function M.enabled()
  return opts().enabled ~= false
end

--- Whether entries are kept on disk: `agenda.index.cache`, with
--- LuaJIT's string.buffer (Neovim built with PUC Lua has none).
---@return boolean
local function use_cache()
  local o = opts()
  return has_buffer and o.enabled ~= false and o.cache ~= false
end

--- Whether agenda files are parsed in the background.
---@return boolean
local function background()
  local o = opts()
  return o.enabled ~= false and o.background ~= false
end

--- The file the index is kept in.
---@return string
function M.path()
  return vim.fs.joinpath(vim.fn.stdpath("cache") --[[@as string]], "org", "agenda-index.bin")
end

---------------------------------------------------------------------------
-- Signature: what the parse depends on besides the text
---------------------------------------------------------------------------

local code_sig ---@type string|nil

--- The version, the LuaJIT version and the parser's source files (their
--- size and mtime): an entry made by another version is never used.
---@return string
local function code_signature()
  if not code_sig then
    local parts = { tostring(VERSION), jit and jit.version or _VERSION, table.concat(DICT, ",") }
    for _, f in ipairs({ "parser", "date", "agenda/index", "todo_keywords", "keywords" }) do
      local src = vim.api.nvim_get_runtime_file("lua/org/" .. f .. ".lua", false)[1]
      local st = src and uv.fs_stat(src)
      parts[#parts + 1] = st and (st.size .. ":" .. st.mtime.sec .. ":" .. st.mtime.nsec) or "-"
    end
    code_sig = table.concat(parts, "|")
  end
  return code_sig
end

local last_sig = { key = {}, sig = "" }

--- The signature of the options the parse reads, and of the code.
---@return string
local function signature()
  local cfg = require("org.config").opts
  local key = { cfg.todo_keywords, cfg.log_into_drawer, cfg.inlinetask_min_level, cfg.property_separators }
  local k = last_sig.key
  if k[1] == key[1] and k[2] == key[2] and k[3] == key[3] and k[4] == key[4] and last_sig.sig ~= "" then
    return last_sig.sig
  end
  local sig = code_signature() .. "|" .. vim.inspect(key, { newline = "", indent = "" })
  last_sig = { key = key, sig = sig }
  return sig
end

--- The file's TODO keywords (the headline lines are parsed with them).
---@param file org.File
---@return string
local function todo_signature(file)
  local todo = file.settings and file.settings.todo
  return todo and table.concat(todo:names(), " ") or ""
end

---------------------------------------------------------------------------
-- Entries
---------------------------------------------------------------------------

local codec ---@type string.buffer|nil

--- The string.buffer that encodes headline records (dates keep their
--- metatable).
---@return string.buffer
local function get_codec()
  if not codec then
    codec = sbuf.new({ metatable = { require("org.date").Date }, dict = DICT })
  end
  return codec
end

---@param a uv.fs_stat.result
---@param b uv.fs_stat.result
---@return boolean
local function same_stat(a, b)
  return a.size == b.size
    and a.mtime.sec == b.mtime.sec
    and a.mtime.nsec == b.mtime.nsec
    and a.ctime.sec == b.ctime.sec
    and a.ctime.nsec == b.ctime.nsec
end

---@param e any
---@param st uv.fs_stat.result
---@return boolean
local function entry_matches(e, st)
  return type(e) == "table"
    and e.s == st.size
    and e.ms == st.mtime.sec
    and e.mn == st.mtime.nsec
    and e.cs == st.ctime.sec
    and e.cn == st.ctime.nsec
end

local function stop_timer(name)
  local t = S[name]
  if t then
    t:stop()
    if not t:is_closing() then
      t:close()
    end
    S[name] = nil
  end
end

--- Run `fn` on the main loop in `ms` milliseconds, replacing what the
--- timer `name` was waiting for.
local function after(name, ms, fn)
  local t = S[name]
  if not t then
    t = assert(uv.new_timer())
    S[name] = t
  end
  t:stop()
  t:start(ms, 0, vim.schedule_wrap(fn))
end

--- Let go of the entries a while after their last use (they can be
--- large; the parsed files stay in org.files).
local function release_later()
  after("release_timer", RELEASE_DELAY, function()
    if not S.dirty and not S.warming then
      S.entries = nil
    end
  end)
end

--- The entries, read from disk on first use. An unreadable, partly
--- written or foreign file, or one made under another signature, gives
--- none (it is replaced on the next save).
---@return table<string, org.agenda.index.Entry>
local function load()
  local sig = signature()
  if S.entries and S.sig == sig then
    release_later()
    return S.entries
  end
  if S.entries and S.sig ~= sig then
    -- the options changed: every entry is out of date
    S.dirty = true
  end
  S.entries, S.sig = {}, sig
  release_later()
  if not use_cache() then
    return S.entries
  end
  local fd = io.open(M.path(), "rb")
  if not fd then
    return S.entries
  end
  local data = fd:read("*a")
  fd:close()
  local ok, t = pcall(sbuf.decode, data or "")
  if ok and type(t) == "table" and t.version == VERSION and t.sig == sig and type(t.files) == "table" then
    S.entries = t.files
  end
  return S.entries
end

--- Fill in the headlines of `file` (parsed from `path`, whose fs_stat is
--- `st`) from its entry. Every headline must be where and what it was.
---@param path string
---@param st uv.fs_stat.result
---@param file org.File
---@return boolean applied
local function apply(path, st, file)
  local entries = load()
  local e = entries[path]
  if not entry_matches(e, st) or e.n ~= #file.lines or e.k ~= todo_signature(file) then
    return false
  end
  local ok, recs = pcall(function()
    return get_codec():set(e.d):decode()
  end)
  local headlines = file.headlines
  if not ok or type(recs) ~= "table" or #recs ~= #headlines then
    entries[path] = nil
    S.dirty = true
    return false
  end
  for i, hl in ipairs(headlines) do
    local r = recs[i]
    if type(r) ~= "table" or r._l ~= rawget(hl, "line") or r._r ~= rawget(hl, "raw") then
      return false
    end
  end
  local parser = require("org.parser")
  for i, hl in ipairs(headlines) do
    parser.restore(hl, recs[i])
  end
  local now = os.time()
  if now - (tonumber(e.t) or 0) > 86400 then
    e.t = now
    S.dirty = true
  end
  return true
end

local schedule_save

--- Parse all of `file` now (it was just parsed from `path`, and nothing
--- has read it yet) and, with `cache`, add it to the index.
---@param path string
---@param st uv.fs_stat.result
---@param file org.File
local function add(path, st, file)
  local parser = require("org.parser")
  local fields = parser.LAZY_FIELDS
  local recs = {}
  for i, hl in ipairs(file.headlines) do
    parser.load_all(hl)
    local r = { _l = rawget(hl, "line"), _r = rawget(hl, "raw") }
    for _, k in ipairs(fields) do
      r[k] = rawget(hl, k)
    end
    recs[i] = r
  end
  if not use_cache() then
    return
  end
  local ok, blob = pcall(function()
    return get_codec():reset():encode(recs):tostring()
  end)
  if not ok then
    return
  end
  load()[path] = {
    ms = st.mtime.sec,
    mn = st.mtime.nsec,
    cs = st.ctime.sec,
    cn = st.ctime.nsec,
    s = st.size,
    n = #file.lines,
    k = todo_signature(file),
    t = os.time(),
    d = blob,
  }
  S.dirty = true
  S.stats.indexed = S.stats.indexed + 1
  schedule_save()
end

---------------------------------------------------------------------------
-- Saving
---------------------------------------------------------------------------

--- The index file's contents, without entries unused for PRUNE_SECONDS.
---@return string|nil
local function encode_all()
  local entries = S.entries
  if not entries then
    return nil
  end
  local now = os.time()
  for path, e in pairs(entries) do
    if type(e) ~= "table" or now - (tonumber(e.t) or 0) > PRUNE_SECONDS then
      entries[path] = nil
    end
  end
  local ok, data = pcall(sbuf.encode, { version = VERSION, sig = S.sig, files = entries })
  return ok and data or nil
end

local tmp_count = 0

--- A temporary file next to the index (renamed over it: a reader sees the
--- old file or the new one, never part of one).
---@return string
local function tmp_path()
  tmp_count = tmp_count + 1
  return ("%s.%d.%d.tmp"):format(M.path(), uv.os_getpid(), tmp_count)
end

--- Write the index now, if it changed (VimLeavePre, tests).
---@return boolean saved
function M.flush()
  stop_timer("save_timer")
  if not (S.dirty and use_cache()) then
    return false
  end
  local data = encode_all()
  if not data then
    return false
  end
  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = tmp_path()
  local fd = uv.fs_open(tmp, "w", 420)
  local ok = fd and uv.fs_write(fd, data, 0) == #data
  if fd then
    uv.fs_close(fd)
  end
  ok = ok and uv.fs_rename(tmp, path)
  if not ok then
    uv.fs_unlink(tmp)
    S.stats.error = "could not write " .. path
    return false
  end
  S.dirty = false
  S.stats.saved = os.time()
  return true
end

--- Write the index in the background, if it changed.
local function save_async()
  if not (S.dirty and use_cache()) then
    return
  end
  local data = encode_all()
  if not data then
    return
  end
  S.dirty = false
  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = tmp_path()
  S.saving = S.saving + 1
  local function fail(fd)
    if fd then
      uv.fs_close(fd)
    end
    uv.fs_unlink(tmp)
    vim.schedule(function()
      S.saving = S.saving - 1
      S.dirty = true
      S.stats.error = "could not write " .. path
    end)
  end
  uv.fs_open(tmp, "w", 420, function(err, fd)
    if err or not fd then
      return fail()
    end
    uv.fs_write(fd, data, 0, function(werr, n)
      if werr or n ~= #data then
        return fail(fd)
      end
      uv.fs_close(fd, function()
        uv.fs_rename(tmp, path, function(rerr)
          if rerr then
            return fail()
          end
          vim.schedule(function()
            S.saving = S.saving - 1
            S.stats.saved = os.time()
            S.stats.error = nil
          end)
        end)
      end)
    end)
  end)
end

--- Save a while after the last change (after the background queue is done).
function schedule_save()
  if not use_cache() then
    return
  end
  after("save_timer", SAVE_DELAY, function()
    if S.warming then
      return -- the end of the queue saves
    end
    save_async()
  end)
end

---------------------------------------------------------------------------
-- Parsing on the main path (org.files)
---------------------------------------------------------------------------

local enqueue

--- Called by org.files for an agenda file it just parsed from disk (`st`:
--- its fs_stat before it was read), before anything reads the parse:
--- fills it from the index, or, on a miss, adds it (or has the background
--- add it).
---@param path string
---@param st uv.fs_stat.result
---@param file org.File
function M.parsed(path, st, file)
  if not M.enabled() then
    return
  end
  local ok, err = pcall(function()
    local now = uv.fs_stat(path)
    if not (now and same_stat(st, now)) then
      return -- changed while it was read: the text may not be that of `st`
    end
    if use_cache() and apply(path, st, file) then
      S.stats.hits = S.stats.hits + 1
      return
    end
    S.stats.misses = S.stats.misses + 1
    if background() then
      S.known[path] = true
      enqueue(path)
    elseif use_cache() then
      add(path, st, file)
    end
  end)
  if not ok then
    S.stats.error = tostring(err)
  end
end

---------------------------------------------------------------------------
-- The background
---------------------------------------------------------------------------

local pump

--- Have the next slice run soon.
local function wake()
  if S.pump_timer and S.pump_timer:get_due_in() > 0 then
    return
  end
  after("pump_timer", PAUSE_MS, pump)
end

function enqueue(path)
  if S.queued[path] then
    return
  end
  S.queued[path] = true
  S.queue[#S.queue + 1] = path
  S.warming = true
  wake()
end

--- Whether `path` needs reading: not in a buffer (parsed from there),
--- and not both parsed already and indexed.
---@param path string
---@param st uv.fs_stat.result
---@return boolean
local function wanted(path, st)
  if utils.find_buffer(path) then
    return false
  end
  if not require("org.files").cached(path, st) then
    return true
  end
  return use_cache() and not entry_matches(load()[path], st)
end

--- Read `path` (whose fs_stat is `st`) in the background; it goes to
--- S.ready when it is still that file once read.
---@param path string
---@param st uv.fs_stat.result
local function read_async(path, st)
  S.in_flight = S.in_flight + 1
  local gen = S.gen
  local function done(data, retry)
    S.in_flight = S.in_flight - 1
    if gen ~= S.gen then
      return
    end
    if data then
      S.ready[#S.ready + 1] = { path = path, st = st, data = data }
    end
    vim.schedule(function()
      if retry then
        enqueue(path)
      end
      wake()
    end)
  end
  uv.fs_open(path, "r", 438, function(oerr, fd)
    if oerr or not fd then
      return done()
    end
    local function close(data, retry)
      uv.fs_close(fd, function()
        done(data, retry)
      end)
    end
    uv.fs_fstat(fd, function(e1, st1)
      if e1 or not st1 or not same_stat(st, st1) then
        return close(nil, true)
      end
      uv.fs_read(fd, st.size, 0, function(rerr, data)
        if rerr or not data or #data ~= st.size then
          return close(nil, true)
        end
        uv.fs_fstat(fd, function(e2, st2)
          if e2 or not st2 or not same_stat(st, st2) then
            return close(nil, true)
          end
          close(data)
        end)
      end)
    end)
  end)
end

--- Parse a file read in the background and hand it to org.files.
---@param item { path: string, st: uv.fs_stat.result, data: string }
local function parse_ready(item)
  local path, st = item.path, item.st
  if not wanted(path, st) then
    return
  end
  local file = require("org.parser").parse(utils.split_content(item.data), path)
  if use_cache() and apply(path, st, file) then
    S.stats.hits = S.stats.hits + 1
  else
    add(path, st, file)
  end
  require("org.files").install(path, st, file)
end

local start_watching

--- The queue is done: save, and watch the files for changes.
local function finish()
  S.warming = false
  save_async()
  release_later()
  if S.announce then
    S.announce = false
    utils.notify(("Agenda index: %d files indexed"):format(vim.tbl_count(S.known)))
  end
  if opts().watch ~= false then
    start_watching()
  end
end

--- One slice of background work: start stats and reads, then parse
--- what was read, for at most SLICE_MS.
function pump()
  if not background() then
    S.queue, S.head, S.queued, S.stated, S.ready, S.warming = {}, 1, {}, {}, {}, false
    return
  end
  local deadline = uv.hrtime() + SLICE_MS * 1e6
  -- decide on what was stat-ed: read it, or not
  while #S.stated > 0 do
    local item = table.remove(S.stated)
    if item.st and item.st.type == "file" and wanted(item.path, item.st) then
      read_async(item.path, item.st)
    elseif not item.st then
      -- gone: let go of its parse
      require("org.files").invalidate(item.path)
    end
  end
  -- stat the next files
  while S.in_flight < IN_FLIGHT and S.head <= #S.queue do
    local path = S.queue[S.head]
    S.head = S.head + 1
    S.queued[path] = nil
    S.in_flight = S.in_flight + 1
    local gen = S.gen
    uv.fs_stat(path, function(_, st)
      S.in_flight = S.in_flight - 1
      if gen ~= S.gen then
        return
      end
      S.stated[#S.stated + 1] = { path = path, st = st }
      vim.schedule(wake)
    end)
  end
  if S.head > #S.queue then
    S.queue, S.head = {}, 1
  end
  -- parse
  while #S.ready > 0 and uv.hrtime() < deadline do
    local item = table.remove(S.ready, 1)
    local ok, err = pcall(parse_ready, item)
    if not ok then
      S.stats.error = tostring(err)
    end
  end
  if #S.ready > 0 or #S.stated > 0 or #S.queue > 0 then
    wake()
  elseif S.in_flight == 0 then
    finish()
  end
end

--- Index the agenda files in the background (`agenda.index.background`):
--- from the first org buffer, or the first agenda over files not parsed
--- yet. Files parsed already (and indexed) are skipped.
function M.start()
  if not background() then
    return
  end
  local ok, paths = pcall(require("org.files").agenda_file_paths)
  if not ok then
    return
  end
  S.known = {}
  for _, path in ipairs(paths) do
    S.known[path] = true
    enqueue(path)
  end
end

---------------------------------------------------------------------------
-- Watching for changes
---------------------------------------------------------------------------

--- Take the changes the watchers reported: parse the changed agenda
--- files again, and look for agenda files that came or went.
local function take_changes()
  local changed = S.changed
  S.changed = {}
  if S.rescan then
    S.rescan = false
    local ok, paths = pcall(require("org.files").agenda_file_paths)
    if ok then
      local now = {}
      for _, p in ipairs(paths) do
        now[p] = true
        if not S.known[p] then
          changed[p] = true
        end
      end
      for p in pairs(S.known) do
        if not now[p] then
          require("org.files").invalidate(p)
        end
      end
      S.known = now
    end
  end
  for path in pairs(changed) do
    if S.known[path] then
      enqueue(path)
    end
  end
end

--- A watcher's event: `name` changed in `dir` (nil: something did).
---@param dir string
---@param name string|nil
local function on_event(dir, name)
  if name and name ~= "" then
    local path = vim.fs.normalize(dir .. "/" .. name)
    if path:match("%.org$") or path:match("%.org_archive$") then
      S.changed[path] = true
      -- a file that came or went changes what an agenda glob matches
      if not S.known[path] or not uv.fs_stat(path) then
        S.rescan = true
      end
    end
  else
    for p in pairs(S.known) do
      if vim.fs.dirname(p) == dir then
        S.changed[p] = true
      end
    end
    S.rescan = true
  end
  after("debounce_timer", DEBOUNCE_MS, take_changes)
end

local function stop_watching()
  for _, w in pairs(S.watchers) do
    w:stop()
    if not w:is_closing() then
      w:close()
    end
  end
  S.watchers, S.polled = {}, {}
  stop_timer("poll_timer")
end

--- Poll the files of the directories without a watcher.
local function poll()
  for p in pairs(S.known) do
    if S.polled[vim.fs.dirname(p)] then
      enqueue(p)
    end
  end
end

--- Watch the directories of the agenda files, at most
--- `agenda.index.max_watchers` of them (fs_event); the others, and those
--- whose watcher fails, are polled every `agenda.index.poll_interval`
--- seconds.
function start_watching()
  local o = opts()
  local dirs, seen = {}, {}
  for p in pairs(S.known) do
    local d = vim.fs.dirname(p)
    if not seen[d] then
      seen[d] = true
      dirs[#dirs + 1] = d
    end
  end
  table.sort(dirs)
  local max = tonumber(o.max_watchers) or 32
  for d, w in pairs(S.watchers) do
    if not seen[d] then
      w:stop()
      if not w:is_closing() then
        w:close()
      end
      S.watchers[d] = nil
    end
  end
  S.polled = {}
  local count = vim.tbl_count(S.watchers)
  for _, d in ipairs(dirs) do
    if not S.watchers[d] then
      local w = count < max and uv.new_fs_event() or nil
      local ok = w
        and w:start(d, {}, function(err, name)
          if err then
            vim.schedule(function()
              local cur = S.watchers[d]
              if cur then
                cur:stop()
                if not cur:is_closing() then
                  cur:close()
                end
                S.watchers[d] = nil
                S.polled[d] = true
              end
            end)
            return
          end
          vim.schedule(function()
            on_event(d, name)
          end)
        end)
      if ok then
        S.watchers[d] = w
        count = count + 1
      else
        if w and not w:is_closing() then
          w:close()
        end
        S.polled[d] = true
      end
    end
  end
  local interval = tonumber(o.poll_interval) or 30
  stop_timer("poll_timer")
  if next(S.polled) and interval > 0 then
    local t = assert(uv.new_timer())
    S.poll_timer = t
    local ms = math.max(1, math.floor(interval * 1000))
    t:start(ms, ms, vim.schedule_wrap(poll))
  end
end

---------------------------------------------------------------------------
-- Control
---------------------------------------------------------------------------

--- Stop the background work and the watchers (the entries stay).
function M.stop()
  stop_watching()
  for _, name in ipairs({ "pump_timer", "debounce_timer", "release_timer" }) do
    stop_timer(name)
  end
  S.queue, S.head, S.queued, S.stated, S.ready = {}, 1, {}, {}, {}
  S.warming, S.changed, S.rescan, S.announce = false, {}, false, false
  S.gen = S.gen + 1
end

--- Forget the entries in memory, unsaved ones too (they are read from the
--- index file again when needed).
function M.reset()
  M.stop()
  stop_timer("save_timer")
  S.entries, S.sig, S.dirty = nil, nil, false
end

--- Wait until the background queue and saves are done (tests).
---@param timeout? integer milliseconds (default 10000)
---@return boolean done
function M.wait(timeout)
  return vim.wait(timeout or 10000, function()
    return not S.warming and S.in_flight == 0 and S.saving == 0
  end, 5) == true
end

--- Forget the index and build it again (`:Org agenda_index_rebuild`):
--- the index file is deleted and every agenda file parsed again, in the
--- background, or now with `agenda.index.background = false`.
---@return boolean
function M.rebuild()
  if not M.enabled() then
    utils.warn("The agenda index is off (agenda.index.enabled)")
    return true
  end
  M.stop()
  S.entries, S.sig, S.dirty = {}, signature(), use_cache()
  S.known = {}
  os.remove(M.path())
  local files = require("org.files")
  files.invalidate()
  if background() then
    S.announce = true
    M.start()
    if not S.warming then
      finish()
    end
  else
    local n = #files.agenda_files()
    M.flush()
    utils.notify(("Agenda index: %d files indexed"):format(n))
  end
  return true
end

--- The state of the index (`:checkhealth org`, tests).
---@return table
function M.status()
  local o = opts()
  local path = M.path()
  local st = uv.fs_stat(path)
  return {
    enabled = M.enabled(),
    cache = use_cache(),
    string_buffer = has_buffer,
    background = background(),
    watch = o.watch ~= false,
    path = path,
    size = st and st.size or nil,
    entries = S.entries and vim.tbl_count(S.entries) or nil,
    warming = S.warming,
    queued = #S.queue - S.head + 1 + #S.stated + #S.ready + S.in_flight,
    watchers = vim.tbl_count(S.watchers),
    polled = vim.tbl_count(S.polled),
    hits = S.stats.hits,
    misses = S.stats.misses,
    indexed = S.stats.indexed,
    saved = S.stats.saved,
    error = S.stats.error,
  }
end

--- Install the autocmds (setup()): start in the background on the first
--- org buffer, save on exit.
function M.setup()
  local group = vim.api.nvim_create_augroup("org.agenda_index", { clear = true })
  M.stop()
  S.known = {}
  if not M.enabled() then
    return
  end
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.stop()
      M.flush()
    end,
  })
  if not background() then
    return
  end
  local function start_soon()
    -- after what opened the buffer is done
    vim.defer_fn(M.start, 500)
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" then
      start_soon()
      return
    end
  end
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "org",
    once = true,
    callback = start_soon,
  })
end

return M

-- The agenda index (lua/org/agenda/index.lua, :h org-agenda-index): agenda
-- views built from it must be the views built without it, whatever state
-- the index is in: empty, full, out of date, corrupt, cut short, made under
-- other options, warmed in the background or half way through it.

local P = require("tests.emacs_parity")
local gen = require("tests.helpers.gen")
local config = require("org.config")
local date = require("org.date")
local files = require("org.files")
local index = require("org.agenda.index")
local agenda = require("org.agenda")
local view = require("org.agenda.view")

local WIDTH = 100

--- A directory of agenda files: the tutorial examples, the Emacs parity
--- agenda files and generated headlines (planning, properties, clocks).
local function fixture_dir()
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  local sources = vim.fn.glob(P.root .. "/examples/*.org", false, true)
  vim.list_extend(sources, { P.dir .. "/agenda/work.org", P.dir .. "/agenda/home.org" })
  for _, src in ipairs(sources) do
    vim.fn.writefile(vim.fn.readfile(src, "b"), dir .. "/" .. vim.fs.basename(src), "b")
  end
  vim.fn.writefile(gen.headlines(200), dir .. "/generated.org")
  vim.fn.writefile({
    "#+TODO: OPEN LATER | SHUT",
    "#+STARTUP: logdrawer",
    "* OPEN [#B] Own keywords :mine:",
    "  SCHEDULED: <2026-10-01 Thu 10:00 +1w>",
    "  :PROPERTIES:",
    "  :Effort: 0:30",
    "  :END:",
    "  :LOGBOOK:",
    "  CLOCK: [2026-09-30 Wed 09:00]--[2026-09-30 Wed 10:15] =>  1:15",
    "  :END:",
    "* LATER Title stamp <2026-10-02 Fri 14:00-15:00>",
    "* SHUT Finished",
    "  CLOSED: [2026-10-01 Thu 09:30]",
    "* TODO not a keyword here",
    "  DEADLINE: <2026-10-03 Sat -2d>",
    "* COMMENT Hidden",
    "  <2026-10-01 Thu>",
  }, dir .. "/own-keywords.org")
  return dir
end

--- The lines of the week agenda, the TODO list, a tags match and a search.
local function views()
  local out = {}
  local function take(name)
    out[name] = view.build(WIDTH).lines
  end
  agenda.open_agenda({ span = "week", anchor = date.read_date("2026-10-01"):days() })
  take("week")
  agenda.open_todo()
  take("todo")
  agenda.open_tags("+work|+mine|t7")
  take("tags")
  agenda.open_search("task")
  take("search")
  vim.cmd("silent! %bwipeout!")
  return out
end

local function set_index(o)
  config.opts.agenda.index = vim.tbl_extend("force", {
    enabled = true,
    cache = true,
    background = false,
    watch = false,
    max_watchers = 32,
    poll_interval = 30,
  }, o or {})
end

--- The views built with the index off: the reference.
local function reference()
  index.stop()
  set_index({ enabled = false })
  files.invalidate()
  local out = views()
  set_index()
  files.invalidate()
  return out
end

--- Rewrite `path` with `lines`, keeping its mtime (as on a file system
--- with coarse timestamps; the ctime still changes).
local function rewrite(path, lines)
  local st = assert(vim.uv.fs_stat(path))
  vim.fn.writefile(lines, path)
  vim.uv.fs_utime(path, st.atime.sec, st.mtime.sec)
end

local function eq_views(want, got)
  for _, name in ipairs({ "week", "todo", "tags", "search" }) do
    eq(want[name], got[name])
  end
end

describe("agenda index", function()
  P.freeze_time()
  local dir, saved_files, saved_index
  before_each(function()
    dir = fixture_dir()
    saved_files = config.opts.agenda_files
    saved_index = config.opts.agenda.index
    config.opts.agenda_files = { dir }
    config.opts.agenda.show_current_time_in_grid = false
    index.reset()
    os.remove(index.path())
    set_index()
    files.invalidate()
  end)
  after_each(function()
    index.stop()
    config.opts.agenda_files = saved_files
    config.opts.agenda.index = saved_index
    config.opts.agenda.show_current_time_in_grid = true
    files.invalidate()
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
  end)

  it("builds the same views from an empty index, a full one and a fresh parse", function()
    local want = reference()
    local before = index.status()
    -- empty: every file is parsed and added
    eq_views(want, views())
    local added = index.status()
    ok(added.indexed - before.indexed >= 25)
    ok(index.flush())
    ok(vim.uv.fs_stat(index.path()) ~= nil)
    -- full, read back from disk: every file is filled in from it
    index.reset()
    files.invalidate()
    eq_views(want, views())
    local after = index.status()
    ok(after.hits - added.hits >= 25)
    eq(added.indexed, after.indexed)
    -- no temporary file is left next to the index
    eq({}, vim.fn.glob(index.path() .. ".*.tmp", false, true))
  end)

  it("never uses an entry of a file changed on disk, even within the same mtime and size", function()
    views()
    ok(index.flush())
    local path = dir .. "/work.org"
    local lines = vim.fn.readfile(path)
    for i, l in ipairs(lines) do
      -- same length: the size doesn't change either
      lines[i] = l:gsub("2026%-10%-01 Thu 09:00", "2026-10-02 Fri 09:00")
    end
    rewrite(path, lines)
    local want = reference()
    ok(table.concat(want.week, "\n"):find("Important task", 1, true) ~= nil)
    files.invalidate()
    eq_views(want, views())
  end)

  it("builds views from an unsaved buffer, not from the index", function()
    views()
    ok(index.flush())
    local path = dir .. "/home.org"
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "* TODO Unsaved task :work:", "  SCHEDULED: <2026-10-02 Fri>" })
    ok(vim.bo[buf].modified)
    local function with_buffer()
      local out = {}
      agenda.open_agenda({ span = "week", anchor = date.read_date("2026-10-01"):days() })
      out.week = view.build(WIDTH).lines
      agenda.open_tags("+work")
      out.tags = view.build(WIDTH).lines
      return out
    end
    set_index({ enabled = false })
    files.invalidate()
    local want = with_buffer()
    ok(table.concat(want.week, "\n"):find("Unsaved task", 1, true) ~= nil)
    set_index()
    files.invalidate()
    local got = with_buffer()
    eq(want.week, got.week)
    eq(want.tags, got.tags)
    vim.bo[buf].modified = false
  end)

  it("ignores a corrupt or partly written index file and writes a good one", function()
    local want = reference()
    views()
    ok(index.flush())
    local fd = assert(io.open(index.path(), "rb"))
    local data = fd:read("*a")
    fd:close()
    for _, bad in ipairs({ data:sub(1, math.floor(#data / 2)), "not an index", "", ("\0"):rep(64) }) do
      -- forget the entries in memory: they are read again from the file
      index.reset()
      fd = assert(io.open(index.path(), "wb"))
      fd:write(bad)
      fd:close()
      files.invalidate()
      eq_views(want, views())
    end
    ok(index.flush())
    files.invalidate()
    local hits = index.status().hits
    eq_views(want, views())
    ok(index.status().hits - hits >= 25)
  end)

  it("drops the index when an option the parse reads changes", function()
    views()
    ok(index.flush())
    local saved = config.opts.todo_keywords
    config.opts.todo_keywords = { "TODO", "NEXT", "WAITING", "|", "DONE" }
    local ok_, err = pcall(function()
      local want = reference()
      local hits = index.status().hits
      eq_views(want, views())
      eq(hits, index.status().hits)
    end)
    config.opts.todo_keywords = saved
    files.invalidate()
    assert(ok_, err)
  end)

  it("rebuilds with :Org agenda_index_rebuild", function()
    local want = reference()
    views()
    ok(index.flush())
    local notified
    local notify = vim.notify
    vim.notify = function(msg)
      notified = msg
    end
    local ok_, err = pcall(vim.cmd, "Org agenda_index_rebuild")
    vim.notify = notify
    assert(ok_, err)
    ok(notified and notified:find("files indexed", 1, true) ~= nil)
    ok(vim.uv.fs_stat(index.path()) ~= nil)
    files.invalidate()
    eq_views(want, views())
  end)

  it("shows its state in :checkhealth org", function()
    views()
    ok(index.flush())
    local said = {}
    local health = vim.health
    local function say(kind)
      return function(msg)
        said[#said + 1] = kind .. ": " .. msg
      end
    end
    vim.health = vim.tbl_extend("force", health, { ok = say("ok"), info = say("info"), warn = say("warn") })
    local ok_, err = pcall(require("org.health").check_agenda_index)
    vim.health = health
    assert(ok_, err)
    eq(1, #said)
    ok(said[1]:find("^ok: agenda index: .*agenda%-index%.bin %(%d+%.%d MB%); %d+ files indexed") ~= nil, said[1])
  end)

  describe("in the background", function()
    it("parses every agenda file, and views built after it match", function()
      local want = reference()
      set_index({ background = true })
      local n = #files.agenda_file_paths()
      local before = index.status().indexed
      index.start()
      ok(index.wait())
      eq(n, index.status().indexed - before)
      -- the files are parsed already: the view parses none
      for _, p in ipairs(files.agenda_file_paths()) do
        ok(files.cached(p, assert(vim.uv.fs_stat(p))) ~= nil)
      end
      eq_views(want, views())
      -- the next session reads them from the index
      index.flush()
      ok(vim.uv.fs_stat(index.path()) ~= nil)
      index.reset()
      files.invalidate()
      local hits = index.status().hits
      index.start()
      ok(index.wait())
      ok(index.status().hits - hits >= n)
      eq_views(want, views())
    end)

    it("builds correct views before it is done", function()
      local want = reference()
      set_index({ background = true })
      index.start()
      ok(index.status().warming)
      -- right away, then half way through
      eq_views(want, views())
      vim.wait(20)
      eq_views(want, views())
      ok(index.wait())
      eq_views(want, views())
    end)

    it("parses a file changed on disk again (polling)", function()
      set_index({ background = true, watch = true, max_watchers = 0, poll_interval = 0.05 })
      index.start()
      ok(index.wait())
      eq(1, index.status().polled)
      local path = dir .. "/home.org"
      local lines = vim.fn.readfile(path)
      table.insert(lines, "* TODO Polled change :work:")
      vim.fn.writefile(lines, path)
      local st = assert(vim.uv.fs_stat(path))
      ok(vim.wait(5000, function()
        return files.cached(path, st) ~= nil
      end, 10))
      ok(index.wait())
      local want = reference()
      ok(table.concat(want.tags, "\n"):find("Polled change", 1, true) ~= nil)
      eq_views(want, views())
    end)

    it("parses a file changed on disk again (watcher)", function()
      set_index({ background = true, watch = true, poll_interval = 0 })
      index.start()
      ok(index.wait())
      eq(1, index.status().watchers)
      local path = dir .. "/work.org"
      local lines = vim.fn.readfile(path)
      table.insert(lines, "* TODO Watched change :work:")
      vim.fn.writefile(lines, path)
      local st = assert(vim.uv.fs_stat(path))
      ok(vim.wait(5000, function()
        return files.cached(path, st) ~= nil
      end, 10))
      ok(index.wait())
      local want = reference()
      ok(table.concat(want.tags, "\n"):find("Watched change", 1, true) ~= nil)
      eq_views(want, views())
    end)

    it("leaves files loaded in a buffer to the buffer", function()
      local path = dir .. "/home.org"
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      set_index({ background = true })
      index.start()
      ok(index.wait())
      eq(nil, files.cached(path, assert(vim.uv.fs_stat(path))))
    end)
  end)
end)

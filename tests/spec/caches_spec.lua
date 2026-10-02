-- Caches keyed by buffer changedtick (or scoped to one operation) must
-- never hand out stale results after an edit.

describe("babel block cache", function()
  local babel = require("org.babel")
  local config = require("org.config")
  local evaluate
  before_each(function()
    evaluate = babel.evaluate
    config.opts.babel.confirm_evaluate = false
    -- each block evaluates to its first body line, synchronously
    babel.evaluate = function(_, src, _, _, cb)
      local v = src.body[1]
      if cb then
        return cb(v, {})
      end
      return v, {}
    end
  end)
  after_each(function()
    babel.evaluate = evaluate
    config.opts.babel.confirm_evaluate = true
  end)

  it("re-parses at_block after an edit", function()
    local buf = org_buffer({ "#+begin_src sh", "echo one", "#+end_src" }, { 2, 0 })
    eq({ "echo one" }, babel.at_block(buf, 2).body)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "echo two" })
    eq({ "echo two" }, babel.at_block(buf, 2).body)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "", "" })
    eq(nil, babel.at_block(buf, 2))
    eq(3, babel.at_block(buf, 4).start)
  end)

  it("hands out copies, so callers can't corrupt the cache", function()
    local buf = org_buffer({ "#+begin_src sh", "echo one", "#+end_src" }, { 2, 0 })
    local b = babel.at_block(buf, 2)
    b.body[1] = "changed"
    b.start = 99
    eq({ "echo one" }, babel.at_block(buf, 2).body)
    eq(1, babel.at_block(buf, 2).start)
  end)

  it("inserts every result of execute_buffer at the right block", function()
    local buf = org_buffer({
      "#+begin_src sh",
      "a",
      "#+end_src",
      "",
      "#+begin_src sh",
      "b",
      "#+end_src",
      "",
      "#+begin_src sh",
      "c",
      "#+end_src",
    })
    babel.execute_buffer({ bufnr = buf, skip_confirm = true, sync = true })
    local expected = {
      "#+begin_src sh",
      "a",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": a",
      "",
      "#+begin_src sh",
      "b",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": b",
      "",
      "#+begin_src sh",
      "c",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": c",
    }
    eq(expected, buf_lines(buf))
    -- a second run replaces the results in place
    babel.execute_buffer({ bufnr = buf, skip_confirm = true, sync = true })
    eq(expected, buf_lines(buf))
  end)
end)

describe("agenda headline iteration", function()
  local items = require("org.agenda.items")
  local config = require("org.config")
  local parser = require("org.parser")
  after_each(function()
    config.opts.agenda.skip_function_global = nil
  end)

  local function titles(file, opts)
    local out = {}
    items.each_headline({ file }, opts, function(hl)
      out[#out + 1] = hl.title
    end)
    return out
  end

  it("hides ARCHIVE subtrees and reads skip_function_global per call", function()
    local file = parser.parse({ "* A", "* B :x:ARCHIVE:", "** C", "* D :ARCHIVEX:" })
    eq({ "A", "D" }, titles(file))
    eq({ "A", "B", "C", "D" }, titles(file, { archives = true }))
    config.opts.agenda.skip_function_global = function(hl)
      return hl.title == "A"
    end
    eq({ "D" }, titles(file))
    config.opts.agenda.skip_function_global = nil
    eq({ "A", "D" }, titles(file))
  end)
end)

describe("roam lookup after one file changes", function()
  local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
  local utils = require("org.utils")
  local dir, index_file
  local function db()
    return require("org.extensions.roam.db")
  end
  before_each(function()
    dir = vim.fn.tempname() .. "/roam"
    vim.fn.mkdir(dir, "p")
    dir = utils.realpath(dir)
    index_file = dir .. "/../roam-index.json"
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      extensions = { roam = { directory = dir, index_file = index_file } },
    })
    db().reset()
  end)
  after_each(function()
    db().reset()
    vim.fn.delete(vim.fs.dirname(dir), "rf")
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = { root .. "/tests/fixtures/*.org" },
    })
  end)

  local function note(name, id, lines)
    local path = dir .. "/" .. name .. ".org"
    utils.writefile(path, vim.list_extend({ ":PROPERTIES:", ":ID: " .. id, ":END:", "#+title: " .. name }, lines or {}))
    return path
  end

  -- what the lookup holds, in a comparable form
  local function snapshot()
    local lk = db()._lookup()
    local function links(map)
      local out = {}
      for k, list in pairs(map) do
        out[k] = vim.tbl_map(function(l)
          return { l.file, l.source, l.lnum, l.col }
        end, list)
      end
      return out
    end
    return {
      nodes = vim.tbl_map(function(n)
        return { n.id, n.file, n.title }
      end, lk.nodes),
      ids = vim.tbl_map(function(n)
        return n.file
      end, lk.by_id),
      backlinks = links(lk.backlinks),
      reflinks = links(lk.reflinks),
      duplicates = vim.tbl_keys(lk.duplicates),
    }
  end

  -- the patched lookup equals one built from scratch (from the index
  -- written to disk)
  local function check()
    local patched = snapshot()
    db().reset()
    eq(snapshot(), patched)
  end

  it("matches a full build after adding, changing and removing nodes and links", function()
    local a = note("a", "A", { "* A1", ":PROPERTIES:", ":ID: A1", ":END:", "[[id:C][c]] https://x.org" })
    note("c", "C", { "[[id:A][a]]" })
    local e = note("e", "E", { "[[id:C][to c]]", "[[id:A1][a1]]" })
    db().sync()
    snapshot()
    -- a note between a and c (path order) linking to both
    local b = note("b", "B", { "* B1", ":PROPERTIES:", ":ID: B1", ":END:", "[[id:A][a]] [[id:C][c]]" })
    db().update_file(b)
    eq(
      { "A", "A1", "B", "B1", "C", "E" },
      vim.tbl_map(function(n)
        return n.id
      end, db().nodes())
    )
    check()
    -- a node renamed, a link removed and another added
    utils.writefile(
      a,
      { ":PROPERTIES:", ":ID: A", ":END:", "#+title: a", "* A2", ":PROPERTIES:", ":ID: A2", ":END:", "[[id:E][e]]" }
    )
    db().update_file(a)
    eq(nil, db().node("A1"))
    eq("A2", db().node("A2").id)
    check()
    -- a file deleted
    vim.fn.delete(e)
    db().update_file(e)
    eq(nil, db().node("E"))
    eq({}, db().backlinks("C") and vim.tbl_filter(function(x)
      return x.link.file == e
    end, db().backlinks("C")))
    check()
  end)

  it("falls back to a full build when an id is used by another file", function()
    note("a", "A")
    local b = note("b", "B")
    db().sync()
    snapshot()
    utils.writefile(b, { ":PROPERTIES:", ":ID: A", ":END:", "#+title: b" })
    db().update_file(b)
    eq({ "A" }, vim.tbl_keys(db().duplicates()))
    eq(dir .. "/a.org", db().node("A").file)
    check()
    -- and back to a unique id
    utils.writefile(b, { ":PROPERTIES:", ":ID: B", ":END:", "#+title: b" })
    db().update_file(b)
    eq({}, db().duplicates())
    check()
  end)

  it("writes the index atomically", function()
    note("a", "A")
    db().sync()
    ok(vim.uv.fs_stat(index_file))
    local leftovers = vim.fn.glob(vim.fs.normalize(index_file) .. ".tmp*", false, true)
    eq({}, leftovers)
    eq("A", vim.json.decode(table.concat(vim.fn.readfile(index_file), "\n")).files[dir .. "/a.org"].nodes[1].id)
  end)
end)

describe("incremental ID scan", function()
  local id = require("org.id")
  local config = require("org.config")
  local utils = require("org.utils")
  local files = require("org.files")
  local dir, get
  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = utils.realpath(dir)
    get = files.get
    vim.cmd("enew!")
    vim.cmd("silent! %bwipeout!")
  end)
  after_each(function()
    files.get = get
    config.setup({})
    id._reset()
    vim.fn.delete(dir, "rf")
  end)

  local function setup(db)
    config.setup({
      org_directory = dir,
      agenda_files = { dir .. "/*.org" },
      id = { locations_file = db or (dir .. "/ids.json") },
    })
    id._reset()
  end

  -- the files parsed during `fn`
  local function parsed(fn)
    local out = {}
    files.get = function(p)
      out[#out + 1] = vim.fs.basename(p)
      return get(p)
    end
    fn()
    files.get = get
    table.sort(out)
    return out
  end

  local function entry(id_)
    return { "* H", ":PROPERTIES:", ":ID: " .. id_, ":END:" }
  end

  local function bump(path)
    local st = vim.uv.fs_stat(path)
    vim.uv.fs_utime(path, st.atime.sec, st.mtime.sec + 5)
  end

  it("reads again only the files that changed, also in a new session", function()
    local a, b = dir .. "/a.org", dir .. "/b.org"
    utils.writefile(a, entry("a1"))
    utils.writefile(b, entry("b1"))
    utils.writefile(dir .. "/a.org_archive", entry("old"))
    setup()
    local n
    eq(
      { "a.org", "a.org_archive", "b.org" },
      parsed(function()
        n = id.update_locations()
      end)
    )
    eq(3, n)
    -- a new session: the scan comes from the database
    id._reset()
    files.invalidate()
    eq(
      {},
      parsed(function()
        n = id.update_locations()
      end)
    )
    eq(3, n)
    eq(b, utils.read_json(dir .. "/ids.json").b1)
    -- a changed file (same size, other mtime) is read again
    utils.writefile(b, entry("b2"))
    bump(b)
    id._reset()
    files.invalidate()
    eq(
      { "b.org" },
      parsed(function()
        n = id.update_locations()
      end)
    )
    local map = utils.read_json(dir .. "/ids.json")
    eq(b, map.b2)
    eq(nil, map.b1)
    -- a deleted file drops its ids
    vim.fn.delete(a)
    eq(2, id.update_locations())
    eq(nil, utils.read_json(dir .. "/ids.json").a1)
  end)

  it("reads a loaded buffer, with its unsaved changes", function()
    local a = dir .. "/a.org"
    utils.writefile(a, entry("a1"))
    setup()
    eq(1, id.update_locations())
    vim.cmd("edit " .. a)
    vim.api.nvim_buf_set_lines(0, 2, 3, false, { ":ID: unsaved" })
    eq(1, id.update_locations())
    eq({ "unsaved" }, id.known_ids())
    vim.cmd("edit! " .. a)
    vim.cmd("silent! %bwipeout!")
    eq(1, id.update_locations())
    eq({ "a1" }, id.known_ids())
  end)

  it("keeps the database readable as a plain map and in Emacs's format", function()
    local a = dir .. "/a.org"
    utils.writefile(a, entry("a1"))
    -- a database written before the scan was stored
    utils.write_json(dir .. "/ids.json", { a1 = a })
    setup()
    eq({ "a1" }, id.known_ids())
    id.update_locations()
    id._reset()
    eq({ "a1" }, id.known_ids())
    -- Emacs's format: the scan is a comment, which its reader skips
    local db = dir .. "/.org-id-locations"
    utils.writefile(db, { "", '(("' .. a .. '" "a1"))' })
    setup(db)
    id.update_locations()
    local text = table.concat(utils.readfile(db), "\n")
    ok(text:find("\n; org.nvim-scan: ", 1, true), text)
    eq({ a1 = a }, id.parse_emacs_locations(text, dir))
    id._reset()
    files.invalidate()
    eq(
      {},
      parsed(function()
        id.update_locations()
      end)
    )
    eq({ "a1" }, id.known_ids())
  end)
end)

describe("open clock cache", function()
  local clock = require("org.clock")
  local date = require("org.date")
  before_each(function()
    clock.state = nil
  end)
  after_each(function()
    clock.state = nil
  end)

  it("follows edits to the buffer of the running clock", function()
    local buf = org_buffer({ "* Task" }, { 1, 0 })
    vim.bo[buf].bufhidden = "hide"
    clock.clock_in(nil, { at = date.parse("[2026-10-01 Thu 10:00]") })
    local b, l = clock.find_open_clock()
    eq(buf, b)
    eq(3, l)
    -- the same answer again from the cache
    eq(3, select(2, clock.find_open_clock()))
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "* Before", "text" })
    eq(5, select(2, clock.find_open_clock()))
    -- the clock line removed: no open clock
    vim.api.nvim_buf_set_lines(buf, 4, 5, false, {})
    eq(nil, clock.find_open_clock())
    vim.api.nvim_buf_set_lines(buf, 4, 4, false, { "CLOCK: [2026-10-01 Thu 10:00]" })
    eq(5, select(2, clock.find_open_clock()))
    eq(90, clock.clock_out({ at = date.parse("[2026-10-01 Thu 11:30]") }))
    eq(nil, clock.find_open_clock())
  end)

  it("does not reuse the answer for another clock state", function()
    local buf = org_buffer({ "* A", "* B" }, { 1, 0 })
    vim.bo[buf].bufhidden = "hide"
    clock.clock_in(nil, { at = date.parse("[2026-10-01 Thu 10:00]") })
    eq(3, select(2, clock.find_open_clock()))
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    clock.clock_in(nil, { at = date.parse("[2026-10-01 Thu 11:00]") })
    eq(7, select(2, clock.find_open_clock()))
    clock.clock_out({ at = date.parse("[2026-10-01 Thu 11:30]") })
  end)
end)

-- The org command line as an interface for scripts and agents: the JSON
-- envelope of every command, the query and write commands, targets,
-- error codes and the schema.
local cli = require("org.extensions.cli.run")
local schema = require("org.extensions.cli.schema")

local function stamp(y, m, d, rest)
  return os.date("%Y-%m-%d %a", os.time({ year = y, month = m, day = d, hour = 12 })) .. (rest or "")
end

local TODAY = os.date("%Y-%m-%d %a")

--- A temp directory with work.org, home.org, a config file and XDG dirs.
local function workspace(extra_config)
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({
    "#+CATEGORY: work",
    "#+FILETAGS: :office:",
    "* TODO [#A] Review pull request :code:",
    "  SCHEDULED: <" .. TODAY .. " 10:00>",
    "* NEXT Write release notes",
    "  DEADLINE: <" .. stamp(2030, 1, 20) .. ">",
    "  :PROPERTIES:",
    "  :ID: notes-id",
    "  :EFFORT: 1:30",
    "  :OWNER: ann",
    "  :END:",
    "  :LOGBOOK:",
    "  CLOCK: [" .. stamp(2030, 1, 10, " 09:00") .. "]--[" .. stamp(2030, 1, 10, " 10:30") .. "] =>  1:30",
    "  :END:",
    "  Body of the notes.",
    "  Meeting on <" .. stamp(2030, 1, 12, " 14:00-15:00") .. ">.",
    "** TODO Draft the changelog :writing:",
    "   SCHEDULED: <" .. stamp(2030, 1, 15) .. ">",
    "** DONE Collect the PRs",
    "* Standup meeting",
    "  :PROPERTIES:",
    "  :CUSTOM_ID: standup",
    "  :END:",
    "* DONE Old thing",
    "  CLOSED: [" .. stamp(2029, 12, 1, " 10:00") .. "]",
    "* Archived :ARCHIVE:",
    "** TODO Hidden task",
    "* Notes",
    "Searchable zebra text.",
  }, dir .. "/work.org")
  vim.fn.writefile({
    "* TODO Buy milk :errand:",
    "* Projects",
    "** Garden",
  }, dir .. "/home.org")
  local cfg = {
    "local dir = " .. vim.inspect(dir),
    "return {",
    "  org_directory = dir,",
    "  agenda_files = { dir .. '/work.org', dir .. '/home.org' },",
    "  todo_keywords = { 'TODO NEXT | DONE' },",
    "  tags = { 'urgent(u)' },",
    "  capture = { templates = {",
    "    t = { description = 'Task', target = dir .. '/inbox.org', headline = 'Inbox',",
    "          template = '* TODO %?\\n  %U' },",
    "    p = { description = 'Prompt', target = dir .. '/inbox.org',",
    "          template = '* TODO %^{Title}\\n  %^{Where}p' },",
    "  } },",
    "  clock = { persist = true, persist_file = dir .. '/clock.json' },",
  }
  vim.list_extend(cfg, extra_config or {})
  cfg[#cfg + 1] = "}"
  vim.fn.writefile(cfg, dir .. "/cfg.lua")
  for _, d in ipairs({ "config", "state", "cache" }) do
    vim.fn.mkdir(dir .. "/xdg-" .. d, "p")
  end
  return dir
end

local function env(dir)
  return {
    ORG_NVIM_CONFIG = "",
    XDG_CONFIG_HOME = dir .. "/xdg-config",
    XDG_STATE_HOME = dir .. "/xdg-state",
    XDG_CACHE_HOME = dir .. "/xdg-cache",
    XDG_DATA_HOME = vim.env.XDG_DATA_HOME or (dir .. "/xdg-data"),
    ORG_NVIM_BIN = vim.v.progpath,
  }
end

--- Run bin/org; returns exit code, stdout, stderr.
local function run(dir, args, stdin)
  local cmd = { require("org.extensions.cli").bin(), "--config", dir .. "/cfg.lua" }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { text = true, stdin = stdin or false, env = env(dir), cwd = dir }):wait(20000)
  return res.code, res.stdout or "", res.stderr or ""
end

--- Run with --json and decode the envelope, checking that stdout holds
--- that one JSON document and stderr stays empty.
local function json(dir, args, stdin)
  local a = vim.list_extend({ "--json" }, args)
  local code, stdout, stderr = run(dir, a, stdin)
  local lines = vim.split(vim.trim(stdout), "\n", { plain = true })
  eq(1, #lines, stdout)
  local okd, env_ = pcall(vim.json.decode, stdout)
  ok(okd, "not JSON: " .. stdout .. stderr)
  if vim.fn.has("win32") == 0 then
    -- (Windows consoles may add their own noise to stderr)
    eq("", stderr)
  end
  eq(1, env_.version)
  return code, env_
end

local function same_path(a, b)
  return vim.fs.normalize(vim.fn.resolve(a)) == vim.fs.normalize(vim.fn.resolve(b))
end

local function read(path)
  return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
end

local function titles(list)
  return vim.tbl_map(function(h)
    return h.title
  end, list)
end

local function alive(pid)
  return vim.uv.kill(pid, 0) == 0
end

-- Neovims started by busy_nvim(), stopped by stop_busy()
local busy = {}

--- A headless Neovim with unsaved changes in `file` (its swap file says
--- so). Specs starting one call stop_busy() in an after_each, so it is
--- stopped also when the spec fails; it quits by itself after two minutes
--- should this Neovim die first.
local function busy_nvim(dir, file)
  local job = vim.system({
    vim.v.progpath,
    "--headless",
    "--clean",
    "--cmd",
    "set swapfile updatecount=1",
    "--cmd",
    "call timer_start(120000, {-> execute('qa!')})",
    "-c",
    "edit " .. vim.fn.fnameescape(file),
    "-c",
    "call setline(1, getline(1) .. ' (changed in Neovim)')",
    "-c",
    "preserve",
  }, { env = env(dir) })
  busy[#busy + 1] = job
  local swapdir = dir .. "/xdg-state/nvim/swap"
  local found = vim.wait(10000, function()
    for _, sw in ipairs(vim.fn.glob(swapdir .. "/*", true, true)) do
      if vim.fn.swapinfo(sw).dirty == 1 then
        return true
      end
    end
    return false
  end, 50)
  ok(found, "no swap file")
  return job
end

local function stop_busy()
  for _, job in ipairs(busy) do
    pcall(job.kill, job, 9)
    pcall(job.wait, job, 5000)
  end
  busy = {}
end

--- Does the decoded JSON `v` fit the JSON Schema `s` (the parts of JSON
--- Schema `org schema` uses)? true, or a message saying where it doesn't.
local function fits(v, s, defs, path)
  path = path or "$"
  if s["$ref"] then
    return fits(v, defs[s["$ref"]:match("[^/]+$")], defs, path)
  end
  if s.anyOf then
    for _, alt in ipairs(s.anyOf) do
      if fits(v, alt, defs, path) == true then
        return true
      end
    end
    return path .. ": " .. vim.inspect(v) .. " fits no alternative"
  end
  for _, part in ipairs(s.allOf or {}) do
    local r = fits(v, part, defs, path)
    if r ~= true then
      return r
    end
  end
  if s.const ~= nil and v ~= s.const then
    return path .. ": not " .. tostring(s.const)
  end
  if s.enum and not vim.tbl_contains(s.enum, v) then
    return path .. ": " .. tostring(v) .. " not one of " .. table.concat(s.enum, ", ")
  end
  local t = s.type
  local is_table = type(v) == "table" and v ~= vim.NIL
  local list = is_table and (vim.islist(v) or (next(v) == nil and getmetatable(v) == nil))
  local good = t == nil
    or (t == "null" and v == vim.NIL)
    or (t == "string" and type(v) == "string")
    or (t == "boolean" and type(v) == "boolean")
    or (t == "integer" and type(v) == "number" and v % 1 == 0)
    or (t == "array" and list)
    or (t == "object" and is_table and (not list or next(v) == nil))
  if not good then
    return path .. ": " .. vim.inspect(v) .. " is not " .. t
  end
  if t == "array" then
    for i, item in ipairs(v) do
      local r = fits(item, s.items or {}, defs, path .. "[" .. i .. "]")
      if r ~= true then
        return r
      end
    end
  elseif t == "object" then
    for _, k in ipairs(s.required or {}) do
      if v[k] == nil then
        return path .. ": no " .. k
      end
    end
    for k, ps in pairs(s.properties or {}) do
      if v[k] ~= nil then
        local r = fits(v[k], ps, defs, path .. "." .. k)
        if r ~= true then
          return r
        end
      end
    end
  end
  return true
end

describe("cli json: envelope", function()
  local dir
  before_each(function()
    dir = workspace()
  end)
  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  it("wraps every read command's data in the same envelope", function()
    for _, args in ipairs({
      { "agenda", "week" },
      { "search", "zebra" },
      { "headlines" },
      { "show", "notes-id" },
      { "clock" },
      { "templates" },
      { "files" },
      { "tags" },
      { "keywords" },
      { "version" },
    }) do
      local code, e = json(dir, args)
      eq(0, code, vim.inspect(args))
      eq(true, e.ok)
      eq({}, e.errors)
      eq({}, e.warnings)
      ok(e.data ~= nil and e.data ~= vim.NIL, vim.inspect(args))
    end
  end)

  it("names the command, subcommands included", function()
    eq("clock status", select(2, json(dir, { "clock" })).command)
    eq("headlines", select(2, json(dir, { "query" })).command)
    eq("agenda", select(2, json(dir, { "agenda" })).command)
  end)

  it("streams one object per line with --jsonl", function()
    local code, stdout = run(dir, { "--jsonl", "headlines", "--todo", "open" })
    eq(0, code)
    local lines = vim.split(vim.trim(stdout), "\n", { plain = true })
    local got = {}
    for _, l in ipairs(lines) do
      got[#got + 1] = vim.json.decode(l).title
    end
    eq({ "Review pull request", "Write release notes", "Draft the changelog", "Buy milk" }, got)
    local _, agenda = run(dir, { "--jsonl", "agenda", "day" })
    local first = vim.json.decode(vim.split(agenda, "\n")[1])
    eq("Review pull request", first.title)
    eq(os.date("%Y-%m-%d"), first.date)
  end)

  it("keeps org.nvim's messages off stdout, also with -v", function()
    local code, stdout, stderr = run(dir, { "-v", "--json", "capture", "Buy bread" })
    eq(0, code)
    eq(true, vim.json.decode(stdout).ok)
    eq(1, #vim.split(vim.trim(stdout), "\n"))
    ok(stderr:find("Captured to", 1, true), stderr)
  end)

  it("puts errors on stdout as JSON with stable codes and exit codes", function()
    local cases = {
      { { "frobnicate" }, "unknown_command", 2 },
      { { "agenda", "--nope" }, "unknown_option", 2 },
      { { "agenda", "--children" }, "unknown_option", 2 },
      { { "agenda", "--date" }, "usage", 2 },
      { { "agenda", "day", "--date", "notadate" }, "bad_value", 2 },
      { { "show", "no such heading at all" }, "not_found", 1 },
      { { "show", "e" }, "ambiguous", 1 },
      { { "clock", "out" }, "no_clock", 1 },
      { { "set", "todo", "notes-id", "BOGUS" }, "bad_value", 2 },
      { { "set", "frob", "x" }, "usage", 2 },
      { { "capture", "-t", "zz", "x" }, "bad_value", 2 },
      { { "capture", "-t", "p" }, "input_needed", 3 },
      { { "headlines", "--level", "x" }, "bad_value", 2 },
      { { "search", "--match", "+{[}" }, "bad_value", 2 },
    }
    for _, c in ipairs(cases) do
      local code, e = json(dir, c[1])
      eq(c[3], code, vim.inspect(c[1]))
      eq(false, e.ok)
      eq(vim.NIL, e.data)
      eq(c[2], e.errors[1].code, vim.inspect(c[1]))
      ok(type(e.errors[1].message) == "string")
      eq(c[3], schema.ERRORS[c[2]].exit)
    end
  end)

  it("fits the envelope org schema describes, an error before the command is known too", function()
    local doc = schema.describe()
    for _, args in ipairs({
      { "version" },
      { "show", "no such heading at all" },
      { "frobnicate" },
      { "--nope" },
      { "agenda", "--date" },
    }) do
      local _, e = json(dir, args)
      eq(true, fits(e, doc.envelope, doc["$defs"]), vim.inspect(args))
    end
    eq(vim.NIL, select(2, json(dir, { "frobnicate" })).command)
  end)

  it("says which prompt needed an answer", function()
    local code, e = json(dir, { "capture", "-t", "p" })
    eq(3, code)
    eq("Title", e.errors[1].details.prompt)
    eq({}, read(dir .. "/inbox.org"))
  end)

  it("lists the candidates of an ambiguous target", function()
    local _, e = json(dir, { "show", "e" })
    local cands = e.errors[1].details.candidates
    ok(#cands > 2)
    eq("Review pull request", cands[1].title)
    local code, picked = json(dir, { "show", "e", "--pick", "2" })
    eq(0, code)
    eq(cands[2].title, picked.data.title)
  end)

  it("exits 0 with an empty list when nothing matches", function()
    local code, e = json(dir, { "search", "nomatchatall" })
    eq(0, code)
    eq({}, e.data)
    code = run(dir, { "search", "nomatchatall" })
    eq(1, code)
  end)
end)

describe("cli json: reading", function()
  local dir
  before_each(function()
    dir = workspace()
  end)
  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  it("gives headlines with ISO dates and absolute paths", function()
    local _, e = json(dir, { "headlines", "--todo", "NEXT" })
    eq(1, #e.data)
    local h = e.data[1]
    eq("Write release notes", h.title)
    eq("NEXT", h.todo)
    eq("todo", h.todo_type)
    eq("notes-id", h.id)
    eq(5, h.line)
    eq(1, h.level)
    eq("work", h.category)
    eq({ "office" }, h.tags)
    eq({}, h.local_tags)
    ok(same_path(dir .. "/work.org", h.file))
    ok(h.file:match("^/") or h.file:match("^%a:/"), h.file)
    eq("2030-01-20", h.deadline.date)
    eq("2030-01-20", h.deadline.start)
    eq("<" .. stamp(2030, 1, 20) .. ">", h.deadline.raw)
    eq(true, h.deadline.active)
    eq(vim.NIL, h.scheduled)
    eq(vim.NIL, h.priority)
  end)

  it("filters headlines", function()
    local function q(args)
      local _, e = json(dir, vim.list_extend({ "headlines" }, args))
      eq(true, e.ok, vim.inspect(e.errors))
      return titles(e.data)
    end
    eq({ "Review pull request", "Write release notes", "Draft the changelog", "Buy milk" }, q({ "--todo", "open" }))
    eq({ "Collect the PRs", "Old thing" }, q({ "--todo", "done" }))
    eq({ "Review pull request", "Buy milk" }, q({ "--todo", "TODO", "--level", "1" }))
    eq({ "Draft the changelog" }, q({ "--tag", "writing" }))
    eq({ "Review pull request" }, q({ "--tag", "code", "--tag", "office" }))
    eq({ "Write release notes" }, q({ "--property", "OWNER=ann" }))
    eq({ "Standup meeting" }, q({ "--property", "custom_id" }))
    eq({ "Draft the changelog" }, q({ "--scheduled", "2030-01-01..2030-01-31" }))
    eq({ "Review pull request" }, q({ "--scheduled", "today" }))
    eq({ "Write release notes" }, q({ "--deadline", "any" }))
    eq({ "Buy milk" }, q({ "--file", "home", "--todo", "any" }))
    eq({ "Draft the changelog", "Collect the PRs" }, q({ "--level", "2..", "--file", "work.org" }))
    eq({ "Review pull request" }, q({ "--match", "+code-writing/TODO" }))
    eq({ "Review pull request" }, q({ "--todo", "open", "--limit", "1" }))
    eq({ "Buy milk", "Projects", "Garden" }, q({ dir .. "/home.org" }))
    -- archived subtrees only with --archived
    ok(not vim.tbl_contains(q({}), "Hidden task"))
    ok(vim.tbl_contains(q({ "--archived" }), "Hidden task"))
  end)

  it("evaluates code blocks like an export in Neovim, and stops at one that would ask", function()
    local src = dir .. "/code.org"
    vim.fn.writefile({ "* Code", "#+begin_src lua :exports both", "return 1 + 2", "#+end_src" }, src)
    -- babel.confirm_evaluate (on by default) asks before running the block:
    -- nothing is exported, as in Emacs's batch export
    local code, e = json(dir, { "export", src, "md", "--stdout" })
    eq(3, code)
    eq("input_needed", e.errors[1].code)
    local prompt = e.errors[1].details.prompt
    ok(prompt:find("Evaluate this lua code block", 1, true), prompt)
    for _, w in ipairs(e.warnings) do
      ok(not w:find("table: 0x", 1, true), w)
    end
    code = json(dir, { "export", src, "md", "-o", dir .. "/code.md" })
    eq(3, code)
    eq(0, vim.fn.filereadable(dir .. "/code.md"))
    -- without the question, the result is exported
    local d = workspace({ "  babel = { confirm_evaluate = false }," })
    vim.fn.writefile(read(src), d .. "/code.org")
    code, e = json(d, { "export", d .. "/code.org", "md", "--stdout" })
    eq(0, code)
    eq({}, e.warnings)
    ok(e.data.text:find("\n    3\n", 1, true), e.data.text)
    vim.fn.delete(d, "rf")
  end)

  it("searches text and tags matches", function()
    local _, e = json(dir, { "search", "zebra" })
    eq({ "Notes" }, titles(e.data))
    _, e = json(dir, { "search", "--match", "+errand" })
    eq({ "Buy milk" }, titles(e.data))
  end)

  it("shows a heading's full data", function()
    local _, e = json(dir, { "show", "notes-id", "--children" })
    local d = e.data
    eq("Write release notes", d.title)
    eq({ ID = "notes-id", EFFORT = "1:30", OWNER = "ann" }, d.properties)
    eq(90, d.effort_minutes)
    eq(1, d.clock.count)
    eq(90, d.clock.minutes)
    eq("1:30", d.clock.total)
    eq(false, d.clock.running)
    eq("2030-01-10T09:00", d.clock.entries[1].start.start)
    eq("2030-01-10T10:30", d.clock.entries[1]["end"].start)
    eq(90, d.clock.entries[1].minutes)
    ok(d.body:find("Body of the notes.", 1, true))
    eq(1, #d.timestamps)
    eq("2030-01-12T14:00", d.timestamps[1].start)
    eq("2030-01-12T15:00", d.timestamps[1]["end"])
    eq("15:00", d.timestamps[1].end_time)
    eq({ "Draft the changelog", "Collect the PRs" }, titles(d.children))
    eq({ "Write release notes" }, d.children[1].outline_path)
    eq("writing", d.children[1].local_tags[1])
    _, e = json(dir, { "show", "notes-id" })
    eq(vim.NIL, e.data.children)
  end)

  it("finds targets by ID, FILE:LINE, FILE::TITLE and FILE::#CUSTOM_ID", function()
    local function title(t)
      local code, e = json(dir, { "show", t })
      eq(0, code, t)
      return e.data.title
    end
    eq("Write release notes", title("id:notes-id"))
    eq("Write release notes", title("notes-id"))
    eq("Write release notes", title(dir .. "/work.org:14"))
    eq("Draft the changelog", title("work.org:17"))
    eq("Buy milk", title("home.org::Buy milk"))
    eq("Garden", title("home::*Garden"))
    eq("Standup meeting", title("work.org::#standup"))
    -- an org file outside the agenda
    vim.fn.writefile({ "* Elsewhere" }, dir .. "/other.org")
    eq("Elsewhere", title(dir .. "/other.org::Elsewhere"))
    eq("Elsewhere", title("other.org:1"))
    local code = json(dir, { "show", "work.org:1" })
    eq(1, code)
  end)

  it("lists templates, files, tags and keywords", function()
    local _, e = json(dir, { "templates" })
    eq(
      { "p", "t" },
      vim.tbl_map(function(t)
        return t.key
      end, e.data)
    )
    eq("Task", e.data[2].description)
    eq("entry", e.data[2].type)
    ok(same_path(dir .. "/inbox.org", e.data[2].target))
    eq(e.data, select(2, json(dir, { "capture", "--list" })).data)
    _, e = json(dir, { "files" })
    eq(2, #e.data)
    ok(same_path(dir .. "/work.org", e.data[1].file))
    eq("work", e.data[1].category)
    eq(9, e.data[1].headlines)
    _, e = json(dir, { "tags" })
    local by = {}
    for _, t in ipairs(e.data) do
      by[t.name] = t
    end
    eq(1, by.code.count)
    eq(1, by.office.count)
    eq(true, by.urgent.defined)
    eq(0, by.urgent.count)
    _, e = json(dir, { "keywords" })
    eq({ "TODO", "NEXT" }, e.data.todo)
    eq({ "DONE" }, e.data.done)
    eq("A", e.data.priority.highest)
  end)

  it("gives the agenda with ISO dates, custom commands too", function()
    local d2 = workspace({
      "  agenda = { custom_commands = { w = { description = 'Writing', type = 'tags', match = '+writing' } } },",
    })
    local _, e = json(d2, { "agenda", "day" })
    eq("agenda", e.data.view)
    eq(os.date("%Y-%m-%d"), e.data.start)
    local it = e.data.items[1]
    eq("Review pull request", it.title)
    eq("10:00", it.time)
    eq(os.date("%Y-%m-%dT10:00"), it.timestamp.start)
    ok(same_path(d2 .. "/work.org", it.file))
    _, e = json(d2, { "agenda", "w" })
    eq("custom", e.data.view)
    eq("w", e.data.key)
    eq({ "Draft the changelog" }, titles(e.data.items))
    _, e = json(d2, { "agenda", "tags-todo", "+office" })
    ok(vim.tbl_contains(titles(e.data.items), "Review pull request"))
    ok(not vim.tbl_contains(titles(e.data.items), "Standup meeting"))
    vim.fn.delete(d2, "rf")
  end)
end)

describe("cli json: writing", function()
  local dir
  before_each(function()
    dir = workspace()
  end)
  after_each(function()
    stop_busy()
    vim.fn.delete(dir, "rf")
  end)

  local function work()
    return read(dir .. "/work.org")
  end

  it("sets the TODO keyword", function()
    local code, e = json(dir, { "set", "todo", "notes-id", "DONE" })
    eq(0, code)
    eq("todo", e.data.field)
    eq("NEXT", e.data.old)
    eq("DONE", e.data.new)
    eq("done", e.data.headline.todo_type)
    eq("* DONE Write release notes", work()[5])
    code, e = json(dir, { "set", "todo", "notes-id", "none" })
    eq(0, code)
    eq(vim.NIL, e.data.new)
    eq("* Write release notes", work()[5])
  end)

  it("records a note when the keyword logs one", function()
    local d2 = workspace({ "  todo_keywords = { 'TODO(t) | DONE(d@)' }," })
    local code = json(d2, { "set", "todo", "Review", "DONE", "--note", "Merged" })
    eq(0, code)
    local text = table.concat(read(d2 .. "/work.org"), "\n")
    ok(text:find('State "DONE"', 1, true), text)
    ok(text:find("Merged", 1, true), text)
    -- without --note: the change is logged without a note, nothing asks
    code = json(d2, { "set", "todo", "Buy milk", "DONE" })
    eq(0, code)
    vim.fn.delete(d2, "rf")
  end)

  it("sets, adds and removes tags", function()
    local _, e = json(dir, { "set", "tags", "Review", "a:b" })
    eq({ "code" }, e.data.old)
    eq({ "a", "b" }, e.data.new)
    ok(work()[3]:match(":a:b:$"))
    _, e = json(dir, { "set", "tags", "Review", "--add", "c", "--remove", "a" })
    eq({ "b", "c" }, e.data.new)
    _, e = json(dir, { "set", "tags", "Review", "" })
    eq({}, e.data.new)
    eq("* TODO [#A] Review pull request", work()[3])
    local code, err = json(dir, { "set", "tags", "Review", "bad tag!" })
    eq(2, code)
    eq("bad_value", err.errors[1].code)
  end)

  it("sets and removes the priority", function()
    local _, e = json(dir, { "set", "priority", "notes-id", "b" })
    eq(vim.NIL, e.data.old)
    eq("B", e.data.new)
    eq("* NEXT [#B] Write release notes", work()[5])
    _, e = json(dir, { "set", "priority", "notes-id", "none" })
    eq(vim.NIL, e.data.new)
    local code, err = json(dir, { "set", "priority", "notes-id", "Z" })
    eq(2, code)
    eq("bad_value", err.errors[1].code)
  end)

  it("sets and deletes properties", function()
    local _, e = json(dir, { "set", "property", "notes-id", "OWNER", "bob" })
    eq("ann", e.data.old)
    eq("bob", e.data.new)
    eq("OWNER", e.data.name)
    _, e = json(dir, { "set", "property", "Buy milk", "Shop", "corner store" })
    eq("corner store", e.data.new)
    ok(table.concat(read(dir .. "/home.org"), "\n"):find(":Shop:%s+corner store"))
    _, e = json(dir, { "set", "property", "notes-id", "OWNER", "--delete" })
    eq(vim.NIL, e.data.new)
    ok(not table.concat(work(), "\n"):find("OWNER", 1, true))
  end)

  it("schedules and sets deadlines, with ISO dates back", function()
    local _, e = json(dir, { "set", "scheduled", "Buy milk", "2030-02-03 09:15" })
    eq(vim.NIL, e.data.old)
    eq("2030-02-03T09:15", e.data.new.start)
    eq("<" .. stamp(2030, 2, 3, " 09:15") .. ">", e.data.new.raw)
    eq("SCHEDULED: <" .. stamp(2030, 2, 3, " 09:15") .. ">", vim.trim(read(dir .. "/home.org")[2]))
    _, e = json(dir, { "set", "deadline", "notes-id", "<2030-01-25 Fri +1w>" })
    eq("2030-01-20", e.data.old.date)
    eq("+1w", e.data.new.repeater)
    _, e = json(dir, { "set", "scheduled", "Buy milk", "none" })
    eq(vim.NIL, e.data.new)
    eq("* Projects", read(dir .. "/home.org")[2])
    local code, err = json(dir, { "set", "deadline", "Buy milk", "not a date at all" })
    eq(2, code)
    eq("bad_value", err.errors[1].code)
  end)

  it("keeps the repeater and warning period of a rescheduled date, and logs it", function()
    local d = workspace({ "  log_reschedule = 'time',", "  log_redeadline = 'note'," })
    vim.fn.writefile(
      { "* TODO Water plants", "  SCHEDULED: <" .. stamp(2030, 1, 4, " +1w -2d") .. ">" },
      d .. "/home.org"
    )
    local _, e = json(d, { "set", "scheduled", "Water plants", "2030-01-11" })
    eq("+1w", e.data.new.repeater)
    eq("-2d", e.data.new.warning)
    local home = table.concat(read(d .. "/home.org"), "\n")
    ok(home:find("SCHEDULED: <" .. stamp(2030, 1, 11, " +1w -2d") .. ">", 1, true), home)
    ok(home:find("Rescheduled from", 1, true), home)
    -- a "note" log setting takes the --note text instead of prompting
    json(d, { "set", "deadline", "Water plants", "2030-01-20" })
    local code = json(d, { "set", "deadline", "Water plants", "2030-01-27", "--note", "moved by a script" })
    eq(0, code)
    home = table.concat(read(d .. "/home.org"), "\n")
    ok(home:find("New deadline from", 1, true), home)
    ok(home:find("moved by a script", 1, true), home)
  end)

  it("adds a note, from an argument or stdin", function()
    local _, e = json(dir, { "note", "Buy milk", "Out", "of", "milk" })
    eq("Out of milk", e.data.new)
    local home = table.concat(read(dir .. "/home.org"), "\n")
    ok(home:find("Note taken on", 1, true), home)
    ok(home:find("Out of milk", 1, true), home)
    json(dir, { "note", "Buy milk", "-" }, "piped note\n")
    ok(table.concat(read(dir .. "/home.org"), "\n"):find("piped note", 1, true))
  end)

  it("gets or creates an ID", function()
    local _, e = json(dir, { "id", "notes-id" })
    eq("notes-id", e.data.id)
    eq(false, e.data.created)
    _, e = json(dir, { "id", "Buy milk" })
    eq(vim.NIL, e.data.id)
    _, e = json(dir, { "id", "Buy milk", "--create" })
    eq(true, e.data.created)
    ok(type(e.data.id) == "string" and #e.data.id > 8)
    ok(table.concat(read(dir .. "/home.org"), "\n"):find(e.data.id, 1, true))
    eq(e.data.id, select(2, json(dir, { "show", "id:" .. e.data.id })).data.id)
  end)

  it("refiles under a heading and to a file", function()
    local code, e = json(dir, { "refile", "Buy milk", "home.org::Garden" })
    eq(0, code)
    eq(3, e.data.headline.level)
    eq({ "Projects", "Garden" }, e.data.headline.outline_path)
    eq(1, e.data.from.line)
    local home = read(dir .. "/home.org")
    eq({ "* Projects", "** Garden" }, { home[1], home[2] })
    ok(home[3]:match("^%*%*%* TODO Buy milk%s+:errand:$"), home[3])
    eq(3, #home)
    code, e = json(dir, { "refile", "Old thing", dir .. "/home.org" })
    eq(0, code)
    eq(1, e.data.headline.level)
    ok(same_path(dir .. "/home.org", e.data.headline.file))
    ok(not table.concat(work(), "\n"):find("Old thing", 1, true))
    code, e = json(dir, { "refile", "Projects", "Garden" })
    eq(1, code)
    eq("failed", e.errors[1].code)
  end)

  it("archives a heading", function()
    local code, e = json(dir, { "archive", "Old thing" })
    eq(0, code)
    eq("Old thing", e.data.title)
    ok(same_path(dir .. "/work.org_archive", e.data.archive_file))
    eq("Old thing", e.data.headline.title)
    eq(
      e.data.headline.line,
      (function()
        for i, l in ipairs(read(dir .. "/work.org_archive")) do
          if l:match("^%* DONE Old thing") then
            return i
          end
        end
      end)()
    )
    ok(not table.concat(work(), "\n"):find("Old thing", 1, true))
  end)

  it("captures with fields, a JSON object on stdin and an ID", function()
    local code, e = json(dir, { "capture", "-t", "p", "--field", "Title=Call Bob", "--field", "where=phone", "--id" })
    eq(0, code)
    eq("p", e.data.template)
    eq("entry", e.data.type)
    ok(same_path(dir .. "/inbox.org", e.data.file))
    eq("Call Bob", e.data.headline.title)
    ok(type(e.data.id) == "string")
    eq(e.data.id, e.data.headline.id)
    local inbox = table.concat(read(dir .. "/inbox.org"), "\n")
    ok(inbox:find(":Where:%s+phone"), inbox)
    code, e = json(dir, { "capture", "--input", "-" }, vim.json.encode({ template = "t", text = "From JSON" }))
    eq(0, code)
    eq("From JSON", e.data.headline.title)
    eq({ "Inbox" }, e.data.headline.outline_path)
    code, e = json(
      dir,
      { "capture", "--input", "-" },
      vim.json.encode({ template = "p", fields = { Title = "Fielded", Where = "x" } })
    )
    eq(0, code)
    eq("Fielded", e.data.headline.title)
    code, e = json(dir, { "capture", "--input", "-" }, "[1, 2")
    eq(2, code)
    eq("bad_value", e.errors[1].code)
  end)

  it("clocks in and out with JSON results", function()
    local code, e = json(dir, { "clock", "in", "notes-id" })
    eq(0, code)
    eq(true, e.data.active)
    eq("notes-id", e.data.id)
    eq(5, e.data.line)
    ok(e.data.start_iso:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d$"), e.data.start_iso)
    eq(90, e.data.effort)
    code, e = json(dir, { "clock", "out" })
    eq(0, code)
    eq(false, e.data.active)
    eq("0:00", e.data.duration)
    eq(false, e.data.canceled)
    _, e = json(dir, { "clock" })
    eq(false, e.data.active)
    eq(vim.NIL, e.data.title)
  end)

  it("refuses a file a running Neovim has unsaved changes in", function()
    if vim.fn.has("win32") == 1 then
      -- swap file names differ on Windows; the check is best effort there
      return
    end
    local file = dir .. "/home.org"
    busy_nvim(dir, file)
    local code, e = json(dir, { "set", "todo", "Buy milk", "DONE" })
    eq(4, code)
    eq("file_busy", e.errors[1].code)
    ok(same_path(file, e.errors[1].details.file))
    eq("* TODO Buy milk :errand:", read(file)[1])
    -- other files are fine, and --force writes anyway
    eq(0, (json(dir, { "set", "todo", "notes-id", "DONE" })))
    eq(0, (json(dir, { "set", "todo", "Buy milk", "DONE", "--force" })))
    ok(read(file)[1]:match("^%* DONE Buy milk%s+:errand:$"), read(file)[1])
  end)

  it("checks every file it would write before it changes any", function()
    if vim.fn.has("win32") == 1 then
      return
    end
    -- clocking in elsewhere clocks out of Buy milk: home.org changes too
    local d = workspace({ "  clock = { persist = false }," })
    local yesterday = os.date("%Y-%m-%d %a", os.time() - 86400)
    vim.fn.writefile({
      "* TODO Buy milk :errand:",
      "  :LOGBOOK:",
      "  CLOCK: [" .. yesterday .. " 10:00]",
      "  :END:",
      "* Projects",
    }, d .. "/home.org")
    local home, work_before = read(d .. "/home.org"), read(d .. "/work.org")
    busy_nvim(d, d .. "/home.org")
    local code, e = json(d, { "clock", "in", "Review pull request" })
    eq(4, code)
    eq("file_busy", e.errors[1].code)
    ok(same_path(d .. "/home.org", e.errors[1].details.file))
    -- no file changed: one clock, still on Buy milk
    eq(work_before, read(d .. "/work.org"))
    eq(home, read(d .. "/home.org"))
    eq("Buy milk", select(2, json(d, { "clock" })).data.title)
    stop_busy()
    vim.fn.delete(d, "rf")
  end)
end)

describe("cli json: a running Neovim a spec starts", function()
  local dir, pid
  after_each(function()
    stop_busy()
    vim.fn.delete(dir, "rf")
  end)

  it("is stopped after the spec, also one that fails before its end", function()
    dir = workspace()
    if vim.fn.has("win32") == 1 then
      return
    end
    pid = busy_nvim(dir, dir .. "/home.org").pid
    ok(alive(pid))
    -- nothing stops it here: the after_each does
  end)

  it("(the previous spec's Neovim is gone)", function()
    dir = workspace()
    if vim.fn.has("win32") == 1 then
      return
    end
    ok(pid)
    eq(false, alive(pid))
  end)
end)

describe("cli: saving the changed files", function()
  local d
  after_each(function()
    require("org.write_hooks").unregister("cli-spec")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find(d, 1, true) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    vim.fn.delete(d, "rf")
  end)

  it("writes none of them unless it can write them all", function()
    d = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(d, "p")
    vim.fn.writefile({ "* A" }, d .. "/a.org")
    vim.fn.writefile({ "* B" }, d .. "/b.org")
    local a, b = cli.load_buffer(d .. "/a.org"), cli.load_buffer(d .. "/b.org")
    vim.api.nvim_buf_set_lines(a, 0, -1, false, { "* A changed" })
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* B changed" })
    -- b.org has unsaved changes in a running Neovim
    local guard = cli.guard
    cli.guard = function(path)
      if path:find("b.org", 1, true) then
        cli.fail("busy", "file_busy")
      end
    end
    local saved, e = pcall(cli.save_all, {})
    cli.guard = guard
    eq(false, saved)
    eq("file_busy", e.ecode)
    eq({ "* A" }, vim.fn.readfile(d .. "/a.org"))
    -- a write hook refuses b.org (org-crypt without a passphrase, ...)
    require("org.write_hooks").register("cli-spec", {
      pre = function(buf)
        if vim.api.nvim_buf_get_name(buf):find("b.org", 1, true) then
          return false, "refused"
        end
      end,
    })
    saved = pcall(cli.save_all, {})
    eq(false, saved)
    eq({ "* A" }, vim.fn.readfile(d .. "/a.org"))
    eq({ "* B" }, vim.fn.readfile(d .. "/b.org"))
    require("org.write_hooks").unregister("cli-spec")
    cli.save_all({})
    eq({ "* A changed" }, vim.fn.readfile(d .. "/a.org"))
    eq({ "* B changed" }, vim.fn.readfile(d .. "/b.org"))
  end)
end)

describe("cli json: schema", function()
  it("describes every command the CLI runs", function()
    local doc = schema.describe()
    local names = {}
    for _, c in ipairs(doc.commands) do
      names[c.name] = true
      ok(c.summary and c.usage:match("^org "), c.name)
      eq("object", c.input_schema.type)
      ok(c.output, c.name)
      for _, a in ipairs(c.args) do
        ok(c.input_schema.properties[a.name], c.name .. " " .. a.name)
      end
    end
    for name in pairs(cli.COMMANDS) do
      ok(names[name], "no schema for " .. name)
    end
    for name in pairs(names) do
      ok(cli.COMMANDS[name] or name == "help", "no command for " .. name)
    end
    eq(schema.VERSION, doc.version)
    ok(doc["$defs"].Headline and doc["$defs"].Timestamp and doc["$defs"].Entry)
  end)

  it("prints the schema, alone or for one command", function()
    local dir = workspace()
    local code, stdout = run(dir, { "schema" })
    eq(0, code)
    local doc = vim.json.decode(stdout)
    eq("org", doc.name)
    local _, one = run(dir, { "schema", "set", "todo" })
    eq(
      { "set todo" },
      vim.tbl_map(function(c)
        return c.name
      end, vim.json.decode(one).commands)
    )
    local _, e = json(dir, { "help" })
    eq(true, e.ok)
    eq("schema", e.command)
    eq(#doc.commands, #e.data.commands)
    _, e = json(dir, { "set", "tags", "--help" })
    eq("set tags", e.data.commands[1].name)
    local c2 = json(dir, { "schema", "nope" })
    eq(2, c2)
    vim.fn.delete(dir, "rf")
  end)
end)

describe("cli json: helpers", function()
  it("reads the question of a prompt", function()
    eq("Title", cli.prompt_label("Title: "))
    eq("Title", cli.prompt_label({ prompt = "Title [x]: " }))
    eq("Deadline", cli.prompt_label("Deadline Date+time [2026-10-01]: "))
    eq("", cli.prompt_label("Date+time [2026-10-01 10:00]: "))
  end)

  it("collects repeatable flags and rejects flags of other commands", function()
    local flags, words =
      cli.parse_args({ "headlines", "--todo", "TODO,NEXT", "--tag", "a", "--tag=b", "--field", "x=1,2" })
    eq({ "TODO", "NEXT" }, flags.todo)
    eq({ "a", "b" }, flags.tag)
    eq({ "x=1,2" }, flags.field)
    eq({ "headlines" }, words)
    local saved = cli.stdout
    local text = {}
    cli.stdout = function(s)
      text[#text + 1] = s
    end
    local code = cli.main({ "--json", "version", "--todo", "x" })
    cli.stdout = saved
    eq(2, code)
    eq("unknown_option", vim.json.decode(table.concat(text)).errors[1].code)
  end)
end)

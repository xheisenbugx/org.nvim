-- Benchmarks: opening the first org file, and the agenda over a large
-- corpus (tests/helpers/gen.lua agenda_corpus: 200 files, 50,000
-- headlines). Prints a Markdown table of medians and the machine it ran
-- on. `make bench` runs it with throwaway data and cache directories:
--
--   make bench                          # 5 runs of each
--   make bench ARGS="--runs 9"          # more runs
--   make bench ARGS="--files 50"        # a smaller corpus (250 headlines a file)
--   make bench ARGS="--json"            # the numbers as JSON
--
-- Every measurement runs in a Neovim of its own (a new session), the
-- agenda ones with `agenda.index.background` and `watch` off (but the last
-- one), so what is timed is the view itself:
--
--   cold week     a week agenda, no agenda index on disk: every file read
--                 and parsed
--   warm week     the same from the agenda index (:h org-agenda-index)
--   hot week      the week again in the same session (files in memory)
--   tags match    a tags view, "+work-home" (after the week)
--   TODO list     every TODO entry (after the week)
--   refresh       the week rebuilt (`r`) after one file was edited
--                 and saved
--   background    the week once the background parse is done, with
--                 `agenda.index.start = "startup"` and the index on disk:
--                 the first agenda of a session that waited a moment
--
-- See "Performance budgets" in CONTRIBUTING.md.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local args = _G.arg or {}

local function opt(name, default)
  for i, a in ipairs(args) do
    if a == name then
      return args[i + 1]
    end
  end
  return default
end
local function flag(name)
  return vim.tbl_contains(args, name)
end

local ANCHOR = "<2026-05-13 Wed>"

local function ms_since(t)
  return (vim.uv.hrtime() - t) / 1e6
end

---------------------------------------------------------------------------
-- Child: one session, prints a JSON line of timings
---------------------------------------------------------------------------

local function child(scenario, dir)
  vim.opt.rtp:prepend(root)
  vim.opt.swapfile = false
  vim.opt.shadafile = "NONE"
  vim.env.ORG_NVIM_SERVER = "none"
  vim.cmd("runtime plugin/org.lua")
  local idx = { background = false, watch = false }
  if scenario == "background" then
    idx = { start = "startup", watch = false }
  end
  require("org").setup({ agenda_files = { dir }, agenda = { index = idx } })
  local files = require("org.files")
  local index = require("org.agenda.index")
  local agenda = require("org.agenda")
  local anchor = require("org.date").parse(ANCHOR):days()
  local out = {}
  local function timed(key, fn)
    collectgarbage()
    local t = vim.uv.hrtime()
    fn()
    vim.cmd("redraw")
    out[key] = ms_since(t)
    -- (the lines of the view: what it found)
    if vim.bo.filetype == "orgagenda" then
      out[key .. "_lines"] = vim.api.nvim_buf_line_count(0)
    end
  end
  local function week()
    agenda.open({ type = "agenda" }, { span = "week", anchor = anchor })
  end

  if scenario == "index" then
    -- build the agenda index on disk
    os.remove(index.path())
    files.agenda_files()
    index.flush()
  elseif scenario == "cold" then
    os.remove(index.path())
    timed("cold_week", week)
  elseif scenario == "background" then
    -- (the background starts half a second after startup, later on a
    -- busy machine)
    vim.wait(10000, function()
      local st = index.status()
      return st.warming or st.hits + st.indexed > 0
    end, 10)
    assert(index.wait(5 * 60 * 1000), "the background parse did not finish")
    local st = index.status()
    assert(st.hits + st.indexed > 0, "the background parse did not start")
    timed("background_week", week)
  elseif scenario == "warm" then
    timed("warm_week", week)
    timed("hot_week", week)
    timed("tags", function()
      agenda.open({ type = "tags", match = "+work-home" })
    end)
    timed("todo", function()
      agenda.open({ type = "todo" })
    end)
    week()
    -- edit one file and save it, as from another window
    local path = dir .. "/project001.org"
    local before = vim.fn.readfile(path)
    local lines = vim.list_extend(vim.deepcopy(before), { "* TODO Added", "SCHEDULED: " .. ANCHOR })
    vim.fn.writefile(lines, path)
    timed("refresh", function()
      require("org.agenda.view").redo()
    end)
    -- put it back and the index with it, for the next run
    vim.fn.writefile(before, path)
    files.agenda_files()
    index.flush()
  end
  io.stdout:write(vim.json.encode(out) .. "\n")
  vim.cmd("qa!")
end

---------------------------------------------------------------------------
-- Parent: the corpus, the runs, the table
---------------------------------------------------------------------------

local function run_child(cmd)
  local res = vim.system(cmd, { text = true }):wait(30 * 60 * 1000)
  if res.code ~= 0 then
    error(("%s failed (%d):\n%s%s"):format(table.concat(cmd, " "), res.code, res.stdout or "", res.stderr or ""))
  end
  local lines = vim.split(vim.trim(res.stdout), "\n")
  return vim.json.decode(lines[#lines])
end

local function median(xs)
  local s = vim.deepcopy(xs)
  table.sort(s)
  local n = #s
  if n == 0 then
    return nil
  end
  return n % 2 == 1 and s[(n + 1) / 2] or (s[n / 2] + s[n / 2 + 1]) / 2
end

local function machine()
  local cpus = vim.uv.cpu_info() or {}
  local uname = vim.uv.os_uname()
  local v = vim.version()
  return {
    os = ("%s %s (%s)"):format(uname.sysname, uname.release, uname.machine),
    cpu = ("%s, %d threads"):format(cpus[1] and vim.trim(cpus[1].model) or "?", #cpus),
    memory = ("%.0f GB"):format(vim.uv.get_total_memory() / 2 ^ 30),
    nvim = ("%d.%d.%d%s"):format(v.major, v.minor, v.patch, v.prerelease and "-dev" or ""),
    luajit = jit and jit.version or _VERSION,
    load = (function()
      local a, b, c = vim.uv.loadavg()
      return ("%.1f %.1f %.1f"):format(a, b, c)
    end)(),
  }
end

local function parent()
  package.path = root .. "/?.lua;" .. package.path
  local gen = require("tests.helpers.gen")
  local runs = tonumber(opt("--runs", "5")) or 5
  local nfiles = tonumber(opt("--files", "200")) or 200
  local per_file = tonumber(opt("--headlines", "250")) or 250
  local json = flag("--json")
  local function say(msg)
    if not json then
      io.stderr:write(msg .. "\n")
    end
  end

  local dir = vim.fn.tempname() .. "-bench"
  vim.fn.mkdir(dir, "p")
  local headlines, bytes = 0, 0
  for _, f in ipairs(gen.agenda_corpus(nfiles, per_file)) do
    vim.fn.writefile(f.lines, dir .. "/" .. f.name)
    for _, l in ipairs(f.lines) do
      bytes = bytes + #l + 1
      if l:byte(1) == 42 then
        headlines = headlines + 1
      end
    end
  end
  say(("corpus: %d files, %d headlines, %.1f MB in %s"):format(nfiles, headlines, bytes / 2 ^ 20, dir))

  local nvim = { vim.v.progpath, "--clean", "--headless", "-l" }
  local function bench(scenario)
    return run_child(vim.list_extend(vim.deepcopy(nvim), { root .. "/scripts/bench.lua", "--child", scenario, dir }))
  end
  local samples = {}
  local function add(res)
    for k, v in pairs(res) do
      samples[k] = samples[k] or {}
      table.insert(samples[k], v)
    end
  end
  for i = 1, runs do
    say(("run %d/%d"):format(i, runs))
    add(run_child(vim.list_extend(vim.deepcopy(nvim), {
      root .. "/tests/helpers/first_open.lua",
      root,
      root .. "/tests/fixtures/first_open.org",
    })))
    add(bench("cold"))
  end
  bench("index")
  for _ = 1, runs do
    add(bench("warm"))
    add(bench("background"))
  end
  vim.fn.delete(dir, "rf")

  local rows = {
    { "setup()", "setup_ms" },
    { "open the first org file (plain, 35 lines)", "open_ms" },
    { ("cold week agenda (no index, %d files)"):format(nfiles), "cold_week" },
    { "warm week agenda (from the agenda index)", "warm_week" },
    { "hot week agenda (files in memory)", "hot_week" },
    { 'tags match "+work-home"', "tags" },
    { "TODO list", "todo" },
    { "refresh the week after editing one file", "refresh" },
    { "week agenda after the background parse (start = startup)", "background_week" },
  }
  local info = machine()
  local result = { machine = info, runs = runs, files = nfiles, headlines = headlines, ms = {} }
  for _, r in ipairs(rows) do
    result.ms[r[2]] = median(samples[r[2]] or {})
  end
  result.modules = samples.modules and #samples.modules[1] or nil
  if json then
    io.stdout:write(vim.json.encode(result) .. "\n")
    return
  end
  local out = {
    ("Neovim %s, %s, %s, %s RAM; load average %s"):format(info.nvim, info.os, info.cpu, info.memory, info.load),
    ("Median of %d runs, each in a new Neovim. Corpus: %d files, %d headlines."):format(runs, nfiles, headlines),
    "",
    "| Operation | ms | agenda lines |",
    "| --- | ---: | ---: |",
  }
  for _, r in ipairs(rows) do
    local v = result.ms[r[2]]
    local lines = samples[r[2] .. "_lines"]
    out[#out + 1] = ("| %s | %s | %s |"):format(
      r[1],
      v and ("%.0f"):format(v) or "-",
      lines and tostring(lines[1]) or ""
    )
  end
  io.stdout:write(table.concat(out, "\n") .. "\n")
end

if flag("--child") then
  child(opt("--child"), args[#args])
else
  parent()
end

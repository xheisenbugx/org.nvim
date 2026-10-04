-- Tiny busted-style test runner.
-- Usage: nvim --headless -u tests/minimal_init.lua -l tests/run.lua [spec files...]
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local results = { passed = 0, failed = 0, errors = {}, skipped = {} }
local stack = {}
local befores = {}
local afters = {}

_G.describe = function(name, fn)
  table.insert(stack, name)
  table.insert(befores, {})
  table.insert(afters, {})
  -- an error in the body fails the describe, not the specs of later files:
  -- they would run with its name and its before_each/after_each hooks
  local ok, err = pcall(fn)
  if not ok then
    results.failed = results.failed + 1
    table.insert(results.errors, { name = table.concat(stack, " > "), err = err })
  end
  table.remove(afters)
  table.remove(befores)
  table.remove(stack)
end

_G.before_each = function(fn)
  table.insert(befores[#befores], fn)
end

_G.after_each = function(fn)
  table.insert(afters[#afters], fn)
end

--- Inside a describe: set top-level config options for each of its tests
--- and restore them afterwards (specs written for a non-default setup,
--- e.g. a NEXT keyword or logging into LOGBOOK).
_G.with_config = function(overrides)
  local saved
  before_each(function()
    local opts = require("org.config").opts
    saved = {}
    for k, v in pairs(overrides) do
      saved[k] = { opts[k] }
      opts[k] = vim.deepcopy(v)
    end
  end)
  after_each(function()
    local opts = require("org.config").opts
    for k, v in pairs(saved or {}) do
      opts[k] = v[1]
    end
  end)
end

_G.it = function(name, fn)
  local full = table.concat(stack, " > ") .. " > " .. name
  if vim.env.ORG_TEST_PROGRESS == "2" then
    io.stderr:write("   " .. full .. "\n")
    io.stderr:flush()
  end
  -- specs call commands directly, which read v:count: don't let one test's
  -- count (e.g. a fed "3<C-c><C-s>") leak into the next
  vim.cmd("normal! \27")
  local ok, err = pcall(function()
    for _, level in ipairs(befores) do
      for _, b in ipairs(level) do
        b()
      end
    end
    fn()
  end)
  for i = #afters, 1, -1 do
    for _, a in ipairs(afters[i]) do
      local aok, aerr = pcall(a)
      if ok and not aok then
        ok, err = false, aerr
      end
    end
  end
  if ok then
    results.passed = results.passed + 1
  elseif type(err) == "table" and err.skip then
    results.skipped[#results.skipped + 1] = full .. " (" .. err.skip .. ")"
  else
    results.failed = results.failed + 1
    table.insert(results.errors, { name = full, err = err })
  end
end

local function fmt(v)
  return vim.inspect(v)
end

_G.eq = function(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error((msg and (msg .. ": ") or "") .. "expected " .. fmt(expected) .. ", got " .. fmt(actual), 2)
  end
end

_G.ok = function(v, msg)
  if not v then
    error(msg or ("expected truthy, got " .. fmt(v)), 2)
  end
end

--- Create a scratch org buffer with `lines`, make it current, cursor at {lnum, col0}.
_G.org_buffer = function(lines, cursor)
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "org"
  if cursor then
    vim.api.nvim_win_set_cursor(0, cursor)
  end
  return buf
end

_G.buf_lines = function(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

local is_win = vim.fn.has("win32") == 1

--- A fake program `name` in `dir` running the POSIX shell script `body`
--- (with or without its #! line). On Windows, where a script isn't
--- executable, `name.cmd` runs it with sh (Git for Windows' on CI). Returns
--- the path to run it by.
_G.fake_exe = function(dir, name, body)
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. name
  if not body:match("^#!") then
    body = "#!/bin/sh\n" .. body
  end
  local f = assert(io.open(path, "wb"))
  f:write(body, body:sub(-1) == "\n" and "" or "\n")
  f:close()
  vim.uv.fs_chmod(path, tonumber("755", 8))
  if not is_win then
    return path
  end
  local cmd = assert(io.open(path .. ".cmd", "wb"))
  cmd:write('@sh "%~dpn0" %*\r\n')
  cmd:close()
  return path .. ".cmd"
end

--- Put `dir` first on $PATH (with the platform's separator).
_G.path_prepend = function(dir)
  vim.env.PATH = dir .. (is_win and ";" or ":") .. (vim.env.PATH or "")
end

--- Skip the rest of the current spec on Windows, which can't do `reason`
--- (Unix file modes, POSIX time zone names in TZ, ...).
_G.skip_on_windows = function(reason)
  if is_win then
    error({ skip = reason }, 0)
  end
end

--- The TZ value for the zone `name` ("America/New_York"), for a spec
--- simulating another zone. Skipped on Windows: its C runtime takes no zone
--- names and reads TZ once per process, so the zone can't change while the
--- specs run.
_G.tz = function(name)
  if is_win and name ~= nil then
    skip_on_windows("the Windows C runtime reads TZ once per process and takes no zone names")
  end
  return name
end

--- Inside a describe: run 'shell' commands with sh (Git for Windows' on
--- Windows) for its specs, which give the plugin POSIX shell commands
--- ("cp %f %b.pdf", 'quotes', ;). Elsewhere 'shell' already is one.
_G.posix_shell = function()
  if not (is_win and vim.fn.executable("sh") == 1) then
    return
  end
  local keys = { "shell", "shellcmdflag", "shellquote", "shellxquote", "shellredir", "shellpipe" }
  local saved
  before_each(function()
    saved = {}
    for _, k in ipairs(keys) do
      saved[k] = vim.o[k]
    end
    vim.o.shell, vim.o.shellcmdflag, vim.o.shellquote, vim.o.shellxquote = "sh", "-c", "", ""
    vim.o.shellredir, vim.o.shellpipe = ">%s 2>&1", "2>&1| tee"
  end)
  after_each(function()
    for k, v in pairs(saved or {}) do
      vim.o[k] = v
    end
  end)
end

-- Temp names in the form the plugin works with: forward slashes, and the
-- long form of 8.3 short names (C:\Users\RUNNER~1\...), as on other systems
-- expectations are built from them.
if is_win then
  local tempname = vim.fn.tempname
  vim.fn.tempname = function()
    local p = tempname()
    local dir, base = p:match("^(.*)[/\\]([^/\\]+)$")
    return vim.fs.normalize(require("org.utils").realpath(dir) or dir) .. "/" .. base
  end
end

-- What specs stub: a spec that fails before putting a function or an
-- environment variable back would break the specs of later files (e.g. a
-- no-op utils.notify hides every later warning). Each file starts from the
-- state the previous one found.
local VIM_FNS = {
  { vim, "notify" },
  { vim, "system" },
  { vim.ui, "select" },
  { vim.ui, "input" },
  { vim.fn, "input" },
  { vim.fn, "confirm" },
  { vim.fn, "getchar" },
  { vim.fn, "inputlist" },
  { vim.fn, "has" },
  { vim.fn, "executable" },
  { os, "time" },
  { os, "date" },
  { os, "getenv" },
}

local function snapshot()
  local s = { vim = {}, modules = {}, env = vim.fn.environ() }
  for i, f in ipairs(VIM_FNS) do
    s.vim[i] = f[1][f[2]]
  end
  for name, mod in pairs(package.loaded) do
    if type(name) == "string" and name:match("^org[%.]") or name == "org" then
      if type(mod) == "table" then
        local fns = {}
        for k, v in pairs(mod) do
          if type(v) == "function" then
            fns[k] = v
          end
        end
        s.modules[name] = fns
      end
    end
  end
  return s
end

local function restore(s)
  -- and no buffers: a modified one left by a failing spec makes a later
  -- :edit fail with E37
  vim.cmd("silent! %bwipeout!")
  for i, f in ipairs(VIM_FNS) do
    f[1][f[2]] = s.vim[i]
  end
  for name, fns in pairs(s.modules) do
    local mod = package.loaded[name]
    if type(mod) == "table" then
      for k, v in pairs(fns) do
        if mod[k] ~= v then
          mod[k] = v
        end
      end
    end
  end
  -- names are case-insensitive on Windows (Path and PATH are one variable)
  local function fold(k)
    return is_win and k:upper() or k
  end
  local before = {}
  for k in pairs(s.env) do
    before[fold(k)] = true
  end
  for k in pairs(vim.fn.environ()) do
    if not before[fold(k)] then
      vim.env[k] = nil
    end
  end
  for k, v in pairs(s.env) do
    if vim.env[k] ~= v then
      vim.env[k] = v
    end
  end
  -- the C library reads TZ once: make it read it again
  pcall(function()
    require("org.date").set_tz(s.env.TZ)
  end)
end

--- Whether `make coverage` runs the specs: the JIT is off and every line
--- is counted, so a spec's time limits don't hold.
_G.under_coverage = function()
  return package.loaded["tests.coverage"] ~= nil
end

--- `make coverage`: this Neovim's line counts (tests/coverage.lua).
local function write_coverage()
  local cov = package.loaded["tests.coverage"]
  if cov then
    cov.write()
  end
end

local files = _G.arg and #_G.arg > 0 and _G.arg or vim.fn.glob(root .. "/tests/spec/**/*_spec.lua", false, true)
local progress = vim.env.ORG_TEST_PROGRESS

--- Spec files that time their work: a parallel run starts them after every
--- other file has finished, one at a time, so no other spec file competes
--- with them for the CPUs (their growth checks failed now and then when
--- the 2n run shared the machine with a heavier neighbour than the n run).
local function solo(f)
  return f:match("perf_budgets_spec%.lua$") ~= nil
end

local function file_size(f)
  local st = vim.uv.fs_stat(f)
  return st and st.size or 0
end

-- ORG_TEST_PERF=0 leaves out the timed files (CI times them in a job of
-- their own)
if vim.env.ORG_TEST_PERF == "0" and vim.env.ORG_TEST_WORKER ~= "1" then
  files = vim.tbl_filter(function(f)
    return not solo(f)
  end, files)
end

-- ORG_TEST_SHARD=i/n runs the i-th of n shares of the files (CI splits the
-- slow Windows run over several runners): the biggest files first, each to
-- the share with the fewest bytes so far, so every share gets a similar load
-- and the same files on every run.
local shard_i, shard_n = (vim.env.ORG_TEST_SHARD or ""):match("^(%d+)/(%d+)$")
shard_i, shard_n = tonumber(shard_i), tonumber(shard_n)
if shard_n and shard_n > 1 and vim.env.ORG_TEST_WORKER ~= "1" then
  assert(shard_i >= 1 and shard_i <= shard_n, "ORG_TEST_SHARD: expected i/n with 1 <= i <= n")
  local sorted = vim.deepcopy(files)
  table.sort(sorted, function(a, b)
    local sa, sb = file_size(a), file_size(b)
    if sa ~= sb then
      return sa > sb
    end
    return a < b
  end)
  local load, mine = {}, {}
  for s = 1, shard_n do
    load[s] = 0
  end
  for _, f in ipairs(sorted) do
    local s = 1
    for t = 2, shard_n do
      if load[t] < load[s] then
        s = t
      end
    end
    load[s] = load[s] + file_size(f)
    if s == shard_i then
      mine[#mine + 1] = f
    end
  end
  files = mine
end

--- Run each spec file in its own Neovim, `jobs` at a time, and report the
--- totals like a serial run. Every worker gets a fresh XDG_DATA_HOME and
--- XDG_CACHE_HOME, so workers don't share the ID database, clock state or
--- agenda index, and no state leaks from one file into the next.
local function run_parallel(jobs)
  local timeout = (tonumber(vim.env.ORG_TEST_TIMEOUT) or 600) * 1000
  local uv = vim.uv
  -- the biggest files first, so a slow one doesn't start last; the timed
  -- files after all of them
  local queue = vim.deepcopy(files)
  local size = {}
  for _, f in ipairs(queue) do
    size[f] = file_size(f)
  end
  table.sort(queue, function(a, b)
    if solo(a) ~= solo(b) then
      return solo(b)
    end
    return size[a] > size[b]
  end)
  local running, finished, outputs = {}, 0, {}
  local start = uv.hrtime()
  local function launch(f)
    local data = vim.fn.tempname()
    vim.fn.mkdir(data, "p")
    if progress and progress ~= "" then
      io.stderr:write("== " .. vim.fn.fnamemodify(f, ":t") .. "\n")
      io.stderr:flush()
    end
    local job = {
      file = f,
      data = data,
      started = uv.hrtime(),
    }
    job.proc = vim.system({
      vim.v.progpath,
      "--headless",
      "-u",
      root .. "/tests/minimal_init.lua",
      "-l",
      root .. "/tests/run.lua",
      f,
    }, {
      text = true,
      env = {
        XDG_DATA_HOME = data,
        XDG_CACHE_HOME = data .. "/cache",
        ORG_TEST_WORKER = "1",
        ORG_TEST_JOBS = "1",
        ORG_TEST_PROGRESS = "",
        ORG_TEST_RESULT = data .. "/result.json",
      },
    }, function(res)
      job.res = res
    end)
    running[#running + 1] = job
  end
  local function collect(job)
    local res = job.res
    local entry = {
      file = job.file,
      out = (res.stdout or "") .. "\n" .. (res.stderr or ""),
      seconds = (uv.hrtime() - job.started) / 1e9,
    }
    local f = io.open(job.data .. "/result.json", "rb")
    if f then
      local ok, r = pcall(vim.json.decode, f:read("*a"))
      f:close()
      if ok and type(r) == "table" then
        entry.result = r
      end
    end
    local crashed = job.timed_out or res.code ~= 0 or (res.signal or 0) ~= 0
    if not entry.result or (crashed and entry.result.failed == 0) then
      entry.crash = job.timed_out and string.format("timed out after %d s", timeout / 1000)
        or ((res.signal or 0) ~= 0 and ("killed by signal " .. res.signal))
        or (res.code ~= 0 and ("exited with code " .. tostring(res.code)))
        or "exited without results"
    end
    outputs[#outputs + 1] = entry
    vim.fn.delete(job.data, "rf")
  end
  local n = math.min(jobs, #queue)
  local function may_launch()
    if #queue == 0 then
      return false
    end
    if solo(queue[1]) then
      return #running == 0
    end
    return #running < n
  end
  while #queue > 0 or #running > 0 do
    while may_launch() do
      launch(table.remove(queue, 1))
    end
    vim.wait(50, function()
      for _, job in ipairs(running) do
        if job.res then
          return true
        end
      end
      return false
    end, 10)
    for i = #running, 1, -1 do
      local job = running[i]
      if not job.res and (uv.hrtime() - job.started) / 1e6 > timeout then
        job.timed_out = true
        job.proc:kill(9)
        job.proc:wait(1000)
        job.res = job.res or { code = -1, stdout = "", stderr = "" }
      end
      if job.res then
        table.remove(running, i)
        finished = finished + 1
        collect(job)
      end
    end
  end
  table.sort(outputs, function(a, b)
    return a.file < b.file
  end)
  local passed, failed, skips = 0, 0, {}
  for _, e in ipairs(outputs) do
    local r = e.result or { passed = 0, failed = 0, errors = {}, skipped = {} }
    passed = passed + (r.passed or 0)
    failed = failed + (r.failed or 0)
    for _, err in ipairs(r.errors or {}) do
      io.stdout:write("FAIL: " .. err.name .. "\n    " .. tostring(err.err):gsub("\n", "\n    ") .. "\n")
    end
    for _, sk in ipairs(r.skipped or {}) do
      skips[#skips + 1] = sk
    end
    if e.crash then
      failed = failed + 1
      io.stdout:write("FAIL: " .. vim.fn.fnamemodify(e.file, ":.") .. ": " .. e.crash .. "\n")
      local tail = vim.trim(e.out):sub(-2000)
      if tail ~= "" then
        io.stdout:write("    " .. tail:gsub("\n", "\n    ") .. "\n")
      end
    end
  end
  for _, sk in ipairs(skips) do
    io.stdout:write("SKIP: " .. sk .. "\n")
  end
  io.stdout:write(
    string.format(
      "\n%d passed, %d failed%s\n",
      passed,
      failed,
      #skips > 0 and string.format(", %d skipped", #skips) or ""
    )
  )
  -- where the time went, to see which files to split or speed up
  table.sort(outputs, function(a, b)
    return a.seconds > b.seconds
  end)
  local slowest = {}
  for i = 1, math.min(5, #outputs) do
    slowest[i] = string.format("%s %.1f s", vim.fn.fnamemodify(outputs[i].file, ":t"), outputs[i].seconds)
  end
  io.stderr:write("slowest: " .. table.concat(slowest, ", ") .. "\n")
  io.stderr:write(string.format("%d files, %d jobs, %.1f s\n", #files, n, (uv.hrtime() - start) / 1e9))
  write_coverage()
  vim.cmd(failed > 0 and "cquit 1" or "qall!")
end

-- ORG_TEST_JOBS=1 runs every file in this Neovim, one after another
local jobs = tonumber(vim.env.ORG_TEST_JOBS or "")
  or (vim.uv.available_parallelism and vim.uv.available_parallelism())
  or 1
if jobs > 1 and #files > 1 and vim.env.ORG_TEST_WORKER ~= "1" then
  run_parallel(jobs)
  return
end

for _, f in ipairs(files) do
  if progress and progress ~= "" then
    -- which file a hanging run is in
    io.stderr:write("== " .. vim.fn.fnamemodify(f, ":t") .. "\n")
    io.stderr:flush()
  end
  local state = snapshot()
  local ok, err = pcall(dofile, f)
  if not ok then
    results.failed = results.failed + 1
    table.insert(results.errors, { name = "load " .. f, err = err })
  end
  restore(state)
end

if vim.env.ORG_TEST_RESULT then
  -- a parallel run's worker: the totals for the parent, which can't read
  -- them reliably from stdout (messages may share the summary's line)
  local errors = {}
  for _, e in ipairs(results.errors) do
    errors[#errors + 1] = { name = e.name, err = tostring(e.err) }
  end
  local f = io.open(vim.env.ORG_TEST_RESULT, "wb")
  if f then
    f:write(vim.json.encode({
      passed = results.passed,
      failed = results.failed,
      errors = errors,
      skipped = results.skipped,
    }))
    f:close()
  end
end

for _, e in ipairs(results.errors) do
  io.stdout:write("FAIL: " .. e.name .. "\n    " .. tostring(e.err):gsub("\n", "\n    ") .. "\n")
end
for _, s in ipairs(results.skipped) do
  io.stdout:write("SKIP: " .. s .. "\n")
end
io.stdout:write(
  string.format(
    "\n%d passed, %d failed%s\n",
    results.passed,
    results.failed,
    #results.skipped > 0 and string.format(", %d skipped", #results.skipped) or ""
  )
)
write_coverage()
vim.cmd(results.failed > 0 and "cquit 1" or "qall!")

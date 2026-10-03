-- Merge the line counts of a `make coverage` run into a report.
--
--   nvim --clean --headless -l scripts/coverage_report.lua COUNTS_DIR OUT_DIR
--
-- COUNTS_DIR holds the <pid>.json files tests/coverage.lua wrote. Writes to
-- OUT_DIR:
--   report.md      per-module table, lowest coverage first, with a summary
--   summary.md     the totals and the 20 lowest modules (for CI summaries)
--   missed.txt     the line ranges no spec ran, per module
--   coverage.json  { [module] = { lines, hit, missed = { ranges } } }
-- and prints the summary. The executable lines of a module are the lines
-- LuaJIT emits bytecode for, from its compiled chunk (jit.util).
local counts_dir, out_dir = arg[1], arg[2]
if not counts_dir or not out_dir then
  io.stderr:write("usage: coverage_report.lua COUNTS_DIR OUT_DIR\n")
  os.exit(2)
end
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local ju = require("jit.util")

--- Lines with bytecode in `fn` and every function nested in it.
local function code_lines(fn, out)
  local pc = 1
  while ju.funcbc(fn, pc) do
    local line = ju.funcinfo(fn, pc).currentline
    if line then
      out[line] = true
    end
    pc = pc + 1
  end
  local k = -1
  while true do
    local c = ju.funck(fn, k)
    if c == nil then
      break
    end
    if type(c) == "proto" then
      code_lines(c, out)
    end
    k = k - 1
  end
  return out
end

-- the counts of every Neovim of the run
local hits = {}
local nfiles = 0
for _, path in ipairs(vim.fn.glob(counts_dir .. "/*.json", false, true)) do
  local f = assert(io.open(path, "rb"))
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  if ok and type(data) == "table" then
    nfiles = nfiles + 1
    for mod, lines in pairs(data) do
      local t = hits[mod] or {}
      for l, n in pairs(lines) do
        l = tonumber(l)
        t[l] = (t[l] or 0) + n
      end
      hits[mod] = t
    end
  end
end
if nfiles == 0 then
  io.stderr:write("no coverage counts in " .. counts_dir .. "\n")
  os.exit(1)
end

--- "3-7, 12" from a sorted list of line numbers.
local function ranges(list)
  local out, i = {}, 1
  while i <= #list do
    local j = i
    while list[j + 1] == list[j] + 1 do
      j = j + 1
    end
    out[#out + 1] = i == j and tostring(list[i]) or (list[i] .. "-" .. list[j])
    i = j + 1
  end
  return out
end

local rows = {}
local total, total_hit = 0, 0
for _, path in ipairs(vim.fn.glob(root .. "/lua/org/**/*.lua", false, true)) do
  local rel = path:sub(#root + 2):gsub("\\", "/")
  -- lua/org/_meta: annotations only, never loaded
  if not rel:match("^lua/org/_meta/") then
    local fn = loadfile(path)
    if fn then
      local exec = code_lines(fn, {})
      local h = hits[rel] or {}
      local n, hit, missed = 0, 0, {}
      for l in pairs(exec) do
        n = n + 1
        if h[l] then
          hit = hit + 1
        else
          missed[#missed + 1] = l
        end
      end
      table.sort(missed)
      total, total_hit = total + n, total_hit + hit
      local mod = rel:gsub("^lua/", ""):gsub("/init%.lua$", ""):gsub("%.lua$", ""):gsub("/", ".")
      rows[#rows + 1] = {
        module = mod,
        file = rel,
        lines = n,
        hit = hit,
        pct = n > 0 and hit * 100 / n or 100,
        missed = ranges(missed),
      }
    end
  end
end
table.sort(rows, function(a, b)
  if a.pct ~= b.pct then
    return a.pct < b.pct
  end
  return a.module < b.module
end)

local pct = total > 0 and total_hit * 100 / total or 0
local loaded = 0
for _, r in ipairs(rows) do
  if r.hit > 0 then
    loaded = loaded + 1
  end
end

local function row_line(r)
  return ("| `%s` | %.1f%% | %d | %d |"):format(r.module, r.pct, r.hit, r.lines)
end
local header = { "| Module | Coverage | Lines run | Lines |", "| --- | ---: | ---: | ---: |" }
local summary = {
  "## Line coverage of lua/org",
  "",
  ("**%.1f%%** of %d lines in %d modules (%d never loaded by a spec), from %d test processes."):format(
    pct,
    total,
    #rows,
    #rows - loaded,
    nfiles
  ),
  "",
  "### The 20 lowest",
  "",
}
vim.list_extend(summary, header)
for i = 1, math.min(20, #rows) do
  summary[#summary + 1] = row_line(rows[i])
end

local report = vim.list_extend({}, summary, 1, 3)
report[#report + 1] = ""
report[#report + 1] = "### Every module, lowest first"
report[#report + 1] = ""
vim.list_extend(report, header)
for _, r in ipairs(rows) do
  report[#report + 1] = row_line(r)
end

local missed, json = {}, {}
for _, r in ipairs(rows) do
  if #r.missed > 0 then
    missed[#missed + 1] = ("%s (%.1f%%): %s"):format(r.file, r.pct, table.concat(r.missed, ", "))
  end
  json[r.module] = { file = r.file, lines = r.lines, hit = r.hit, missed = r.missed }
end

vim.fn.mkdir(out_dir, "p")
local function write(name, text)
  local f = assert(io.open(out_dir .. "/" .. name, "wb"))
  f:write(text)
  f:close()
end
write("summary.md", table.concat(summary, "\n") .. "\n")
write("report.md", table.concat(report, "\n") .. "\n")
write("missed.txt", table.concat(missed, "\n") .. "\n")
write("coverage.json", vim.json.encode({ total = total, hit = total_hit, percent = pct, modules = json }))
io.stdout:write(table.concat(summary, "\n") .. "\n\nReport: " .. out_dir .. "/report.md\n")

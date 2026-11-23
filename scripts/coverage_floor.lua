-- Hold the line coverage of `make coverage` to the floors in
-- scripts/coverage_floor.txt, so a change can't quietly drop the tests of a
-- module.
--
--   nvim --clean --headless -l scripts/coverage_floor.lua COVERAGE_JSON [FLOOR_FILE] [--update]
--
-- COVERAGE_JSON is the coverage.json scripts/coverage_report.lua writes;
-- FLOOR_FILE defaults to scripts/coverage_floor.txt. Each line of the floor
-- file is a repo-relative path (a file, or a directory covering everything
-- under it) and its floor in percent; `#` starts a comment. The coverage of
-- a path is the lines run over the executable lines of every file it
-- covers. Exits 1 when a path is below its floor or covers no file.
--
-- --update rewrites the floor file with each path's coverage, rounded down
-- to a whole percent, less one (the slack for lines that only run on some
-- runs), keeping the comments and the order. A path without a number gets
-- one. Only meaningful after a full `make coverage` run.
local args = {}
local update = false
for _, a in ipairs(arg) do
  if a == "--update" then
    update = true
  else
    args[#args + 1] = a
  end
end
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local json_path, floor_path = args[1], args[2] or (root .. "/scripts/coverage_floor.txt")
if not json_path then
  io.stderr:write("usage: coverage_floor.lua COVERAGE_JSON [FLOOR_FILE] [--update]\n")
  os.exit(2)
end

local function read(path)
  local f, err = io.open(path, "rb")
  if not f then
    io.stderr:write(err .. "\n")
    os.exit(2)
  end
  local s = f:read("*a")
  f:close()
  return s
end

local ok, cov = pcall(vim.json.decode, read(json_path))
if not ok or type(cov) ~= "table" or type(cov.modules) ~= "table" then
  io.stderr:write(json_path .. ": not a coverage.json of scripts/coverage_report.lua\n")
  os.exit(2)
end

--- Lines run and executable lines of the files `path` covers.
local function measure(path)
  local hit, lines, files = 0, 0, 0
  for _, m in pairs(cov.modules) do
    local f = m.file or ""
    if f == path or f:sub(1, #path + 1) == path .. "/" then
      hit, lines, files = hit + (m.hit or 0), lines + (m.lines or 0), files + 1
    end
  end
  return files, lines > 0 and hit * 100 / lines or 100
end

local out, failures, report, seen = {}, {}, {}, {}
for line in (read(floor_path) .. "\n"):gmatch("([^\n]*)\n") do
  local path, floor = line:match("^%s*([^#%s]+)%s*([%d%.]*)%s*$")
  if not path then
    out[#out + 1] = line
  else
    seen[path] = true
    floor = tonumber(floor)
    local files, pct = measure(path)
    if update then
      local new = files > 0 and math.max(0, math.floor(pct) - 1) or (floor or 0)
      out[#out + 1] = ("%-36s %d"):format(path, new)
    elseif files == 0 then
      failures[#failures + 1] = ("%s: covers no file in the report (renamed? update the floor file)"):format(path)
    elseif floor and pct < floor then
      failures[#failures + 1] = ("%s: %.1f%%, below its floor of %g%%"):format(path, pct, floor)
    end
    local shown = files > 0 and ("%5.1f%%"):format(pct) or "    -"
    report[#report + 1] = ("%-36s %s  floor %s"):format(path, shown, floor and tostring(floor) .. "%" or "-")
  end
end

-- Keep the default floor file in step with scripts/typecheck_strict.txt.
if not update and not args[2] then
  local strict_path = root .. "/scripts/typecheck_strict.txt"
  local f = io.open(strict_path, "rb")
  if f then
    local strict = f:read("*a")
    f:close()
    for line in (strict .. "\n"):gmatch("([^\n]*)\n") do
      local path = line:match("^%s*([^#%s]+)%s*$")
      if path and not seen[path] then
        failures[#failures + 1] = ("%s: in scripts/typecheck_strict.txt but missing from scripts/coverage_floor.txt"):format(
          path
        )
      end
    end
  end
end

if update then
  -- the split leaves an empty last line for the file's final newline
  if out[#out] == "" then
    out[#out] = nil
  end
  local f = assert(io.open(floor_path, "wb"))
  f:write(table.concat(out, "\n") .. "\n")
  f:close()
  io.stdout:write("Updated " .. floor_path .. "\n")
  os.exit(0)
end

io.stdout:write(table.concat(report, "\n") .. "\n")
if #failures > 0 then
  io.stdout:write("\nCoverage below the floor (" .. floor_path .. "):\n")
  for _, f in ipairs(failures) do
    io.stdout:write("  " .. f .. "\n")
  end
  os.exit(1)
end
io.stdout:write("\nEvery path is at or above its floor.\n")

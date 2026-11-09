-- The sizes README.md quotes, checked against the repository. Run it with
--
--   nvim --headless --clean -l scripts/readme_stats.lua [--update]
--
-- from the repository root (`make lint` does, `make readme-stats` passes
-- --update). The README says how large the code and the test suite are:
--
--   It's about 260k lines of Lua ...
--   The headless test suite runs 5,700+ tests from 360+ spec files.
--
-- Nothing rewrote those numbers as the code grew, so they went stale. This
-- script counts
--
--   lines       the lines of every *.lua file under lua/
--   tests       the `it(...)` lines of tests/spec/*_spec.lua (what
--               scripts/extension_report.lua counts; a test made in a loop
--               counts once, so the suite runs at least this many)
--   spec files  tests/spec/*_spec.lua
--
-- and prints `README.md:line: stats: message` for a number that is no
-- longer true, exiting non-zero:
--
--   about Nk    more than 10% away from the count
--   N+          above the count, or below 90% of it
--   (missing)   the sentence was reworded and the number isn't found:
--               change the patterns below with it
--
-- The 10% leaves room to grow, so a pull request that adds a few tests
-- doesn't fail the lint; --update rewrites the numbers (lines to the
-- nearest 10k, tests down to a hundred, spec files down to ten; finer for
-- a count so small that this would be more than 10% off).

local M = {}

M.TOLERANCE = 0.10

--- The claims: `pattern` captures the number as written; `key` names the
--- count it is checked against, `step` what --update rounds it to.
M.CLAIMS = {
  { key = "lines", kind = "about", step = 10000, label = "lines of Lua", pattern = "about ()([%d,]+)()k lines of Lua" },
  { key = "tests", kind = "floor", step = 100, label = "tests", pattern = "()([%d,]+)()%+ tests from" },
  {
    key = "spec_files",
    kind = "floor",
    step = 10,
    label = "spec files",
    pattern = "tests from ()([%d,]+)()%+%s+spec%s+files",
  },
}

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

--- 5703 → "5,703"
function M.commas(n)
  local s = tostring(n)
  local out
  repeat
    s, out = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
  until out == 0
  return s
end

--- Lines of `text`: a last line without a newline counts too.
function M.count_lines(text)
  local _, n = text:gsub("\n", "")
  if text ~= "" and text:sub(-1) ~= "\n" then
    n = n + 1
  end
  return n
end

--- `it(...)` lines of a spec's text.
function M.count_tests(text)
  local n = 0
  for l in text:gmatch("[^\n]+") do
    if l:match("^%s*it%(") then
      n = n + 1
    end
  end
  return n
end

--- Every *.lua under `dir`, recursively.
local function lua_files(dir, out)
  out = out or {}
  for name, kind in vim.fs.dir(dir) do
    local path = dir .. "/" .. name
    if kind == "directory" then
      lua_files(path, out)
    elseif kind == "file" and name:match("%.lua$") then
      out[#out + 1] = path
    end
  end
  return out
end

--- The counts of the repository at `root`.
---@return { lines: integer, tests: integer, spec_files: integer }
function M.count(root)
  local counts = { lines = 0, tests = 0, spec_files = 0 }
  for _, file in ipairs(lua_files(root .. "/lua")) do
    counts.lines = counts.lines + M.count_lines(read(file) or "")
  end
  for name, kind in vim.fs.dir(root .. "/tests/spec") do
    if kind == "file" and name:match("_spec%.lua$") then
      counts.spec_files = counts.spec_files + 1
      counts.tests = counts.tests + M.count_tests(read(root .. "/tests/spec/" .. name) or "")
    end
  end
  return counts
end

--- The number a claim should show for `count`, as written in the README:
--- rounded to the claim's step ("about": to the nearest, else down), or to
--- a finer one when that would put a small count outside the tolerance.
function M.wanted(claim, count)
  local about = claim.kind == "about"
  local function rounded(step)
    return math.floor(count / step + (about and 0.5 or 0)) * step
  end
  local step = claim.step
  while step > (about and 1000 or 1) and math.abs(count - rounded(step)) > count * M.TOLERANCE do
    step = step / 10
  end
  if about then
    return string.format("%d", rounded(step) / 1000)
  end
  return M.commas(rounded(step))
end

--- The value of a claim's number as written ("5,700", or "260" for 260k).
local function value(claim, written)
  local n = tonumber((written:gsub(",", "")))
  return n and (claim.kind == "about" and n * 1000 or n)
end

--- 1-based line of byte offset `pos` in `text`.
local function line_of(text, pos)
  local _, n = text:sub(1, pos):gsub("\n", "")
  return n + 1
end

--- What is wrong with the numbers of the README `text`, given `counts`.
---@return { line: integer, msg: string }[]
function M.check(text, counts)
  local problems = {}
  for _, claim in ipairs(M.CLAIMS) do
    local s, written = text:match(claim.pattern)
    local count = counts[claim.key]
    if not s then
      problems[#problems + 1] = {
        line = 1,
        msg = "the number of " .. claim.label .. " wasn't found (reworded? see scripts/readme_stats.lua)",
      }
    else
      local n = value(claim, written)
      local low, high
      if claim.kind == "about" then
        low, high = count * (1 - M.TOLERANCE), count * (1 + M.TOLERANCE)
      else
        low, high = count * (1 - M.TOLERANCE), count
      end
      if not n or n < low or n > high then
        local shown = claim.kind == "about" and (written .. "k") or (written .. "+")
        local want = M.wanted(claim, count) .. (claim.kind == "about" and "k" or "+")
        problems[#problems + 1] = {
          line = line_of(text, s),
          msg = string.format(
            "%s %s, but there are %s: write %s (make readme-stats)",
            shown,
            claim.label,
            M.commas(count),
            want
          ),
        }
      end
    end
  end
  return problems
end

--- The README `text` with every number found rewritten from `counts`.
function M.update(text, counts)
  for _, claim in ipairs(M.CLAIMS) do
    local s, _, e = text:match(claim.pattern)
    if s then
      text = text:sub(1, s - 1) .. M.wanted(claim, counts[claim.key]) .. text:sub(e)
    end
  end
  return text
end

if arg and arg[0] and arg[0]:match("readme_stats%.lua$") then
  local root = vim.fn.getcwd()
  local path = root .. "/README.md"
  local text = read(path)
  if not text then
    io.stdout:write("readme_stats.lua: no README.md in ", root, "\n")
    os.exit(2)
  end
  local counts = M.count(root)
  if arg[1] == "--update" then
    local new = M.update(text, counts)
    if new ~= text then
      local f = assert(io.open(path, "wb"))
      f:write(new)
      f:close()
    end
    text = new
  end
  local problems = M.check(text, counts)
  for _, p in ipairs(problems) do
    io.stdout:write(string.format("README.md:%d: stats: %s\n", p.line, p.msg))
  end
  if #problems > 0 then
    os.exit(1)
  end
  io.stdout:write(
    string.format(
      "README.md stats: %s lines of Lua, %s tests, %s spec files\n",
      M.commas(counts.lines),
      M.commas(counts.tests),
      M.commas(counts.spec_files)
    )
  )
  os.exit(0)
end

return M

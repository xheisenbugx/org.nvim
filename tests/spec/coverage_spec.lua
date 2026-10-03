-- The line coverage of `make coverage`: tests/coverage.lua counts the
-- lines of lua/org each Neovim of a test run executes, and
-- scripts/coverage_report.lua merges the counts of all of them into the
-- report. Both run here on a throwaway checkout of a few modules.
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))

-- executable lines (with bytecode): 2, 4-6, 8-9, 11-13, 15; one() is
-- called with a positive number by one Neovim, a negative by the other
local ALPHA = {
  "-- a comment",
  "local M = {}",
  "",
  "function M.one(x)",
  "  if x > 0 then",
  '    return "pos"',
  "  end",
  '  return "neg"',
  "end",
  "",
  "function M.two()",
  "  return 2",
  "end",
  "",
  "return M",
}

-- a() runs, b() doesn't
local GAMMA = {
  "local M = {}",
  "function M.a()",
  "  return 1",
  "end",
  "function M.b()",
  "  local x = 1",
  "  local y = 2",
  "  local z = 3",
  "  return x + y + z",
  "end",
  "return M",
}

-- a Neovim of the test run
local CHILD = {
  "local repo, tree, sign = arg[1], arg[2], tonumber(arg[3])",
  'local cov = dofile(repo .. "/tests/coverage.lua")',
  'cov.start(tree .. "/counts")',
  'dofile(tree .. "/lua/org/alpha.lua").one(sign)',
  'dofile(tree .. "/lua/org/gamma.lua").a()',
  "cov.write()",
}

describe("coverage", function()
  local tree

  local function write(path, lines)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
  end
  local function read(path)
    return table.concat(vim.fn.readfile(path), "\n")
  end
  local function nvim(...)
    return vim.system({ vim.v.progpath, "--clean", "--headless", "-l", ... }, { text = true }):wait(60000)
  end
  --- The line numbers of ranges like { "3-5", "9" }.
  local function expand(ranges)
    local out = {}
    for _, r in ipairs(ranges) do
      local a, b = r:match("^(%d+)%-(%d+)$")
      for l = tonumber(a or r), tonumber(b or r) do
        out[l] = true
      end
    end
    return out
  end

  before_each(function()
    skip_on_windows("make coverage runs on Linux (the Coverage workflow)")
    tree = vim.fn.tempname()
    write(tree .. "/scripts/coverage_report.lua", vim.fn.readfile(root .. "/scripts/coverage_report.lua"))
    write(tree .. "/lua/org/alpha.lua", ALPHA)
    write(tree .. "/lua/org/gamma.lua", GAMMA)
    -- never loaded
    write(tree .. "/lua/org/beta.lua", { "local M = {}", "function M.f()", "  return 1", "end", "return M" })
    write(tree .. "/lua/org/sub/init.lua", { "return { x = 1 }" })
    -- annotations only: left out
    write(tree .. "/lua/org/_meta/types.lua", { "---@meta", "local x = 1", "return x" })
    write(tree .. "/child.lua", CHILD)
  end)
  after_each(function()
    vim.fn.delete(tree, "rf")
  end)

  it("counts the lines each Neovim runs and merges them into one report", function()
    for _, sign in ipairs({ "1", "-1" }) do
      local res = nvim(tree .. "/child.lua", root, tree, sign)
      eq(0, res.code, res.stderr)
    end
    -- one file per Neovim, of the lines of lua/org it ran (by path in the
    -- checkout), each with its count
    local files = vim.fn.glob(tree .. "/counts/*.json", false, true)
    eq(2, #files)
    local hit = {}
    for _, f in ipairs(files) do
      local counts = vim.json.decode(read(f))
      local mods = vim.tbl_keys(counts)
      table.sort(mods)
      eq({ "lua/org/alpha.lua", "lua/org/gamma.lua" }, mods)
      for l, n in pairs(counts["lua/org/alpha.lua"]) do
        ok(n >= 1)
        hit[tonumber(l)] = (hit[tonumber(l)] or 0) + 1
      end
    end
    -- each ran one branch of one()
    eq(1, hit[6])
    eq(1, hit[8])
    eq(2, hit[5])

    local res = nvim(tree .. "/scripts/coverage_report.lua", tree .. "/counts", tree .. "/out")
    eq(0, res.code, res.stderr)
    local cov = vim.json.decode(read(tree .. "/out/coverage.json"))
    local alpha = cov.modules["org.alpha"]
    eq("lua/org/alpha.lua", alpha.file)
    -- the executable lines come from the bytecode: code lines, not the
    -- comment, the blank lines or the "end" of the if
    local exec = expand(alpha.missed)
    for l in pairs(hit) do
      exec[l] = true
    end
    for _, l in ipairs({ 2, 5, 6, 8, 12, 15 }) do
      ok(exec[l], "line " .. l .. " is executable")
    end
    for _, l in ipairs({ 1, 3, 7, 10, 14 }) do
      ok(not exec[l], "line " .. l .. " is not executable")
    end
    eq(vim.tbl_count(exec), alpha.lines)
    -- merged: the lines of both Neovims are run, only two()'s body isn't
    eq({ "12" }, alpha.missed)
    eq(alpha.lines - 1, alpha.hit)
    eq({ "6-9" }, cov.modules["org.gamma"].missed)
    -- the modules no spec loaded count, with every line missed
    eq(0, cov.modules["org.beta"].hit)
    eq({ "1-5" }, cov.modules["org.beta"].missed)
    eq({ file = "lua/org/sub/init.lua", lines = 1, hit = 0, missed = { "1" } }, cov.modules["org.sub"])
    eq(nil, cov.modules["org._meta.types"])
    eq(vim.tbl_count(cov.modules), 4)

    -- lowest coverage first, then by name
    local function order(text)
      local out = {}
      for mod in text:gmatch("\n| `([^`]+)` |") do
        out[#out + 1] = mod
      end
      return out
    end
    local want = { "org.beta", "org.sub", "org.gamma", "org.alpha" }
    eq(want, order(read(tree .. "/out/report.md")))
    local summary = read(tree .. "/out/summary.md")
    eq(want, order(summary))
    local total = 0
    for _, m in pairs(cov.modules) do
      total = total + m.lines
    end
    ok(
      summary:find(
        ("of %d lines in 4 modules (2 never loaded by a spec), from 2 test processes."):format(total),
        1,
        true
      ),
      summary
    )
    eq(total, cov.total)
    -- the lines to test next, in the same order
    eq({
      "lua/org/beta.lua (0.0%): 1-5",
      "lua/org/sub/init.lua (0.0%): 1",
      ("lua/org/gamma.lua (%.1f%%): 6-9"):format(cov.modules["org.gamma"].hit * 100 / cov.modules["org.gamma"].lines),
      ("lua/org/alpha.lua (%.1f%%): 12"):format(alpha.hit * 100 / alpha.lines),
    }, vim.fn.readfile(tree .. "/out/missed.txt"))
  end)

  it("fails without counts", function()
    vim.fn.mkdir(tree .. "/counts", "p")
    local res = nvim(tree .. "/scripts/coverage_report.lua", tree .. "/counts", tree .. "/out")
    eq(1, res.code)
    ok(res.stderr:find("no coverage counts", 1, true), res.stderr)
  end)
end)

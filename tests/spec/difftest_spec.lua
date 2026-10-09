-- The differential test against Emacs (tests/difftest/, `make difftest`)
-- without Emacs: the generator, org.nvim's side of every oracle, the
-- comparison with known differences and the shrinking, with a fake Emacs
-- that answers what org.nvim prints (plus a planted difference).

local gen = require("tests.difftest.gen")
local oracles = require("tests.difftest.oracles")
local compare = require("tests.difftest.compare")
local difftest = require("tests.difftest")

local scratch = vim.fn.tempname()

--- A fake Emacs pool: org.nvim's own output, with an extra line when the
--- input holds a line "MARKER".
local function fake_pool()
  return {
    request = function(_, oracle, input, output)
      local s = oracles.frozen(function()
        return oracles.run(oracle, input)
      end)
      if vim.tbl_contains(vim.fn.readfile(input), "MARKER") then
        s = s .. "EXTRA\n"
      end
      vim.fn.mkdir(vim.fn.fnamemodify(output, ":h"), "p")
      vim.fn.writefile(vim.split(s, "\n", { plain = true }), output, "b")
    end,
    wait = function() end,
    stop = function() end,
  }
end

--- Seeds 1 and 2 of the generator, a "MARKER" line in the middle of 2.
local function docs(seed)
  local lines = gen.doc(seed)
  if seed == 2 then
    table.insert(lines, math.floor(#lines / 2) + 1, "MARKER")
  end
  return lines
end

local function run(opts)
  return difftest.run(vim.tbl_extend("force", {
    seed = 1,
    count = 2,
    oracles = { "export-ascii" },
    out = scratch,
    pool = fake_pool,
    docs = docs,
    log = function() end,
  }, opts or {}))
end

describe("difftest", function()
  after_each(function()
    vim.fn.delete(scratch, "rf")
  end)

  it("generates the same document for a seed, and others for other seeds", function()
    eq(gen.doc(7), gen.doc(7))
    ok(not vim.deep_equal(gen.doc(7), gen.doc(8)))
    for seed = 1, 20 do
      for _, l in ipairs(gen.doc(seed)) do
        ok(not l:find("\r"), "no CR")
      end
    end
  end)

  it("runs every oracle of org.nvim without an error", function()
    local file = scratch .. "/d.org"
    vim.fn.mkdir(scratch, "p")
    for seed = 1, 3 do
      vim.fn.writefile(gen.doc(seed), file)
      for _, o in ipairs(oracles.ALL) do
        local out = oracles.frozen(function()
          return oracles.run(o, file)
        end)
        ok(not out:find("!error"), ("seed %d %s: %s"):format(seed, o, out:match("!error[^\n]*")))
      end
    end
  end)

  it("applies NORMALISE and splits a difference into hunks", function()
    local res = compare.compare("export-html", '<a id="org1234abc">\nx\ny\n', '<a id="orgfedcba9">\nx\nz\n', {
      known = {},
    })
    eq(1, #res.hunks)
    eq({ "y" }, res.hunks[1].emacs)
    eq({ "z" }, res.hunks[1].ours)
    ok(compare.unified(res):find("\n%-y\n%+z"))
    -- an error in Emacs: nothing to compare
    ok(compare.compare("table", "!error boom\n", "x\n", { known = {} }).emacs_error)
  end)

  it("matches known differences by pattern, input and rewrite", function()
    local upper = { oracle = "table", same = string.upper, reason = "case" }
    local spaces = {
      oracle = "table",
      input = "^#%+TBLFM",
      same = function(s)
        return (s:gsub(" +", " "))
      end,
      reason = "spaces",
    }
    local res = compare.compare("table", "a\nb\n", "a\nB\n", { known = { upper } })
    eq(upper, res.hunks[1].known)
    eq(0, #res.unknown)
    -- the input decides
    res = compare.compare("table", "| a  |\n", "| a |\n", { known = { spaces }, input = { "| a |" } })
    eq(1, #res.unknown)
    res = compare.compare("table", "| a  |\n", "| a |\n", { known = { spaces }, input = { "#+TBLFM: $1=1" } })
    eq(0, #res.unknown)
    -- two known differences in one hunk
    res = compare.compare("table", "| a  |\n", "| A |\n", { known = { upper, spaces }, input = { "#+TBLFM:" } })
    eq(0, #res.unknown)
    -- the oracle decides
    eq(1, #compare.compare("agenda", "a\n", "A\n", { known = { upper } }).unknown)
  end)

  it("groups differences by the words only one side has", function()
    local h = { at = 1, emacs = { "  1. task 42" }, ours = { "  1) task 17" } }
    eq("export-org|#. => #)", compare.signature("export-org", h))
    eq(
      "visibility|whitespace a *************** a",
      compare.signature(
        "visibility",
        { at = 1, emacs = { "h *************** END" }, ours = { "v *************** END" } }
      )
    )
  end)

  it("finds a difference and shrinks its input", function()
    local res = run()
    eq(1, #res.failures)
    local f = res.failures[1]
    eq(2, f.seed)
    eq({ "MARKER" }, f.minimal)
    eq(1, #res.distinct)
    local report = table.concat(vim.fn.readfile(scratch .. "/report.md"), "\n")
    ok(report:find("make difftest SEED=2 COUNT=1 ORACLES=export%-ascii"))
    ok(report:find("```org\nMARKER\n```"))
    ok(report:find("\n%-EXTRA"))
    eq({ "MARKER" }, vim.fn.readfile(scratch .. "/repros/01-export-ascii-seed2.org"))
  end)

  it("doesn't fail on a known difference", function()
    local k = { oracle = "export%-.*", ours = "^$", emacs = "EXTRA", reason = "planted" }
    local res = run({ known = { k } })
    eq(0, #res.failures)
    eq(1, res.stats.known)
    eq(1, res.stats.by_known[k])
  end)
end)

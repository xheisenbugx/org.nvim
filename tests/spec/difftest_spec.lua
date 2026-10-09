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
--- input holds a line "MARKER"; "!error broken" for the oracles in
--- `broken` (a broken Emacs side).
local function fake_pool(broken)
  return {
    request = function(_, oracle, input, output)
      local s = oracles.frozen(function()
        return oracles.run(oracle, input)
      end)
      if vim.tbl_contains(vim.fn.readfile(input), "MARKER") then
        s = s .. "EXTRA\n"
      end
      if broken and vim.tbl_contains(broken, oracle) then
        s = "!error broken\n"
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

local function run(opts, broken)
  return difftest.run(vim.tbl_extend("force", {
    seed = 1,
    count = 2,
    oracles = { "export-ascii" },
    out = scratch,
    pool = function()
      return fake_pool(broken)
    end,
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

  it("leaves out only the sections Emacs raised an error on", function()
    -- an agenda view, an S-TAB step
    local res =
      compare.compare("agenda", "=== week\n!error boom\n=== day\na\n", "=== week\nx\n=== day\nb\n", { known = {} })
    eq(nil, res.emacs_error)
    eq({ "week: !error boom" }, res.skipped)
    eq(1, #res.hunks)
    eq({ "a" }, res.hunks[1].emacs)
    -- every section: nothing compared
    res = compare.compare("visibility", "=== startup\n!error a\n", "=== startup\nv x\n", { known = {} })
    eq("!error a", res.emacs_error)
    -- a table (difftest.el puts it back and adds the error after it)
    res = compare.compare(
      "table",
      "| 1 |\n#+TBLFM: $1=x\n!error bad\ntext\n| 2 |\n#+TBLFM: $1=2\n",
      "| 9 |\n#+TBLFM: $1=x\ntext\n| 3 |\n#+TBLFM: $1=2\n",
      { known = {} }
    )
    eq(nil, res.emacs_error)
    eq({ "!error bad" }, res.skipped)
    eq(1, #res.hunks)
    eq({ "| 2 |" }, res.hunks[1].emacs)
    -- an export: all or nothing
    ok(compare.compare("export-html", "!error x\n", "y\n", { known = {} }).emacs_error)
  end)

  it("fails as an infrastructure problem when Emacs keeps raising errors", function()
    local res = run({ count = 4, oracles = { "export-ascii", "export-md" } }, { "export-md" })
    eq(4, res.stats.emacs_errors)
    ok(res.infra and res.infra:find("4 of 8"), res.infra)
    ok(table.concat(vim.fn.readfile(scratch .. "/report.md"), "\n"):find("Infrastructure failure"))
    -- one error in a few comparisons isn't
    eq(
      nil,
      difftest.infrastructure(
        { compared = 8, emacs_errors = 1, by_oracle = { a = { compared = 1, errors = 1 } } },
        { "a" }
      )
    )
    -- every comparison of one oracle is
    ok(difftest.infrastructure({
      compared = 40,
      emacs_errors = 3,
      by_oracle = { a = { compared = 3, errors = 3 }, b = { compared = 37, errors = 0 } },
    }, { "a", "b" }))
  end)

  it("refuses to empty an output directory it didn't write", function()
    vim.fn.mkdir(scratch, "p")
    vim.fn.writefile({ "mine" }, scratch .. "/notes.txt")
    local okr, err = pcall(run)
    ok(not okr)
    ok(tostring(err):find("not emptying it"), err)
    eq({ "mine" }, vim.fn.readfile(scratch .. "/notes.txt"))
    -- an earlier run's directory is emptied
    vim.fn.delete(scratch .. "/notes.txt")
    run()
    ok(vim.uv.fs_stat(scratch .. "/" .. difftest.MARKER))
    run()
  end)

  it("reports the whole input and diff of failures it doesn't shrink", function()
    local res = run({ minimise = 0 })
    eq(1, #res.distinct)
    ok(res.distinct[1].unshrunk)
    local report = table.concat(vim.fn.readfile(scratch .. "/report.md"), "\n")
    ok(report:find("Input %(not shrunk"))
    ok(report:find("\n%-EXTRA"))
    ok(vim.uv.fs_stat(scratch .. "/repros/01-export-ascii-seed2.diff"))
  end)

  it("matches two known differences in one hunk, the broad rewrite last", function()
    -- seed 39 (export-latex): a doubled backslash and a date range in one
    -- line, with an inline task titled like a headline (not a second
    -- target for the link)
    local input = {
      "*** end. gamma",
      "*************** end. gamma",
      "\\\\ <2026-10-01 09:00>--<2025-06-07 Sat>",
      "[[*Alpha][heading]]",
    }
    local res = compare.compare(
      "export-latex",
      "$\\backslash$\\ \\textit{<2026-10-01 Thu 09:00>--<2025-06-07 Sat 09:00>}\n",
      "$\\backslash$$\\backslash$ \\textit{<2026-10-01 Thu 09:00>--<2025-06-07 Sat>}\n",
      { input = input }
    )
    eq(1, #res.hunks)
    eq(0, #res.unknown)
    -- a broad rewrite (digits) applied first would break the narrower one
    local digits = {
      oracle = "table",
      broad = true,
      same = function(s)
        return (s:gsub("%d", "#"))
      end,
      reason = "digits",
    }
    local suffix = {
      oracle = "table",
      same = function(s)
        return (s:gsub(" 1x", ""))
      end,
      reason = "suffix",
    }
    res = compare.compare("table", "a 1 1x\n", "a 2\n", { known = { digits, suffix } })
    eq(0, #res.unknown)
  end)

  it("matches lines moved between hunks together", function()
    local moved = {
      oracle = "table",
      moves = true,
      same = function(s)
        local t = vim.split(s, "\n")
        table.sort(t)
        return table.concat(t, "\n")
      end,
      reason = "moved",
    }
    local e, o = "a\nb\nc\nd\ne\n", "b\nc\nd\na\ne\n"
    eq(2, #compare.compare("table", e, o, { known = {} }).unknown)
    eq(0, #compare.compare("table", e, o, { known = { moved } }).unknown)
  end)

  it("knows the visibility of blank lines inside a list before the first headline", function()
    -- seed 74
    local e = { "=== S1", "v +", "v  + plan", "v ", "v  +", "=== S2" }
    local o = { "=== S1", "v +", "h  + plan", "h ", "h  +", "=== S2" }
    local res = compare.compare("visibility", table.concat(e, "\n") .. "\n", table.concat(o, "\n") .. "\n")
    eq(1, #res.hunks)
    eq(0, #res.unknown)
    -- a blank line alone isn't
    res = compare.compare("visibility", "=== S1\nv x\nv \n", "=== S1\nv x\nh \n")
    eq(1, #res.unknown)
  end)

  it("keeps footnote definitions in subtrees that aren't exported out of the count", function()
    -- seed 1376: the only [fn:named] was under a :noexport: headline
    local doc = gen.doc(1376)
    local at = vim.fn.index(doc, "* Footnotes")
    ok(at >= 0)
    ok(vim.tbl_contains(vim.list_slice(doc, at + 1), "[fn:named] Note named."))
  end)

  it("doesn't fail on a known difference", function()
    local k = { oracle = "export%-.*", ours = "^$", emacs = "EXTRA", reason = "planted" }
    local res = run({ known = { k } })
    eq(0, #res.failures)
    eq(1, res.stats.known)
    eq(1, res.stats.by_known[k])
  end)
end)

local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local stats = dofile(root .. "/scripts/readme_stats.lua")

--- A README with the three numbers as given.
local function readme(lines, tests, files)
  return table.concat({
    "# org.nvim",
    "",
    "- **No dependencies.** It's about " .. lines .. " lines of Lua and needs no",
    "  tree-sitter parser.",
    "- **Tested.** The headless test suite runs " .. tests .. " tests from " .. files .. " spec",
    "  files.",
    "",
  }, "\n")
end

--- "line: message" of every problem.
local function problems(text, counts)
  return vim.tbl_map(function(p)
    return p.line .. ": " .. p.msg
  end, stats.check(text, counts))
end

local COUNTS = { lines = 260121, tests = 5703, spec_files = 362 }

describe("README stats (scripts/readme_stats.lua)", function()
  describe("check", function()
    it("accepts numbers that are true and within 10% of the counts", function()
      eq({}, problems(readme("260k", "5,700+", "360+"), COUNTS))
      -- room to grow: the counts may run ahead of the README by 10%
      eq({}, problems(readme("240k", "5,200+", "330+"), COUNTS))
      -- "about" may also be a little over
      eq({}, problems(readme("280k", "5,703+", "362+"), COUNTS))
    end)

    it("reports numbers that fell more than 10% behind, with their line", function()
      eq({
        "3: 170k lines of Lua, but there are 260,121: write 260k (make readme-stats)",
        "5: 4,800+ tests, but there are 5,703: write 5,700+ (make readme-stats)",
        "5: 240+ spec files, but there are 362: write 360+ (make readme-stats)",
      }, problems(readme("170k", "4,800+", "240+"), COUNTS))
    end)

    it("reports an N+ that is more than there is", function()
      eq({
        "5: 5,800+ tests, but there are 5,703: write 5,700+ (make readme-stats)",
        "5: 370+ spec files, but there are 362: write 360+ (make readme-stats)",
      }, problems(readme("260k", "5,800+", "370+"), COUNTS))
    end)

    it("reports a number it can't find instead of passing", function()
      local text = "# org.nvim\n\nA plugin with many lines and many tests.\n"
      eq({
        "1: the number of lines of Lua wasn't found (reworded? see scripts/readme_stats.lua)",
        "1: the number of tests wasn't found (reworded? see scripts/readme_stats.lua)",
        "1: the number of spec files wasn't found (reworded? see scripts/readme_stats.lua)",
      }, problems(text, COUNTS))
    end)
  end)

  describe("update", function()
    it("rewrites the three numbers and nothing else", function()
      eq(readme("260k", "5,700+", "360+"), stats.update(readme("170k", "4,800+", "240+"), COUNTS))
    end)

    it("leaves numbers that are right as they are", function()
      local text = readme("260k", "5,700+", "360+")
      eq(text, stats.update(text, COUNTS))
    end)

    it("rounds lines to the nearest 10k, tests down to 100 and files down to 10", function()
      eq(
        readme("90k", "900+", "1,230+"),
        stats.update(readme("1k", "1+", "1+"), { lines = 94999, tests = 999, spec_files = 1239 })
      )
      eq(
        readme("100k", "1,000+", "360+"),
        stats.update(readme("1k", "1+", "1+"), { lines = 95000, tests = 1099, spec_files = 369 })
      )
    end)

    it("rounds a small count less, to stay within 10% of it", function()
      eq(
        readme("14k", "150+", "19+"),
        stats.update(readme("1k", "1+", "1+"), { lines = 14200, tests = 150, spec_files = 19 })
      )
    end)

    it("gives a README the check accepts", function()
      for _, counts in ipairs({
        COUNTS,
        { lines = 14200, tests = 150, spec_files = 19 },
        { lines = 94999, tests = 999, spec_files = 9 },
      }) do
        eq({}, problems(stats.update(readme("1k", "1+", "1+"), counts), counts))
      end
    end)
  end)

  describe("counting", function()
    it("counts lines with or without a last newline", function()
      eq(0, stats.count_lines(""))
      eq(2, stats.count_lines("a\nb\n"))
      eq(2, stats.count_lines("a\nb"))
    end)

    it("counts the it(...) lines of a spec", function()
      eq(
        2,
        stats.count_tests(table.concat({
          'describe("x", function()',
          '  it("one", function() end)',
          '  -- it("commented out", function() end)',
          "  local edit = function() end",
          '    it("two", function() end)',
          "end)",
        }, "\n"))
      )
    end)

    it("counts lua/ and tests/spec of a repository", function()
      local dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir .. "/lua/org/sub", "p")
      vim.fn.mkdir(dir .. "/tests/spec", "p")
      vim.fn.writefile({ "local M = {}", "return M" }, dir .. "/lua/org/a.lua")
      vim.fn.writefile({ "return 1" }, dir .. "/lua/org/sub/b.lua")
      vim.fn.writefile({ "not lua" }, dir .. "/lua/org/notes.txt")
      vim.fn.writefile({ 'it("a", f)', 'it("b", f)' }, dir .. "/tests/spec/x_spec.lua")
      vim.fn.writefile({ 'it("c", f)' }, dir .. "/tests/spec/y_spec.lua")
      vim.fn.writefile({ 'it("not a spec", f)' }, dir .. "/tests/spec/helper.lua")
      eq({ lines = 3, tests = 3, spec_files = 2 }, stats.count(dir))
      vim.fn.delete(dir, "rf")
    end)
  end)

  it("formats thousands", function()
    eq("362", stats.commas(362))
    eq("5,703", stats.commas(5703))
    eq("1,260,121", stats.commas(1260121))
  end)

  it("finds the three numbers in the real README", function()
    local f = assert(io.open(root .. "/README.md", "rb"))
    local text = f:read("*a")
    f:close()
    for _, claim in ipairs(stats.CLAIMS) do
      ok(text:match(claim.pattern), claim.label)
    end
  end)
end)

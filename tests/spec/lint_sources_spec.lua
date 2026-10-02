local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local lint = dofile(root .. "/scripts/lint_sources.lua")

--- "line:rule" of every hit in `src` (lines joined with "\n").
local function hits(lines)
  return vim.tbl_map(function(h)
    return h.line .. ":" .. h.rule
  end, lint.check(table.concat(lines, "\n")))
end

describe("source lint", function()
  describe("expand", function()
    it("flags vim.fn.expand on anything but a string literal", function()
      eq(
        { "1:expand", "2:expand", "3:expand", "4:expand" },
        hits({
          "local a = vim.fn.expand(path)",
          'local b = vim.fn.expand("~" .. user)',
          "local c = fn.expand(x, true)",
          "local d = vim.fn.expandcmd(cmd)",
        })
      )
    end)

    it("accepts literals, the utils helpers and other expands", function()
      eq(
        {},
        hits({
          'local a = vim.fn.expand("<cfile>")',
          "local b = vim.fn.expand('%:p')",
          'local c = vim.fn.expand("~/x", true)',
          "local d = utils.expand(path)",
          "local e = utils.expand_vars(path)",
          "-- vim.fn.expand(path) in a comment",
          'local f = "vim.fn.expand(path) in a string"',
          "local g = [[vim.fn.expand(path)]]",
        })
      )
    end)
  end)

  describe("gsub", function()
    it("flags a variable or concatenated replacement", function()
      eq(
        { "1:gsub", "2:gsub", "3:gsub", "4:gsub", "5:gsub", "6:gsub" },
        hits({
          's = s:gsub("x", path)',
          's = s:gsub("x", "[" .. label .. "]")',
          's = string.gsub(s, "x", t.value)',
          's = s:gsub("x", ok and name or "y")',
          's = s:gsub("x", vim.pesc(ref))',
          "s = s:gsub(",
          '  "x",',
          "  shell_quote(file)",
          ")",
        })
      )
    end)

    it("accepts literals, functions, tables, escaped values and constants", function()
      eq(
        {},
        hits({
          'local SEP = "\\1"',
          "local map = { a = 1 }",
          "local function f(c) return c end",
          "M.g = function(c) return c end",
          's = s:gsub("x", "%1")',
          's = s:gsub("x", "a" .. "b")',
          's = s:gsub("x", function(c) return c end)',
          's = s:gsub("x", { a = "b" })',
          's = s:gsub("x", map)',
          's = s:gsub("x", f)',
          's = s:gsub("x", M.g)',
          's = s:gsub("x", SEP)',
          's = s:gsub("x", string.upper)',
          's = s:gsub("x", utils.gsub_escape(path))',
          's = s:gsub("x", require("org.utils").gsub_escape(path))',
          's = s:gsub("x", "%1" .. gsub_escape(label))',
          's = s:gsub("x", (path:gsub("%%", "%%%%")))',
          's = s:gsub("x", tostring(n))',
          's = s:gsub("x", string.rep(" ", n))',
          's = s:gsub("x", string.format("%06d", n))',
          's = s:gsub("x", ok and "a" or "b")',
          's = s:gsub("x")',
          "s = vim.split(path, sep)",
        })
      )
    end)

    it("still flags string.format with %s", function()
      eq({ "1:gsub" }, hits({ 's = s:gsub("x", string.format("%s!", name))' }))
    end)
  end)

  describe("keyword-span", function()
    it("flags finding a #+KEY: value again from the start of the line", function()
      -- the LSP rename bug: `#+name: name` was renamed inside the keyword
      eq(
        { "2:keyword-span", "4:keyword-span" },
        hits({
          'local name = line:match("^[ \\t]*#%+[Nn][Aa][Mm][Ee]:[ \\t]+(.-)[ \\t]*$")',
          "local s = line:find(name, 1, true)",
          'local _, v = lines[i]:match("^#%+(%w+):%s*(.*)$")',
          "local c = lines[i]:find(v)",
        })
      )
    end)

    it("accepts a captured column, a search after the keyword or an unrelated find", function()
      eq(
        {},
        hits({
          'local s, name = line:match("^[ \\t]*#%+[Nn][Aa][Mm][Ee]:[ \\t]+()(.-)[ \\t]*$")',
          'local v = line:match("^#%+title:%s*(.*)$")',
          "local a = line:find(v, 10, true)",
          'local w = text:match("^(%w+)")',
          "local b = line:find(w, 1, true)",
        })
      )
    end)
  end)

  describe("allow comments", function()
    it("allow a hit on the same line or the line before, with a reason", function()
      eq(
        {},
        hits({
          "-- lint: allow expand: the jar_path option",
          "local a = vim.fn.expand(jar)",
          's = s:gsub("x", n) -- lint: allow gsub: a number',
        })
      )
    end)

    it("must give a reason, name a known rule and allow something", function()
      eq(
        { "1:allow", "2:expand", "3:allow", "5:allow", "6:expand" },
        hits({
          "-- lint: allow expand",
          "local a = vim.fn.expand(jar)",
          "-- lint: allow typo: reason",
          "local b = 1",
          "-- lint: allow gsub: nothing to allow",
          "local c = vim.fn.expand(jar)",
        })
      )
    end)
  end)

  it("finds nothing in lua/", function()
    local out = lint.run({ root .. "/lua" })
    eq({}, out)
  end)
end)

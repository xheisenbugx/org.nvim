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

  describe("glob", function()
    it("flags vim.fn.glob / globpath on anything but string literals", function()
      eq(
        { "1:glob", "2:glob", "3:glob", "4:glob" },
        hits({
          "local a = vim.fn.glob(pattern, false, true)",
          'local b = vim.fn.glob(dir .. "/*.org")',
          'local c = fn.globpath(dir, "*.org", false, true)',
          'local d = vim.fn.globpath("~/org", pat)',
        })
      )
    end)

    it("accepts literals and utils.glob", function()
      eq(
        {},
        hits({
          'local a = vim.fn.glob("~/org/*.org", false, true)',
          'local b = vim.fn.globpath("~/org", "*.org")',
          'local c = utils.glob(dir .. "/*.org")',
          "local d = vim.fn.glob2regpat(part)",
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

  describe("planning-line", function()
    it("flags a hand-written planning-line pattern", function()
      eq(
        { "1:planning-line", "1:planning-line", "2:planning-line", "3:planning-line", "4:planning-line" },
        hits({
          'if l:match("^%s*SCHEDULED:") or l:match("^%s*DEADLINE:") then end',
          'local x = l:find("^[ \\t]*CLOSED:")',
          "local P = { '^ *DEADLINE:' }",
          'local y = l:match("^%s*CLOSED:%s*(%b[])")',
        })
      )
    end)

    it("accepts the keywords elsewhere in a pattern or line", function()
      eq(
        {},
        hits({
          'local a = l:find("DEADLINE:", 1, true)',
          'local b = l:match("SCHEDULED:%s*$")',
          'local c = l:match("^SCHEDULED: +<[^>]+>()", s)',
          'local d = l:match("^%s*CLOCK:")',
          'local e = l:match("^%s*NOTE:")',
          "local f = parser.is_planning_line(l)",
        })
      )
    end)
  end)

  describe("pcall", function()
    it("flags a pcall / xpcall statement whose callee isn't a vim function", function()
      eq(
        { "1:pcall", "2:pcall", "3:pcall", "4:pcall", "6:pcall", "8:pcall", "9:pcall", "10:pcall" },
        hits({
          "pcall(utils.write_json, path, data)",
          'pcall(require("org.lists").update_statistics_for, bufnr, l)',
          "if x then pcall(fn) end",
          "pcall(function()",
          "end)",
          "xpcall(save, debug.traceback)",
          "local a = 1",
          "pcall(vim.api.nvim_exec_autocmds, 'User', { pattern = 'X' })",
          "do pcall(cb, 1) end",
          "f() pcall(g)",
        })
      )
    end)

    it("flags nvim_exec_autocmds through an alias too", function()
      eq({ "2:pcall" }, hits({ "local api = vim.api", "pcall(api.nvim_exec_autocmds, 'User', {})" }))
    end)

    it("accepts vim functions, their aliases, used results and utils.try", function()
      eq(
        {},
        hits({
          "local api = vim.api",
          "local api2, fn = vim.api, vim.fn",
          "local timer = assert(vim.uv.new_timer())",
          "proc = vim.system({ 'ls' })",
          "pcall(vim.api.nvim_win_close, win, true)",
          "pcall(vim.cmd, 'normal! zv')",
          "pcall(api.nvim_buf_del_extmark, buf, ns, id)",
          "pcall(fn.delete, path)",
          "pcall(timer.close, timer)",
          "pcall(proc.kill, proc, 15)",
          "local ok = pcall(write, path)",
          "local ok2, err = pcall(write, path)",
          "if pcall(write, path) then end",
          "return pcall(write, path)",
          "local t = { pcall(write, path) }",
          "f(pcall(write, path))",
          "x = not pcall(write, path) or pcall(write, path)",
          "M.pcall(write)",
          "obj:pcall(write)",
          "local function pcall2() end",
          "utils.try('bookmarks: save', utils.write_json, path, data)",
          "-- pcall(write, path) in a comment",
          "local s = 'pcall(write, path)'",
        })
      )
    end)

    it("doesn't take a table key or a field for an alias", function()
      eq(
        { "2:pcall", "3:pcall" },
        hits({
          "local t = { timer = vim.uv.new_timer() }",
          "pcall(timer.close, timer)",
          "pcall(t.timer.close, t.timer)",
        })
      )
    end)

    it("is allowed with a reason", function()
      eq(
        {},
        hits({
          "-- lint: allow pcall: the job may have exited already",
          "pcall(obj.kill, obj, 15)",
          "pcall(job.kill, job) -- lint: allow pcall: exited already",
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

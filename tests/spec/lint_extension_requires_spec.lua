local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local check = dofile(root .. "/scripts/lint_extension_requires.lua")

--- A fake repository: `files` maps paths (from the root) to their lines.
local function repo(files)
  local dir = vim.fn.tempname()
  for path, lines in pairs(files) do
    vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. path), "p")
    vim.fn.writefile(lines, dir .. "/" .. path)
  end
  return dir
end

describe("extension requires check", function()
  it("reads the strings of the code, not of its comments", function()
    local src = table.concat({
      'local a = require("org.files")',
      "local b = require 'org.utils' -- require(\"org.date\")",
      '--[[ require("org.config")',
      "]]",
      "local c = [[org.todo]]",
      'local d = "it\\"s"',
      "--[==[ long",
      "comment ]==] local e = 'org.clock'",
    }, "\n")
    eq({
      { "org.files", 1 },
      { "org.utils", 2 },
      { "org.todo", 5 },
      { 'it\\"s', 6 },
      { "org.clock", 8 },
    }, check.strings(src))
  end)

  it("tells the extension of a file; the registry has none", function()
    eq("kanban", check.extension_of("kanban/init.lua"))
    eq("cli", check.extension_of("cli/run/deep.lua"))
    eq("views_util", check.extension_of("views_util.lua"))
    eq(nil, check.extension_of("init.lua"))
  end)

  it("allows the API, the registry, the shared views code and the own modules", function()
    for _, mod in ipairs({
      "org.api",
      "org.api.headline",
      "org.extensions",
      "org.extensions.views_util",
      "org.extensions.demo",
      "org.extensions.demo.part",
    }) do
      eq(true, check.allowed("demo", mod), mod)
    end
    for _, mod in ipairs({ "org.files", "org.apis", "org.extensions.other", "org.extensions.demos" }) do
      eq(false, check.allowed("demo", mod), mod)
    end
  end)

  it("finds requires, aliases, pcall, lazy hooks and module names in locals", function()
    local dir = repo({
      ["lua/org/files.lua"] = { "return {}" },
      ["lua/org/utils.lua"] = { "return {}" },
      ["lua/org/date.lua"] = { "return {}" },
      ["lua/org/agenda/render.lua"] = { "return {}" },
      ["lua/org/clock/init.lua"] = { "return {}" },
      ["lua/org/api/init.lua"] = { "return {}" },
      ["lua/org/extensions/init.lua"] = { 'local u = require("org.utils")' },
      ["lua/org/extensions/demo/init.lua"] = {
        'local api = require("org.api")',
        'local own = require("org.extensions.demo.part")',
        "local req = require",
        'local f = req("org.files")',
        'local ok, u = pcall(require, "org.utils")',
        'require("org.lazy").on_load("org.agenda.render", "demo", function() end)',
        'local CLOCK = "org.clock"',
        '-- require("org.date") in a comment',
        'local msg = "org.nvim is not a module"',
      },
      ["lua/org/extensions/demo/part.lua"] = { 'local d = require("org.date")', 'local f = require("org.files")' },
    })
    local found = check.scan(dir)
    eq({
      "demo org.agenda.render",
      "demo org.clock",
      "demo org.date",
      "demo org.files",
      "demo org.utils",
    }, vim.fn.sort(vim.tbl_keys(found)))
    eq("lua/org/extensions/demo/init.lua:4", found["demo org.files"])
    eq("lua/org/extensions/demo/part.lua:1", found["demo org.date"])
    vim.fn.delete(dir, "rf")
  end)

  it("fails on a dependency the baseline lacks and on one it lists that is gone", function()
    local baseline = check.parse_baseline(table.concat({
      "# comment",
      "",
      "demo org.files",
      "demo org.date",
    }, "\n"))
    eq({ ["demo org.files"] = true, ["demo org.date"] = true }, baseline)
    local problems = check.check({
      ["demo org.files"] = "lua/org/extensions/demo/init.lua:4",
      ["demo org.utils"] = "lua/org/extensions/demo/init.lua:5",
    }, baseline)
    eq(2, #problems)
    ok(problems[1]:find("demo/init.lua:5: extension demo depends on the internal module org.utils", 1, true))
    ok(problems[1]:find("org.api", 1, true))
    ok(problems[2]:find('"demo org.date" is no longer a dependency', 1, true))
    eq({}, check.check({ ["demo org.files"] = "x:1" }, { ["demo org.files"] = true }))
  end)

  it("passes on the repository, and the views built on org.api have no line", function()
    local f = assert(io.open(root .. "/" .. check.BASELINE, "rb"))
    local text = f:read("*a")
    f:close()
    local baseline = check.parse_baseline(text)
    local found = check.scan(root)
    eq({}, check.check(found, baseline))
    -- sorted, one pair a line
    local pairs_ = {}
    for l in text:gmatch("[^\n]+") do
      if not l:match("^#") then
        ok(l:match("^%S+ org%.[%w_.]+$"), l)
        pairs_[#pairs_ + 1] = l
      end
    end
    eq(vim.fn.sort(vim.deepcopy(pairs_)), pairs_)
    for key in pairs(baseline) do
      local ext = key:match("^(%S+)")
      ok(ext ~= "kanban" and ext ~= "timeline" and ext ~= "heatmap", key)
    end
  end)
end)

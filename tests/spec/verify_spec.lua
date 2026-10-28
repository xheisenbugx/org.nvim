-- The verify driver (scripts/verify/drive.lua) and the feature map of the
-- verify-org skill (.claude/skills/verify-org/features/): the driver fails
-- a scenario when what it expects doesn't happen or a step leaves an
-- error, keeps the child away from the real home, every recipe passes,
-- and every feature file's header names keys, modules, specs and help
-- tags that exist.
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local drive = dofile(root .. "/scripts/verify/drive.lua")
local features = root .. "/.claude/skills/verify-org/features"

--- Run scenario `sc`, its evidence in a directory deleted afterwards.
local function run(sc)
  local out = drive.mkdtemp("org-verify-spec-")
  local res = drive.run(sc, out)
  vim.fn.delete(out, "rf")
  if res.dir then
    vim.fn.delete(res.dir, "rf")
  end
  return res
end

--- The failing step's reason, or a description of every step.
local function why(res)
  for _, s in ipairs(res.steps) do
    if not s.ok then
      return s.text .. ": " .. tostring(s.why)
    end
  end
  return "every step passed"
end

describe("verify driver", function()
  it("passes a scenario whose expectations hold", function()
    local res = run({
      name = "cycle",
      files = { ["a.org"] = { "* One", "body" } },
      open = "a.org",
      setup = { startup_folded = "overview" },
      steps = {
        { expect = { screen = "* One", no_screen = "body" } },
        { key = "{{org.cycle}}", expect = { screen = "body", filetype = "org", line = "^%* One$" } },
      },
    })
    ok(res.ok, why(res))
    eq(2, #res.steps)
  end)

  it("fails at the first expectation that doesn't hold, and stops", function()
    local res = run({
      name = "wrong",
      files = { ["a.org"] = { "* One" } },
      open = "a.org",
      steps = {
        { expect = { screen = "* Two", timeout = 200 } },
        { key = "j" },
      },
    })
    eq(false, res.ok)
    eq(1, #res.steps)
    ok(res.steps[1].why:find('screen has no "* Two"', 1, true), res.steps[1].why)
  end)

  it("compares a file on disk line by line", function()
    local res = run({
      name = "file",
      files = { ["a.org"] = { "* One" } },
      open = "a.org",
      steps = { { expect = { file = { "a.org", lines = { "* Two" } }, timeout = 200 } } },
    })
    eq(false, res.ok)
    ok(res.steps[1].why:find("a.org is", 1, true), res.steps[1].why)
  end)

  it("fails a step that leaves an error, unless it allows one", function()
    local notify = [[vim.notify("broken", vim.log.levels.ERROR)]]
    local res = run({ name = "error", steps = { { lua = notify } } })
    eq(false, res.ok)
    ok(res.steps[1].why:find("error: broken", 1, true), res.steps[1].why)
    res = run({ name = "allowed", steps = { { lua = notify, allow_error = true } } })
    ok(res.ok, why(res))
    res = run({ name = "errmsg", steps = { { cmd = "silent! call nosuchfunction()" } } })
    eq(false, res.ok)
    ok(res.steps[1].why:find("E117", 1, true), res.steps[1].why)
  end)

  it("gives the child a scratch home and data directory, and a fixed clock moved by wait", function()
    local res = run({
      name = "env",
      steps = {
        {
          expect = {
            lua = [[
              local n = vim.fs.normalize
              return vim.startswith(n(vim.env.HOME), n(...)) and vim.startswith(n(vim.fn.stdpath("data")), n(...))
            ]],
          },
        },
        { expect = { lua = [[return os.date("%Y-%m-%d %H:%M") == "2026-10-12 09:00"]] } },
        { wait = 90 },
        { expect = { lua = [[return os.date("%H:%M") == "10:30"]] } },
      },
    })
    ok(res.ok, why(res))
    ok(vim.env.HOME ~= nil and not vim.env.HOME:find("org-verify-files-", 1, true))
  end)

  it("names the step that failed when the target has no such scenario", function()
    local out = drive.mkdtemp("org-verify-spec-")
    local saved = io.stdout
    local captured = {}
    io.stdout = { ---@diagnostic disable-line: missing-fields
      write = function(_, s)
        captured[#captured + 1] = s
      end,
    }
    local passed = drive.main({ "folding:no such scenario" }, out)
    io.stdout = saved
    vim.fn.delete(out, "rf")
    eq(false, passed)
    ok(table.concat(captured):find('no scenario matches "no such scenario"', 1, true))
  end)
end)

describe("verify recipes", function()
  for _, name in ipairs(drive.recipes()) do
    for _, sc in ipairs(drive.recipe(name)) do
      it(name .. ": " .. sc.name, function()
        local res = run(sc)
        ok(res.ok, why(res))
      end)
    end
  end
end)

--- The header of a feature file: field -> list of values.
local function header(path)
  local fields, inside = {}, false
  for line in io.lines(path) do
    if line == "---" then
      if inside then
        return fields
      end
      inside = true
    elseif inside then
      local k, v = line:match("^(%w+):%s*(.*)$")
      if k then
        fields[k] = vim.split(v, "%s*,%s*", { trimempty = true })
      end
    end
  end
  return nil
end

describe("verify-org feature map", function()
  local files = {}
  for name, kind in vim.fs.dir(features) do
    if kind == "file" and name:match("%.md$") and name ~= "README.md" then
      files[#files + 1] = name
    end
  end
  table.sort(files)

  it("has a feature file per recipe, and a recipe per feature file", function()
    local areas = vim.tbl_map(function(f)
      return (f:gsub("%.md$", ""))
    end, files)
    eq(drive.recipes(), areas)
  end)

  local doc = table.concat(vim.fn.readfile(root .. "/doc/org.txt"), "\n")
  local maps = require("org.config").opts.mappings
  local actions = require("org.actions").list
  local index = table.concat(vim.fn.readfile(features .. "/README.md"), "\n")

  -- the keys and actions an extension adds once enabled (none is enabled
  -- here): section -> name -> true
  local ext_keys = {}
  for name in vim.fs.dir(root .. "/lua/org/extensions") do
    name = name:gsub("%.lua$", "")
    local loaded, ext = pcall(require, "org.extensions." .. name)
    if loaded and type(ext) == "table" then
      for section, keys in pairs(type(ext.mappings) == "table" and ext.mappings or {}) do
        ext_keys[section] = ext_keys[section] or {}
        for key in pairs(keys) do
          ext_keys[section][key] = true
        end
      end
      for action in pairs(type(ext.actions) == "table" and ext.actions or {}) do
        for _, section in ipairs({ "org", "global" }) do
          ext_keys[section] = ext_keys[section] or {}
          ext_keys[section][action] = true
        end
      end
    end
  end

  for _, file in ipairs(files) do
    it(file .. " names things that exist", function()
      local h = assert(header(features .. "/" .. file), file .. " has no header")
      local area = file:gsub("%.md$", "")
      eq({ area }, h.area)
      eq({ "scripts/verify/recipes/" .. area .. ".lua" }, h.recipe)
      ok(index:find("(" .. file .. ")", 1, true), file .. " isn't in features/README.md")
      for _, field in ipairs({ "keys", "modules", "specs", "doc", "emacs" }) do
        ok(h[field] and #h[field] > 0, file .. ": no " .. field)
      end
      for _, key in ipairs(h.keys) do
        local section, name = key:match("^([%w_]+)%.([%w_]+)$")
        local known = section
          and (
            (type(maps[section]) == "table" and maps[section][name] ~= nil)
            or ((section == "org" or section == "global") and actions[name] ~= nil)
            or (ext_keys[section] and ext_keys[section][name])
          )
        ok(known, file .. ": no key or action " .. key)
      end
      for _, path in ipairs(vim.list_extend(vim.list_extend({}, h.modules), h.specs)) do
        ok(vim.uv.fs_stat(root .. "/" .. path), file .. ": no " .. path)
      end
      for _, tag in ipairs(h.doc) do
        ok(doc:find("*" .. tag .. "*", 1, true), file .. ": no *" .. tag .. "* in doc/org.txt")
      end
      -- placeholders in the text are keys too
      local text = table.concat(vim.fn.readfile(features .. "/" .. file), "\n")
      for ref in text:gmatch("{{([%w_]+%.[%w_]+)}}") do
        ok(vim.tbl_contains(h.keys, ref), file .. ": {{" .. ref .. "}} isn't in its keys")
      end
    end)
  end
end)

-- Each extension's stability ("stable" or "experimental") is the
-- `stability` field of its module (org.extensions.stability()). README.md,
-- doc/org.txt and :checkhealth org must agree with it; promoting an
-- extension (CONTRIBUTING.md, "Promoting an extension") changes the field
-- and these together.
local exts = require("org.extensions")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function read(path)
  local f = assert(io.open(root .. "/" .. path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

--- { stable = { names... }, experimental = { names... } }, sorted, from the
--- modules.
local function by_stability()
  local out = { stable = {}, experimental = {} }
  for _, name in ipairs(exts.builtin()) do
    table.insert(out[exts.stability(name)], name)
  end
  return out
end

--- The `name`s in backticks in `s`, sorted.
local function ticked(s)
  local out = {}
  for n in s:gmatch("`([%w_]+)`") do
    out[#out + 1] = n
  end
  table.sort(out)
  return out
end

describe("extension stability", function()
  it("lists the built-in extensions", function()
    local names = exts.builtin()
    ok(vim.tbl_contains(names, "roam"))
    ok(vim.tbl_contains(names, "heatmap"))
    -- helpers are not extensions
    ok(not vim.tbl_contains(names, "views_util"))
    ok(not vim.tbl_contains(names, "init"))
  end)

  it("every built-in extension has a known stability, experimental by default", function()
    for _, name in ipairs(exts.builtin()) do
      local ext = require("org.extensions." .. name)
      ok(ext.stability == nil or ext.stability == "stable" or ext.stability == "experimental", name)
      eq(ext.stability or "experimental", exts.stability(name), name)
    end
    eq("experimental", exts.stability("no_such_extension"))
  end)

  it("README's table puts each extension under its stability", function()
    local readme = read("README.md")
    local row = readme:match("\n| ✅ Stable | 🧪 Experimental |\n| %-%-%- | %-%-%- |\n(|[^\n]*|)\n")
    ok(row, "README.md has the stability table")
    local cells = vim.split(row, "|", { plain = true })
    local want = by_stability()
    eq(want.stable, ticked(cells[2]), "README.md stable column")
    eq(want.experimental, ticked(cells[3]), "README.md experimental column")
  end)

  it("README marks each extension's entry with its stability", function()
    local readme = read("README.md")
    local section = readme:match("\n## 🧩 Extensions\n(.-)\n## ")
    ok(section, "README.md has an Extensions section")
    local marks = {}
    for mark, name in section:gmatch("\n%- ([^ ]+) %*%*`([%w_]+)`%*%*") do
      marks[name] = mark
    end
    for _, name in ipairs(exts.builtin()) do
      local want = exts.stability(name) == "stable" and "✅" or "🧪"
      eq(want, marks[name], "README.md entry of " .. name)
    end
  end)

  it("doc/org.txt lists each extension under its stability", function()
    local doc = read("doc/org.txt")
    local section = doc:match("%*org%-extensions%-stability%*(.-)\nWriting an extension ~")
    ok(section, "doc/org.txt has *org-extensions-stability*")
    local stable = section:match("\nStable:(.-)\nExperimental:")
    local experimental = section:match("\nExperimental:(.-)\n\n")
    ok(stable and experimental, "the Stable: and Experimental: lists")
    local want = by_stability()
    eq(want.stable, ticked(stable), "doc/org.txt Stable:")
    eq(want.experimental, ticked(experimental), "doc/org.txt Experimental:")
  end)

  it("each extension's section in doc/org.txt states its stability", function()
    local doc = read("doc/org.txt")
    for _, name in ipairs(exts.builtin()) do
      local tag = "*org-extensions-" .. name:gsub("_", "-") .. "*"
      local at = doc:find(tag, 1, true)
      ok(at, "doc/org.txt has " .. tag)
      local head = doc:sub(at, at + 400)
      local stated = head:match("\nStability: (%a+) %(|org%-extensions%-stability|%)")
      eq(exts.stability(name), stated, "Stability: line of " .. tag)
    end
  end)

  it(":checkhealth org shows the stability of the enabled extensions", function()
    local want = by_stability()
    local stable, experimental = want.stable[1], want.experimental[1]
    local saved = exts.loaded
    local out = {}
    local h = {}
    for _, k in ipairs({ "start", "ok", "info", "warn", "error" }) do
      h[k] = function(msg)
        out[#out + 1] = k .. ": " .. msg
      end
    end
    exts.loaded = {
      [stable] = {},
      third_party = {},
      third_stable = { stability = "stable" },
      third_experimental = { stability = "experimental" },
    }
    if experimental then
      exts.loaded[experimental] = {}
    end
    local ran, err = pcall(exts.check, h)
    exts.loaded = saved
    ok(ran, err)
    local text = table.concat(out, "\n")
    ok(text:find("ok: enabled: " .. stable .. "\ninfo: stability: stable\n", 1, true), text)
    -- a third-party extension gets a stability line only when it sets one
    ok(text:find("ok: enabled: third_party$") or text:find("ok: enabled: third_party\nok:"), text)
    ok(text:find("ok: enabled: third_stable\ninfo: stability: stable", 1, true), text)
    ok(
      text:find("ok: enabled: third_experimental\ninfo: stability: experimental, its options may change", 1, true),
      text
    )
    if experimental then
      local line = "ok: enabled: "
        .. experimental
        .. "\ninfo: stability: experimental, its options may change (:h org-extensions-stability)"
      ok(text:find(line, 1, true), text)
    end
  end)
end)

describe("extension promotion report", function()
  it("measures the criteria of the extensions asked for", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local demo, cov = dir .. "/config.lua", dir .. "/coverage.json"
    vim.fn.writefile({ "return {", "  extensions = {", "    heatmap = {},", "  },", "}" }, demo)
    vim.fn.writefile({
      vim.json.encode({
        modules = {
          ["org.extensions.heatmap"] = { file = "lua/org/extensions/heatmap/init.lua", lines = 100, hit = 50 },
          ["org.extensions.kanban"] = { file = "lua/org/extensions/kanban/init.lua", lines = 10, hit = 10 },
        },
      }),
    }, cov)
    local res = vim
      .system({
        vim.v.progpath,
        "--headless",
        "--clean",
        "-l",
        root .. "/scripts/extension_report.lua",
        "--json",
        "--no-gh",
        "--demo",
        demo,
        "--coverage",
        cov,
        "heatmap",
        "kanban",
      }, { text = true })
      :wait()
    vim.fn.delete(dir, "rf")
    eq(0, res.code, res.stderr)
    local data = vim.json.decode(res.stdout)
    eq(2, #data.extensions)
    local rows = {}
    for _, r in ipairs(data.extensions) do
      rows[r.name] = r
    end
    for _, name in ipairs({ "heatmap", "kanban" }) do
      eq(exts.stability(name), rows[name].stability)
      eq(true, rows[name].criteria.health.pass)
      eq(true, rows[name].criteria.docs.pass, rows[name].criteria.docs.detail)
    end
    eq("50.0%", rows.heatmap.criteria.coverage.value)
    eq(false, rows.heatmap.criteria.coverage.pass)
    eq(true, rows.kanban.criteria.coverage.pass)
    eq(true, rows.heatmap.criteria.demo.pass)
    eq(false, rows.kanban.criteria.demo.pass)
    -- gh is off: not measured, so it neither passes nor fails
    eq("-", rows.heatmap.criteria.bugs.value)
    eq(nil, rows.heatmap.criteria.bugs.pass)
    -- below the coverage bar: not a candidate
    eq(false, rows.heatmap.candidate)
  end)

  it("rejects an extension that doesn't exist", function()
    local res = vim
      .system(
        { vim.v.progpath, "--headless", "--clean", "-l", root .. "/scripts/extension_report.lua", "nope" },
        { text = true }
      )
      :wait()
    eq(2, res.code)
    ok(res.stderr:find("no built-in extension nope", 1, true), res.stderr)
  end)
end)

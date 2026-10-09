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

  it("the bug report form lists every built-in extension", function()
    local form = read(".github/ISSUE_TEMPLATE/bug_report.yml")
    local block = form:match("\n    id: extension\n(.-)\n    validations:")
    ok(block, "bug_report.yml has the Extension dropdown")
    local options = {}
    for o in block:gmatch("\n        %- ([^\n]+)") do
      options[#options + 1] = o
    end
    eq("None (org.nvim itself)", table.remove(options, 1))
    eq(exts.builtin(), options)
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

  --- Runs the report with `args` and returns its rows by name.
  local function report(args)
    local cmd = { vim.v.progpath, "--headless", "--clean", "-l", root .. "/scripts/extension_report.lua", "--json" }
    local res = vim.system(vim.list_extend(cmd, args), { text = true }):wait()
    eq(0, res.code, res.stderr)
    local rows = {}
    for _, r in ipairs(vim.json.decode(res.stdout).extensions) do
      rows[r.name] = r
    end
    return rows
  end

  --- A throwaway git repository built by `steps`: { files = { path... },
  --- msg = ..., days_ago = N, tags = { ... } }, oldest first.
  local function repo(steps)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local env = { GIT_CONFIG_NOSYSTEM = "1", GIT_CONFIG_GLOBAL = "/dev/null" }
    local function git(args, date)
      local e = vim.deepcopy(env)
      if date then
        e.GIT_AUTHOR_DATE, e.GIT_COMMITTER_DATE = date, date
      end
      local cmd = { "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false" }
      local res = vim.system(vim.list_extend(cmd, args), { text = true, env = e }):wait()
      eq(0, res.code, res.stderr)
    end
    git({ "init", "-q" })
    for i, step in ipairs(steps) do
      for _, f in ipairs(step.files or { "README" }) do
        vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. f), "p")
        vim.fn.writefile({ tostring(i) }, dir .. "/" .. f, "a")
      end
      git({ "add", "-A" })
      git({ "commit", "-q", "-m", step.msg }, ("@%d +0000"):format(os.time() - (step.days_ago or 0) * 86400))
      for _, t in ipairs(step.tags or {}) do
        git({ "tag", t })
      end
    end
    return dir
  end

  local function ext_file(name)
    return "lua/org/extensions/" .. name .. "/init.lua"
  end

  it("charges a breaking change only to the extensions it names", function()
    local dir = repo({
      {
        msg = "feat: the extensions",
        files = { ext_file("heatmap"), ext_file("code"), ext_file("present"), ext_file("review") },
        days_ago = 400,
        tags = { "v1.0.0" },
      },
      { msg = "feat(journal): add journal", files = { ext_file("journal") }, days_ago = 5 },
      {
        -- every name in its footer is an extension's, but as plain words
        msg = "refactor(babel)!: hash the whole src block\n\n"
          .. "BREAKING CHANGE: the code of a src block is hashed with its header, "
          .. "so present caches are invalidated; review them.",
        days_ago = 300,
        tags = { "v1.1.0" },
      },
      { msg = "fix: x", days_ago = 290, tags = { "v1.1.1", "v1.2.0" } },
      { msg = "feat(extensions)!: rename the heatmap :Org heatmap kinds", days_ago = 200, tags = { "v1.3.0" } },
      { msg = "fix: y", days_ago = 100, tags = { "v1.3.1" } },
      { msg = "fix: z", days_ago = 50, tags = { "v1.4.0" } },
    })
    local rows = report({ "--no-gh", "--repo", dir, "heatmap", "code", "present", "review", "journal" })
    vim.fn.delete(dir, "rf")
    for _, name in ipairs({ "code", "present", "review" }) do
      eq("never", rows[name].criteria.breaking.value, name)
      eq(true, rows[name].criteria.breaking.pass, name)
    end
    -- `feat(extensions)!:` naming it: v1.3.0 shipped it, v1.4.0 is the only
    -- minor release after it (v1.3.1 is a patch)
    eq("1", rows.heatmap.criteria.breaking.value)
    eq(false, rows.heatmap.criteria.breaking.pass)
    -- minor releases with its first commit: v1.0.0 to v1.4.0, not v1.1.1
    -- or v1.3.1
    eq("5, 400d", rows.heatmap.criteria.added.value)
    eq(true, rows.heatmap.criteria.added.pass)
    -- in four minor releases, but only five days old
    eq(false, rows.journal.criteria.added.pass)
  end)

  it("charges a footer that names the extension unambiguously", function()
    local dir = repo({
      { msg = "feat: review", files = { ext_file("review"), ext_file("code") }, days_ago = 90, tags = { "v1.0.0" } },
      { msg = "fix(agenda): x\n\nBREAKING CHANGE: the `review` keys are now under keys.", tags = { "v1.1.0" } },
    })
    local rows = report({ "--no-gh", "--repo", dir, "review", "code" })
    vim.fn.delete(dir, "rf")
    eq("0", rows.review.criteria.breaking.value)
    eq("never", rows.code.criteria.breaking.value)
  end)

  it("doesn't measure the history without tags or in a shallow clone", function()
    local dir = repo({ { msg = "feat: heatmap", files = { ext_file("heatmap") }, days_ago = 90 } })
    local rows = report({ "--no-gh", "--repo", dir, "heatmap" })
    for _, k in ipairs({ "added", "breaking" }) do
      eq("?", rows.heatmap.criteria[k].value, k)
      eq(nil, rows.heatmap.criteria[k].pass, k)
      eq("needs full history and tags", rows.heatmap.criteria[k].detail, k)
    end
    eq(false, rows.heatmap.candidate)

    local full = repo({
      { msg = "feat: heatmap", files = { ext_file("heatmap") }, days_ago = 90, tags = { "v1.0.0" } },
      { msg = "fix: x", tags = { "v1.1.0" } },
    })
    local shallow = vim.fn.tempname()
    local res = vim.system({ "git", "clone", "-q", "--depth", "1", "file://" .. full, shallow }, { text = true }):wait()
    eq(0, res.code, res.stderr)
    rows = report({ "--no-gh", "--repo", shallow, "heatmap" })
    eq(nil, rows.heatmap.criteria.added.pass)
    eq(nil, rows.heatmap.criteria.breaking.pass)
    -- the full clone is measured
    rows = report({ "--no-gh", "--repo", full, "heatmap" })
    eq("2, 90d", rows.heatmap.criteria.added.value)
    eq("never", rows.heatmap.criteria.breaking.value)
    for _, d in ipairs({ dir, full, shallow }) do
      vim.fn.delete(d, "rf")
    end
  end)

  it("counts the open bugs about each extension", function()
    local file = vim.fn.tempname()
    local function issue(number, title, body)
      return { number = number, title = title, body = body or "", labels = { { name = "bug" } } }
    end
    vim.fn.writefile({
      vim.json.encode({
        issue(1, "heatmap: crash on an empty file"),
        issue(2, "Wrong code block in the agenda", "### What happened\n\nx\n\n### Extension\n\nreview\n\n### Steps"),
        issue(3, "Folding breaks", "### Extension\n\nNone (org.nvim itself)\n\nThe present code is wrong; review it."),
        issue(4, "The kanban board doesn't refresh"),
        issue(5, "[present] slides overlap"),
        issue(6, "fix(timeline): dates", "### Extension\n\n_No response_"),
        issue(7, "Timeline of the merge", "With the drill extension enabled"),
      }),
    }, file)
    local rows =
      report({ "--issues", file, "heatmap", "review", "code", "kanban", "present", "timeline", "merge", "drill" })
    vim.fn.delete(file)
    local function bugs(name)
      return rows[name].criteria.bugs.detail
    end
    eq("#1", bugs("heatmap"))
    eq("#2", bugs("review"))
    eq(nil, bugs("code"))
    eq("0", rows.code.criteria.bugs.value)
    eq(true, rows.code.criteria.bugs.pass)
    eq("#4", bugs("kanban"))
    eq("#5", bugs("present"))
    eq("#6", bugs("timeline"))
    eq(nil, bugs("merge"))
    eq("#7", bugs("drill"))
    eq(false, rows.heatmap.criteria.bugs.pass)
  end)

  it("counts the documented keys of present and review", function()
    local rows = report({ "--no-gh", "present", "review" })
    for _, name in ipairs({ "present", "review" }) do
      eq(true, rows[name].criteria.docs.pass, rows[name].criteria.docs.detail)
    end
  end)
end)

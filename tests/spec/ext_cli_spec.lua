local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
-- what :Org cli_install writes: a symlink, or a launcher on Windows
local LINK = vim.fn.has("win32") == 1 and "org.cmd" or "org"
local cli = require("org.extensions.cli.run")

local function reset()
  require("org").setup({
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
  })
end

local TODAY = os.date("%Y-%m-%d %a")
local TOMORROW = os.date("%Y-%m-%d %a", os.time() + 86400)

--- A temp directory with work.org, a config file and XDG dirs.
local function workspace(extra_config)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({
    "#+CATEGORY: work",
    "* TODO [#A] Review pull request :code:",
    "  SCHEDULED: <" .. TODAY .. " 10:00>",
    "* TODO Write release notes",
    "  DEADLINE: <" .. TODAY .. ">",
    "* Standup meeting",
    "  <" .. TODAY .. " 09:30-09:45>",
    "* TODO Plan the offsite",
    "  SCHEDULED: <" .. TOMORROW .. ">",
    "* DONE Old thing",
    "* Notes",
    "Searchable zebra text.",
  }, dir .. "/work.org")
  local cfg = {
    "local dir = " .. vim.inspect(dir),
    "return {",
    "  org_directory = dir,",
    "  agenda_files = { dir .. '/work.org' },",
    "  capture = { templates = {",
    "    t = { description = 'Task', target = dir .. '/inbox.org', headline = 'Inbox',",
    "          template = '* TODO %?\\n  %U' },",
    "    n = { description = 'Note', target = dir .. '/notes.org', template = '* %i' },",
    "    p = { description = 'Prompt', target = dir .. '/inbox.org', template = '* %^{Title}' },",
    "  } },",
    "  clock = { persist = true, persist_file = dir .. '/clock.json' },",
  }
  vim.list_extend(cfg, extra_config or {})
  cfg[#cfg + 1] = "}"
  vim.fn.writefile(cfg, dir .. "/cfg.lua")
  for _, d in ipairs({ "config", "state", "cache" }) do
    vim.fn.mkdir(dir .. "/xdg-" .. d, "p")
  end
  return dir
end

--- Run bin/org in a subprocess (never interactive: stdin is closed).
local function run(dir, args, stdin)
  local cmd = { require("org.extensions.cli").bin(), "--config", dir .. "/cfg.lua" }
  vim.list_extend(cmd, args)
  local env = {
    ORG_NVIM_CONFIG = "",
    XDG_CONFIG_HOME = dir .. "/xdg-config",
    XDG_STATE_HOME = dir .. "/xdg-state",
    XDG_CACHE_HOME = dir .. "/xdg-cache",
    XDG_DATA_HOME = vim.env.XDG_DATA_HOME or (dir .. "/xdg-data"),
    ORG_NVIM_BIN = vim.v.progpath,
  }
  local res = vim.system(cmd, { text = true, stdin = stdin or false, env = env }):wait(20000)
  return res.code, res.stdout or "", res.stderr or ""
end

local function read(path)
  return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
end

describe("cli arguments", function()
  it("splits flags and words", function()
    local flags, words = cli.parse_args({ "--files", "a.org,b.org", "agenda", "--json", "week", "--files=c.org" })
    eq({ "a.org", "b.org", "c.org" }, flags.files)
    eq(true, flags.json)
    eq({ "agenda", "week" }, words)
  end)

  it("reads values after flags and stops at --", function()
    local flags, words = cli.parse_args({ "capture", "-t", "n", "--", "--not-a-flag", "text" })
    eq("n", flags.template)
    eq({ "capture", "--not-a-flag", "text" }, words)
  end)

  it("rejects unknown options and missing values", function()
    local success, e = pcall(cli.parse_args, { "--nope" })
    eq(false, success)
    eq(2, e.code)
    success, e = pcall(cli.parse_args, { "agenda", "--date" })
    eq(false, success)
    ok(e.msg:match("needs a value"))
  end)

  it("keeps a lone dash as a word (stdin)", function()
    local _, words = cli.parse_args({ "capture", "-" })
    eq({ "capture", "-" }, words)
  end)
end)

describe("cli helpers", function()
  after_each(reset)

  it("formats the clock", function()
    local c = { title = "Task", elapsed = "0:42", minutes = 42, total = 102, effort = 60, file = "/x/a.org" }
    eq("0:42 Task", cli.format_clock("%e %t", c))
    eq("1:42/1:00 100%", cli.format_clock("%T/%E 100%%", c))
    eq("%q", cli.format_clock("%q", c))
  end)

  it("puts the text where %? was in a capture template", function()
    require("org").setup({
      capture = {
        templates = {
          t = { description = "T", target = "/tmp/x.org", template = "* TODO %?\n  %U" },
          i = { description = "I", target = "/tmp/x.org", template = "* %i %?" },
          e = { description = "E", target = "/tmp/x.org", type = "item" },
        },
      },
    })
    local t = cli.capture_template("t")
    eq("* TODO %i\n  %U", t.template)
    eq(true, t.immediate_finish)
    eq("* %i %?", cli.capture_template("i").template)
    eq("- %i", cli.capture_template("e").template)
    local success, e = pcall(cli.capture_template, "zz")
    eq(false, success)
    eq(2, e.code)
  end)

  it("finds headlines by title, exact title first, and by ID", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({
      "* Write",
      "* Write docs",
      ":PROPERTIES:",
      ":ID: abc-123",
      ":END:",
      "* Rewrite",
    }, dir .. "/a.org")
    require("org").setup({ agenda_files = { dir .. "/a.org" } })
    eq(1, #cli.find_headlines("write"))
    eq("Write", cli.find_headlines("WRITE")[1]:plain_title())
    eq(2, #cli.find_headlines("docs") + #cli.find_headlines("rewrite"))
    eq("Write docs", cli.find_headlines("id:abc-123")[1]:plain_title())
    eq(0, #cli.find_headlines("nothing here"))
    vim.fn.delete(dir, "rf")
  end)

  it("returns 2 with usage for no command and 0 for help", function()
    local saved = cli.stdout
    local text = {}
    cli.stdout = function(s)
      text[#text + 1] = s
    end
    local code = cli.main({})
    local help = cli.main({ "help" })
    cli.stdout = saved
    eq(2, code)
    eq(0, help)
    ok(table.concat(text):match("usage: org"))
  end)
end)

describe("cli extension", function()
  -- keep "org CLI installed" and the $PATH warning out of the test output
  local real_notify
  before_each(function()
    real_notify = vim.notify
    vim.notify = function() end
  end)
  after_each(function()
    vim.notify = real_notify
    reset()
  end)

  it("is off by default and registers cli_install when enabled", function()
    reset()
    eq(nil, require("org.actions").list.cli_install)
    require("org").setup({ extensions = { cli = { install_dir = "/tmp/x" } } })
    ok(require("org.actions").list.cli_install)
    eq("/tmp/x", require("org.extensions").opts("cli").install_dir)
    eq("%e %t", require("org.extensions").opts("cli").status_format)
    reset()
    eq(nil, require("org.actions").list.cli_install)
  end)

  it("links bin/org into install_dir after confirming", function()
    local dir = vim.fn.tempname()
    require("org").setup({ extensions = { cli = { install_dir = dir } } })
    local select = vim.ui.select
    local asked
    vim.ui.select = function(items, o, cb)
      asked = o.prompt
      cb("Yes")
    end
    require("org.actions").run("cli_install")
    vim.wait(1000, function()
      return vim.uv.fs_lstat(dir .. "/" .. LINK) ~= nil
    end)
    vim.ui.select = select
    ok(asked:match("Link"))
    if vim.fn.has("win32") == 1 then
      -- a launcher, as symlinks need administrator rights
      local bin = require("org.extensions.cli").bin():gsub("/", "\\")
      eq({ '@"' .. bin .. '" %*' }, vim.fn.readfile(dir .. "/org.cmd"))
    else
      eq(vim.fs.normalize(vim.fn.resolve(root .. "/bin/org")), vim.fs.normalize(vim.fn.resolve(dir .. "/org")))
    end
    vim.fn.delete(dir, "rf")
  end)

  it("does not link when declined, nor over another file", function()
    local dir = vim.fn.tempname()
    require("org").setup({ extensions = { cli = { install_dir = dir } } })
    local select = vim.ui.select
    vim.ui.select = function(_, _, cb)
      cb("No")
    end
    require("org.actions").run("cli_install")
    eq(nil, vim.uv.fs_lstat(dir .. "/" .. LINK))
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "other" }, dir .. "/" .. LINK)
    local called = false
    vim.ui.select = function(_, _, cb)
      called = true
      cb("Yes")
    end
    require("org.actions").run("cli_install")
    vim.ui.select = select
    eq(false, called)
    eq({ "other" }, vim.fn.readfile(dir .. "/" .. LINK))
    vim.fn.delete(dir, "rf")
  end)

  it("reports in health", function()
    local msgs = {}
    local h = {}
    for _, k in ipairs({ "ok", "warn", "error", "info", "start" }) do
      h[k] = function(m)
        msgs[#msgs + 1] = k .. ": " .. m
      end
    end
    require("org.extensions.cli").health(h)
    ok(msgs[1]:match("^ok: cli: .*bin/org$"))
  end)
end)

describe("cli (bin/org)", function()
  it("prints the day agenda as text", function()
    local dir = workspace()
    local code, stdout = run(dir, { "agenda", "day" })
    eq(0, code)
    ok(stdout:match("Day%-agenda"))
    ok(stdout:match("Review pull request"))
    ok(stdout:match("Standup meeting"))
    ok(not stdout:match("Plan the offsite"))
    vim.fn.delete(dir, "rf")
  end)

  it("prints the agenda as JSON", function()
    local dir = workspace()
    local code, stdout = run(dir, { "agenda", "week", "--json" })
    eq(0, code)
    local data = vim.json.decode(stdout)
    eq("agenda", data.view)
    local by_title = {}
    for _, it in ipairs(data.items) do
      by_title[it.title] = it
    end
    local review = by_title["Review pull request"]
    eq("10:00", review.time)
    eq("TODO", review.todo)
    eq("A", review.priority)
    eq({ "code" }, review.tags)
    eq("work", review.category)
    eq("scheduled", review.type)
    eq(os.date("%Y-%m-%d"), review.date)
    eq(vim.fs.normalize(vim.fn.resolve(dir .. "/work.org")), vim.fs.normalize(vim.fn.resolve(review.file)))
    eq(2, review.line)
    eq("09:45", by_title["Standup meeting"].end_time)
    ok(by_title["Plan the offsite"])
    vim.fn.delete(dir, "rf")
  end)

  it("moves the agenda with --date and lists TODOs", function()
    local dir = workspace()
    local _, stdout = run(dir, { "agenda", "day", "--date", "+1", "--json" })
    local data = vim.json.decode(stdout)
    eq(os.date("%Y-%m-%d", os.time() + 86400), data.start)
    eq("Plan the offsite", data.items[1].title)
    local code, todo = run(dir, { "agenda", "todo" })
    eq(0, code)
    ok(todo:match("Write release notes"))
    ok(not todo:match("Old thing"))
    vim.fn.delete(dir, "rf")
  end)

  it("uses --files over the config's agenda files", function()
    local dir = workspace()
    vim.fn.writefile({ "* TODO Other file task" }, dir .. "/other.org")
    local _, stdout = run(dir, { "--files", dir .. "/other.org", "agenda", "todo" })
    ok(stdout:match("Other file task"))
    ok(not stdout:match("Write release notes"))
    vim.fn.delete(dir, "rf")
  end)

  it("captures text with a template", function()
    local dir = workspace()
    local code, stdout = run(dir, { "capture", "Buy", "milk" })
    eq(0, code)
    ok(stdout:match("Captured to"))
    local lines = read(dir .. "/inbox.org")
    eq("* Inbox", lines[1])
    eq("** TODO Buy milk", lines[2])
    ok(lines[3]:match("^  %[%d+%-%d+%-%d+"))
    code = run(dir, { "capture", "-t", "n", "A note" })
    eq(0, code)
    eq({ "* A note" }, read(dir .. "/notes.org"))
    vim.fn.delete(dir, "rf")
  end)

  it("captures from stdin and lists templates", function()
    local dir = workspace()
    local code = run(dir, { "capture", "-t", "n", "-" }, "From a pipe\n")
    eq(0, code)
    eq({ "* From a pipe" }, read(dir .. "/notes.org"))
    local _, stdout = run(dir, { "capture", "--list", "--json" })
    local list = vim.json.decode(stdout)
    local keys = {}
    for _, t in ipairs(list) do
      keys[#keys + 1] = t.key
    end
    eq({ "n", "p", "t" }, keys)
    vim.fn.delete(dir, "rf")
  end)

  it("fails instead of prompting", function()
    local dir = workspace()
    local code, _, stderr = run(dir, { "capture", "-t", "p", "text" })
    eq(3, code)
    ok(stderr:match("interactive input"))
    eq({}, read(dir .. "/inbox.org"))
    vim.fn.delete(dir, "rf")
  end)

  it("clocks in, reports the status and clocks out", function()
    local dir = workspace()
    local code, stdout = run(dir, { "clock", "status" })
    eq(0, code)
    eq("No running clock\n", stdout)
    code, stdout = run(dir, { "clock", "in", "release notes" })
    eq(0, code)
    eq("Clocked in: Write release notes\n", stdout)
    local lines = read(dir .. "/work.org")
    ok(table.concat(lines, "\n"):match("CLOCK: %[[^%]]+%]\n"))
    local _, js = run(dir, { "clock", "status", "--json" })
    local st = vim.json.decode(js)
    eq(true, st.active)
    eq("Write release notes", st.title)
    eq(vim.fs.normalize(vim.fn.resolve(dir .. "/work.org")), vim.fs.normalize(vim.fn.resolve(st.file)))
    eq(0, st.minutes)
    local _, short = run(dir, { "clock", "status", "--format", "[%e] %t" })
    eq("[0:00] Write release notes\n", short)
    code, stdout = run(dir, { "clock", "out" })
    eq(0, code)
    ok(stdout:match("^Clocked out: Write release notes"))
    ok(table.concat(read(dir .. "/work.org"), "\n"):match("CLOCK: %[[^%]]+%]%-%-%[[^%]]+%] =>"))
    _, stdout = run(dir, { "clock", "status", "--short" })
    eq("", stdout)
    code = run(dir, { "clock", "out" })
    eq(1, code)
    vim.fn.delete(dir, "rf")
  end)

  it("finds the running clock without a persist file", function()
    local dir = workspace()
    run(dir, { "clock", "in", "Review" })
    vim.fn.delete(dir .. "/clock.json")
    local _, js = run(dir, { "clock", "status", "--json" })
    eq("Review pull request", vim.json.decode(js).title)
    vim.fn.delete(dir, "rf")
  end)

  it("refuses an ambiguous or unknown clock-in query", function()
    local dir = workspace()
    local code, _, stderr = run(dir, { "clock", "in", "e" })
    eq(1, code)
    ok(stderr:match("several headings match"))
    code, _, stderr = run(dir, { "clock", "in", "nothing like this" })
    eq(1, code)
    ok(stderr:match("no heading matches"))
    vim.fn.delete(dir, "rf")
  end)

  it("searches with plain words, and with ql when enabled", function()
    local dir = workspace()
    local code, stdout = run(dir, { "search", "zebra" })
    eq(0, code)
    ok(stdout:match("work%.org:11: %* Notes"))
    local _, js = run(dir, { "search", "release", "--json" })
    local res = vim.json.decode(js)
    eq(1, #res)
    eq("Write release notes", res[1].title)
    eq("TODO", res[1].todo)
    ok(res[1].deadline)
    code = run(dir, { "search", "nomatchatall" })
    eq(1, code)
    local qdir = workspace({ "  extensions = { ql = { views_file = false } }," })
    _, stdout = run(qdir, { "search", '(and (todo) (priority "A"))' })
    ok(stdout:match("Review pull request"))
    ok(not stdout:match("release notes"))
    vim.fn.delete(dir, "rf")
    vim.fn.delete(qdir, "rf")
  end)

  it("exports a file to stdout and to a file", function()
    local dir = workspace()
    local code, stdout = run(dir, { "export", dir .. "/work.org", "md", "--stdout" })
    eq(0, code)
    ok(stdout:match("Review pull request"))
    code, stdout = run(dir, { "export", dir .. "/work.org", "html", "-o", dir .. "/out.html" })
    eq(0, code)
    eq(dir .. "/out.html\n", stdout)
    ok(table.concat(read(dir .. "/out.html"), "\n"):match("<html"))
    vim.fn.delete(dir, "rf")
  end)

  it("reports usage errors with exit code 2", function()
    local dir = workspace()
    local code, _, stderr = run(dir, { "frobnicate" })
    eq(2, code)
    ok(stderr:match("unknown command"))
    code = run(dir, { "agenda", "nosuchview" })
    eq(2, code)
    code = run(dir, { "export", dir .. "/missing.org", "md" })
    eq(2, code)
    vim.fn.delete(dir, "rf")
  end)

  it("fails on a missing config file", function()
    local dir = workspace()
    vim.fn.delete(dir .. "/cfg.lua")
    local code, _, stderr = run(dir, { "agenda" })
    eq(2, code)
    ok(stderr:match("config file not found"))
    vim.fn.delete(dir, "rf")
  end)
end)

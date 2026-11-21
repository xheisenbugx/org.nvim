-- org add, org append and org set title (the cli extension), run as
-- bin/org in a subprocess on a temp workspace

--- A temp directory with work.org and a config file.
local function workspace(lines, extra_config)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(lines, dir .. "/work.org")
  local cfg = {
    "local dir = " .. vim.inspect(dir),
    "return {",
    "  org_directory = dir,",
    "  agenda_files = { dir .. '/*.org' },",
    "  default_notes_file = dir .. '/work.org',",
    "  todo_keywords = { 'TODO NEXT | DONE' },",
  }
  vim.list_extend(cfg, extra_config or {})
  cfg[#cfg + 1] = "}"
  vim.fn.writefile(cfg, dir .. "/cfg.lua")
  for _, d in ipairs({ "config", "state", "cache" }) do
    vim.fn.mkdir(dir .. "/xdg-" .. d, "p")
  end
  return dir
end

local MAIN = vim.api.nvim_get_runtime_file("lua/org/extensions/cli/main.lua", false)[1]

--- Run bin/org: exit code, stdout, stderr. An argument of several lines
--- runs main.lua directly, as `org mcp` does: cmd.exe (bin/org.cmd on
--- Windows) cuts an argument at a newline.
local function run(dir, args, stdin)
  local multiline = vim.iter(args):any(function(a)
    return a:find("\n", 1, true) ~= nil
  end)
  local cmd = multiline and { vim.v.progpath, "--headless", "-l", MAIN } or { require("org.extensions.cli").bin() }
  vim.list_extend(cmd, { "--config", dir .. "/cfg.lua", "--no-server" })
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

local function json(dir, args)
  local code, out = run(dir, vim.list_extend({ "--json" }, args))
  return code, vim.json.decode(out)
end

local function read(dir)
  return vim.fn.readfile(dir .. "/work.org")
end

local PROJECT = {
  "#+TITLE: Work",
  "* Project X",
  "  :PROPERTIES:",
  "  :ID:       px",
  "  :END:",
  "Some notes.",
  "** TODO First task",
  "** Second",
  "",
  "* Other",
}

describe("cli add", function()
  it("adds a heading as the last child, before the blank lines after the subtree", function()
    local dir = workspace(PROJECT)
    local code = run(dir, { "add", "id:px", "Third" })
    eq(0, code)
    eq({
      "#+TITLE: Work",
      "* Project X",
      "  :PROPERTIES:",
      "  :ID:       px",
      "  :END:",
      "Some notes.",
      "** TODO First task",
      "** Second",
      "** Third",
      "",
      "* Other",
    }, read(dir))
  end)

  it("adds the first child with --first", function()
    local dir = workspace(PROJECT)
    eq(0, (run(dir, { "add", "--first", "Project X", "Zeroth" })))
    local lines = read(dir)
    eq("Some notes.", lines[6])
    eq("** Zeroth", lines[7])
    eq("** TODO First task", lines[8])
  end)

  it("adds a top-level heading at the end of a file, by name or path", function()
    local dir = workspace(PROJECT)
    eq(0, (run(dir, { "add", "work", "By name" })))
    eq(0, (run(dir, { "add", dir .. "/work.org", "By path" })))
    local lines = read(dir)
    -- blank_before_new_entry.heading = auto: "* Other" has a blank line above
    eq({ "* Other", "", "* By name", "", "* By path" }, vim.list_slice(lines, #lines - 4))
  end)

  it("adds to an empty file", function()
    local dir = workspace({})
    eq(0, (run(dir, { "add", "work.org", "Only" })))
    eq({ "* Only" }, read(dir))
  end)

  it("sets the keyword, priority, tags, dates, properties and body", function()
    local dir = workspace(PROJECT)
    local code, _, err = run(dir, {
      "add",
      "id:px",
      "Third task",
      "--todo",
      "NEXT",
      "--priority",
      "A",
      "--tag",
      "work",
      "--tag",
      "urgent",
      "--scheduled",
      "2026-10-23",
      "--deadline",
      "2026-10-30",
      "--property",
      "Effort=1:00",
      "--body",
      "Line one\nLine two\n\n* starred",
    })
    eq(0, code, err)
    local lines = read(dir)
    local i = 9
    ok(lines[i]:match("^%*%* NEXT %[#A%] Third task +:work:urgent:$"), lines[i])
    eq(77, #lines[i])
    eq("SCHEDULED: <2026-10-23 Fri> DEADLINE: <2026-10-30 Fri>", lines[i + 1])
    eq({ ":PROPERTIES:", ":Effort:   1:00", ":END:" }, vim.list_slice(lines, i + 2, i + 4))
    -- a * line of the body gets a space: it isn't a heading
    eq({ "Line one", "Line two", "", " * starred", "", "* Other" }, vim.list_slice(lines, i + 5))
  end)

  it("indents the body with adapt_indentation", function()
    local dir = workspace(PROJECT, { "  adapt_indentation = true," })
    eq(0, (run(dir, { "add", "Other", "Child", "--body", "text" })))
    local lines = read(dir)
    eq({ "** Child", "   text" }, vim.list_slice(lines, #lines - 1))
  end)

  it("rejects an unknown keyword, a bad tag and a bad property", function()
    local dir = workspace(PROJECT)
    local code, res = json(dir, { "add", "id:px", "x", "--todo", "WAITING" })
    eq(2, code)
    eq("bad_value", res.errors[1].code)
    eq({ "TODO", "NEXT", "DONE" }, res.errors[1].details.keywords)
    code, res = json(dir, { "add", "id:px", "x", "--tag", "bad tag" })
    eq(2, code)
    eq("bad_value", res.errors[1].code)
    code, res = json(dir, { "add", "id:px", "x", "--property", "novalue" })
    eq(2, code)
    eq("bad_value", res.errors[1].code)
    code, res = json(dir, { "add", "id:px", "x", "--property", "NOTE=two\nlines" })
    eq(2, code)
    eq("bad_value", res.errors[1].code)
    eq(PROJECT, read(dir))
  end)

  it("gives the new heading and its parent in --json", function()
    local dir = workspace(PROJECT)
    local code, res = json(dir, { "add", "id:px", "Third", "--todo", "TODO" })
    eq(0, code)
    eq("add", res.command)
    eq("Third", res.data.headline.title)
    eq("TODO", res.data.headline.todo)
    eq(2, res.data.headline.level)
    eq({ "Project X" }, res.data.headline.outline_path)
    eq("px", res.data.parent.id)
    code, res = json(dir, { "add", "work", "Top" })
    eq(0, code)
    eq(vim.NIL, res.data.parent)
  end)
end)

describe("cli append", function()
  it("appends a paragraph after the body, before the children", function()
    local dir = workspace(PROJECT)
    local code, res = json(dir, { "append", "id:px", "More notes.\n- item" })
    eq(0, code)
    eq("More notes.\n- item", res.data.text)
    eq("Project X", res.data.headline.title)
    eq({ "Some notes.", "", "More notes.", "- item", "** TODO First task" }, vim.list_slice(read(dir), 6, 10))
  end)

  it("appends after planning and the drawer without a blank line", function()
    local dir = workspace({ "* Task", "  SCHEDULED: <2026-10-20 Tue>", "  :LOGBOOK:", "  - Note", "  :END:", "* Next" })
    eq(0, (run(dir, { "append", "Task", "text" })))
    eq(
      { "* Task", "  SCHEDULED: <2026-10-20 Tue>", "  :LOGBOOK:", "  - Note", "  :END:", "", "text", "* Next" },
      read(dir)
    )
    dir = workspace({ "* Task", "  SCHEDULED: <2026-10-20 Tue>", "* Next" })
    eq(0, (run(dir, { "append", "Task", "text" })))
    eq({ "* Task", "  SCHEDULED: <2026-10-20 Tue>", "text", "* Next" }, read(dir))
  end)

  -- #386: a capture's `%U` / `%T` line is the entry's "created at", not a
  -- paragraph: the first append goes right under it, later ones don't
  it("appends under a lone timestamp line without a blank line", function()
    local dir = workspace({ "* Notes", "** Call the vendor", "  [2026-11-21 Sat 11:23]", "* Next" })
    eq(0, (run(dir, { "append", "Call the vendor", "Ask about the price." })))
    eq({ "* Notes", "** Call the vendor", "  [2026-11-21 Sat 11:23]", "Ask about the price.", "* Next" }, read(dir))
    eq(0, (run(dir, { "append", "Call the vendor", "Second." })))
    eq({ "  [2026-11-21 Sat 11:23]", "Ask about the price.", "", "Second.", "* Next" }, vim.list_slice(read(dir), 3))
    dir = workspace({ "* Task", "  SCHEDULED: <2026-10-20 Tue>", "  <2026-10-19 Mon 09:00>", "* Next" })
    eq(0, (run(dir, { "append", "Task", "text" })))
    eq({ "  <2026-10-19 Mon 09:00>", "text", "* Next" }, vim.list_slice(read(dir), 3))
  end)

  it("still starts a paragraph after a line with a timestamp in its text", function()
    local dir = workspace({ "* Task", "  Met on [2026-11-21 Sat].", "* Next" })
    eq(0, (run(dir, { "append", "Task", "text" })))
    eq({ "* Task", "  Met on [2026-11-21 Sat].", "", "text", "* Next" }, read(dir))
  end)

  it("reads the text from stdin with -", function()
    local dir = workspace(PROJECT)
    eq(0, (run(dir, { "append", "Second", "-" }, "from stdin\n")))
    eq({ "** Second", "from stdin", "", "* Other" }, vim.list_slice(read(dir), 8))
  end)
end)

describe("cli set title", function()
  it("keeps the keyword, priority and tags", function()
    local dir = workspace({ "* TODO [#B] Old title :a:b:", "body" })
    local code, res = json(dir, { "set", "title", "Old title", "New title" })
    eq(0, code)
    eq("title", res.data.field)
    eq("Old title", res.data.old)
    eq("New title", res.data.new)
    local line = read(dir)[1]
    ok(line:match("^%* TODO %[#B%] New title +:a:b:$"), line)
    eq("body", read(dir)[2])
  end)

  it("refuses a title of several lines", function()
    local dir = workspace({ "* Old" })
    local code, res = json(dir, { "set", "title", "Old", "a\nb" })
    eq(2, code)
    eq("bad_value", res.errors[1].code)
    eq({ "* Old" }, read(dir))
  end)
end)

describe("cli add / append / set title in the schema", function()
  it("are write commands, and tools of org mcp", function()
    local schema = require("org.extensions.cli.schema")
    for _, name in ipairs({ "add", "append", "set title" }) do
      eq(true, schema.BY_COMMAND[name].writes)
    end
    -- add takes one --todo, a string
    local input = schema.input_schema(schema.BY_COMMAND.add)
    eq("string", input.properties.todo.type)
    eq({ "parent", "title" }, input.required)
    local names = vim.tbl_map(function(t)
      return t.name
    end, require("org.extensions.cli.mcp").tools(false))
    for _, n in ipairs({ "add", "append", "set_title" }) do
      ok(vim.tbl_contains(names, n), n)
    end
    local ro = vim.tbl_map(function(t)
      return t.name
    end, require("org.extensions.cli.mcp").tools(true))
    eq(false, vim.tbl_contains(ro, "add"))
  end)
end)

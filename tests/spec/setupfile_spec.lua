-- Collection order, cycles and unique settings checked with Emacs Org 9.8.7.
local parser = require("org.parser")
local files = require("org.files")

describe("local SETUPFILE settings", function()
  local dir, cwd
  local function write(name, lines)
    local path = dir .. "/" .. name
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
    return path
  end

  local function parse(lines)
    return parser.parse(lines, dir .. "/tasks.org")
  end

  before_each(function()
    cwd = vim.fn.getcwd()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    files.invalidate()
  end)

  after_each(function()
    vim.fn.chdir(cwd)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf):sub(1, #dir + 1) == dir .. "/" then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    vim.fn.delete(dir, "rf")
    files.invalidate()
  end)

  it("inherits task metadata through quoted paths relative to each setup file", function()
    write("settings/common setup.org", {
      "#+SETUPFILE: nested/tasks.setup",
      "#+FILETAGS: :common:",
      "#+PROPERTY: Flavor+ common",
      "* Heading in the setup file is not included",
    })
    write("settings/nested/tasks.setup", {
      "#+TODO: WAIT(w) | FIN(f)",
      "#+FILETAGS: :nested:",
      "#+PROPERTY: Flavor base",
    })
    local file = parse({
      "#+FILETAGS: :before:",
      '#+SETUPFILE: "settings/common setup.org"',
      "#+FILETAGS: :after:",
      "#+PROPERTY: Flavor+ local",
      "* WAIT Task :own:",
    })
    eq({ "WAIT", "FIN" }, file.settings.todo:names())
    eq(1, #file.headlines)
    eq("WAIT", file.headlines[1].todo)
    eq(5, file.headlines[1].line)
    eq({ "before", "nested", "common", "after", "own" }, file.headlines[1]:get_tags())
    eq("base common local", file.headlines[1]:get_property("Flavor", true))
  end)

  it("inherits all supported keyword settings while retaining the source document", function()
    write("common.setup", {
      "#+TITLE: Shared title",
      "#+CATEGORY: Project",
      "#+ARCHIVE: archive.org::* Finished",
      "#+COLUMNS: %ITEM %TODO %Effort",
      "#+PRIORITIES: A E C",
      "#+TAGS: work(w) home(h)",
      "#+STARTUP: overview hidestars",
      "#+LINK: ticket https://example.test/%s",
      "#+CONSTANTS: pi=3.14",
    })
    local lines = { "#+SETUPFILE: common.setup", "* Task" }
    local file = parse(lines)
    eq(lines, file.lines)
    eq("Shared title", file:title())
    eq("Project", file.headlines[1]:get_category())
    eq("archive.org::* Finished", file.settings.archive)
    eq("%ITEM %TODO %Effort", file.settings.columns)
    eq({ highest = "A", lowest = "E", default = "C" }, file:priorities())
    eq({ { name = "work", key = "w" }, { name = "home", key = "h" } }, file:tag_definitions())
    eq({ overview = true, hidestars = true }, file.settings.startup)
    eq("https://example.test/%s", file.settings.link_abbrevs.ticket)
    eq({ "pi=3.14" }, file.settings.keywords.CONSTANTS)
    local title = file.settings.keyword_entries[2]
    eq({ "TITLE", 1, dir .. "/common.setup", 1 }, { title.key, title.line, title.filename, title.source_line })
  end)

  it("uses the first unique setting, whether it is local or inherited, except CATEGORY", function()
    write("common.setup", {
      "#+CATEGORY: Setup",
      "#+ARCHIVE: setup.org::",
      "#+COLUMNS: %ITEM %TODO",
      "#+PRIORITIES: A E C",
    })
    local local_settings = {
      "#+CATEGORY: Local",
      "#+ARCHIVE: local.org::",
      "#+COLUMNS: %ITEM",
      "#+PRIORITIES: 1 5 2",
    }
    local before = parse(vim.list_extend({ "#+SETUPFILE: common.setup" }, local_settings))
    -- org-element--get-category: the buffer's own last CATEGORY first
    eq("Local", before:category())
    eq("setup.org::", before.settings.archive)
    eq("%ITEM %TODO", before.settings.columns)
    eq({ highest = "A", lowest = "E", default = "C" }, before:priorities())
    local after = parse(vim.list_extend(vim.deepcopy(local_settings), { "#+SETUPFILE: common.setup" }))
    eq("Local", after:category())
    eq("local.org::", after.settings.archive)
    eq("%ITEM", after.settings.columns)
    eq({ highest = "1", lowest = "5", default = "2" }, after:priorities())
  end)

  it("preserves empty first values for unique settings", function()
    local file = parse({ "#+CATEGORY:", "#+CATEGORY: Later", "#+COLUMNS:", "#+COLUMNS: %ITEM" })
    eq("Later", file:category())
    eq("", file.settings.columns)
  end)

  it("takes the last local CATEGORY, else the first inherited one", function()
    write("common.setup", { "#+CATEGORY: Setup", "#+CATEGORY: Setup2" })
    eq("second", parse({ "#+CATEGORY: first", "#+CATEGORY: second", "* H" }):category())
    eq("Setup", parse({ "#+SETUPFILE: common.setup", "* H" }):category())
    eq("mine", parse({ "#+SETUPFILE: common.setup", "#+CATEGORY: mine", "* H" }):category())
  end)

  it("ignores SETUPFILE and settings inside literal blocks in either file", function()
    write("wrong.setup", { "#+TODO: BROKEN | BAD" })
    write("common.setup", {
      "#+begin_src org",
      "#+SETUPFILE: wrong.setup",
      "#+TODO: BROKEN | BAD",
      "#+end_src",
      "#+begin_quote",
      "#+TODO: WAIT | FIN",
      "#+end_quote",
    })
    local file = parse({
      "#+begin_example",
      "#+SETUPFILE: wrong.setup",
      "#+end_example",
      "  #+sEtUpFiLe: common.setup",
      "* WAIT Task",
    })
    eq({ "WAIT", "FIN" }, file.settings.todo:names())
    eq(nil, file.setup_dependencies[dir .. "/wrong.setup"])
  end)

  it("stops recursive cycles but applies repeated noncyclic imports", function()
    write("a.setup", { "#+FILETAGS: :a:", "#+SETUPFILE: b.setup" })
    write("b.setup", { "#+FILETAGS: :b:", "#+SETUPFILE: ./a.setup", "#+SETUPFILE: tasks.org" })
    write("tasks.org", { "#+FILETAGS: :disk-copy-must-not-be-imported:" })
    local file = parse({ "#+FILETAGS: :local:", "#+SETUPFILE: a.setup", "#+SETUPFILE: a.setup" })
    eq({ "local", "a", "b", "a", "b" }, file.settings.filetags)
  end)

  it("recognizes a cycle through a symlink", function()
    local path = write("common.setup", { "#+FILETAGS: :common:", "#+SETUPFILE: alias.setup" })
    assert(vim.uv.fs_symlink(path, dir .. "/alias.setup"))
    eq({ "common" }, parse({ "#+SETUPFILE: common.setup" }).settings.filetags)
  end)

  it("invalidates a skipped cycle when its symlink points at a new file", function()
    local setup = write("common.setup", { "#+FILETAGS: :common:", "#+SETUPFILE: alias.setup" })
    local target = write("target.setup", { "#+FILETAGS: :target:" })
    local alias = dir .. "/alias.setup"
    assert(vim.uv.fs_symlink(setup, alias))
    local main = write("tasks.org", { "#+SETUPFILE: common.setup" })
    eq({ "common" }, files.get(main).settings.filetags)
    assert(vim.uv.fs_unlink(alias))
    assert(vim.uv.fs_symlink(target, alias))
    eq({ "common", "target" }, files.get(main).settings.filetags)
  end)

  it("does not impose the old lint nesting limit", function()
    for i = 1, 12 do
      write(i .. ".setup", { i == 12 and "#+TODO: WAIT | FIN" or ("#+SETUPFILE: " .. (i + 1) .. ".setup") })
    end
    local lines = { "#+SETUPFILE: 1.setup", "* WAIT Task" }
    local file = parse(lines)
    eq("WAIT", file.headlines[1].todo)
    local lint = require("org.lint")
    eq({ "WAIT", "FIN" }, lint.parse(lines, { dir = dir }).todo:names())
    eq(file.settings.todo, lint.parse(lines, { file = file }).todo)
  end)

  it("bounds deeply nested and exponentially repeated imports", function()
    for i = 1, 70 do
      write(i .. ".setup", { "#+FILETAGS: :depth:", "#+SETUPFILE: " .. (i + 1) .. ".setup" })
    end
    eq(64, #parse({ "#+SETUPFILE: 1.setup" }).settings.filetags)
    for i = 1, 20 do
      local next_file = "#+SETUPFILE: repeated" .. (i + 1) .. ".setup"
      write("repeated" .. i .. ".setup", { "#+FILETAGS: :repeated:", next_file, next_file })
    end
    local file = parse({ "#+SETUPFILE: repeated1.setup" })
    ok(#file.settings.filetags <= 256)
    ok(#file.settings.keyword_entries <= 769)
  end)

  it("treats Vim filename expansion and backtick expressions as literal text", function()
    vim.g.org_setup_evaluated = nil
    for _, name in ipairs({ "%", "#", "`printf literal.setup`", "`=execute('let g:org_setup_evaluated=1')`" }) do
      write(name, { "#+FILETAGS: :literal:" })
      eq({ "literal" }, parse({ "#+SETUPFILE: " .. name }).settings.filetags)
    end
    eq(nil, vim.g.org_setup_evaluated)
  end)

  it("expands ~ but not environment variables, like expand-file-name", function()
    local path = write("common.setup", { "#+FILETAGS: :expanded:" })
    local saved_var, saved_home = vim.env.ORG_SETUP_TEST_DIR, vim.env.HOME
    vim.env.ORG_SETUP_TEST_DIR, vim.env.HOME = dir, dir
    local env = parse({
      "#+SETUPFILE: ${ORG_SETUP_TEST_DIR}/common.setup",
      "#+SETUPFILE: $ORG_SETUP_TEST_DIR/common.setup",
    })
    local home = parse({ "#+SETUPFILE: ~/common.setup" })
    vim.env.ORG_SETUP_TEST_DIR, vim.env.HOME = saved_var, saved_home
    eq({}, env.settings.filetags)
    eq({ "expanded" }, home.settings.filetags)
    eq({ "expanded" }, parse({ "#+SETUPFILE: " .. path }).settings.filetags)
  end)

  it("ignores missing files, directories and remote URLs without reading them", function()
    local file = parse({
      "#+SETUPFILE: missing.setup",
      "#+SETUPFILE: .",
      "#+SETUPFILE: https://example.test/config.org",
      "#+SETUPFILE: file:///tmp/config.org",
      "#+SETUPFILE:",
      "* TODO Task",
    })
    eq("TODO", file.headlines[1].todo)
    eq("missing", file.setup_dependencies[dir .. "/missing.setup"])
    eq(2, vim.tbl_count(file.setup_dependencies))
  end)

  it("invalidates a disk document when a nested setup file changes", function()
    write("common.setup", { "#+SETUPFILE: nested.setup" })
    local nested = write("nested.setup", { "#+TODO: WAIT | FIN" })
    local path = write("tasks.org", { "#+SETUPFILE: common.setup", "* WAIT Task" })
    local initial = files.get(path)
    eq(initial, files.get(path))
    eq("WAIT", initial.headlines[1].todo)
    vim.fn.writefile({ "#+TODO: NEXT | FINISHED" }, nested)
    local changed = files.get(path)
    ok(initial ~= changed)
    eq({ "NEXT", "FINISHED" }, changed.settings.todo:names())
    eq(nil, changed.headlines[1].todo)
  end)

  it("invalidates a buffer document when a missing dependency appears or is deleted", function()
    local buf = org_buffer({ "#+SETUPFILE: common.setup", "* WAIT Task" })
    vim.api.nvim_buf_set_name(buf, dir .. "/tasks.org")
    eq(nil, files.get_buffer(buf).headlines[1].todo)
    local path = write("common.setup", { "#+TODO: WAIT | FIN" })
    eq("WAIT", files.get_buffer(buf).headlines[1].todo)
    vim.fn.delete(path)
    eq(nil, files.get_buffer(buf).headlines[1].todo)
  end)

  it("tracks unsaved setup buffers and their unload state without editing the main file", function()
    local path = write("common.setup", { "#+TODO: WAIT | FIN" })
    local main = write("tasks.org", { "#+SETUPFILE: common.setup", "* NEXT Task" })
    eq(nil, files.get(main).headlines[1].todo)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "#+TODO: NEXT | FIN" })
    eq("NEXT", files.get(main).headlines[1].todo)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "#+TODO: WAIT | FIN" })
    eq(nil, files.get(main).headlines[1].todo)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "#+TODO: NEXT | FIN" })
    eq("NEXT", files.get(main).headlines[1].todo)
    vim.api.nvim_buf_delete(buf, { force = true })
    eq(nil, files.get(main).headlines[1].todo)
  end)

  it("refreshes nested dependency paths after a setup file changes", function()
    local setup = write("common.setup", { "#+SETUPFILE: first.setup" })
    write("first.setup", { "#+FILETAGS: :first:" })
    local second = write("second.setup", { "#+FILETAGS: :second:" })
    local path = write("tasks.org", { "#+SETUPFILE: common.setup" })
    eq({ "first" }, files.get(path).settings.filetags)
    vim.fn.writefile({ "#+SETUPFILE: second.setup" }, setup)
    eq({ "second" }, files.get(path).settings.filetags)
    vim.fn.writefile({ "#+FILETAGS: :updated-second:" }, second)
    eq({ "updated-second" }, files.get(path).settings.filetags)
  end)

  it("resolves unnamed buffer setup files against the current directory", function()
    write("one/common.setup", { "#+FILETAGS: :one:" })
    write("two/common.setup", { "#+FILETAGS: :two:" })
    vim.fn.chdir(dir .. "/one")
    local buf = org_buffer({ "#+SETUPFILE: common.setup" })
    eq({ "one" }, files.get_buffer(buf).settings.filetags)
    vim.fn.chdir(dir .. "/two")
    eq({ "two" }, files.get_buffer(buf).settings.filetags)
  end)

  it("uses inherited allowed values at file scope with the same property precedence", function()
    write("common.setup", { '#+PROPERTY: Color_ALL "light blue" green' })
    local file = parse({
      ":PROPERTIES:",
      ":Color_ALL+: red",
      ":END:",
      "#+SETUPFILE: common.setup",
      "* Task",
    })
    eq("red", file:get_property("Color_ALL", false))
    eq('"light blue" green red', file:get_property("Color_ALL", true))
    eq({ "light blue", "green", "red" }, file:get_allowed_values("Color"))
    eq(file.headlines[1]:get_allowed_values("Color"), file:get_allowed_values("Color"))
  end)

  it("uses inherited table constants and ignores constants in literal examples", function()
    write("common.setup", { "#+CONSTANTS: rate=2 base=5" })
    local buf = org_buffer({
      "#+SETUPFILE: common.setup",
      "#+CONSTANTS: rate=3",
      "#+begin_example",
      "#+CONSTANTS: rate=100 base=100",
      "#+end_example",
      "| 2 | | |",
      "#+TBLFM: $2=$rate*$1::$3=$base*$1",
    })
    vim.api.nvim_buf_set_name(buf, dir .. "/tasks.org")
    require("org.table").recalc(buf, 6)
    eq("| 2 | 6 | 10 |", buf_lines(buf)[6])
  end)

  it("lets later STARTUP words override inherited options case insensitively", function()
    write("common.setup", { "#+STARTUP: nologdone showall indent fnanon hideblocks" })
    local file = parse({
      "#+SETUPFILE: common.setup",
      "#+STARTUP: LOGDONE overview noindent fnauto nohideblocks",
    })
    eq({ logdone = true, overview = true, noindent = true, fnauto = true, nohideblocks = true }, file.settings.startup)
    eq("time", require("org.todo").log_setting(file, "done"))
  end)

  it("uses last STARTUP words even when conflicting options are on the same line", function()
    local file = parse({ "#+STARTUP: lognotedone LOGDONE logdrawer nologdrawer showeverything overview" })
    eq({ logdone = true, nologdrawer = true, overview = true }, file.settings.startup)
    eq("time", require("org.todo").log_setting(file, "done"))
  end)

  it("uses inherited preview startup settings and excludes literal examples", function()
    write("common.setup", { "#+STARTUP: LINKPREVIEWS LATEXPREVIEW" })
    local buf = org_buffer({
      "#+SETUPFILE: common.setup",
      "#+begin_example",
      "#+STARTUP: nolinkpreviews nolatexpreview",
      "#+end_example",
    })
    vim.api.nvim_buf_set_name(buf, dir .. "/tasks.org")
    local images = require("org.ui.images")
    local links, latex = images.show_links, images.show_latex
    local seen = {}
    images.show_links = function(b)
      seen.links = b
    end
    images.show_latex = function(b)
      seen.latex = b
    end
    local success, err = pcall(function()
      images.setup_buffer(buf)
      ok(vim.wait(200, function()
        return seen.links ~= nil and seen.latex ~= nil
      end))
      eq({ links = buf, latex = buf }, seen)
    end)
    images.show_links, images.show_latex = links, latex
    if not success then
      error(err)
    end
  end)
end)

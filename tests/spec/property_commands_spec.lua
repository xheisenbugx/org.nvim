local properties = require("org.properties")
local files = require("org.files")
local columns = require("org.columns")
local ui = require("org.ui")
local utils = require("org.utils")

describe("file property commands", function()
  local menu, select
  before_each(function()
    menu, select = ui.menu, utils.select
  end)
  after_each(function()
    ui.menu, utils.select = menu, select
  end)

  it("cycles file drawer values inherited from keyword settings", function()
    local buf = org_buffer({
      ":PROPERTIES:",
      ":Publisher: EMI",
      ":END:",
      '#+PROPERTY: Publisher_ALL "Deutsche Grammophon" Philips EMI',
      "* Task",
    }, { 2, 0 })
    eq("Deutsche Grammophon", properties.next_allowed_value(1))
    eq("Deutsche Grammophon", files.get_buffer(buf).properties.PUBLISHER)
    eq("EMI", properties.next_allowed_value(-1))
  end)

  it("sets a file property through the context menu with allowed values", function()
    local buf = org_buffer({ ":PROPERTIES:", ":Status_ALL: new done", ":Status: new", ":END:", "* Task" }, { 3, 0 })
    ui.menu = function()
      return "s"
    end
    utils.select = function(values)
      eq({ "new", "done" }, values)
      return "done"
    end
    require("org.context").context_action()
    eq("done", files.get_buffer(buf).properties.STATUS)
  end)

  it("deletes from a file drawer through the context menu", function()
    local buf = org_buffer({ ":PROPERTIES:", ":X: file", ":END:", "* Task" }, { 2, 0 })
    ui.menu = function()
      return "d"
    end
    require("org.context").context_action()
    eq({ "* Task" }, buf_lines(buf))
  end)

  it("global deletion includes the file drawer and appended values", function()
    local buf = org_buffer({
      ":PROPERTIES:",
      ":X: file",
      ":X+: extra",
      ":END:",
      "#+PROPERTY: X default",
      "* Task",
      ":PROPERTIES:",
      ":X+: child",
      ":END:",
      "#+begin_example",
      ":PROPERTIES:",
      ":X: literal",
      ":END:",
      "#+end_example",
    })
    eq(2, properties.delete_property_globally(buf, "X"))
    eq({
      "#+PROPERTY: X default",
      "* Task",
      "#+begin_example",
      ":PROPERTIES:",
      ":X: literal",
      ":END:",
      "#+end_example",
    }, buf_lines(buf))
  end)

  it("does not treat a malformed file drawer as a property command target", function()
    local buf = org_buffer({ ":PROPERTIES:", ":X: keep", "body", ":END:", "* Task" }, { 2, 0 })
    eq(nil, properties.at_property_line(buf, 2))
    eq(false, properties.next_allowed_value(1))
  end)

  it("includes file drawer names and values in property completion", function()
    local buf = org_buffer({ ":PROPERTIES:", ":FileOnly: uncommon value", ":END:", "* Task" })
    ok(vim.tbl_contains(properties.known_names(buf), "FILEONLY"))
    ok(vim.tbl_contains(properties.known_values("FileOnly", buf), "uncommon value"))
  end)
end)

describe("compute property at point", function()
  it("updates only the current subtree with a file column format", function()
    local buf = org_buffer({
      "#+COLUMNS: %ITEM %Cost{+} %Effort{:}",
      "* Project",
      ":PROPERTIES:",
      ":Cost: 99",
      ":Effort: 9:00",
      ":END:",
      "** A",
      ":PROPERTIES:",
      ":Cost: 2",
      ":Effort: 0:30",
      ":END:",
      "** B",
      ":PROPERTIES:",
      ":Cost: 3",
      ":Effort: 0:45",
      ":END:",
      "* Other",
      ":PROPERTIES:",
      ":Cost: 88",
      ":END:",
      "** C",
      ":PROPERTIES:",
      ":Cost: 7",
      ":END:",
    }, { 4, 0 })
    ok(properties.compute_property_at_point())
    local h = files.get_buffer(buf).headlines
    eq("5", h[1].properties.COST)
    eq("9:00", h[1].properties.EFFORT)
    eq("88", h[4].properties.COST)
  end)

  it("uses the enclosing COLUMNS scope and first matching summary", function()
    local buf = org_buffer({
      "* Project",
      ":PROPERTIES:",
      ":COLUMNS: %ITEM %Cost{+} %Cost{max}",
      ":Cost: 99",
      ":END:",
      "** A",
      ":PROPERTIES:",
      ":Cost: 20",
      ":END:",
      "*** Leaf",
      ":PROPERTIES:",
      ":Cost: 2",
      ":END:",
      "** B",
      ":PROPERTIES:",
      ":Cost: 3",
      ":END:",
    }, { 8, 0 })
    ok(properties.compute_property_at_point())
    local h = files.get_buffer(buf).headlines
    eq("5", h[1].properties.COST)
    eq("2", h[2].properties.COST)
  end)

  it("uses a file drawer COLUMNS format for the whole document", function()
    local buf = org_buffer({
      ":PROPERTIES:",
      ":COLUMNS: %ITEM %Cost{+}",
      ":Cost: 100",
      ":END:",
      "* Project",
      ":PROPERTIES:",
      ":Cost: 99",
      ":END:",
      "** A",
      ":PROPERTIES:",
      ":Cost: 2",
      ":END:",
      "* Other",
      ":PROPERTIES:",
      ":Cost: 88",
      ":END:",
      "** B",
      ":PROPERTIES:",
      ":Cost: 3",
      ":END:",
    }, { 3, 0 })
    ok(properties.compute_property_at_point())
    local file = files.get_buffer(buf)
    eq("100", file.properties.COST)
    eq("2", file.headlines[1].properties.COST)
    eq("3", file.headlines[3].properties.COST)
  end)

  it("rejects missing or unknown operators without editing the buffer", function()
    for _, fmt in ipairs({ "%ITEM %Cost", "%Cost %Cost{+}", "%Cost{unknown}" }) do
      local lines = {
        "#+COLUMNS: " .. fmt,
        "* Task",
        ":PROPERTIES:",
        ":Cost: 99",
        ":END:",
        "** Child",
        ":PROPERTIES:",
        ":Cost: 2",
        ":END:",
      }
      local buf = org_buffer(lines, { 4, 0 })
      eq(nil, properties.compute_property_at_point())
      eq(lines, buf_lines(buf))
    end
  end)

  it("offers compute in the property menu and action registry", function()
    local buf = org_buffer({
      "#+COLUMNS: %Cost{+}",
      "* Task",
      ":PROPERTIES:",
      ":Cost: 99",
      ":END:",
      "** Child",
      ":PROPERTIES:",
      ":Cost: 2",
      ":END:",
    }, { 4, 0 })
    local old = ui.menu
    ui.menu = function(opts)
      ok(vim.iter(opts.items):any(function(item)
        return item.key == "c"
      end))
      return "c"
    end
    local success, err = pcall(properties.property_action)
    ui.menu = old
    ok(success, err)
    eq("2", files.get_buffer(buf).headlines[1].properties.COST)
    eq("compute_property_at_point", require("org.actions").list.compute_property_at_point[2])
  end)
end)

describe("column scope regressions", function()
  local function widen()
    columns.open()
    vim.api.nvim_feedkeys(vim.keycode(":3<CR>0>"), "xt", false)
    vim.api.nvim_win_close(0, true)
  end

  it("stores format changes back in a file drawer", function()
    local buf = org_buffer({ ":PROPERTIES:", ":COLUMNS: %ITEM", ":END:", "* Task" }, { 4, 0 })
    widen()
    eq("%7ITEM", files.get_buffer(buf).properties.COLUMNS)
    eq(4, #buf_lines(buf))
  end)

  it("leaves literal COLUMNS examples untouched when storing the format", function()
    local buf = org_buffer({
      "#+begin_example",
      "#+COLUMNS: %Wrong",
      "#+end_example",
      "#+COLUMNS: %ITEM",
      "* Task",
    }, { 5, 0 })
    widen()
    eq("#+COLUMNS: %Wrong", buf_lines(buf)[2])
    eq("#+COLUMNS: %7ITEM", buf_lines(buf)[4])
  end)

  it("stores a local override before the SETUPFILE providing the format", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local settings = { "#+COLUMNS: %ITEM" }
    vim.fn.writefile(settings, dir .. "/shared.setup")
    local buf = org_buffer({ "#+SETUPFILE: shared.setup", "* Task" }, { 2, 0 })
    vim.api.nvim_buf_set_name(buf, dir .. "/tasks.org")
    widen()
    local actual, fmt = buf_lines(buf), files.get_buffer(buf).settings.columns
    local shared = vim.fn.readfile(dir .. "/shared.setup")
    vim.fn.delete(dir, "rf")
    eq({ "#+COLUMNS: %7ITEM", "#+SETUPFILE: shared.setup", "* Task" }, actual)
    eq("%7ITEM", fmt)
    eq(settings, shared)
  end)

  it("ignores malformed text before a column specification", function()
    eq({ { prop = "Cost", title = "Cost", summary = "+" } }, columns.parse_format("garbage %Cost{+}"))
  end)

  it("opening columns below a heading does not rewrite unrelated siblings", function()
    local buf = org_buffer({
      "#+COLUMNS: %ITEM %Cost{+}",
      "* Project",
      ":PROPERTIES:",
      ":Cost: 99",
      ":END:",
      "** A",
      ":PROPERTIES:",
      ":Cost: 2",
      ":END:",
      "* Other",
      ":PROPERTIES:",
      ":Cost: 88",
      ":END:",
      "** B",
      ":PROPERTIES:",
      ":Cost: 3",
      ":END:",
    }, { 2, 0 })
    columns.open()
    local output = buf_lines()
    vim.api.nvim_win_close(0, true)
    eq("2", files.get_buffer(buf).headlines[1].properties.COST)
    eq("88", files.get_buffer(buf).headlines[3].properties.COST)
    ok(not table.concat(output, "\n"):find("Other", 1, true))
  end)

  it("prefers the buffer's own COLUMNS line over a SETUPFILE format", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "#+COLUMNS: %ITEM %Shared" }, dir .. "/shared.setup")
    local buf = org_buffer({ "#+SETUPFILE: shared.setup", "#+COLUMNS: %ITEM %Local", "* Task" }, { 3, 0 })
    vim.api.nvim_buf_set_name(buf, dir .. "/tasks.org")
    columns.open()
    local header = buf_lines()[1]
    vim.api.nvim_win_close(0, true)
    widen()
    local actual = buf_lines(buf)
    vim.fn.delete(dir, "rf")
    ok(header:find("Local", 1, true) and not header:find("Shared", 1, true), header)
    eq({ "#+SETUPFILE: shared.setup", "#+COLUMNS: %7ITEM %Local", "* Task" }, actual)
  end)

  it("edits allowed values where the file drawer defines them", function()
    local buf = org_buffer({
      ":PROPERTIES:",
      ":Status_ALL: a b",
      ":END:",
      "#+COLUMNS: %ITEM %Status",
      "* Task",
      ":PROPERTIES:",
      ":Status: a",
      ":END:",
    }, { 5, 0 })
    local input = require("org.utils").input
    require("org.utils").input = function()
      return "a b c"
    end
    columns.open()
    vim.api.nvim_feedkeys(vim.keycode(":3<CR>$a"), "xt", false)
    vim.api.nvim_win_close(0, true)
    require("org.utils").input = input
    eq(":Status_ALL: a b c", buf_lines(buf)[2])
    eq(8, #buf_lines(buf))
  end)

  it("skips an empty COLUMNS keyword instead of crashing", function()
    org_buffer({ "#+COLUMNS:", "#+COLUMNS: %ITEM %Foo", "* TODO h" }, { 3, 0 })
    eq(true, columns.open())
    local header = buf_lines()[1]
    vim.api.nvim_win_close(0, true)
    ok(header:find("Foo", 1, true), header)
  end)

  it("shows the whole file with a count, like C-u in Emacs", function()
    org_buffer({ "#+COLUMNS: %ITEM", "* Project", "** A", "* Other" }, { 2, 0 })
    columns.open({ global = true })
    local output = table.concat(buf_lines(), "\n")
    vim.api.nvim_win_close(0, true)
    ok(output:find("Other", 1, true), output)
  end)
end)

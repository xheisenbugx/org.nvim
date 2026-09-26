-- Regression cases checked against Emacs 30 / Org 9.8.7 with emacs -Q.
local parser = require("org.parser")
local files = require("org.files")
local properties = require("org.properties")
local edit = require("org.edit")

describe("property names containing colons", function()
  it("updates one language-specific property and deletes its appended values", function()
    local buf = org_buffer({
      "* Task",
      ":PROPERTIES:",
      ":header-args:sh: :results output",
      ":header-args:sh+: :exports both",
      ":header-args: :cache yes",
      ":END:",
      "body",
    }, { 1, 0 })
    properties.set_property(nil, "header-args:sh", ":results value")
    eq({
      "* Task",
      ":PROPERTIES:",
      ":header-args:sh: :results value",
      ":header-args:sh+: :exports both",
      ":header-args: :cache yes",
      ":END:",
      "body",
    }, buf_lines(buf))
    eq(":results value :exports both", files.get_buffer(buf).headlines[1]:get_property("header-args:sh"))
    properties.delete_property(nil, "header-args:sh")
    eq({ "* Task", ":PROPERTIES:", ":header-args: :cache yes", ":END:", "body" }, buf_lines(buf))
  end)

  it("reads and edits language-specific file properties without truncating the key", function()
    local buf = org_buffer({
      ":PROPERTIES:",
      ":header-args:sh: :results output",
      ":header-args:sh+: :exports both",
      ":END:",
      "* Task",
    }, { 1, 0 })
    eq(":results output :exports both", files.get_buffer(buf).headlines[1]:get_property("header-args:sh", true))
    properties.set_property(nil, "header-args:sh", ":results value")
    eq(":results value :exports both", files.get_buffer(buf).headlines[1]:get_property("header-args:sh", true))
    properties.delete_property(nil, "header-args:sh")
    eq({ "* Task" }, buf_lines(buf))
  end)

  it("recognizes the full property at point including an empty value", function()
    local buf = org_buffer({ "* Task", ":PROPERTIES:", ":header-args:sh:", ":END:" }, { 3, 0 })
    local name, value = properties.at_property_line(buf, 3)
    eq("header-args:sh", name)
    eq("", value)
    properties.delete_property(nil, name)
    eq({ "* Task" }, buf_lines(buf))
  end)

  it("keeps every appended file property when the base follows an addition", function()
    local file = parser.parse({ ":PROPERTIES:", ":X+: first", ":X: base", ":X+: last", ":END:", "* Task" })
    eq("base first last", file.headlines[1]:get_property("X", true))
  end)
end)

describe("metadata parser boundaries", function()
  it("preserves ordinary text containing a planning keyword when scheduling", function()
    local buf = org_buffer({ "* Task", "NOTE: SCHEDULED: see calendar", "body" }, { 1, 0 })
    eq(nil, files.get_buffer(buf).headlines[1].planning_line)
    edit.set_planning(buf, 1, "scheduled", require("org.date").parse("<2026-09-27 Sun>"))
    eq({ "* Task", "SCHEDULED: <2026-09-27 Sun>", "NOTE: SCHEDULED: see calendar", "body" }, buf_lines(buf))
    edit.set_planning(buf, 1, "scheduled", nil)
    eq({ "* Task", "NOTE: SCHEDULED: see calendar", "body" }, buf_lines(buf))
  end)

  it("does not expose properties from an unterminated drawer", function()
    local file = parser.parse({ "* Task", ":PROPERTIES:", ":ID: phantom", "body", "* Next" })
    eq(nil, file:find_by_id("phantom"))
    eq({}, file.headlines[1].properties)
    eq(nil, file.headlines[1].properties_range)
  end)

  it("does not treat a malformed drawer as editable metadata", function()
    for _, prefix in ipairs({ {}, { "* Task" } }) do
      local lines = vim.list_extend(vim.deepcopy(prefix), { ":PROPERTIES:", ":ID: phantom", "body", ":END:" })
      local buf = org_buffer(lines, { 1, 0 })
      local file = files.get_buffer(buf)
      eq({}, (#prefix > 0 and file.headlines[1] or file).properties)
      edit.set_property(buf, 1, "ID", "real")
      local expected = vim.list_extend(vim.deepcopy(prefix), { ":PROPERTIES:", ":ID:       real", ":END:" })
      vim.list_extend(expected, { ":PROPERTIES:", ":ID: phantom", "body", ":END:" })
      eq(expected, buf_lines(buf))
    end
  end)
end)

describe("quoted allowed property values", function()
  it("cycles whole quoted values without inserting quotation marks", function()
    local buf = org_buffer({
      "* Task",
      ":PROPERTIES:",
      ':Publisher_ALL: "Deutsche Grammophon" Philips EMI',
      ":Publisher: EMI",
      ":END:",
    }, { 4, 0 })
    eq({ "Deutsche Grammophon", "Philips", "EMI" }, files.get_buffer(buf).headlines[1]:get_allowed_values("Publisher"))
    eq("Deutsche Grammophon", properties.next_allowed_value(1))
    eq(":Publisher: Deutsche Grammophon", buf_lines(buf)[4])
    eq("Philips", properties.next_allowed_value(1))
    eq("Deutsche Grammophon", properties.next_allowed_value(-1))
  end)

  it("reads escaped strings, symbols and numbers from inherited allowed values", function()
    local file = parser.parse({
      ":PROPERTIES:",
      ':Choice_ALL: "A \\"quoted\\" value" "C:\\\\path" plain 2 1.5 nil t',
      ":END:",
      "* Task",
    })
    eq(
      { 'A "quoted" value', "C:\\path", "plain", "2", "1.5", "nil", "t" },
      file.headlines[1]:get_allowed_values("Choice")
    )
  end)

  it("does not evaluate Lisp forms in an allowed-values property", function()
    local file = parser.parse({ "* Task", ":PROPERTIES:", ':Choice_ALL: safe (error "must not run")', ":END:" })
    eq({ "safe", "???" }, file.headlines[1]:get_allowed_values("Choice"))
  end)

  it("rejects an unterminated quoted value without changing the property", function()
    local buf = org_buffer({ "* Task", ":PROPERTIES:", ':Choice_ALL: "unfinished', ":Choice: keep", ":END:" }, { 4, 0 })
    eq(nil, files.get_buffer(buf).headlines[1]:get_allowed_values("Choice"))
    properties.next_allowed_value(1)
    eq(":Choice: keep", buf_lines(buf)[4])
  end)
end)

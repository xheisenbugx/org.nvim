local tags = require("org.tags")
local properties = require("org.properties")
local utils = require("org.utils")

describe("tags", function()
  it("parses input", function()
    eq({ "a", "b", "c" }, tags.parse_input(":a:b: c,a"))
  end)
  it("sets, toggles and aligns tags", function()
    local buf = org_buffer({ "* TODO Task", "** Sub  :x:" }, { 1, 0 })
    tags.set_tags(nil, { "work", "home" })
    local l = buf_lines(buf)[1]
    ok(l:match("^%* TODO Task%s+:work:home:$"))
    eq(77, vim.api.nvim_strwidth(l))
    tags.toggle_tag(nil, "work")
    ok(buf_lines(buf)[1]:match("^%* TODO Task%s+:home:$"))
    tags.align_all(buf)
    eq(77, vim.api.nvim_strwidth(buf_lines(buf)[2]))
    tags.set_tags(nil, {})
    eq("* TODO Task", buf_lines(buf)[1])
  end)
  it("offers the defined tags, else the buffer's tags (org-set-tags-command)", function()
    org_buffer({ "#+TAGS: alpha(a) beta", "#+FILETAGS: :ft:", "* H :gamma:" })
    eq({ "alpha", "beta" }, tags.all_tags())
    org_buffer({ "#+FILETAGS: :ft:", "* H :gamma:" })
    eq({ "ft", "gamma" }, tags.all_tags())
  end)
  it("prompts with completion when no fast keys", function()
    local orig = utils.input_complete
    utils.input_complete = function(_, _, default)
      eq("", default)
      return ":x:y:"
    end
    local buf = org_buffer({ "* Task" }, { 1, 0 })
    tags.set_tags()
    utils.input_complete = orig
    ok(buf_lines(buf)[1]:match(":x:y:$"))
  end)
end)

describe("properties", function()
  it("sets effort and properties", function()
    local buf = org_buffer({ "* Task" }, { 1, 0 })
    -- stored as typed and aligned with org-property-format, like Emacs
    properties.set_effort(nil, "90")
    eq({ "* Task", ":PROPERTIES:", ":Effort:   90", ":END:" }, buf_lines(buf))
    properties.set_property(nil, "Owner", "me")
    eq(":Owner:    me", buf_lines(buf)[4])
    properties.delete_property(nil, "Effort")
    eq({ "* Task", ":PROPERTIES:", ":Owner:    me", ":END:" }, buf_lines(buf))
    ok(vim.tbl_contains(properties.known_names(buf), "OWNER"))
  end)
end)

-- Emacs Org 9.8 parity (expectations checked against Emacs in batch mode)
describe("tags: Emacs parity", function()
  local config = require("org.config")
  local search = require("org.agenda.search")
  local files = require("org.files")

  --- Run the fast selection with `keys` (a list of characters).
  local function fast(defs_lines, current, keys_list, opts)
    local buf = org_buffer(defs_lines, { #defs_lines, 0 })
    local i = 0
    local orig_getchar, orig_float = utils.getchar, require("org.ui").float
    utils.getchar = function()
      i = i + 1
      return keys_list[i]
    end
    local shown = {}
    require("org.ui").float = function(lines)
      shown = lines
      local b = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
      return b, vim.api.nvim_open_win(b, false, { relative = "editor", row = 0, col = 0, width = 80, height = 5 })
    end
    local ok_, res = pcall(tags.fast_select, current, files.get_buffer(buf):tag_definitions(), {}, opts)
    utils.getchar, require("org.ui").float = orig_getchar, orig_float
    assert(ok_, res)
    return res, shown
  end

  it("fast selection: automatic keys, table order, exclusive groups", function()
    local res = fast({ "#+TAGS: alpha(a) beta gamma", "* H" }, { "zz" }, { "b", "g", "\r" })
    eq({ "beta", "gamma", "zz" }, res)
    res = fast({ "#+TAGS: alpha(a) beta gamma", "* H" }, { "gamma", "zz" }, { "a", "\r" })
    eq({ "alpha", "gamma", "zz" }, res)
    res = fast({ "#+TAGS: alpha(a) beta gamma @home", "* H" }, {}, { "h", "\r" })
    eq({ "@home" }, res)
    -- taken letters: the first free key of a-z A-Z
    res = fast({ "#+TAGS: alpha(a) bravo(b) beta gamma @alpha", "* H" }, {}, { "c", "d", "\r" })
    eq({ "beta", "@alpha" }, res)
    res = fast({ "#+TAGS: { x(x) y(y) } z(z)", "* H" }, {}, { "x", "y", "z", "\r" })
    eq({ "y", "z" }, res)
    -- `!` turns the exclusivity off
    res = fast({ "#+TAGS: { x(x) y(y) } z(z)", "* H" }, {}, { "x", "!", "y", "\r" })
    eq({ "x", "y" }, res)
  end)

  it("fast selection: C-c exits after one change, SPC clears, q quits unless bound", function()
    eq({ "x" }, (fast({ "#+TAGS: x(x) y(y)", "* H" }, {}, { "\3", "x" })))
    eq({}, (fast({ "#+TAGS: x(x) y(y)", "* H :x:" }, { "x" }, { " ", "\r" })))
    eq(nil, (fast({ "#+TAGS: x(x) y(y) q", "* H" }, {}, { "q" })))
    eq({ "x", "q" }, (fast({ "#+TAGS: x(x) y(y) r q", "* H" }, {}, { "x", "q", "\r" })))
    local res = fast({ "#+TAGS: [ GTD(g) : Control(c) Persp(p) ] other", "* H" }, {}, { "g", "c", "o", "\r" })
    eq({ "GTD", "Control", "other" }, res)
  end)

  it("fast selection: TAB adds or removes one tag", function()
    local orig = utils.input_complete
    local answers = { "new", "x" }
    utils.input_complete = function()
      return table.remove(answers, 1)
    end
    local res = fast({ "#+TAGS: x(x) y(y)", "* H" }, { "x" }, { "\t", "\t", "\r" })
    utils.input_complete = orig
    eq({ "new" }, res)
  end)

  it("fast selection: single-key mode and TODO keys", function()
    local saved = config.opts.fast_tag_selection_single_key
    config.opts.fast_tag_selection_single_key = true
    local ok_, err = pcall(function()
      eq({ "y" }, (fast({ "#+TAGS: x(x) y(y)", "* H" }, {}, { "y" })))
    end)
    config.opts.fast_tag_selection_single_key = saved
    assert(ok_, err)
    local changed
    local res = fast({ "#+TAGS: x(x)", "* H" }, {}, { "t", "x", "\r" }, {
      todo_keys = { { key = "t", name = "TODO" } },
      on_todo = function(kw)
        changed = kw
      end,
    })
    eq("TODO", changed)
    eq({ "x" }, res)
  end)

  it("tag characters follow org-tag-re", function()
    local buf = org_buffer({ "* TODO Short :a-b:" }, { 1, 0 })
    tags.set_tags(nil, { "z" })
    ok(buf_lines(buf)[1]:match("^%* TODO Short :a%-b:%s+:z:$"), buf_lines(buf)[1])
    eq({ "a@b", "x#1", "日本" }, require("org.parser").parse_headline_line("* H :a@b:x#1:日本:").tags)
  end)

  it("a positive tags_column starts the tags at that column", function()
    local saved = config.opts.tags_column
    config.opts.tags_column = 40
    local buf = org_buffer({ "* TODO Short :a:b:" }, { 1, 0 })
    tags.align(buf, 1)
    config.opts.tags_column = saved
    eq(40, (buf_lines(buf)[1]:find(":a:b:", 1, true)) - 1)
  end)

  it("tag groups expand in matches, recursively and with regexps", function()
    local buf = org_buffer({
      "#+TAGS: [ GTD : Control Persp ] { Context : @Home @Work }",
      "#+TAGS: [ Project : {^P@} Sub ] [ Sub : Deep ]",
      "* A :Control:",
      "* B :Persp:",
      "* C :GTD:",
      "* D :@Home:",
      "* E :other:",
      "* F :P@x:",
      "* G :Deep:",
    }, { 3, 0 })
    local file = files.get_buffer(buf)
    local function names(match)
      local pred = search.compile(match)
      local out = {}
      for _, h in ipairs(file.headlines) do
        if pred(h) then
          out[#out + 1] = h.title:match("^%a")
        end
      end
      return table.concat(out, " ")
    end
    eq("A B C", names("GTD"))
    eq("D", names("Context"))
    eq("D E F G", names("-GTD"))
    eq("A B C", names("gtd"))
    eq("F G", names("Project"))
    tags.toggle_groups()
    eq("C", names("GTD"))
    tags.toggle_groups()
    eq("A B C", names("GTD"))
    eq("C", search.compile("GTD", { groups = false })(file.headlines[3]) and "C" or "")
  end)

  it("completion offers the defined tags, or all agenda tags on request", function()
    local tmp = vim.fn.tempname() .. ".org"
    vim.fn.writefile({ "* T :elsewhere:" }, tmp)
    local saved_files = config.opts.agenda_files
    config.opts.agenda_files = { tmp }
    org_buffer({ "* H :here:" })
    eq({ "here" }, tags.all_tags())
    local saved = config.opts.complete_tags_always_offer_all_agenda_tags
    config.opts.complete_tags_always_offer_all_agenda_tags = true
    local all = tags.all_tags()
    config.opts.complete_tags_always_offer_all_agenda_tags = saved
    config.opts.agenda_files = saved_files
    eq({ "elsewhere", "here" }, all)
  end)
end)

describe("properties: Emacs parity", function()
  local files = require("org.files")
  local function hl(buf, n)
    return files.get_buffer(buf).headlines[n or 1]
  end

  it("aligns with property_format and leaves no trailing space", function()
    local buf = org_buffer({ "* X", ":PROPERTIES:", ":Foo: old", ":END:" }, { 1, 0 })
    properties.set_property(nil, "foo", "new")
    eq(":foo:      new", buf_lines(buf)[3])
    properties.set_property(nil, "Empty", "")
    eq(":Empty:", buf_lines(buf)[4])
    properties.set_property(nil, "LONGPROPERTYNAME", "v")
    eq(":LONGPROPERTYNAME: v", buf_lines(buf)[5])
  end)

  it("special properties change the headline", function()
    local buf = org_buffer({ "* TODO X" }, { 1, 0 })
    properties.set_property(nil, "TODO", "DONE")
    eq("* DONE X", buf_lines(buf)[1])
    properties.set_property(nil, "PRIORITY", "A")
    eq("* DONE [#A] X", buf_lines(buf)[1])
    properties.set_property(nil, "SCHEDULED", "<2026-10-01 Thu>")
    eq("SCHEDULED: <2026-10-01 Thu>", buf_lines(buf)[2])
    properties.set_property(nil, "SCHEDULED", "")
    eq({ "* DONE [#A] X" }, buf_lines(buf))
    eq(nil, properties.set_property(nil, "ITEM", "x"))
  end)

  it("TIMESTAMP_IA, BLOCKED and PROP+ through inheritance", function()
    local buf = org_buffer({
      "#+PROPERTY: Var a",
      "#+PROPERTY: Var+ b",
      "* TODO Parent",
      ":PROPERTIES:",
      ":Acc: 1",
      ":END:",
      "** TODO Child <2026-09-01 Tue> [2026-08-01 Sat]",
      ":PROPERTIES:",
      ":Acc+: 2",
      ":END:",
    }, { 7, 0 })
    local child = hl(buf, 2)
    eq("[2026-08-01 Sat]", child:get_property("TIMESTAMP_IA"))
    eq("2", child:get_property("Acc", false))
    eq("1 2", child:get_property("Acc", true))
    eq("a b", child:get_property("Var", true))
    eq("", hl(buf, 1):get_property("BLOCKED"))
    local saved = require("org.config").opts.enforce_todo_dependencies
    require("org.config").opts.enforce_todo_dependencies = true
    eq("t", hl(buf, 1):get_property("BLOCKED"))
    require("org.config").opts.enforce_todo_dependencies = saved
  end)

  it("deleting a property removes its PROP+ lines", function()
    local buf = org_buffer({ "* X", ":PROPERTIES:", ":Foo: a", ":Foo+: b", ":END:", "body" }, { 1, 0 })
    properties.delete_property(nil, "Foo")
    eq({ "* X", "body" }, buf_lines(buf))
  end)

  it("before the first headline: the file-level property drawer", function()
    local buf = org_buffer({ "# comment", "Pre", "* X" }, { 2, 0 })
    properties.set_property(nil, "Foo", "bar")
    eq({ "# comment", ":PROPERTIES:", ":Foo:      bar", ":END:", "Pre", "* X" }, buf_lines(buf))
    properties.set_property(nil, "Foo", "baz")
    eq(":Foo:      baz", buf_lines(buf)[3])
    local saved = require("org.config").opts.use_property_inheritance
    require("org.config").opts.use_property_inheritance = true
    eq("baz", hl(buf):get_property("Foo"))
    require("org.config").opts.use_property_inheritance = saved
    properties.delete_property(nil, "Foo")
    eq({ "# comment", "Pre", "* X" }, buf_lines(buf))
  end)

  it("set_property_and_value, OrgPropertyChanged, effort as typed", function()
    local seen
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "OrgPropertyChanged",
      callback = function(ev)
        seen = ev.data.name .. "=" .. ev.data.value
      end,
    })
    local buf = org_buffer({ "* X" }, { 1, 0 })
    properties.set_property_and_value(nil, "Owner: me")
    vim.api.nvim_del_autocmd(id)
    eq(":Owner:    me", buf_lines(buf)[3])
    eq("Owner=me", seen)
    properties.set_effort(nil, "1h")
    eq(":Effort:   1h", buf_lines(buf)[4])
    eq(nil, properties.set_effort(nil, "foo"))
  end)
end)

describe("priority and tag faces", function()
  it("ui.priority_faces / ui.tag_faces highlight cookies and tags", function()
    local ui = require("org.config").opts.ui
    local saved_p, saved_t = ui.priority_faces, ui.tag_faces
    ui.priority_faces = { A = "ErrorMsg", ["10"] = { fg = "#123456" } }
    ui.tag_faces = { urgent = ":foreground red :weight bold" }
    local ok_, err = pcall(function()
      org_buffer({ "* TODO [#A] Task :urgent:x:", "* [#10] N" })
      require("org.syntax").apply(0)
      require("org.highlights").apply_todo_faces()
      local function group_at(l, c)
        local names = {}
        for _, id in ipairs(vim.fn.synstack(l, c)) do
          names[#names + 1] = vim.fn.synIDattr(id, "name")
        end
        return table.concat(names, " ")
      end
      local line = buf_lines()[1]
      ok(group_at(1, line:find("#A", 1, true)):find("orgPriorityFace_A"), group_at(1, 9))
      ok(group_at(1, line:find("urgent", 1, true)):find("orgTagFace_urgent"), group_at(1, line:find("urgent")))
      ok(not group_at(1, line:find("x:", 1, true)):find("orgTagFace"))
      ok(group_at(2, 4):find("orgPriorityFace_10"), group_at(2, 4))
      eq("#ff0000", string.format("#%06x", vim.api.nvim_get_hl(0, { name = "orgTagFace_urgent" }).fg))
    end)
    ui.priority_faces, ui.tag_faces = saved_p, saved_t
    assert(ok_, err)
  end)
end)

describe("inheritance options", function()
  local config = require("org.config")
  it("use_tag_inheritance as a list or regexp, use_property_inheritance as a regexp", function()
    local buf = org_buffer({ "#+FILETAGS: :ft:", "* P :a:b:", ":PROPERTIES:", ":Foo: 1", ":Bar: 2", ":END:", "** C :c:" })
    local child = require("org.files").get_buffer(buf).headlines[2]
    local saved_t, saved_p = config.opts.use_tag_inheritance, config.opts.use_property_inheritance
    config.opts.use_tag_inheritance = { "b", "ft" }
    local list = child:get_tags()
    config.opts.use_tag_inheritance = "^a$"
    local re = child:get_tags()
    config.opts.use_property_inheritance = "^fo"
    local foo, bar = child:get_property("Foo"), child:get_property("Bar")
    config.opts.use_tag_inheritance, config.opts.use_property_inheritance = saved_t, saved_p
    eq({ "ft", "b", "c" }, list)
    eq({ "a", "c" }, re)
    eq("1", foo)
    eq(nil, bar)
  end)
end)

-- Expected settings checked with org-collect-keywords in Emacs Org 9.8.7.
local parser = require("org.parser")

describe("file settings respect literal blocks", function()
  for _, kind in ipairs({ "src", "example", "export", "comment", "verse" }) do
    it("ignores configuration text in " .. kind .. " blocks", function()
      local file = parser.parse({
        "#+TITLE: Actual title",
        "#+TODO: TODO | DONE",
        "#+begin_" .. kind .. " text",
        "#+TITLE: Example title",
        "#+TODO: BROKEN | FIN",
        "#+ARCHIVE: wrong-archive.org::",
        "#+PROPERTY: header-args :dir /wrong",
        "#+end_" .. kind,
        "* TODO Task",
      })
      eq("Actual title", file:title())
      eq({ "TODO", "DONE" }, file.settings.todo:names())
      eq(nil, file.settings.archive)
      eq({}, file.settings.properties)
    end)
  end

  it("continues collecting settings after a closed block and inside quote blocks", function()
    local file = parser.parse({
      "  #+BeGiN_ExAmPlE",
      "  #+TITLE: Example",
      "  #+EnD_ExAmPlE",
      "#+TITLE: Actual",
      "#+begin_quote",
      "#+TODO: NEXT | FIN",
      "#+end_quote",
    })
    eq("Actual", file:title())
    eq({ "NEXT", "FIN" }, file.settings.todo:names())
  end)

  it("does not hide settings after an unmatched block opening or across a headline", function()
    for _, ending in ipairs({ {}, { "#+end_src" } }) do
      local lines = { "#+begin_src text", "#+TODO: NEXT | FIN", "* NEXT Task" }
      vim.list_extend(lines, ending)
      eq({ "NEXT", "FIN" }, parser.parse(lines).settings.todo:names())
    end
  end)
end)

describe("single keyword TODO sequences", function()
  it("treats the only keyword as done when there is no separator", function()
    local file = parser.parse({ "#+TODO: FIN", "* FIN Task" })
    eq({ "FIN" }, file.settings.todo:done_names())
    eq({}, file.settings.todo:todo_names())
    ok(file.headlines[1]:is_done())
  end)

  it("keeps an explicitly separated open keyword open", function()
    local file = parser.parse({ "#+TODO: WAIT |", "* WAIT Task" })
    eq({}, file.settings.todo:done_names())
    ok(file.headlines[1]:is_todo())
  end)
end)

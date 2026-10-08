local element = require("org.export.element")
local export = require("org.export")
local ox = require("org.export.ox")

describe("export follow-up regressions", function()
  with_config({ babel = vim.tbl_extend("force", require("org.config").opts.babel, { evaluate_on_export = false }) })

  it("removes exactly one protective comma, including nested escapes", function()
    eq(
      { "* heading", ",* literal", ",,#+keyword", "  ,#+keyword", "\t,* literal", ",ordinary", ", * spaced" },
      element.unescape({
        ",* heading",
        ",,* literal",
        ",,,#+keyword",
        "  ,,#+keyword",
        "\t,,* literal",
        ",ordinary",
        ", * spaced",
      })
    )
  end)

  it("unescapes source, example and raw export block bodies consistently", function()
    for _, block in ipairs({ "src text", "example", "export html" }) do
      local kind = block:match("^%S+")
      local html = export.to_string("html", {
        lines = { "#+begin_" .. block, ",,* literal", ",,#+literal", "#+end_" .. kind },
        body_only = true,
      })
      ok(html:find(",* literal\n,#+literal", 1, true), html)
      ok(not html:find(",,* literal", 1, true), html)
    end
  end)
end)

describe("export SETUPFILE collection", function()
  with_config({ babel = vim.tbl_extend("force", require("org.config").opts.babel, { evaluate_on_export = false }) })
  local dir
  local function write(name, lines)
    local path = dir .. "/" .. name
    vim.fn.writefile(lines, path)
    return path
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end)

  after_each(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf):sub(1, #dir + 1) == dir .. "/" then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    vim.fn.delete(dir, "rf")
  end)

  it("reads literal filenames without evaluating Vim expansion syntax", function()
    for _, name in ipairs({ "#", "%", "`=1+1`" }) do
      write(name, { "#+HTML_HEAD: literal " .. name })
      local keywords = ox.collect_keywords({ "#+SETUPFILE: " .. name }, dir)
      eq({ "literal " .. name }, keywords.HTML_HEAD)
    end
  end)

  it("includes keywords in greater blocks and ignores only matched literal blocks", function()
    local lines, expected = {}, {}
    for _, kind in ipairs({ "quote", "center", "special", "src", "example", "export", "comment", "verse" }) do
      vim.list_extend(lines, { "#+begin_" .. kind, "#+HTML_HEAD: " .. kind, "#+end_" .. kind })
      if kind == "quote" or kind == "center" or kind == "special" then
        expected[#expected + 1] = kind
      end
    end
    vim.list_extend(lines, { "#+begin_example", "* Headline", "#+HTML_HEAD: after unmatched block" })
    expected[#expected + 1] = "after unmatched block"
    eq(expected, ox.collect_keywords(lines, dir).HTML_HEAD)
  end)

  it("stops source-file cycles while allowing repeated noncyclic imports", function()
    write("a.setup", { "#+TITLE: Imported", "#+SETUPFILE: main.org" })
    local lines = { "#+TITLE: Root", "#+SETUPFILE: a.setup", "#+SETUPFILE: a.setup" }
    local filename = write("main.org", lines)
    local _, info = ox.export_as("html", lines, { filename = filename })
    eq("Root Imported Imported", element.interpret(info.title))
    eq({ "Root", "Imported", "Imported" }, require("org.export.publish").find_property(filename, "TITLE"))
  end)

  it("loads export macros through more than ten setup files", function()
    for i = 1, 12 do
      write(i .. ".setup", { i == 12 and "#+MACRO: imported found" or ("#+SETUPFILE: " .. (i + 1) .. ".setup") })
    end
    local html = export.to_string("html", {
      lines = { "#+SETUPFILE: 1.setup", "{{{imported}}}" },
      filename = dir .. "/main.org",
      body_only = true,
    })
    ok(html:find("found", 1, true), html)
  end)

  it("uses unsaved setup-buffer changes when collecting export settings", function()
    local path = write("common.setup", { "#+HTML_HEAD: saved" })
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "#+HTML_HEAD: unsaved" })
    eq({ "unsaved" }, ox.collect_keywords({ "#+SETUPFILE: common.setup" }, dir).HTML_HEAD)
  end)

  it("resolves INCLUDE paths without evaluating Vim expressions", function()
    vim.g.org_include_evaluated = nil
    local name = "`=execute('let g:org_include_evaluated=1')`"
    write(name, { "included text" })
    local html = export.to_string("html", {
      lines = { '#+INCLUDE: "' .. name .. '"' },
      filename = dir .. "/main.org",
      body_only = true,
    })
    eq(nil, vim.g.org_include_evaluated)
    ok(html:find("included text", 1, true), html)
  end)

  it("treats a relative setup name with a colon as a local file", function()
    write("a:b.setup", { "#+TITLE: Colon" })
    eq({ "Colon" }, ox.collect_keywords({ "#+SETUPFILE: a:b.setup" }, dir).TITLE)
  end)

  it("ignores remote setup URLs without attempting to fetch them", function()
    eq(
      { TITLE = { "Local" } },
      ox.collect_keywords({ "#+SETUPFILE: https://example.test/setup.org", "#+TITLE: Local" }, dir)
    )
  end)
end)

describe("export headline tags", function()
  it("takes non-ASCII tags as tags, not title", function()
    local html = export.to_string("html", {
      lines = { "#+OPTIONS: tags:nil", "* Hello :café:" },
      body_only = true,
    })
    ok(html:find("Hello", 1, true), html)
    ok(not html:find("café", 1, true), html)
  end)
end)

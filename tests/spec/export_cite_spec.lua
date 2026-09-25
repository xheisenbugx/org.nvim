-- Citations in export (oc.el, oc-basic, oc-natbib, oc-biblatex, oc-bibtex).
-- Expected outputs under tests/fixtures/export/cite/ were produced by
-- Emacs Org 9.8.10 (body-only export).

local ox = require("org.export.ox")
local cite = require("org.export.cite")

require("org.config").opts.babel.evaluate_on_export = false

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local dir = root .. "/fixtures/export/cite/"

local function read(name)
  return table.concat(vim.fn.readfile(dir .. name), "\n")
end

local function strip(s)
  return (s:gsub("\n+$", ""))
end

local function export(name, backend, body_only)
  local file = dir .. name
  return ox.export_as(backend, vim.fn.readfile(file), { body_only = body_only ~= false, filename = file })
end

local function export_lines(lines, backend, opts)
  opts = opts or {}
  opts = vim.tbl_extend("force", { body_only = true, filename = dir .. "inline.org" }, opts)
  return ox.export_as(backend, lines, opts)
end

local function check(name, backend, ext)
  eq(strip(export(name .. ".org", backend)), strip(read(name .. "." .. ext)))
end

describe("citations export parity with Emacs", function()
  it("basic processor, all styles (html)", function()
    check("c1", "html", "html")
  end)
  it("basic processor, all styles (latex)", function()
    check("c1", "latex", "tex")
  end)
  it("basic plain bibliography and note styles", function()
    check("c2", "html", "html")
    check("c2", "latex", "tex")
  end)
  it("basic numeric bibliography", function()
    check("c3", "html", "html")
    check("c3", "latex", "tex")
  end)
  it("note placement with en-us rules", function()
    check("c4", "html", "html")
  end)
  it("CSL-JSON bibliography, fr rules and citations in footnotes", function()
    check("c8", "html", "html")
    check("c8", "latex", "tex")
  end)
  it("natbib processor", function()
    check("c5", "latex", "tex")
  end)
  it("biblatex processor", function()
    check("c6", "latex", "tex")
    check("c9", "latex", "tex")
  end)
  it("bibtex processor", function()
    check("c7", "latex", "tex")
  end)
  it("markdown and ascii back-ends", function()
    check("c2", "md", "md")
    check("c1", "ascii", "txt")
  end)
end)

describe("citations export finalizers", function()
  it("natbib loads the package", function()
    local out = export("c5.org", "latex", false)
    ok(out:find("\\usepackage{natbib}\n\\begin{document}", 1, true) ~= nil, out)
  end)
  it("biblatex adds the package and resources", function()
    local out = export("c6.org", "latex", false)
    ok(out:find("\\usepackage[style=authoryear]{biblatex}\n\\addbibresource{refs.bib}\n", 1, true) ~= nil, out)
  end)
  it("biblatex merges options into an existing package", function()
    local out = export("c9.org", "latex", false)
    ok(
      out:find(
        "\\usepackage[backend=biber,bibstyle=numeric,citestyle=authoryear]{biblatex}\n"
          .. "\\addbibresource{refs.bib}\n\\addbibresource[location=remote]{https://example.com/remote.bib}\n",
        1,
        true
      ) ~= nil,
      out
    )
  end)
  it("basic has no finalizer", function()
    local out = export("c1.org", "latex", false)
    ok(out:find("natbib", 1, true) == nil and out:find("biblatex", 1, true) == nil)
  end)
end)

describe("citations export options", function()
  it("unknown processor is an error", function()
    local okp, err = pcall(export_lines, { "#+cite_export: nope", "", "A [cite:@x]." }, "html")
    eq(okp, false)
    ok(tostring(err):find("Unknown processor nope", 1, true) ~= nil, tostring(err))
  end)
  it("processor chosen per back-end from export.cite.export_processors", function()
    local c = require("org.config").opts
    c.export.cite = c.export.cite or {}
    local saved = c.export.cite.export_processors
    c.export.cite.export_processors = { latex = { "natbib" }, t = { "basic" } }
    local okp, res = pcall(function()
      local lines = { "#+bibliography: refs.bib", "", "A [cite:@doe2020]." }
      return { export_lines(lines, "latex"), export_lines(lines, "html") }
    end)
    c.export.cite.export_processors = saved
    ok(okp, tostring(res))
    eq(strip(res[1]), "A \\citep{doe2020}.")
    eq(strip(res[2]), "<p>\nA (Doe, John and Smith, Jane, 2020).\n</p>")
  end)
end)

describe("citations helpers", function()
  it("reads processor declarations", function()
    eq(cite.read_processor_declaration("basic"), { "basic", nil, nil })
    eq(cite.read_processor_declaration('biblatex "a b" nil'), { "biblatex", "a b", nil })
    eq(cite.read_processor_declaration("csl chicago author-date"), { "csl", "chicago", "author-date" })
  end)
  it("parses property lists", function()
    eq(cite.parse_as_plist(':keyword abc,xyz :title "Primary Sources"'), {
      { keyword = ":keyword" },
      "abc,xyz",
      { keyword = ":title" },
      "Primary Sources",
    })
  end)
  it("parses BibTeX strings, concatenation and months", function()
    local e = cite.parse_bibtex([[@string{p = "Press"}
@book{k1, title = "A " # {B {C}} # p, year = 2001, month = feb,
  author = {Doe,   Jane}}]]).k1
    local function field(f)
      for _, kv in ipairs(e) do
        if kv[1] == f then
          return kv[2]
        end
      end
    end
    eq(field("id"), "k1")
    eq(field("type"), "book")
    eq(field("title"), "A B {C}Press")
    eq(field("year"), "2001")
    eq(field("month"), "February")
    eq(field("author"), "Doe, Jane")
  end)
  it("numbers to disambiguation suffixes", function()
    eq(cite.basic.number_to_suffix(0), "a")
    eq(cite.basic.number_to_suffix(25), "z")
    eq(cite.basic.number_to_suffix(26), "aa")
  end)
end)

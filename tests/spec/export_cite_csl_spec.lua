-- The csl citation processor (oc-csl.el with a Lua port of citeproc-el).
-- Expected outputs under tests/fixtures/export/cite/csl/ were produced by
-- Emacs Org 9.8.10 with citeproc-el 0.9.4 (body-only export).

local ox = require("org.export.ox")

require("org.config").opts.babel.evaluate_on_export = false

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local dir = root .. "/fixtures/export/cite/csl/"

local function read(name)
  return table.concat(vim.fn.readfile(dir .. name), "\n")
end

local function norm(s)
  return (s:gsub("\\label{sec:org%x+}", "\\label{sec:ID}"):gsub("\n+$", ""))
end

local function export(name, backend, body_only)
  local file = dir .. name
  return ox.export_as(backend, vim.fn.readfile(file), { body_only = body_only ~= false, filename = file })
end

local function check(name, backend, ext)
  eq(norm(read(name .. "." .. ext)), norm(export(name .. ".org", backend)))
end

describe("csl citation processor, parity with Emacs", function()
  local saved
  before_each(function()
    local e = require("org.config").opts.export
    saved = { e.with_toc, e.with_section_numbers }
    e.with_toc, e.with_section_numbers = false, false
  end)
  after_each(function()
    local e = require("org.config").opts.export
    e.with_toc, e.with_section_numbers = saved[1], saved[2]
  end)
  it("Chicago author-date: citation styles, locators, disambiguation (html)", function()
    check("s1", "html", "html")
  end)
  it("Chicago author-date (latex, ascii, md)", function()
    check("s1", "latex", "tex")
    check("s1", "ascii", "txt")
    check("s1", "md", "md")
  end)
  it("note style: footnotes, ibid and subsequent positions", function()
    check("s2", "html", "html")
    check("s2", "latex", "tex")
    check("s2", "ascii", "txt")
    check("s2", "md", "md")
  end)
  it("numeric style: collapsed ranges, sub-bibliographies, second-field-align", function()
    check("s3", "html", "html")
    check("s3", "latex", "tex")
    check("s3", "ascii", "txt")
    check("s3", "md", "md")
  end)
  it("adds the CSL LaTeX preamble", function()
    local out = export("s3.org", "latex", false)
    ok(out:find(read("s3.preamble.tex"), 1, true) ~= nil, out)
  end)
  it("adds the CSS for hanging indents and label widths to the HTML head", function()
    local out = export("s1.org", "html", false)
    ok(out:find(read("s1.head.html"), 1, true) ~= nil)
    out = export("s3.org", "html", false)
    ok(
      out:find(
        "<style>.csl-left-margin{float: left; padding-right: 0em;}\n .csl-right-inline{margin: 0 0 0 1em;}</style>",
        1,
        true
      ) ~= nil
    )
  end)
end)

describe("csl processor options", function()
  it("reports a missing style file", function()
    local file = dir .. "s1.org"
    local okp, err = pcall(ox.export_as, "html", { "#+cite_export: csl nope.csl", "#+bibliography: refs.bib", "", "[cite:@knuth1984]" }, { body_only = true, filename = file })
    eq(false, okp)
    ok(tostring(err):find('CSL style file not found: "nope.csl"', 1, true) ~= nil, tostring(err))
  end)
  it("finds styles in export.cite.csl_styles_dir and can drop citation links", function()
    local c = require("org.config").opts.export.cite
    c.csl_styles_dir = dir
    c.csl_link_cites = false
    local okp, out = pcall(ox.export_as, "html", {
      "#+cite_export: csl numeric.csl",
      "#+bibliography: " .. dir .. "refs.bib",
      "",
      "A [cite:@knuth1984].",
      "",
      "#+print_bibliography:",
    }, { body_only = true, filename = "/tmp/elsewhere/x.org" })
    c.csl_styles_dir, c.csl_link_cites = nil, nil
    assert(okp, out)
    ok(out:find("A [1].", 1, true) ~= nil, out)
  end)
  it("reads locales from export.cite.csl_locales_dir", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local src = root .. "/../etc/csl/locales-en-US.xml"
    local lines = vim.fn.readfile(src)
    for i, l in ipairs(lines) do
      lines[i] = l:gsub('<term name="and">and</term>', '<term name="and">und</term>')
    end
    vim.fn.writefile(lines, tmp .. "/locales-en-US.xml")
    local c = require("org.config").opts.export.cite
    c.csl_locales_dir = tmp
    local okp, out = pcall(export, "s1.org", "ascii")
    c.csl_locales_dir = nil
    assert(okp, out)
    ok(out:find("Lamport und Doe", 1, true) ~= nil, out)
  end)
  it("keeps title case with csl_bibtex_titles_to_sentence_case = false", function()
    local c = require("org.config").opts.export.cite
    c.csl_bibtex_titles_to_sentence_case = false
    local okp, out = pcall(export, "s3.org", "ascii")
    c.csl_bibtex_titles_to_sentence_case = nil
    assert(okp, out)
    ok(out:find("“The METAFONT Book,”", 1, true) ~= nil, out)
  end)
  it("uses csl_html_hanging_indent and the LaTeX lengths", function()
    local c = require("org.config").opts.export.cite
    c.csl_html_hanging_indent = "2em"
    c.csl_latex_hanging_indent = "3em"
    c.csl_latex_label_separator = "1em"
    c.csl_latex_label_width_per_char = "0.5em"
    local ok1, html = pcall(export, "s1.org", "html", false)
    local ok2, tex = pcall(export, "s3.org", "latex", false)
    c.csl_html_hanging_indent, c.csl_latex_hanging_indent = nil, nil
    c.csl_latex_label_separator, c.csl_latex_label_width_per_char = nil, nil
    assert(ok1 and ok2, tostring(html) .. tostring(tex))
    ok(html:find(".csl-entry{text-indent: -2em; margin-left: 2em;}", 1, true) ~= nil)
    ok(tex:find("\\setlength{\\cslhangindent}{3em}", 1, true) ~= nil)
    ok(tex:find("\\setlength{\\csllabelsep}{1em}", 1, true) ~= nil)
    ok(tex:find("\\setlength{\\csllabelwidth}{0.5em * 3}", 1, true) ~= nil, tex)
  end)
end)

describe("csl engine", function()
  local R = require("org.export.csl.regex")
  it("matches Emacs regexps", function()
    eq(1, (R.search("\\(b+\\)", "abbc")))
    eq("bb", R.match("\\(b+\\)", "abbc")[1])
    eq({ "a", "b", "", "c" }, R.split("a b  c", " ", false))
    eq("x-y-z", R.replace("[ ,]+", "-", "x, y z"))
    ok(R.test("\\bAND\\b", "Smith and Jones"))
    ok(not R.test("\\bAND\\b", "Smith and Jones", { case_fold = false }))
  end)
  it("converts BibTeX names and markup like citeproc-el", function()
    local B = require("org.export.csl.bib")
    eq({ { { "family", "Beethoven" }, { "non-dropping-particle", "van" }, { "given", "Ludwig" } } }, B.to_csl_names("Ludwig van Beethoven"))
    eq('The <span class="nocase">TeX</span>book', B.bt_to_csl("The {TeX}book", true))
    eq("Für", B.bt_to_csl('F{\\"u}r'))
  end)
end)

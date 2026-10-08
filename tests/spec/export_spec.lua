local export = require("org.export")
local ox = require("org.export.ox")
local element = require("org.export.element")
local config = require("org.config")
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local sample = root .. "/fixtures/export/sample.org"
local lines = vim.fn.readfile(sample)

local function has(s, sub)
  ok(s:find(sub, 1, true), "missing: " .. sub .. "\n---\n" .. s)
end
local function hasnt(s, sub)
  ok(not s:find(sub, 1, true), "unexpected: " .. sub .. "\n---\n" .. s)
end

local function body(fmt, l, opts)
  opts = opts or {}
  return export.to_string(fmt, vim.tbl_extend("force", { lines = l, body_only = true }, opts))
end

describe("export", function()
  before_each(function()
    config.opts.babel.evaluate_on_export = false
  end)

  describe("element parser", function()
    it("parses objects like org-element", function()
      local nodes = element.parse_secondary("a *b* /c/ =d= [[x][y]] [fn:1] <2026-01-01 Thu> \\alpha $x$", "paragraph")
      local types = {}
      for _, n in ipairs(nodes) do
        if n.type ~= "plain-text" then
          types[#types + 1] = n.type
        end
      end
      eq({ "bold", "italic", "verbatim", "link", "footnote-reference", "timestamp", "entity", "latex-fragment" }, types)
    end)
    it("does not treat mid-word markers as emphasis", function()
      local nodes = element.parse_secondary("a*b*c 2*3*4", "paragraph")
      eq(1, #nodes)
    end)
    it("keeps blank lines as post-blank", function()
      local d = element.parse({ "para", "", "", "- item" }, {})
      local sec = d.contents[1]
      eq("paragraph", sec.contents[1].type)
      eq(2, sec.contents[1].post_blank)
      eq("plain-list", sec.contents[2].type)
    end)
  end)

  describe("html", function()
    local html = export.to_string("html", { lines = lines, filename = sample })
    it("has the xhtml-strict document structure", function()
      has(html, '<?xml version="1.0" encoding="utf-8"?>')
      has(html, '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"')
      has(html, '<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">')
      has(html, '<h1 class="title">Sample Document</h1>')
      has(html, 'id="table-of-contents"')
      has(html, '<span class="section-number-2">1.</span>')
      has(html, '<div id="postamble" class="status">')
      has(html, '<p class="author">Author: Jane Doe</p>')
      has(html, '<p class="date">Date: 2026-09-23</p>')
      has(html, '<meta name="generator" content="Org Mode" />')
    end)
    it("renders inline markup", function()
      has(html, "<b>bold</b>")
      has(html, "<i>italic</i>")
      has(html, "<del>strike</del>")
      has(html, "<code>verb</code>")
      has(html, '<a href="https://orgmode.org">Org</a>')
      has(html, '<a href="https://neovim.io">https://neovim.io</a>')
      has(html, "Hello, World!")
      has(html, "&alpha;")
      has(html, "H<sub>2O</sub>")
      has(html, "&ndash;")
      has(html, "&hellip;")
      has(html, "\\(a^2 + b^2\\)")
    end)
    it("renders structures", function()
      has(html, '<span class="todo TODO">TODO</span>')
      has(html, '<li class="on"><code>[X]</code> item two')
      has(html, '<ol class="org-ol">')
      has(html, "<dt>term</dt><dd>description</dd>")
      has(html, "<thead>")
      has(html, '<td class="org-right">22</td>')
      has(html, '<caption class="t-above"><span class="table-number">Table 1:</span> Numbers</caption>')
      has(html, 'class="src src-python"')
      has(html, "<blockquote>")
      has(html, '<a href="#first">the first</a>')
      has(html, "<hr />")
      has(html, '<pre class="example">\nfixed width\n</pre>')
      has(html, '<div id="footnotes">')
      has(html, "The footnote text.")
      has(html, "Deep heading")
      has(html, "MathJax")
    end)
    it("gives a src block without a language the class src-nil", function()
      has(body("html", { "#+begin_src", "x", "#+end_src" }), '<pre class="src src-nil"><code>x')
    end)
    it("inlines a remote image whose URL has a query string", function()
      -- org-html-inline-image-rules are unanchored, case-insensitive regexps
      local l = { "[[https://img.shields.io/badge/b.SVG?style=flat]]", "", "[[https://x.org/][https://x.org/a.png?s=1]]" }
      local h = body("html", l)
      has(h, '<img src="https://img.shields.io/badge/b.SVG?style=flat"')
      has(h, '<a href="https://x.org/"><img src="https://x.org/a.png?s=1"')
      -- ox-md uses the HTML rules
      has(body("md", l), "![img](https://img.shields.io/badge/b.SVG?style=flat)")
      -- the LaTeX rules are anchored at the end of the path
      has(body("latex", l), "\\url{https://img.shields.io/badge/b.SVG?style=flat}")
    end)
    it("excludes noexport and COMMENT subtrees", function()
      hasnt(html, "secret")
      hasnt(html, "hidden comment")
      hasnt(html, "SCHEDULED")
    end)
  end)

  describe("markdown (ox-md)", function()
    local md = body("md", lines, { filename = sample })
    it("writes Emacs ox-md markdown", function()
      has(md, "# TODO First section")
      has(md, "**bold**")
      has(md, "*italic*")
      has(md, "`verb`")
      has(md, "[Org](https://orgmode.org)")
      has(md, "-   [X] item two")
      has(md, "<table ")
      has(md, '    print("hi")')
      has(md, "> Quoted **text**.")
      has(md, '<sup><a id="fn.1" href="#fnr.1">1</a></sup> The footnote text.')
      hasnt(md, "secret")
    end)
  end)

  describe("gfm", function()
    local md = export.to_string("gfm", { lines = lines, filename = sample })
    it("writes GitHub flavoured markdown", function()
      has(md, "# Sample Document")
      has(md, "## TODO First section")
      has(md, "- [x] item two")
      has(md, "- [ ] item three")
      has(md, "| Name | Qty |")
      has(md, "|---|---|")
      has(md, "```python")
      has(md, "> Quoted **text**.")
      has(md, "[^1]: The footnote text.")
      has(md, "[the first](#first)")
      hasnt(md, "secret")
    end)
    it("writes code spans with backticks as valid CommonMark", function()
      -- like ox-md (a space inside when a backtick is at an edge), with a
      -- fence longer than any run of backticks in the code
      eq("``` `` ``` and `` ` `` and ``a`b`` and ```x``y```\n", body("gfm", { "=``= and ~`~ and =a`b= and =x``y=" }))
    end)
    it("links headings with GitHub's ids, from the text GitHub renders", function()
      local out = body("gfm", {
        "#+OPTIONS: toc:t tags:t",
        "* Install [[https://neovim.io][Neovim]] first",
        "* TODO Ça \\alpha /it/ ~co_de~ — x 🎬 :tag1:t2:",
        "* Install Neovim first",
      })
      has(out, "- [Install Neovim first](#install-neovim-first)\n")
      has(out, "(#todo-ça-α-it-co_de--x-tag1-t2)")
      -- GitHub numbers a repeated id itself
      has(out, "- [Install Neovim first](#install-neovim-first-1)")
      hasnt(out, '<a id="install-neovim-first"></a>')
    end)
  end)

  describe("latex", function()
    local tex = export.to_string("latex", { lines = lines, filename = sample })
    it("renders latex like ox-latex", function()
      has(tex, "\\documentclass[11pt]{article}")
      has(tex, "\\section{{\\bfseries\\sffamily TODO} First section")
      has(tex, "\\textbf{bold}")
      has(tex, "\\begin{itemize}")
      has(tex, "\\begin{tabular}{lr}")
      has(tex, "\\caption{Numbers}")
      has(tex, "\\footnote{The footnote text.}")
      has(tex, "\\begin{verbatim}")
      has(tex, "\\hypersetup{")
      has(tex, " pdfauthor={Jane Doe},")
      has(tex, "\\label{sec:org")
    end)
    it("wraps math entities of TITLE, AUTHOR and DATE in \\(...\\)", function()
      local out = export.to_string("latex", { lines = { "#+TITLE: \\alpha", "#+AUTHOR: x \\beta", "#+DATE: \\gamma" } })
      has(out, "\\title{\\(\\alpha\\)}")
      has(out, "\\author{x \\(\\beta\\)}")
      has(out, "\\date{\\(\\gamma\\)}")
      has(out, " pdfauthor={x \\(\\beta\\)},")
      has(out, " pdftitle={\\(\\alpha\\)},")
    end)
    it("sets enumi for a counter in an unordered list", function()
      -- ox-latex: (nth (1- 0) '("i" ...)) is "i"
      has(body("latex", { "- [@5] five" }), "\\begin{itemize}\n\\setcounter{enumi}{4}\n\\item five")
      has(body("latex", { "1. a", "   - [@3] b" }), "\\setcounter{enumi}{2}\n\\item b")
    end)
  end)

  describe("files", function()
    it("writes html next to the source and exports a subtree", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local buf = org_buffer(lines)
      vim.api.nvim_buf_set_name(buf, dir .. "/doc.org")
      local out = export.export("html", { bufnr = buf })
      eq(require("org.utils").realpath(dir) .. "/doc.html", require("org.utils").realpath(out))
      ok(vim.fn.filereadable(out) == 1)
      local sub_line
      for i, l in ipairs(lines) do
        if l == "* Second section" then
          sub_line = i
        end
      end
      -- the link to #first points outside the subtree: mark it like Emacs
      local md =
        export.to_string("gfm", { lines = lines, subtree_line = sub_line, ext = { with_broken_links = "mark" } })
      has(md, "# Second section")
      hasnt(md, "First section")
      local md_body = export.to_string("gfm", { lines = lines, body_only = true })
      hasnt(md_body, "# Sample Document")
      vim.bo[buf].modified = false
    end)
    it("uses EXPORT_FILE_NAME for the output file", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local buf = org_buffer({ "#+EXPORT_FILE_NAME: other", "text" })
      vim.api.nvim_buf_set_name(buf, dir .. "/doc.org")
      local out = export.export("gfm", { bufnr = buf })
      eq("other.md", vim.fn.fnamemodify(out, ":t"))
      vim.bo[buf].modified = false
    end)
  end)

  describe("pandoc", function()
    it("exports docx and rst via pandoc when available", function()
      if vim.fn.executable("pandoc") == 0 then
        return
      end
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local buf = org_buffer({ "#+TITLE: P", "* Head", "text", "* Hidden :noexport:", "zzz" })
      vim.api.nvim_buf_set_name(buf, dir .. "/p.org")
      local out = export.export("docx", { bufnr = buf })
      ok(out and vim.fn.filereadable(out) == 1)
      local rst = export.export("rst", { bufnr = buf })
      local content = table.concat(vim.fn.readfile(rst), "\n")
      has(content, "Head")
      hasnt(content, "zzz")
      vim.bo[buf].modified = false
    end)
  end)

  describe("link abbreviations", function()
    it("expands function abbreviations", function()
      config.opts.links.abbreviations = {
        gh = function(tag)
          return "https://github.com/" .. tag
        end,
      }
      local h = body("html", { "See [[gh:neovim/neovim][nvim]]." })
      has(h, '<a href="https://github.com/neovim/neovim">nvim</a>')
      config.opts.links.abbreviations = {}
    end)
  end)

  describe("engine", function()
    it("reads #+OPTIONS values like the Elisp reader", function()
      local o = ox.parse_option_line('toc:nil H:2 d:(not "LOGBOOK") tasks:("TODO" "NEXT") ^:{} ::nil')
      eq(false, o.toc)
      eq(2, o.H)
      eq({ "LOGBOOK", negate = true }, o.d)
      eq({ "TODO", "NEXT" }, o.tasks)
      eq("{}", o["^"])
      eq(false, o[":"])
    end)
  end)

  describe("macros, footnotes and blocks (Emacs parity)", function()
    local function tmpdir(files)
      local d = vim.fn.tempname()
      vim.fn.mkdir(d, "p")
      for name, l in pairs(files) do
        vim.fn.writefile(l, d .. "/" .. name)
      end
      return d
    end

    it("aborts on an undefined macro", function()
      local ok_, err = pcall(body, "html", { "Text {{{nope}}} here." })
      eq(false, ok_)
      eq("Undefined Org macro: nope; aborting", err)
      -- but not in a COMMENT subtree, which is gone before expansion
      eq("", body("html", { "* COMMENT c", "{{{nope}}}" }))
    end)

    it("expands $0 to the first argument like org-macro-expand", function()
      eq("<p>\n[a|b|a]\n</p>\n", body("html", { "#+MACRO: m [$1|$2|$0]", "{{{m(a,b)}}}" }))
    end)

    it("reads macros and keywords from included files", function()
      local d = tmpdir({
        ["defs.org"] = { "#+MACRO: incm from-include", "#+TITLE: inc title" },
        ["main.org"] = { '#+INCLUDE: "defs.org"', "Use {{{incm}}} {{{title}}}" },
      })
      local f = d .. "/main.org"
      local h = ox.export_as("html", vim.fn.readfile(f), { filename = f, body_only = true })
      eq("<p>\nUse from-include inc title\n</p>\n", h)
    end)

    it("finds a footnote definition outside the exported subtree", function()
      local src = { "* A", "Note[fn:1].", "* B", "", "[fn:1] The definition." }
      local h = ox.export_as("html", src, { subtree_line = 1, body_only = true })
      has(h, "The definition.")
      has(h, 'href="#fn.1"')
    end)

    it("keeps a % in a user label of a LaTeX environment", function()
      local h = ox.export_as("html", { "#+NAME: eq%1", "\\begin{equation}", "x", "\\end{equation}" }, {
        body_only = true,
        ext = { html_prefer_user_labels = true },
      })
      eq("\\begin{equation}\n\\label{eq%1}\nx\n\\end{equation}\n", h)
    end)

    it("reads a blank line opening a quote or dynamic block as a paragraph", function()
      eq(
        "<blockquote>\n<p>\n\n</p>\n\n<p>\nq\n</p>\n</blockquote>\n",
        body("html", { "#+BEGIN_QUOTE", "", "q", "#+END_QUOTE" })
      )
      eq("<p>\n\n</p>\n\n\n<p>\nd\n</p>\n", body("html", { "#+BEGIN: foo", "", "", "d", "#+END:" }))
      -- drawers skip it
      eq("<p>\nx\n</p>\n", body("html", { ":DRW:", "", "x", ":END:" }))
    end)
  end)
end)

-- What the exporters ask for each headline, reference or row is computed
-- once per export (asked again and again, it made exports of a few
-- thousand headlines, footnotes or table rows take seconds to minutes);
-- the results are those of asking each time.
describe("export: answers computed once", function()
  before_each(function()
    config.opts.babel.evaluate_on_export = false
  end)

  it("anchors the Markdown headlines a table of contents or a link refers to", function()
    local doc = {
      "#+OPTIONS: toc:nil",
      "* A",
      "#+TOC: headlines 1 local",
      "** A1",
      "*** A1x",
      "** A2",
      "* B",
      ":PROPERTIES:",
      ":CUSTOM_ID: bee",
      ":END:",
      "* C",
      "See [[#bee][B]] and [[*D][d]].",
      "* D",
      ":PROPERTIES:",
      ":ID: dee",
      ":END:",
      "* E",
      "[[id:dee]]",
    }
    local function anchored(md)
      local out = {}
      for title in md:gmatch('<a id="[^"]+"></a>\n\n#+ ([^\n]+)') do
        out[#out + 1] = title
      end
      return out
    end
    eq({ "A1", "A2", "B", "D" }, anchored(body("md", doc)))
    -- the global table of contents refers to every top-level headline
    doc[1] = "#+OPTIONS: toc:1"
    local with_toc = anchored(body("md", doc))
    for _, title in ipairs({ "A", "B", "C", "D", "E" }) do
      ok(vim.tbl_contains(with_toc, title), title)
    end
  end)

  it("finds the emphasis of a search from each opening marker", function()
    local function objects(s)
      local out = {}
      local function walk(nodes)
        for _, n in ipairs(nodes or {}) do
          if type(n) == "table" and n.type ~= "plain-text" then
            out[#out + 1] = n.type .. " " .. tostring(n.value or n.raw_link or "")
            walk(n.contents)
          end
        end
      end
      walk(element.parse_secondary(s, "paragraph"))
      return out
    end
    eq({ "bold ", "bold " }, objects("*a b* c *d e* f *g"))
    eq({ "bold " }, objects("a *b *c d* e"))
    eq({ "italic ", "bold " }, objects("/x *y /z w* q/ r"))
    eq({ "verbatim a =b" }, objects("=a =b= c= *d *e"))
    eq({ "bold ", "bold " }, objects("*a\nb* c *d\ne *f* g*"))
    -- a plain link type is at most as long as the longest type
    eq({ "link https://x.org" }, objects("a1b2c3-d4 https://x.org"))
    eq({ "link https://x.org" }, objects(string.rep("a+b-", 50) .. "https://x.org"))
  end)

  it("numbers footnotes in the order of their first reference", function()
    local html = body("html", {
      "One[fn:b] two[fn:a] inline[fn:: anonymous] again[fn:b] nested[fn:n].",
      "",
      "[fn:a] A.",
      "[fn:b] B.",
      "[fn:n] N, see[fn:a] and[fn:c].",
      "[fn:c] C.",
    })
    local refs = {}
    for n in html:gmatch('class="footref"[^>]*>(%d+)</a>') do
      refs[#refs + 1] = tonumber(n)
    end
    -- b=1, a=2, the anonymous one 3, b again 1, n=4; inside n: a=2, c=5
    eq({ 1, 2, 3, 1, 4, 2, 5 }, refs)
    -- a definition only once, at its first reference
    local _, defs = html:gsub('class="footnum"', "")
    eq(5, defs)
  end)

  it("draws the rule borders of table rows", function()
    local html = body("html", { "| a | b |", "|---+---|", "| 1 | 2 |", "| 3 | 4 |", "|---+---|", "| 5 | 6 |" })
    local _, groups = html:gsub("<tbody>", "")
    eq(2, groups)
    has(html, "<thead>")
  end)
end)

describe("export: sub- and superscripts in the title", function()
  -- a subscript right in a #+TITLE (a secondary string) has no parent
  -- element: ^:nil and ^:{} still keep it as text, like Emacs
  it("follows ^:nil and ^:{}", function()
    for _, opt in ipairs({ "^:nil", "^:{}" }) do
      local html =
        export.to_string("html", { lines = { "#+TITLE: HUGO_DRAFT x^y", "#+OPTIONS: " .. opt, "", "Text." } })
      has(html, '<h1 class="title">HUGO_DRAFT x^y</h1>')
    end
    has(export.to_string("html", { lines = { "#+TITLE: a_b", "", "Text." } }), '<h1 class="title">a<sub>b</sub></h1>')
  end)
end)

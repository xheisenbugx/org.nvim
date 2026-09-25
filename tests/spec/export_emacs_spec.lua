local export = require("org.export")

local function html(lines, opts)
  opts = opts or {}
  return export.to_string("html", { lines = lines, filename = opts.filename, subtree_line = opts.subtree_line, body_only = true })
end

local function txt(lines)
  return export.to_string("txt", { lines = lines, body_only = true })
end

local function has(s, sub)
  ok(s:find(sub, 1, true), "missing: " .. sub .. "\n---\n" .. s)
end
local function hasnt(s, sub)
  ok(not s:find(sub, 1, true), "unexpected: " .. sub .. "\n---\n" .. s)
end

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

describe("export (Emacs features)", function()
  it("exports #+HTML: / #+LATEX: keywords to their backend only", function()
    local lines = { "#+HTML: <hr class='x'>", "#+LATEX: \\newpage", "Text" }
    local h = html(lines)
    has(h, "<hr class='x'>")
    hasnt(h, "newpage")
    local l = export.to_string("latex", { lines = lines, body_only = true })
    has(l, "\\newpage")
  end)

  it("turns radio targets into anchors and their occurrences into links", function()
    local h = html({ "* A", "The <<<Widget>>> is defined here.", "* B", "Use the widget often." })
    has(h, '<a id="target-widget"></a>Widget')
    has(h, '<a href="#target-widget">widget</a>')
    local h2 = html({ "A <<<big box>>> here.", "", "Put it in the big", "box now." })
    has(h2, '<a href="#target-big-box">big\nbox</a>')
    local t = txt({ "The <<<Widget>>> here." })
    has(t, "The Widget here.")
  end)

  it("honours tasks:, arch:, stat:, e: and c: options", function()
    local lines = {
      "#+OPTIONS: tasks:todo arch:nil stat:nil e:nil c:t toc:nil num:nil",
      "* TODO Open task [1/2]",
      "* DONE Closed task",
      "* Plain \\alpha",
      "CLOCK: [2026-09-01 Tue 10:00]--[2026-09-01 Tue 11:00] =>  1:00",
      "* Old :ARCHIVE:",
    }
    local h = html(lines)
    has(h, "Open task")
    hasnt(h, "[1/2]")
    hasnt(h, "Closed task")
    has(h, "\\alpha")
    has(h, "CLOCK:")
    hasnt(h, "Old")
    local h2 = html({ '#+OPTIONS: tasks:("NEXT") toc:nil', "* TODO a", "* NEXT b", "* c" })
    hasnt(h2, ">a<")
    has(h2, "b")
    has(h2, "c")
    hasnt(html({ "* H", "CLOCK: [2026-09-01 Tue 10:00]--[2026-09-01 Tue 11:00] =>  1:00" }), "CLOCK:")
  end)

  it("exports properties with prop:t and chosen drawers with d:", function()
    local lines = {
      '#+OPTIONS: prop:t d:("NOTES") toc:nil',
      "* H",
      ":PROPERTIES:",
      ":OWNER: me",
      ":END:",
      ":NOTES:",
      "visible note",
      ":END:",
      ":OTHER:",
      "hidden",
      ":END:",
    }
    local h = html(lines)
    has(h, '<pre class="properties">OWNER: me</pre>')
    has(h, "visible note")
    hasnt(h, "hidden")
  end)

  it("uses EXPORT_OPTIONS / EXPORT_AUTHOR of an exported subtree", function()
    local lines = {
      "#+AUTHOR: File Author",
      "* Sub",
      ":PROPERTIES:",
      ":EXPORT_OPTIONS: todo:nil",
      ":EXPORT_AUTHOR: Sub Author",
      ":END:",
      "** TODO Task",
    }
    local doc = require("org.export.ast").parse(lines, { subtree_line = 2 })
    eq("Sub Author", doc.author)
    eq(false, doc.options.todo)
  end)

  it("#+INCLUDE with a headline selector, :only-contents and level shifting", function()
    local dir = tmpdir()
    vim.fn.writefile({ "* One", "one body", "* Two", ":PROPERTIES:", ":X: 1", ":END:", "two body", "** Two child" }, dir .. "/inc.org")
    vim.fn.writefile({ "#+MACRO: shout $1!" }, dir .. "/setup.org")
    local lines = {
      "#+SETUPFILE: setup.org",
      "* Parent",
      '#+INCLUDE: "inc.org::*Two" :only-contents t',
      "{{{shout(hey)}}}",
    }
    local doc = require("org.export.ast").parse(lines, { filename = dir .. "/main.org" })
    local parent = doc.children[1]
    eq("Parent", parent.raw_title)
    eq("Two child", parent.children[#parent.children].raw_title)
    eq(2, parent.children[#parent.children].level)
    local h = html(lines, { filename = dir .. "/main.org" })
    has(h, "two body")
    hasnt(h, "one body")
    has(h, "hey!")
  end)

  it("expands nested macros, escaped commas, property, n and results", function()
    local lines = {
      "#+MACRO: pair ($1 / $2)",
      "#+MACRO: wrap [{{{pair($1,$2)}}}]",
      "#+DATE: <2026-03-04 Wed>",
      "* H",
      ":PROPERTIES:",
      ":COLOR: blue",
      ":END:",
      "{{{wrap(x,y)}}} {{{pair(a\\, b, c)}}} {{{property(COLOR)}}} {{{n}}} {{{n}}} {{{n(x,5)}}} {{{date(%Y)}}} {{{results(42)}}}",
    }
    local h = html(lines)
    has(h, "[(x / y)] (a, b / c) blue 1 2 5 2026 42")
  end)

  it("exports inline src blocks by their :exports setting", function()
    local h = html({ "Sum: src_python{1+1} {{{results(=2=)}}} and src_sh[:exports code]{ls}." })
    has(h, "Sum:  <code>2</code> and <code>ls</code>.")
  end)

  it("numbers lines and resolves coderefs", function()
    local lines = {
      "#+begin_src sh -n -r",
      "echo a",
      "echo b (ref:second)",
      "#+end_src",
      "",
      "Line [[(second)]] prints b.",
    }
    local h = html(lines)
    has(h, '<span id="coderef-second" class="coderef-off">2  echo b</span>')
    has(h, '<a href="#coderef-second">2</a>')
    has(h, "1  echo a")
    local h2 = html({ "#+begin_example -n 9", "a", "b", "#+end_example", "#+begin_example +n", "c", "#+end_example" })
    has(h2, " 9  a\n10  b")
    has(h2, "11  c")
  end)

  it("expands noweb references in exported code with :noweb yes", function()
    local h = html({
      "#+NAME: helper",
      "#+begin_src sh",
      "helper() { :; }",
      "#+end_src",
      "#+begin_src sh :noweb yes",
      "<<helper>>",
      "helper",
      "#+end_src",
      "#+begin_src sh :noweb no-export",
      "<<helper>>",
      "#+end_src",
    })
    local _, n = h:gsub("helper%(%) { :; }", "")
    eq(2, n)
    has(h, "&lt;&lt;helper&gt;&gt;")
  end)

  it("inserts the default export template", function()
    local buf = org_buffer({ "#+TITLE: Mine", "text" }, { 2, 0 })
    export.insert_template()
    local l = buf_lines(buf)
    ok(l[2]:match("^#%+options: "), l[2])
    ok(vim.tbl_contains(l, "#+title: Mine"))
    ok(vim.tbl_contains(l, "#+exclude_tags: noexport"))
    local o = require("org.export.ast").options(require("org.parser").parse(l).settings)
    eq(true, o.toc)
  end)
end)

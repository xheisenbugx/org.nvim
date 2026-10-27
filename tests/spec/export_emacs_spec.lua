local export = require("org.export")
local ox = require("org.export.ox")
local config = require("org.config")

local function html(lines, opts)
  opts = opts or {}
  return export.to_string("html", {
    lines = lines,
    filename = opts.filename,
    subtree_line = opts.subtree_line,
    body_only = opts.body_only ~= false,
    ext = opts.ext,
  })
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
  local babel = require("org.babel")
  local real_evaluate = babel.export_evaluate
  before_each(function()
    config.opts.babel.evaluate_on_export = false
    babel.export_evaluate = real_evaluate
  end)

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
    local id = h:match('<a id="(org%x+)">Widget</a>')
    ok(id, h)
    has(h, '<a href="#' .. id .. '">widget</a>')
    local h2 = html({ "A <<<big box>>> here.", "", "Put it in the big", "box now." })
    ok(h2:find('<a href="#org%x+">big\nbox</a>'), h2)
  end)

  it("a line starting with an object with contents doesn't count for a paragraph's indentation", function()
    -- org-element-normalize-contents (difftest seed 8395981): the empty
    -- {{{title}}} leaves " task", and the other lines start with objects
    eq(
      '<p>\ntask gamma\n<a id="orgID">radio</a>\n</p>\n',
      (html({ "{{{title}}} task gamma", "<<<radio>>>" }):gsub("org%x+", "orgID"))
    )
    has(html({ " task gamma", "*bold* x" }), "<p>\ntask gamma\n<b>bold</b> x\n</p>")
    has(html({ " task gamma", "_*mixed*_ x" }), '<p>\ntask gamma\n<span class="underline"><b>mixed</b></span> x\n</p>')
    -- a line starting with text keeps the indentation
    has(html({ " task gamma", "plain" }), "<p>\n task gamma\nplain\n</p>")
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
    has(h, '<span class="timestamp-kwd">CLOCK:</span>')
    hasnt(h, "Old")
    local h2 = html({ "#+TODO: TODO NEXT | DONE", '#+OPTIONS: tasks:("NEXT") toc:nil', "* TODO a", "* NEXT b", "* c" })
    hasnt(h2, "> a<")
    has(h2, "NEXT</span> b")
    has(h2, "c</h2>")
    hasnt(html({ "* H", "CLOCK: [2026-09-01 Tue 10:00]--[2026-09-01 Tue 11:00] =>  1:00" }), "CLOCK:")
  end)

  it("exports drawers by default except LOGBOOK, and properties with prop:t", function()
    local lines = {
      "#+OPTIONS: toc:nil",
      "* H",
      ":PROPERTIES:",
      ":OWNER: me",
      ":END:",
      ":LOGBOOK:",
      "- logged",
      ":END:",
      ":NOTES:",
      "visible note",
      ":END:",
    }
    local h = html(lines)
    has(h, "visible note")
    hasnt(h, "logged")
    hasnt(h, "OWNER")
    local h2 = html(vim.list_extend({ '#+OPTIONS: prop:t d:("LOGBOOK")' }, vim.list_slice(lines, 2)))
    has(h2, '<pre class="example">\nOWNER: me\n</pre>')
    has(h2, "logged")
    hasnt(h2, "visible note")
    config.opts.export.with_drawers = false
    hasnt(html(lines), "visible note")
    config.opts.export.with_drawers = { ["not"] = { "LOGBOOK" } }
  end)

  it("uses EXPORT_* properties of an exported subtree", function()
    local lines = {
      "#+AUTHOR: File Author",
      "* Sub",
      ":PROPERTIES:",
      ":EXPORT_OPTIONS: todo:nil",
      ":EXPORT_AUTHOR: Sub Author",
      ":EXPORT_TITLE: The Title",
      ":END:",
      "** TODO Task",
    }
    local out, info = ox.export_as("html", lines, { subtree_line = 2 })
    eq("Sub Author", require("org.export.element").interpret(info.author))
    eq(false, info.with_todo_keywords)
    has(out, '<h1 class="title">The Title</h1>')
    hasnt(out, ">TODO<")
  end)

  it("#+INCLUDE with a headline selector, :only-contents and level shifting", function()
    local dir = tmpdir()
    vim.fn.writefile(
      { "* One", "one body", "* Two", ":PROPERTIES:", ":X: 1", ":END:", "two body", "** Two child" },
      dir .. "/inc.org"
    )
    vim.fn.writefile({ "#+MACRO: shout $1!" }, dir .. "/setup.org")
    local lines = {
      "#+SETUPFILE: setup.org",
      "#+OPTIONS: toc:nil",
      "* Parent",
      '#+INCLUDE: "inc.org::*Two" :only-contents t',
      "{{{shout(hey)}}}",
    }
    local h = html(lines, { filename = dir .. "/main.org" })
    has(h, "two body")
    hasnt(h, "one body")
    has(h, "hey!")
    has(h, '<h3 id="org')
    has(h, "Two child</h3>")
  end)

  it("rebases an included file's links onto the top-level document", function()
    -- org-export--prepare-file-contents: every file link (plain, angle,
    -- bracket, file+sys / file+emacs), also in a nested include, becomes
    -- relative to the top-level file; verbatim text and src blocks are kept
    local dir = tmpdir()
    vim.fn.mkdir(dir .. "/sub", "p")
    vim.fn.writefile({
      "plain file:pic.png and <file:a.txt> and [[file+sys:b.pdf]] and [[file+emacs:c.org][C]]",
      "[[./d.org]] [[file:e.org::*H][E]] [[file:/abs/x.org]] [[file:p.png][file:thumb.png]] =file:v.png=",
      "#+begin_src sh",
      "echo file:src.png",
      "#+end_src",
      '#+INCLUDE: "./deeper.org"',
    }, dir .. "/sub/inc.org")
    vim.fn.writefile({ "deeper [[file:d2.org][d]] file:dd.png" }, dir .. "/sub/deeper.org")
    local out = export.to_string("org", {
      lines = { '#+INCLUDE: "sub/inc.org"' },
      filename = dir .. "/main.org",
      body_only = true,
    })
    has(out, "plain file:sub/pic.png and <file:sub/a.txt> and [[file+sys:sub/b.pdf]] and [[file+emacs:sub/c.org][C]]")
    has(out, "[[sub/d.org]] [[file:sub/e.org::*H][E]] [[file:/abs/x.org]] [[file:sub/p.png][file:sub/thumb.png]]")
    has(out, "=file:v.png=")
    has(out, "echo file:src.png")
    has(out, "deeper [[file:sub/d2.org][d]] file:sub/dd.png")
  end)

  it("stops the export on a missing #+INCLUDE file, like Emacs", function()
    local ok_, err = pcall(ox.export_as, "html", { '#+INCLUDE: "nope.org"' }, { filename = tmpdir() .. "/x.org" })
    eq(false, ok_)
    ok(tostring(err):find("Cannot include file", 1, true), tostring(err))
  end)

  it("expands nested macros, escaped commas, property, n and results", function()
    config.opts.babel.evaluate_on_export = true
    babel.export_evaluate = function(_, l)
      return l
    end
    local lines = {
      "#+MACRO: pair ($1 / $2)",
      "#+MACRO: wrap [{{{pair($1,$2)}}}]",
      "#+DATE: <2026-03-04 Wed>",
      "#+OPTIONS: toc:nil",
      "* H",
      ":PROPERTIES:",
      ":COLOR: blue",
      ":END:",
      "{{{wrap(x,y)}}} {{{pair(a\\, b, c)}}} {{{property(COLOR)}}} "
        .. "{{{n}}} {{{n}}} {{{n(x,5)}}} {{{date(%Y)}}} {{{results(42)}}}",
    }
    -- like Emacs, the space after the comma belongs to the second argument
    has(html(lines), "[(x / y)] (a, b /  c) blue 1 2 5 2026 42")
  end)

  it("exports a link to another file's /regexp/ search without a broken link", function()
    -- Emacs: the search is a sparse tree (org-occur), never an error
    local dir = tmpdir()
    vim.fn.writefile({ "* A", ":PROPERTIES:", ":OWNER: Alice", ":END:" }, dir .. "/other.org")
    require("org.utils").notify = function() end
    local h = html({ "[[file:other.org::/OWNER: +Alice/][Alice]]" }, { filename = dir .. "/main.org" })
    has(h, '<a href="other.html#MissingReference">Alice</a>')
  end)

  describe("a link to another file with a search option", function()
    -- expected output from Emacs 9.8.10 (org-html-link ->
    -- org-publish-resolve-external-link, which runs org-link-search with
    -- org-link-search-must-match-exact-headline bound to t)
    local utils = require("org.utils")
    local real_notify = utils.notify
    local notes
    local dir
    before_each(function()
      notes = {}
      utils.notify = function(msg)
        notes[#notes + 1] = msg
      end
      dir = tmpdir()
      vim.fn.writefile({ "local a = 1", "local b = 2", "return a + b -- 3" }, dir .. "/x.lua")
      vim.fn.writefile({ "-- see <<tgt>> here", "#+NAME: nm" }, dir .. "/y.lua")
      vim.fn.writefile({
        "* Head one",
        ":PROPERTIES:",
        ":CUSTOM_ID: hc",
        ":END:",
        "* Two",
        "<<otgt>>",
        "#+begin_src emacs-lisp",
        "(a) ; (ref:lbl)",
        "#+end_src",
        "* <<ht>> Three",
        ":PROPERTIES:",
        ":CUSTOM_ID: hh",
        ":END:",
      }, dir .. "/o.org")
    end)
    after_each(function()
      utils.notify = real_notify
    end)

    local function export_links(links, broken)
      local lines = { "* H", links }
      if broken then
        table.insert(lines, 1, "#+OPTIONS: broken-links:" .. broken)
      end
      return html(lines, { filename = dir .. "/t.org" })
    end

    it("makes a search in a missing file a broken link", function()
      -- find-file-noselect gives an empty buffer: the search finds nothing
      local links = "[[file:missing.org::target][t]] [[file:missing.org::#cid][c]] "
        .. "[[file:missing.org::*Head][h]] [[file:missing.org::(ref)][r]]"
      local h = export_links(links, "mark")
      has(
        h,
        "[BROKEN LINK: No match for fuzzy expression: target] "
          .. '<a href="missing.html#cid">c</a> '
          .. "[BROKEN LINK: No match for fuzzy expression: *Head] "
          .. "[BROKEN LINK: No match for coderef: ref]"
      )
      has(export_links(links, "t"), '<a href="missing.html#cid">c</a> \n</p>')
      local ok_, err = pcall(export_links, links)
      eq(false, ok_)
      has(tostring(err), 'Unable to resolve link: "No match for fuzzy expression: target"')
    end)

    it("finds the text of a file that isn't an Org file, and warns", function()
      local h = export_links("See [[file:x.lua::3]] and [[file:x.lua::3][desc]].")
      has(
        h,
        '<a href="x.lua#MissingReference">x.lua#MissingReference</a> and <a href="x.lua#MissingReference">desc</a>'
      )
      eq('Reference "3" in file "x.lua" cannot be resolved without publishing', notes[1])
    end)

    it("searches words case-insensitively in a file that isn't an Org file", function()
      local h = export_links(
        "[[file:x.lua::LOCAL   b][a]] [[file:x.lua::*local][b]] [[file:x.lua::/re/][c]] "
          .. "[[file:y.lua::tgt][d]] [[file:y.lua::nm][e]] [[file:x.lua::#cid][f]]"
      )
      has(
        h,
        '<a href="x.lua#MissingReference">a</a> <a href="x.lua#MissingReference">b</a> '
          .. '<a href="x.lua#MissingReference">c</a> <a href="y.lua#MissingReference">d</a> '
          .. '<a href="y.lua#MissingReference">e</a> <a href="x.lua#cid">f</a>'
      )
    end)

    it("aborts on text that isn't there, with Emacs's message", function()
      local okk, err = pcall(export_links, "[[file:x.lua::nomatch][d]]")
      eq(false, okk)
      ok(tostring(err):find('Unable to resolve link: "No match for fuzzy expression: nomatch"', 1, true), err)
      local h = export_links("[[file:x.lua::*nomatch][a]] [[file:x.lua::(zz)][b]] [[file:o.org::words][c]]", "mark")
      has(
        h,
        "[BROKEN LINK: No match for fuzzy expression: *nomatch] [BROKEN LINK: No match for coderef: zz] "
          .. "[BROKEN LINK: No match for fuzzy expression: words]"
      )
    end)

    it("an Org file: CUSTOM_ID of the headline found, else MissingReference", function()
      local h = export_links(
        "[[file:o.org::*Head one][a]] [[file:o.org::Two][b]] [[file:o.org::otgt][c]] "
          .. "[[file:o.org::(lbl)][d]] [[file:o.org::ht][e]] [[file:o.org::/x/][f]] [[file:o.org::#zz][g]]"
      )
      has(
        h,
        '<a href="o.html#hc">a</a> <a href="o.html#MissingReference">b</a> '
          .. '<a href="o.html#MissingReference">c</a> <a href="o.html#MissingReference">d</a> '
          .. '<a href="o.html#hh">e</a> <a href="o.html#hc">f</a> <a href="o.html#zz">g</a>'
      )
    end)
  end)

  it("replaces {{{results}}} only when Babel runs on export (org-export-use-babel)", function()
    -- Emacs 9.8.10: org-export-as expands the results macro after
    -- Babel ran; with org-export-use-babel nil it stays and exports as
    -- nothing
    local lines = { "#+OPTIONS: toc:nil", "* H", "A {{{results(42)}}} B" }
    has(html(lines), "A B")
    hasnt(html(lines), "42")
    config.opts.babel.evaluate_on_export = true
    babel.export_evaluate = function(_, l)
      return l
    end
    has(html(lines), "A 42 B")
  end)

  it("does not expand macros in code, blocks or fixed-width areas", function()
    local h = html({ "#+TITLE: T", "=v {{{title}}}= {{{title}}}", ": f {{{title}}}" })
    has(h, "<code>v {{{title}}}</code> T")
    has(h, "f {{{title}}}")
  end)

  it("handles :exports of source blocks and inline code on export (org-export-use-babel)", function()
    config.opts.babel.evaluate_on_export = true
    babel.export_evaluate = function(_, l)
      return l
    end
    local h = html({
      "#+begin_src sh :exports results",
      "echo res",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": res",
      "",
      "#+begin_src sh :exports none",
      "echo none",
      "#+end_src",
      "",
      "Sum: src_python{1+1} {{{results(=2=)}}} and src_sh[:exports code]{ls}.",
    })
    hasnt(h, "echo res")
    has(h, "res\n</pre>")
    hasnt(h, "none")
    has(h, 'Sum: <code>2</code> and <code class="src src-sh">ls</code>.')
    -- text in verbatim, code and link paths is not Babel code
    local h1 =
      html({ "V =src_sh{echo v}= C ~call_f()~ [[https://x.org/src_sh{p}][d]] R src_sh{r} {{{results(=r=)}}}." })
    has(h1, "V <code>src_sh{echo v}</code> C <code>call_f()</code>")
    has(h1, 'href="https://x.org/src_sh%7Bp%7D"')
    has(h1, "R <code>r</code>.")
    -- without Babel on export every block and result is exported, like Emacs
    config.opts.babel.evaluate_on_export = false
    local h2 = html({ "#+begin_src sh :exports none", "echo none", "#+end_src" })
    has(h2, "echo none")
  end)

  it("numbers lines and resolves coderefs like ox-html", function()
    local lines = {
      "#+begin_src sh -n -r",
      "echo a",
      "echo b (ref:second)",
      "#+end_src",
      "",
      "Line [[(second)]] prints b.",
    }
    local h = html(lines)
    has(h, '<span id="coderef-second" class="coderef-off"><span class="linenr">2: </span>echo b</span>')
    has(h, 'class="coderef"')
    has(h, ">2</a> prints b.")
    -- without -r the label is kept and links show it
    local h2 = html({ "#+begin_src sh -n", "echo b (ref:x)", "#+end_src", "", "See [[(x)]]." })
    has(h2, "echo b (x)</span>")
    has(h2, ">x</a>.")
    local h3 = html({ "#+begin_example -n 9", "a", "b", "#+end_example", "#+begin_example +n", "c", "#+end_example" })
    has(h3, '<span class="linenr"> 9: </span>a\n<span class="linenr">10: </span>b')
    has(h3, '<span class="linenr">11: </span>c')
  end)

  it("resolves a coderef whose label has pattern characters (ref:a-b)", function()
    local h = html({ "#+begin_src sh -n -r", "echo a", "echo b (ref:a-b)", "#+end_src", "", "Line [[(a-b)]]." })
    has(h, ">2</a>.")
  end)

  it("expands noweb references in exported code with :noweb yes", function()
    config.opts.babel.evaluate_on_export = true
    babel.export_evaluate = function(_, l)
      return l
    end
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

  it("inserts the default export template like org-export-insert-default-template", function()
    local buf = org_buffer({ "text" }, { 1, 0 })
    vim.api.nvim_buf_set_name(buf, tmpdir() .. "/mine.org")
    local out = export.insert_template()
    local l = buf_lines(buf)
    eq("#+options: ':nil *:t -:t ::t <:t H:3 \\n:nil ^:t arch:headline", l[1])
    ok(vim.tbl_contains(l, "#+title: mine"), vim.inspect(l))
    ok(vim.tbl_contains(l, "#+language: en"))
    ok(vim.tbl_contains(l, "#+select_tags: export"))
    ok(vim.tbl_contains(l, "#+exclude_tags: noexport"))
    ok(vim.tbl_contains(l, '#+options: d:(not "LOGBOOK") date:t e:t email:nil expand-links:t f:t'), vim.inspect(out))
    vim.bo[buf].modified = false
  end)

  it("drops the table special column and special rows, applies alignment cookies", function()
    local h = html({ "| ! | a | b |", "| # | 1 | 2 |", "| $ | x=1 |  |", "", "| <r> | <l> |", "| left | 1 |" })
    has(h, '<td class="org-right">1</td>\n<td class="org-right">2</td>')
    hasnt(h, "x=1")
    hasnt(h, "!")
    has(h, '<td class="org-right">left</td>\n<td class="org-left">1</td>')
  end)

  it("removes only isolated timestamps with <:nil", function()
    local h = html({ "#+OPTIONS: <:nil", "date <2026-09-23 Wed>, ok", "", "<2026-09-24 Thu>" })
    has(h, "2026-09-23")
    hasnt(h, "2026-09-24")
    local h2 = html({ "#+OPTIONS: <:active", "[2026-09-23 Wed]", "", "<2026-09-24 Thu>" })
    hasnt(h2, "2026-09-23")
    has(h2, "2026-09-24")
  end)

  it("exports inline tasks like org-inlinetask", function()
    local h = html({ "text", "*************** TODO Inline task", "inline body", "*************** END", "after" })
    has(h, '<div class="inlinetask">\n<b><span class="todo TODO">TODO</span> Inline task</b><br />')
    has(h, "inline body")
    hasnt(h, ">END<")
    hasnt(
      html({ "#+OPTIONS: inline:nil", "*************** TODO Inline task", "body", "*************** END" }),
      "Inline"
    )
  end)

  it("handles broken links per broken-links:", function()
    local ok_, err = pcall(html, { "[[#nope]]" })
    eq(false, ok_)
    ok(tostring(err):find("Unable to resolve link", 1, true), tostring(err))
    has(html({ "#+OPTIONS: broken-links:mark", "a [[#nope]] b" }), "[BROKEN LINK: nope]")
    has(html({ "#+OPTIONS: broken-links:t", "a [[#nope]] b" }), "a b")
  end)

  it("uses smart quotes with ':t and localises strings with #+LANGUAGE", function()
    local h = html({ "#+OPTIONS: ':t", '"quoted" and don\'t' })
    has(h, "&ldquo;quoted&rdquo; and don&rsquo;t")
    local fr = html({ "#+LANGUAGE: fr", "* A" }, { body_only = true })
    has(fr, "Table des matières")
  end)

  it("keeps select tags in headlines and drops the text before the first one", function()
    local h = html({ "#+OPTIONS: toc:nil", "preamble", "* A :export:", "* B" })
    hasnt(h, "preamble")
    has(h, '<span class="export">export</span>')
    hasnt(h, "> B<")
  end)

  it("renders #+TOC: tables, listings and local", function()
    local lines = {
      "#+OPTIONS: toc:nil",
      "#+TOC: tables",
      "#+TOC: listings",
      "#+CAPTION: Tbl",
      "| a |",
      "#+CAPTION: Lst",
      "#+begin_src sh",
      "ls",
      "#+end_src",
      "* One",
      "#+TOC: headlines 1 local",
      "** Two",
      "* Three",
    }
    local h = html(lines)
    has(h, '<div id="list-of-tables">')
    has(h, '<span class="table-number">Table 1:</span> Tbl')
    has(h, '<div id="list-of-listings">')
    has(h, '<span class="listing-number">Listing 1:</span> Lst')
    has(h, '<div id="text-table-of-contents" role="doc-toc">\n<ul>\n<li><a href="#')
    local toc = h:match('<div id="text%-table%-of%-contents" role="doc%-toc">(.-)</div>')
    ok(toc and toc:find("Two", 1, true) and not toc:find("Three", 1, true), toc)
  end)

  it("runs Lua filters and hooks", function()
    config.opts.export.filters = {
      paragraph = function(s)
        return s:upper()
      end,
      ["final-output"] = {
        function(s)
          return s .. "<!-- done -->\n"
        end,
      },
    }
    config.opts.export.hooks = {
      before_parsing = function(_, lines)
        return vim.list_extend(lines, { "", "added" })
      end,
    }
    local h = html({ "text" })
    config.opts.export.filters = {}
    config.opts.export.hooks = {}
    has(h, "<P>\nTEXT\n</P>")
    has(h, "ADDED")
    has(h, "<!-- done -->")
  end)

  it("exports only visible lines with visible_only", function()
    local buf = org_buffer({ "* A", "hidden body", "* B", "shown body" }, { 1, 0 })
    vim.wo.foldmethod = "manual"
    vim.cmd("normal! zE")
    vim.cmd("1,2fold")
    eq(1, vim.fn.foldclosed(2))
    local h = export.to_string("html", { bufnr = buf, body_only = true, visible_only = true })
    hasnt(h, "hidden body")
    has(h, "shown body")
    vim.bo[buf].modified = false
  end)

  it("applies visible_only to a subtree export", function()
    local buf = org_buffer({ "* S", "intro", "** One", "hidden body", "** Two", "shown body" }, { 1, 0 })
    vim.wo.foldmethod = "manual"
    vim.cmd("normal! zE")
    vim.cmd("3,4fold")
    local h = export.to_string("html", { bufnr = buf, subtree_line = 1, body_only = true, visible_only = true })
    has(h, "intro")
    has(h, "One")
    hasnt(h, "hidden body")
    has(h, "shown body")
    -- a folded subtree root hides its whole body
    vim.cmd("normal! zE")
    vim.cmd("1,6fold")
    h = export.to_string("html", { bufnr = buf, subtree_line = 1, body_only = true, visible_only = true })
    hasnt(h, "intro")
    hasnt(h, "One")
    vim.bo[buf].modified = false
  end)

  it("reads {{{property}}} from the exported subtree's own heading", function()
    local lines = {
      "* Top",
      "** Sub",
      ":PROPERTIES:",
      ":OWNER: Charles",
      ":END:",
      "Owner: {{{property(OWNER)}}}; item {{{property(ITEM)}}}.",
      "*** Kid",
      ":PROPERTIES:",
      ":OWNER: Ada",
      ":END:",
      "Kid owner: {{{property(OWNER)}}}.",
    }
    local h = html(lines, { subtree_line = 6 })
    has(h, "Owner: Charles; item Sub.")
    has(h, "Kid owner: Ada.")
  end)
end)

describe("export: fuzzy links with more than one target", function()
  -- org-export-resolve-fuzzy-link pushes each datum onto its search cell,
  -- so the last one in the document wins (difftest seed 5792506)
  it("a *title link reaches the last headline that matches", function()
    local out = ox.export_as("ascii", {
      "#+OPTIONS: num:nil",
      "** Alpha [/]",
      "[[*Alpha][heading]]",
      "*** alpha",
    }, { body_only = true })
    has(out, "[heading] See section alpha")
  end)

  it("a link reaches the last of two <<target>>s", function()
    local out = html({ "first <<here>> and second <<here>>", "", "[[here][go]]" })
    local ids = {}
    for id in out:gmatch('id="([^"]+)"') do
      ids[#ids + 1] = id
    end
    eq(2, #ids)
    has(out, 'href="#' .. ids[2] .. '"')
  end)
end)

describe("export: Emacs parity (difftest #243)", function()
  it("a verse line break keeps the blank before it (seed 2521119)", function()
    -- org-html-verse-block only drops blanks right before a newline
    local out = html({ "#+begin_verse", "plan \\\\", "next  ", "#+end_verse" })
    has(out, "plan <br />\nnext<br />\n")
  end)

  it("an inline task ends a plain list (seed 2521175)", function()
    local out = html({ "- a", "*************** plan", "- b" })
    has(out, '<ul class="org-ul">\n<li>a</li>\n</ul>\n<div class="inlinetask">')
    has(out, '</div>\n<ul class="org-ul">\n<li>b</li>\n</ul>')
    out = html({ "3.", "*************** plan", "+ 42" })
    has(out, '<ol class="org-ol">\n<li></li>\n</ol>')
    has(out, '<ul class="org-ul">\n<li>42</li>\n</ul>')
  end)
end)

describe("export: Emacs parity (difftest #273)", function()
  local function latex(lines)
    return export.to_string("latex", { lines = lines, body_only = true })
  end

  it("blank lines after the last verse line are dropped (seed 8155455)", function()
    local out = latex({ "#+begin_verse", "<https://example.com/angle>", "", "#+end_verse" })
    eq("\\begin{verse}\n\\url{https://example.com/angle}\n\\end{verse}\n", out)
  end)

  it("several blank lines in a verse make one stanza break", function()
    local out = latex({ "#+begin_verse", "a", "b", "", "", "c *x*", "", "", "d", "#+end_verse" })
    eq("\\begin{verse}\na\\\\\nb\n\nc \\textbf{x}\n\nd\\\\\n\\end{verse}\n", out)
  end)

  it("with :lines a stanza ends with \\\\!", function()
    local out =
      latex({ "#+attr_latex: :lines 5", "#+begin_verse", "a", "", "", "b *x*", "", "", "c", "", "#+end_verse" })
    has(out, "a\\\\!\n\nb \\textbf{x}\\\\!\n\nc\\\\!\n\\end{verse}")
  end)

  it("with :literal blank lines stay empty lines", function()
    local out = latex({ "#+attr_latex: :literal t", "#+begin_verse", "", "a *x*", "", "", "  d", "", "#+end_verse" })
    eq("\\begin{verse}\n\na \\textbf{x}\\\\\n\n\n\\hspace*{2\\fontdimen2\\font}d\\\\\n\n\\end{verse}\n", out)
  end)
end)

describe("export: Emacs parity (difftest known differences)", function()
  local function latex(lines)
    return ox.export_as("latex", lines, { body_only = true })
  end

  it("LaTeX escapes each of two backslashes (an intentional difference)", function()
    -- Emacs writes "$\backslash$\ x" (:h org-export-unsupported); the
    -- export NORMALISE rule of tests/emacs_parity.lua maps one to the other
    local out = latex({ "A \\\\ x." })
    has(out, "A $\\backslash$$\\backslash$ x.")
    local parity = require("tests.emacs_parity")
    local e, o = parity.normalise("export", { "A $\\backslash$\\ x." }, { "A $\\backslash$$\\backslash$ x." })
    eq(e, o)
  end)

  it("LaTeX puts math entities of a caption in \\(...\\) as in the text", function()
    -- org-latex--wrap-latex-math-block maps over affiliated keywords too
    local out = latex({ "#+CAPTION[Short \\gamma]: A \\alpha\\beta and \\pi *b \\delta*", "| a |" })
    has(out, "\\caption[Short \\(\\gamma\\)]{A \\(\\alpha \\beta\\) and \\(\\pi\\) \\textbf{b \\(\\delta\\)}}")
  end)

  it("Org export repairs plain lists like org-list-repair", function()
    -- "1." bullets whatever the source used, sub-lists under their
    -- parent's text, parent checkboxes from their children
    local out = ox.export_as("org", {
      "1) one",
      "2) two",
      "   1) sub",
      "   2) [@5] subtwo",
      "",
      "- tag :: body",
      "  - nested [X]",
      "  - [ ] child",
      "- [ ] parent",
      "  - [X] c",
      "  - [ ] d",
      "    + [X] e",
      "- [X] desc :: with",
      "  1. [X] f",
    }, { body_only = true })
    eq(
      table.concat({
        "1. one",
        "2. two",
        "   1. sub",
        "   5. [@5] subtwo",
        "",
        "3. tag :: body",
        "   - nested [X]",
        "   - [ ] child",
        "4. [X] parent",
        "   - [X] c",
        "   - [X] d",
        "     - [X] e",
        "5. [X] desc :: with",
        "   1. [X] f",
        "",
      }, "\n"),
      out
    )
  end)

  it("Org export indents repaired lists with spaces (an intentional difference)", function()
    -- Emacs writes a tab from column 8 on (indent-tabs-mode); the export
    -- NORMALISE rule expands tabs in the indentation (difftest seed 5129)
    local out = ox.export_as("org", { "1.", "-", " 3.", "  -", "   (paren) Review" }, { body_only = true })
    has(out, "\n        (paren) Review")
    local parity = require("tests.emacs_parity")
    local e, o = parity.normalise(
      "export",
      { "\t(paren) Review", "   \t x" },
      { "        (paren) Review", "         x" }
    )
    eq(e, o)
  end)

  it("Org export keeps a sub-list under an item with only a checkbox", function()
    -- the item's pre-blank counts lines from the bullet line
    -- (org-element-item-parser), so the contents start on a new line
    local out = ox.export_as("org", { "- [X]", "  - [-] a", "  - [ ] b", "-", "", "  text" }, { body_only = true })
    eq("- [-] \n  - [-] a\n  - [ ] b\n- \n\n  text\n", out)
  end)

  it("Org export aligns headline tags by characters, as Emacs's interpreter", function()
    -- org-element-headline-interpreter counts (length heading)
    local out = ox.export_as("org", { "* 日本語 title :work:", "* Emoji 🎉 :x:" }, { body_only = true })
    local lines = vim.split(out, "\n")
    eq(77, vim.fn.strchars(lines[1]))
    eq(77, vim.fn.strchars(lines[2]))
    ok(lines[1]:match("^%* 日本語 title +:work:$"), lines[1])
  end)

  it("a block holding only a blank line has an empty box (ASCII) or quote (Markdown)", function()
    -- org-ascii--box-string and org-md-quote-block replace "^" in an
    -- empty string: nothing
    local lines = { "#+begin_example", "", "#+end_example", "", "#+begin_quote", "", "#+end_quote", "", "End." }
    eq(",----\n\n`----\n\n\n\nEnd.\n", (ox.export_as("ascii", lines, { body_only = true })))
    local md = ox.export_as("md", lines, { body_only = true })
    hasnt(md, ">")
  end)

  it("an ASCII box leaves an empty last line unprefixed only after an empty line", function()
    -- replace-regexp-in-string "^" stops once an empty match reaches the
    -- end of the string (difftest seeds 44, 62)
    local function box(body)
      local lines = { "#+begin_src" }
      vim.list_extend(lines, body)
      lines[#lines + 1] = "#+end_src"
      return (ox.export_as("ascii", lines, { body_only = true }))
    end
    eq(",----\n| \n\n`----\n", box({ "", "" }))
    eq(",----\n| x\n| \n`----\n", box({ "x", "" }))
    eq(",----\n| x\n| \n\n`----\n", box({ "x", "", "" }))
  end)

  it("a timestamp keeps a habit's repeater deadline (.+2d/4d)", function()
    local out = ox.export_as("ascii", { "Text <2026-10-01 Thu .+2d/4d> and [2026-10-01 Thu +1d/3d -2d]." }, {
      body_only = true,
    })
    has(out, "<2026-10-01 Thu .+2d/4d>")
    has(out, "[2026-10-01 Thu +1d/3d -2d]")
  end)

  it("a property drawer without :END: is text, its CUSTOM_ID unused", function()
    local out = html({ "* H1", ":PROPERTIES:", ":CUSTOM_ID: foo", "Text after." })
    hasnt(out, 'id="foo"')
    has(out, ":PROPERTIES:\n:CUSTOM<sub>ID</sub>: foo\nText after.")
  end)

  it("an item with an empty tag (- :: text) is a plain item", function()
    local out = html({ "- alpha :: one", "- :: two", "", "Para.", "", "- [ ] :: five", "- gamma :: six" })
    has(out, "<dt>(no term)</dt><dd>:: two</dd>")
    has(out, '<li class="off"><code>[&nbsp;]</code> :: five</li>')
  end)

  it("macros are replaced in the text before it is parsed", function()
    -- org-macro-replace-all: {{{title}}} without #+title expands to
    -- nothing, which empties a line (two paragraphs), stops a line
    -- continuing a list item, empties a description tag and drops the
    -- space it leaves at the end of a headline
    local out = ox.export_as("org", {
      "* Head {{{title}}}",
      "First line",
      "{{{title}}}",
      "second para.",
      "",
      "- item one",
      "{{{title}}} continues",
      "- {{{title}}} :: tag gone",
      "",
      "=verbatim {{{title}}}= stays, {{{title}}} goes.",
      "#+begin_src emacs-lisp",
      "{{{nothing}}}",
      "#+end_src",
    }, { body_only = true })
    eq(
      table.concat({
        "* Head",
        "First line",
        "",
        "second para.",
        "",
        "- item one",
        "  continues",
        "- :: tag gone",
        "",
        "=verbatim {{{title}}}= stays,  goes.",
        "#+begin_src emacs-lisp",
        "  {{{nothing}}}",
        "#+end_src",
        "",
      }, "\n"),
      out
    )
  end)

  it("macros of a caption or a title are replaced before the value is trimmed", function()
    -- difftest seed 20231
    local out = ox.export_as("org", {
      "#+CAPTION: A alpha {{{title}}}",
      ",*",
      "",
      "#+CAPTION[{{{title}}} short]: {{{title}}} Long =v {{{title}}}=",
      "| a |",
    }, { body_only = true })
    has(out, "#+caption: A alpha\n")
    has(out, "#+caption[ short]: Long =v {{{title}}}=\n")
    local full = html({ "#+TITLE: Doc {{{author}}}", "x" }, { body_only = false })
    has(full, "<title>Doc</title>")
  end)

  it("a paragraph's indentation ignores unindented lines starting with an object", function()
    -- org-element-normalize-contents (difftest seed 120106)
    local out = ox.export_as("org", { " plain gamma", "src_python{1+1}", "", " plain", "next" }, { body_only = true })
    eq("plain gamma\nsrc_python{1+1}\n\n plain\nnext\n", out)
  end)

  it("a macro's value is parsed with the text around it", function()
    local out = html({ "#+MACRO: item - $1", "{{{item(one)}}}", "{{{item(two)}}}" })
    has(out, '<ul class="org-ul">\n<li>one</li>\n<li>two</li>\n</ul>')
  end)

  it("a footnote label defined twice exports its last definition", function()
    -- org-export-get-footnote-definition fills its cache with puthash
    local out = ox.export_as("ascii", {
      "* A",
      "Text[fn:1] and[fn:x].",
      "",
      "[fn:1] First def.",
      "",
      "[fn:x] X one.",
      "* B",
      "[fn:1] Second def.",
      "",
      "[fn:x] X two.",
    }, { body_only = true })
    has(out, "[1] Second def.")
    has(out, "[2] X two.")
    hasnt(out, "First def.")
  end)

  it("a date range whose end has no time takes the start's time", function()
    -- org-element-timestamp-parser: hour-end defaults to hour-start (the
    -- two spaces after a timestamp are Emacs's too)
    local out = ox.export_as(
      "org",
      { "<2026-10-01 Thu 17:30>--<2026-10-03 Sat> <2026-10-01 Thu>--<2026-10-03 Sat 10:00>" },
      {
        body_only = true,
      }
    )
    eq("<2026-10-01 Thu 17:30>--<2026-10-03 Sat 17:30>  <2026-10-01 Thu>--<2026-10-03 Sat 10:00>\n", out)
  end)
end)

describe("export: {{{n}}} counters in keywords follow the document (Emacs 9.8.10)", function()
  -- org-macro-replace-all walks the widened buffer in order and replaces
  -- the macros of the back-end's parsed keywords (TITLE, AUTHOR, DATE,
  -- SUBTITLE, and DESCRIPTION / KEYWORDS in LaTeX) where they are
  local doc = {
    "#+TITLE: T{{{n}}}",
    "#+SUBTITLE: S{{{n}}}",
    "#+AUTHOR: A{{{n}}}",
    "#+OPTIONS: toc:nil num:nil",
    "",
    "Intro {{{n}}} {{{n(fig)}}}",
    "",
    "* H{{{n}}}",
    "Body {{{n}}} {{{n(fig)}}} title is {{{title}}}",
    "",
    "#+DATE: D{{{n}}} {{{n(fig,-)}}}",
    "#+DESCRIPTION: X{{{n}}}",
    "#+KEYWORDS: K{{{n}}}",
    "",
    "After {{{n}}} {{{n(fig,10)}}} {{{n(fig)}}}",
  }

  local function has(s, sub)
    ok(s:find(sub, 1, true), "missing: " .. sub .. "\n---\n" .. s)
  end

  it("ascii: the title block numbered before the body", function()
    local out = ox.export_as("ascii", doc, {})
    for _, s in ipairs({ " T1\n", " S2\n", " A3\n", " D8 2\n", "Intro 4 1\n", "H5\n" }) do
      has(out, s)
    end
    -- {{{title}}} is the raw #+TITLE value, whose {{{n}}} is replaced there
    has(out, "Body 6 2 title is T7\n")
    has(out, "After 9 10 11\n")
  end)

  it("html: DESCRIPTION and KEYWORDS are not parsed, their macros stay", function()
    local out = ox.export_as("html", doc, {})
    has(out, "<title>T1</title>")
    has(out, '<meta name="author" content="A3" />')
    has(out, '<meta name="description" content="X{{{n}}}" />')
    has(out, '<span class="subtitle">S2</span>')
    has(out, "After 9 10 11")
  end)

  it("latex: DESCRIPTION and KEYWORDS are parsed and counted", function()
    local out = ox.export_as("latex", doc, {})
    has(out, "\\author{A3}")
    has(out, "\\date{D8 2}")
    has(out, "\\title{T1\\\\\\medskip\n\\large S2}")
    has(out, "pdfkeywords={K10}")
    has(out, "pdfsubject={X9}")
    has(out, "After 11 10 11")
  end)

  it("org: no SUBTITLE, its macro stays", function()
    local out = ox.export_as("org", doc, {})
    has(out, "#+title: T1\n#+date: D7 2\n#+author: A2\n#+subtitle: S{{{n}}}\n")
    has(out, "Intro 3 1\n* H4\nBody 5 2 title is T6\n")
    has(out, "After 8 10 11")
  end)

  it("md (body only): the counters the keywords took are skipped", function()
    has(
      (ox.export_as("md", doc, { body_only = true })),
      "Intro 4 1\n\n\n# H5\n\nBody 6 2 title is T7\n\nAfter 9 10 11\n"
    )
  end)

  it("a subtree export counts the text around it, and its EXPORT_ properties", function()
    local lines = {
      "#+TITLE: T{{{n}}}",
      "#+OPTIONS: toc:nil num:nil",
      "",
      "Intro {{{n}}}",
      "",
      "* First {{{n}}}",
      "One {{{n}}}",
      "",
      "* Second {{{n}}}",
      ":PROPERTIES:",
      ":EXPORT_AUTHOR: PA{{{n}}}",
      ":END:",
      "Two {{{n}}}",
      "",
      "#+SUBTITLE: S{{{n}}}",
      "",
      "* Third {{{n}}}",
      "#+DATE: D{{{n}}}",
      "Three {{{n}}}",
    }
    local out = ox.export_as("latex", lines, { subtree_line = 9 })
    has(out, "\\author{PA6}")
    has(out, "\\date{D10}")
    has(out, "\\title{Second 5\\\\\\medskip\n\\large S8}")
    has(out, "Two 7\n")
    out = ox.export_as("ascii", lines, {})
    for _, s in ipairs({ " T1\n", " S8\n", " D10\n", "Intro 2\n", "First 3\n", "One 4\n", "Two 7\n", "Three 11\n" }) do
      has(out, s)
    end
  end)

  it("macros in a keyword's macro, commented trees and example blocks", function()
    local out = ox.export_as("ascii", {
      "#+OPTIONS: toc:nil num:nil",
      "#+MACRO: two {{{n(x)}}}-{{{n(x)}}}",
      "",
      "First {{{n(x)}}} kw {{{keyword(TITLE)}}}",
      "",
      "#+TITLE: Title {{{two}}} {{{n}}}",
      "#+AUTHOR: {{{n(x,-)}}} and {{{n(x,5)}}}",
      "",
      "* COMMENT Hidden",
      "#+DATE: hidden {{{n}}}",
      "Hidden {{{n}}}",
      "",
      "* Visible",
      "After {{{n(x)}}} {{{n}}} title {{{title}}}",
      "",
      "#+begin_quote",
      "#+SUBTITLE: Sub {{{n}}}",
      "#+end_quote",
      "",
      "#+begin_example",
      "#+DATE: Ex {{{n}}}",
      "#+end_example",
    }, {})
    for _, s in ipairs({ " TITLE 4-5 2\n", " Sub 5\n", " 5 and 5\n", "First 1 kw Title 2-3 1\n" }) do
      has(out, s)
    end
    has(out, "After 6 3 title Title 7-8 4\n")
    has(out, "| #+DATE: Ex {{{n}}}\n")
  end)
end)

describe("export: id: links to another file (Emacs 9.8.10)", function()
  -- org-export-resolve-id-link gives the other file's name; each back-end
  -- links to that file. org.nvim used to abort with "Unable to resolve link".
  local dir
  before_each(function()
    dir = tmpdir()
    local other = {
      "* Other heading",
      ":PROPERTIES:",
      ":ID: hunt9-abc",
      ":END:",
      "** Sub other",
      ":PROPERTIES:",
      ":ID: hunt9-def",
      ":END:",
    }
    vim.fn.writefile(other, dir .. "/other.org")
    require("org.id").register_lines(other, dir .. "/other.org")
  end)

  local function exp(backend)
    pcall(require, "org.export.odt")
    return (
      ox.export_as(
        backend,
        -- texinfo exports nothing before the first heading (Emacs too)
        { "* Local", "See [[id:hunt9-abc][an id]] and [[id:hunt9-abc]] and [[id:hunt9-def]]." },
        { filename = dir .. "/a.org", body_only = true }
      )
    )
  end

  it("html", function()
    has(
      exp("html"),
      'See <a href="other.html#ID-hunt9-abc">an id</a> and <a href="other.html#ID-hunt9-abc">other.org</a>'
        .. ' and <a href="other.html#ID-hunt9-def">other.org</a>.'
    )
  end)

  it("latex", function()
    has(exp("latex"), "See \\href{other.org}{an id} and \\url{other.org} and \\url{other.org}.")
  end)

  it("md", function()
    has(exp("md"), "See [an id](other.md) and <other.md> and <other.md>.")
  end)

  it("ascii", function()
    local out = exp("ascii")
    has(out, "See [an id] and other.org and other.org.")
    has(out, "[an id] See file other.org")
  end)

  it("texinfo", function()
    has(exp("texinfo"), "See @uref{file://other.org,an id} and @uref{file://other.org} and @uref{file://other.org}.")
  end)

  it("odt", function()
    has(
      exp("odt"),
      'See <text:a xlink:type="simple" xlink:href="../other.org">an id</text:a> and '
        .. '<text:a xlink:type="simple" xlink:href="../other.org">../other.org</text:a>'
    )
  end)
end)

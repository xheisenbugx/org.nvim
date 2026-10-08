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

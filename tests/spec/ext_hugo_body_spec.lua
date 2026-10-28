-- The hugo extension's Markdown for the body of a post (ox-hugo's
-- blackfriday transcoders): tables, verse, center and quote blocks, lists,
-- targets, example and fixed-width blocks, snippets, the table of
-- contents, MathJax, info: links, references to named elements, drawers,
-- section numbers and the :prefix commands.
local set_tz = require("org.date").set_tz

local dir, saved_tz

local function hugo()
  return require("org.extensions.hugo.export")
end

--- The Markdown of `lines` as one post.
local function md(lines)
  local path = dir .. "/post.org"
  vim.fn.writefile(vim.list_extend({ "#+title: T", "#+author:" }, lines), path)
  vim.cmd("silent edit! " .. vim.fn.fnameescape(path))
  vim.cmd("filetype plugin off")
  local buf = hugo().export_as_buffer({ hidden = true })
  vim.cmd("filetype plugin on")
  ok(buf, "exported")
  local text = table.concat(buf_lines(buf), "\n")
  vim.api.nvim_buf_delete(buf, { force = true })
  return text
end

local function has(text, fragment)
  ok(text:find(fragment, 1, true), "no " .. vim.inspect(fragment) .. " in:\n" .. text)
end

describe("hugo body", function()
  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    saved_tz = vim.env.TZ
    set_tz(tz("UTC"))
    require("org").setup({ export = { author = false }, extensions = { hugo = true } })
  end)
  after_each(function()
    vim.cmd("silent! %bwipeout!")
    set_tz(saved_tz)
    vim.fn.delete(dir, "rf")
    require("org").setup({})
  end)

  it("writes tables with alignment cookies, escaped pipes, captions and one-row tables", function()
    local text = md({
      "#+name: tbl-sizes",
      "#+caption: Sizes",
      "| Name | Size |",
      "| <l>  |  <r> |",
      "|------+------|",
      "| a\\vert{}b | 1 |",
      "| c    |   22 |",
      "",
      "| only | row |",
      "",
      "See [[tbl-sizes]].",
    })
    has(text, "| Name     | Size |\n|:---------|-----:|\n| a&vert;b | 1    |")
    has(text, '<span class="table-number">')
    has(text, "Sizes")
    -- a one-row table gets an empty header
    has(text, "| only | row |")
    ok(text:find("|%s+|%s+|\n|[-:]+|[-:]+|\n| only | row |"), text)
    has(text, "(#table--tbl-sizes)")
  end)

  it("writes verse and center blocks as HTML", function()
    local text = md({
      "#+begin_verse",
      "Roses are red,",
      "   violets are blue.",
      "#+end_verse",
      "",
      "#+begin_center",
      "In the middle",
      "#+end_center",
    })
    has(text, '<div class="verse">')
    has(text, "Roses are red,<br />")
    has(text, "&nbsp;&nbsp;&nbsp;violets are blue.")
    has(text, '<div class="org-center">')
    has(text, "In the middle")
  end)

  it("separates consecutive quote blocks and lists", function()
    local text = md({
      "#+begin_quote",
      "One",
      "#+end_quote",
      "#+begin_quote",
      "Two",
      "#+end_quote",
      "",
      "- a",
      "- b",
      "",
      "",
      "1. one",
      "2. two",
    })
    has(text, "> One\n\n<!--quoteend-->")
    has(text, "> Two")
    has(text, "<!--listend-->")
    has(text, "1.  one")
  end)

  it("writes descriptive lists, checkboxes and nested descriptions", function()
    local text = md({
      "- Term :: the meaning",
      "- Other :: more",
      "",
      "",
      "- [X] done",
      "- [-] partly",
      "- [ ] todo",
      "",
      "",
      "- item",
      "  - Inner :: nested",
    })
    has(text, "Term\n: the meaning")
    has(text, "-   [X] done")
    has(text, "-   [-] partly")
    has(text, "-   [ ] todo")
    has(text, "**Inner:** nested")
  end)

  it("writes targets, radio targets and links to them", function()
    local text = md({ "A <<here>> target and <<<Radio>>> one.", "", "Back [[here][to it]] and Radio again." })
    has(text, '<span class="org-target" id="org-target--here"></span>')
    has(text, '<span class="org-radio" id="org-radio--Radio">Radio</span>')
    has(text, "[to it](#org-target--here)")
    has(text, "[Radio](#org-radio--Radio)")
  end)

  it("writes example, fixed-width and inline source code", function()
    local text = md({
      "#+begin_example",
      "plain text",
      "#+end_example",
      "",
      ": fixed width",
      "",
      -- (an inline block exports its results by default)
      "Inline src_python[:exports code]{print(1)} code.",
    })
    has(text, "```text\nplain text\n```")
    has(text, "```text\nfixed width\n```")
    has(text, '<span class="inline-src language-python" data-lang="python">`print(1)`</span>')
  end)

  it("keeps hugo snippets and blocks, and other back-ends' through HTML", function()
    local text = md({
      "A @@hugo:{{< kbd >}}@@ and @@html:<b>bold</b>@@ snippet.",
      "",
      "#+begin_export hugo",
      "  {{< youtube id >}}",
      "#+end_export",
      "",
      "#+begin_export latex",
      "\\LaTeX only",
      "#+end_export",
    })
    has(text, "A {{< kbd >}} and <b>bold</b> snippet.")
    has(text, "{{< youtube id >}}")
    eq(nil, text:find("LaTeX only", 1, true))
  end)

  it("writes a table of contents with #+toc, numbered with num:t", function()
    local text = md({
      "#+options: num:t toc:nil",
      "#+toc: headlines 2",
      "",
      "* First",
      "** Sub",
      "* Second",
    })
    has(text, '<div class="ox-hugo-toc toc has-section-numbers">')
    has(text, '<span class="section-num">1</span> [First](#first)')
    has(text, '    - <span class="section-num">1.1</span> [Sub](#sub)')
    has(text, "<!--endtoc-->")
  end)

  it("writes LaTeX for MathJax, escaping Markdown in it", function()
    local text = md({ "#+options: tex:t", "", "Inline $a_1 * b$ and \\(x^2\\).", "", "$$e = mc^2$$" })
    has(text, "\\\\(a\\_1 \\* b\\\\)")
    has(text, "\\\\(x^2\\\\)")
    has(text, "\\\\[e = mc^2\\\\]")
  end)

  it("links info: manuals to their pages on the web", function()
    local text = md({ "[[info:org#Tags]] and [[info:emacs#Dired][Dired]] and [[info:make]]." })
    has(text, "(https://orgmode.org/manual/Tags.html")
    has(text, "[Dired](https://www.gnu.org/software/emacs/manual/html_node/emacs/Dired.html")
    has(text, "(https://www.gnu.org/software/make/manual/html_node/index.html")
  end)

  it("leaves out LOGBOOK drawers and keeps others", function()
    local text = md({
      "#+options: d:t",
      "* Task",
      ":LOGBOOK:",
      "- Note taken on [2026-01-01 Thu 10:00]",
      ":END:",
      ":NOTES:",
      "Kept text",
      ":END:",
    })
    eq(nil, text:find("Note taken", 1, true))
    has(text, "Kept text")
  end)

  it("puts a heading's HTML_CONTAINER around its section", function()
    local text = md({ "* Boxed", ":PROPERTIES:", ":HTML_CONTAINER: section", ":END:", "Inside." })
    has(text, "<section")
    has(text, "Inside.")
  end)

  it("runs :Org hugo with its arguments, needing a base dir, and rejects unknown ones", function()
    local path = dir .. "/c.org"
    vim.fn.writefile({ "#+title: C", "#+author:", "", "Text." }, path)
    vim.cmd("silent edit! " .. vim.fn.fnameescape(path))
    local u = require("org.utils")
    local saved = { u.notify, u.warn, u.error }
    local msgs = {}
    u.notify = function(m)
      msgs[#msgs + 1] = m
    end
    u.warn, u.error = u.notify, u.notify
    local ext = require("org.extensions.hugo")
    pcall(ext.command, "nonsense")
    pcall(ext.command, "wim")
    pcall(ext.command, "all")
    pcall(ext.command, "file")
    u.notify, u.warn, u.error = saved[1], saved[2], saved[3]
    local all = table.concat(msgs, "\n")
    ok(all:find("Usage: :Org hugo", 1, true), all)
    -- no base dir: each export says so instead of writing anywhere
    local _, n = all:gsub("HUGO_BASE_DIR", "")
    eq(3, n)
  end)
end)

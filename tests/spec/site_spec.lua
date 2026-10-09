-- The documentation website generator (scripts/site/): vimdoc and Markdown
-- to HTML, and a full build whose link check must pass.
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
package.path = root .. "/scripts/?.lua;" .. package.path
local html = require("site.html")
local vimdoc = require("site.vimdoc")
local markdown = require("site.markdown")
local outdir = require("site.outdir")

local function has(haystack, needle)
  if not haystack:find(needle, 1, true) then
    error(string.format("expected to find\n  %s\nin\n%s", needle, haystack), 2)
  end
end

local function render(lines, tags)
  local set = {}
  for _, t in ipairs(tags or vimdoc.tags(lines)) do
    set[t] = true
  end
  local seen = {}
  local out = vimdoc.render(lines, {
    title = "Test",
    tags = set,
    slugs = {},
    link = function(tag)
      if set[tag] then
        return "#" .. tag
      elseif tag == "'foldmethod'" then
        return "https://neovim.io/doc/user/helptag.html?tag=" .. html.urlencode(tag)
      end
    end,
    on_tag = function(tag)
      seen[#seen + 1] = tag
    end,
  })
  return out, seen
end

describe("site", function()
  describe("vimdoc", function()
    it("finds the same tags in doc/org.txt as :helptags", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      vim.fn.writefile(vim.fn.readfile(root .. "/doc/org.txt"), dir .. "/org.txt")
      -- in a clean Neovim: newer ones read tags with the vimdoc parser,
      -- which the test runtimepath leaves out
      vim
        .system({ vim.v.progpath, "--headless", "--clean", "-c", "helptags " .. vim.fn.fnameescape(dir), "-c", "qa!" })
        :wait(60000)
      local want = {}
      for _, l in ipairs(vim.fn.readfile(dir .. "/tags")) do
        want[#want + 1] = l:match("^[^\t]+")
      end
      vim.fn.delete(dir, "rf")
      local doc = vim.fn.readfile(root .. "/doc/org.txt")
      local got = vimdoc.tags(doc)
      -- Neovim 0.11 also reads tags inside `code`, the vimdoc parser doesn't
      local text = table.concat(doc, "\n")
      want = vim.tbl_filter(function(t)
        return vim.tbl_contains(got, t) or not text:find("`[^`\n]*%*" .. vim.pesc(t) .. "%*[^`\n]*`")
      end, want)
      table.sort(want)
      table.sort(got)
      eq(want, got)
    end)

    it("turns tags into anchors and links into hyperlinks", function()
      local out, seen = render({
        "Folding                                             *t-fold* *t-cycle*",
        "",
        "See |t-fold| and |'foldmethod'|, and `zc` with <Tab>.",
      })
      has(out, '<a class="tag" id="t-fold" href="#t-fold">t-fold</a>')
      has(out, '<div class="tags">')
      has(out, '<a class="hl" href="#t-fold">t-fold</a>')
      has(out, 'href="https://neovim.io/doc/user/helptag.html?tag=%27foldmethod%27"')
      has(out, "<code>zc</code>")
      has(out, '<span class="key">&lt;Tab&gt;</span>')
      eq({ "t-fold", "t-cycle" }, seen)
    end)

    it("doesn't link the alternatives of a|b|c or unknown tags", function()
      local out = render({ "  :results   replace|append|silent", "", "Use |nowhere| here." }, {})
      ok(not out:find("<a", 1, true))
      has(out, "replace|append|silent")
      has(out, '<span class="hl">nowhere</span>')
    end)

    it("highlights code blocks and ends them at < or column 0", function()
      local out = render({
        "Set it up: >sh",
        '    nvim -u init.lua "$FILE" # hi',
        "<",
        "After.",
        "Org: >org",
        "    * TODO Task :work:",
        "Next paragraph.",
      })
      has(out, "<p>Set it up:</p>")
      has(out, '<pre class="code"><code class="language-sh"><span class="h-f">nvim</span>')
      has(out, '<span class="h-c"># hi</span>')
      has(out, '<span class="h-s">&quot;$FILE&quot;</span>')
      has(out, "<p>After. Org:</p>")
      has(out, '<span class="h-k">TODO</span>')
      has(out, '<span class="h-t">:work:</span>')
      has(out, "<p>Next paragraph.</p>")
    end)

    it("renders headings, prose, lists and aligned text", function()
      local out = render({
        "Stability ~",
        "Flowing text that",
        "wraps over `two",
        "lines` here.",
        "",
        "  - one item",
        "    continued",
        "  - two",
        "",
        "  `width`    40",
        "  `height`   10",
      })
      has(out, '<h3 id="h-stability">Stability</h3>')
      has(out, "<p>Flowing text that wraps over <code>two lines</code> here.</p>")
      has(out, "<ul>\n<li>one item continued</li>\n<li>two</li>\n</ul>")
      has(out, '<table class="defs">\n<tr><td class="term"><code>width</code></td><td>40</td></tr>')
      has(out, '<tr><td class="term"><code>height</code></td><td>10</td></tr>\n</table>')
    end)

    it("turns aligned keys and options into tables", function()
      local out = render({
        "Keys:",
        "  <C-c>a         agenda; continued",
        "                 on the next line",
        "  f / b / .      later / earlier / today",
        "  <C-x><C-c><BS> one space at the column",
        "  `hidden`   backticks do not count",
        "  long term alone",
        "                its description",
        "Prose after.",
      })
      has(out, "<p>Keys:</p>")
      has(out, '<td class="term"><span class="key">&lt;C-c&gt;</span>a</td><td>agenda; continued on the next line</td>')
      has(out, '<td class="term">f / b / .</td><td>later / earlier / today</td>')
      has(out, "<td>one space at the column</td>")
      has(out, '<td class="term"><code>hidden</code></td><td>backticks do not count</td>')
      has(out, '<td class="term">long term alone</td><td>its description</td>')
      has(out, "<p>Prose after.</p>")
      ok(not out:find("<pre", 1, true))
    end)

    it("gives option tables a column for the value", function()
      local out = render({
        '  org_directory             "~/org"   base for relative paths',
        "  agenda_files              {}        files, dirs, globs,",
        "                                      or a file listing them",
        '  win_border                "rounded"',
        "  startup_shrink_all_tables false     one space before the value",
      })
      has(out, '<table class="defs defs3">')
      has(out, '<td class="value"><code>&quot;~/org&quot;</code></td><td>base for relative paths</td>')
      has(out, "<td>files, dirs, globs, or a file listing them</td>")
      has(
        out,
        '<td class="term long">startup_<wbr>shrink_<wbr>all_<wbr>tables</td><td class="value"><code>false</code></td>'
      )
    end)

    it("merges the second key of a command into the first", function()
      local out = render({
        "<prefix>id      Insert a drawer at the cursor (Insert mode splits the line,",
        "<C-c><C-x>d     like Emacs), or around the Visual selection.",
        "<prefix>ib      Insert a template.",
      })
      has(out, '<span class="key">&lt;C-c&gt;</span><span class="key">&lt;C-x&gt;</span>d</td>')
      has(out, "splits the line, like Emacs), or around the Visual selection.</td>")
      local _, rows = out:gsub("<tr>", "")
      eq(2, rows)
    end)

    it("renders a header row over columns as a grid", function()
      local out = render({
        "                    native   snacks",
        "  in place          yes      yes (5)",
        "  under the link    yes      no",
      })
      has(out, '<table class="grid">')
      has(out, "<th>native</th>\n<th>snacks</th>")
      has(out, "<tr><td>in place</td><td>yes</td><td>yes (5)</td></tr>")
    end)

    it("reads text after the < that ends a code block", function()
      local out = render({ "Code: >lua", "    x = 1", "<then more text.", "  vim:tw=78:ts=8:ft=help:norl:" })
      has(out, "<p>then more text.</p>")
      ok(not out:find("vim:tw", 1, true))
    end)

    it("splits chapters at ==== and sections at ----", function()
      local rule = string.rep("=", 78)
      local thin = string.rep("-", 78)
      local pages = vimdoc.split({
        "*x.txt*  X",
        rule,
        "CONTENTS                              *x-contents*",
        "  1. First ............ |x-first|",
        rule,
        "1. FIRST                                  *x-first*",
        "Text. >",
        "    " .. rule,
        "<",
        thin,
        "A section                                 *x-sec*",
        "More.",
      })
      eq(
        { "index", "x-first", "x-sec" },
        vim.tbl_map(function(p)
          return p.name
        end, pages)
      )
      eq("First", pages[2].title)
      eq("A section", pages[3].title)
      eq("x-first", pages[3].parent)
      -- a rule inside a code block doesn't split
      eq(4, #pages[2].lines)
    end)
  end)

  describe("markdown", function()
    it("renders GitHub-flavoured Markdown", function()
      local headings = {}
      local out = markdown.render({
        "## ⚡ Install in 30 seconds",
        "",
        "Some **bold**, *em*, `code` and a [link](doc/org.txt#x).",
        "",
        "```sh",
        "make site # build",
        "```",
        "",
        "| A | B |",
        "| --- | ---: |",
        "| `a\\|b` | 2 |",
        "",
        "- one",
        "  - nested",
        "- two",
        "",
        "> [!TIP]",
        "> Be careful.",
        "",
        '<img src="logo.png" width="9">',
      }, {
        link = function(href)
          return "/site/" .. href
        end,
        rewrite_html = function(tag)
          return (tag:gsub('src="', 'src="/media/'))
        end,
        on_heading = function(id)
          headings[#headings + 1] = id
        end,
      })
      eq({ "-install-in-30-seconds" }, headings)
      has(out, '<h2 id="-install-in-30-seconds">⚡ Install in 30 seconds</h2>')
      has(out, "<strong>bold</strong>, <em>em</em>, <code>code</code>")
      has(out, '<a href="/site/doc/org.txt#x">link</a>')
      has(out, '<code class="language-sh"><span class="h-f">make</span> site <span class="h-c"># build</span>')
      has(out, '<th style="text-align:right">B</th>')
      has(out, "<td><code>a|b</code></td>")
      has(out, "<li>one\n<ul>\n<li>nested</li>\n</ul></li>")
      has(out, '<div class="alert alert-tip"><p class="alert-title">Tip</p><p>Be careful.</p></div>')
      has(out, '<img src="/media/logo.png" width="9">')
    end)

    it("makes GitHub's heading slugs", function()
      local seen = {}
      eq("-a-quick-tour", html.slug("🎬 A quick tour", seen))
      eq("faq", html.slug("FAQ", seen))
      eq("faq-1", html.slug("FAQ", seen))
      eq("orgnvim-vs-emacs", html.slug("org.nvim vs. Emacs!", seen))
    end)
  end)

  -- A build empties its output directory. Only throwaway trees here: a
  -- fake checkout (with a .git) in a temp directory stands for the
  -- repository, so a broken check can only empty those.
  describe("output directory", function()
    local base, repo
    local function write(path, text)
      vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
      vim.fn.writefile({ text or "x" }, path)
    end
    local function exists(path)
      return vim.uv.fs_lstat(path) ~= nil
    end
    --- The files of the fake checkout and its neighbours are all there.
    local function intact()
      for _, p in ipairs({ repo .. "/.git/HEAD", repo .. "/notes.org", base .. "/parent/sibling/keep.txt" }) do
        ok(exists(p), p .. " was deleted")
      end
    end
    local function refused(arg, why)
      local dir, msg = outdir.check(arg, repo)
      eq(nil, dir, vim.inspect(arg))
      ok(msg and msg:find(why, 1, true), vim.inspect(arg) .. ": " .. tostring(msg))
      -- and preparing it changes nothing
      dir, msg = outdir.prepare(arg, repo)
      eq(nil, dir, vim.inspect(arg))
      ok(msg and msg:find(why, 1, true), vim.inspect(arg) .. ": " .. tostring(msg))
      intact()
    end
    before_each(function()
      base = vim.fn.tempname()
      repo = base .. "/parent/repo"
      write(repo .. "/.git/HEAD", "ref: refs/heads/main")
      write(repo .. "/notes.org", "* uncommitted work")
      write(base .. "/parent/sibling/keep.txt")
    end)
    after_each(function()
      vim.fn.delete(base, "rf")
    end)

    it("refuses an empty argument, the checkout and what contains it", function()
      refused("", "no output directory")
      refused("  ", "no output directory")
      refused(".", "the repository itself")
      refused("./", "the repository itself")
      refused("site/..", "the repository itself")
      refused(repo, "the repository itself")
      refused(repo .. "/", "the repository itself")
      refused("..", "the repository is inside it")
      refused("../..", "the repository is inside it")
      refused(base, "the repository is inside it")
    end)

    it("refuses a repository, a file and a directory a build didn't make", function()
      write(base .. "/other/.git", "gitdir: elsewhere")
      refused(base .. "/other", "holds a .git")
      refused("notes.org", "not a directory")
      refused("../sibling", "no site build made it")
      ok(exists(base .. "/parent/sibling/keep.txt"))
      if vim.fn.has("win32") == 0 then
        -- a link to the checkout is the checkout
        vim.uv.fs_symlink(repo, base .. "/link")
        refused(base .. "/link", "the repository itself")
      end
    end)

    it("creates a new directory, takes an empty one and empties its own", function()
      local real = vim.fs.normalize(vim.uv.fs_realpath(repo))
      eq(real .. "/site", outdir.check("site", repo))
      local dir = outdir.prepare("site", repo)
      eq(real .. "/site", dir)
      ok(exists(dir .. "/" .. outdir.MARKER))
      write(dir .. "/manual/old.html")
      eq(dir, outdir.prepare(dir, repo))
      ok(not exists(dir .. "/manual"))
      ok(exists(dir .. "/" .. outdir.MARKER))
      vim.fn.mkdir(base .. "/empty", "p")
      ok(outdir.prepare(base .. "/empty", repo))
      ok(exists(base .. "/empty/" .. outdir.MARKER))
      intact()
    end)

    it("is checked by the builder before anything else", function()
      -- the builder's scripts in the fake checkout: their root is that one
      vim.fn.mkdir(repo .. "/scripts/site", "p")
      for _, f in ipairs(vim.fn.glob(root .. "/scripts/site/*.lua", false, true)) do
        vim.fn.writefile(vim.fn.readfile(f, "b"), repo .. "/scripts/site/" .. vim.fn.fnamemodify(f, ":t"), "b")
      end
      for _, arg in ipairs({ "", ".", "..", "notes.org" }) do
        local res = vim
          .system({ vim.v.progpath, "--headless", "--clean", "-l", repo .. "/scripts/site/build.lua", arg }, { text = true })
          :wait(60000)
        eq(2, res.code, vim.inspect(arg) .. ": " .. (res.stdout or "") .. (res.stderr or ""))
        ok((res.stderr or ""):find("site: ", 1, true), res.stderr)
        intact()
        ok(exists(repo .. "/scripts/site/build.lua"))
      end
    end)
  end)

  -- the build exports every example with org.nvim and checks every
  -- internal link and anchor; the site is only built on Linux
  if vim.fn.has("win32") == 0 then
    it("builds with no broken links", function()
      local out = vim.fn.tempname()
      local res = vim
        .system({ vim.v.progpath, "--headless", "--clean", "-l", root .. "/scripts/site/build.lua", out }, { text = true })
        :wait(120000)
      ok(res.code == 0, (res.stdout or "") .. (res.stderr or ""))
      ok(vim.uv.fs_stat(out .. "/manual/org-agenda.html"))
      ok(vim.uv.fs_stat(out .. "/examples/tutorial.html"))
      local index = table.concat(vim.fn.readfile(out .. "/index.html"), "\n")
      has(index, 'href="manual/index.html"')
      has(index, "https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/hero.gif")
      -- Lua blocks are highlighted with Neovim's tree-sitter parser
      local install = table.concat(vim.fn.readfile(out .. "/manual/org-installation.html"), "\n")
      has(install, '<code class="language-lua"><span class="h-')
      -- the playground: a player per tutor lesson, linked from the README
      local pg = table.concat(vim.fn.readfile(out .. "/playground.html"), "\n")
      has(pg, 'data-src="playground/basics.js"')
      has(pg, '<div class="pg-player" role="region" tabindex="0" aria-label="Recording of the basics lesson">')
      has(pg, '<script src="assets/playground.js" defer></script>')
      has(index, 'href="playground.html"')
      ok(vim.uv.fs_stat(out .. "/playground/workflow.cast"))
      vim.fn.delete(out, "rf")
    end)
  end
end)

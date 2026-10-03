-- The documentation website generator (scripts/site/): vimdoc and Markdown
-- to HTML, and a full build whose link check must pass.
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
package.path = root .. "/scripts/?.lua;" .. package.path
local html = require("site.html")
local vimdoc = require("site.vimdoc")
local markdown = require("site.markdown")

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
      has(out, '<pre class="help">  <code>width</code>    40\n  <code>height</code>   10</pre>')
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
      vim.fn.delete(out, "rf")
    end)
  end
end)

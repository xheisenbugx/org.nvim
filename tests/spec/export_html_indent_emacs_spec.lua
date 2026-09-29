-- org-html-indent: the fixtures are the output of Emacs Org 9.8.10
-- (org-export-string-as with org-html-indent t, Emacs 31.1 mhtml-mode).
local export = require("org.export")
local config = require("org.config")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local dir = root .. "/fixtures/export/indent"

local function read(name)
  return table.concat(vim.fn.readfile(dir .. "/" .. name), "\n") .. "\n"
end

local function norm(s)
  return (s:gsub("org%x%x%x%x%x%x%x", "orgID"))
end

describe("html indent (Emacs parity)", function()
  local saved
  before_each(function()
    saved = vim.deepcopy(config.opts.export)
    config.opts.babel.evaluate_on_export = false
    config.opts.export.html.indent = true
    config.opts.export.timestamp_file = false
  end)
  after_each(function()
    config.opts.export = saved
    config.opts.babel.evaluate_on_export = true
  end)

  it("indents an XHTML document like mhtml-mode (CSS and JS included)", function()
    local src = "#+title: T\n#+author: Tester\n* Head\nSome *bold* text $x$.\n- item\n  - sub\n\n#+begin_src sh\nif x; then\n    y\nfi\n#+end_src\n| a | b |\n|---+---|\n| 1 | 2 |\n#+begin_quote\nq\n#+end_quote\n: fixed\n<!-- c -->\n#+begin_verse\n  v1\n v2\n#+end_verse"
    local out = export.to_string("html", { lines = vim.split(src, "\n") })
    eq(norm(read("xhtml.emacs.html")), norm(out) .. "\n")
  end)

  it("indents an HTML5 document (void elements)", function()
    local h = config.opts.export.html
    h.doctype, h.html5_fancy, h.head_include_default_style, h.postamble = "html5", true, false, false
    config.opts.export.with_toc = false
    local src = "#+title: T\n#+author: Tester\n* Head\nSome text.\nLine two<br>\n- item\n\n[[./img.png]]\n| a |\n#+begin_quote\nq\n#+end_quote"
    local out = export.to_string("html", { lines = vim.split(src, "\n") })
    eq(norm(read("html5.emacs.html")), norm(out) .. "\n")
  end)

  it("gives a body-only fragment the first line's indentation (fundamental-mode)", function()
    local out = export.to_string("html", {
      lines = { "#+options: toc:nil", "Some *bold* text.", "- item", "  - sub", "", "#+begin_src sh", "if x; then", "    y", "fi", "#+end_src" },
      body_only = true,
    })
    -- Emacs: every line flush left, even inside <pre>
    eq(
      table.concat({
        "<p>",
        "Some <b>bold</b> text.",
        "</p>",
        '<ul class="org-ul">',
        "<li>item",
        '<ul class="org-ul">',
        "<li>sub</li>",
        "</ul></li>",
        "</ul>",
        "",
        '<div class="org-src-container">',
        '<pre class="src src-sh"><code>if x; then',
        "y",
        "fi",
        "</code></pre>",
        "</div>",
        "",
      }, "\n"),
      out
    )
  end)
end)

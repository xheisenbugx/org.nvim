-- #+BIND: keywords (org-export-allow-bind-keywords). Expected outputs were
-- produced by Emacs 31 / Org 9.8.10 in batch (org-export-as with
-- org-export-allow-bind-keywords t and org-export-with-author nil).
local ox = require("org.export.ox")
local bind = require("org.export.bind")
local config = require("org.config")

local function export(backend, lines, body_only)
  return (ox.export_as(backend, lines, { body_only = body_only }))
end

local function has(s, sub)
  ok(s:find(sub, 1, true), "missing: " .. sub .. "\n---\n" .. s)
end
local function hasnt(s, sub)
  ok(not s:find(sub, 1, true), "unexpected: " .. sub .. "\n---\n" .. s)
end

local doc = {
  "#+TITLE: Bound",
  "#+BIND: org-html-postamble nil",
  '#+BIND: org-html-preamble "<p>pre %t</p>"',
  '#+BIND: org-html-doctype "html5"',
  "#+BIND: org-html-head-include-default-style nil",
  "#+BIND: org-html-head-include-scripts nil",
  "#+BIND: org-export-with-toc nil",
  "#+BIND: org-export-with-section-numbers nil",
  '#+BIND: org-export-exclude-tags ("secret")',
  "#+BIND: org-html-checkbox-type unicode",
  "#+BIND: some-unknown-variable 42",
  "",
  "* One",
  "- [X] done",
  "* Hidden :secret:",
  "text",
}

describe("#+BIND:", function()
  local saved
  before_each(function()
    saved = vim.deepcopy(config.opts.export)
    config.opts.babel.evaluate_on_export = false
    config.opts.export.with_author = false
  end)
  after_each(function()
    config.opts.export = saved
  end)

  it("is ignored unless export.allow_bind_keywords is set", function()
    local html = export("html", doc)
    has(html, '<div id="postamble" class="status">')
    has(html, "table-of-contents")
    has(html, "Hidden")
  end)

  it("sets the export options of the bound variables, like Emacs", function()
    config.opts.export.allow_bind_keywords = true
    local html = export("html", doc)
    has(html, '<!DOCTYPE html>\n<html lang="en">\n<head>')
    has(html, '<div id="preamble" class="status">\n<p>pre Bound</p>\n</div>\n<div id="content" class="content">')
    has(html, '<h2 id="')
    has(html, '">One</h2>')
    has(html, '<li class="on">&#x2611; done</li>')
    has(html, "</div>\n</div>\n</body>\n</html>")
    hasnt(html, "postamble")
    hasnt(html, "table-of-contents")
    hasnt(html, "Hidden")
    hasnt(html, "<style")
    -- only for the export
    eq("auto", config.opts.export.html.postamble)
    eq(true, config.opts.export.with_toc)
  end)

  it("reads alists, lists and symbols", function()
    config.opts.export.allow_bind_keywords = true
    local html = export("html", {
      "#+TITLE: Fmt",
      "#+AUTHOR: Ann",
      "#+BIND: org-html-postamble t",
      '#+BIND: org-html-postamble-format (("en" "<p class=\\"a\\">by %a</p>"))',
      "#+BIND: org-html-preamble nil",
      "#+BIND: org-export-with-author t",
      "",
      "Text.",
    })
    has(
      html,
      table.concat({
        "<body>",
        '<div id="content" class="content">',
        '<h1 class="title">Fmt</h1>',
        "<p>",
        "Text.",
        "</p>",
        "</div>",
        '<div id="postamble" class="status">',
        '<p class="a">by Ann</p>',
        "</div>",
        "</body>",
        "</html>",
      }, "\n")
    )
    local lines = {
      "#+BIND: org-ascii-text-width 30",
      "#+BIND: org-ascii-global-margin 2",
      '#+BIND: org-export-with-drawers ("NOTES")',
      "#+BIND: org-export-with-sub-superscripts {}",
      "",
      "* Head",
      ":NOTES:",
      "kept drawer",
      ":END:",
      ":OTHER:",
      "hidden drawer",
      ":END:",
      "A paragraph that is long enough to be filled at thirty columns wide. a_b a_{c}",
    }
    eq(
      table.concat({
        "  1 Head",
        "  ======",
        "",
        "    kept drawer",
        "    A paragraph that is long",
        "    enough to be filled at",
        "    thirty columns wide. a_b",
        "    a_{c}",
      }, "\n"),
      (export("ascii", lines, true):gsub("^\n+", ""):gsub("%s+$", ""))
    )
    has(export("html", lines, true), "a_b a<sub>c</sub>")
  end)

  it("maps Emacs variables to options", function()
    eq({ "html", "postamble" }, bind.option_path("org-html-postamble"))
    eq({ "with_toc" }, bind.option_path("org-export-with-toc"))
    eq({ "latex", "default_packages" }, bind.option_path("org-latex-default-packages-alist"))
    eq({ "icalendar", "store_uid" }, bind.option_path("org-icalendar-store-UID"))
    eq({ "author" }, bind.option_path("user-full-name"))
    eq(nil, bind.option_path("fill-column"))
    eq(nil, bind.option_path("org-export-before-parsing-functions"))
    local b = bind.bindings({
      BIND = {
        "org-export-with-tags not-in-toc",
        'org-export-select-tags \'("pub" "web")',
        'org-export-with-drawers (not "LOGBOOK" "X")',
        'org-latex-packages-alist (("" "minted"))',
        "org-ascii-headline-spacing (1 . 2)",
        'org-export-global-macros (("hi" . "Hello $1"))',
        "unbalanced (",
        "org-texinfo-node-description-column 40.0",
      },
    })
    local got = {}
    for _, x in ipairs(b) do
      got[x.var] = x.value
    end
    eq("not-in-toc", got["org-export-with-tags"])
    eq({ "pub", "web" }, got["org-export-select-tags"])
    eq({ ["not"] = { "LOGBOOK", "X" } }, got["org-export-with-drawers"])
    eq({ { "", "minted" } }, got["org-latex-packages-alist"])
    eq({ 1, 2 }, got["org-ascii-headline-spacing"])
    eq({ hi = "Hello $1" }, got["org-export-global-macros"])
    eq(40, got["org-texinfo-node-description-column"])
    eq(7, #b)
  end)

  it("binds global macros", function()
    config.opts.export.allow_bind_keywords = true
    local out = export("ascii", {
      '#+BIND: org-export-global-macros (("hi" . "Hello $1"))',
      "",
      "{{{hi(you)}}}",
    }, true)
    eq("Hello you", vim.trim(out))
  end)
end)

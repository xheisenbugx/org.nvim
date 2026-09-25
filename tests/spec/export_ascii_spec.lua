-- ASCII back-end (port of ox-ascii.el). Expected strings come from Emacs
-- Org 9.8.10; the fixture comparisons use outputs checked in under
-- tests/fixtures/export/ascii (see the header of each test for the
-- Emacs settings).

local ox = require("org.export.ox")
local config = require("org.config")
local ascii = require("org.export.ascii")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local dir = root .. "/fixtures/export/ascii"

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local function exp(text, charset, opts)
  local lines = type(text) == "table" and text or vim.split(text, "\n", { plain = true })
  opts = vim.tbl_extend("force", { body_only = true }, opts or {})
  if charset then
    opts.ext = vim.tbl_extend("force", opts.ext or {}, { ascii_charset = charset })
  end
  return (ox.export_as("ascii", lines, opts))
end

-- The runner has no after_each: run each test with known settings and
-- restore the previous ones afterwards so other specs are unaffected.
local it = function(name, fn)
  _G.it(name, function()
    local e = config.opts.export
    local saved = { config.opts.babel.evaluate_on_export, e.with_drawers, e.ascii, e.text_width }
    config.opts.babel.evaluate_on_export = false
    e.with_drawers = { ["not"] = { "LOGBOOK" } }
    e.ascii = {}
    e.text_width = nil
    local ok, err = pcall(fn)
    config.opts.babel.evaluate_on_export, e.with_drawers, e.ascii, e.text_width = unpack(saved, 1, 4)
    if not ok then
      error(err, 0)
    end
  end)
end

describe("ascii export", function()
  it("org.export.text is the ascii back-end", function()
    eq(ascii, require("org.export.text"))
  end)

  describe("fill", function()
    it("fills paragraphs with two spaces after sentences", function()
      eq(
        "One two three four.  Five six\nseven eight.\n",
        ascii.fill_string("One two three four.\nFive six seven eight.\n", 30, {})
      )
    end)

    it("keeps single spaces inside sentences and after abbreviations", function()
      eq("e.g. this. That\n", ascii.fill_string("e.g. this. That\n", 72, {}))
    end)

    it("breaks at hard newlines only", function()
      eq("a b\nc d\n", ascii.fill_string("a\nb" .. ascii.HARD .. "c\nd\n", 72, {}))
    end)

    it("centers and right-justifies", function()
      eq("\t   abc\n", ascii.fill_string("abc\n", 25, {}, "center"))
      eq("\t\t\t abc\n", ascii.fill_string("abc\n", 28, {}, "right"))
    end)

    it("justify_lines uses spaces", function()
      eq("     ab", ascii.justify_lines("ab", 12, "center"))
      eq("       ab", ascii.justify_lines("ab", 9, "right"))
    end)
  end)

  describe("transcoders", function()
    it("markup", function()
      eq("*b* /i/ _u_ +s+ `v' `c'\n", exp("*b* /i/ _u_ +s+ =v= ~c~"))
    end)

    it("verbatim format option", function()
      config.opts.export.ascii = { verbatim_format = "=%s=" }
      eq("=v=\n", exp("=v="))
    end)

    it("entities per charset", function()
      eq("alpha -> x\n", exp("\\alpha \\to x", "ascii"))
      eq("alpha -> x\n", exp("\\alpha \\to x", "latin1"))
      eq("α → x\n", exp("\\alpha \\to x", "utf-8"))
      eq("a ¬ b\n", exp("a \\not b", "latin1"))
    end)

    it("special strings in utf-8", function()
      eq("a -- b... \"q\"\n", exp('a -- b... "q"', "ascii"))
      eq("a – b… \"q\"\n", exp('a -- b... "q"', "utf-8"))
      eq("“q”\n", exp({ "#+OPTIONS: ':t", "\"q\"" }, "utf-8"))
    end)

    it("sub and superscripts", function()
      eq("x^2 H_{2}O\n", exp("x^2 H_{2}O"))
    end)

    it("links", function()
      eq("[Org]\n\n\n[Org] <https://orgmode.org>\n", exp("[[https://orgmode.org][Org]]"))
      eq("<https://orgmode.org>\n", exp("[[https://orgmode.org]]"))
      config.opts.export.ascii = { links_to_notes = false }
      eq("[Org] (<https://orgmode.org>)\n", exp("[[https://orgmode.org][Org]]"))
    end)

    it("internal links", function()
      eq(
        "1 A\n═══\n\n  See 2.\n\n\n2 B\n═══\n",
        exp({ "* A", "See [[B]].", "* B" }, "utf-8")
      )
    end)

    it("footnotes", function()
      eq("Text[1].\n\n\n\nFootnotes\n_________\n\n[1] Note.\n", exp({ "Text[fn:1].", "", "[fn:1] Note." }))
      eq("Text[1].\n\n\n\nFootnotes\n─────────\n\n[1] Note.\n", exp({ "Text[fn:1].", "", "[fn:1] Note." }, "utf-8"))
    end)

    it("headlines, tags, todo and priority", function()
      local out = exp({ "* TODO [#A] Title :t1:", "Body." }, "ascii", { ext = { with_priority = true } })
      eq("1 TODO (#A) Title" .. string.rep(" ", 72 - 17 - 4) .. ":t1:\n=================\n\n  Body.\n", out)
    end)

    it("low level headlines use bullets per charset", function()
      local src = { "#+OPTIONS: H:1", "* A", "** B", "Text." }
      eq("1 A\n═══\n\n◊ 1.1 B\n\n  Text.\n", exp(src, "utf-8"))
      eq("1 A\n===\n\n§ 1.1 B\n\n  Text.\n", exp(src, "latin1"))
      eq("1 A\n===\n\n* 1.1 B\n\n  Text.\n", exp(src, "ascii"))
    end)

    it("plain lists and checkboxes", function()
      local src = { "- [X] a", "- [ ] b", "- [-] c", "1. one", "2. two" }
      eq("- [X] a\n- [ ] b\n- [-] c\n1. one\n2. two\n", exp(src, "ascii"))
      eq("• ☑ a\n• ☐ b\n• ☒ c\n1. one\n2. two\n", exp(src, "utf-8"))
    end)

    it("descriptive lists", function()
      eq("term\n      value\n", exp("- term :: value"))
    end)

    it("blocks are boxed", function()
      eq(",----\n| x\n`----\n", exp({ "#+begin_example", "x", "#+end_example" }))
      eq("┌────\n│ x\n└────\n", exp({ "#+begin_src sh", "x", "#+end_src" }, "utf-8"))
      eq(",----\n| a\n`----\n", exp(": a"))
    end)

    it("quote and verse blocks", function()
      eq("      q\n", exp({ "#+begin_quote", "q", "#+end_quote" }))
      eq("      a\n        b\n", exp({ "#+begin_verse", "a", "  b", "#+end_verse" }))
    end)

    it("tables per charset", function()
      local src = { "| a | b |", "|---+---|", "| 1 | 2 |" }
      eq(" a  b \n------\n 1  2 \n", exp(src, "ascii"))
      eq("━━━━━━\n a  b \n──────\n 1  2 \n━━━━━━\n", exp(src, "utf-8"))
    end)

    it("table captions", function()
      eq(
        " a \nTable 1: Cap\n",
        exp({ "#+CAPTION: Cap", "| a |" })
      )
      config.opts.export.ascii = { caption_above = true }
      eq("Table 1: Cap\n a \n", exp({ "#+CAPTION: Cap", "| a |" }))
    end)

    it("horizontal rules", function()
      eq(string.rep("-", 72) .. "\n", exp("-----"))
      eq(string.rep("―", 72) .. "\n", exp("-----", "utf-8"))
    end)

    it("planning and clocks", function()
      eq(
        "1 H\n═══\n\n  SCHEDULED: <2024-01-01 Mon>\n"
          .. "  CLOCK: [2024-01-01 Mon 10:00]--[2024-01-01 Mon 11:00]  =>  1:00\n",
        exp({
          "#+OPTIONS: p:t c:t",
          "* H",
          "SCHEDULED: <2024-01-01 Mon>",
          "CLOCK: [2024-01-01 Mon 10:00]--[2024-01-01 Mon 11:00] =>  1:00",
        }, "utf-8")
      )
    end)

    it("export blocks, keywords and snippets", function()
      local src = { "#+begin_export ascii", "raw", "#+end_export", "", "#+ASCII: kw", "", "@@ascii:s@@ @@html:h@@" }
      eq("raw\n\nkw\n\ns\n", exp(src))
    end)

    it("line breaks", function()
      eq("a\nb\n", exp("a\\\\\nb"))
    end)

    it("drawers with a format function", function()
      config.opts.export.with_drawers = true
      config.opts.export.ascii = {
        format_drawer_function = function(name, contents, width)
          return name .. ":" .. width .. ":" .. contents
        end,
      }
      eq("D:72:x\n", exp({ ":D:", "x", ":END:" }))
    end)

    it("inlinetasks", function()
      local out = exp({ "*************** TODO Task", "Body.", "*************** END" }, "utf-8")
      eq(
        string.rep(" ", 42)
          .. string.rep("━", 30)
          .. "\n"
          .. string.rep(" ", 42)
          .. "TODO Task\n"
          .. string.rep(" ", 42)
          .. string.rep("─", 30)
          .. "\n"
          .. string.rep(" ", 42)
          .. "Body.\n"
          .. string.rep(" ", 42)
          .. string.rep("━", 30)
          .. "\n",
        out
      )
    end)
  end)

  describe("options", function()
    it("text_width with legacy export.text_width fallback", function()
      local src = "aaa bbb ccc ddd"
      config.opts.export.text_width = 8
      eq("aaa bbb\nccc ddd\n", exp(src))
      config.opts.export.ascii = { text_width = 12 }
      eq("aaa bbb ccc\nddd\n", exp(src))
    end)

    it("ascii_charset in the export options", function()
      config.opts.export.ascii = { charset = "utf-8" }
      eq("α\n", exp("\\alpha", nil))
      eq("alpha\n", exp("\\alpha", "ascii"))
    end)

    it("global margin and inner margin", function()
      config.opts.export.ascii = { global_margin = 1, inner_margin = 3 }
      eq(" 1 H\n ═══\n\n    x\n", exp({ "* H", "x" }, "utf-8"))
    end)

    it("paragraph spacing and indented line width", function()
      config.opts.export.ascii = { paragraph_spacing = 0, indented_line_width = 2 }
      eq("a\n  b\n", exp({ "a", "", "b" }))
    end)

    it("headline spacing", function()
      config.opts.export.ascii = { headline_spacing = { 0, 0 } }
      eq("1 A\n═══\n  x\n2 B\n═══\n", exp({ "* A", "x", "* B" }, "utf-8"))
    end)
  end)

  describe("matches Emacs", function()
    local function check(name, charset, cfg)
      it(name .. " (" .. charset .. ")", function()
        if cfg then
          cfg()
        end
        local file = dir .. "/" .. name .. ".org"
        local out = ox.export_as("ascii", vim.fn.readfile(file), { filename = file, ext = { ascii_charset = charset } })
        eq(read(dir .. "/" .. name .. "." .. charset .. ".txt"), out)
      end)
    end
    for _, name in ipairs({ "features", "misc", "justify" }) do
      for _, charset in ipairs({ "ascii", "latin1", "utf-8" }) do
        check(name, charset)
      end
    end
    -- (setq org-ascii-text-width 50 org-ascii-global-margin 2 org-ascii-inner-margin 4
    --       org-ascii-paragraph-spacing 0 org-ascii-indented-line-width 3 org-ascii-links-to-notes nil
    --       org-ascii-table-widen-columns nil org-ascii-caption-above t org-ascii-list-margin 2
    --       org-ascii-headline-spacing '(0 . 1) org-export-with-drawers t)
    for _, charset in ipairs({ "ascii", "utf-8" }) do
      check("options", charset, function()
        config.opts.export.with_drawers = true
        config.opts.export.ascii = {
          text_width = 50,
          global_margin = 2,
          inner_margin = 4,
          paragraph_spacing = 0,
          indented_line_width = 3,
          links_to_notes = false,
          table_widen_columns = false,
          caption_above = true,
          list_margin = 2,
          headline_spacing = { 0, 1 },
        }
      end)
    end
  end)
end)

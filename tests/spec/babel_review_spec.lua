local babel = require("org.babel")
local blocks = require("org.babel.blocks")

describe("babel asynchronous source tracking", function()
  local evaluate, pending
  before_each(function()
    evaluate, pending = babel.evaluate, {}
    babel.evaluate = function(_, _, _, _, callback)
      pending[#pending + 1] = callback
    end
  end)
  after_each(function()
    babel.evaluate = evaluate
  end)

  it("does not replace another block's results after the running block is deleted", function()
    local buf = org_buffer({
      "#+begin_src sh :results output",
      "sleep 2; echo stale",
      "#+end_src",
      "#+begin_src sh :results output",
      "echo kept",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": kept",
    })
    local completed
    babel.execute({
      bufnr = buf,
      lnum = 1,
      on_done = function(ok, abort)
        completed = { ok, abort }
      end,
    })
    vim.api.nvim_buf_set_lines(buf, 0, 3, false, {})
    local expected = buf_lines(buf)
    pending[1]("stale", {})
    eq(expected, buf_lines(buf))
    eq({ false, true }, completed)
  end)

  it("does not insert results for a source that changed during execution", function()
    local buf = org_buffer({ "#+begin_src sh", "echo old", "#+end_src" })
    babel.execute({ bufnr = buf, lnum = 1 })
    vim.api.nvim_buf_set_text(buf, 1, 5, 1, 8, { "new" })
    local expected = buf_lines(buf)
    pending[1]("old", {})
    eq(expected, buf_lines(buf))
  end)

  it("follows intact source blocks when lines are inserted above them", function()
    local buf = org_buffer({ "#+begin_src sh", "echo moved", "#+end_src" })
    babel.execute({ bufnr = buf, lnum = 1 })
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "* New heading", "" })
    pending[1]("moved", {})
    eq({ "", "#+RESULTS:", ": moved" }, vim.list_slice(buf_lines(buf), 6))
  end)

  it("does not insert inline results into text after the source is deleted", function()
    local line = "Before src_sh{echo stale} after."
    local buf = org_buffer({ line })
    local ib = babel.inline_all(line)[1]
    babel.execute_inline_at(buf, 1, ib)
    vim.api.nvim_buf_set_text(buf, 0, ib.s - 1, 0, ib.e, {})
    local expected = buf_lines(buf)
    pending[1]("stale", {})
    eq(expected, buf_lines(buf))
  end)

  it("follows intact inline source when preceding text changes", function()
    local line = "Before src_sh{echo moved} after."
    local buf = org_buffer({ line })
    babel.execute_inline_at(buf, 1, babel.inline_all(line)[1])
    vim.api.nvim_buf_set_text(buf, 0, 0, 0, 6, { "Edited prefix" })
    pending[1]("moved", {})
    eq({ "Edited prefix src_sh{echo moved} {{{results(=moved=)}}} after." }, buf_lines(buf))
  end)

  it("finishes buffer execution after the source buffer is wiped", function()
    local buf = org_buffer({ "#+begin_src sh", "echo gone", "#+end_src" })
    local completed
    babel.execute_buffer({
      bufnr = buf,
      on_done = function(n)
        completed = n
      end,
    })
    vim.api.nvim_buf_delete(buf, { force = true })
    pending[1]("gone", {})
    eq(1, completed)
  end)
end)

-- Checked with Emacs -Q, Org 9.8.7: org-babel-map-src-blocks and
-- org-unescape-code-in-string (org-src.el).
describe("babel literal source parity", function()
  it("requires a complete source block terminator", function()
    for _, ending in ipairs({ "#+end_src_extra", "#+end_src extra" }) do
      eq({}, blocks.parse_blocks({ "#+begin_src sh", "echo before", ending }))
      local found = blocks.parse_blocks({
        "#+begin_src sh",
        "echo before",
        ending,
        "echo after",
        "#+end_src",
      })
      eq(1, #found)
      eq(5, found[1].finish)
      eq({ "echo before", ending, "echo after" }, found[1].body)
    end
  end)

  it("recovers valid source blocks after a heading ends an unmatched block", function()
    local found = blocks.parse_blocks({
      "#+begin_src sh",
      "echo discarded",
      "* Heading",
      "#+begin_src sh",
      "echo active",
      "#+end_src",
    })
    eq(1, #found)
    eq(4, found[1].start)
    eq({ "echo active" }, found[1].body)
  end)

  it("keeps apparent nested source openers as code until the closing delimiter", function()
    local found = blocks.parse_blocks({
      "#+begin_src sh",
      "echo first",
      "#+begin_src sh",
      "echo second",
      "#+end_src",
    })
    eq(1, #found)
    eq(1, found[1].start)
    eq({ "echo first", "#+begin_src sh", "echo second" }, found[1].body)
  end)

  it("does not find executable blocks or calls inside literal elements", function()
    for _, kind in ipairs({ "example", "export", "comment", "verse" }) do
      eq(
        {},
        blocks.parse_blocks({
          "#+begin_" .. kind,
          "#+begin_src sh :tangle yes :exports none",
          "echo literal",
          "#+end_src",
          "#+CALL: other()",
          "#+end_" .. kind,
        }),
        kind
      )
    end
  end)

  it("still finds executable blocks in greater elements", function()
    for _, kind in ipairs({ "quote", "center", "special" }) do
      local found = blocks.parse_blocks({
        "#+begin_" .. kind,
        "#+begin_src sh",
        "echo active",
        "#+end_src",
        "#+end_" .. kind,
      })
      eq(1, #found, kind)
      eq({ "echo active" }, found[1].body)
    end
  end)

  it("does not extend literal blocks across a heading", function()
    local found = blocks.parse_blocks({
      "#+begin_example",
      "* Heading",
      "#+begin_src sh",
      "echo active",
      "#+end_src",
      "#+end_example",
    })
    eq(1, #found)
    eq({ "echo active" }, found[1].body)
  end)

  it("does not alter literal Babel examples during export preprocessing", function()
    local lines = {
      "#+begin_example",
      "#+begin_src sh :exports none",
      "echo example",
      "#+end_src",
      "#+end_example",
    }
    eq(lines, require("org.export.ox").babel_process(lines, {}))
  end)

  it("does not execute inline examples after a nested source terminator", function()
    local lines = {
      "#+begin_example",
      "#+begin_src sh",
      "echo example",
      "#+end_src",
      "Text src_lua{return 99}.",
      "#+end_example",
    }
    local buf = org_buffer(lines)
    babel.execute_buffer({ bufnr = buf, sync = true, skip_confirm = true })
    eq(lines, buf_lines(buf))
  end)

  it("executes inline objects inside greater elements and verse", function()
    for _, kind in ipairs({ "quote", "center", "special", "verse" }) do
      local buf = org_buffer({ "#+begin_" .. kind, "Text src_lua{return 7}.", "#+end_" .. kind })
      babel.execute_buffer({ bufnr = buf, sync = true, skip_confirm = true })
      eq("Text src_lua{return 7} {{{results(=7=)}}}.", buf_lines(buf)[2], kind)
      eq("Text {{{results(=7=)}}}.", require("org.export.ox").babel_process(buf_lines(buf), {})[2], kind)
    end
  end)

  it("unescapes exactly one comma only for escaped Org syntax", function()
    eq(
      { ",#literal", ",* nested", ",#+begin_src", "  * heading", "  ,#+end_src" },
      blocks.unescape({
        ",#literal",
        ",,* nested",
        ",,#+begin_src",
        "  ,* heading",
        "  ,,#+end_src",
      })
    )
    local source = { "* heading", ",* literal", "#+begin_src", ",#+end_src", ",#literal" }
    eq(source, blocks.unescape(blocks.escape(source)))
  end)
end)

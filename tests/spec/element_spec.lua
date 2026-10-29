-- org.element: the line-based element parser and the element commands
-- (org-forward-element, org-up-element, org-mark-element, ...). Every
-- expectation was checked against Emacs 31.1 with Org 9.8.10 in batch
-- (org-element-parse-buffer for the trees, the commands on the same text
-- for the motions), except where a test says otherwise. Emacs's lines are
-- 1-based like ours; a region's end is the line before Emacs's exclusive
-- end.

local E = require("org.element")

--- The parse of `lines` as { type, first, post, last, children? }.
local function shape(els)
  local out = {}
  for _, el in ipairs(els) do
    local s = { el.type, el.first, el.post, el.last }
    if el.children and #el.children > 0 then
      s[5] = shape(el.children)
    end
    out[#out + 1] = s
  end
  return out
end

local function parse(lines)
  return shape(E.parse(lines, 1, #lines))
end

--- Run `fn` with the buffer `lines` and the cursor at `pos` ({lnum, col0}),
--- and return the cursor, the messages and the buffer's lines.
local function run(lines, pos, fn)
  local buf = org_buffer(lines, pos)
  local msgs = {}
  local notify = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = tostring(m)
  end
  local okk, err = pcall(fn)
  vim.notify = notify
  assert(okk, err)
  return vim.api.nvim_win_get_cursor(0), msgs, buf_lines(buf)
end

--- The line the cursor is on after `fn`.
local function lnum_after(lines, pos, fn)
  local cur = run(lines, pos, fn)
  return cur[1]
end

--- A test of a known difference from Emacs: it runs (and counts as
--- skipped) while it fails; once it passes, drop the marker.
local function known(reason, fn)
  return function()
    local passed = pcall(fn)
    if passed then
      error("known difference fixed, drop known(): " .. reason)
    end
    error({ skip = "known difference: " .. reason }, 0)
  end
end

describe("element parser", function()
  with_config({ startup_folded = "showeverything" })

  it("parses blocks, footnotes, LaTeX environments, drawers and dynamic blocks like org-element", function()
    eq(
      {
        { "paragraph", 1, 1, 1 },
        -- #+NAME: is affiliated to the block
        { "special-block", 2, 3, 6, { { "paragraph", 4, 4, 4 } } },
        -- a footnote definition ends at two blank lines
        { "footnote-definition", 7, 7, 10, { { "paragraph", 7, 7, 8 } } },
        { "paragraph", 11, 11, 11 },
        { "latex-environment", 12, 12, 14 },
        { "drawer", 15, 15, 17, { { "paragraph", 16, 16, 16 } } },
        { "dynamic-block", 18, 18, 19 },
      },
      parse({
        "para",
        "#+NAME: x",
        "#+begin_foo",
        "inner",
        "#+end_foo",
        "",
        "[fn:1] note",
        "more",
        "",
        "",
        "after",
        "\\begin{equation}",
        "x",
        "\\end{equation}",
        ":DR:",
        "in",
        ":END:",
        "#+BEGIN: clocktable",
        "#+END:",
      })
    )
  end)

  it("parses tables, fixed-width areas, comments and one-line elements like org-element", function()
    eq(
      {
        -- #+TBLFM: lines belong to the table
        { "table", 1, 2, 4 },
        { "fixed-width", 5, 5, 6 },
        { "comment", 7, 7, 8 },
        { "horizontal-rule", 9, 9, 9 },
        { "clock", 10, 10, 10 },
        { "keyword", 11, 11, 11 },
        { "babel-call", 12, 12, 12 },
        -- an affiliated keyword before a blank line is a keyword of its own
        { "keyword", 13, 13, 14 },
        -- a table.el table
        { "table", 15, 15, 17 },
        { "src-block", 18, 18, 20 },
        { "example-block", 21, 21, 22 },
      },
      parse({
        "#+NAME: tbl",
        "| a |",
        "| b |",
        "#+TBLFM: $1=1",
        ": fw1",
        ":",
        "# c1",
        "#",
        "-----",
        "CLOCK: [2024-01-01 Mon 10:00]",
        "#+TITLE: t",
        "#+CALL: f()",
        "#+NAME: alone",
        "",
        "+--+--+",
        "|a |b |",
        "+--+--+",
        "#+begin_src sh",
        "echo",
        "#+end_src",
        "#+begin_example",
        "#+end_example",
      })
    )
  end)

  it("gives src and example blocks no children, and greater blocks their contents", function()
    local els = E.parse({ "#+begin_src sh", "- a", "#+end_src", "#+begin_center", "- a", "#+end_center" }, 1, 6)
    eq({ false, 2, 2 }, { els[1].greater, els[1].cfirst, els[1].cend })
    eq({}, els[1].children)
    eq({ true, 5, 5 }, { els[2].greater, els[2].cfirst, els[2].cend })
    eq({ { "plain-list", 5, 5, 5, { { "item", 5, 5, 5, { { "paragraph", 5, 5, 5 } } } } } }, shape(els[2].children))
  end)

  it("parses nested plain lists into items like org-element", function()
    eq({
      {
        "plain-list",
        1,
        1,
        5,
        {
          {
            "item",
            1,
            1,
            4,
            {
              { "paragraph", 1, 1, 1 },
              { "plain-list", 2, 2, 3, { { "item", 2, 2, 2, { { "paragraph", 2, 2, 2 } } } } },
              { "paragraph", 4, 4, 4 },
            },
          },
          { "item", 5, 5, 5, { { "paragraph", 5, 5, 5 } } },
        },
      },
    }, parse({ "- one", "  - two", "", "  three", "- four" }))
  end)

  it("leaves an unterminated block a paragraph", function()
    eq({ { "paragraph", 1, 1, 2 } }, parse({ "#+begin_quote", "never ends" }))
    eq({ { "paragraph", 1, 1, 2 } }, parse({ ":NOEND:", "x" }))
    eq({ { "paragraph", 1, 1, 2 } }, parse({ "\\begin{eq}", "y" }))
    eq({ { "paragraph", 1, 1, 2 } }, parse({ "#+BEGIN: clocktable", "x" }))
  end)

  it("doesn't end a paragraph at a line that only looks like a drawer, block or LaTeX start", function()
    -- org-element-paragraph-parser only stops at a drawer, a block or an
    -- environment that is closed further down
    eq({ { "paragraph", 1, 1, 3 } }, parse({ "text", ":NOEND:", "x" }))
    eq({ { "paragraph", 1, 1, 3 } }, parse({ "text", "\\begin{eq}", "x" }))
    eq({ { "paragraph", 1, 1, 3 } }, parse({ "text", "#+begin_quote", "x" }))
    -- closed, they do
    eq({ { "paragraph", 1, 1, 1 }, { "drawer", 2, 2, 3 } }, parse({ "text", ":DR:", ":END:" }))
    eq({ { "paragraph", 1, 1, 1 }, { "latex-environment", 2, 2, 3 } }, parse({ "text", "\\begin{eq}", "\\end{eq}" }))
    eq({ { "paragraph", 1, 1, 1 }, { "quote-block", 2, 2, 3 } }, parse({ "text", "#+begin_quote", "#+end_quote" }))
  end)

  it("parses a section: planning, property drawer, drawers, footnotes", function()
    local buf = org_buffer({
      "* H",
      "SCHEDULED: <2024-01-01 Mon>",
      "",
      ":PROPERTIES:",
      ":A: 1",
      ":END:",
      "text",
      ":LOGBOOK:",
      ":END:",
      "[fn:a] one",
      "[fn:b] two",
      "* G",
    })
    local els, from, to, hl = E.section(buf, 7)
    eq({ 2, 11, 1 }, { from, to, hl.line })
    -- the property drawer's node properties are not elements here
    eq({
      { "planning", 2, 2, 3 },
      { "property-drawer", 4, 4, 6 },
      { "paragraph", 7, 7, 7 },
      { "drawer", 8, 8, 9 },
      { "footnote-definition", 10, 10, 10, { { "paragraph", 10, 10, 10 } } },
      { "footnote-definition", 11, 11, 11, { { "paragraph", 11, 11, 11 } } },
    }, shape(els))
  end)

  it("parses the text before the first headline as a section", function()
    local buf = org_buffer({ "#+TITLE: t", "", "intro", "* H", "body" })
    local els, from, to, hl = E.section(buf, 3)
    eq({ 1, 3 }, { from, to })
    eq(nil, hl)
    eq({ { "keyword", 1, 1, 2 }, { "paragraph", 3, 3, 3 } }, shape(els))
  end)

  it("finds the deepest element at a line, the list on a list's first line", function()
    local buf = org_buffer({ "* H", "#+begin_quote", "- a", "- b", "  text", "#+end_quote" })
    eq("quote-block", E.at(buf, 2).type)
    eq("plain-list", E.at(buf, 3).type)
    eq("item", E.at(buf, 4).type)
    eq("paragraph", E.at(buf, 5).type)
    eq("quote-block", E.at(buf, 6).type)
    eq(nil, E.at(buf, 1))
  end)

  it("recognizes affiliated keywords", function()
    ok(E.is_affiliated("#+NAME: x"))
    ok(E.is_affiliated("  #+caption[short]: long"))
    ok(E.is_affiliated("#+ATTR_HTML: :width 10"))
    ok(not E.is_affiliated("#+TITLE: x"))
    ok(not E.is_affiliated("text"))
  end)
end)

describe("org-forward-element", function()
  with_config({ startup_folded = "showeverything" })

  it("stays on the last subtree's headline", function()
    local cur, msgs = run({ "* H", "x", "* G" }, { 3, 0 }, E.forward)
    eq(3, cur[1])
    eq({ "Cannot move further down" }, msgs)
  end)

  it("stays on the last line", function()
    local cur, msgs = run({ "* H", "para" }, { 2, 0 }, E.forward)
    eq(2, cur[1])
    eq({ "Cannot move further down" }, msgs)
  end)

  it("leaves the parent from its last element", function()
    eq(7, lnum_after({ "* H", "#+begin_quote", "q1", "", "q2", "#+end_quote", "after" }, { 5, 1 }, E.forward))
  end)

  it("goes to the next item from an item's last paragraph", function()
    eq(4, lnum_after({ "* H", "- a", "  p1", "- b", "after" }, { 3, 2 }, E.forward))
  end)

  it("goes to the next headline from the blank lines of an empty section", function()
    eq(4, lnum_after({ "* H", "", "", "* G" }, { 2, 0 }, E.forward))
  end)

  it("stays on a blank last line", function()
    local cur, msgs = run({ "* H", "" }, { 2, 0 }, E.forward)
    eq(2, cur[1])
    eq({ "Cannot move further down" }, msgs)
  end)

  it(
    "goes past the section from the blank lines at its start",
    known("org.nvim goes to the section's first element", function()
      eq(5, lnum_after({ "* H", "", "", "para", "* G" }, { 2, 0 }, E.forward))
    end)
  )
end)

describe("org-backward-element", function()
  with_config({ startup_folded = "showeverything" })

  it("goes to the previous sibling headline", function()
    eq(1, lnum_after({ "* A", "* B" }, { 2, 0 }, E.backward))
  end)

  it("goes to the parent headline from a first child", function()
    eq(1, lnum_after({ "* A", "** B" }, { 2, 0 }, E.backward))
  end)

  it("stays on a first top-level headline", function()
    local cur, msgs = run({ "x", "* A" }, { 2, 0 }, E.backward)
    eq(2, cur[1])
    eq({ "Cannot move further up" }, msgs)
  end)

  it("stays at the start of the buffer", function()
    local cur, msgs = run({ "* A" }, { 1, 0 }, E.backward)
    eq({ 1, 0 }, cur)
    eq({ "Cannot move further up" }, msgs)
  end)

  it("goes to the start of the buffer over leading blank lines", function()
    eq(1, lnum_after({ "", "", "para" }, { 3, 0 }, E.backward))
  end)

  it("goes to the start of a list that ended before", function()
    eq(2, lnum_after({ "* H", "- a", "- b", "", "after" }, { 5, 0 }, E.backward))
  end)

  it("goes to the start of a block that ended before", function()
    eq(2, lnum_after({ "* H", "#+begin_quote", "- a", "- b", "#+end_quote", "after" }, { 6, 0 }, E.backward))
  end)
end)

describe("org-up-element", function()
  with_config({ startup_folded = "showeverything" })

  it("has nothing around a top-level headline", function()
    local cur, msgs = run({ "* A" }, { 1, 0 }, E.up)
    eq(1, cur[1])
    eq({ "No surrounding element" }, msgs)
  end)

  it("goes to the parent headline", function()
    eq(1, lnum_after({ "* A", "** B" }, { 2, 0 }, E.up))
  end)

  it("has nothing around text before the first headline", function()
    local cur, msgs = run({ "pre", "* A" }, { 1, 1 }, E.up)
    eq({ 1, 1 }, cur)
    eq({ "No surrounding element" }, msgs)
  end)

  it("goes from an item's bullet to its list", function()
    eq(3, lnum_after({ "* H", "p", "- a", "- b" }, { 4, 0 }, E.up))
  end)

  it("goes from the list's first bullet to what holds the list", function()
    eq(1, lnum_after({ "* H", "p", "- a", "- b" }, { 3, 0 }, E.up))
    eq(2, lnum_after({ "* H", "#+begin_quote", "- a", "- b", "#+end_quote" }, { 3, 0 }, E.up))
  end)

  it("goes from an item's text to the item", function()
    eq(4, lnum_after({ "* H", "- a", "  - b", "  - c" }, { 4, 5 }, E.up))
  end)
end)

describe("org-down-element", function()
  with_config({ startup_folded = "showeverything" })

  it("goes from a headline to its first element", function()
    eq(3, lnum_after({ "* H", "", "para" }, { 1, 0 }, E.down))
  end)

  it("goes from a headline without text to its first child", function()
    eq(2, lnum_after({ "* H", "** C" }, { 1, 0 }, E.down))
  end)

  it("stays on an empty headline", function()
    -- Emacs: the same, saying "No content for this element"
    local cur, msgs = run({ "* H" }, { 1, 0 }, E.down)
    eq(1, cur[1])
    eq(1, #msgs)
  end)

  it("stays on an empty greater element", function()
    local cur, msgs = run({ "* H", "#+begin_quote", "#+end_quote" }, { 2, 0 }, E.down)
    eq(2, cur[1])
    eq({ "No content for this element" }, msgs)
  end)

  it("stays on an element with no inner elements", function()
    local cur, msgs = run({ "* H", "para" }, { 2, 0 }, E.down)
    eq(2, cur[1])
    eq({ "No inner element" }, msgs)
  end)

  it("goes into a drawer", function()
    eq(3, lnum_after({ "* H", ":DR:", "in", ":END:" }, { 2, 0 }, E.down))
  end)

  it("opens a closed fold on the element", function()
    org_buffer({ "* H", "#+begin_quote", "q", "r", "#+end_quote", "after" }, { 2, 0 })
    vim.cmd("normal! zx")
    vim.cmd("normal! zc")
    eq(2, vim.fn.foldclosed(2))
    E.down()
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
    eq(-1, vim.fn.foldclosed(3))
  end)
end)

describe("org-mark-element", function()
  with_config({ startup_folded = "showeverything" })

  local function selection()
    return { vim.fn.mode(), vim.fn.line("v"), vim.fn.line(".") }
  end

  it("selects the element and the blank lines after it", function()
    org_buffer({ "* H", "p1", "p1b", "", "p2" }, { 2, 1 })
    E.mark()
    eq({ "V", 2, 4 }, selection())
  end)

  it("selects the subtree on a headline", function()
    org_buffer({ "* H", "x", "** C", "y", "* G" }, { 1, 0 })
    E.mark()
    eq({ "V", 1, 4 }, selection())
  end)

  it("extends the selection by the next element", function()
    org_buffer({ "* H", "p1", "", "p2", "", "p3" }, { 2, 1 })
    E.mark()
    E.mark()
    eq({ "V", 2, 5 }, selection())
  end)

  it("extends the selection by the next subtree", function()
    org_buffer({ "* H", "p1", "* G", "x", "* I" }, { 2, 0 })
    E.mark()
    E.mark()
    eq({ "V", 2, 4 }, selection())
  end)

  it("keeps the selection at the end of the buffer", function()
    org_buffer({ "* H", "p1" }, { 2, 0 })
    E.mark()
    E.mark()
    eq({ "V", 2, 2 }, selection())
  end)
end)

describe("org-drag-element / org-transpose-element", function()
  with_config({ startup_folded = "showeverything" })

  it("drags a subtree down from its headline", function()
    local cur, _, lines = run({ "* A", "x", "* B", "y" }, { 1, 0 }, E.drag_forward)
    eq({ "* B", "y", "* A", "x" }, lines)
    eq(3, cur[1])
  end)

  it("drags a subtree up from its headline", function()
    -- Emacs moves subtree A from column 0 (it skips back over the newline
    -- first); from inside the headline it moves B like this
    local _, _, lines = run({ "* A", "x", "* B", "y" }, { 3, 2 }, E.drag_backward)
    eq({ "* B", "y", "* A", "x" }, lines)
  end)

  it("doesn't drag where there is no element", function()
    local _, msgs, lines = run({ "", "* H" }, { 1, 0 }, E.drag_forward)
    eq({ "", "* H" }, lines)
    eq({ "No element at point" }, msgs)
    _, msgs, lines = run({ "", "", "para" }, { 1, 0 }, E.drag_backward)
    eq({ "", "", "para" }, lines)
    eq({ "No element at point" }, msgs)
  end)

  it("doesn't drag the last element of a block out of it", function()
    local lines = { "* H", "#+begin_quote", "q", "#+end_quote", "after" }
    local _, msgs, out = run(lines, { 3, 0 }, E.drag_forward)
    eq(lines, out)
    eq({ "Cannot drag element forward" }, msgs)
    _, msgs, out = run(lines, { 3, 0 }, E.drag_backward)
    eq(lines, out)
    eq({ "Cannot drag element backward" }, msgs)
  end)

  it("doesn't drag an element onto the next headline", function()
    local _, msgs, out = run({ "* H", "para", "* G" }, { 2, 1 }, E.drag_forward)
    eq({ "* H", "para", "* G" }, out)
    eq({ "Cannot drag element forward" }, msgs)
  end)

  it("drags a paragraph past a list, the cursor with it", function()
    local cur, _, out = run({ "* H", "para", "", "", "- a", "- b" }, { 2, 3 }, E.drag_forward)
    eq({ "* H", "- a", "- b", "", "", "para" }, out)
    eq({ 6, 3 }, cur)
  end)

  it("drags a paragraph up past a whole list", function()
    local cur, _, out = run({ "* H", "- a", "- b", "", "after" }, { 5, 0 }, E.drag_backward)
    eq({ "* H", "after", "", "- a", "- b" }, out)
    eq(2, cur[1])
  end)

  it("drags a table with its #+NAME:", function()
    local cur, _, out = run({ "* H", "#+NAME: n", "| a |", "", "para" }, { 5, 1 }, E.drag_backward)
    eq({ "* H", "para", "", "#+NAME: n", "| a |" }, out)
    eq({ 2, 1 }, cur)
  end)

  it("transposes from the blank lines before an element", function()
    local cur, _, out = run({ "* H", "p1", "", "p2", "", "p3" }, { 3, 0 }, E.transpose)
    eq({ "* H", "p2", "", "p1", "", "p3" }, out)
    eq(6, cur[1])
  end)

  it("doesn't transpose the first element", function()
    local _, msgs, out = run({ "* H", "p1", "", "p2" }, { 2, 1 }, E.transpose)
    eq({ "* H", "p1", "", "p2" }, out)
    eq({ "Cannot drag element backward" }, msgs)
  end)
end)

describe("org-narrow-to-element / org-narrow-to-block", function()
  with_config({ startup_folded = "showeverything" })

  local function narrowed(lines, pos, fn)
    local buf = org_buffer(lines, pos)
    local msgs = {}
    local notify = vim.notify
    vim.notify = function(m)
      msgs[#msgs + 1] = tostring(m)
    end
    local okk, err = pcall(fn)
    vim.notify = notify
    assert(okk, err)
    local cur = vim.api.nvim_get_current_buf()
    local out = cur ~= buf and buf_lines(cur) or nil
    if cur ~= buf then
      vim.cmd("bwipeout! " .. cur)
    end
    return out, msgs
  end

  -- org-narrow-to-element: the subtree on a headline, a greater element's
  -- contents, any other element with its blank lines
  it("narrows to the subtree on a headline", function()
    eq({ "* A", "a" }, narrowed({ "* A", "a", "* B" }, { 1, 0 }, E.narrow_to_element))
  end)

  it("narrows to a drawer's contents", function()
    eq({ "in", "more" }, narrowed({ "* H", ":DR:", "in", "more", ":END:" }, { 2, 0 }, E.narrow_to_element))
  end)

  it("narrows to a paragraph and its blank lines", function()
    eq({ "p1", "" }, narrowed({ "* H", "p1", "", "p2" }, { 2, 0 }, E.narrow_to_element))
  end)

  it("doesn't narrow where there is no element", function()
    local out, msgs = narrowed({ "", "", "para" }, { 1, 0 }, E.narrow_to_element)
    eq(nil, out)
    eq({ "No element at point" }, msgs)
  end)

  it("narrows to a greater block's contents", function()
    eq({ "q" }, narrowed({ "* H", "#+begin_quote", "q", "#+end_quote" }, { 2, 0 }, E.narrow_to_block))
  end)

  it("narrows to a whole src block", function()
    eq(
      { "#+begin_src sh", "echo", "#+end_src" },
      narrowed({ "* H", "#+begin_src sh", "echo", "#+end_src" }, { 3, 0 }, E.narrow_to_block)
    )
  end)

  it("doesn't narrow outside a block", function()
    local out, msgs = narrowed({ "* H", "para" }, { 2, 0 }, E.narrow_to_block)
    eq(nil, out)
    eq({ "Not in a block" }, msgs)
  end)

  it("doesn't narrow from a paragraph inside a greater block", function()
    -- org-narrow-to-block only looks at org-element-at-point, here the
    -- quote block's paragraph, not at the elements around it
    local out, msgs = narrowed({ "* H", "#+begin_quote", "para", "#+end_quote" }, { 3, 0 }, E.narrow_to_block)
    eq(nil, out)
    eq({ "Not in a block" }, msgs)
  end)
end)

describe("org-next-block / org-previous-block", function()
  with_config({ startup_folded = "showeverything" })

  it("says when there is no further block", function()
    local cur, msgs = run({ "* H", "#+begin_quote", "q", "#+end_quote", "p" }, { 3, 0 }, E.next_block)
    eq(3, cur[1])
    eq({ "No further code blocks" }, msgs)
  end)

  it("says when there is no previous block", function()
    local cur, msgs = run({ "* H", "p", "#+begin_quote", "q", "#+end_quote" }, { 2, 0 }, E.previous_block)
    eq(2, cur[1])
    eq({ "No previous code blocks" }, msgs)
  end)

  it("skips a #+begin line that starts no block", function()
    local cur, msgs = run({ "* H", "#+begin_quote", "never ends", "p" }, { 1, 0 }, E.next_block)
    eq(1, cur[1])
    eq({ "No further code blocks" }, msgs)
  end)
end)

describe("org-toggle-fixed-width", function()
  with_config({ startup_folded = "showeverything" })

  it("removes a lone colon", function()
    local _, _, out = run({ "* H", ":" }, { 2, 0 }, E.toggle_fixed_width)
    eq({ "* H", "" }, out)
  end)

  it("removes only the marker and one space", function()
    local _, _, out = run({ "* H", "  :   x" }, { 2, 6 }, E.toggle_fixed_width)
    eq({ "* H", "    x" }, out)
  end)

  it("marks a headline", function()
    local _, _, out = run({ "* H" }, { 1, 2 }, E.toggle_fixed_width)
    eq({ ": * H" }, out)
  end)

  it("marks a clock line", function()
    local _, _, out = run({ "* H", "CLOCK: [2024-01-01 Mon 10:00]" }, { 2, 3 }, E.toggle_fixed_width)
    eq({ "* H", ": CLOCK: [2024-01-01 Mon 10:00]" }, out)
  end)

  it("can't mark a block's first line", function()
    local lines = { "* H", "#+begin_quote", "q", "#+end_quote" }
    local _, msgs, out = run(lines, { 2, 0 }, E.toggle_fixed_width)
    eq(lines, out)
    eq({ "Cannot insert a fixed-width line here" }, msgs)
  end)

  local function visual(fn)
    return function()
      vim.cmd("normal! VG")
      fn()
    end
  end

  it("marks a headline and the lines of a region", function()
    local _, _, out = run({ "* H", ": x", "y" }, { 1, 0 }, visual(E.toggle_fixed_width))
    eq({ ": * H", ": x", ": y" }, out)
  end)

  it("unmarks a region of fixed-width lines, blank lines kept", function()
    local _, _, out = run({ ": a", "", ": b", "" }, { 1, 0 }, visual(E.toggle_fixed_width))
    eq({ "a", "", "b", "" }, out)
  end)

  it(
    "marks the blank lines in a region at the common indentation",
    known("org.nvim writes no space after the colon of a blank line", function()
      local _, _, out = run({ "* H", "  a", "", "    b" }, { 2, 0 }, visual(E.toggle_fixed_width))
      eq({ "* H", "  : a", "  : ", "  :   b" }, out)
    end)
  )
end)

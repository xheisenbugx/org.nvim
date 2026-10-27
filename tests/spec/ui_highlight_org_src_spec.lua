-- The body of an org src block drawn as Org by the parser highlighter
-- (org.ui.highlight `org_body`): Emacs fontifies it in an Org buffer of
-- its own and copies the faces back (org-src-font-lock-fontify-block).
-- What Emacs draws is compared in emacs_faces_*_spec.lua
-- (tests/fixtures/emacs/faces/orgsrc.org).
local hl = require("tests.helpers.highlighter")
local fuzz = require("tests.helpers.fuzz")
local deco = require("org.ui.decorations")
local H = require("org.ui.highlight")

local has = hl.has

--- The column (1-based) of the first `s` in line l.
local function col(l, s)
  return assert(vim.fn.getline(l):find(s, 1, true), s)
end

--- Whether a byte of line `l` from column `c` (1-based) on is hidden.
local function hidden(l, c)
  for _, m in ipairs(deco.line_marks(vim.api.nvim_get_current_buf(), l - 1)) do
    if c - 1 >= m[1] and c - 1 < (m[2].end_col or m[1] + 1) and m[2].conceal == "" then
      return true
    end
  end
  return false
end

--- The marks `H.add_marks` makes on each row, as sortable strings.
local function keys(rows, row)
  local out = {}
  for _, m in ipairs(rows[row] or {}) do
    out[#out + 1] = m[1] .. ":" .. vim.inspect(m[2], { newline = "", indent = "" })
  end
  table.sort(out)
  return table.concat(out, " ")
end

describe("parser highlighter: org src blocks", function()
  with_config({ ui = { highlighter = "parser", hide_emphasis_markers = true } })

  it("draws the body as Org text on orgBlock", function()
    org_buffer({
      "#+begin_src org",
      "#+STARTUP: overview",
      "#+TITLE: A title",
      "# a comment",
      "Some *bold* and <2026-10-01 Thu>.",
      "- [X] done [1/2]",
      "| a | b |",
      ":PROPERTIES:",
      ":ID: x",
      ":END:",
      "A footnote[fn:1].",
      "#+begin_quote",
      "quoted",
      "#+end_quote",
      "#+end_src",
    }, { 1, 0 })
    ok(has(2, 1, "orgKeyword"))
    ok(has(3, col(3, "A title"), "orgTitle"))
    ok(has(4, 1, "orgComment"))
    ok(has(5, col(5, "bold"), "orgBold"))
    ok(has(5, col(5, "<2026"), "orgTimestamp"))
    ok(has(6, col(6, "[X]"), "orgCheckboxChecked"))
    ok(has(6, col(6, "[1/2]"), "orgStatistic"))
    ok(has(7, 1, "orgTable"))
    ok(has(8, 1, "orgDrawer"))
    ok(has(9, 1, "orgPropertyKey"))
    ok(has(11, col(11, "[fn:1]"), "orgFootnote"))
    ok(has(12, 1, "orgBlockDelimiter"))
    for l = 2, 14 do
      ok(has(l, 1, "orgBlock"), "line " .. l)
    end
    -- the begin and end lines stay the outer block's
    ok(has(1, 1, "orgBlockDelimiter"))
    ok(has(15, 1, "orgBlockDelimiter"))
  end)

  it("parses lines escaped with a comma as typed: no headline, no keyword", function()
    org_buffer({
      "#+begin_src org",
      ",* TODO A headline :tag:",
      ",#+TITLE: x",
      "#+end_src",
    }, { 1, 0 })
    for c = 1, #vim.fn.getline(2) do
      ok(not has(2, c, "orgHeadlineLevel1") and not has(2, c, "orgTodo") and not has(2, c, "orgTags"))
    end
    ok(not has(3, col(3, "x"), "orgTitle") and not has(3, 2, "orgKeyword"))
    ok(has(2, 1, "orgBlock"))
  end)

  it("hides nothing in the body, the markers that would be hidden drawn as text", function()
    vim.wo.conceallevel = 2
    org_buffer({
      "#+begin_src org",
      "Some *bold* and [[https://orgmode.org][a link]].",
      "#+end_src",
      "Some *bold* and [[https://orgmode.org][a link]].",
    }, { 1, 0 })
    vim.wo.conceallevel = 2
    local star = col(2, "*")
    ok(not hidden(2, star))
    ok(not has(2, star, "orgBoldDelimiter") and not has(2, star, "orgBold"))
    ok(has(2, star + 1, "orgBold"))
    ok(not hidden(2, col(2, "[[")))
    ok(has(2, col(2, "[["), "orgLink"))
    -- (outside the block they are hidden)
    ok(hidden(4, col(4, "*")))
    ok(hidden(4, col(4, "[[")))
  end)

  it("draws org export and example blocks the same, not other languages or ORG", function()
    org_buffer({
      "#+begin_export org",
      "*bold*",
      "#+end_export",
      "#+begin_example org",
      "*bold*",
      "#+end_example",
      "#+begin_src ORG",
      "*bold*",
      "#+end_src",
      "#+begin_src sh",
      "*bold*",
      "#+end_src",
      "#+begin_quote org",
      "*bold*",
      "#+end_quote",
    }, { 1, 0 })
    ok(has(2, 2, "orgBold"))
    ok(has(5, 2, "orgBold"))
    ok(not has(8, 2, "orgBold"))
    ok(not has(11, 2, "orgBold"))
    -- (a quote block's body is Org text anyway)
    ok(has(14, 2, "orgBold"))
  end)

  it("follows src_lang_modes, and draws plain orgBlock with src highlighting off", function()
    require("org.config").opts.src_lang_modes = { orgmode = "org" }
    org_buffer({ "#+begin_src orgmode", "*bold*", "#+end_src" }, { 1, 0 })
    ok(has(2, 2, "orgBold"))
    require("org.config").opts.src_lang_modes = nil
    require("org.config").opts.ui.src_highlight = false
    org_buffer({ "#+begin_src org", "*bold*", "#+end_src" }, { 1, 0 })
    ok(not has(2, 2, "orgBold"))
    ok(has(2, 2, "orgBlock"))
    require("org.config").opts.ui.src_highlight = nil
  end)

  it("keeps a block in the body closed at the body's end", function()
    org_buffer({
      "#+begin_src org",
      "#+begin_quote",
      "*q*",
      "#+end_src",
      "#+end_quote",
      "*after*",
    }, { 1, 0 })
    -- the quote has no end line in the body: no block there (Emacs's Org
    -- buffer of the body ends before "#+end_quote")
    ok(not has(2, 1, "orgBlockDelimiter"))
    ok(not has(3, 2, "orgQuoteBlock"))
    ok(has(3, 2, "orgBold"))
    ok(has(3, 2, "orgBlock"))
  end)

  it("draws a row alone like the whole buffer", function()
    for _, seed in ipairs(fuzz.seeds(8)) do
      local rng = fuzz.rng(seed)
      local lines = { "* H", "#+begin_src org" }
      for _, l in ipairs(fuzz.doc(rng)) do
        -- (escaped as org-escape-code-in-string does)
        local ind, rest = l:match("^([ \t]*)(.*)$")
        if rest:find("^,*%*") or rest:find("^,*#%+") then
          l = ind .. "," .. rest
        end
        lines[#lines + 1] = l
      end
      vim.list_extend(lines, { "#+end_src", "after *b*" })
      local buf = org_buffer(lines, { 1, 0 })
      local ui = deco.ui_options(buf)
      local whole = {}
      H.add_marks(buf, 0, #lines - 1, ui, whole)
      for row = 0, #lines - 1 do
        local alone = {}
        H.add_marks(buf, row, row, ui, alone)
        if keys(whole, row) ~= keys(alone, row) then
          error(fuzz.report(seed, "row " .. row .. " drawn alone differs", lines, lines))
        end
      end
    end
  end)

  it("draws a row of a long body from the lines around it", function()
    local lines = { "* H", "#+begin_src org" }
    for i = 1, 2500 do
      lines[#lines + 1] = "Some *bold* text " .. i
    end
    vim.list_extend(lines, { "#+end_src", "* After" })
    local buf = org_buffer(lines, { 1, 0 })
    local ui = deco.ui_options(buf)
    local real = vim.api.nvim_buf_get_lines
    local fetched = 0
    vim.api.nvim_buf_get_lines = function(b, s, e, strict)
      local r = real(b, s, e, strict)
      fetched = fetched + #r
      return r
    end
    local rows = {}
    local ok_, err = pcall(H.add_marks, buf, 1200, 1250, ui, rows)
    vim.api.nvim_buf_get_lines = real
    assert(ok_, err)
    ok(keys(rows, 1200):find("orgBold", 1, true))
    -- (the window around the rows and the look back up to the headline,
    -- for the buffer and for the body: never the whole body twice over)
    ok(fetched < 4 * #lines, fetched)
  end)
end)

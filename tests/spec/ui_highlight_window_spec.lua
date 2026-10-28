-- The parser highlighter draws a row from a window of the lines around it
-- (org.ui.highlight `window_of`): a row must be drawn the same whatever the
-- window, as in a scan of the whole buffer. Macros and footnote references
-- run on over lines that separate paragraphs (a keyword line, a list
-- item), so the window grows over them.
local fuzz = require("tests.helpers.fuzz")

local deco = require("org.ui.decorations")
local H = require("org.ui.highlight")

--- The marks of a row as one string.
local function key(t)
  local out = {}
  for _, m in ipairs(t or {}) do
    local o = vim.tbl_extend("force", {}, m[2])
    o.ephemeral = nil
    out[#out + 1] = m[1] .. ":" .. vim.inspect(o, { newline = "", indent = "" })
  end
  table.sort(out)
  return table.concat(out, " ")
end

local function ui_of(buf)
  return deco.ui_options(buf, H.file_in_use(buf))
end

--- The first row of `lines` drawn by some window of `heights` rows other
--- than as the whole buffer draws it: nil, or row, first, last.
local function differs(lines, heights)
  local buf = org_buffer(lines, { 1, 0 })
  local ui = ui_of(buf)
  local n = #lines
  local whole = {}
  H.add_marks(buf, 0, n - 1, ui, whole)
  for _, h in ipairs(heights) do
    for first = 0, n - 1 do
      local last = math.min(n - 1, first + h - 1)
      local rows = {}
      H.add_marks(buf, first, last, ui, rows)
      for row = first, last do
        if key(whole[row]) ~= key(rows[row]) then
          return row, first, last
        end
      end
    end
  end
end

-- What the fragments of a fuzzed document are made of: macros and
-- footnote references opened and closed on different lines, and the lines
-- between them (separating paragraphs or not).
local PIECES = {
  "{{{m(a",
  "{{{title}}}",
  "b)}}}",
  "}}}",
  "x {{{n",
  "[fn:x: a",
  "[fn::anon",
  "text [fn:1] more",
  "[fn:y] definition",
  "]",
  "c] d",
  "e (f",
  'a "q',
  'q]"',
  "[[link][desc",
  "desc]]",
  "#+TITLE: t",
  "#+begin_quote",
  "#+end_quote",
  "- item",
  "1. item",
  "",
  "  ",
  "* H",
  "** H2 {{{m(",
  "text",
  "*bold",
  "bold*",
  "| a | b |",
  ":PROPERTIES:",
  ":END:",
  "-----",
  "# comment {{{x",
  ": fixed",
  "CLOCK: => 1:00",
}

local function fragment(rng)
  local lines = {}
  for i = 1, rng:int(3, 14) do
    local l = rng:pick(PIECES)
    if rng:chance(0.3) then
      l = l .. " " .. rng:pick(PIECES)
    end
    lines[i] = l
  end
  return lines
end

describe("parser highlighter windows", function()
  with_config({ ui = { hide_emphasis_markers = true } })

  it("draws macros and footnotes over separating lines whatever the window", function()
    for _, lines in ipairs({
      { "para {{{m(a", "#+TITLE: x", "b)}}} after" },
      { "- a {{{m(", "- b", "- c", "- d )}}} e", "- f", "g" },
      { "x [fn:: a", "#+TITLE: t", "- item", "b] y" },
      { "x [fn:: a", "", "", "b] y", "* H" },
      { "* H {{{m(", "#+KEY: v", "x)}}}" },
      -- (not over a headline)
      { "x {{{m(", "* H", "y)}}}" },
      { "x [fn:: a", "* H", "b] y" },
      -- (nor over an empty line, macros only)
      { "x {{{m(", "#+K: v", "", "y)}}}" },
      -- (a long paragraph: the window starts PARAGRAPH lines up)
      (function()
        local t = { "a {{{m(" }
        for i = 1, 80 do
          t[#t + 1] = "- line " .. i
        end
        t[#t + 1] = "b)}}} c"
        return t
      end)(),
    }) do
      local row, first, last = differs(lines, { 1, 2, 3, 5 })
      eq(nil, row, vim.inspect({ lines = lines, row = row, window = { first, last } }))
    end
  end)

  it("draws every row of random fragments the same whatever the window", function()
    for _, seed in ipairs(fuzz.seeds(150)) do
      local rng = fuzz.rng(seed)
      local lines = fragment(rng)
      local row, first, last = differs(lines, { 1, 3 })
      if row then
        error(
          fuzz.report(
            seed,
            ("row %d drawn from rows %d-%d differs from the whole buffer"):format(row, first, last),
            lines,
            lines
          )
        )
      end
    end
  end)

  it("draws the rows on screen the same whatever the scroll", function()
    local lines = {}
    for i = 1, 12 do
      vim.list_extend(lines, { "para " .. i .. " {{{m(a", "#+TITLE: x", "- item [fn:: b", "#+K: v", "c] d)}}} e" })
    end
    local buf = org_buffer(lines, { 1, 0 })
    local whole = {}
    H.add_marks(buf, 0, #lines - 1, ui_of(buf), whole)
    vim.cmd("resize 5")
    for top = 1, #lines - 4 do
      deco.render(buf, true)
      vim.fn.winrestview({ topline = top })
      vim.cmd("redraw")
      for row = top - 1, vim.fn.line("w$") - 1 do
        local got = {}
        for _, m in ipairs(deco.line_marks(buf, row)) do
          if m[3] == "parser" then
            got[#got + 1] = { m[1], m[2] }
          end
        end
        eq(key(whole[row]), key(got), ("row %d, window from %d"):format(row, top - 1))
      end
    end
    vim.cmd("resize")
  end)

  it("draws the rows kept over edits as a fresh scan does", function()
    -- an opening typed above rows drawn before (in other windows), and a
    -- closing removed: the rows below it are drawn again
    for _, case in ipairs({
      { { "a {{m(", "#+K: v", "- b", "- b2", "- b3", "- c)}}} d", "e" }, 0, 2, "{" },
      { { "a {{{m(", "#+K: v", "- b", "- b2", "- b3", "- c)}}} d", "- e)}}} f" }, 5, 3, "" },
      { { "a [f:: x", "#+K: v", "- b", "- b2", "- b3", "- c] d", "e" }, 0, 3, "n" },
      { { "a [fn:: x", "#+K: v", "- b", "- b2", "- b3", "- c] d", "- e] f" }, 5, 4, "" },
      { { "a [fn:: x", "#+K: v", "- b", "- b2", "- b3", "- c] d", "- e] f" }, 5, 4, "[" },
    }) do
      local lines, row, col, text = case[1], case[2], case[3], case[4]
      local buf = org_buffer(lines, { 1, 0 })
      -- (each row drawn alone, as windows that show one row each would)
      for r = 0, #lines - 1 do
        deco.line_marks(buf, r)
      end
      if text == "" then
        vim.api.nvim_buf_set_text(buf, row, col, row, col + 1, {})
      else
        vim.api.nvim_buf_set_text(buf, row, col, row, col, { text })
      end
      local ui = ui_of(buf)
      local now = buf_lines(buf)
      local whole = {}
      H.add_marks(buf, 0, #now - 1, ui, whole)
      for r = 0, #now - 1 do
        local got = {}
        for _, m in ipairs(deco.line_marks(buf, r)) do
          if m[3] == "parser" then
            got[#got + 1] = { m[1], m[2] }
          end
        end
        eq(key(whole[r]), key(got), vim.inspect({ lines = now, row = r }))
      end
    end
  end)
end)

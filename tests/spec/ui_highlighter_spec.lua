-- ui.highlighter = "parser": emphasis and the hidden parts of links drawn
-- by the decorations (org.ui.emphasis) instead of syntax regions. What it
-- draws is checked against Emacs in emacs_fontify_parity_spec.lua; this
-- spec checks the rest: no syntax regions, no 'synmaxcol' limit, spelling,
-- the toggles, the cursor and drawing any part of a buffer alone.
local fuzz = require("tests.helpers.fuzz")
local hl = require("tests.helpers.highlighter")

local deco = require("org.ui.decorations")

--- The marks the decorations draw on 0-based row `row`, as
--- "group@start-end" (or "conceal@..."), sorted.
local function marks(buf, row)
  local out = {}
  for _, m in ipairs(deco.line_marks(buf, row)) do
    local o = m[2]
    -- (orgSrcBlock: the block part's mark under a src block's body, with
    -- no attributes; this spec is about emphasis and links)
    for _, name in ipairs({
      o.hl_group ~= "orgSrcBlock" and o.hl_group or false,
      o.conceal == "" and "conceal" or false,
    }) do
      if name then
        out[#out + 1] = string.format("%s@%d-%d", name, m[1], o.end_col or m[1] + 1)
      end
    end
  end
  table.sort(out)
  return out
end

local function has(list, item)
  return vim.tbl_contains(list, item)
end

describe("ui.highlighter = parser", function()
  with_config({ ui = { highlighter = "parser", hide_emphasis_markers = true } })

  it("defines no emphasis regions and draws the emphasis as marks", function()
    local buf = org_buffer({ "a *bold* and =code= x" }, { 1, 0 })
    for c = 1, 21 do
      for _, id in ipairs(vim.fn.synstack(1, c)) do
        ok(not vim.fn.synIDattr(id, "name"):find("^org[BVC][oe]"), vim.fn.synIDattr(id, "name"))
      end
    end
    local m = marks(buf, 0)
    ok(has(m, "orgBold@3-7"), vim.inspect(m))
    ok(has(m, "orgBoldDelimiter@2-3") and has(m, "orgBoldDelimiter@7-8"), vim.inspect(m))
    ok(has(m, "conceal@2-3") and has(m, "conceal@7-8"), vim.inspect(m))
    ok(has(m, "orgVerbatim@14-18"), vim.inspect(m))
  end)

  it("hides link brackets with marks, not with the syntax", function()
    local buf = org_buffer({ "see [[https://x.org][site]] end" }, { 1, 0 })
    vim.wo.conceallevel = 2
    for c = 1, 31 do
      eq(0, vim.fn.synconcealed(1, c)[1])
    end
    -- (the link's face is a mark too: org.ui.highlight.object)
    local function hidden()
      return vim.tbl_filter(function(m)
        return m:find("^conceal@") ~= nil
      end, marks(buf, 0))
    end
    eq({ "conceal@25-27", "conceal@4-21" }, hidden())
    ok(has(marks(buf, 0), "orgLink@4-27"))
    -- org-toggle-link-display: shown literally
    require("org.links").toggle_link_display()
    eq({}, hidden())
    require("org.links").toggle_link_display()
    eq({ "conceal@25-27", "conceal@4-21" }, hidden())
  end)

  it("draws markup past 'synmaxcol' and on very long lines", function()
    local long = string.rep("word ", 20000) .. "*bold* end"
    local buf = org_buffer({ long, "next *b*" }, { 1, 0 })
    ok(vim.bo.synmaxcol > 0 and vim.bo.synmaxcol < #long)
    local m = marks(buf, 0)
    ok(has(m, string.format("orgBold@%d-%d", 100001, 100005)), vim.inspect(m))
    ok(has(marks(buf, 1), "orgBold@6-7"))
  end)

  it("draws a long line full of unclosed markers in linear time", function()
    local function time(n)
      local buf = org_buffer({ string.rep("*a /b _c =d ", n) }, { 1, 0 })
      local t = vim.uv.hrtime()
      marks(buf, 0)
      return (vim.uv.hrtime() - t) / 1e6
    end
    time(100)
    local small, big = time(2000), time(20000)
    -- ten times the text, well under a hundred times the time
    ok(big < math.max(small, 1) * 40, string.format("%.1f ms then %.1f ms", small, big))
  end)

  it("leaves verbatim and code out of spell checking", function()
    local buf = org_buffer({ "*bold* =verbatim= ~code~" }, { 1, 0 })
    for _, m in ipairs(deco.line_marks(buf, 0)) do
      local g = m[2].hl_group or ""
      if g:find("^orgVerbatim") or g:find("^orgCode") then
        eq(false, m[2].spell)
      elseif g:find("^orgBold") then
        eq(nil, m[2].spell)
      end
    end
  end)

  it("follows b:org_hide_emphasis_markers (presentation slides)", function()
    local buf = org_buffer({ "a *b* c" }, { 1, 0 })
    ok(has(marks(buf, 0), "conceal@2-3"))
    vim.b[buf].org_hide_emphasis_markers = false
    deco.render(buf)
    ok(not has(marks(buf, 0), "conceal@2-3"))
    ok(has(marks(buf, 0), "orgBoldDelimiter@2-3"))
  end)

  it("draws nothing in a src block that starts far above the window", function()
    local lines = { "* H", "#+begin_src lua" }
    for i = 1, 400 do
      lines[#lines + 1] = "x = *a* -- [[l]] " .. i
    end
    lines[#lines + 1] = "#+end_src"
    lines[#lines + 1] = "*after*"
    local buf = org_buffer(lines, { 1, 0 })
    eq({}, marks(buf, 300))
    eq({}, marks(buf, 401))
    ok(has(marks(buf, #lines - 1), "orgBold@1-6"))
  end)

  it("draws a row alone as it draws it with the whole buffer", function()
    -- the scan starts two lines above the rows asked for, in the block
    -- state there: any row drawn alone gets the marks it gets in a scan of
    -- the whole buffer
    local E = require("org.ui.emphasis")
    for _, seed in ipairs(fuzz.seeds(12)) do
      local rng = fuzz.rng(seed)
      local lines = fuzz.doc(rng)
      local opts = { hide_markers = true, conceal_links = true }
      local whole = {}
      E.marks(lines, 0, 0, #lines - 1, opts, whole)
      local buf = org_buffer(lines, { 1, 0 })
      for row = 0, #lines - 1 do
        local alone = {}
        E.add_marks(buf, row, row, require("org.config").opts.ui, alone)
        local function key(t)
          local out = {}
          for _, m in ipairs(t or {}) do
            out[#out + 1] = m[1] .. ":" .. vim.inspect(m[2], { newline = "", indent = "" })
          end
          table.sort(out)
          return table.concat(out, " ")
        end
        if key(whole[row]) ~= key(alone[row]) then
          error(fuzz.report(seed, "row " .. row .. " drawn alone differs", lines, lines))
        end
      end
    end
  end)

  it("draws a row alone like the whole buffer: links over lines, blocks far up", function()
    local E = require("org.ui.emphasis")
    local cases = {
      { "a", "see [[a][first", "second", "third", "fourth]] end", "b" },
      { "x [[a][b", "* H2", "c]] y" },
    }
    -- a src block with no headline within the look back
    local far = {}
    for i = 1, 3100 do
      far[i] = "text " .. i
    end
    vim.list_extend(far, { "#+begin_src python", "x = '*y*'", "x = '*y*'", "x = '*y*'", "#+end_src", "*z*" })
    cases[#cases + 1] = far
    for _, lines in ipairs(cases) do
      local whole = {}
      E.marks(lines, 0, 0, #lines - 1, { hide_markers = true, conceal_links = true }, whole)
      local buf = org_buffer(lines, { 1, 0 })
      for row = math.max(0, #lines - 8), #lines - 1 do
        local alone = {}
        E.add_marks(buf, row, row, require("org.config").opts.ui, alone)
        eq(vim.inspect(whole[row]), vim.inspect(alone[row]), "row " .. row .. ": " .. lines[row + 1])
      end
    end
  end)

  it("moves the cursor over hidden markers and link brackets", function()
    vim.cmd("syntax on")
    local function press(keys)
      vim.cmd("normal! " .. keys)
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
    end
    local function col()
      return vim.api.nvim_win_get_cursor(0)[2]
    end
    org_buffer({ "See [[https://example.org][the site]] end" }, { 1, 2 })
    eq(2, vim.wo.conceallevel)
    -- "See " 0-3, "[[https://example.org][" 4-26, "the site" 27-34
    press("l")
    eq(3, col())
    press("l")
    eq(27, col())
    org_buffer({ "a *bold* b" }, { 1, 0 })
    vim.wo.conceallevel = 2
    press("l")
    press("l")
    eq(3, col())
  end)

  it("is turned on and off by b:org_ui", function()
    require("org.config").opts.ui.highlighter = "syntax"
    local buf = org_buffer({ "a *b* c" }, { 1, 0 })
    hl.use(buf, "syntax")
    eq({}, marks(buf, 0))
    local found = false
    for _, id in ipairs(vim.fn.synstack(1, 4)) do
      found = found or vim.fn.synIDattr(id, "name"):lower() == "orgbold"
    end
    ok(found)
    vim.cmd("enew!")
    local b2 = vim.api.nvim_get_current_buf()
    vim.bo[b2].bufhidden = "wipe"
    vim.b[b2].org_ui = { highlighter = "parser" }
    vim.api.nvim_buf_set_lines(b2, 0, -1, false, { "a *b* c" })
    vim.bo[b2].filetype = "org"
    ok(has(marks(b2, 0), "orgBold@3-4"), vim.inspect(marks(b2, 0)))
    require("org.config").opts.ui.highlighter = "parser"
  end)

  it("leaves the syntax regions to a buffer with only the org syntax (drill)", function()
    vim.cmd("enew!")
    local b = vim.api.nvim_get_current_buf()
    vim.bo[b].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "A *bold* word" })
    vim.bo[b].filetype = "org_drill"
    vim.bo[b].syntax = "org"
    local names = vim.tbl_map(function(id)
      return vim.fn.synIDattr(id, "name"):lower()
    end, vim.fn.synstack(1, 4))
    ok(vim.tbl_contains(names, "orgbold"), vim.inspect(names))
  end)

  it("gives a LaTeX preview with foreground auto the emphasis color", function()
    require("org.config").opts.ui.latex_preview = { foreground = "auto" }
    vim.api.nvim_set_hl(0, "OrgBold", { fg = "#ff0000", bold = true })
    local buf = org_buffer({ "text *bold $x^2$ here* end" }, { 1, 0 })
    eq("1.000,0.000,0.000", require("org.ui.images")._foreground(buf, 0, 11))
    require("org.config").opts.ui.latex_preview = nil
  end)

  it("the test helper sees the same on both sides of a plain case", function()
    local buf = org_buffer({ "*a* /b/ =c=" }, { 1, 0 })
    vim.wo.conceallevel = 2
    eq(hl.emacs_codes(buf, "syntax"), hl.emacs_codes(buf, "parser"))
    hl.use(buf, "parser")
  end)
end)

-- Typing keeps the marks of the rows an edit can't change
-- (org.ui.decorations `carried`): after every edit, each row must be drawn
-- as a fresh scan of the buffer draws it.
describe("ui.highlighter = parser, after an edit inside a line", function()
  with_config({
    ui = {
      highlighter = "parser",
      hide_emphasis_markers = true,
      indent_mode = true,
      pretty_entities = true,
      bullets = { "◉", "○" },
      checkboxes = { " ", "◐", "✓" },
    },
  })

  --- Every row's marks, as one string per row: as drawn (`fresh`: as a
  --- scan of that row alone draws them, with the same parse).
  local function all_marks(buf, fresh)
    local ui = fresh and deco.ui_options(buf, require("org.ui.highlight").file_in_use(buf))
    local out = {}
    for row = 0, vim.api.nvim_buf_line_count(buf) - 1 do
      local t = {}
      local marks = fresh and deco.compute(buf, row, row, ui)[row] or not fresh and deco.line_marks(buf, row) or {}
      for _, m in ipairs(marks) do
        local o = vim.tbl_extend("force", {}, m[2])
        o.ephemeral = nil
        t[#t + 1] = m[1] .. ":" .. vim.inspect(o, { newline = "", indent = "" })
      end
      table.sort(t)
      out[row + 1] = table.concat(t, " ")
    end
    return out
  end

  --- The inline marks drawn on screen (org.ui.decorations `sync_inline`),
  --- after a redraw.
  local function inline_marks(buf)
    vim.cmd("redraw")
    local ns = vim.api.nvim_create_namespace("org.decorations.inline")
    local t = {}
    local top, bot = vim.fn.line("w0") - 1, vim.fn.line("w$") - 1
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { top, 0 }, { bot, -1 }, { details = true })) do
      local d = m[4]
      d.ns_id = nil
      t[#t + 1] = m[2] .. ":" .. m[3] .. vim.inspect(d, { newline = "", indent = "" })
    end
    table.sort(t)
    return table.concat(t, "\n")
  end

  -- what an edit inserts: plain text, markup markers, link and footnote
  -- brackets, and what keeps rows from being kept (a star, "#", "\")
  local CHARS = { "a", "x", " ", " ", "*", "/", "=", "~", "+", "_", "[", "]", "<", ">", "{", "}", "(", ")", '"' }
  vim.list_extend(CHARS, { "\\", "#", ":", "|", "-", "$", "^", "1", ".", "@", "\t" })

  local root = vim.fn.getcwd() .. "/tests/fixtures/emacs/faces/"
  local fixtures = {}
  for _, f in ipairs({ "headline", "list", "date", "meta", "table", "block", "object" }) do
    vim.list_extend(fixtures, vim.fn.readfile(root .. f .. ".org"))
  end

  it("draws every row as a fresh scan does, and keeps rows", function()
    local carried = deco._carried
    for _, seed in ipairs(fuzz.seeds(4)) do
      local rng = fuzz.rng(seed)
      local lines = fuzz.doc(rng, { crlf = false })
      -- (and a part of the Emacs faces cases)
      local from = rng:int(1, #fixtures - 40)
      vim.list_extend(lines, vim.list_slice(fixtures, from, from + 40))
      local buf = org_buffer(lines, { 1, 0 })
      all_marks(buf)
      for _ = 1, 25 do
        local n = vim.api.nvim_buf_line_count(buf)
        local row = rng:int(0, n - 1)
        local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
        local col = rng:int(0, #line)
        if #line > 0 and rng:chance(0.3) then
          col = math.min(col, #line - 1)
          vim.api.nvim_buf_set_text(buf, row, col, row, col + 1, {})
        else
          vim.api.nvim_buf_set_text(buf, row, col, row, col, { rng:pick(CHARS) })
        end
        local kept = all_marks(buf)
        local fresh = all_marks(buf, true)
        local now = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        for i = 1, #fresh do
          if kept[i] ~= fresh[i] then
            error(fuzz.report(seed, ("row %d drawn after an edit of row %d differs"):format(i - 1, row), now, now))
          end
        end
        -- and the inline marks (indent mode) of the rows on screen
        vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
        local inline = inline_marks(buf)
        deco.render(buf)
        if inline ~= inline_marks(buf) then
          error(fuzz.report(seed, ("inline marks after an edit of row %d differ"):format(row), now, now))
        end
        -- (the redraw computed the rows on screen together, whose marks
        -- can differ from those of each row alone: a macro over a list
        -- item; each row alone again, without a redraw)
        deco.render(buf, true)
        all_marks(buf)
      end
    end
    -- (rows were kept, not only drawn again)
    ok(deco._carried > carried)
  end)
end)

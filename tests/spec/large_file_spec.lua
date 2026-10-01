-- Caches that are updated per edit must agree with a full recompute.
local fold = require("org.fold")

--- A deterministic pseudo-random generator (independent of math.random).
local function prng(seed)
  local s = seed
  return function(n)
    s = (s * 1103515245 + 12345) % 2147483648
    return s % n + 1
  end
end

local SNIPPETS = {
  { "* Top" },
  { "** Child" },
  { "*** Grandchild" },
  { "" },
  { "", "" },
  { "text" },
  { ":PROPERTIES:", ":ID: x", ":END:" },
  { ":LOGBOOK:" },
  { ":END:" },
  { "#+begin_src lua", "print(1)", "#+end_src" },
  { "#+begin_quote" },
  { "#+end_quote" },
  { "- item", "  more" },
  { "- [ ] task" },
  { "  continued" },
  { "1. one", "2. two", "   two more" },
  { "#+RESULTS:", ": out" },
  { "*************** inline", "body", "*************** END" },
  { "*bold* not a headline" },
}

local function base_lines(n)
  local out = {}
  for i = 1, n do
    out[#out + 1] = "* H" .. i
    out[#out + 1] = ":PROPERTIES:"
    out[#out + 1] = ":ID: " .. i
    out[#out + 1] = ":END:"
    out[#out + 1] = "- a"
    out[#out + 1] = "  b"
    out[#out + 1] = "** Sub " .. i
    out[#out + 1] = "#+begin_src sh"
    out[#out + 1] = "ls"
    out[#out + 1] = "#+end_src"
    out[#out + 1] = ""
    out[#out + 1] = ""
  end
  return out
end

local function check(buf, label)
  local expected = fold.compute(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  local actual = {}
  vim.api.nvim_buf_call(buf, function()
    for l = 1, vim.api.nvim_buf_line_count(buf) do
      actual[l] = fold.foldexpr(l)
    end
  end)
  eq(expected, actual, label)
end

describe("large files: incremental fold levels", function()
  with_config({ inlinetask_min_level = 15 })

  it("match a full recompute after random edits", function()
    local buf = org_buffer(base_lines(20), { 1, 0 })
    fold.setup_buffer(buf)
    check(buf, "initial")
    local rand = prng(42)
    for step = 1, 400 do
      local n = vim.api.nvim_buf_line_count(buf)
      local op = rand(4)
      local at = rand(n) - 1
      if op == 1 then
        vim.api.nvim_buf_set_lines(buf, at, at, false, SNIPPETS[rand(#SNIPPETS)])
      elseif op == 2 and n > 5 then
        vim.api.nvim_buf_set_lines(buf, at, math.min(n, at + rand(3)), false, {})
      elseif op == 3 then
        vim.api.nvim_buf_set_lines(buf, at, at + 1, false, SNIPPETS[rand(#SNIPPETS)])
      else
        -- several edits before the next lookup
        for _ = 1, 3 do
          local m = vim.api.nvim_buf_line_count(buf)
          local a = rand(m) - 1
          vim.api.nvim_buf_set_lines(buf, a, a + rand(2) - 1, false, SNIPPETS[rand(#SNIPPETS)])
        end
      end
      check(buf, "step " .. step)
    end
  end)

  it("give the regions of a range like those of the whole buffer", function()
    local buf = org_buffer(base_lines(10), { 1, 0 })
    fold.setup_buffer(buf)
    local rand = prng(3)
    local function key(r)
      return r.kind .. ":" .. r.start .. "-" .. tostring(r["end"])
    end
    for step = 1, 60 do
      local n = vim.api.nvim_buf_line_count(buf)
      local at = rand(n) - 1
      vim.api.nvim_buf_set_lines(buf, at, at + rand(2) - 1, false, SNIPPETS[rand(#SNIPPETS)])
      n = vim.api.nvim_buf_line_count(buf)
      local s = rand(n)
      local e = math.min(n, s + rand(15) - 1)
      local _, all = fold.compute(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      local want, got = {}, {}
      for _, r in ipairs(all) do
        if r.start >= s and r.start <= e then
          want[#want + 1] = key(r)
        end
      end
      vim.api.nvim_buf_call(buf, function()
        fold.foldexpr(1) -- the levels are current
        for _, r in ipairs(fold._regions(buf, s, e)) do
          if r.start >= s and r.start <= e then
            got[#got + 1] = key(r)
          end
        end
      end)
      eq(want, got, ("step %d, lines %d-%d"):format(step, s, e))
    end
  end)

  it("follow normal mode and Ex edits", function()
    local buf = org_buffer(base_lines(8), { 1, 0 })
    fold.setup_buffer(buf)
    vim.cmd("normal! zR")
    check(buf, "initial")
    local steps = {
      "normal! 3Gdd",
      "normal! 2Gyyp",
      "normal! 5G3J",
      "normal! 7G>>",
      "normal! Go* End",
      "normal! ggO",
      "normal! 12GcW* Converted",
      "normal! 20Gi** \27",
      "normal! 30Gx",
      "normal! 1G2dd",
      "normal! 40Gd3j",
      "normal! 44GVjd",
      "normal! 9Gp",
      "normal! 15G\22jjI  \27",
      "%s/^\\*\\* /*** /",
      "g/^:END:/d",
      "normal! u",
      "normal! u",
      "redo",
      "3,10sort",
      "normal! 25GA\r- new item\r** new head\27",
      "normal! 50GoText\r\r\r* Sep\27",
      "%d",
      "normal! u",
    }
    for _, cmd in ipairs(steps) do
      vim.cmd(cmd)
      check(buf, cmd)
    end
  end)

  it("give Neovim the same folds as a full recompute, undo included", function()
    -- the reference: every lookup recomputes the whole buffer (the old way)
    local ref_cache = {}
    _G.__org_ref_foldexpr = function(l)
      local b = vim.api.nvim_get_current_buf()
      local tick = vim.api.nvim_buf_get_changedtick(b)
      if not ref_cache[b] or ref_cache[b].tick ~= tick then
        ref_cache[b] = { tick = tick, levels = fold.compute(vim.api.nvim_buf_get_lines(b, 0, -1, false)) }
      end
      return ref_cache[b].levels[l] or 0
    end
    local lines = base_lines(6)
    local buf = org_buffer(lines, { 1, 0 })
    fold.setup_buffer(buf)
    local win = vim.api.nvim_get_current_win()
    vim.cmd("new")
    local ref_win = vim.api.nvim_get_current_win()
    local ref = vim.api.nvim_get_current_buf()
    vim.bo[ref].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(ref, 0, -1, false, lines)
    for _, o in ipairs({ "expandtab", "shiftwidth", "tabstop", "softtabstop" }) do
      vim.bo[ref][o] = vim.bo[buf][o]
    end
    vim.wo[ref_win].foldmethod = "expr"
    vim.wo[ref_win].foldexpr = "v:lua.__org_ref_foldexpr(v:lnum)"
    local function folds(w)
      local out = {}
      vim.api.nvim_win_call(w, function()
        for l = 1, vim.fn.line("$") do
          out[l] = vim.fn.foldlevel(l)
        end
      end)
      return out
    end
    for _, w in ipairs({ win, ref_win }) do
      vim.api.nvim_win_call(w, function()
        vim.cmd("normal! zR")
        vim.bo.undolevels = vim.bo.undolevels -- start the undo history here
      end)
    end
    local steps = {
      "normal! 1Gx",
      "normal! u",
      "normal! 7G>>",
      "normal! u",
      "normal! 3Gdd",
      "normal! u",
      "normal! 2GO* New",
      "normal! u",
      "redo",
      "normal! 1Gi*\27",
      "normal! u",
      "normal! u",
      "%s/^\\*\\* /* /",
      "normal! u",
      "redo",
      "normal! 5Gyy3p",
      "normal! uu",
    }
    for _, cmd in ipairs(steps) do
      for _, w in ipairs({ win, ref_win }) do
        vim.api.nvim_win_call(w, function()
          vim.cmd(cmd)
        end)
      end
      eq(buf_lines(ref), buf_lines(buf), cmd .. " (text)")
      eq(folds(ref_win), folds(win), cmd)
    end
    vim.api.nvim_win_close(ref_win, true)
    _G.__org_ref_foldexpr = nil
  end)

  it("follow undo and redo", function()
    local buf = org_buffer(base_lines(5), { 1, 0 })
    fold.setup_buffer(buf)
    check(buf, "initial")
    vim.cmd("normal! 3Gdd")
    check(buf, "dd")
    vim.cmd("normal! Go* New")
    check(buf, "o")
    vim.cmd("normal! u")
    check(buf, "undo")
    vim.cmd("normal! u")
    check(buf, "undo 2")
    vim.cmd("redo")
    check(buf, "redo")
  end)
end)

describe("large files: textbuf writes back only the edited lines", function()
  it("matches the whole text after random edits", function()
    local textbuf = require("org.textbuf")
    local rand = prng(7)
    local pieces = { "\n", "\n\n", "x", "* H\n", "- item", " ", "text\nmore", "" }
    for round = 1, 60 do
      local lines = {}
      for i = 1, rand(12) do
        lines[i] = ({ "", "* A", "text", "- b", "  c" })[rand(5)]
      end
      local buf = org_buffer(lines, { 1, 0 })
      local tb = textbuf.from_buffer(buf, { rand(#lines), 0 })
      for _ = 1, 3 do
        for _ = 1, rand(4) do
          tb:goto_char(rand(#tb.text + 1))
          if rand(2) == 1 then
            tb:insert(pieces[rand(#pieces)])
          else
            local a = rand(#tb.text + 1)
            tb:delete(a, math.min(#tb.text + 1, a + rand(6) - 1))
          end
        end
        if rand(5) == 1 then
          tb.text = tb.text .. "direct\n" -- untracked write
        end
        tb:apply(false)
        eq(tb:lines(), buf_lines(buf), "round " .. round)
      end
    end
  end)
end)

describe("large files: decorations of a range", function()
  local deco = require("org.ui.decorations")
  local cfg = require("org.config").opts
  local saved
  before_each(function()
    saved = vim.deepcopy(cfg.ui)
    cfg.ui.bullets = { "◉", "○" }
    cfg.ui.checkboxes = { " ", "◐", "✓" }
    cfg.ui.indent_mode = true
    cfg.ui.pretty_entities = true
    cfg.ui.num = true
  end)
  after_each(function()
    cfg.ui = saved
  end)
  with_config({ inlinetask_min_level = 15 })

  local lines = {
    "#+TITLE: t",
    "intro \\alpha",
    "* A",
    "- [X] done \\beta",
    "#+begin_src lua",
    "x = \\gamma",
    "- [ ] not a box",
    "#+end_src",
    "** B",
    "text x^2",
    "*************** inline",
    "- [-] partial",
    "*************** END",
    "* C",
    "#+begin_example",
    "** not closed",
    "after \\delta",
  }

  it("match the whole-buffer computation", function()
    local buf = org_buffer(lines)
    local all = deco.compute(buf)
    for first = 0, #lines - 1 do
      for last = first, #lines - 1 do
        local part = deco.compute(buf, first, last)
        for row = 0, #lines - 1 do
          local want = (row >= first and row <= last) and all[row] or nil
          eq(vim.inspect(want), vim.inspect(part[row]), ("rows %d-%d, row %d"):format(first, last, row))
        end
      end
    end
  end)

  it("keep indent-mode inline marks right after edits", function()
    local ns_inline = vim.api.nvim_create_namespace("org.decorations.inline")
    vim.cmd("only") -- marks are synced for the rows windows draw: all of them here
    local buf = org_buffer(lines, { 1, 0 })
    deco.attach(buf)
    vim.cmd("redraw")
    local function inline_marks()
      local out = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns_inline, 0, -1, { details = true })) do
        out[#out + 1] = m[2] .. ":" .. m[3] .. ":" .. m[4].virt_text_pos
      end
      table.sort(out)
      return out
    end
    local function expected()
      local out = {}
      for row, marks in pairs(deco.compute(buf)) do
        for _, m in ipairs(marks) do
          if m[3] or m[2].virt_text_pos == "inline" then
            out[#out + 1] = row .. ":" .. m[1] .. ":" .. m[2].virt_text_pos
          end
        end
      end
      table.sort(out)
      return out
    end
    eq(expected(), inline_marks(), "initial")
    vim.api.nvim_buf_set_lines(buf, 8, 9, false, { "*** B deeper" })
    vim.cmd("redraw")
    eq(expected(), inline_marks(), "after promoting")
    vim.api.nvim_buf_set_lines(buf, 2, 4, false, {})
    vim.cmd("redraw")
    eq(expected(), inline_marks(), "after deleting")
  end)
end)

describe("large files: startup visibility", function()
  with_config({ startup_folded = "overview" })
  local function closed_lines()
    local out = {}
    for l = 1, vim.fn.line("$") do
      out[l] = vim.fn.foldclosed(l)
    end
    return out
  end

  local function open_file(lines)
    local path = vim.fn.tempname() .. ".org"
    vim.fn.writefile(lines, path)
    vim.cmd("silent! only")
    vim.cmd("enew!")
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    return path
  end

  local lines = {
    "#+TITLE: t",
    "* A",
    ":PROPERTIES:",
    ":ID: a",
    ":END:",
    "text",
    "#+begin_src sh",
    "ls",
    "#+end_src",
    "** B",
    ":LOGBOOK:",
    "- note",
    ":END:",
    "* C :ARCHIVE:",
    "** D",
    "body",
    "* E",
    "- item",
    "  more",
  }

  it("folds like the full startup visibility", function()
    local path = open_file(lines)
    local fast = closed_lines()
    eq(2, fast[2], "headline folded")
    require("org.fold").apply_startup(0)
    eq(closed_lines(), fast)
    -- opening an entry keeps its drawer folded
    vim.cmd("normal! 2Gzo")
    eq(3, vim.fn.foldclosed(3))
    vim.cmd("bwipe!")
    os.remove(path)
  end)

  it("shows everything like zR", function()
    require("org.config").opts.startup_folded = "showeverything"
    local path = open_file(lines)
    local fast, fdl = closed_lines(), vim.wo.foldlevel
    eq(-1, fast[2])
    eq(-1, fast[3], "drawers too")
    require("org.fold").apply_startup(0)
    eq(closed_lines(), fast)
    eq(vim.wo.foldlevel, fdl)
    vim.cmd("bwipe!")
    os.remove(path)
  end)

  it("applies VISIBILITY properties", function()
    local with_prop = vim.deepcopy(lines)
    table.insert(with_prop, 5, ":VISIBILITY: children")
    local path = open_file(with_prop)
    eq(-1, vim.fn.foldclosed(2), "A shows its children")
    eq(11, vim.fn.foldclosed(11), "B is folded")
    eq(3, vim.fn.foldclosed(3), "the drawer stays folded")
    vim.cmd("bwipe!")
    os.remove(path)
  end)
end)

describe("large files: list items from the section around the cursor", function()
  it("match the items of the parsed section", function()
    local lists = require("org.lists")
    local buf = org_buffer({
      "- preamble item",
      "  more",
      "* H",
      "- a",
      "  - b",
      "    text",
      "",
      "  - c",
      "#+begin_src sh",
      "- not an item",
      "#+end_src",
      "1. one",
      "2. two",
      "",
      "",
      "- after blanks",
      "** Sub",
      "text",
      "- [ ] x",
      "* Last",
      "- z",
    })
    for l = 1, vim.api.nvim_buf_line_count(buf) do
      local line = vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1]
      local want
      if not require("org.parser").headline_level(line) and not lists.in_forbidden_block(buf, l) then
        local _, all = lists.section_lists(buf, l)
        for _, it in ipairs(all) do
          if it.lnum <= l and l <= it.end_lnum then
            want = it
          end
        end
      end
      local got = lists.item_at(buf, l)
      eq(want and { want.lnum, want.end_lnum, want.indent } or nil, got and { got.lnum, got.end_lnum, got.indent } or nil, "line " .. l)
    end
    eq(true, lists.in_forbidden_block(buf, 10))
    eq(false, lists.in_forbidden_block(buf, 12))
  end)
end)

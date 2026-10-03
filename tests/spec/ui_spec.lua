local function syn(l, c)
  return vim.fn.synIDattr(vim.fn.synID(l, c, 1), "name")
end

describe("syntax", function()
  it("highlights core elements", function()
    org_buffer({
      "#+TODO: TODO WAIT | DONE",
      "* WAIT [#A] Hello *bold* :tag:",
      "- [ ] item",
      "** DONE finished",
      "| a | b |",
      "#+begin_src lua",
      "local x = 1",
      "#+end_src",
    })
    eq("OrgTodo", syn(2, 3))
    eq("OrgPriorityA", syn(2, 8))
    eq("OrgTags", syn(2, 27))
    eq("OrgCheckbox", syn(3, 3))
    eq("OrgDone", syn(4, 4))
    eq("OrgTableSeparator", syn(5, 1))
    eq("OrgBlockDelimiter", syn(6, 1))
    ok(syn(7, 1):match("^lua"), "lua embedded: " .. syn(7, 1))
  end)

  it("highlights description list terms after the bullet and checkbox", function()
    org_buffer({
      "- term :: description",
      "- [ ] box term :: desc",
      "   * star bullet :: x",
      "1. numbered :: no term",
      "- no space::here",
      "- tricky :: one :: two",
    })
    eq("OrgListBullet", syn(1, 1))
    eq("OrgListTerm", syn(1, 3))
    eq("OrgListTerm", syn(1, 6))
    eq("", syn(1, 11))
    eq("OrgCheckbox", syn(2, 3))
    eq("OrgListTerm", syn(2, 7))
    eq("OrgListTerm", syn(3, 6))
    ok(syn(4, 4) ~= "OrgListTerm")
    ok(syn(5, 3) ~= "OrgListTerm")
    eq("OrgListTerm", syn(6, 3))
    ok(syn(6, 14) ~= "OrgListTerm")
  end)

  -- #121: with the NFA engine orgListTerm's lazy .\{-} ran out of
  -- 'maxmempattern' on a long paragraph line, and highlighting stopped there
  it("highlights long paragraph lines within the default maxmempattern", function()
    local mmp = vim.o.maxmempattern
    vim.o.maxmempattern = 1000
    local prose = string.rep("I would like the board to be set to a certain color for clients. ", 20)
    org_buffer({
      "* TODO Miro Color Tagging :blender:",
      "",
      prose,
      "",
      "- " .. prose .. ":: term",
      "",
      "** Prompt *bold*",
    })
    for _, l in ipairs({ 3, 5 }) do
      for c = 1, #prose, 50 do
        local ok_syn, err = pcall(vim.fn.synstack, l, c)
        ok(ok_syn, ("line %d col %d: %s"):format(l, c, tostring(err)))
      end
    end
    eq("OrgListTerm", syn(5, 3))
    eq("OrgHeadlineLevel2", syn(7, 1))
    eq("OrgBold", syn(7, 12))
    vim.o.maxmempattern = mmp
  end)
end)

describe("completion", function()
  local c = require("org.completion")
  it("todo keywords after stars", function()
    org_buffer({ "* " })
    local r = c.get("* T", 3, 0)
    eq(2, r.start)
    ok(vim.tbl_contains(
      vim.tbl_map(function(i)
        return i.word
      end, r.items),
      "TODO"
    ))
  end)
  it("src languages", function()
    org_buffer({ "" })
    local r = c.get("#+begin_src py", 14, 0)
    eq(12, r.start)
  end)
  it("tags at end of headline", function()
    org_buffer({ "* A :work:", "* B :w" })
    local r = c.get("* B :w", 6, 0)
    eq(5, r.start)
    ok(vim.tbl_contains(
      vim.tbl_map(function(i)
        return i.word
      end, r.items),
      "work:"
    ))
  end)
  local function words(r)
    return vim.tbl_map(function(i)
      return i.word
    end, r and r.items or {})
  end
  it("omits tags already on the headline (pcomplete/org-mode/tag)", function()
    org_buffer({ "* A :work:home:", "* B :work:h" })
    local w = words(c.get("* B :work:h", 11, 0))
    ok(vim.tbl_contains(w, "home:"), vim.inspect(w))
    ok(not vim.tbl_contains(w, "work:"), vim.inspect(w))
  end)
  it("startup options, header args, clocktable parameters, entities", function()
    org_buffer({ "" })
    ok(vim.tbl_contains(words(c.get("#+STARTUP: fn", 13, 0)), "fnadjust"))
    local r = c.get("#+begin_src python :res", 23, 0)
    eq(19, r.start)
    ok(vim.tbl_contains(words(r), ":results"))
    ok(vim.tbl_contains(words(c.get("#+BEGIN: clocktable :max", 24, 0)), ":maxlevel"))
    r = c.get("an \\alp", 7, 0)
    eq(3, r.start)
    ok(vim.tbl_contains(words(r), "\\alpha"), vim.inspect(words(r)))
  end)
  it("properties not yet set inside a property drawer, drawer names elsewhere", function()
    org_buffer({ "* A", ":PROPERTIES:", ":Effort: 1:00", ":", ":END:", "* B", ":NOTES:", ":END:", ":" }, { 4, 1 })
    local w = words(c.get(":", 1, 0))
    ok(vim.tbl_contains(w, "ID: "), vim.inspect(w))
    ok(not vim.tbl_contains(w, "Effort: "), vim.inspect(w))
    vim.api.nvim_win_set_cursor(0, { 9, 1 })
    w = words(c.get(":", 1, 0))
    ok(vim.tbl_contains(w, "NOTES:"), vim.inspect(w))
  end)
  it("completes incomplete property names without exposing malformed metadata", function()
    local buf = org_buffer({ "* A", ":PROPERTIES:", ":ID: existing", ":Cus", ":END:" }, { 4, 3 })
    local w = words(c.get(":Cus", 4, buf))
    ok(vim.tbl_contains(w, "CUSTOM_ID: "), vim.inspect(w))
    ok(not vim.tbl_contains(w, "ID: "), vim.inspect(w))
    eq(nil, require("org.files").get_buffer(buf):find_by_id("existing"))
  end)
  it("completes an unfinished file-level property drawer", function()
    local buf = org_buffer({ "# comment", ":PROPERTIES:", ":Effort: 1:00", ":" }, { 4, 0 })
    local w = words(c.get(":", 1, buf))
    ok(vim.tbl_contains(w, "ID: "), vim.inspect(w))
    ok(not vim.tbl_contains(w, "Effort: "), vim.inspect(w))
    eq({}, require("org.files").get_buffer(buf).properties)
  end)
  it("links", function()
    org_buffer({ "* Heading one" })
    local r = c.get("see [[*He", 9, 0)
    eq(6, r.start)
    eq("*Heading one", r.items[1].word)
  end)

  describe("omnifunc", function()
    --- Complete the text before the cursor on line `lnum` the way <C-x><C-o>
    --- calls the omnifunc: findstart first, then the base, after Vim has
    --- deleted the base from the line.
    local function omni(lnum, typed)
      -- Insert mode puts the cursor after the last character
      local ve = vim.o.virtualedit
      vim.o.virtualedit = "onemore"
      vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { typed })
      vim.api.nvim_win_set_cursor(0, { lnum, #typed })
      local start = c.omnifunc(1, "")
      ok(type(start) == "number" and start >= 0, vim.inspect(start))
      local base = typed:sub(start + 1)
      vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { typed:sub(1, start) })
      vim.api.nvim_win_set_cursor(0, { lnum, start })
      local out = vim.tbl_map(function(i)
        return i.word
      end, c.omnifunc(0, base))
      vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { typed })
      vim.o.virtualedit = ve
      return out
    end

    it("offers custom IDs after [[#", function()
      org_buffer({
        "* A",
        ":PROPERTIES:",
        ":CUSTOM_ID: foo",
        ":END:",
        "* B",
        ":PROPERTIES:",
        ":CUSTOM_ID: bar",
        ":END:",
        "",
      })
      eq({ "#foo", "#bar" }, omni(9, "[[#"))
      eq({ "#bar" }, omni(9, "see [[#b"))
    end)

    it("keeps every other context, with header args and entities", function()
      org_buffer({ "* A :work:", ":PROPERTIES:", ":Effort: 1:00", ":", ":END:", "" })
      local function has(lnum, typed, word)
        local w = omni(lnum, typed)
        ok(vim.tbl_contains(w, word), typed .. ": " .. vim.inspect(w))
      end
      has(6, "* T", "TODO")
      has(6, "* B :wo", "work:")
      has(6, "#+TI", "TITLE:")
      has(6, "#+STARTUP: ov", "overview")
      has(6, "#+OPTIONS: to", "toc:")
      has(6, "#+begin_src py", "python")
      has(6, "#+begin_src python :res", ":results")
      has(6, "#+BEGIN: clocktable :max", ":maxlevel")
      has(6, "[[*", "*A")
      has(6, "[[fi", "file:")
      has(6, "an \\alp", "\\alpha")
      has(4, ":", "ID: ")
      has(4, ":CU", "CUSTOM_ID: ")
      has(6, ":LOG", "LOGBOOK:")
    end)
  end)
end)

describe("decorations", function()
  local deco = require("org.ui.decorations")
  local cfg = require("org.config").opts
  local function with_ui(ui, fn)
    local saved = vim.deepcopy(cfg.ui)
    for k, v in pairs(ui) do
      cfg.ui[k] = v
    end
    local ok_, err = pcall(fn)
    cfg.ui = saved
    assert(ok_, err)
  end
  local function texts(rows, row)
    return vim.tbl_map(function(m)
      if m[2].virt_text then
        return table.concat(vim.tbl_map(function(chunk)
          return chunk[1]
        end, m[2].virt_text))
      end
      return m[2].conceal
    end, rows[row] or {})
  end

  it("computes bullets and checkboxes per row", function()
    with_ui({ bullets = { "◉", "○" }, checkboxes = { " ", "◐", "✓" } }, function()
      local buf = org_buffer({ "* A", "** B", "- [X] done", "1. [ ] todo" })
      local rows = deco.compute(buf)
      eq({ "◉" }, texts(rows, 0))
      eq({ " ○" }, texts(rows, 1))
      eq({ "[✓]" }, texts(rows, 2))
      eq(2, rows[2][1][1])
      eq({ "[ ]" }, texts(rows, 3))
      eq(3, rows[3][1][1])
    end)
  end)

  it("never leaves stale marks when lines are replaced", function()
    -- Regression: persistent extmarks were dragged to the next line (col 0)
    -- by list edits and showed up there until a debounced re-render.
    with_ui({ bullets = { "◉" }, checkboxes = { " ", "◐", "✓" } }, function()
      local buf = org_buffer({ "* H", "- [X] a", "- [X] b" })
      deco.render(buf)
      vim.api.nvim_buf_set_lines(buf, 1, 3, false, { "1. [X] a", "   1. [X] b", "2. [X] c" })
      local ns = vim.api.nvim_create_namespace("org.decorations")
      eq({}, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}), "no persistent marks to go stale")
      local rows = deco.compute(buf)
      eq({ 3, 6, 3 }, { rows[1][1][1], rows[2][1][1], rows[3][1][1] })
    end)
  end)

  it("indent mode: bullets and hidden stars cover the stars, after the prefix", function()
    -- Regression: the headline overlay was ephemeral while the indent
    -- prefix is a real inline extmark at the same column, so the overlay
    -- was drawn over the prefix and the stars stayed visible ("○*").
    local ns_inline = vim.api.nvim_create_namespace("org.decorations.inline")
    local function prefix_marks(buf, row)
      local out = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns_inline, { row, 0 }, { row, 0 }, { details = true })) do
        out[#out + 1] = m[4].virt_text_pos .. ":" .. m[4].virt_text[#m[4].virt_text][1]
      end
      return out
    end
    with_ui({ indent_mode = true, bullets = { "◉", "○", "✸" } }, function()
      local buf = org_buffer({ "* A", "** B", "body", "*** C" })
      local rows = deco.compute(buf)
      eq({ "◉" }, texts(rows, 0))
      eq({ " ", " ○" }, texts(rows, 1))
      eq({ "  ", "  ✸" }, texts(rows, 3))
      for _, m in ipairs(rows[1]) do
        eq(nil, m[2].conceal, "stars are covered, not concealed: the title stays at column 2n")
      end
      deco.attach(buf)
      vim.cmd("redraw")
      eq({ "inline: ", "overlay:○" }, prefix_marks(buf, 1))
    end)
    with_ui({ indent_mode = true, bullets = false }, function()
      local buf = org_buffer({ "* A", "*** C" })
      deco.attach(buf)
      vim.cmd("redraw")
      eq({ "inline:  ", "overlay:  " }, prefix_marks(buf, 1))
    end)
  end)

  it("keeps indent-mode inline marks as real extmarks", function()
    with_ui({ indent_mode = true }, function()
      local buf = org_buffer({ "* A", "body" })
      local rows = deco.compute(buf)
      eq("inline", rows[1][1][2].virt_text_pos)
    end)
  end)
end)

describe("link conceal", function()
  local function rendered(text)
    org_buffer({ text })
    local s, line, last = "", vim.fn.getline(1), nil
    for c = 1, #line do
      local r = vim.fn.synconcealed(1, c)
      if r[1] == 0 then
        s, last = s .. line:sub(c, c), nil
      elseif r[3] ~= last then
        s, last = s .. r[2], r[3]
      end
    end
    return s
  end
  it("shows only the description", function()
    eq("3. this is something else", rendered("3. this is [[https://www.google.com][something else]]"))
    eq("* TODO see Link :tag:", rendered("* TODO see [[file:a.org::*x][Link]] :tag:"))
    eq("| cell H | b |", rendered("| cell [[*Heading][H]] | b |"))
  end)
  it("shows the target when there is no description", function()
    eq("no desc https://example.com end", rendered("no desc [[https://example.com]] end"))
  end)
end)

describe("ui.menu", function()
  local ui, utils = require("org.ui"), require("org.utils")
  local function pick(keys, ch)
    local items = {}
    for _, k in ipairs(keys) do
      items[#items + 1] = { key = k, label = k, value = k }
    end
    local orig = utils.getchar
    utils.getchar = function()
      return ch
    end
    local r = ui.menu({ title = "t", items = items })
    utils.getchar = orig
    return r
  end
  it("q is an ordinary key, not quit", function()
    eq("q", pick({ "a", "q" }, "q"))
    eq(nil, pick({ "a", "b" }, "q"))
  end)
  it("Esc quits", function()
    eq(nil, pick({ "a", "q" }, nil))
  end)
  it("is wide enough for its longest label", function()
    local label = string.rep("x", 60)
    local width
    local orig = utils.getchar
    utils.getchar = function()
      width = vim.api.nvim_win_get_width(0)
    end
    ui.menu({ title = "t", items = { { key = "a", label = label, value = "a" } } })
    utils.getchar = orig
    eq(true, width >= #(" [a]  " .. label))
  end)
end)

-- The ranges where entities aren't drawn are searched without patterns
-- that go back over a line from each character (seconds for a 40,000-
-- character hash): they are those of the pattern matches they replace.
describe("decorations: protected ranges", function()
  local deco = require("org.ui.decorations")
  local EMPH_PRE = "[%s%(%'\"{%-]"
  local EMPH_POST = "[%s%-%.,:!%?;%'\"%)}%[]"

  --- The ranges as the patterns found them.
  local function reference(line)
    local out = {}
    for s, e in line:gmatch("()%[%[.-%]%]()") do
      out[#out + 1] = { s, e - 1 }
    end
    for i = 1, #line do
      local m = line:sub(i, i)
      if
        m:find("^[*/_+=~]")
        and (i == 1 or line:sub(i - 1, i - 1):find("^" .. EMPH_PRE))
        and line:sub(i + 1, i + 1):find("^%S")
        and not (m == "*" and i == 1 and line:find("^%*+ "))
      then
        local j = i + 1
        while true do
          j = line:find(m, j + 1, true)
          if not j then
            break
          end
          local after = line:sub(j + 1, j + 1)
          if line:sub(j - 1, j - 1):find("^%S") and (after == "" or after:find("^" .. EMPH_POST)) then
            out[#out + 1] = { i, j }
            break
          end
        end
      end
    end
    local schemes = require("org.links").URL_SCHEMES
    for s, scheme, e in line:gmatch("()(%a[%w+%-]*):[^%s%[%]<>()]+()") do
      if schemes[scheme:lower()] and (s == 1 or not line:sub(s - 1, s - 1):find("^%w")) then
        out[#out + 1] = { s, e - 1 }
      end
    end
    for s, e in line:gmatch("()%[fn:[^%]]*%]()") do
      out[#out + 1] = { s, e - 1 }
    end
    if line:byte(1) == 42 then
      local s = line:match("^%*+ .-%s():[^%s]+:%s*$")
      if s then
        out[#out + 1] = { s, #line }
      end
    else
      local e = line:match("^%s*:[^%s]-:()%s") or line:match("^%s*:[^%s]-:()$")
      if e then
        out[#out + 1] = { 1, e - 1 }
      end
    end
    return out
  end

  local function sorted(ranges)
    local out = vim.tbl_map(function(r)
      return r[1] .. "-" .. r[2]
    end, ranges)
    table.sort(out)
    return out
  end

  it("are those of the patterns, on random lines", function()
    local fuzz = require("tests.helpers.fuzz")
    local atoms = {
      "*",
      "/",
      "_",
      "+",
      "=",
      "~",
      " ",
      " ",
      "a",
      "B",
      "1",
      "-",
      "(",
      ")",
      ".",
      ",",
      "[[",
      "]]",
      "[fn:",
      "]",
      "https:",
      "file:",
      ":",
      "x:y",
      "+a-",
      "\\alpha",
      "'",
      '"',
      "\t",
      "* ",
    }
    for seed = 1, 2000 do
      local rng = fuzz.rng(seed)
      local parts = {}
      for _ = 1, rng:int(1, 40) do
        parts[#parts + 1] = rng:pick(atoms)
      end
      local line = table.concat(parts)
      eq(sorted(reference(line)), sorted(deco._protected_ranges(line)), "seed " .. seed .. ": " .. line)
    end
  end)

  it("are found quickly in a long hash, unclosed links and markers", function()
    local gen = require("tests.helpers.gen")
    local line = gen.blob(40000) .. " [[" .. gen.markers(40000) .. " [fn:" .. gen.prose(1000)
    local t = vim.uv.hrtime()
    deco._protected_ranges(line)
    local ms = (vim.uv.hrtime() - t) / 1e6
    -- (8 s before, a few ms after on a laptop)
    ok(ms < 1000 * (tonumber(vim.env.ORG_PERF_SCALE or "") or 1), ms .. " ms")
    eq(sorted(reference(line:sub(1, 3000))), sorted(deco._protected_ranges(line:sub(1, 3000))))
  end)
end)

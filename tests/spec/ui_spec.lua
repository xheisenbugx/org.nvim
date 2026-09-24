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
end)

describe("completion", function()
  local c = require("org.completion")
  it("todo keywords after stars", function()
    org_buffer({ "* " })
    local r = c.get("* T", 3, 0)
    eq(2, r.start)
    ok(vim.tbl_contains(vim.tbl_map(function(i)
      return i.word
    end, r.items), "TODO"))
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
    ok(vim.tbl_contains(vim.tbl_map(function(i)
      return i.word
    end, r.items), "work"))
  end)
  it("links", function()
    org_buffer({ "* Heading one" })
    local r = c.get("see [[*He", 9, 0)
    eq(6, r.start)
    eq("*Heading one", r.items[1].word)
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
      return m[2].virt_text and m[2].virt_text[1][1] or m[2].conceal
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
end)

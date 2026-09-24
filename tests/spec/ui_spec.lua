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
  it("renders bullets without errors", function()
    local cfg = require("org.config").opts
    cfg.ui.bullets = { "◉", "○" }
    cfg.ui.checkboxes = { " ", "◐", "✓" }
    local buf = org_buffer({ "* A", "** B", "- [X] done" })
    require("org.ui.decorations").render(buf)
    local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("org.decorations"), 0, -1, {})
    ok(#marks >= 3)
    cfg.ui.bullets = false
    cfg.ui.checkboxes = false
  end)
end)

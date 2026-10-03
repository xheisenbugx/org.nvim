-- Regex syntax on long lines: the patterns stay within 'maxmempattern'
-- (no E363, which turns highlighting off), don't take time quadratic in
-- the line length, and highlight what they did on short lines. The time
-- budgets are in perf_budgets_spec.lua.
local gen = require("tests.helpers.gen")

--- The syntax group drawn at line l, column c is `group` ("" for none).
local function is(group, l, c)
  eq(group:lower(), vim.fn.synIDattr(vim.fn.synID(l, c, 1), "name"):lower(), ("line %d, col %d"):format(l, c))
end

--- Draw the window; fails on E363 and "'redrawtime' exceeded".
local function draw()
  vim.cmd("messages clear")
  local okr, err = pcall(vim.cmd, "redraw!")
  ok(okr, tostring(err))
  local m = vim.api.nvim_exec2("messages", { output = true }).output
  ok(not m:find("E363") and not m:find("redrawtime"), m)
end

describe("syntax on long lines", function()
  local mmp, rdt
  before_each(function()
    mmp, rdt = vim.o.maxmempattern, vim.o.redrawtime
    -- the default 'maxmempattern'; a short 'redrawtime' catches patterns
    -- that are slow without being out of memory
    vim.o.maxmempattern = 1000
    vim.o.redrawtime = 500
  end)
  after_each(function()
    vim.o.maxmempattern, vim.o.redrawtime = mmp, rdt
  end)

  it("highlights description terms, not the blanks around the bullet", function()
    local prose = gen.prose(5000)
    org_buffer({
      "- term :: desc",
      "  - [X] boxed *bold* term :: d",
      "1. ordered :: not a term",
      "- " .. prose .. " :: long term",
      "#+begin_quote",
      "+ quoted :: x",
      "#+end_quote",
      "- " .. prose,
    })
    draw()
    is("OrgListBullet", 1, 1)
    is("", 1, 2)
    is("OrgListTerm", 1, 3)
    is("", 1, 7)
    is("OrgCheckboxChecked", 2, 5)
    is("", 2, 8)
    is("OrgListTerm", 2, 9)
    is("OrgBold", 2, 16)
    is("", 3, 4)
    is("OrgListTerm", 4, 3)
    is("OrgListTerm", 4, 2990)
    is("OrgQuoteBlock", 6, 2)
    is("OrgListTerm", 6, 3)
    is("", 8, 3)
  end)

  it("highlights the marking column and formulas of a padded table", function()
    local pad = string.rep(" ", 4000)
    org_buffer({
      "| ! | a" .. pad .. " | b |",
      "| # | 1" .. pad .. " | <l5> |",
      "|   | x" .. pad .. " | :=$1 |",
      "| / | y" .. pad .. " | =vsum(@2) |",
    })
    draw()
    is("OrgTableFormula", 1, 2)
    is("OrgTableFormula", 1, 3)
    is("OrgTableSeparator", 1, 5)
    is("OrgTableFormula", 2, 3)
    is("OrgTable", 2, 7)
    is("OrgTableFormula", 4, 3)
    -- past 'synmaxcol' nothing is drawn: the cookie and formulas are
    -- checked on a narrow copy
    org_buffer({ "| # | <l5> |", "| x | :=$1 |", "| y | =vsum(@2) |" })
    draw()
    is("OrgTableFormula", 1, 7)
    is("OrgTableFormula", 2, 7)
    is("OrgTableFormula", 3, 7)
  end)

  it("dims a long headline tagged ARCHIVE", function()
    org_buffer({ "** TODO plain " .. gen.marked(1500) .. " :work:ARCHIVE:", "* Next" })
    draw()
    is("OrgHeadlineArchived", 1, 10)
    is("OrgHeadlineLevel1", 2, 1)
  end)

  it("highlights markup that ends before 'synmaxcol', and only that", function()
    local smc = vim.o.synmaxcol
    org_buffer({
      gen.prose(smc - 20) .. " *bold* " .. gen.prose(3000),
      gen.prose(smc - 4) .. " ~starts before 'synmaxcol'~ and ends after",
      "* Next",
      "text *b*",
    })
    draw()
    is("OrgBold", 1, smc - 16)
    is("", 2, smc - 1)
    -- (the unfinished region went on over the following lines)
    is("OrgHeadlineLevel1", 3, 1)
    is("", 4, 1)
    is("OrgBold", 4, 7)
  end)

  it("still highlights markup over two lines", function()
    org_buffer({ "some *bold", "text* and /it/" })
    draw()
    is("OrgBold", 1, 7)
    is("OrgBold", 2, 2)
    is("OrgItalic", 2, 12)
  end)

  for _, kind in ipairs({ "prose", "marked", "markers", "blob" }) do
    it("draws a 20,000-character line of " .. kind .. " and the lines after it", function()
      org_buffer({ "* H", gen[kind](20000), "* After *bold*", "- term :: x" })
      draw()
      is("OrgHeadlineLevel1", 3, 1)
      is("OrgBold", 3, 11)
      is("OrgListTerm", 4, 3)
    end)
  end
end)

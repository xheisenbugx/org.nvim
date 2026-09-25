local columns = require("org.columns")
local dblock = require("org.dblock")
local utils = require("org.utils")

local function keys(k)
  vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
end

--- Run `fn` with utils functions replaced by `stubs` ({ name = fn }).
local function with_stubs(stubs, fn)
  local orig = {}
  for k, v in pairs(stubs) do
    orig[k] = utils[k]
    utils[k] = v
  end
  local ok_, err = pcall(fn)
  for k, v in pairs(orig) do
    utils[k] = v
  end
  if not ok_ then
    error(err, 0)
  end
end

--- Answer successive prompts with `answers`.
local function answers(list)
  local i = 0
  return function()
    i = i + 1
    return list[i]
  end
end

--- Open column view on `lines` with the cursor on line `lnum`; returns the
--- source buffer (the view window is current).
local function open_view(lines, lnum)
  local src = org_buffer(lines, { lnum or 1, 0 })
  columns.open()
  return src
end

local function close_view()
  if vim.bo.filetype == "orgcolumns" then
    vim.api.nvim_win_close(0, true)
  end
end

describe("columns summaries", function()
  it("supports $, est+, X partial and ages", function()
    eq("3.50", columns.summarize("$", { "1.25", "2.25" }))
    eq("[-]", columns.summarize("X", { "[X]", "[ ]" }))
    eq("[X]", columns.summarize("X", { "[X]", "[X]" }))
    -- 2-4 and 3-5: means 3 + 4, variances 1 + 1
    eq("6-8", columns.summarize("est+", { "2-4", "3-5" }))
    eq("5-5", columns.summarize("est+", { "2", "3" }))
    eq("1d 2h", columns.format_age(26 * 60))
    eq("0min", columns.format_age(0))
    eq("1h 30min", columns.summarize("@max", { "1:30", "0:10" }))
    eq("10min", columns.summarize("@min", { "1:30", "0:10" }))
  end)

  it("does not summarize special properties", function()
    local file = require("org.files").get_buffer(org_buffer({ "* TODO P", "** DONE C" }))
    local rows = columns.compute(file.children, columns.parse_format("%ITEM %TODO{X}"))
    eq("TODO", rows[1].cells[2])
  end)

  it("formats a column spec back to a string", function()
    local fmt = "%25ITEM %TODO %Effort(Est){:} %N{+;%.1f}"
    eq(fmt, columns.format_string(columns.parse_format(fmt)))
  end)
end)

describe("columnview dblock parameters", function()
  local lines = {
    "#+BEGIN: columnview :id global :format \"%ITEM %N{+}\" PARAMS",
    "#+END:",
    "* A :x:",
    ":PROPERTIES:",
    ":N: 1",
    ":END:",
    "** A1",
    ":PROPERTIES:",
    ":N: 2",
    ":END:",
    "* B :skip:",
    ":PROPERTIES:",
    ":N: 4",
    ":END:",
  }
  local function run(params)
    local l = vim.deepcopy(lines)
    l[1] = l[1]:gsub("PARAMS", params)
    local buf = org_buffer(l, { 1, 0 })
    dblock.update_at_cursor()
    return buf_lines(buf)
  end

  it(":hlines puts a separator before each top-level entry", function()
    local l = run(":hlines 1")
    local expected = { "| ITEM | N |", "|------+---|", "| A    | 2 |", "| A1   | 2 |", "|------+---|", "| B    | 4 |" }
    eq(expected, vim.list_slice(l, 2, 7))
  end)

  it(":exclude-tags and :match filter rows", function()
    local l = run(":exclude-tags (skip)")
    eq("#+END:", l[6])
    -- A1 inherits the x tag
    l = run(':match "x"')
    eq("| A1   | 2 |", l[5])
    eq("#+END:", l[6])
  end)

  it(":link links items, :vlines adds column groups", function()
    local l = run(":link t :vlines t :maxlevel 1")
    -- links count as their description when aligning (org-link-descriptive)
    eq("|   | [[*A][A]]    |  2 |", l[4])
    eq("| / | <>   | <> |", l[6])
  end)

  it("keeps keywords and #+TBLFM lines and recalculates", function()
    local buf = org_buffer({
      "#+BEGIN: columnview :id global :format \"%ITEM %N\"",
      "#+NAME: view",
      "| old |",
      "#+TBLFM: @>$2=99",
      "#+END:",
      "* A",
      ":PROPERTIES:",
      ":N: 1",
      ":END:",
    }, { 1, 0 })
    dblock.update_at_cursor()
    local expected = { "#+NAME: view", "| ITEM |  N |", "|------+----|", "| A    | 99 |", "#+TBLFM: @>$2=99", "#+END:" }
    eq(expected, vim.list_slice(buf_lines(buf), 2, 7))
  end)
end)

describe("column view", function()
  -- written for this setup rather than the Emacs defaults
  with_config({ todo_keywords = { "TODO(t) NEXT(n) | DONE(d)" }, log_done = "time", log_into_drawer = "LOGBOOK" })
  it("n / p cycle allowed values and C-c C-t changes the TODO state", function()
    local src = open_view({
      "#+COLUMNS: %ITEM %Status",
      "* Task",
      ":PROPERTIES:",
      ":Status_ALL: new open done",
      ":END:",
    }, 2)
    keys("3G$")
    keys("n")
    ok(vim.tbl_contains(buf_lines(src), ":Status: new"))
    keys("n")
    ok(vim.tbl_contains(buf_lines(src), ":Status: open"))
    keys("p")
    ok(vim.tbl_contains(buf_lines(src), ":Status: new"))
    keys("p")
    ok(vim.tbl_contains(buf_lines(src), ":Status: done"))
    keys("0<C-c><C-t>t")
    eq("* TODO Task", buf_lines(src)[2])
    close_view()
  end)

  it("S-Right cycles TODO keywords and the priority", function()
    local src = open_view({ "#+COLUMNS: %ITEM %TODO %PRIORITY", "* Task" }, 2)
    keys("3G0")
    local line = vim.api.nvim_get_current_line()
    vim.api.nvim_win_set_cursor(0, { 3, line:find("│", 1, true) + 3 })
    keys("<S-Right>")
    eq("* TODO Task", buf_lines(src)[2])
    keys("<S-Right>")
    eq("* NEXT Task", buf_lines(src)[2])
    local l3 = vim.api.nvim_get_current_line()
    local _, e = l3:find("│.-│")
    vim.api.nvim_win_set_cursor(0, { 3, e + 1 })
    keys("n")
    eq("* NEXT [#C] Task", buf_lines(src)[2])
    close_view()
  end)

  it("< > widen / narrow and store the format in #+COLUMNS", function()
    local src = open_view({ "#+COLUMNS: %ITEM %N", "* Task" }, 2)
    keys("3G0")
    keys("3>")
    eq("#+COLUMNS: %9ITEM %N", buf_lines(src)[1])
    keys("<")
    eq("#+COLUMNS: %8ITEM %N", buf_lines(src)[1])
    close_view()
  end)

  it("M-Right moves a column, M-S-Left deletes one, s edits one", function()
    local src = open_view({
      "* Top",
      ":PROPERTIES:",
      ":COLUMNS: %ITEM %A %B",
      ":END:",
      "** Child",
    }, 5)
    keys("3G0<M-Right>")
    eq(":COLUMNS: %A %ITEM %B", buf_lines(src)[3])
    with_stubs({
      confirm = function()
        return true
      end,
    }, function()
      keys("<M-S-Left>")
    end)
    eq(":COLUMNS: %A %B", buf_lines(src)[3])
    with_stubs({
      input_complete = answers({ "B", "+" }),
      input = answers({ "Bee", "5", "" }),
    }, function()
      keys("s")
    end)
    eq(":COLUMNS: %A %5B(Bee){+}", buf_lines(src)[3])
    close_view()
  end)

  it("M-S-Right adds a column and inserts #+COLUMNS when missing", function()
    local src = open_view({ "Intro", "* Task" }, 2)
    with_stubs({
      input_complete = answers({ "Effort", ":" }),
      input = answers({ "", "", "" }),
    }, function()
      keys("3G0<M-S-Right>")
    end)
    eq("#+COLUMNS: %Effort{:} %25ITEM %TODO %3PRIORITY %TAGS", buf_lines(src)[2])
    close_view()
  end)

  it("a edits the allowed values", function()
    local src = open_view({ "#+COLUMNS: %ITEM %Size", "* Task" }, 2)
    with_stubs({ input = answers({ "S M L" }) }, function()
      keys("3G$a")
    end)
    ok(vim.tbl_contains(buf_lines(src), ":Size_ALL: S M L"))
    keys("n")
    ok(vim.tbl_contains(buf_lines(src), ":Size: S"))
    close_view()
  end)
end)

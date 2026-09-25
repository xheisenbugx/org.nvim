-- Column view summaries and columnview options compared with Emacs Org
-- 9.8.10 (org-colview.el).
local columns = require("org.columns")
local dblock = require("org.dblock")
local utils = require("org.utils")

local function view_lines(buf)
  return buf_lines(buf)
end

describe("column summaries (org-columns-summary-types-default)", function()
  it("formats numbers like (format \"%s\" n)", function()
    eq("4.1", columns.summarize("+", { "1.1", "3" }))
    eq("6", columns.summarize("+", { "1", "5" }))
    eq("3.5", columns.summarize("mean", { "3", "4" }))
    eq("2.5", columns.summarize("max", { "1", "2.5" }))
    eq("1", columns.summarize("min", { "1", "2.5" }))
    eq("3.75", columns.summarize("+", { "1.25", "2.5", "abc" }))
    eq("3.0", columns.summarize("+", { "1", "2" }, "%.1f"))
  end)

  it("sums durations with duration_format unless all values are H:MM", function()
    eq("1d 2:00", columns.summarize(":", { "1d", "2h" }))
    eq("26:00", columns.summarize(":", { "20:00", "6:00" }))
    eq("2:15", columns.summarize(":", { "1:30", "0:45" }))
  end)

  it("counts checkboxes and rounds percentages like Emacs", function()
    eq("[2/3]", columns.summarize("X/", { "[X]", "[2/2]", "[ ]" }))
    eq("[33%]", columns.summarize("X%", { "[X]", "[ ]", "[ ]" }))
    eq("[100%]", columns.summarize("X%", { "[X]", "[100%]" }))
  end)
end)

describe("columnview blocks", function()
  local lines = {
    "#+COLUMNS: %40ITEM %TODO %Effort{:} %Cost{+} %Done{X/}",
    "* TODO Project [1/2] <<target>> [fn:1]",
    "** DONE Task A",
    ":PROPERTIES:",
    ":Effort: 1:30",
    ":Cost: 1.1",
    ":Done: [X]",
    ":END:",
    "** TODO Task B :work:",
    ":PROPERTIES:",
    ":Effort: 0:45",
    ":Cost: 2.222",
    ":Done: [ ]",
    ":END:",
    "*** Sub B1",
    ":PROPERTIES:",
    ":Cost: 3",
    ":END:",
    "",
    "#+BEGIN: columnview :id global PARAMS",
    "#+END:",
  }
  local function run(params)
    local l = vim.deepcopy(lines)
    l[20] = l[20]:gsub("PARAMS", function()
      return params
    end)
    local buf = org_buffer(l, { 20, 0 })
    dblock.update_all(buf)
    return buf_lines(buf), buf
  end

  it("writes the width cookie row and cleans ITEM", function()
    local out = run("")
    eq("| <40>    |      |        |      |       |", out[21])
    eq("| Project | TODO |   2:15 |  4.1 | [1/2] |", out[24])
  end)

  it("writes summaries back into existing properties (org-columns-compute-all)", function()
    local _, buf = run("")
    -- Task B has a Cost property: its summary (3) replaces it
    eq(":COST:     3", buf_lines(buf)[12])
  end)

  it(":link searches the heading without cookies", function()
    local out = run(':link t :format "%ITEM"')
    eq("| [[*Project <<target>> \\[fn:1\\]][Project]] |", out[23])
  end)

  it(":exclude-tags also drops entries inheriting the tag", function()
    local out = run(':exclude-tags ("work") :format "%ITEM"')
    eq({ "| ITEM    |", "|---------|", "| Project |", "| Task A  |", "#+END:" }, vim.list_slice(out, 21, 25))
  end)

  it("SCHEDULED is shown as an inactive timestamp and LEVEL as a property", function()
    local buf = org_buffer({
      "#+COLUMNS: %ITEM %SCHEDULED %LEVEL",
      "* A",
      "SCHEDULED: <2024-01-01 Mon>",
      "#+BEGIN: columnview :id global",
      "#+END:",
    })
    dblock.update_all(buf)
    eq("| A    | [2024-01-01 Mon] |       |", buf_lines(buf)[7])
  end)

  describe("user summary types, formatter and display function", function()
    with_config({
      columns_summary_types = {
        ["+|"] = function(values)
          return table.concat(values, "|"):gsub("|", "/")
        end,
      },
      columns_modify_value_for_display_function = function(title, value)
        if title == "Up" then
          return value:upper()
        end
      end,
    })
    it("uses them", function()
      local buf = org_buffer({
        "#+COLUMNS: %ITEM %N{+|} %Name(Up)",
        "* P",
        "** a",
        ":PROPERTIES:",
        ":N: 1",
        ":Name: x",
        ":END:",
        "** b",
        ":PROPERTIES:",
        ":N: 2",
        ":END:",
        "#+BEGIN: columnview :id global",
        "#+END:",
      })
      dblock.update_all(buf)
      local out = buf_lines(buf)
      eq("| P    | 1/2 |    |", out[15])
      eq("| a    |   1 | X  |", out[16])
    end)

    it(":formatter names a global Lua function", function()
      _G.org_test_formatter = function(rows, params)
        local out = { "rows: " .. (#rows - 2) .. " " .. tostring(params.formatter) }
        for i = 3, #rows do
          out[#out + 1] = rows[i].level .. " " .. rows[i][1]
        end
        return out
      end
      local buf = org_buffer({ "* A", "** B", "#+BEGIN: columnview :id global :formatter org_test_formatter", "#+END:" })
      dblock.update_all(buf)
      eq({ "rows: 2 org_test_formatter", "1 A", "2 B" }, vim.list_slice(buf_lines(buf), 4, 6))
      _G.org_test_formatter = nil
    end)
  end)
end)

describe("column view keys", function()
  it("1-9 select the Nth allowed value, 0 the last", function()
    local src = org_buffer({
      "* A",
      ":PROPERTIES:",
      ":COLUMNS: %ITEM %Status",
      ":Status_ALL: new open done",
      ":Status: new",
      ":END:",
    }, { 1, 0 })
    columns.open()
    local view = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { 3, #vim.api.nvim_get_current_line() - 1 })
    vim.api.nvim_feedkeys("3", "xt", false)
    eq(":Status: done", buf_lines(src)[5])
    vim.api.nvim_feedkeys("0", "xt", false)
    eq(":Status: done", buf_lines(src)[5])
    vim.api.nvim_feedkeys("2", "xt", false)
    eq(":Status: open", buf_lines(src)[5])
    ok(#view_lines(view) >= 3)
    vim.api.nvim_win_close(0, true)
  end)

  it("<C-c><C-o> opens the link in the field", function()
    org_buffer({ "* A", ":PROPERTIES:", ":COLUMNS: %ITEM %Url", ":Url: [[https://example.org][site]]", ":END:" }, { 1, 0 })
    columns.open()
    vim.api.nvim_win_set_cursor(0, { 3, #vim.api.nvim_get_current_line() - 1 })
    local links = require("org.links")
    local open, seen = links.open, nil
    links.open = function(target)
      seen = target
    end
    local warn = utils.warn
    utils.warn = function() end
    vim.api.nvim_feedkeys(vim.keycode("<C-c><C-o>"), "xt", false)
    links.open, utils.warn = open, warn
    eq("https://example.org", seen)
    pcall(vim.cmd, "only")
  end)
end)

local calendar = require("org.calendar")
local date = require("org.date")

describe("calendar", function()
  local function render(sel, today, opts)
    return calendar.render(date.parse(sel), vim.tbl_extend("force", { today = date.parse(today) }, opts or {}))
  end

  --- The text each mark of group `group` covers, in order.
  local function marked(lines, marks, group)
    local out = {}
    for _, m in ipairs(marks) do
      if m[4] == group then
        out[#out + 1] = lines[m[1] + 1]:sub(m[2] + 1, m[3])
      end
    end
    return out
  end

  it("draws six weeks with ISO week numbers and the neighbouring months", function()
    local lines = render("<2026-09-26 Sat>", "<2026-09-27 Sun>")
    eq(" ‹        September 2026        ›", lines[2])
    eq("  Wk  Mo  Tu  We  Th  Fr  Sa  Su ", lines[4])
    eq("  36  31   1   2   3   4   5   6 ", lines[5])
    eq("  39  21  22  23  24  25  26  27 ", lines[8])
    eq("  41   5   6   7   8   9  10  11 ", lines[10])
    for _, l in ipairs(lines) do
      ok(vim.fn.strdisplaywidth(l) < calendar.WIDTH, l)
    end
  end)

  it("marks the selected day, today, weekends and other months", function()
    local lines, marks = render("<2026-09-26 Sat>", "<2026-09-27 Sun>")
    eq({ " 26 " }, marked(lines, marks, "OrgCalendarSelected"))
    eq({ "27" }, marked(lines, marks, "OrgCalendarToday"))
    eq(
      { "31", " 1", " 2", " 3", " 4", " 5", " 6", " 7", " 8", " 9", "10", "11" },
      marked(lines, marks, "OrgCalendarOutside")
    )
    local weekend = marked(lines, marks, "OrgCalendarWeekend")
    eq({ " 5", " 6", "12", "13", "19", "20", "26", "27" }, weekend)
    eq({ "‹", "›" }, marked(lines, marks, "OrgCalendarArrow"))
    eq({ "September 2026" }, marked(lines, marks, "OrgCalendarTitle"))
  end)

  it("previews the date in full, its timestamp and its distance from today", function()
    local lines, marks = render("<2026-10-01 Thu 14:00>", "<2026-09-27 Sun>")
    eq({ "Thursday, 1 October 2026" }, marked(lines, marks, "OrgCalendarDate"))
    eq({ "<2026-10-01 Thu 14:00>" }, marked(lines, marks, "OrgCalendarTimestamp"))
    eq({ "in 4 days" }, marked(lines, marks, "OrgCalendarRelative"))
    eq(
      { "today", "tomorrow", "yesterday", "in 3 days", "5 days ago", "in 2 weeks", "in 15 days" },
      vim.tbl_map(calendar.relative, { 0, 1, -1, 3, -5, 14, 15 })
    )
  end)

  it("lists the remove key only when the date can be removed", function()
    local lines = render("<2026-09-26 Sat>", "<2026-09-26 Sat>")
    ok(not table.concat(lines, "\n"):find("remove", 1, true))
    lines = render("<2026-09-26 Sat>", "<2026-09-26 Sat>", { allow_remove = true })
    ok(table.concat(lines, "\n"):find("x remove", 1, true))
  end)

  it("keeps one window while moving and closes it when done", function()
    local keys = { "l", "L", "\r" }
    local getcharstr = vim.fn.getcharstr
    local wins = {}
    vim.fn.getcharstr = function()
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then
          wins[w] = true
        end
      end
      return table.remove(keys, 1)
    end
    local picked = calendar.pick({ default = date.parse("<2026-09-26 Sat>") })
    vim.fn.getcharstr = getcharstr
    eq("<2026-10-27 Tue>", picked:to_string())
    eq(1, vim.tbl_count(wins))
    for w in pairs(wins) do
      ok(not vim.api.nvim_win_is_valid(w))
    end
  end)
end)

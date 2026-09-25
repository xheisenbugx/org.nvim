local dblock = require("org.dblock")
local columns = require("org.columns")

describe("dblock", function()
  it("parses params", function()
    local p = dblock.parse_params(':scope agenda :maxlevel 2 :block thisweek :link t :fileskip0 nil :match "+work" :tstart <2026-01-01 Thu>')
    eq("agenda", p.scope)
    eq(2, p.maxlevel)
    eq("thisweek", p.block)
    eq(true, p.link)
    eq(false, p.fileskip0)
    eq("+work", p.match)
    eq("<2026-01-01 Thu>", p.tstart)
  end)

  it("updates clocktable blocks", function()
    local buf = org_buffer({
      "#+BEGIN: clocktable :maxlevel 1",
      "old",
      "#+END:",
      "* A",
      "CLOCK: [2026-09-23 Wed 10:00]--[2026-09-23 Wed 11:00] =>  1:00",
    }, { 2, 0 })
    ok(dblock.at_cursor())
    dblock.update_at_cursor()
    local l = buf_lines(buf)
    ok(l[2]:match("^#%+CAPTION"))
    eq("| *Total time* | *1:00* |", l[5])
    eq("#+END:", l[8])
  end)

  it("inserts a clock report", function()
    local buf = org_buffer({ "* A", "CLOCK: [2026-09-23 Wed 10:00]--[2026-09-23 Wed 10:30] =>  0:30" }, { 2, 0 })
    dblock.insert_clocktable()
    local l = buf_lines(buf)
    ok(l[3]:match("^#%+BEGIN: clocktable"))
    eq("#+END:", l[#l])
  end)

  it("custom writers and update_all", function()
    dblock.register("hello", function(params)
      return { "hello " .. tostring(params.name) }
    end)
    local buf = org_buffer({ "#+BEGIN: hello :name a", "#+END:", "#+BEGIN: hello :name b", "x", "#+END:" })
    eq(2, dblock.update_all(buf))
    eq({ "#+BEGIN: hello :name a", "hello a", "#+END:", "#+BEGIN: hello :name b", "hello b", "#+END:" }, buf_lines(buf))
  end)
end)

describe("columns", function()
  it("parses formats", function()
    local cols = columns.parse_format("%25ITEM %TODO %3PRIORITY %Effort(Est){:} %N{+;%.1f}")
    eq(25, cols[1].width)
    eq("Est", cols[4].title)
    eq(":", cols[4].summary)
    eq("+", cols[5].summary)
    eq("%.1f", cols[5].summary_fmt)
  end)

  it("summarizes", function()
    eq("1:30", columns.summarize(":", { "1:00", "0:30", "" }))
    eq("6", columns.summarize("+", { "1", "5" }))
    eq("[1/2]", columns.summarize("X/", { "[X]", "[ ]" }))
    eq("[-]", columns.summarize("X", { "[X]", "[ ]" }))
    eq("[ ]", columns.summarize("X", { "[ ]", "[ ]" }))
    eq("[50%]", columns.summarize("X%", { "[X]", "[ ]" }))
    -- Emacs divides by a float: (format "%s" 2.0)
    eq("2.0", columns.summarize("mean", { "1", "3" }))
  end)

  it("columnview dblock", function()
    local buf = org_buffer({
      "#+COLUMNS: %ITEM %Effort{:}",
      "#+BEGIN: columnview :id global",
      "#+END:",
      "* Parent",
      "** A",
      ":PROPERTIES:",
      ":Effort: 1:00",
      ":END:",
      "** B",
      ":PROPERTIES:",
      ":Effort: 0:45",
      ":END:",
    }, { 2, 0 })
    dblock.update_at_cursor()
    local l = buf_lines(buf)
    eq("| ITEM   | Effort |", l[3])
    eq("| Parent |   1:45 |", l[5])
    eq("| A      |   1:00 |", l[6])
  end)
end)

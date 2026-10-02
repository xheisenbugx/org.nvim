local parser = require("org.parser")

describe("parser edge cases", function()
  it("treats a drawer without :END: as text, keeping its timestamps", function()
    local f = parser.parse({ "* Task", ":note:", "some text", "<2024-01-02 Tue>", "* Next" }, "/x.org")
    local hl = f.headlines[1]
    eq(0, #hl.drawers)
    eq(1, #hl.timestamps)
    eq(4, hl.timestamps[1].line)
  end)

  it("does not close a drawer with an :END: from a later section", function()
    local f = parser.parse({ "* A", ":note:", "<2024-01-02 Tue>", "* B", ":END:" }, "/x.org")
    eq(1, #f.headlines[1].timestamps)
    eq(0, #f.headlines[1].drawers)
  end)

  it("closes a drawer with a lower-case :end: line", function()
    local f = parser.parse({ "* Task", ":LOGBOOK:", "- note", ":end:", "<2024-01-02 Tue>" }, "/x.org")
    local hl = f.headlines[1]
    eq(1, #hl.drawers)
    eq(4, hl.drawers[1]["end"])
    eq({ start = 2, ["end"] = 4 }, hl.logbook)
    eq(1, #hl.timestamps)
  end)

  it("still hides timestamps inside closed drawers", function()
    local f = parser.parse({ "* Task", ":note:", "<2024-01-02 Tue>", ":END:", ":x:", "<2024-01-03 Wed>" }, "/x.org")
    local hl = f.headlines[1]
    eq(1, #hl.drawers)
    eq(1, #hl.timestamps)
    eq(6, hl.timestamps[1].line)
  end)
end)

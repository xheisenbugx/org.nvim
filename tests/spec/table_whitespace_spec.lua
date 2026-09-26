local tbl = require("org.table")

-- Emacs Org 9.8.7: org-table-align ignores horizontal whitespace after
-- the closing delimiter, but keeps explicitly delimited empty fields.
describe("table trailing whitespace", function()
  it("does not parse padding after the closing pipe as another column", function()
    for _, suffix in ipairs({ " ", "   ", "\t", " \t " }) do
      eq({ "a", "b" }, tbl.split_cells("  | a | b |" .. suffix))
    end
    eq({ "a", "b", "" }, tbl.split_cells("| a | b | |  "))
    eq({ "a", "b" }, tbl.split_cells("| a | b  "))
  end)

  it("aligns pasted rows without growing every row by one field", function()
    local buf = org_buffer({ "| name | qty |  ", "|---+---|", "| apple | 3 |\t" }, { 1, 2 })
    tbl.align()
    eq({ "| name  | qty |", "|-------+-----|", "| apple |   3 |" }, buf_lines(buf))
  end)

  it("keeps the last-column formula target on the real last field", function()
    local buf = org_buffer({ "| 2 | 0 |  ", "#+TBLFM: $>=$1*3" }, { 1, 2 })
    tbl.recalc(buf, 1)
    eq({ "| 2 | 6 |", "#+TBLFM: $>=$1*3" }, buf_lines(buf))
  end)
end)

-- Minimized inputs found by the fuzz specs (fuzz_*_spec.lua).
describe("fuzz regressions", function()
  it("M-down from the blank lines after the last-but-one element keeps the cursor in the buffer", function()
    local buf = org_buffer({ "a", "", "", "#+title: x" }, { 2, 0 })
    require("org.element").drag_forward()
    eq({ "#+title: x", "", "", "a" }, buf_lines(buf))
    eq(4, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("S-M-up on the bracket of a CLOCK timestamp toggles it without an error", function()
    local line = "CLOCK: [2003-10-04 Fri 05:00]--[2003-10-04 Fri 23:30] => 18:30"
    local buf = org_buffer({ "* T", line }, { 2, 52 })
    eq(true, require("org.clock").timestamps_adjust_closest(-1))
    eq("CLOCK: [2003-10-04 Fri 05:00]--<2003-10-04 Fri 23:30> => 18:30", buf_lines(buf)[2])
  end)
end)

-- The formula editor (Emacs org-table-edit-formulas, C-c ').
local tbl = require("org.table")
local fedit = require("org.table.fedit")
local utils = require("org.utils")

local function quiet(fn)
  local notify, warn = utils.notify, utils.warn
  utils.notify, utils.warn = function() end, function() end
  local ok_, err = pcall(fn)
  utils.notify, utils.warn = notify, warn
  if not ok_ then
    error(err, 0)
  end
end

local function keys(k)
  vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
end

describe("formula editor", function()
  local lines = {
    "| a | b | c |",
    "|---+---+---|",
    "| 1 | 2 |   |",
    "| 3 | 4 |   |",
    "#+TBLFM: @3$1=7::$3=$1+$2::$x=1",
    "#+TBLFM: $3=$1*$2",
  }

  it("lists sorted formulas under section titles", function()
    eq({
      "# Column Formulas",
      "$3 = $1+$2",
      "",
      "# Field and Range Formulas",
      "@3$1 = 7",
      "",
      "# Named Field Formulas",
      "$x = 1",
    }, fedit.editor_lines({ "@3$1=7", "$3=$1+$2", "$x=1" }))
  end)

  it("parses edited lines back, joining continuation lines", function()
    eq(
      { "$3=$1+$2", "@3$1='(+ 1 2)" },
      fedit.parse_lines({ "# Column Formulas", "$3 = $1+$2", "", "@3$1 = '(+ 1", "         2)" })
    )
  end)

  it("stores into the edited #+TBLFM line only, and applies with a count", function()
    local buf = org_buffer(lines, { 3, 10 })
    local ebuf
    quiet(function()
      ebuf = fedit.open()
    end)
    eq(ebuf, vim.api.nvim_get_current_buf())
    -- the cursor starts on the formula of the current field
    eq("$3 = $1+$2", vim.api.nvim_get_current_line())
    vim.api.nvim_set_current_line("$3 = $1-$2")
    keys("4<C-c><C-c>")
    eq(buf, vim.api.nvim_get_current_buf())
    eq({
      "| a | b |  c |",
      "|---+---+----|",
      "| 1 | 2 | -1 |",
      "| 7 | 4 | -1 |",
      "#+TBLFM: $3=$1-$2::@3$1=7::$x=1",
      "#+TBLFM: $3=$1*$2",
    }, buf_lines(buf))
  end)

  it("edits the #+TBLFM line at the cursor", function()
    local buf = org_buffer(lines, { 6, 0 })
    quiet(function()
      fedit.open()
    end)
    eq({ "# Column Formulas", "$3 = $1*$2" }, buf_lines(0))
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "$3 = $1*$2*2" })
    keys("<C-c>'")
    eq("#+TBLFM: $3=$1*$2*2", buf_lines(buf)[6])
    eq(lines[5], buf_lines(buf)[5])
  end)

  it("aborts with <C-c><C-q>", function()
    local buf = org_buffer(lines, { 3, 2 })
    quiet(function()
      fedit.open()
    end)
    vim.api.nvim_set_current_line("$3 = 0")
    keys("<C-c><C-q>")
    eq(lines, buf_lines(buf))
  end)

  it("highlights the referenced fields", function()
    local buf = org_buffer(lines, { 3, 10 })
    quiet(function()
      fedit.open()
    end)
    local marks = vim.api.nvim_buf_get_extmarks(buf, fedit.src_ns, 0, -1, { details = true })
    local groups = {}
    for _, m in ipairs(marks) do
      if m[4].hl_group then
        groups[#groups + 1] = (m[2] + 1) .. ":" .. m[4].hl_group
      end
    end
    table.sort(groups)
    -- target @2$3 and the references $1, $2 of the test row (line 3)
    eq({ "3:OrgTableFormulaRef", "3:OrgTableFormulaRef", "3:OrgTableFormulaTarget" }, groups)
    keys("<C-c><C-q>")
  end)

  it("shifts references with S-arrows and pretty-prints Lisp", function()
    org_buffer({ "| 1 |" })
    vim.api.nvim_set_current_line("@2$3 = @2$1+$4")
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    fedit.shift_reference("down")
    eq("@2$3 = @3$1+$4", vim.api.nvim_get_current_line())
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    fedit.shift_reference("right")
    eq("@2$3 = @3$2+$4", vim.api.nvim_get_current_line())
    vim.api.nvim_set_current_line("$3 = '(concat (substring $1 0 3) \"-\" (upcase $2) \"-\" (number-to-string (+ 1 2 3 4 5 6)))")
    fedit.lisp_indent(0)
    eq({
      "$3 = '(concat (substring $1 0 3)",
      '              "-"',
      "              (upcase $2)",
      '              "-"',
      "              (number-to-string (+ 1 2 3 4 5 6)))",
    }, buf_lines(0))
    eq({ "$3='(concat (substring $1 0 3) \"-\" (upcase $2) \"-\" (number-to-string (+ 1 2 3 4 5 6)))" }, fedit.parse_lines(buf_lines(0)))
  end)

  it("converts A1 references", function()
    eq("@3$2+$3", tbl.refs_to_rc("B3+C&"))
    eq("B3+C&", tbl.refs_to_an("@3$2+$3"))
    eq("vsum(@2$1..@3$1)", tbl.refs_to_rc("vsum(A2..A3)"))
  end)
end)

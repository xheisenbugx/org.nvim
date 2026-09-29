-- Table options and commands. Every expected buffer and cursor position
-- came from Emacs Org 9.8.10 (emacs -Q --batch, same text and command).

local tbl = require("org.table")

--- Run `fn` from a visual-mode mapping after typing `keys` in normal mode.
local function in_visual(keys, fn)
  vim.keymap.set("x", "<F12>", fn, { buffer = 0 })
  vim.api.nvim_feedkeys(vim.keycode(keys .. "<F12>"), "x", false)
  vim.keymap.del("x", "<F12>", { buffer = 0 })
end

local function cursor()
  return vim.api.nvim_win_get_cursor(0)
end

describe("table: tab_jumps_over_hlines", function()
  it("jumps over an hline by default", function()
    local buf = org_buffer({ "| a | b |", "|---+---|", "| c | d |" }, { 1, 6 })
    tbl.next_field()
    eq({ "| a | b |", "|---+---|", "| c | d |" }, buf_lines(buf))
    eq({ 3, 2 }, cursor())
  end)

  it("adds a row before a final hline", function()
    local buf = org_buffer({ "| a | b |", "|---+---|" }, { 1, 2 })
    tbl.next_field()
    tbl.next_field()
    eq({ "| a | b |", "|   |   |", "|---+---|" }, buf_lines(buf))
    eq({ 2, 2 }, cursor())
  end)
end)

describe("table: tab_jumps_over_hlines = false", function()
  with_config({ table_tab_jumps_over_hlines = false })
  it("adds a row before the hline", function()
    local buf = org_buffer({ "| a | b |", "|---+---|", "| c | d |" }, { 1, 6 })
    tbl.next_field()
    eq({ "| a | b |", "|   |   |", "|---+---|", "| c | d |" }, buf_lines(buf))
    eq({ 2, 2 }, cursor())
  end)
end)

describe("table: automatic_realign = false", function()
  with_config({ table_automatic_realign = false })
  it("moves without realigning", function()
    local buf = org_buffer({ "| axxxx | b |", "| c | d |" }, { 1, 2 })
    tbl.next_field()
    eq({ "| axxxx | b |", "| c | d |" }, buf_lines(buf))
    eq({ 1, 10 }, cursor())
    buf = org_buffer({ "| axxxx | b |", "| c | d |" }, { 1, 2 })
    tbl.next_row()
    eq({ "| axxxx | b |", "| c | d |" }, buf_lines(buf))
    eq({ 2, 2 }, cursor())
  end)

  it("still aligns when a row is added", function()
    local buf = org_buffer({ "| a | bxxxx |" }, { 1, 6 })
    tbl.next_field()
    eq({ "| a | bxxxx |", "|   |       |" }, buf_lines(buf))
    eq({ 2, 2 }, cursor())
  end)
end)

describe("table: allow_automatic_line_recalculation", function()
  it("recalculates a # row on Tab", function()
    local buf = org_buffer({ "| # | 1 | 2 |   |", "#+TBLFM: $4=$2+$3" }, { 1, 10 })
    tbl.next_field()
    eq("| # | 1 | 2 | 3 |", buf_lines(buf)[1])
  end)
end)

describe("table: allow_automatic_line_recalculation = false", function()
  with_config({ table_allow_automatic_line_recalculation = false })
  it("leaves the row alone", function()
    local buf = org_buffer({ "| # | 1 | 2 |   |", "#+TBLFM: $4=$2+$3" }, { 1, 10 })
    tbl.next_field()
    eq("| # | 1 | 2 |   |", buf_lines(buf)[1])
  end)
end)

describe("table: formula_field_format", function()
  with_config({ table_formula_field_format = "~%s~" })
  it("formats formula results", function()
    local buf = org_buffer({ "| 1 | 2 |   |", "#+TBLFM: $3=$1+$2" }, { 1, 2 })
    tbl.recalc(0, 1)
    eq("| 1 | 2 | ~3~ |", buf_lines(buf)[1])
  end)
end)

describe("table: formula_use_constants = false", function()
  with_config({ table_formula_use_constants = false, table_formula_constants = { c = "10" } })
  it("does not substitute names in a single evaluation", function()
    local buf = org_buffer({ "| 1 | =$1+$c |" }, { 1, 8 })
    tbl.next_field()
    eq("| 1 | #ERROR |", buf_lines(buf)[1])
  end)

  it("still substitutes them when recalculating", function()
    local buf = org_buffer({ "| 1 |   |", "#+TBLFM: $2=$1+$c" }, { 1, 2 })
    tbl.recalc(0, 1)
    eq("| 1 | 11 |", buf_lines(buf)[1])
  end)
end)

describe("table: relative_ref_may_cross_hline", function()
  local rel = { "| 1 |   |", "| 2 |   |", "|---+---|", "| 3 |   |", "| 4 |   |", "#+TBLFM: $2=@-1$1" }
  it("crosses by default", function()
    local buf = org_buffer(rel, { 1, 2 })
    tbl.recalc(0, 1)
    eq({ "| 3 | 2 |", "| 4 | 3 |" }, { buf_lines(buf)[4], buf_lines(buf)[5] })
  end)
end)

describe("table: relative_ref_may_cross_hline = false", function()
  with_config({ table_relative_ref_may_cross_hline = false })
  it("stops at the hline", function()
    local buf = org_buffer(
      { "| 1 |   |", "| 2 |   |", "|---+---|", "| 3 |   |", "| 4 |   |", "#+TBLFM: $2=@-1$1" },
      { 1, 2 }
    )
    tbl.recalc(0, 1)
    eq({ "| 3 | 3 |", "| 4 | 3 |" }, { buf_lines(buf)[4], buf_lines(buf)[5] })
    buf = org_buffer({
      "| 1 |   |",
      "| 2 |   |",
      "|---+---|",
      "| 3 |   |",
      "| 4 |   |",
      "#+TBLFM: @1$2=@+2$1::@2$2=@+1$1",
    }, { 1, 2 })
    tbl.recalc(0, 1)
    eq({ "| 1 | 2 |", "| 2 | 2 |" }, { buf_lines(buf)[1], buf_lines(buf)[2] })
  end)
end)

describe("table: relative_ref_may_cross_hline = error", function()
  with_config({ table_relative_ref_may_cross_hline = "error" })
  it("stops the recalculation", function()
    local rel = { "| 1 |   |", "| 2 |   |", "|---+---|", "| 3 |   |", "| 4 |   |", "#+TBLFM: $2=@-1$1" }
    local buf = org_buffer(rel, { 1, 2 })
    tbl.recalc(0, 1)
    eq(rel, buf_lines(buf))
  end)
end)

describe("table: calc_default_modes", function()
  with_config({ calc_default_modes = { internal_prec = 12, float_format = { "fix", 2 }, angle_mode = "rad" } })
  it("sets the float format and angle mode", function()
    local buf = org_buffer({ "| 1 |   |   |", "#+TBLFM: $2=$1/3::$3=sin(1)" }, { 1, 2 })
    tbl.recalc(0, 1)
    eq("| 1 | 0.33 | 0.84 |", buf_lines(buf)[1])
  end)
end)

describe("table: calc_default_modes fractions", function()
  with_config({ calc_default_modes = { prefer_frac = true } })
  it("prefers fractions", function()
    local buf = org_buffer({ "| 1 |   |", "#+TBLFM: $2=$1/3" }, { 1, 2 })
    tbl.recalc(0, 1)
    eq("| 1 | 1:3 |", buf_lines(buf)[1])
  end)
end)

describe("table: number_regexp", function()
  it("right-aligns hex numbers by default", function()
    local buf = org_buffer({ "| 0xFF | x |", "| 0x1A | y |", "| abc | z |" }, { 1, 2 })
    tbl.align()
    eq({ "| 0xFF | x |", "| 0x1A | y |", "|  abc | z |" }, buf_lines(buf))
    ok(tbl.is_number("NAN"))
    ok(tbl.is_number("-inf"))
    ok(tbl.is_number("16#FF"))
  end)
end)

describe("table: number_regexp custom", function()
  with_config({ table_number_regexp = "^[0-9]+$" })
  it("uses the regexp", function()
    ok(not tbl.is_number("1.5"))
    ok(tbl.is_number("15"))
    local buf = org_buffer({ "| 1.5 | x |", "| 2.5 | y |", "| abc | z |" }, { 1, 2 })
    tbl.align()
    eq({ "| 1.5 | x |", "| 2.5 | y |", "| abc | z |" }, buf_lines(buf))
  end)
end)

describe("table: goto_column", function()
  it("goes to the Nth field", function()
    org_buffer({ "| a | b | c |" }, { 1, 2 })
    tbl.goto_column(2)
    eq({ 1, 6 }, cursor())
    tbl.goto_column(5)
    eq({ 1, 12 }, cursor()) -- after the last `|` (Normal mode: on it)
    org_buffer({ "| a | b |   |" }, { 1, 2 })
    tbl.goto_column(3)
    eq({ 1, 10 }, cursor())
  end)
end)

describe("table: wrap_region (M-RET)", function()
  it("splits the field at the cursor", function()
    local buf = org_buffer({ "| aaa bbb ccc | x |", "| ddd         | y |" }, { 1, 9 })
    tbl.wrap_region({ split = true })
    eq({ "| aaa bbb | x |", "| ccc ddd | y |" }, buf_lines(buf))
    eq({ 2, 2 }, cursor())
    buf = org_buffer({ "| a | aaa bbb |" }, { 1, 10 })
    tbl.wrap_region({ split = true })
    eq({ "| a | aaa |", "|   | bbb |" }, buf_lines(buf))
    eq({ 2, 6 }, cursor())
    buf = org_buffer({ "| aaa bbb | x |", "|----+---|", "| ddd | y |" }, { 1, 6 })
    tbl.wrap_region({ split = true })
    eq({ "| aaa | x |", "| bbb |   |", "|-----+---|", "| ddd | y |" }, buf_lines(buf))
  end)

  it("goes to the field below without splitting", function()
    local buf = org_buffer({ "| aaa bbb ccc | x |", "| ddd         | y |" }, { 1, 9 })
    tbl.wrap_region({ split = false })
    eq({ "| aaa bbb ccc | x |", "| ddd         | y |" }, buf_lines(buf))
    eq({ 2, 2 }, cursor())
  end)

  it("with a count appends the field to the one above", function()
    local buf = org_buffer({ "| aaa | x |", "|-----+---|", "| bbb | y |" }, { 3, 2 })
    tbl.wrap_region({ count = 4 })
    eq({ "| aaa bbb | x |", "|---------+---|", "|         | y |" }, buf_lines(buf))
    eq({ 1, 2 }, cursor())
  end)

  it("wraps a selected column like a paragraph", function()
    local text = { "| one two three | x |", "| four five | y |", "| six | z |", "| | w |" }
    local buf = org_buffer(text, { 1, 2 })
    in_visual("vjj", function()
      tbl.wrap_region()
    end)
    eq({ "| one two    | x |", "| three four | y |", "| five six   | z |", "|            | w |" }, buf_lines(buf))
    eq({ 1, 2 }, cursor())
    buf = org_buffer(text, { 1, 2 })
    in_visual("vjj", function()
      tbl.wrap_region({ count = 2 })
    end)
    eq(
      { "| one two three | x |", "| four five six | y |", "|               | z |", "|               | w |" },
      buf_lines(buf)
    )
  end)

  it("is what M-RET does in a table", function()
    local buf = org_buffer({ "| aaa bbb ccc | x |", "| ddd         | y |" }, { 1, 9 })
    require("org.context").meta_return()
    -- Normal mode: no split, like Insert mode with meta_return_split_line = false
    eq({ "| aaa bbb ccc | x |", "| ddd         | y |" }, buf_lines(buf))
    eq({ 2, 2 }, cursor())
  end)
end)

describe("table: default_size", function()
  with_config({ table_default_size = "2x3" })
  it("is the default of the size prompt", function()
    local buf = org_buffer({ "" }, { 1, 0 })
    local orig = require("org.utils").input
    local prompt
    require("org.utils").input = function(o)
      prompt = o.prompt
      return ""
    end
    tbl.create_or_convert()
    require("org.utils").input = orig
    eq("Table size Columns x Rows [e.g. 2x3]: ", prompt)
    eq({ "|   |   |", "|---+---|", "|   |   |", "|   |   |" }, buf_lines(buf))
  end)
end)

describe("table: convert_region_max_lines", function()
  with_config({ table_convert_region_max_lines = 2 })
  it("refuses longer regions", function()
    local buf = org_buffer({ "a b", "c d", "e f" }, { 1, 0 })
    in_visual("Vjj", tbl.create_or_convert)
    eq({ "a b", "c d", "e f" }, buf_lines(buf))
  end)
end)

-- Typing is simulated: the InsertCharPre handler, the character going in,
-- then the TextChangedI handler.
local function type_chars(buf, chars)
  local typing = require("org.table.typing")
  for ch in chars:gmatch(".") do
    typing._on_char(buf, ch)
    local c = cursor()
    vim.api.nvim_buf_set_text(buf, c[1] - 1, c[2], c[1] - 1, c[2], { ch })
    vim.api.nvim_win_set_cursor(0, { c[1], c[2] + 1 })
    typing._on_changed(buf)
  end
end

describe("table: auto_blank_field and overwriting padding", function()
  it("blanks the field typed into after <Tab>", function()
    local buf = org_buffer({ "| a | abc   | x |" }, { 1, 2 })
    tbl.next_field()
    type_chars(buf, "xy")
    eq("| a | xy  | x |", buf_lines(buf)[1])
    buf = org_buffer({ "| abc |", "| def |" }, { 1, 2 })
    tbl.next_row()
    type_chars(buf, "z")
    eq("| z   |", buf_lines(buf)[2])
  end)

  it("overwrites padding when typing", function()
    local buf = org_buffer({ "| ab    | x |" }, { 1, 4 })
    type_chars(buf, "c")
    eq("| abc   | x |", buf_lines(buf)[1])
    buf = org_buffer({ "| ab | x |" }, { 1, 4 })
    type_chars(buf, "c")
    eq("| abc | x |", buf_lines(buf)[1])
  end)
end)

describe("table: auto_blank_field = false", function()
  with_config({ table_auto_blank_field = false })
  it("inserts before the field text", function()
    local buf = org_buffer({ "| a | abc   | x |" }, { 1, 2 })
    tbl.next_field()
    type_chars(buf, "x")
    eq("| a | xabc | x |", buf_lines(buf)[1])
  end)
end)

describe("table: #+STARTUP: align", function()
  it("aligns the tables of the file", function()
    local buf = org_buffer({ "#+STARTUP: align", "| a | bbbb |", "| ccc | d |" })
    vim.wait(100, function()
      return buf_lines(buf)[2] == "| a   | bbbb |"
    end)
    eq({ "#+STARTUP: align", "| a   | bbbb |", "| ccc | d    |" }, buf_lines(buf))
  end)
end)

describe("table: mode hooks", function()
  it("fire User autocmds", function()
    local got = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = { "OrgTableHeaderLineMode", "OrgtblMode" },
      callback = function(ev)
        got[#got + 1] = ev.match .. "=" .. tostring(ev.data.enabled)
      end,
    })
    org_buffer({ "| a |" }, { 1, 2 })
    require("org.table.follow").header_line_mode(0, true)
    require("org.table.follow").header_line_mode(0, false)
    vim.cmd("enew!")
    require("org.table.orgtbl").enable(0)
    require("org.table.orgtbl").disable(0)
    vim.api.nvim_del_autocmd(id)
    eq({ "OrgTableHeaderLineMode=true", "OrgTableHeaderLineMode=false", "OrgtblMode=true", "OrgtblMode=false" }, got)
  end)
end)

describe("table: plot_preset_plot_types", function()
  with_config({
    plot_preset_plot_types = {
      bars = {
        plot_cmd = "plot",
        plot_pre = function()
          return "set style fill solid"
        end,
        plot_func = function(_, data_file, ncols)
          return { string.format("'%s' using 1:%d with boxes", data_file, ncols) }
        end,
      },
    },
  })
  it("adds a plot type (script from Emacs org-plot/gnuplot-script)", function()
    local plot = require("org.table.plot")
    local opts = vim.deepcopy(plot.default_options)
    opts.plot_type = "bars"
    opts.title = "T"
    local script = plot.script({ { "1", "2" }, { "3", "4" } }, "/tmp/data", 2, opts)
    eq(
      table.concat({
        "reset",
        "set term GNUTERM ",
        "set style fill solid",
        "",
        "set title 'T'",
        'set datafile separator "\\t"',
        "plot '/tmp/data' using 1:2 with boxes",
      }, "\n"),
      script
    )
  end)
end)

describe("table: follow-field mode hook", function()
  it("fires OrgTableFollowFieldMode", function()
    local got = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "OrgTableFollowFieldMode",
      callback = function(ev)
        got[#got + 1] = ev.data.enabled
      end,
    })
    org_buffer({ "| a | b |" }, { 1, 2 })
    local follow = require("org.table.follow")
    follow.start()
    follow.stop(0)
    vim.api.nvim_del_autocmd(id)
    eq({ true, false }, got)
  end)
end)

describe("table: orgtbl_optimized", function()
  local function typing_autocmds(buf)
    local ok_, cmds = pcall(vim.api.nvim_get_autocmds, { group = "org.table.typing." .. buf })
    return ok_ and #cmds or 0
  end
  it("makes orgtbl-mode handle typing in tables", function()
    vim.cmd("enew!")
    local buf = vim.api.nvim_get_current_buf()
    require("org.table.orgtbl").enable(buf)
    ok(typing_autocmds(buf) > 0)
    require("org.table.orgtbl").disable(buf)
    eq(0, typing_autocmds(buf))
  end)
end)

describe("table: orgtbl_optimized = false", function()
  with_config({ orgtbl_optimized = false })
  it("leaves typing alone in orgtbl-mode", function()
    vim.cmd("enew!")
    local buf = vim.api.nvim_get_current_buf()
    require("org.table.orgtbl").enable(buf)
    local ok_, cmds = pcall(vim.api.nvim_get_autocmds, { group = "org.table.typing." .. buf })
    eq(0, ok_ and #cmds or 0)
    require("org.table.orgtbl").disable(buf)
  end)
end)

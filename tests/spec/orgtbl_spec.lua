-- Table translators, radio tables, orgtbl-mode and plots, compared with
-- Emacs Org 9.8.10 (orgtbl-to-*, orgtbl-send-table, orgtbl-ascii-plot,
-- org-plot/gnuplot-script): expected strings are Emacs' output.
local orgtbl = require("org.table.orgtbl")
local plot = require("org.table.plot")
local tbl = require("org.table")
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

describe("table translators (orgtbl-to-*)", function()
  local rows = {
    { "Name", "Qty", "Price" },
    "hline",
    { "a & b", "3", "1.5" },
    { "*bold* x_y", "10", "2e3" },
    { "50%", "", "$5" },
  }
  local expected = {
    ["tsv"] = "Name\tQty\tPrice\na & b\t3\t1.5\n*bold* x_y\t10\t2e3\n50%\t\t$5",
    ["csv"] = "Name,Qty,Price\na & b,3,1.5\n*bold* x_y,10,2e3\n50%,,$5",
    ["latex"] = "\\begin{tabular}{lrr}\nName & Qty & Price\\\\\n\\hline\na \\& b & 3 & 1.5\\\\\n\\textbf{bold} x\\textsubscript{y} & 10 & 2e3\\\\\n50\\% &  & \\$5\\\\\n\\end{tabular}",
    ["latex-booktabs"] = "\\begin{tabular}{lrr}\n\\toprule\nName & Qty & Price\\\\\n\\midrule\na \\& b & 3 & 1.5\\\\\n\\textbf{bold} x\\textsubscript{y} & 10 & 2e3\\\\\n50\\% &  & \\$5\\\\\n\\bottomrule\n\\end{tabular}",
    ["latex-splice"] = "Name & Qty & Price\\\\\n\\hline\na \\& b & 3 & 1.5\\\\\n\\textbf{bold} x\\textsubscript{y} & 10 & 2e3\\\\\n50\\% &  & \\$5\\\\",
    ["html"] = '<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">\n\n\n<colgroup>\n<col  class="org-left" />\n\n<col  class="org-right" />\n\n<col  class="org-right" />\n</colgroup>\n<thead>\n<tr>\n<th scope="col" class="org-left">Name</th>\n<th scope="col" class="org-right">Qty</th>\n<th scope="col" class="org-right">Price</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td class="org-left">a &amp; b</td>\n<td class="org-right">3</td>\n<td class="org-right">1.5</td>\n</tr>\n\n<tr>\n<td class="org-left"><b>bold</b> x<sub>y</sub></td>\n<td class="org-right">10</td>\n<td class="org-right">2e3</td>\n</tr>\n\n<tr>\n<td class="org-left">50%</td>\n<td class="org-right">&nbsp;</td>\n<td class="org-right">$5</td>\n</tr>\n</tbody>\n</table>',
    ["texinfo"] = "@multitable {aaaaaaaaaa} {aaa} {aaaaa}\n@headitem Name\n@tab Qty\n@tab Price\n@item a & b\n@tab 3\n@tab 1.5\n@item @strong{bold} x@math{_y}\n@tab 10\n@tab 2e3\n@item 50%\n@tab \n@tab $5\n@end multitable",
    ["orgtbl"] = "| Name       | Qty | Price |\n|------------+-----+-------|\n| a & b      |   3 |   1.5 |\n| *bold* x_y |  10 |   2e3 |\n| 50%        |     |    $5 |",
    ["generic"] = "BEGIN\n<Name ; Qty ; Price>\n---\n<a & b ; 3 ; 1.5>\n<*bold* x_y ; 10 ; 2e3>\n<50% ;  ; $5>\nEND",
    ["generic-h"] = "H:{Name}|{Qty}|{Price}\n[a & b],[3],[1.5]\n[*bold* x_y],[10],[2e3]\n[50%],,[$5]",
    ["generic-skip"] = "a & b,1.5\n*bold* x_y,2e3\n50%,$5",
    ["generic-lfmt"] = "Name = Qty @ Price\na & b = 3 @ 1.5\n*bold* x_y = 10 @ 2e3\n50% =  @ $5",
    ["generic-llend"] = "Name,Qty,Price \\\\\na & b,3,1.5 \\\\\n*bold* x_y,10,2e3 \\\\\n50%,,$5.",
    ["generic-efmt"] = "Name,Qty,Price\na & b,3,1.5\n*bold* x_y,10,2 x10^3\n50%,,$5",
    ["latex-fmt"] = "\\begin{tabular}{lrr}\nName & $Qty$ & Price\\\\\n\\hline\na \\& b & $3$ & 1.5\\\\\n\\textbf{bold} x\\textsubscript{y} & $10$ & 2e3\\\\\n50\\% &  & \\$5\\\\\n\\end{tabular}",
    ["generic-default"] = "NameQtyPrice\na & b31.5\n*bold* x_y102e3\n50%$5",
  }
  local cases = {
    { "tsv", "orgtbl-to-tsv", "" },
    { "csv", "orgtbl-to-csv", "" },
    { "latex", "orgtbl-to-latex", "" },
    { "latex-booktabs", "orgtbl-to-latex", ":booktabs t" },
    { "latex-splice", "orgtbl-to-latex", ":splice t" },
    { "html", "orgtbl-to-html", "" },
    { "texinfo", "orgtbl-to-texinfo", "" },
    { "orgtbl", "orgtbl-to-orgtbl", "" },
    { "generic", "orgtbl-to-generic", ':sep " ; " :lstart "<" :lend ">" :hline "---" :tstart "BEGIN" :tend "END"' },
    { "generic-h", "orgtbl-to-generic", ':sep "," :hsep "|" :hlstart "H:" :fmt "[%s]" :hfmt "{%s}"' },
    { "generic-skip", "orgtbl-to-generic", ':sep "," :skip 2 :skipcols (2)' },
    { "generic-lfmt", "orgtbl-to-generic", ':lfmt "%s = %s @ %s" :hline nil' },
    { "generic-llend", "orgtbl-to-generic", ':sep "," :lend " \\\\\\\\" :llend "." :hline nil' },
    { "generic-efmt", "orgtbl-to-generic", ':sep "," :efmt "%s x10^%s" :hline nil' },
    { "latex-fmt", "orgtbl-to-latex", ':fmt (2 "$%s$")' },
    { "generic-default", "orgtbl-to-generic", "" },
  }
  for _, c in ipairs(cases) do
    it(c[1], function()
      eq(expected[c[1]], orgtbl.translate(c[2], rows, c[3]))
    end)
  end

  it("drops the special column and special rows", function()
    local out = orgtbl.translate("orgtbl-to-csv", {
      { "!", "a", "b" },
      { "#", "1", "2" },
      { "", "<5>", "" },
      { "*", "3", "4" },
    }, "")
    eq("1,2\n3,4", out)
  end)

  it("table_export writes the translator output", function()
    local path = vim.fn.tempname() .. ".tex"
    org_buffer({ "| a | b |", "|---+---|", "| 1 | 2 |" }, { 1, 2 })
    quiet(function()
      tbl.export(path, "orgtbl-to-latex :splice t")
    end)
    eq({ "a & b\\\\", "\\hline", "1 & 2\\\\" }, utils.readfile(path))
  end)
end)

describe("radio tables", function()
  it("C-c C-c on the table sends it to the receiver", function()
    local buf = org_buffer({
      "% BEGIN RECEIVE ORGTBL sales",
      "old",
      "% END RECEIVE ORGTBL sales",
      "#+ORGTBL: SEND sales orgtbl-to-latex :splice t",
      "| a | b |",
      "| 1 | 2 |",
    }, { 5, 2 })
    quiet(function()
      eq(1, orgtbl.send_table(buf, 5))
    end)
    eq({ "% BEGIN RECEIVE ORGTBL sales", "a & b\\\\", "1 & 2\\\\", "% END RECEIVE ORGTBL sales" }, vim.list_slice(buf_lines(buf), 1, 4))
    -- recalculating from #+TBLFM sends it too
    vim.api.nvim_buf_set_lines(buf, 7, 7, false, { "#+TBLFM: $2=$1*10" })
    quiet(function()
      tbl.calc_current_tblfm(buf, 8)
    end)
    eq("1 & 10\\\\", buf_lines(buf)[3])
  end)

  it("warns without a receiver", function()
    local buf = org_buffer({ "#+ORGTBL: SEND x orgtbl-to-csv", "| a |" })
    local seen
    local warn = utils.warn
    utils.warn = function(m)
      seen = m
    end
    orgtbl.send_table(buf, 2)
    utils.warn = warn
    eq("No valid receiver location found in the buffer", seen)
  end)

  it("inserts a template for the filetype", function()
    vim.cmd("enew!")
    vim.bo.filetype = "html"
    local input = utils.input
    utils.input = function()
      return "t1"
    end
    orgtbl.insert_radio_table()
    utils.input = input
    eq({
      "<!-- BEGIN RECEIVE ORGTBL t1 -->",
      "<!-- END RECEIVE ORGTBL t1 -->",
      "<!--",
      "#+ORGTBL: SEND t1 orgtbl-to-html :splice nil :skip 0",
      "| | |",
      "-->",
    }, buf_lines(0))
    vim.cmd("bwipe!")
  end)
end)

describe("orgtbl-mode", function()
  it("edits tables in other filetypes and keeps keys elsewhere", function()
    vim.cmd("enew!")
    local buf = vim.api.nvim_get_current_buf()
    vim.bo.filetype = "markdown"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "text", "|a|bb|", "|1|2|" })
    quiet(function()
      orgtbl.enable(buf)
    end)
    vim.api.nvim_win_set_cursor(0, { 2, 1 })
    vim.api.nvim_feedkeys(vim.keycode("<C-c><C-c>"), "xt", false)
    eq({ "text", "| a | bb |", "| 1 |  2 |" }, buf_lines(buf))
    vim.api.nvim_win_set_cursor(0, { 3, 2 })
    vim.api.nvim_feedkeys(vim.keycode("A<Tab>x<Esc>"), "xt", false)
    eq({ "text", "| a | bb |", "| 1 |  2 |", "| x |    |" }, buf_lines(buf))
    -- outside tables <Tab> inserts a tab
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("I<Tab><Esc>"), "xt", false)
    ok(buf_lines(buf)[1]:match("^%s+text$"))
    quiet(function()
      orgtbl.toggle(buf)
    end)
    eq(nil, vim.b[buf].orgtbl_mode)
    vim.cmd("bwipe!")
  end)

  it("toggles a comment around the table", function()
    vim.cmd("enew!")
    vim.bo.commentstring = "% %s"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "| a |", "| b |" })
    orgtbl.toggle_comment()
    eq({ "% | a |", "% | b |" }, buf_lines(0))
    orgtbl.toggle_comment()
    eq({ "| a |", "| b |" }, buf_lines(0))
    vim.cmd("bwipe!")
  end)
end)

describe("plots", function()
  it("ASCII plot adds a bar column (orgtbl-ascii-plot)", function()
    local buf = org_buffer({
      "| name | n |",
      "|------+---|",
      "| a | 1 |",
      "| b | 5 |",
      "| c | 10 |",
      "| d | 2.5 |",
      "#+TBLFM: $1=$1",
    }, { 3, 9 })
    quiet(function()
      plot.ascii_plot()
    end)
    eq({
      "| name |   n |              |",
      "|------+-----+--------------|",
      "| a    |   1 |              |",
      "| b    |   5 | WWWWW;       |",
      "| c    |  10 | WWWWWWWWWWWW |",
      "| d    | 2.5 | WW           |",
      "#+TBLFM: $1=$1::$3='(orgtbl-ascii-draw $2 1 10 12)",
    }, buf_lines(buf))
  end)

  it("parses #+PLOT: options like org-plot", function()
    local o = plot.parse_options({}, 'title:"Hello W" ind:1 deps:(2 3) type:2d with:histograms set:"yrange [0:]" set:"grid" file:"out.png"')
    eq("Hello W", o.title)
    eq(1, o.ind)
    eq({ 2, 3 }, o.deps)
    eq("histograms", o.with)
    eq({ "grid", "yrange [0:]" }, o.set)
    eq("out.png", o.file)
  end)

  it("writes gnuplot scripts and data like org-plot", function()
    local script = plot.script({ { "1", "2" }, { "3", "4" } }, "/tmp/data", 2, {
      plot_type = "2d",
      with = "lines",
      ind = 1,
      title = "T",
      labels = { "x", "y" },
      set = { "grid" },
      line = { "set key left" },
    })
    eq(
      "reset\nset term GNUTERM \n\nset title 'T'\nset key left\nset grid\nset datafile separator \"\\t\"\nplot '/tmp/data' using 1:2 with lines title 'y'",
      script
    )
    script = plot.script({}, "/tmp/data", 2, { plot_type = "3d", with = "pm3d", map = true })
    eq("reset\nset term GNUTERM \nset map\n\nset datafile separator \"\\t\"\nsplot '/tmp/data' matrix with pm3d title ''", script)
    eq('"a"\t1\n"b c"\t2\n2024-01-10-00:00:00\t3', plot.data({ { "a", "1" }, { "b c", "2" }, { "<2024-01-10 Wed>", "3" } }, {}))
  end)

  it("collects the options and header labels of a table", function()
    local buf = org_buffer({ "#+PLOT: title:\"Sales\" ind:1", "| m | v |", "|---+---|", "| 1 | 5 |" })
    local opts, rows, ncols = plot.collect(buf, 1)
    eq("Sales", opts.title)
    eq({ "m", "v" }, opts.labels)
    eq({ { "1", "5" } }, rows)
    eq(2, ncols)
  end)
end)

-- ob-groovy, ob-julia, ob-maxima and ob-ocaml, checked against Emacs Org
-- 9.8.10 (`emacs --batch`): expansions from org-babel-expand-src-block and
-- results from org-babel-execute-buffer with the same fake programs (none
-- of them is installed). Emacs can't run OCaml blocks without tuareg, so
-- the OCaml transcript parsing follows ob-ocaml's code.
local config = require("org.config")
local h = require("tests.helpers.babel_ob")

local FAKE_GROOVY = [[
if grep -q 'class Runner' "$1"; then cat "$1" > "$(dirname "$0")/groovy.log"; echo 42; else cat "$1"; fi]]

local FAKE_JULIA = [[
code=$(cat)
out=$(printf '%s\n' "$code" | sed -n 's/^    local p_tmp_file = "\(.*\)"$/\1/p')
if [ -n "$out" ]; then printf '1,2\n3,x\n' > "$out"; printf '%s\n' "$code" > "$(dirname "$0")/julia.log"; else printf '%s\n' "$code"; fi]]

local FAKE_MAXIMA = [[
echo "ARGS: $*"
echo "read and interpret /tmp/x.max"
echo "(%i1) "
echo "rat: replaced 0.5 by 1/2 = 0.5"
file=$(echo "$2" | sed 's/.*("\(.*\)"))\$$/\1/')
cat "$file"
echo ""
echo "1 2"]]

describe("babel ob-groovy", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(h.restore)

  it("runs the script for output, the Runner wrapper for a value", function()
    local dir = h.tmpdir()
    h.set_lang("groovy", { cmd = h.fake(dir, "groovy", FAKE_GROOVY) })
    local out = h.run({
      "#+begin_src groovy :results output :var x=1",
      'println "hi"',
      "#+end_src",
      "",
      "#+begin_src groovy",
      "[1, 2, 3]",
      "#+end_src",
    }, dir)
    -- Emacs 9.8.10: :var is ignored, the value is read back
    eq({ "#+RESULTS:", ': println "hi"' }, vim.list_slice(out, 5, 6))
    eq({ "#+RESULTS:", ": 42" }, vim.list_slice(out, 12, 13))
    eq({
      "class Runner extends Script {",
      "    def out = new PrintWriter(new ByteArrayOutputStream())",
      "    def run() { [1, 2, 3] }",
      "}",
      "",
      "println(new Runner().run())",
    }, vim.fn.readfile(dir .. "/groovy.log"))
  end)
end)

describe("babel ob-julia", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(h.restore)

  it("assigns variables, reads the CSV value file, :colnames yes adds an hline", function()
    local dir = h.tmpdir()
    h.set_lang("julia", { cmd = h.fake(dir, "julia", FAKE_JULIA) })
    local out = h.run({
      "#+name: tb",
      "| a | b |",
      "|---+---|",
      "| 1 | x |",
      "",
      '#+begin_src julia :var n=3 s="q\\"r" :results output',
      "println(n)",
      "#+end_src",
      "",
      "#+begin_src julia :var t=tb",
      "t",
      "#+end_src",
      "",
      "#+begin_src julia :colnames yes",
      "1",
      "#+end_src",
    }, dir)
    -- Emacs 9.8.10
    eq({ "#+RESULTS:", ": n = 3", ': s = "q""r"', ": println(n)" }, vim.list_slice(out, 10, 13))
    eq({ "#+RESULTS:", "| 1 | 2 |", "| 3 | x |" }, vim.list_slice(out, 19, 21))
    eq({ "#+RESULTS:", "| 1 | 2 |", "|---+---|", "| 3 | x |" }, vim.list_slice(out, 27, 30))
    local log = vim.fn.readfile(dir .. "/julia.log")
    eq({ "begin", "    local p_ans = begin 1 end" }, vim.list_slice(log, 1, 2))
    eq("                  writeheader = true,", log[16])
  end)

  it("writes table variables to a CSV file read by CSV.jl", function()
    local text = h.expand({
      "#+name: tb",
      "| a | b |",
      "|---+---|",
      "| 1 | x |",
      "",
      "#+begin_src julia :var t=tb",
      "t",
      "#+end_src",
    })
    -- Emacs puts the CSV text itself in CSV.read("..."): a file here
    local file = text:match('CSV%.read%("([^"]+)"%)')
    ok(file)
    eq({ '"a","b"', '"1","x"' }, vim.fn.readfile(file))
    eq('t = begin\n    using CSV\n    CSV.read("' .. file .. '")\nend\nt', text)
  end)
end)

describe("babel ob-maxima", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(h.restore)

  it("batchloads the expanded file and filters Maxima's noise", function()
    local dir = h.tmpdir()
    h.set_lang("maxima", { cmd = h.fake(dir, "maxima", FAKE_MAXIMA) })
    local out = h.run({
      "#+begin_src maxima :var x=2 l='(1 2) :results verbatim",
      "x + 1;",
      "#+end_src",
      "",
      "#+begin_src maxima :batch batch :cmdline --quiet :results verbatim",
      "1;",
      "#+end_src",
      "",
      "#+begin_src maxima :results table",
      "1;",
      "#+end_src",
      "",
      "#+begin_src maxima :file p.png :results graphics file",
      "plot2d(sin(x), [x, 0, 1])$",
      "#+end_src",
    }, dir)
    -- Emacs 9.8.10
    eq({
      "#+begin_src maxima :var x=2 l='(1 2) :results verbatim",
      "x + 1;",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": x: 2$",
      ": l: [1, 2]$",
      ": x + 1;",
      ": 1 2",
      "",
      "#+begin_src maxima :batch batch :cmdline --quiet :results verbatim",
      "1;",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": 1;",
      ": 1 2",
      "",
      "#+begin_src maxima :results table",
      "1;",
      "#+end_src",
      "",
      "#+RESULTS:",
      "| 1; |   |",
      "|  1 | 2 |",
      "",
      "#+begin_src maxima :file p.png :results graphics file",
      "plot2d(sin(x), [x, 0, 1])$",
      "#+end_src",
      "",
      "#+RESULTS:",
      "[[file:p.png]]",
    }, out)
    eq("x + 1;", h.expand({ "#+begin_src maxima :var x=2", "x + 1;", "#+end_src" }))
  end)

  it("sets up the graphics package for a graphics :file", function()
    local m = require("org.babel.lang.maxima")
    local args = require("org.babel.blocks").header_args(
      require("org.babel.blocks").parse_blocks({ "#+begin_src maxima :file p.png :results graphics file", "#+end_src" })[1]
    )
    args.file = "p.png"
    eq(
      "(set_plot_option ('[gnuplot_term, png]), set_plot_option ('[gnuplot_out_file, \"p.png\"]))$\n\nplot\ngnuplot_close ()$",
      m.maxima_expand({ "plot" }, args, {})
    )
    args["graphics-pkg"] = "draw"
    eq(
      "(load(draw), set_draw_defaults(terminal='png,file_name=\"p\"))$\n\nplot\ngnuplot_close ()$",
      m.maxima_expand({ "plot" }, args, {})
    )
  end)
end)

describe("babel ob-ocaml", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(h.restore)

  it("expands variables like org-babel-variable-assignments:ocaml", function()
    -- Emacs 9.8.10
    eq(
      'let a = 1;;\nlet l = [|1; 2|];;\nlet s = "x";;\na + 1',
      h.expand({ "#+begin_src ocaml :var a=1 l='(1 2) s=\"x\"", "a + 1", "#+end_src" })
    )
  end)

  it("reads the toplevel's answer by type", function()
    local dir = h.tmpdir()
    local transcript = table.concat({
      "        OCaml version 5.1.0",
      "",
      "# val a : int = 1",
      "# - : int list = [1; 2; 3]",
      '# - : string = "org-babel-ocaml-eoe"',
      "# ",
    }, "\n")
    local f = dir .. "/transcript"
    vim.fn.writefile(vim.split(transcript, "\n"), f)
    h.set_lang("ocaml", { cmd = h.fake(dir, "ocaml", "cat > " .. dir .. "/input; cat " .. f) })
    local out = h.run({
      "#+begin_src ocaml :var a=1",
      "[1; 2; 3]",
      "#+end_src",
      "",
      "#+begin_src ocaml :results verbatim",
      "[1; 2; 3]",
      "#+end_src",
    }, dir)
    eq({ "#+RESULTS:", "| 1 | 2 | 3 |" }, vim.list_slice(out, 5, 6))
    eq({ "#+RESULTS:", ": - : int list = [1; 2; 3]" }, vim.list_slice(out, 12, 13))
    eq({ "[1; 2; 3];;", '"org-babel-ocaml-eoe";;' }, vim.fn.readfile(dir .. "/input"))
  end)
end)

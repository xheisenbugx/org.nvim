-- ob-gnuplot. The expanded scripts, data files and results were compared
-- with Emacs Org 9.8.10 in `emacs --batch` (org-babel-expand-src-block,
-- org-babel-execute-buffer with a stub `gnuplot` feature). gnuplot is not
-- installed: a fake `gnuplot` prints the script it is given.
local config = require("org.config")
local h = require("tests.helpers.babel_ob")

describe("babel ob-gnuplot", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(h.restore)

  it("expands header arguments and writes table variables to data files", function()
    local dir = h.tmpdir()
    local buf = org_buffer({ "" }, { 1, 0 })
    vim.api.nvim_buf_set_name(buf, dir .. "/g.org")
    local lines = {
      "#+name: data",
      "| x | y                |",
      "|---+------------------|",
      "| 1 | a b              |",
      "| 2 |                  |",
      '| 3 | "q"              |',
      "| 4 | <2024-01-02 Tue> |",
      "",
      "#+begin_src gnuplot :var d=data :file out.png :title \"T\" :set '(\"grid\" \"key off\") :line '(\"lw 2\") "
        .. ':missing "?" :xlabels \'((1 . "one") (2 . "two")) :timefmt "%Y" :prologue "reset" :epilogue "exit"',
      "plot $d using 1:2",
      "#+end_src",
    }
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local blocks = require("org.babel.blocks")
    local b = blocks.parse_blocks(lines)[1]
    local args = blocks.header_args(b, require("org.babel").get_file(buf))
    local text = table.concat(require("org.babel").expand_body(buf, b, args), "\n")
    local data = text:match('d = "([^"]+)"')
    ok(data)
    -- Emacs 9.8.10
    eq({
      "cd '" .. dir .. "/'",
      "reset",
      'd = "' .. data .. '"',
      "set term png",
      'set output "out.png"',
      'set timefmt "%Y"',
      "set xdata time",
      'set xtics ("one" 1, "two" 2)',
      "set key off",
      "set grid",
      "lw 2",
      "set title 'T'",
      "set datafile missing '?'",
      "plot " .. data .. " using 1:2",
      "set output",
      "",
      "exit",
    }, vim.split(text, "\n", { plain = true }))
    local ts = os.date("%Y-%m-%d-%H:%M:%S", os.time({ year = 2024, month = 1, day = 2, hour = 0 }))
    eq({ '1\t"a b"', "2\t?", "3\tq", "4\t" .. ts }, vim.fn.readfile(data))
  end)

  it("sets the terminal of the :file extension (eps: postscript eps)", function()
    local text = h.expand({ "#+begin_src gnuplot :file x.eps", "plot sin(x)", "#+end_src" })
    local l = vim.split(text, "\n", { plain = true })
    ok(l[1]:match("^cd '"))
    eq({ "", "set term postscript eps", 'set output "x.eps"', "plot sin(x)", "set output", "" }, vim.list_slice(l, 2))
  end)

  it("runs gnuplot; :results output returns what it printed, else the :file link", function()
    local dir = h.tmpdir()
    local exe = h.fake(dir, "fakegnuplot", 'cat "$1" | tail -n +2')
    h.set_lang("gnuplot", { cmd = exe })
    -- Emacs 9.8.10 (with the same fake gnuplot and a stub gnuplot feature):
    -- the default `:results file` makes a link of the printed text
    local out = h.run({
      "#+begin_src gnuplot :session none :var n=5 :term dumb :results output",
      "print n",
      "#+end_src",
      "",
      "#+begin_src gnuplot :session none :file p.png",
      "plot x",
      "#+end_src",
      "",
      "#+begin_src gnuplot :session none :var n=5 :results output verbatim",
      "print n",
      "#+end_src",
    }, dir)
    eq({
      "#+begin_src gnuplot :session none :var n=5 :term dumb :results output",
      "print n",
      "#+end_src",
      "",
      "#+RESULTS:",
      '[[file:n = "5"',
      "set term dumb",
      "print n",
      "]]",
      "",
      "#+begin_src gnuplot :session none :file p.png",
      "plot x",
      "#+end_src",
      "",
      "#+RESULTS:",
      "[[file:p.png]]",
      "",
      "#+begin_src gnuplot :session none :var n=5 :results output verbatim",
      "print n",
      "#+end_src",
      "",
      "#+RESULTS:",
      ': n = "5"',
      ": print n",
    }, out)
  end)
end)

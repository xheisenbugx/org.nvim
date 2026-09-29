-- ob-latex, checked against Emacs Org 9.8.10 (`emacs --batch`,
-- org-babel-execute-buffer) with the same fake latex, pdflatex, dvipng,
-- inkscape, convert and htlatex on $PATH (TeX is not installed): they log
-- their arguments and the .tex they get, and create the expected outputs.
local config = require("org.config")
local h = require("tests.helpers.babel_ob")

local FAKE_LATEX = [[
log="$(dirname "$0")/latex.log"
name=$(basename "$0")
echo "$name" >> "$log"
for a in "$@"; do last=$a; done
dir=.
prev=
for a in "$@"; do if [ "$prev" = "-output-directory" ]; then dir=$a; fi; prev=$a; done
cat "$last" >> "$log"
echo "---" >> "$log"
base=$(basename "$last" .tex)
if [ "$name" = "pdflatex" ]; then : > "$dir/$base.pdf"; else : > "$dir/$base.dvi"; fi]]

local FAKE_TOOL = [[
log="$(dirname "$0")/latex.log"
name=$(basename "$0")
echo "$name $*" >> "$log"
prev=
for a in "$@"; do
  if [ "$prev" = "-o" ]; then : > "$a"; fi
  case $a in --export-filename=*) : > "${a#--export-filename=}";; esac
  prev=$a; last=$a
done
if [ "$name" = "convert" ]; then : > "$last"; fi
if [ "$name" = "htlatex" ]; then cat "$1" >> "$log"; echo "---" >> "$log"; : > "$(basename "$1" .tex).html"; fi]]

--- The .tex files logged by the fake compilers, deduplicated.
local function texts(log)
  local out, cur, seen = {}, nil, {}
  for _, l in ipairs(log) do
    if l == "pdflatex" or l == "latex" then
      cur = {}
    elseif l:match("%-%-%-$") and cur then
      -- a .tex without a final newline ends on the marker's line
      if l ~= "---" then
        cur[#cur + 1] = l:sub(1, -4)
      end
      local t = table.concat(cur, "\n")
      if not seen[t] then
        seen[t] = true
        out[#out + 1] = t
      end
      cur = nil
    elseif cur then
      cur[#cur + 1] = l
    end
  end
  return out
end

local FULLPAGE = {
  "\\pagestyle{empty}             % do not remove",
  "% The settings below are copied from fullpage.sty",
  "\\setlength{\\textwidth}{\\paperwidth}",
  "\\addtolength{\\textwidth}{-3cm}",
  "\\setlength{\\oddsidemargin}{1.5cm}",
  "\\addtolength{\\oddsidemargin}{-2.54cm}",
  "\\setlength{\\evensidemargin}{\\oddsidemargin}",
  "\\setlength{\\textheight}{\\paperheight}",
  "\\addtolength{\\textheight}{-\\headheight}",
  "\\addtolength{\\textheight}{-\\headsep}",
  "\\addtolength{\\textheight}{-\\footskip}",
  "\\addtolength{\\textheight}{-3cm}",
  "\\setlength{\\topmargin}{1.5cm}",
  "\\addtolength{\\topmargin}{-2.54cm}",
}

describe("babel ob-latex", function()
  local dir
  before_each(function()
    config.opts.babel.confirm_evaluate = false
    dir = h.tmpdir()
    for _, n in ipairs({ "latex", "pdflatex" }) do
      h.fake(dir, n, FAKE_LATEX)
    end
    for _, n in ipairs({ "dvipng", "inkscape", "convert", "htlatex" }) do
      h.fake(dir, n, FAKE_TOOL)
    end
  end)
  after_each(h.restore)

  it("gives the body with variables replaced, without :file", function()
    local out = h.run({ '#+begin_src latex :var NAME="World"', "Hello NAME", "#+end_src" }, dir)
    -- Emacs 9.8.10
    eq({ "#+RESULTS:", "#+begin_export latex", "Hello World", "#+end_export" }, vim.list_slice(out, 5, 8))
  end)

  it("compiles to svg, pdf, tikz, html, imagemagick images and png", function()
    local out
    h.with_path(dir, function()
      out = h.run({
        '#+begin_src latex :file b.svg :headers \'("\\\\usepackage{tikz}")',
        "$y$",
        "#+end_src",
        "",
        '#+begin_src latex :file c.pdf :fit yes :border 2pt :headers \'("\\\\usepackage{x}") :packages \'(("" "amsmath"))',
        "$z$",
        "#+end_src",
        "",
        "#+begin_src latex :file d.tikz",
        "\\draw (0,0);",
        "#+end_src",
        "",
        "#+begin_src latex :file e.html",
        "<b>",
        "#+end_src",
        "",
        "#+begin_src latex :file f.jpg :imagemagick yes :iminoptions -density 300 :imoutoptions -quality 90",
        "$w$",
        "#+end_src",
        "",
        "#+begin_src latex :file g.png :buffer no",
        "$v$",
        "#+end_src",
      }, dir)
    end)
    -- Emacs 9.8.10: with the default `:results latex` the (nil) result is
    -- an empty export block
    for _, i in ipairs({ 5, 13, 21, 29, 37, 45 }) do
      eq({ "#+RESULTS:", "#+begin_export latex", "#+end_export" }, vim.list_slice(out, i, i + 2))
    end
    for _, f in ipairs({ "b.svg", "c.pdf", "e.html", "f.jpg", "g.png" }) do
      ok(vim.fn.filereadable(dir .. "/" .. f) == 1, f)
    end
    eq({ "\\draw (0,0);" }, vim.fn.readfile(dir .. "/d.tikz"))
    local log = vim.fn.readfile(dir .. "/latex.log")
    local tex = texts(log)
    eq("\\documentclass[preview]{standalone}\n\\usepackage{tikz}\\begin{document}$y$\\end{document}", tex[1])
    eq(
      table.concat(
        vim.list_extend(
          vim.list_extend({
            "\\documentclass{article}",
            "\\usepackage[usenames]{color}",
            "\\usepackage[utf8]{inputenc}",
            "\\usepackage[T1]{fontenc}",
            "\\usepackage{graphicx}",
            "\\usepackage{longtable}",
            "\\usepackage{wrapfig}",
            "\\usepackage{rotating}",
            "\\usepackage[normalem]{ulem}",
            "\\usepackage{amsmath}",
            "\\usepackage{amssymb}",
            "\\usepackage{capt-of}",
            "\\usepackage{amsmath}",
          }, vim.deepcopy(FULLPAGE)),
          {
            "\\usepackage[active, tightpage]{preview}",
            "\\setlength{\\PreviewBorder}{2pt}",
            "\\usepackage{x}",
            "",
            "\\begin{document}",
            "\\begin{preview}",
            "$z$",
            "\\end{preview}",
            "\\end{document}",
          }
        ),
        "\n"
      ),
      tex[2]
    )
    -- htlatex's input (the log line ends with the fake's marker)
    local k = vim.fn.index(log, "\\def\\pgfsysdriver{pgfsys-tex4ht.def}") + 1
    eq({
      "\\documentclass[preview]{standalone}",
      "\\def\\pgfsysdriver{pgfsys-tex4ht.def}",
      "\\usepackage[usenames]{color}",
      "\\usepackage{tikz}",
      "\\usepackage{color}",
      "\\usepackage{listings}",
      "\\usepackage{amsmath}\\begin{document}<b>\\end{document}---",
    }, vim.list_slice(log, k - 1, k + 5))
    eq(
      table.concat(
        vim.list_extend(
          vim.list_extend({
            "\\documentclass{article}",
            "\\usepackage[usenames]{color}",
            "\\usepackage[utf8]{inputenc}",
            "\\usepackage[T1]{fontenc}",
            "\\usepackage{graphicx}",
            "\\usepackage{longtable}",
            "\\usepackage{wrapfig}",
            "\\usepackage{rotating}",
            "\\usepackage[normalem]{ulem}",
            "\\usepackage{amsmath}",
            "\\usepackage{amssymb}",
            "\\usepackage{capt-of}",
          }, vim.deepcopy(FULLPAGE)),
          { "\\begin{document}", "$w$", "\\end{document}" }
        ),
        "\n"
      ),
      tex[3]
    )
    local convert
    for _, l in ipairs(log) do
      if l:match("^convert ") then
        convert = l
      end
    end
    ok(convert:match("^convert %-density 300 %S+%.pdf %-quality 90 f%.jpg$"))
    -- :buffer no: black on a transparent background, 140 dpi
    eq(
      table.concat(
        vim.list_extend(
          vim.list_extend({
            "\\documentclass{article}",
            "\\usepackage[usenames]{color}",
            "\\usepackage[utf8]{inputenc}",
            "\\usepackage[T1]{fontenc}",
            "\\usepackage{graphicx}",
            "% Package longtable omitted",
            "% Package wrapfig omitted",
            "% Package rotating omitted",
            "\\usepackage[normalem]{ulem}",
            "\\usepackage{amsmath}",
            "\\usepackage{amssymb}",
            "% Package capt-of omitted",
            "% Package hyperref omitted",
          }, vim.deepcopy(FULLPAGE)),
          {
            "",
            "\\begin{document}",
            "\\definecolor{fg}{rgb}{0,0,0}%",
            "",
            "{\\color{fg}",
            "$v$%",
            "}",
            "",
            "\\end{document}",
          }
        ),
        "\n"
      ),
      tex[4]
    )
    ok(log[#log]:match("^dvipng %-D 140%.0 %-T tight %-bg Transparent %-o %S+%.png %S+%.dvi$"))
  end)

  it("makes png files with process_alist.png", function()
    h.set_lang("latex", {
      process_alist = {
        png = {
          programs = { "latex", "dvipng" },
          image_input_type = "dvi",
          image_output_type = "png",
          latex_compiler = { "latex -output-directory %o %f" },
          image_converter = { "dvipng -D %D -o %O %f" },
        },
      },
    })
    h.with_path(dir, function()
      h.run({ "#+begin_src latex :file p.png :buffer no :results file", "$v$", "#+end_src" }, dir)
    end)
    local log = vim.fn.readfile(dir .. "/latex.log")
    ok(log[#log]:match("^dvipng %-D 140%.0 %-o %S+%.png %S+%.dvi$"))
    eq(1, vim.fn.filereadable(dir .. "/p.png"))
  end)

  it("uses preamble, begin_env, end_env (functions of the header arguments) and pdf_svg_process", function()
    h.set_lang("latex", {
      preamble = function(args)
        return "\\documentclass{" .. (args.class or "x") .. "}\n"
      end,
      begin_env = "\\begin{document}\\color{red}",
      end_env = function()
        return "\\end{document}%"
      end,
      pdf_svg_process = "inkscape -o %O %f",
    })
    h.with_path(dir, function()
      h.run({ "#+begin_src latex :file s.svg :class art", "$y$", "#+end_src" }, dir)
    end)
    local log = vim.fn.readfile(dir .. "/latex.log")
    eq({ "\\documentclass{art}", "\\begin{document}\\color{red}$y$\\end{document}%---" }, vim.list_slice(log, 2, 3))
    ok(log[#log]:match("^inkscape %-o %S+%.svg %S+%.pdf$"))
  end)
end)

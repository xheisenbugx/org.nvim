-- ob-lisp (Common Lisp) and ob-scheme. The expansions were checked against
-- Emacs Org 9.8.10 (org-babel-expand-src-block in `emacs --batch`). Emacs
-- evaluates them through SLIME and Geiser, which are not available in
-- batch, so evaluation follows the code: Common Lisp runs in `sbcl
-- --script` (not installed: a fake writes the output and value files),
-- Scheme in guile (when installed).
local config = require("org.config")
local h = require("tests.helpers.babel_ob")

local FAKE_SBCL = [[
cp "$1" "$(dirname "$0")/sbcl.log"
files=$(sed -n 's/.*(cl:with-open-file (f "\([^"]*\)".*/\1/p' "$1")
out=$(echo "$files" | sed -n 1p)
val=$(echo "$files" | sed -n 2p)
printf 'printed\n' > "$out"
printf '#(1 2) "s"' > "$val"]]

describe("babel ob-lisp", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(h.restore)

  it("expands like org-babel-expand-body:lisp", function()
    local lines = {
      "#+begin_src lisp",
      "  (+ 1 2)",
      "#+end_src",
      "",
      "#+begin_src lisp :var x=1 l='(1 \"a\") :prologue \";; pro\" :epilogue \";; epi\"",
      "(list x l)",
      "#+end_src",
      "",
      "#+begin_src lisp :results pp",
      "(list 1 2)",
      "#+end_src",
    }
    -- Emacs 9.8.10
    eq("(+ 1 2)", h.expand(lines, 1))
    eq(
      "(cl:let ((x (cl:quote 1))\n      (l (cl:quote (1 \"a\"))))\n;; pro\n(list x l)\n;; epi\n)",
      h.expand(lines, 2)
    )
    eq("(cl:pprint (list 1 2))", h.expand(lines, 3))
  end)

  it("evaluates the form in the block's directory and reads the values", function()
    local dir = h.tmpdir()
    h.set_lang("lisp", { cmd = h.fake(dir, "sbcl", FAKE_SBCL) })
    local out = h.run({
      "#+begin_src lisp :package my-pkg",
      "(values (vector 1 2) \"s\")",
      "#+end_src",
      "",
      "#+begin_src lisp :results output",
      '(princ "printed")',
      "#+end_src",
    }, dir)
    -- the two printed values are read as one Lisp form: #(1 2) -> (1 2)
    eq({ "#+RESULTS:", "| 1 | 2 |" }, vim.list_slice(out, 5, 6))
    eq({ "#+RESULTS:", ": printed" }, vim.list_slice(out, 12, 13))
    local w = table.concat(vim.fn.readfile(dir .. "/sbcl.log"), "\n")
    ok(w:find('(cl:eval (cl:read-from-string "(cl:let ((cl:*default-pathname-defaults* #P\\"' .. dir .. '/\\"\n)) (princ \\"printed\\")\n)"))', 1, true))
    ok(w:find('~{~S~^~%~}', 1, true))
  end)
end)

describe("babel ob-scheme", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(h.restore)

  it("expands like org-babel-expand-body:scheme", function()
    -- Emacs 9.8.10
    eq(
      ";; pro\n(define x '1)\n(define l '(1 \"a\"))\n(list x l)\n;; epi",
      h.expand({
        "#+begin_src scheme :var x=1 l='(1 \"a\") :prologue \";; pro\" :epilogue \";; epi\"",
        "(list x l)",
        "#+end_src",
      })
    )
  end)

  it("runs guile: the last value, output, lists as tables with () as hline", function()
    if vim.fn.executable("guile") == 0 then
      return
    end
    local out = h.run({
      "#+begin_src scheme :var x=2",
      "(define y 3)",
      "(* x y)",
      "#+end_src",
      "",
      "#+begin_src scheme",
      "(list 1 '() 3)",
      "#+end_src",
      "",
      "#+begin_src scheme :results output",
      '(display "hi")',
      "#+end_src",
      "",
      "#+begin_src scheme",
      '"str"',
      "#+end_src",
    })
    eq({ "#+RESULTS:", ": 6" }, vim.list_slice(out, 6, 7))
    eq({ "#+RESULTS:", "| 1 | hline | 3 |" }, vim.list_slice(out, 13, 14))
    eq({ "#+RESULTS:", ": hi" }, vim.list_slice(out, 20, 21))
    eq({ "#+RESULTS:", ": str" }, vim.list_slice(out, 27, 28))
  end)
end)

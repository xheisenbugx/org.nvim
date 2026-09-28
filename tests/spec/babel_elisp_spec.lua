-- emacs-lisp Babel blocks (in an external `emacs --batch`, or on the Lisp
-- interpreter of table formulas without one) and elisp: links. EXPECTED is
-- the buffer after Org 9.8.10 org-babel-execute-buffer on INPUT.
local babel = require("org.babel")
local config = require("org.config")
local elisp = require("org.babel.elisp")
local links = require("org.links")
local utils = require("org.utils")

local function has_emacs()
  return vim.fn.executable("emacs") == 1
end

local INPUT = {
  "#+begin_src emacs-lisp",
  "(+ 1 2)",
  "#+end_src",
  "",
  "#+begin_src emacs-lisp",
  "'((1 2) (3 4))",
  "#+end_src",
  "",
  "#+begin_src elisp",
  "(list \"a\" 'b 2.5)",
  "#+end_src",
  "",
  "#+begin_src emacs-lisp :results output",
  "(princ \"hello\\n\")",
  "(print '(1 \"x\"))",
  "#+end_src",
  "",
  "#+begin_src emacs-lisp :results verbatim",
  "\"quoted\"",
  "#+end_src",
  "",
  "#+begin_src emacs-lisp",
  "\"plain\"",
  "#+end_src",
  "",
  "#+begin_src emacs-lisp",
  "nil",
  "#+end_src",
  "",
  "#+NAME: tbl",
  "| a | b |",
  "|---+---|",
  "| 1 | 2 |",
  "| 3 | 4 |",
  "",
  "#+begin_src emacs-lisp :var x=tbl",
  "(mapcar (lambda (r) (apply #'+ r)) x)",
  "#+end_src",
  "",
  "#+begin_src emacs-lisp :var x=tbl :colnames no :hlines yes",
  "x",
  "#+end_src",
  "",
  "#+begin_src emacs-lisp :var x=tbl",
  "x",
  "#+end_src",
  "",
  "#+begin_src emacs-lisp :lexical t",
  "(let ((f (let ((n 5)) (lambda () n)))) (funcall f))",
  "#+end_src",
  "",
  "#+begin_src emacs-lisp :results pp",
  "'(a (b c) \"d\")",
  "#+end_src",
  "",
  "#+begin_src emacs-lisp :var n=3 :prologue \"(setq n (* n 2))\"",
  "(* n 10)",
  "#+end_src",
  "",
  "#+begin_src emacs-lisp",
  "(mapcar (lambda (i) (list i (* i i))) (number-sequence 1 3))",
  "#+end_src",
  "",
  "#+begin_src emacs-lisp :results table",
  "42",
  "#+end_src",
  "",
  "#+begin_src emacs-lisp",
  "(format \"%s-%d\" \"x\" 7)",
  "#+end_src",
}
local EXPECTED = {
  "#+begin_src emacs-lisp",
  "(+ 1 2)",
  "#+end_src",
  "",
  "#+RESULTS:",
  ": 3",
  "",
  "#+begin_src emacs-lisp",
  "'((1 2) (3 4))",
  "#+end_src",
  "",
  "#+RESULTS:",
  "| 1 | 2 |",
  "| 3 | 4 |",
  "",
  "#+begin_src elisp",
  "(list \"a\" 'b 2.5)",
  "#+end_src",
  "",
  "#+RESULTS:",
  "| a | b | 2.5 |",
  "",
  "#+begin_src emacs-lisp :results output",
  "(princ \"hello\\n\")",
  "(print '(1 \"x\"))",
  "#+end_src",
  "",
  "#+RESULTS:",
  ": hello",
  ": ",
  ": (1 \"x\")",
  "",
  "#+begin_src emacs-lisp :results verbatim",
  "\"quoted\"",
  "#+end_src",
  "",
  "#+RESULTS:",
  ": \"quoted\"",
  "",
  "#+begin_src emacs-lisp",
  "\"plain\"",
  "#+end_src",
  "",
  "#+RESULTS:",
  ": plain",
  "",
  "#+begin_src emacs-lisp",
  "nil",
  "#+end_src",
  "",
  "#+RESULTS:",
  "",
  "#+NAME: tbl",
  "| a | b |",
  "|---+---|",
  "| 1 | 2 |",
  "| 3 | 4 |",
  "",
  "#+begin_src emacs-lisp :var x=tbl",
  "(mapcar (lambda (r) (apply #'+ r)) x)",
  "#+end_src",
  "",
  "#+RESULTS:",
  "| 3 | 7 |",
  "",
  "#+begin_src emacs-lisp :var x=tbl :colnames no :hlines yes",
  "x",
  "#+end_src",
  "",
  "#+RESULTS:",
  "| a | b |",
  "|---+---|",
  "| 1 | 2 |",
  "| 3 | 4 |",
  "",
  "#+begin_src emacs-lisp :var x=tbl",
  "x",
  "#+end_src",
  "",
  "#+RESULTS:",
  "| 1 | 2 |",
  "| 3 | 4 |",
  "",
  "#+begin_src emacs-lisp :lexical t",
  "(let ((f (let ((n 5)) (lambda () n)))) (funcall f))",
  "#+end_src",
  "",
  "#+RESULTS:",
  ": 5",
  "",
  "#+begin_src emacs-lisp :results pp",
  "'(a (b c) \"d\")",
  "#+end_src",
  "",
  "#+RESULTS:",
  ": (a (b c) \"d\")",
  "",
  "#+begin_src emacs-lisp :var n=3 :prologue \"(setq n (* n 2))\"",
  "(* n 10)",
  "#+end_src",
  "",
  "#+RESULTS:",
  ": 60",
  "",
  "#+begin_src emacs-lisp",
  "(mapcar (lambda (i) (list i (* i i))) (number-sequence 1 3))",
  "#+end_src",
  "",
  "#+RESULTS:",
  "| 1 | 1 |",
  "| 2 | 4 |",
  "| 3 | 9 |",
  "",
  "#+begin_src emacs-lisp :results table",
  "42",
  "#+end_src",
  "",
  "#+RESULTS:",
  "| 42 |",
  "",
  "#+begin_src emacs-lisp",
  "(format \"%s-%d\" \"x\" 7)",
  "#+end_src",
  "",
  "#+RESULTS:",
  ": x-7",
}

local function stub(tbl_, key, fn)
  local orig = tbl_[key]
  tbl_[key] = fn
  return function()
    tbl_[key] = orig
  end
end

describe("emacs-lisp blocks", function()
  local saved
  before_each(function()
    saved = vim.deepcopy(config.opts.babel.emacs_lisp)
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(function()
    config.opts.babel.emacs_lisp = saved
    config.opts.babel.confirm_evaluate = true
  end)

  local function run_all()
    local buf = org_buffer(INPUT, { 1, 0 })
    babel.execute_buffer({ bufnr = buf, skip_confirm = true, sync = true })
    return buf_lines(buf)
  end

  it("run in an external Emacs like ob-emacs-lisp", function()
    if not has_emacs() then
      return -- no emacs executable: nothing to compare
    end
    eq(EXPECTED, run_all())
  end)

  it("run side-effect-free code without Emacs", function()
    config.opts.babel.emacs_lisp.command = false
    eq(nil, elisp.command())
    eq(EXPECTED, run_all())
  end)

  it("uses the Emacs of babel.emacs_lisp.command", function()
    config.opts.babel.emacs_lisp.command = "/nonexistent/emacs"
    eq(nil, elisp.command())
    if has_emacs() then
      config.opts.babel.emacs_lisp.command = "emacs"
      eq({ "emacs", "-Q", "--batch" }, elisp.command())
      config.opts.babel.emacs_lisp.args = { "--batch" }
      eq({ "emacs", "--batch" }, elisp.command())
    end
  end)

  it("expands the body like org-babel-expand-body:emacs-lisp", function()
    local args = { results_spec = { collection = "value" } }
    eq("(+ 1 2)\n", elisp.expand_body({ "(+ 1 2)" }, args, {}))
    local vars = { { name = "x", value = { { 1, 2 }, "hline", { 3, "a" } } }, { name = "y", value = 4 } }
    eq("(let ((x '((1 2) hline (3 \"a\")))\n      (y '4))\n(+ y 1)\n)", elisp.expand_body({ "(+ y 1)" }, args, vars))
  end)

  it("reports Lisp errors", function()
    if not has_emacs() then
      return
    end
    local buf = org_buffer({ "#+begin_src emacs-lisp", "(car 1)", "#+end_src" }, { 1, 0 })
    local notified
    local restore = stub(babel, "error_notify", function(_, msg)
      notified = msg
    end)
    babel.execute_buffer({ bufnr = buf, skip_confirm = true, sync = true })
    restore()
    ok(notified and notified:find("Wrong type argument: listp, 1", 1, true), tostring(notified))
    eq({ "#+begin_src emacs-lisp", "(car 1)", "#+end_src" }, buf_lines(buf))
  end)
end)

describe("elisp: links", function()
  local saved
  before_each(function()
    saved = { vim.deepcopy(config.opts.links), vim.deepcopy(config.opts.babel.emacs_lisp) }
  end)
  after_each(function()
    config.opts.links = saved[1]
    config.opts.babel.emacs_lisp = saved[2]
  end)

  it("ask before running and abort on no", function()
    local asked
    config.opts.links.confirm_elisp = function(sexp)
      asked = sexp
      return false
    end
    org_buffer({ "" }, { 1, 0 })
    eq(false, links.open("elisp:(+ 1 2)"))
    eq("(+ 1 2)", asked)
  end)

  it("show the value of the sexp", function()
    config.opts.links.confirm_elisp = false
    local msgs = {}
    local restore = stub(utils, "notify", function(m)
      msgs[#msgs + 1] = m
    end)
    org_buffer({ "" }, { 1, 0 })
    config.opts.babel.emacs_lisp.command = false
    local r1 = links.open("elisp:(concat \"a\" \"b\")")
    local r2
    if has_emacs() then
      config.opts.babel.emacs_lisp.command = "emacs"
      r2 = links.open("elisp:(emacs-version)")
    end
    restore()
    eq(true, r1)
    eq('(concat "a" "b") => "ab"', msgs[1])
    if has_emacs() then
      eq(true, r2)
      ok(msgs[2]:match('^%(emacs%-version%) => "GNU Emacs'), msgs[2])
    end
  end)

  it("skip the confirmation for matching sexps", function()
    config.opts.links.confirm_elisp = function()
      error("should not ask")
    end
    config.opts.links.elisp_skip_confirm_regexp = "^(+ "
    config.opts.babel.emacs_lisp.command = false
    local restore = stub(utils, "notify", function() end)
    org_buffer({ "" }, { 1, 0 })
    local r = links.open("elisp:(+ 1 2)")
    restore()
    eq(true, r)
  end)
end)

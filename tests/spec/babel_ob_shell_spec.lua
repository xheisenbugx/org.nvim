-- ob-shell options org-babel-shell-names and
-- org-babel-shell-results-defaults-to-output, checked against Emacs Org
-- 9.8.10 (`emacs --batch`, org-babel-execute-buffer).
local config = require("org.config")
local h = require("tests.helpers.babel_ob")

describe("babel ob-shell options", function()
  local saved
  before_each(function()
    config.opts.babel.confirm_evaluate = false
    saved = { config.opts.babel.shell_results_defaults_to_output, config.opts.babel.shell_names }
  end)
  after_each(function()
    config.opts.babel.shell_results_defaults_to_output, config.opts.babel.shell_names = saved[1], saved[2]
  end)

  it("shell_results_defaults_to_output = false: a plain block gives its exit status", function()
    config.opts.babel.shell_results_defaults_to_output = false
    -- Emacs 9.8.10 with org-babel-shell-results-defaults-to-output nil
    eq({
      "#+begin_src sh",
      "echo hi",
      "false",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": 1",
      "",
      "#+begin_src sh :results table",
      "echo 1 2",
      "#+end_src",
      "",
      "#+RESULTS:",
      "| 1 2 |",
      "",
      "#+begin_src sh :results output",
      "echo hi",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": hi",
    }, h.run({
      "#+begin_src sh",
      "echo hi",
      "false",
      "#+end_src",
      "",
      "#+begin_src sh :results table",
      "echo 1 2",
      "#+end_src",
      "",
      "#+begin_src sh :results output",
      "echo hi",
      "#+end_src",
    }))
  end)

  it("the default gives the output", function()
    eq(": hi", h.run({ "#+begin_src sh", "echo hi", "false", "#+end_src" })[7])
  end)

  it("shell_names: more shells run as themselves", function()
    eq("shell", require("org.babel.langs").family("mksh"))
    config.opts.babel.shell_names = { "sh", "mysh" }
    eq("shell", require("org.babel.langs").family("mysh"))
    eq("generic", require("org.babel.langs").family("mksh"))
    local dir = h.tmpdir()
    h.fake(dir, "mysh", "echo mysh > " .. dir .. '/log; exec sh "$@"')
    local out
    h.with_path(dir, function()
      out = h.run({ "#+begin_src mysh :var x=5", "echo $x", "#+end_src" }, dir)
    end)
    eq({ "#+RESULTS:", ": 5" }, { out[5], out[6] })
    eq({ "mysh" }, vim.fn.readfile(dir .. "/log"))
  end)
end)

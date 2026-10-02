-- ob-ditaa, checked against Emacs Org 9.8.10 (`emacs --batch`,
-- org-babel-execute-buffer) with the same fake `ditaa` script (ditaa and
-- java are not installed) that logs its arguments.
local config = require("org.config")
local h = require("tests.helpers.babel_ob")
local tmpdir, fake, run, set_lang = h.tmpdir, h.fake, h.run, h.set_lang

describe("babel ob-ditaa", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(h.restore)

  it("writes NAME.png (:file-ext png), --svg for .svg, errors without a :file", function()
    local dir = tmpdir()
    local log = dir .. "/log"
    local exe = fake(dir, "fakeditaa", 'echo "ditaa $*" >> ' .. log)
    set_lang("ditaa", { exec_mode = "ditaa", exec = exe })
    -- Emacs: links for the first two blocks, ":file-ext given but no :file
    -- generated" for the third, a missing DitaaEps.jar for the pdf
    local out = run({
      "#+name: diag",
      "#+begin_src ditaa",
      "+--+",
      "#+end_src",
      "",
      "#+begin_src ditaa :file d.svg :cmdline -r",
      "+-+",
      "#+end_src",
      "",
      "#+begin_src ditaa",
      "+-+",
      "#+end_src",
      "",
      "#+begin_src ditaa :file d.pdf",
      "+-+",
      "#+end_src",
    }, dir)
    eq({
      "#+name: diag",
      "#+begin_src ditaa",
      "+--+",
      "#+end_src",
      "",
      "#+RESULTS: diag",
      "[[file:diag.png]]",
      "",
      "#+begin_src ditaa :file d.svg :cmdline -r",
      "+-+",
      "#+end_src",
      "",
      "#+RESULTS:",
      "[[file:d.svg]]",
      "",
      "#+begin_src ditaa",
      "+-+",
      "#+end_src",
      "",
      "#+begin_src ditaa :file d.pdf",
      "+-+",
      "#+end_src",
    }, out)
    local l = vim.fn.readfile(log)
    eq(2, #l)
    ok(l[1]:match("^ditaa %-e utf%-8 %S+ diag%.png$"))
    ok(l[2]:match("^ditaa %-r %-%-svg %-e utf%-8 %S+ d%.svg$"))
  end)

  it("runs java -jar (the default mode) and epstopdf for pdf", function()
    skip_on_windows("the fake tool runs behind cmd.exe, which re-quotes this command line")
    local dir = tmpdir()
    local log = dir .. "/log"
    fake(dir, "java", 'echo "java $*" >> ' .. log)
    fake(dir, "epstopdf", 'echo "epstopdf $*" >> ' .. log)
    vim.fn.writefile({}, dir .. "/ditaa.jar")
    vim.fn.writefile({}, dir .. "/DitaaEps.jar")
    set_lang("ditaa", { exec_mode = "jar", jar_path = dir .. "/ditaa.jar" })
    h.with_path(dir, function()
      run({
        "#+begin_src ditaa :file a.png :java -Dx=1",
        "+-+",
        "#+end_src",
        "",
        "#+begin_src ditaa :file b.pdf",
        "+-+",
        "#+end_src",
      }, dir)
    end)
    local l = vim.fn.readfile(log)
    ok(l[1]:match("^java %-Dx=1 %-jar " .. vim.pesc(dir) .. "/ditaa%.jar %-e utf%-8 %S+ a%.png$"))
    ok(l[2]:match("^java %-jar " .. vim.pesc(dir) .. "/DitaaEps%.jar %-e utf%-8 %S+ %S+%.eps$"))
    ok(l[3]:match("^epstopdf %S+%.eps %-o=b%.pdf$"))
  end)
end)

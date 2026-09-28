-- ob-plantuml, checked against Emacs Org 9.8.10: the expected lines come
-- from `emacs --batch` (org-babel-execute-buffer) with the same fake
-- `plantuml` script (plantuml is not installed), which prints its
-- arguments and copies its input.
local config = require("org.config")
local h = require("tests.helpers.babel_ob")
local tmpdir, fake, run, set_lang = h.tmpdir, h.fake, h.run, h.set_lang

describe("babel ob-plantuml", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(h.restore)

  it("runs the executable with -tTYPE -p and links the :file", function()
    local dir = tmpdir()
    local exe = fake(dir, "fakeplantuml", 'echo "ARGS: $*"\ncat')
    set_lang("plantuml", { exec_mode = "plantuml", executable_path = exe })
    local out = run({
      '#+begin_src plantuml :file out.png :var who="Bob"',
      "Alice -> who",
      "#+end_src",
      "",
      "#+begin_src plantuml :results verbatim",
      "@startsalt",
      "{ a }",
      "@endsalt",
      "#+end_src",
      "",
      "#+begin_src plantuml :results verbatim :cmdline -v",
      "A -> B",
      "#+end_src",
    }, dir)
    eq({
      '#+begin_src plantuml :file out.png :var who="Bob"',
      "Alice -> who",
      "#+end_src",
      "",
      "#+RESULTS:",
      "[[file:out.png]]",
      "",
      "#+begin_src plantuml :results verbatim",
      "@startsalt",
      "{ a }",
      "@endsalt",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": ARGS: -headless -ttxt -p",
      ": @startsalt",
      ": { a }",
      ": @endsalt",
      "",
      "#+begin_src plantuml :results verbatim :cmdline -v",
      "A -> B",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": ARGS: -headless -ttxt -p -v",
      ": @startuml",
      ": A -> B",
      ": @enduml",
    }, out)
    eq(
      { "ARGS: -headless -tpng -p", "@startuml", "!define who Bob", "Alice -> who", "@enduml" },
      vim.fn.readfile(dir .. "/out.png")
    )
  end)

  it("needs the jar in jar mode (the default)", function()
    set_lang("plantuml", { exec_mode = "jar", jar_path = "" })
    local out = run({ "#+begin_src plantuml :file x.png", "A -> B", "#+end_src" })
    eq({ "#+begin_src plantuml :file x.png", "A -> B", "#+end_src" }, out)
  end)

  it("runs java -jar with :java options and converts svg text with inkscape", function()
    local dir = tmpdir()
    local log = dir .. "/log"
    fake(dir, "java", 'echo "java $*" >> ' .. log .. "\ncat")
    fake(dir, "inkscape", 'echo "inkscape $*" >> ' .. log)
    vim.fn.writefile({}, dir .. "/plantuml.jar")
    set_lang("plantuml", { exec_mode = "jar", jar_path = dir .. "/plantuml.jar", svg_text_to_path = true })
    h.with_path(dir, function()
      run({ "#+begin_src plantuml :file d.svg :java -Xmx1g", "A -> B", "#+end_src" }, dir)
    end)
    local l = vim.fn.readfile(log)
    eq("java -Xmx1g -jar " .. dir .. "/plantuml.jar -headless -tsvg -p", l[1])
    eq("inkscape d.svg -T -l d.svg", l[2])
  end)
end)

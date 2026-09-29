-- ob-processing and ob-screen. The Processing HTML result was checked
-- against Emacs Org 9.8.10 (`emacs --batch`, org-babel-execute-buffer).
-- processing-java is not installed (a fake records its arguments); screen
-- is used when installed, started detached by a fake terminal.
local config = require("org.config")
local h = require("tests.helpers.babel_ob")

describe("babel ob-processing", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(h.restore)

  it("gives HTML running the sketch with processing.js", function()
    local out = h.run({
      "#+begin_src processing :var n=3 f=1.5 s=\"hi\" l='(1 2.5) m='((1 2) (3 4)) w='(\"a\" \"b\")",
      "size(100, 100);",
      "#+end_src",
    })
    -- Emacs 9.8.10
    eq({
      "#+begin_src processing :var n=3 f=1.5 s=\"hi\" l='(1 2.5) m='((1 2) (3 4)) w='(\"a\" \"b\")",
      "size(100, 100);",
      "#+end_src",
      "",
      "#+RESULTS:",
      "#+begin_export html",
      '<script src="processing.js"></script>',
      ' <script type="text/processing" data-processing-target="ob-e34e9fd0a67e7c943722cba64f8a47d817bd0c58">',
      "int n=3;",
      "float f=1.5;",
      'String s="hi";',
      "float[] l={1, 2.5};",
      "int[][] m={{1, 2},{3, 4}};",
      'String[] w={"a", "b"};',
      "size(100, 100);",
      '</script> <canvas id="ob-e34e9fd0a67e7c943722cba64f8a47d817bd0c58"></canvas>',
      "#+end_export",
    }, out)
  end)

  it("runs the sketch with processing-java (view sketch)", function()
    local dir = h.tmpdir()
    local log = dir .. "/log"
    h.set_lang("processing", { cmd = h.fake(dir, "pj", 'echo "$*" > ' .. log) })
    org_buffer({ "#+begin_src processing :var n=2", "size(n, n);", "#+end_src" }, { 2, 0 })
    local sketch = require("org.babel.lang.processing").view_sketch()
    local name = vim.fn.fnamemodify(sketch, ":t:r")
    ok(not name:find("-", 1, true))
    eq(name, vim.fn.fnamemodify(sketch, ":h:t"))
    eq({ "int n=2;", "size(n, n);" }, vim.fn.readfile(sketch))
    vim.wait(2000, function()
      return vim.fn.filereadable(log) == 1
    end)
    local dirname = vim.fn.fnamemodify(sketch, ":h")
    eq({ "--force --sketch=" .. dirname .. " --output=" .. dirname .. "/output --run" }, vim.fn.readfile(log))
    org_buffer({ "#+begin_src python", "1", "#+end_src" }, { 2, 0 })
    eq(nil, require("org.babel.lang.processing").view_sketch())
  end)
end)

describe("babel ob-screen", function()
  local session
  before_each(function()
    config.opts.babel.confirm_evaluate = false
    session = "orgtest" .. string.format("%d", vim.uv.hrtime()):sub(-6)
    -- a session that no terminal ever attached needs a window (-p 0) for
    -- -X commands: `location` is a screen that adds it
    local dir = h.tmpdir()
    local wrapper = h.fake(
      dir,
      "myscreen",
      'if [ "$1" = "-S" ]; then s=$2; shift 2; exec screen -S "$s" -p 0 "$@"; else exec screen "$@"; fi'
    )
    h.set_lang("screen", { location = wrapper })
  end)
  after_each(function()
    local screen = require("org.babel.lang.screen")
    local sock = screen.socketname(session)
    if sock then
      vim.system({ "screen", "-S", sock, "-X", "quit" }):wait()
    end
    h.restore()
  end)

  it("starts the session in the terminal and pastes the block into it", function()
    if vim.fn.executable("screen") == 0 then
      return
    end
    local dir = h.tmpdir()
    -- a terminal: `-T title -e screen -c rc -mS session cmd`, run detached
    local term = h.fake(
      dir,
      "term",
      'echo "$*" > ' .. dir .. '/term.log\nshift 3\nexe=$1; shift\n"$exe" -c "$2" -dmS "$4" "$5"'
    )
    local out = h.run({
      "#+begin_src screen :session " .. session .. " :terminal " .. term,
      "echo pasted > " .. dir .. "/out",
      "#+end_src",
    }, dir)
    -- :results silent
    eq(3, #out)
    local l = vim.fn.readfile(dir .. "/term.log")
    ok(l[1]:match("^%-T org%-babel: " .. session .. " %-e %S+myscreen %-c /dev/null %-mS " .. session .. " sh$"))
    ok(vim.wait(5000, function()
      return vim.fn.filereadable(dir .. "/out") == 1
    end))
    eq({ "pasted" }, vim.fn.readfile(dir .. "/out"))
  end)

  it("tests the setup (org-babel-screen-test)", function()
    if vim.fn.executable("screen") == 0 then
      return
    end
    local dir = h.tmpdir()
    local term = h.fake(dir, "term", 'shift 3\nexe=$1; shift\n"$exe" -c "$2" -dmS "$4" "$5"')
    h.set_lang("screen", { default_header_args = { terminal = term, session = session } })
    eq(true, require("org.babel.lang.screen").test())
  end)
end)

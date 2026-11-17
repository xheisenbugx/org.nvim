-- `:session` for the ports of ob-LANG.el with a REPL: julia (ESS in
-- Emacs), ocaml (tuareg) and scheme (Geiser). julia and the OCaml
-- toplevel are replaced by fakes that answer the way they do; scheme runs
-- real guile when it is installed.
local babel = require("org.babel")
local session = require("org.babel.session")
local config = require("org.config")
local h = require("tests.helpers.babel_ob")

local function has(exe)
  return vim.fn.executable(exe) == 1
end

--- Execute every block of `lines` from top to bottom (sessions depend on
--- the order) and return the buffer.
local function run_all(lines)
  local buf = org_buffer(lines, { 1, 0 })
  local i = 0
  while true do
    i = i + 1
    local b = babel.parse_blocks(buf_lines(buf))[i]
    if not b then
      return buf
    end
    local finished = false
    babel.execute({
      bufnr = buf,
      lnum = b.start,
      on_done = function()
        finished = true
      end,
    })
    ok(
      vim.wait(10000, function()
        return finished
      end, 20),
      "block at line " .. b.start .. " did not finish"
    )
  end
end

--- The lines of the `#+RESULTS:` of each block.
local function results_of(buf)
  local out, cur = {}, nil
  for _, l in ipairs(buf_lines(buf)) do
    if l == "#+RESULTS:" then
      cur = {}
      out[#out + 1] = cur
    elseif cur and (l == "" or l:match("^#%+begin")) then
      cur = nil
    elseif cur then
      cur[#cur + 1] = l
    end
  end
  return out
end

local function term_text(sess)
  return table.concat(vim.api.nvim_buf_get_lines(sess.buf, 0, -1, false), "\n")
end

--- Whether the terminal of `sess` shows `text`, waiting for it: Neovim
--- copies a terminal's output into its buffer on a deferred refresh, so a
--- read right after the last block can find only the rows of its screen.
local function term_shows(sess, text)
  return vim.wait(5000, function()
    return term_text(sess):find(text, 1, true) ~= nil
  end, 20)
end

-- A julia REPL: `-L setup.jl` defines __org_babel_run, which the fake
-- stands for: it shows the code (`.echo`), runs `.src` (Julia's syntax of
-- these blocks is Python's) and writes a value block's CSV file.
local FAKE_JULIA = [[#!/usr/bin/env python3
import os, re, sys
args = sys.argv[1:]
with open(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "julia.log"), "a") as f:
    f.write(" ".join(args) + "\n")
assert "__org_babel_run" in open(args[args.index("-L") + 1]).read()
def fail(msg):
    raise Exception(msg)
g = {"println": lambda *a: print("".join(str(x) for x in a)), "error": fail}
def run(code):
    lines = [l.strip() for l in code.split("\n") if l.strip()]
    last = None
    for l in lines:
        a = re.match(r"^(\w+)\s*=[^=]", l)
        if a:
            exec(l, g)
            last = g[a.group(1)]  # an assignment's value is the value assigned
        else:
            last = eval(l, g)
    return last
d = os.environ["ORG_BABEL_SESSION_DIR"]
while True:
    sys.stdout.write("julia> ")
    sys.stdout.flush()
    line = sys.stdin.readline()
    if not line:
        break
    m = re.match(r"__org_babel_run\((\d+)\)$", line.replace("\x15", "").strip())
    if not m:
        continue
    rid = m.group(1)
    base = os.path.join(d, rid)
    if os.path.exists(base + ".echo"):
        print(open(base + ".echo").read())
    print("__ORG_BABEL_BOS__ " + rid)
    sys.stdout.flush()
    src = open(base + ".src").read()
    status = 0
    try:
        w = re.search(r'local p_ans = begin (.*) end\n    local p_tmp_file = "([^"]*)"', src, re.S)
        if w:
            v = run(w.group(1))
            with open(w.group(2), "w") as f:
                rows = v if isinstance(v, list) else [v]
                for r in rows:
                    f.write(",".join(str(c) for c in (r if isinstance(r, list) else [r])) + "\n")
        else:
            run(src)
    except Exception as e:
        status = 1
        print(str(e))
        open(base + ".err", "w").write(str(e))
    print("\n__ORG_BABEL_EOE__ %s %d" % (rid, status))
    sys.stdout.flush()
]]

-- The OCaml toplevel: `-init` defines the marker helpers, `#use` prints
-- the answer to each phrase of the file.
local FAKE_OCAML = [[#!/usr/bin/env python3
import os, re, sys
args = sys.argv[1:]
with open(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "ocaml.log"), "a") as f:
    f.write(" ".join(args) + "\n")
assert "__org_babel_bos" in open(args[args.index("-init") + 1]).read()
g = {}
def py(e):
    return e.replace("[|", "[").replace("|]", "]").replace(";", ",").replace("^", "+")
def typ(v):
    if isinstance(v, list):
        return "int array"
    return {int: "int", float: "float", str: "string"}[type(v)]
def show(v):
    if isinstance(v, list):
        return "[|" + "; ".join(show(x) for x in v) + "|]"
    if isinstance(v, str):
        return '"' + v + '"'
    return str(v)
def use(path):
    for phrase in open(path).read().split(";;"):
        p = phrase.strip()
        if not p:
            continue
        m = re.match(r"let (\w+) = (.*)$", p, re.S)
        try:
            if m:
                v = eval(py(m.group(2)), g)
                g[m.group(1)] = v
                print("val %s : %s = %s" % (m.group(1), typ(v), show(v)))
            else:
                v = eval(py(p), g)
                print("- : %s = %s" % (typ(v), show(v)))
        except NameError as e:
            print("Error: Unbound value " + str(e).split("'")[1])
            return
d = os.environ["ORG_BABEL_SESSION_DIR"]
while True:
    sys.stdout.write("# ")
    sys.stdout.flush()
    line = sys.stdin.readline()
    if not line:
        break
    line = line.replace("\x15", "").strip()
    m = re.match(r"let \(\) = __org_babel_bos (\d+);;$", line)
    if m:
        base = os.path.join(d, m.group(1))
        if os.path.exists(base + ".echo"):
            print(open(base + ".echo").read())
        print("__ORG_BABEL_BOS__ " + m.group(1))
    m = re.match(r'#use "(.*)";;$', line)
    if m:
        use(m.group(1))
    m = re.match(r"let \(\) = __org_babel_eoe (\d+);;$", line)
    if m:
        print("\n__ORG_BABEL_EOE__ %s 0" % m.group(1))
    sys.stdout.flush()
]]

describe("babel :session for julia, ocaml and scheme", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
    session.kill_all()
  end)
  after_each(function()
    session.kill_all()
    h.restore()
  end)

  it("knows these languages have sessions, each its own family", function()
    eq("julia", session.family("julia"))
    eq("ocaml", session.family("ocaml"))
    eq("scheme", session.family("scheme"))
    ok(session.supported("julia", session.family("julia")))
    ok(session.supported("ocaml", session.family("ocaml")))
    ok(session.supported("scheme", session.family("scheme")))
    -- the default sessions are named like Emacs' REPL buffers
    eq("*julia*", session.buffer_name("julia", "default"))
    eq("*OCaml*", session.buffer_name("ocaml", "default"))
    eq("*scheme*", session.buffer_name("scheme", "default"))
    -- other ports still read :session themselves, or have none
    eq("generic", session.family("groovy"))
    ok(not session.supported("groovy", session.family("groovy")))
  end)

  it("julia: globals persist, values and output, :var, errors", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if not has("python3") then
      return
    end
    local dir = h.tmpdir()
    h.set_lang("julia", { cmd = h.fake(dir, "julia", FAKE_JULIA) })
    local buf = run_all({
      "#+begin_src julia :session",
      "x = 20",
      "#+end_src",
      "",
      "#+begin_src julia :session",
      "y = x + 1",
      "y * 2",
      "#+end_src",
      "",
      "#+begin_src julia :session :results output",
      'println("hello ", x)',
      "#+end_src",
      "",
      "#+begin_src julia :session :var n=3",
      "n * x",
      "#+end_src",
      "",
      "#+begin_src julia :session",
      'error("boom")',
      "#+end_src",
      "",
      "#+begin_src julia :session",
      "[[1, 2], [3, x]]",
      "#+end_src",
    })
    eq({ { ": 20" }, { ": 42" }, { ": hello 20" }, { ": 60" }, {}, { "| 1 |  2 |", "| 3 | 20 |" } }, results_of(buf))
    local eb = vim.fn.bufnr("*Org-Babel Error Output*")
    ok(eb > 0 and table.concat(vim.api.nvim_buf_get_lines(eb, 0, -1, false), "\n"):find("boom"))
    -- one REPL, started once with the start-up file, named like ESS
    local log = vim.fn.readfile(dir .. "/julia.log")
    eq(1, #log)
    ok(log[1]:match("^%-i %-%-banner=no %-%-color=no %-%-history%-file=no %-L %S+setup%.jl$"), log[1])
    local sess = session.find("julia", "default")
    eq("*julia*", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(sess.buf), ":t"))
    -- the REPL shows the code of each block
    ok(term_shows(sess, 'println("hello ", x)'), term_text(sess))
  end)

  it("julia: session_cmd is the REPL command; named sessions are separate", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if not has("python3") then
      return
    end
    local dir = h.tmpdir()
    h.set_lang("julia", { session_cmd = h.fake(dir, "julia", FAKE_JULIA) .. " --threads=2" })
    local buf = run_all({
      "#+begin_src julia :session a",
      "z = 1",
      "#+end_src",
      "",
      "#+begin_src julia :session b",
      "z = 2",
      "#+end_src",
      "",
      "#+begin_src julia :session a",
      "z",
      "#+end_src",
    })
    eq({ { ": 1" }, { ": 2" }, { ": 1" } }, results_of(buf))
    local log = vim.fn.readfile(dir .. "/julia.log")
    eq(2, #log)
    ok(log[1]:match("^%-%-threads=2 %-L %S+setup%.jl$"), log[1])
    ok(session.find("julia", "a") and session.find("julia", "b"))
  end)

  it("ocaml: the toplevel keeps its bindings; answers are parsed by type", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if not has("python3") then
      return
    end
    local dir = h.tmpdir()
    h.set_lang("ocaml", { cmd = h.fake(dir, "ocaml", FAKE_OCAML) })
    local buf = run_all({
      "#+begin_src ocaml :session",
      "let x = 20",
      "#+end_src",
      "",
      "#+begin_src ocaml :session",
      "let y = x + 22",
      "#+end_src",
      "",
      '#+begin_src ocaml :session :var s="ab"',
      's ^ "c"',
      "#+end_src",
      "",
      "#+begin_src ocaml :session",
      "[|x; y|]",
      "#+end_src",
      "",
      "#+begin_src ocaml :session :results verbatim",
      "let z = 1;;",
      "z + x",
      "#+end_src",
      "",
      "#+begin_src ocaml :session",
      "nope + 1",
      "#+end_src",
    })
    eq({
      { ": 20" },
      { ": 42" },
      { ": abc" },
      { "| 20 | 42 |" },
      { ": val z : int = 1", ": - : int = 21" },
      { ": Error: Unbound value nope" },
    }, results_of(buf))
    local log = vim.fn.readfile(dir .. "/ocaml.log")
    eq(1, #log)
    ok(log[1]:match("^%-init %S+init%.ml$"), log[1])
    local sess = session.find("ocaml", "default")
    eq("*OCaml*", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(sess.buf), ":t"))
    ok(term_shows(sess, "let y = x + 22"), term_text(sess))
  end)

  it("kills a session at the block; the next block starts a new one", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if not has("python3") then
      return
    end
    local dir = h.tmpdir()
    h.set_lang("ocaml", { cmd = h.fake(dir, "ocaml", FAKE_OCAML) })
    local buf = run_all({
      "#+begin_src ocaml :session k",
      "let x = 5",
      "#+end_src",
    })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    ok(babel.kill_session())
    eq(nil, session.find("ocaml", "k"))
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "#+begin_src ocaml :session k", "x", "#+end_src" })
    babel.execute({ bufnr = buf, lnum = 8, sync = true })
    eq({ { ": 5" }, { ": Error: Unbound value x" } }, results_of(buf))
    eq(2, #vim.fn.readfile(dir .. "/ocaml.log"))
  end)

  it("scheme (guile): definitions persist, value, output, tables, errors", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if not has("guile") then
      return
    end
    local buf = run_all({
      "#+begin_src scheme :session",
      "(define x 20)",
      "(define (twice n) (* n 2))",
      "#+end_src",
      "",
      "#+begin_src scheme :session",
      '(display "ignored")',
      "(+ (twice x) 2)",
      "#+end_src",
      "",
      "#+begin_src scheme :session :results output",
      "(display (twice x))",
      "#+end_src",
      "",
      "#+begin_src scheme :session",
      "(car '())",
      "#+end_src",
      "",
      "#+begin_src scheme :session :var y=5",
      "(list x y)",
      "#+end_src",
    })
    local res = results_of(buf)
    eq({ ": 42" }, res[2])
    eq({ ": 40" }, res[3])
    eq({}, res[4])
    eq({ "| 20 | 5 |" }, res[5])
    local eb = vim.fn.bufnr("*Org-Babel Error Output*")
    ok(eb > 0 and table.concat(vim.api.nvim_buf_get_lines(eb, 0, -1, false), "\n"):find("car"))
    local sess = session.find("scheme", "default")
    eq("*scheme*", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(sess.buf), ":t"))
    ok(term_shows(sess, "(display (twice x))"), term_text(sess))
  end)

  it("scheme: a session program evaluates each form and writes the value", function()
    local prog = require("org.babel.lang.scheme").session_program("guile", "/s/7", "/s/7.src", "value", "(+ 1 2)")
    ok(prog:find('(display "(+ 1 2)")', 1, true), prog)
    ok(prog:find('(display "__ORG_BABEL_BOS__ 7")', 1, true), prog)
    ok(prog:find('(open-input-file "/s/7.src")', 1, true), prog)
    ok(prog:find('(call-with-output-file "/s/7.val"', 1, true), prog)
    ok(prog:find("print-exception", 1, true), prog)
    -- output mode writes no value
    local out = require("org.babel.lang.scheme").session_program("chibi", "/s/8", "/s/8.src", "output")
    ok(not out:find(".val", 1, true), out)
    ok(not out:find("print-exception", 1, true), out)
  end)
end)

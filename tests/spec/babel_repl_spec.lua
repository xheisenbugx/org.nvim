-- :session blocks run in a real REPL (a terminal buffer) like Emacs' comint
-- sessions: state persists between blocks and input typed in the REPL.
local babel = require("org.babel")
local session = require("org.babel.session")
local config = require("org.config")

local function has(exe)
  return vim.fn.executable(exe) == 1
end

--- Execute the blocks of `lines` from top to bottom and return the buffer.
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
      vim.wait(15000, function()
        return finished
      end, 20),
      "block at line " .. b.start .. " did not finish"
    )
  end
end

--- Evaluate one block in `buf` at `lnum` and wait for it.
local function run_at(buf, lnum)
  local finished = false
  babel.execute({
    bufnr = buf,
    lnum = lnum,
    on_done = function()
      finished = true
    end,
  })
  ok(
    vim.wait(15000, function()
      return finished
    end, 20),
    "block at line " .. lnum .. " did not finish"
  )
end

--- Type `text` into the REPL of `sess` and wait until its terminal shows
--- `expect`.
local function type_in(sess, text, expect)
  vim.fn.chansend(sess.job, text .. "\n")
  ok(
    vim.wait(10000, function()
      return table.concat(vim.api.nvim_buf_get_lines(sess.buf, 0, -1, false), "\n"):find(expect, 1, true) ~= nil
    end, 20),
    table.concat(vim.api.nvim_buf_get_lines(sess.buf, 0, -1, false), "\n")
  )
end

local function bufname(sess)
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(sess.buf), ":t")
end

local function after(l, header)
  for i, line in ipairs(l) do
    if line == header then
      return l[i + 4]
    end
  end
end

describe("babel :session REPLs", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
    session.kill_all()
  end)
  after_each(function()
    session.kill_all()
  end)

  it("shell: a live shell keeps cwd, variables and functions; output and value", function()
    if not has("bash") then
      return
    end
    local dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir .. "/a/b", "p")
    local buf = run_all({
      "#+begin_src bash :session :dir " .. dir,
      "cd a",
      "count=1",
      'greet() { echo "hello $1"; }',
      "#+end_src",
      "",
      "#+begin_src bash :session",
      "cd b",
      "count=$((count + 1))",
      "#+end_src",
      "",
      "#+begin_src bash :session :results output",
      'greet "$(basename "$PWD")" $count',
      'echo "count=$count"',
      "#+end_src",
      "",
      "#+begin_src bash :session :results value",
      "test -d /nonexistent",
      "#+end_src",
    })
    local l = buf_lines(buf)
    ok(vim.tbl_contains(l, ": hello b"), vim.inspect(l))
    ok(vim.tbl_contains(l, ": count=2"), vim.inspect(l))
    eq(": 1", l[#l], vim.inspect(l))
    local sess = session.find("shell", "default")
    eq("terminal", vim.bo[sess.buf].buftype)
    eq("*shell*", bufname(sess))
  end)

  it("shell: commands typed in the REPL buffer share the session", function()
    if not has("bash") then
      return
    end
    local buf = run_all({ "#+begin_src bash :session typed", "X=from-block", "#+end_src" })
    local sess = session.find("shell", "typed")
    type_in(sess, "Y=typed-$X; echo got-$Y", "got-typed-from-block")
    -- a half-typed line at the prompt does not break the next evaluation
    vim.fn.chansend(sess.job, "half-typed")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "#+begin_src bash :session typed", "echo $Y", "#+end_src" })
    run_at(buf, #buf_lines(buf) - 1)
    ok(vim.tbl_contains(buf_lines(buf), ": typed-from-block"), vim.inspect(buf_lines(buf)))
  end)

  it("zsh sessions persist too", function()
    if not has("zsh") then
      return
    end
    local buf = run_all({
      "#+begin_src zsh :session z",
      "typeset -A h; h[k]=v",
      "#+end_src",
      "",
      "#+begin_src zsh :session z",
      "echo ${h[k]}$((6 * 7))",
      "#+end_src",
    })
    ok(vim.tbl_contains(buf_lines(buf), ": v42"), vim.inspect(buf_lines(buf)))
  end)

  it("python: definitions, imports and typed input persist; value and output", function()
    if not has("python3") then
      return
    end
    local buf = run_all({
      "#+begin_src python :session",
      "import json",
      "def double(v):",
      "    return v * 2",
      "#+end_src",
      "",
      "#+begin_src python :session :results output",
      "print(json.dumps({'a': double(2)}))",
      "for i in range(2):",
      "    print('line', i)",
      "#+end_src",
      "",
      "#+begin_src python :session",
      "double(21)",
      "#+end_src",
    })
    local l = buf_lines(buf)
    ok(vim.tbl_contains(l, ': {"a": 4}'), vim.inspect(l))
    ok(vim.tbl_contains(l, ": line 1"), vim.inspect(l))
    eq(": 42", l[#l], vim.inspect(l))
    local sess = session.find("python", "default")
    eq("*Python*", bufname(sess))
    -- `:session *Python*` names the same buffer, so the same session
    eq(sess, session.find("python", "*Python*"))
    -- what is typed at the REPL prompt is seen by the next block
    type_in(sess, "typed = double(50)", ">>> ")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "#+begin_src python :session *Python*", "typed", "#+end_src" })
    run_at(buf, #buf_lines(buf) - 1)
    eq(": 100", buf_lines(buf)[#buf_lines(buf)], vim.inspect(buf_lines(buf)))
  end)

  it("python: killing the session stops the REPL; the next block starts afresh", function()
    if not has("python3") then
      return
    end
    local buf = run_all({ "#+begin_src python :session k", "gone = 1", "#+end_src" })
    local sess = session.find("python", "k")
    local tbuf, job = sess.buf, sess.job
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    ok(babel.kill_session())
    eq(nil, session.find("python", "k"))
    ok(not vim.api.nvim_buf_is_valid(tbuf))
    ok(vim.wait(5000, function()
      return vim.fn.jobwait({ job }, 0)[1] ~= -1
    end, 20))
    local more = { "", "#+begin_src python :session k", "'gone' in globals()", "#+end_src" }
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, more)
    run_at(buf, #buf_lines(buf) - 1)
    eq(": False", buf_lines(buf)[#buf_lines(buf)], vim.inspect(buf_lines(buf)))
  end)

  it("python: exiting the interpreter ends the session", function()
    if not has("python3") then
      return
    end
    local buf = run_all({
      "#+begin_src python :session ex",
      "v = 1",
      "#+end_src",
      "",
      "#+begin_src python :session ex :results output",
      "print('bye')",
      "raise SystemExit(0)",
      "#+end_src",
    })
    ok(vim.tbl_contains(buf_lines(buf), ": bye"), vim.inspect(buf_lines(buf)))
    ok(vim.wait(5000, function()
      return session.find("python", "ex") == nil
    end, 20))
    local more = { "", "#+begin_src python :session ex", "'v' in globals()", "#+end_src" }
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, more)
    run_at(buf, #buf_lines(buf) - 1)
    eq(": False", buf_lines(buf)[#buf_lines(buf)], vim.inspect(buf_lines(buf)))
  end)

  it("python: load in session runs the body in the REPL and shows it", function()
    if not has("python3") then
      return
    end
    local buf = org_buffer({ "#+begin_src python :session ld", "loaded = 'yes'", "#+end_src" }, { 2, 0 })
    babel.load_in_session()
    local tbuf = vim.api.nvim_get_current_buf()
    eq("terminal", vim.bo[tbuf].buftype)
    local sess = session.find("python", "ld")
    eq("yes", vim.trim(session.eval_sync(sess, "loaded", "value", { timeout = 5000 }).value))
    vim.cmd("close")
    vim.api.nvim_set_current_buf(buf)
  end)

  it("python: :async session results replace their placeholder", function()
    if not has("python3") then
      return
    end
    local buf = org_buffer({
      "#+begin_src python :session as :async yes :results output",
      "import time; time.sleep(0.2); print('late')",
      "#+end_src",
    }, { 1, 0 })
    local finished
    babel.execute({
      bufnr = buf,
      lnum = 1,
      on_done = function(s)
        finished = s
      end,
    })
    ok(buf_lines(buf)[6]:match("^: %x+%-"), vim.inspect(buf_lines(buf)))
    ok(vim.wait(10000, function()
      return finished ~= nil
    end, 20))
    eq(": late", buf_lines(buf)[6], vim.inspect(buf_lines(buf)))
  end)

  it("ruby: irb locals are shared between blocks and typed input", function()
    if not (has("ruby") and has("irb")) then
      return
    end
    local buf = run_all({
      "#+begin_src ruby :session rb",
      "base = 40",
      "#+end_src",
      "",
      "#+begin_src ruby :session rb :results output",
      "puts base + 2",
      "#+end_src",
    })
    local l = buf_lines(buf)
    ok(vim.tbl_contains(l, ": 42"), vim.inspect(l))
    local sess = session.find("ruby", "rb")
    eq("*rb*", bufname(sess))
    type_in(sess, "extra = base * 2", "80")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "#+begin_src ruby :session rb", "extra + 1", "#+end_src" })
    run_at(buf, #buf_lines(buf) - 1)
    eq(": 81", buf_lines(buf)[#buf_lines(buf)], vim.inspect(buf_lines(buf)))
  end)

  it("node: globals persist, promises are awaited, typed input is shared", function()
    if not has("node") then
      return
    end
    local buf = run_all({
      "#+begin_src js :session",
      "function add(a, b) { return a + b; }",
      "#+end_src",
      "",
      "#+begin_src js :session",
      "new Promise((r) => setTimeout(() => r(add(40, 2)), 50))",
      "#+end_src",
    })
    local l = buf_lines(buf)
    eq(": 42", l[#l], vim.inspect(l))
    local sess = session.find("js", "default")
    eq("*Javascript REPL*", bufname(sess))
    type_in(sess, "var typed = add(1, 2)", "> ")
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "#+begin_src js :session", "typed * 10", "#+end_src" })
    run_at(buf, #buf_lines(buf) - 1)
    eq(": 30", buf_lines(buf)[#buf_lines(buf)], vim.inspect(buf_lines(buf)))
  end)

  it("R: state persists; value and output", function()
    if not has("R") then
      return
    end
    local buf = run_all({
      "#+begin_src R :session",
      "x <- c(1, 2, 3)",
      "#+end_src",
      "",
      "#+begin_src R :session",
      "sum(x) * 7",
      "#+end_src",
      "",
      "#+begin_src R :session :results output",
      "cat(length(x), '\\n')",
      "#+end_src",
    })
    local l = buf_lines(buf)
    eq(": 42", after(l, "#+begin_src R :session"), vim.inspect(l))
    ok(vim.tbl_contains(l, ": 3"), vim.inspect(l))
    eq("*R*", bufname(session.find("r", "default")))
  end)

  it("different languages with the same session name get their own buffer", function()
    if not (has("python3") and has("bash")) then
      return
    end
    run_all({
      "#+begin_src python :session same",
      "1",
      "#+end_src",
      "",
      "#+begin_src bash :session same",
      "echo 1",
      "#+end_src",
    })
    eq("*same*", bufname(session.find("python", "same")))
    eq("*same*<2>", bufname(session.find("shell", "same")))
  end)
end)

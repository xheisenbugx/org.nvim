local babel = require("org.babel")
local session = require("org.babel.session")
local config = require("org.config")

local function wait_for(buf, pred)
  return vim.wait(10000, function()
    return pred(buf_lines(buf))
  end, 20)
end

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

describe("babel :session", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
    session.kill_all()
  end)

  it("keeps Lua globals between blocks of the same session", function()
    local buf = run_all({
      "#+begin_src lua :session s1",
      "counter = 41",
      "#+end_src",
      "",
      "#+begin_src lua :session s1",
      "return counter + 1",
      "#+end_src",
      "",
      "#+begin_src lua",
      "return tostring(counter)",
      "#+end_src",
    })
    ok(vim.tbl_contains(buf_lines(buf), ": 42"), vim.inspect(buf_lines(buf)))
    -- a block without the session doesn't see it
    ok(vim.tbl_contains(buf_lines(buf), ": nil"), vim.inspect(buf_lines(buf)))
  end)

  it("python: state persists, value is the last expression, output mode prints", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if not has("python3") then
      return
    end
    local buf = run_all({
      "#+begin_src python :session py",
      "import math",
      "x = 20",
      "#+end_src",
      "",
      "#+begin_src python :session py",
      "y = x + 1",
      "y * 2",
      "#+end_src",
      "",
      "#+begin_src python :session py :results output",
      "print('hello', x)",
      "#+end_src",
      "",
      "#+begin_src python :session py",
      "[[1, 2], [3, 4]]",
      "#+end_src",
    })
    local l = buf_lines(buf)
    ok(vim.tbl_contains(l, ": 42"), vim.inspect(l))
    ok(vim.tbl_contains(l, ": hello 20"), vim.inspect(l))
    ok(vim.tbl_contains(l, "| 3 | 4 |"), vim.inspect(l))
  end)

  it("python: errors are reported and the session keeps running", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if not has("python3") then
      return
    end
    local buf = run_all({
      "#+begin_src python :session err",
      "a = 5",
      "1/0",
      "#+end_src",
      "",
      "#+begin_src python :session err",
      "a",
      "#+end_src",
    })
    local l = buf_lines(buf)
    -- like Emacs, the error is not the result: it is shown in the
    -- *Org-Babel Error Output* buffer and the result stays empty
    eq({ "#+RESULTS:", "" }, vim.list_slice(l, 6, 7))
    local eb = vim.fn.bufnr("*Org-Babel Error Output*")
    ok(eb > 0 and table.concat(vim.api.nvim_buf_get_lines(eb, 0, -1, false), "\n"):find("ZeroDivisionError"))
    ok(vim.tbl_contains(l, ": 5"), vim.inspect(l))
  end)

  it("shell: environment and directory persist; :results value is the exit status", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if not has("bash") then
      return
    end
    local dir = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname()))
    vim.fn.mkdir(dir .. "/sub", "p")
    local buf = run_all({
      "#+begin_src bash :session sh1 :dir " .. dir,
      "export GREETING=hi",
      "cd sub",
      "#+end_src",
      "",
      "#+begin_src bash :session sh1",
      'echo "$GREETING from $(basename "$PWD")"',
      "#+end_src",
      "",
      "#+begin_src bash :session sh1 :results value",
      "false",
      "#+end_src",
      "",
      "#+begin_src bash :session sh1",
      "echo oops >&2",
      "#+end_src",
    })
    local l = buf_lines(buf)
    ok(vim.tbl_contains(l, ": hi from sub"), vim.inspect(l))
    ok(vim.tbl_contains(l, ": 1"), vim.inspect(l))
    ok(vim.tbl_contains(l, ": oops"), vim.inspect(l))
  end)

  it("node and ruby sessions keep their variables", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if has("node") then
      local buf = run_all({
        "#+begin_src js :session n",
        "const base = 40;",
        "#+end_src",
        "",
        "#+begin_src js :session n",
        "base + 2",
        "#+end_src",
      })
      ok(vim.tbl_contains(buf_lines(buf), ": 42"), vim.inspect(buf_lines(buf)))
      -- re-running a block with a top-level const works
      babel.execute({ bufnr = buf, lnum = 1, sync = true })
      ok(not vim.tbl_contains(buf_lines(buf), ": SyntaxError"), vim.inspect(buf_lines(buf)))
    end
    if has("ruby") then
      local buf = run_all({
        "#+begin_src ruby :session r",
        "items = [1, 2, 3]",
        "#+end_src",
        "",
        "#+begin_src ruby :session r",
        "items.sum * 7",
        "#+end_src",
      })
      ok(vim.tbl_contains(buf_lines(buf), ": 42"), vim.inspect(buf_lines(buf)))
    end
  end)

  it("sessions get :var assignments and differ by name", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if not has("python3") then
      return
    end
    local buf = run_all({
      "#+begin_src python :session one :var n=3",
      "n * 2",
      "#+end_src",
      "",
      "#+begin_src python :session two",
      "'n' in globals()",
      "#+end_src",
    })
    local l = buf_lines(buf)
    ok(vim.tbl_contains(l, ": 6"), vim.inspect(l))
    -- the value is Python's str(), as in Emacs
    ok(vim.tbl_contains(l, ": False"), vim.inspect(l))
  end)

  it("shows a transcript, loads a block and kills the session", function()
    local buf = org_buffer({
      "#+begin_src lua :session tr",
      "shown = 'yes'",
      "#+end_src",
    }, { 2, 0 })
    babel.load_in_session()
    local tbuf = vim.api.nvim_get_current_buf()
    ok(tbuf ~= buf)
    eq("prompt", vim.bo[tbuf].buftype)
    ok(vim.tbl_contains(buf_lines(tbuf), "lua> shown = 'yes'"), vim.inspect(buf_lines(tbuf)))
    eq("yes", session.find("lua", "tr").env.shown)
    vim.cmd("close")
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    ok(babel.kill_session())
    eq(nil, session.find("lua", "tr"))
  end)

  it("switch to session copies the body and shows the REPL terminal", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if not has("python3") then
      return
    end
    local buf = org_buffer({
      "#+begin_src python :session rp",
      "z = 7",
      "#+end_src",
    }, { 2, 0 })
    babel.switch_to_session()
    eq("z = 7", vim.fn.getreg('"'))
    local tbuf = vim.api.nvim_get_current_buf()
    eq("terminal", vim.bo[tbuf].buftype)
    eq("*rp*", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(tbuf), ":t"))
    local sess = session.find("python", "rp")
    local res = session.eval_sync(sess, "6 * 7", "repl", { timeout = 5000 })
    eq("42", vim.trim(res.output))
    ok(
      wait_for(tbuf, function(l)
        return vim.tbl_contains(l, "42")
      end),
      vim.inspect(buf_lines(tbuf))
    )
    vim.cmd("close")
    vim.api.nvim_set_current_buf(buf)
  end)

  it("falls back to a normal run for languages without sessions", function()
    local buf = org_buffer({ "#+begin_src sqlite :session x", "select 1;", "#+end_src" }, { 2, 0 })
    local b = babel.at_block(buf, 2)
    ok(b.args.session == "x")
    ok(not session.supported("sqlite", "sqlite"))
    ok(session.supported("python", "python"))
    ok(not session.supported("ts", "js"))
    eq(nil, session.name("none"))
    eq("default", session.name(""))
  end)
end)

describe("babel :async sessions (org-babel-comint-async)", function()
  local UUID = "%x+%-%x+%-4%x+%-%x+%-%x+"
  before_each(function()
    config.opts.babel.confirm_evaluate = false
    session.kill_all()
  end)

  local function start(lines, lnum)
    local buf = org_buffer(lines, { lnum or 1, 0 })
    local finished
    babel.execute({
      bufnr = buf,
      lnum = lnum or 1,
      on_done = function(success)
        finished = success
      end,
    })
    local function wait()
      local done = vim.wait(10000, function()
        return finished ~= nil
      end, 20)
      ok(done, "block did not finish")
      return finished
    end
    return buf, wait
  end

  it("writes a placeholder at once and replaces it, even after the block was edited", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    local buf, wait = start({
      "#+begin_src sh :session async1 :async yes :results output",
      "sleep 0.3; echo done",
      "#+end_src",
    })
    local placeholder = buf_lines(buf)[6]
    ok(placeholder and placeholder:match("^: " .. UUID .. "$"), vim.inspect(buf_lines(buf)))
    -- edit the block and add text above it while it runs
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "sleep 0.3; echo done # edited" })
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "* Heading", "" })
    eq(true, wait())
    eq({
      "* Heading",
      "",
      "#+begin_src sh :session async1 :async yes :results output",
      "sleep 0.3; echo done # edited",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": done",
    }, buf_lines(buf))
  end)

  it("discards the result when its placeholder was deleted", function()
    local buf, wait = start({
      "#+begin_src sh :session async2 :async :results output",
      "sleep 0.3; echo done",
      "#+end_src",
    })
    ok(buf_lines(buf)[6]:match(UUID), vim.inspect(buf_lines(buf)))
    vim.api.nvim_buf_set_lines(buf, 3, -1, false, {})
    local warned
    local notify = vim.notify
    vim.notify = function(msg)
      warned = msg
    end
    eq(false, wait())
    vim.notify = notify
    ok(warned and warned:find("placeholder", 1, true), warned)
    eq({ "#+begin_src sh :session async2 :async :results output", "sleep 0.3; echo done", "#+end_src" }, buf_lines(buf))
  end)

  it("keeps the normal asynchronous run without :async, with :async no or without a session", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    for _, header in ipairs({ ":session async3", ":session async3 :async no", ":async yes" }) do
      local buf, wait = start({ "#+begin_src sh " .. header .. " :results output", "echo plain", "#+end_src" })
      eq(3, #buf_lines(buf), header)
      eq(true, wait())
      eq(": plain", buf_lines(buf)[6], header)
    end
  end)
end)

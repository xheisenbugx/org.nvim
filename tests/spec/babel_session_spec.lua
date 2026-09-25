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
    ok(vim.wait(10000, function()
      return finished
    end, 20), "block at line " .. b.start .. " did not finish")
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
    ok(vim.tbl_contains(l, ": ZeroDivisionError: division by zero"), vim.inspect(l))
    ok(vim.tbl_contains(l, ": 5"), vim.inspect(l))
  end)

  it("shell: environment and directory persist; :results value is the exit status", function()
    if not has("bash") then
      return
    end
    local dir = vim.fn.resolve(vim.fn.tempname())
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
    ok(vim.tbl_contains(l, ": false"), vim.inspect(l))
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

  it("switch to session copies the body; typing at the prompt evaluates", function()
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
    eq("prompt", vim.bo[tbuf].buftype)
    local sess = session.find("python", "rp")
    local res = session.eval_sync(sess, "6 * 7", "repl", { timeout = 5000 })
    eq("42", vim.trim(res.output))
    ok(wait_for(tbuf, function(l)
      return vim.tbl_contains(l, "42")
    end), vim.inspect(buf_lines(tbuf)))
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

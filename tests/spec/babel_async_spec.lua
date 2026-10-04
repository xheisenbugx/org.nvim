-- Interactive evaluations run in the background: spinner, placeholder
-- results (babel.async / :async), cancelling (org.babel.jobs).
local babel = require("org.babel")
local config = require("org.config")
local jobs = require("org.babel.jobs")
local session = require("org.babel.session")
local utils = require("org.utils")

local UUID = "%x+%-%x+%-4%x+%-%x+%-%x+"

describe("babel async", function()
  posix_shell()
  local saved
  before_each(function()
    local b = config.opts.babel
    saved = { b.confirm_evaluate, b.async, b.spinner, b.spinner_interval }
    b.confirm_evaluate = false
    b.async = false
  end)
  after_each(function()
    jobs.cancel_all({ quiet = true })
    local b = config.opts.babel
    b.confirm_evaluate, b.async, b.spinner, b.spinner_interval = saved[1], saved[2], saved[3], saved[4]
  end)

  --- Execute the block at `lnum` of `buf` in the background; returns a
  --- function that waits for it and gives `ok, abort` of on_done.
  local function run(buf, lnum, extra)
    local res
    local opts = {
      bufnr = buf,
      lnum = lnum,
      on_done = function(okv, abort)
        res = { okv, abort or false }
      end,
    }
    for k, v in pairs(extra or {}) do
      opts[k] = v
    end
    babel.execute(opts)
    return function(timeout)
      ok(
        vim.wait(timeout or 10000, function()
          return res ~= nil
        end, 10),
        "evaluation did not finish"
      )
      return res[1], res[2]
    end
  end

  local function spinner_marks(buf)
    return vim.api.nvim_buf_get_extmarks(buf, jobs.ns, 0, -1, { details = true })
  end

  local function quietly(fn)
    local notify = vim.notify
    local msgs = {}
    vim.notify = function(msg)
      msgs[#msgs + 1] = msg
    end
    local okv, err = pcall(fn)
    vim.notify = notify
    if not okv then
      error(err, 0)
    end
    return msgs
  end

  local SRC = {
    "#+begin_src sh :results output",
    "sleep 0.2; printf 'a\\tb\\n1\\t2\\n'",
    "#+end_src",
  }

  describe("babel background evaluation", function()
    it("inserts the same result as a synchronous run, with and without babel.async", function()
      local sync = org_buffer(SRC)
      babel.execute({ bufnr = sync, lnum = 1, sync = true })
      local expected = buf_lines(sync)
      eq(true, #expected > 3)
      for _, async in ipairs({ false, true }) do
        config.opts.babel.async = async
        local buf = org_buffer(SRC)
        local wait = run(buf, 1)
        eq(true, (wait()))
        eq(expected, buf_lines(buf), "babel.async = " .. tostring(async))
      end
    end)

    it("animates a spinner in virtual text without changing the buffer", function()
      config.opts.babel.spinner = { "1", "2", "3" }
      config.opts.babel.spinner_interval = 20
      local buf = org_buffer({ "#+begin_src sh", "sleep 0.4; echo done", "#+end_src" })
      local tick = vim.api.nvim_buf_get_changedtick(buf)
      local wait = run(buf, 1)
      local seen = {}
      vim.wait(250, function()
        for _, m in ipairs(spinner_marks(buf)) do
          eq(0, m[2], "the spinner is on the #+begin_src line")
          seen[m[4].virt_text[1][1]] = true
          eq("OrgBabelRunning", m[4].virt_text[1][2])
        end
        return false
      end, 10)
      eq(tick, vim.api.nvim_buf_get_changedtick(buf), "no buffer change while it runs")
      ok(seen["  1 executing…"] and seen["  2 executing…"], vim.inspect(seen))
      eq(1, #jobs.list(buf))
      eq(true, (wait()))
      eq({}, spinner_marks(buf))
      eq({}, jobs.list(buf))
      eq(": done", buf_lines(buf)[6])
    end)

    it("puts the result after the block when lines are added above it while it runs", function()
      local buf = org_buffer({ "#+begin_src sh", "sleep 0.2; echo moved", "#+end_src" })
      local wait = run(buf, 1)
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "* Heading", "text", "" })
      eq(true, (wait()))
      eq(
        { "* Heading", "text", "", "#+begin_src sh", "sleep 0.2; echo moved", "#+end_src", "", "#+RESULTS:", ": moved" },
        buf_lines(buf)
      )
    end)

    it("runs several blocks at once, each result in its place", function()
      local buf = org_buffer({
        "#+begin_src sh",
        "sleep 0.3; echo first",
        "#+end_src",
        "",
        "#+begin_src sh",
        "sleep 0.1; echo second",
        "#+end_src",
      })
      local w1 = run(buf, 1)
      local w2 = run(buf, 5)
      eq(2, #jobs.list(buf))
      eq(true, (w2()))
      eq(true, (w1()))
      eq({
        "#+begin_src sh",
        "sleep 0.3; echo first",
        "#+end_src",
        "",
        "#+RESULTS:",
        ": first",
        "",
        "#+begin_src sh",
        "sleep 0.1; echo second",
        "#+end_src",
        "",
        "#+RESULTS:",
        ": second",
      }, buf_lines(buf))
    end)

    it("keeps the standard output as result and shows the error output", function()
      config.opts.babel.async = true
      local buf =
        org_buffer({ "#+begin_src sh :results output", "sleep 0.1; echo out; echo oops >&2; exit 3", "#+end_src" })
      local wait
      quietly(function()
        wait = run(buf, 1)
        eq(false, (wait()))
      end)
      eq({ "", "#+RESULTS:", ": out" }, vim.list_slice(buf_lines(buf), 4))
      local err
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b):match("Org%-Babel Error Output") then
          err = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
        end
      end
      ok(err and err:find("oops", 1, true) and err:find("code 3", 1, true), err)
    end)

    it("makes the result one undo step", function()
      for _, async in ipairs({ false, true }) do
        config.opts.babel.async = async
        local lines = { "#+begin_src sh", "sleep 0.1; echo undo", "#+end_src", "", "#+RESULTS:", ": old" }
        local buf = org_buffer(lines)
        -- a fresh undo step, as after typing
        vim.bo[buf].undolevels = vim.bo[buf].undolevels
        local wait = run(buf, 1)
        eq(true, (wait()))
        eq(": undo", buf_lines(buf)[6])
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("silent undo")
        end)
        eq(lines, buf_lines(buf), "babel.async = " .. tostring(async))
      end
    end)

    it("keeps synchronous runs (export, references) without placeholder or job", function()
      config.opts.babel.async = true
      local buf = org_buffer({ "#+begin_src sh", "echo now", "#+end_src" })
      babel.execute({ bufnr = buf, lnum = 1, sync = true })
      eq({}, jobs.list())
      eq(": now", buf_lines(buf)[6])
      local b = babel.at_block(buf, 1)
      eq("now", babel.evaluate_sync(buf, b, b.args))
    end)
  end)

  describe("babel placeholder results (babel.async)", function()
    it("writes a placeholder at once and replaces it even after the block was edited", function()
      config.opts.babel.async = true
      local buf = org_buffer({ "#+begin_src sh", "sleep 0.2; echo done", "#+end_src", "", "#+RESULTS:", ": old" })
      local wait = run(buf, 1)
      ok(buf_lines(buf)[6]:match("^: " .. UUID .. "$"), vim.inspect(buf_lines(buf)))
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "sleep 0.2; echo done # edited" })
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "* Heading" })
      eq(true, (wait()))
      eq(
        { "* Heading", "#+begin_src sh", "sleep 0.2; echo done # edited", "#+end_src", "", "#+RESULTS:", ": done" },
        buf_lines(buf)
      )
    end)

    it("discards the result with a warning when the placeholder was deleted", function()
      config.opts.babel.async = true
      local buf = org_buffer({ "#+begin_src sh", "sleep 0.2; echo done", "#+end_src" })
      local wait = run(buf, 1)
      vim.api.nvim_buf_set_lines(buf, 3, -1, false, {})
      local msgs = quietly(function()
        eq(false, (wait()))
      end)
      ok(msgs[1] and msgs[1]:find("placeholder", 1, true), vim.inspect(msgs))
      eq({ "#+begin_src sh", "sleep 0.2; echo done", "#+end_src" }, buf_lines(buf))
    end)

    it("leaves a block with :async no alone until it is done", function()
      config.opts.babel.async = true
      local buf = org_buffer({ "#+begin_src sh :async no", "sleep 0.1; echo plain", "#+end_src" })
      local wait = run(buf, 1)
      eq(3, #buf_lines(buf))
      eq(true, (wait()))
      eq(": plain", buf_lines(buf)[6])
    end)
  end)

  describe("babel_cancel", function()
    local dir
    before_each(function()
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
    end)
    after_each(function()
      vim.fn.delete(dir, "rf")
    end)

    --- A block that writes `marker` after a while, unless it is killed.
    local function slow_block(marker)
      return { "#+begin_src sh", "sleep 0.6; touch '" .. dir .. "/" .. marker .. "'; echo late", "#+end_src" }
    end

    local function exists(marker)
      return vim.fn.filereadable(dir .. "/" .. marker) == 1
    end

    it("kills the block at the cursor and shows it in the placeholder", function()
      config.opts.babel.async = true
      local buf = org_buffer(slow_block("one"), { 2, 0 })
      local wait = run(buf, 1)
      local msgs = quietly(function()
        babel.cancel_block()
      end)
      eq({ "Babel evaluation cancelled" }, msgs)
      eq({ false, true }, { wait() })
      eq(": " .. babel.CANCELLED, buf_lines(buf)[6])
      eq({}, spinner_marks(buf))
      vim.wait(900)
      ok(not exists("one"), "the process was killed")
      eq(": " .. babel.CANCELLED, buf_lines(buf)[6], "a late result is dropped")
    end)

    it("keeps the previous result without a placeholder", function()
      local lines = slow_block("two")
      vim.list_extend(lines, { "", "#+RESULTS:", ": previous" })
      local buf = org_buffer(lines, { 1, 0 })
      local wait = run(buf, 1)
      quietly(function()
        babel.cancel_block()
      end)
      eq({ false, true }, { wait() })
      vim.wait(900)
      ok(not exists("two"))
      eq(lines, buf_lines(buf))
    end)

    it("cancels the only running job from elsewhere, or the one picked", function()
      local buf = org_buffer({
        "* Notes",
        "#+begin_src sh",
        "sleep 2; echo a",
        "#+end_src",
        "",
        "#+begin_src sh",
        "sleep 2; echo b",
        "#+end_src",
      }, { 1, 0 })
      local wa = run(buf, 2)
      quietly(function()
        babel.cancel_block()
      end)
      eq({ false, true }, { wa() })
      wa = run(buf, 2)
      local wb = run(buf, 6)
      local select = utils.select
      local offered
      utils.select = function(items, opts)
        offered = vim.tbl_map(opts.format_item, items)
        return items[2]
      end
      quietly(function()
        babel.cancel_block()
      end)
      utils.select = select
      eq(2, #offered)
      ok(offered[1]:match("^sh .*:2 "), offered[1])
      eq({ false, true }, { wb() })
      eq(1, #jobs.list(buf))
      -- (with a count) every running evaluation
      quietly(function()
        eq(1, jobs.cancel_all())
      end)
      eq({ false, true }, { wa() })
      eq({}, jobs.list())
    end)

    it("stops executing the buffer", function()
      local lines = slow_block("first")
      vim.list_extend(lines, { "", "#+begin_src sh", "echo second", "#+end_src" })
      local buf = org_buffer(lines, { 1, 0 })
      local n
      babel.execute_buffer({
        bufnr = buf,
        on_done = function(count)
          n = count
        end,
      })
      ok(vim.wait(1000, function()
        return #jobs.list(buf) == 1
      end))
      quietly(function()
        babel.cancel_block()
      end)
      ok(vim.wait(1000, function()
        return n ~= nil
      end))
      eq(1, n)
      eq(lines, buf_lines(buf))
    end)

    it("kills the jobs of a buffer that is wiped", function()
      local buf = org_buffer(slow_block("wiped"))
      local wait = run(buf, 1)
      vim.cmd("enew!")
      ok(not vim.api.nvim_buf_is_valid(buf))
      eq({ false, true }, { wait() })
      eq({}, jobs.list())
      vim.wait(900)
      ok(not exists("wiped"))
    end)

    it("cancels an inline src block", function()
      local line = "Run src_sh[:results output]{sleep 0.6; touch '" .. dir .. "/inline'; echo late} now."
      local buf = org_buffer({ line }, { 1, 6 })
      babel.execute_block()
      eq(1, #jobs.list(buf))
      eq(1, #spinner_marks(buf))
      quietly(function()
        babel.cancel_block()
      end)
      eq({}, jobs.list())
      eq({}, spinner_marks(buf))
      vim.wait(900)
      ok(not exists("inline"))
      eq({ line }, buf_lines(buf))
    end)

    it("says so when nothing runs", function()
      local msgs = quietly(function()
        babel.cancel_block()
      end)
      eq({ "No source block evaluation is running" }, msgs)
    end)

    it("interrupts a session evaluation and the session runs the next block", function()
      skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
      session.kill_all()
      local buf = org_buffer({
        "#+begin_src sh :session cancel1 :async yes :results output",
        "sleep 5; echo late",
        "#+end_src",
      }, { 1, 0 })
      local wait = run(buf, 1)
      ok(buf_lines(buf)[6]:match("^: " .. UUID .. "$"), vim.inspect(buf_lines(buf)))
      -- the REPL must have the request before the interrupt
      vim.wait(300)
      quietly(function()
        babel.cancel_block()
      end)
      eq({ false, true }, { wait() })
      eq(": " .. babel.CANCELLED, buf_lines(buf)[6])
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "echo next" })
      wait = run(buf, 1)
      eq(true, (wait()))
      eq(": next", buf_lines(buf)[6])
      session.kill_all()
    end)
  end)
end)

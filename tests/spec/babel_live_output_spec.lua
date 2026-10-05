-- The output of a running block shown live below it (babel.live_output,
-- org.babel.jobs): virtual lines only, the result is unchanged.
local babel = require("org.babel")
local config = require("org.config")
local jobs = require("org.babel.jobs")

describe("babel live output", function()
  posix_shell()
  local saved
  before_each(function()
    local b = config.opts.babel
    saved = { b.confirm_evaluate, b.async, b.spinner, b.live_output }
    b.confirm_evaluate = false
    b.async = false
    b.spinner = false
    b.live_output = 10
  end)
  after_each(function()
    jobs.cancel_all({ quiet = true })
    local b = config.opts.babel
    b.confirm_evaluate, b.async, b.spinner, b.live_output = saved[1], saved[2], saved[3], saved[4]
  end)

  --- Execute the block at `lnum` of `buf` in the background; returns a
  --- function that waits for it and gives `ok, abort` of on_done.
  local function run(buf, lnum)
    local res
    babel.execute({
      bufnr = buf,
      lnum = lnum,
      on_done = function(okv, abort)
        res = { okv, abort or false }
      end,
    })
    return function()
      ok(
        vim.wait(10000, function()
          return res ~= nil
        end, 10),
        "evaluation did not finish"
      )
      return res[1], res[2]
    end
  end

  --- The live view of `buf`: { row = 0-based row, lines = { text, ... } },
  --- or nil.
  local function live(buf)
    local marks = vim.api.nvim_buf_get_extmarks(buf, jobs.live_ns, 0, -1, { details = true })
    for _, m in ipairs(marks) do
      if m[4].virt_lines then
        local lines = {}
        for _, vl in ipairs(m[4].virt_lines) do
          local text = {}
          for _, chunk in ipairs(vl) do
            text[#text + 1] = chunk[1]
          end
          lines[#lines + 1] = table.concat(text)
        end
        return { row = m[2], lines = lines, hl = m[4].virt_lines[2] and m[4].virt_lines[2][2][2] }
      end
    end
  end

  local function wait_for(buf, pred, what)
    local view
    ok(
      vim.wait(5000, function()
        view = live(buf)
        return view ~= nil and pred(view)
      end, 5),
      "no live view with " .. what .. ": " .. vim.inspect(view)
    )
    return view
  end

  local function shows(view, text)
    for _, l in ipairs(view.lines) do
      if l == "  │ " .. text then
        return true
      end
    end
    return false
  end

  local function quietly(fn)
    local notify = vim.notify
    vim.notify = function() end
    local okv, err = pcall(fn)
    vim.notify = notify
    if not okv then
      error(err, 0)
    end
  end

  it("shows the output as it arrives below the block, then the result replaces it", function()
    local src = {
      "* Build",
      "#+begin_src sh :results output",
      "echo one; sleep 0.5; echo two >&2; sleep 0.5; echo three",
      "#+end_src",
    }
    local buf = org_buffer(src)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local wait = run(buf, 2)
    local view = wait_for(buf, function(v)
      return shows(v, "one")
    end, "one")
    eq(3, view.row, "below the #+end_src line")
    eq("  output", view.lines[1])
    eq(false, shows(view, "two"), "not yet printed")
    eq("OrgBabelOutput", view.hl)
    view = wait_for(buf, function(v)
      return shows(v, "two")
    end, "two (stderr)")
    eq({ "  │ one", "  │ two" }, vim.list_slice(view.lines, 2))
    eq(tick, vim.api.nvim_buf_get_changedtick(buf), "the buffer does not change while it runs")
    quietly(function()
      eq(false, (wait()))
    end)
    eq(nil, live(buf), "gone when the result is in")
    eq({}, vim.api.nvim_buf_get_extmarks(buf, jobs.live_ns, 0, -1, {}))
    eq({ "", "#+RESULTS:", ": one", ": three" }, vim.list_slice(buf_lines(buf), 5))
  end)

  it("inserts the same result as with live output off and as a synchronous run", function()
    local bodies = {
      "sleep 0.1; printf 'a\\tb\\n1\\t2\\n'",
      "printf 'x\\r\\ny\\r\\n'; sleep 0.1; printf 'z'",
      "for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo line $i; done; echo err >&2",
      "printf '\\033[31mred\\033[0m\\n'",
      "head -c 50000 /dev/zero | tr '\\0' 'a'; echo",
    }
    for _, body in ipairs(bodies) do
      for _, results in ipairs({ "output", "value" }) do
        local src = { "#+begin_src sh :results " .. results, body, "#+end_src" }
        local sync = org_buffer(src)
        quietly(function()
          babel.execute({ bufnr = sync, lnum = 1, sync = true })
        end)
        local expected = buf_lines(sync)
        for _, setting in ipairs({ 10, false }) do
          config.opts.babel.live_output = setting
          local buf = org_buffer(src)
          local wait = run(buf, 1)
          quietly(function()
            wait()
          end)
          eq(expected, buf_lines(buf), body .. " / " .. results .. " / " .. tostring(setting))
        end
        config.opts.babel.live_output = 10
      end
    end
  end)

  it("clears the live view when the run is cancelled", function()
    local buf = org_buffer({ "#+begin_src sh", "echo started; sleep 30", "#+end_src" }, { 1, 0 })
    local wait = run(buf, 1)
    wait_for(buf, function(v)
      return shows(v, "started")
    end, "started")
    quietly(function()
      babel.cancel_block()
    end)
    eq({ false, true }, { wait() })
    eq({}, vim.api.nvim_buf_get_extmarks(buf, jobs.live_ns, 0, -1, {}))
    vim.wait(150)
    eq(nil, live(buf), "no late redraw brings it back")
    eq({ "#+begin_src sh", "echo started; sleep 30", "#+end_src" }, buf_lines(buf))
  end)

  it("clears the live view when the run fails", function()
    local buf = org_buffer({ "#+begin_src sh :results output", "echo partial; sleep 0.3; exit 2", "#+end_src" })
    local wait = run(buf, 1)
    wait_for(buf, function(v)
      return shows(v, "partial")
    end, "partial")
    quietly(function()
      eq(false, (wait()))
    end)
    eq({}, vim.api.nvim_buf_get_extmarks(buf, jobs.live_ns, 0, -1, {}))
    eq(": partial", buf_lines(buf)[6])
  end)

  it("shows nothing while running with babel.live_output off", function()
    for _, setting in ipairs({ false, 0 }) do
      config.opts.babel.live_output = setting
      local buf = org_buffer({ "#+begin_src sh :results output", "echo early; sleep 0.4; echo late", "#+end_src" })
      local wait = run(buf, 1)
      local seen = false
      vim.wait(300, function()
        seen = seen or #vim.api.nvim_buf_get_extmarks(buf, jobs.live_ns, 0, -1, {}) > 0
        return false
      end, 10)
      eq(false, seen, tostring(setting))
      eq(1, #jobs.list(buf), "it still runs as a job")
      eq(nil, jobs.list(buf)[1].live)
      eq(true, (wait()))
      eq({ ": early", ": late" }, vim.list_slice(buf_lines(buf), 6))
    end
  end)

  it("streams nothing without a live view: vim.system collects the output", function()
    local opts = { text = true }
    eq(nil, jobs.stream(nil, opts))
    eq({ text = true }, opts)
  end)

  it("shows the last lines only, with how many there are", function()
    config.opts.babel.live_output = 3
    local buf = org_buffer({ "#+begin_src sh", "for i in $(seq 1 25); do echo line $i; done; sleep 30", "#+end_src" })
    run(buf, 1)
    local view = wait_for(buf, function(v)
      return shows(v, "line 25")
    end, "line 25")
    eq({ "  output, last 3 of 25 lines", "  │ line 23", "  │ line 24", "  │ line 25" }, view.lines)
  end)

  describe("the view", function()
    local buf, job
    before_each(function()
      config.opts.babel.live_output = 4
      buf = org_buffer({ "#+begin_src sh", "true", "#+end_src" })
      job = jobs.start(buf, 0, { end_row = 2 })
    end)
    after_each(function()
      jobs.finish(job)
    end)

    local function text()
      local out = {}
      for _, vl in ipairs(jobs.live_lines(job) or {}) do
        local t = {}
        for _, chunk in ipairs(vl) do
          t[#t + 1] = chunk[1]
        end
        out[#out + 1] = table.concat(t)
      end
      return out
    end

    it("drops colours and control characters, keeps the text after a carriage return, expands tabs", function()
      jobs.output(job, "\27[1;32mgreen\27[0m done\n")
      jobs.output(job, "10%\r50%\r100%\n")
      jobs.output(job, "a\tb\tc\n")
      jobs.output(job, "bell\7 here")
      eq({
        "  output",
        "  │ green done",
        "  │ 100%",
        "  │ a       b       c",
        "  │ bell here",
      }, text())
    end)

    it("shows a line still being written, and joins it with what follows", function()
      jobs.output(job, "loading")
      eq({ "  output", "  │ loading" }, text())
      jobs.output(job, "... ok\n")
      eq({ "  output", "  │ loading... ok" }, text())
    end)

    it("keeps at most LIVE_BYTES of output and cuts long lines", function()
      local long = string.rep("x", jobs.LIVE_LINE_CHARS + 50)
      for _ = 1, 200 do
        jobs.output(job, string.rep("y", 199) .. "\n")
      end
      jobs.output(job, long .. "\n")
      ok(#job.live.tail <= jobs.LIVE_BYTES, #job.live.tail)
      eq(true, job.live.cut)
      local lines = text()
      eq("  output, last 4 of 201 lines", lines[1])
      eq("  │ " .. string.rep("x", jobs.LIVE_LINE_CHARS) .. "…", lines[5])
      -- one write larger than the cap
      jobs.output(job, string.rep("z", jobs.LIVE_BYTES * 2) .. "\nend\n")
      ok(#job.live.tail <= jobs.LIVE_BYTES)
      eq("  │ end", text()[#text()])
    end)

    it("shows nothing before any output, and ignores output after the end", function()
      eq({}, text())
      jobs.finish(job)
      jobs.output(job, "late\n")
      vim.wait(100)
      eq({}, vim.api.nvim_buf_get_extmarks(buf, jobs.live_ns, 0, -1, {}))
    end)

    it("redraws at most every LIVE_REDRAW_MS while output pours in", function()
      local set_extmark = vim.api.nvim_buf_set_extmark
      local draws = 0
      vim.api.nvim_buf_set_extmark = function(b, ns, ...)
        if ns == jobs.live_ns then
          draws = draws + 1
        end
        return set_extmark(b, ns, ...)
      end
      local start = vim.uv.now()
      local okv, err = pcall(function()
        local n = 0
        vim.wait(400, function()
          n = n + 1
          jobs.output(job, "chunk " .. n .. "\n")
          return false
        end, 1)
        -- the last chunk is drawn too
        vim.wait(jobs.LIVE_REDRAW_MS * 3)
        eq("  │ chunk " .. n, text()[#text()])
      end)
      vim.api.nvim_buf_set_extmark = set_extmark
      assert(okv, err)
      local elapsed = vim.uv.now() - start
      ok(draws >= 2, draws)
      ok(draws <= math.ceil(elapsed / jobs.LIVE_REDRAW_MS) + 2, string.format("%d draws in %dms", draws, elapsed))
      local marks = vim.api.nvim_buf_get_extmarks(buf, jobs.live_ns, 0, -1, { details = true })
      eq(2, marks[1][2], "below the #+end_src line")
    end)
  end)
end)

-- Exports in the background (org-export-in-background, org-export-stack):
-- the compilers and converters that run after the Lua export (LaTeX ->
-- PDF, ODT -> DOCX, ...) and the separate Neovim of `a` exports run with
-- vim.system callbacks, sit on the export stack while they run, can be
-- cancelled there, and report their output when they fail. The external
-- programs are faked with POSIX shell commands.

local config = require("org.config")
local export = require("org.export")
local process = require("org.export.process")
local utils = require("org.utils")

local is_win = vim.fn.has("win32") == 1

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return utils.realpath(d)
end

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

--- Set export options ("latex.pdf_process" = value, ...); returns the restore function.
local function set_export(opts)
  local saved = {}
  for key, v in pairs(opts) do
    local t, k = config.opts.export, key
    local sub, rest = key:match("^(%w+)%.(.+)$")
    if sub then
      t, k = config.opts.export[sub], rest
    end
    saved[#saved + 1] = { t, k, t[k] }
    t[k] = v
  end
  return function()
    for i = #saved, 1, -1 do
      local s = saved[i]
      s[1][s[2]] = s[3]
    end
  end
end

local function wait(cond, ms)
  return vim.wait(ms or 20000, cond, 10)
end

local function bufname(buf)
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
end

describe("export in the background", function()
  posix_shell()
  local restore, messages, notify, ui_open, opened

  before_each(function()
    export.stack_clear()
    messages, opened = {}, {}
    notify = utils.notify
    utils.notify = function(msg, level)
      messages[#messages + 1] = { msg = msg, level = level or vim.log.levels.INFO }
    end
    ui_open = vim.ui.open
    vim.ui.open = function(p)
      opened[#opened + 1] = p
    end
  end)

  after_each(function()
    utils.notify = notify
    vim.ui.open = ui_open
    if restore then
      restore()
      restore = nil
    end
    process.cancel_all()
    export.stack_clear()
  end)

  local function message(pat, level)
    for _, m in ipairs(messages) do
      if m.msg:find(pat, 1, true) and (not level or m.level == level) then
        return m.msg
      end
    end
  end

  describe("process runner", function()
    it("runs the commands one after another, waiting, into a log buffer", function()
      local d = tmpdir()
      local run = process.run(
        { "echo one", "echo two > f", "cat f; echo err >&2" },
        { cwd = d, log_buffer = "*T log*" }
      )
      eq(false, run.running)
      eq(0, run.code)
      eq("one\ntwo\nerr\n", run:text())
      eq({ "one", "two", "err", "" }, vim.api.nvim_buf_get_lines(run.log_buf, 0, -1, false))
      eq("*T log*", bufname(run.log_buf))
    end)

    it("runs them in the background and calls back once all are done", function()
      local d = tmpdir()
      local done, streamed = nil, {}
      local run = process.run({ "sleep 0.2; echo a", "echo b > out" }, {
        cwd = d,
        on_output = function(t)
          streamed[#streamed + 1] = t
        end,
      }, function(r)
        done = r
      end)
      -- returns at once, running
      eq(true, run.running)
      eq(nil, done)
      eq("*Org Export Process*", bufname(run.log_buf))
      ok(wait(function()
        return done ~= nil
      end))
      eq(run, done)
      eq(false, run.running)
      eq("a\n", table.concat(streamed))
      eq(1, vim.fn.filereadable(d .. "/out"))
      eq("a", vim.api.nvim_buf_get_lines(run.log_buf, 0, 1, false)[1])
    end)

    it("cancels: kills the command with the processes it started", function()
      local d = tmpdir()
      local done
      -- the inner sh is a child of the command's shell: killing only that
      -- shell would leave it running (and holding the output pipe)
      local run = process.run({ "sh -c 'sleep 2; touch late'", "touch next" }, { cwd = d }, function(r)
        done = r
      end)
      ok(wait(function()
        return run._obj ~= nil
      end, 5000))
      vim.wait(100)
      eq(true, run:cancel())
      eq(false, run:cancel())
      ok(
        wait(function()
          return done ~= nil
        end, 1500),
        "on_done after cancel"
      )
      eq(true, done.cancelled)
      if not is_win then
        vim.wait(2500)
        eq(0, vim.fn.filereadable(d .. "/late"))
      end
      eq(0, vim.fn.filereadable(d .. "/next"))
    end)

    it("picks out LaTeX error lines", function()
      local log = "This is pdfTeX\n! Undefined control sequence.\nl.3 \\foo\n\n(more)\n! Emergency stop.\n"
      eq({ "! Undefined control sequence.", "l.3 \\foo", "! Emergency stop." }, process.error_excerpt(log))
      eq({}, process.error_excerpt("all good"))
    end)
  end)

  describe("PDF compilation", function()
    local function org_file(lines)
      local d = tmpdir()
      local buf = org_buffer(lines, { 1, 0 })
      vim.api.nvim_buf_set_name(buf, d .. "/doc.org")
      return d, buf
    end

    it("compiles in the background, on the stack while it runs", function()
      local d = org_file({ "* H", "text" })
      restore = set_export({
        open_after_export = false,
        ["latex.pdf_process"] = { "sleep 0.3; echo compiling", "cp %f %b.pdf" },
      })
      local pdf, proc = export.export("pdf", { async = true, open = true })
      eq(d .. "/doc.pdf", pdf)
      ok(proc and proc.running)
      eq(0, vim.fn.filereadable(pdf))
      ok(message("Processing LaTeX file " .. d .. "/doc.tex..."))
      local entry = export.stack_contents[1]
      eq(true, entry.running)
      eq("*Org PDF LaTeX Output*", bufname(entry.source))
      ok(export.stack_lines()[1]:match("^1%s+latex%s+run%s+%*Org PDF LaTeX Output%*$"), export.stack_lines()[1])
      ok(wait(function()
        return not entry.running
      end))
      eq(pdf, entry.source)
      eq(read(d .. "/doc.tex"), read(pdf))
      ok(message("PDF file produced. " .. pdf))
      -- "and open": opened once done
      eq({ pdf }, opened)
    end)

    it("reports a failure with the output and keeps the log files", function()
      local d = org_file({ "text" })
      restore = set_export({
        open_after_export = false,
        ["latex.pdf_process"] = {
          "echo 'This is pdfTeX'; echo '! Undefined control sequence.'; echo 'l.7 bad'; echo log > %b.log",
        },
      })
      local _, proc = export.export("pdf", { async = true })
      local entry = export.stack_contents[1]
      ok(wait(function()
        return not proc.running and not entry.running
      end))
      local err = message("wasn't produced", vim.log.levels.ERROR)
      ok(err, vim.inspect(messages))
      ok(
        err:find('File "' .. d .. '/doc.pdf" wasn\'t produced  See "*Org PDF LaTeX Output*" for details', 1, true),
        err
      )
      ok(err:find("! Undefined control sequence.\nl.7 bad", 1, true), err)
      -- Emacs signals the error before removing the log files
      eq(1, vim.fn.filereadable(d .. "/doc.log"))
      -- the entry stays, with the output (Emacs: the process "exit"ed)
      eq("exit", entry.status)
      ok(export.stack_lines()[1]:match("^1%s+latex%s+exit%s+%*Org PDF LaTeX Output%*$"))
      local log = vim.api.nvim_buf_get_lines(entry.source, 0, -1, false)
      eq("! Undefined control sequence.", log[2])
    end)

    it("is cancelled from the stack", function()
      local d = org_file({ "text" })
      restore = set_export({
        open_after_export = false,
        ["latex.pdf_process"] = { "sleep 5", "cp %f %b.pdf" },
      })
      local _, proc = export.export("pdf", { async = true })
      local entry = export.stack_contents[1]
      ok(wait(function()
        return proc._obj ~= nil
      end, 5000))
      local stack = export.stack_show()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      -- x on the entry
      vim.api.nvim_feedkeys("x", "x", false)
      ok(
        wait(function()
          return not entry.running
        end, 3000),
        "cancelled"
      )
      eq(true, proc.cancelled)
      eq("signal", entry.status)
      ok(vim.api.nvim_buf_get_lines(stack, 0, 1, false)[1]:match("^1%s+latex%s+signal"))
      eq(0, vim.fn.filereadable(d .. "/doc.pdf"))
      ok(message("Export cancelled"))
      -- no error for a cancelled compilation
      eq(nil, message("", vim.log.levels.ERROR))
      -- nothing left to cancel
      eq(false, export.stack_cancel())
      pcall(vim.cmd, "close")
    end)

    it("views the output of a running compilation", function()
      org_file({ "text" })
      restore = set_export({ open_after_export = false, ["latex.pdf_process"] = { "echo started; sleep 5" } })
      local _, proc = export.export("pdf", { async = true })
      ok(wait(function()
        return proc:text():find("started") ~= nil
      end, 5000))
      local stack = export.stack_show()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      export.stack_view()
      eq("*Org PDF LaTeX Output*", bufname(0))
      ok(wait(function()
        return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "started"
      end, 2000))
      ok(export.stack_cancel(export.stack_contents[1]))
      pcall(vim.cmd, "only")
      vim.api.nvim_buf_delete(stack, { force = true })
    end)

    it("still compiles synchronously, off the stack, without async", function()
      local d = org_file({ "text" })
      restore = set_export({ open_after_export = false, ["latex.pdf_process"] = { "cp %f %b.pdf", "touch %b.aux" } })
      local pdf, proc = export.export("pdf", { async = false })
      eq(d .. "/doc.pdf", pdf)
      eq(nil, proc)
      eq(1, vim.fn.filereadable(pdf))
      -- logfiles removed after a success
      eq(0, vim.fn.filereadable(d .. "/doc.aux"))
      eq({}, export.stack_contents)
      ok(message("PDF file produced. " .. pdf))
      -- the default without a UI (headless) is synchronous too
      local pdf2, proc2 = export.export("pdf")
      eq(pdf, pdf2)
      eq(nil, proc2)
    end)
  end)

  describe("ODT conversion", function()
    it("converts in the background and opens the result", function()
      local d = tmpdir()
      local buf = org_buffer({ "* H", "text" }, { 1, 0 })
      vim.api.nvim_buf_set_name(buf, d .. "/doc.org")
      restore = set_export({
        open_after_export = false,
        ["odt.preferred_output_format"] = "docx",
        ["odt.convert_process"] = "fake",
        ["odt.convert_processes"] = { { "fake", "sleep 0.2; cp %i %o" } },
      })
      local done
      local out, proc = export.export("odt", {
        async = true,
        open = true,
        on_done = function(r)
          done = r
        end,
      })
      eq(d .. "/doc.odt", out)
      ok(proc and proc.running)
      eq({}, opened)
      local entry = export.stack_contents[1]
      eq("odt", entry.backend)
      eq(true, entry.running)
      ok(wait(function()
        return done ~= nil
      end))
      eq(d .. "/doc.docx", done)
      eq(d .. "/doc.docx", entry.source)
      eq(read(out), read(done))
      eq({ done }, opened)
      ok(message("Exported to " .. done))
    end)

    it("converts synchronously without async", function()
      local d = tmpdir()
      restore = set_export({
        open_after_export = false,
        ["odt.preferred_output_format"] = "docx",
        ["odt.convert_process"] = "fake",
        ["odt.convert_processes"] = { { "fake", "cp %i %o" } },
      })
      local out, proc = require("org.export.odt").export_file({ "Text" }, {}, { output = d .. "/x.odt", async = false })
      eq(d .. "/x.docx", out)
      eq(nil, proc)
      eq({}, export.stack_contents)
    end)
  end)

  describe("asynchronous export (a separate Neovim)", function()
    it("exports the buffer as it was when the export started", function()
      local d = tmpdir()
      local buf = org_buffer({ "first version" }, { 1, 0 })
      vim.api.nvim_buf_set_name(buf, d .. "/s.org")
      restore = set_export({ open_after_export = false })
      local entry = export.export_async("ascii", { body_only = true })
      eq("*Org Export Process*", bufname(entry.source))
      -- edited while the export runs
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "second version" })
      ok(wait(function()
        return not entry.running
      end))
      eq(d .. "/s.txt", entry.source)
      ok(read(entry.source):find("first version", 1, true))
      ok(message("Asynchronous export finished: " .. d .. "/s.txt"))
      -- the process buffer goes, as in Emacs
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        ok(not bufname(b):find("Org Export Process", 1, true) or not vim.api.nvim_buf_is_valid(b))
      end
    end)

    it("reports a failed PDF compilation with its output", function()
      local d = tmpdir()
      local buf = org_buffer({ "text" }, { 1, 0 })
      vim.api.nvim_buf_set_name(buf, d .. "/f.org")
      restore = set_export({
        open_after_export = false,
        ["latex.pdf_process"] = { "echo '! LaTeX Error: File `missing.sty'\"'\"' not found.'" },
      })
      local entry = export.export_async("pdf", {})
      ok(wait(function()
        return not entry.running
      end))
      local err = message("Asynchronous export failed", vim.log.levels.ERROR)
      ok(err, vim.inspect(messages))
      ok(err:find("f.pdf\" wasn't produced", 1, true), err)
      ok(err:find("! LaTeX Error: File `missing.sty' not found.", 1, true), err)
      eq("exit", entry.status)
      local log = table.concat(vim.api.nvim_buf_get_lines(entry.source, 0, -1, false), "\n")
      ok(log:find("missing.sty", 1, true), log)
      -- and the compiler's output buffer, as named in the message
      local latex_log
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if bufname(b) == "*Org PDF LaTeX Output*" then
          latex_log = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
        end
      end
      ok(latex_log and latex_log:find("missing.sty", 1, true), latex_log)
    end)

    it("is cancelled with the compiler it runs", function()
      local d = tmpdir()
      local buf = org_buffer({ "text" }, { 1, 0 })
      vim.api.nvim_buf_set_name(buf, d .. "/c.org")
      restore = set_export({
        open_after_export = false,
        ["latex.pdf_process"] = { "sleep 3; touch %b.late", "cp %f %b.pdf" },
      })
      local entry = export.export_async("pdf", {})
      -- the .tex is written before the compiler starts
      ok(wait(function()
        return vim.fn.filereadable(d .. "/c.tex") == 1
      end, 15000))
      vim.wait(200)
      eq(true, export.stack_cancel())
      ok(
        wait(function()
          return not entry.running
        end, 3000),
        "cancelled"
      )
      eq("signal", entry.status)
      if not is_win then
        vim.wait(3200)
        eq(0, vim.fn.filereadable(d .. "/c.late"))
      end
      eq(0, vim.fn.filereadable(d .. "/c.pdf"))
    end)
  end)
end)

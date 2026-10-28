-- Edge cases of the review extension: a damaged or outdated saved state,
-- missing and empty files, bad step lists, dangling clocks, odd answers.
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))

local date = require("org.date")
local utils = require("org.utils")
local review = require("org.extensions.review")
local steps = require("org.extensions.review.steps")

local dir
local saved = {}
local warns

local function setup(ext, extra)
  require("org").setup(vim.tbl_extend("force", {
    org_directory = dir,
    agenda_files = { dir .. "/work.org" },
    default_notes_file = dir .. "/inbox.org",
    extensions = {
      review = vim.tbl_extend("force", {
        state_file = dir .. "/review.json",
        log_file = dir .. "/review.org",
        confirm_delete = false,
        open_log = false,
      }, ext or {}),
    },
  }, extra or {}))
end

local function write_state(t)
  vim.fn.writefile({ type(t) == "string" and t or vim.json.encode(t) }, dir .. "/review.json")
end

describe("review edge cases", function()
  before_each(function()
    dir = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname()))
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "* TODO Task" }, dir .. "/work.org")
    saved.notify, saved.warn = utils.notify, utils.warn
    utils.notify = function() end
    warns = {}
    utils.warn = function(m)
      warns[#warns + 1] = m
    end
    saved.today, saved.now, saved.today_days = date.today, date.now, date.today_days
    local T = date.days_from_civil(2026, 9, 29)
    date.today_days = function()
      return T
    end
    date.today = function()
      return date.from_days(T)
    end
    date.now = function()
      return date.from_days(T, { hour = 10, min = 0 })
    end
    vim.cmd("enew!")
  end)
  after_each(function()
    if review.session then
      review.teardown()
    end
    date.today, date.now, date.today_days = saved.today, saved.now, saved.today_days
    utils.notify, utils.warn = saved.notify, saved.warn
    vim.cmd("silent! only")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find(dir, 1, true) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = { root .. "/tests/fixtures/*.org" },
    })
    vim.fn.delete(dir, "rf")
  end)

  it("starts afresh when the saved state isn't JSON", function()
    setup()
    write_state("{ broken")
    eq(nil, review.load_state())
    local s = review.start()
    eq(1, s.index)
  end)

  it("cleans up a saved state with wrong types, so finishing still works", function()
    setup()
    write_state({
      started = "2026-09-28 Mon 09:00",
      step = "reflect",
      notes = { ["1"] = 42, ["2"] = { "a table" }, ["3"] = "kept" },
      skipped = "not a table",
      stats = { refiled = "lots", deleted = 2 },
      counts = { overdue = "x" },
    })
    local s = review.start()
    eq("reflect", s.steps[s.index].name)
    eq({}, s.state.skipped)
    review.finish()
    local log = table.concat(vim.fn.readfile(dir .. "/review.org"), "\n")
    ok(log:find("2 processed (0 refiled, 0 scheduled, 0 state changes, 2 deleted)", 1, true), log)
    ok(log:find("kept", 1, true), log)
    ok(not log:find("a table", 1, true), log)
  end)

  it("resumes at the first step when the saved one was removed from steps", function()
    setup({ steps = { "inbox", "reflect" } })
    write_state({ started = "2026-09-28 Mon 09:00", step = "clock" })
    eq(1, review.start().index)
  end)

  it("resumes by step number past the end at the first step", function()
    setup({ steps = { "inbox", "reflect" } })
    write_state({ started = "2026-09-28 Mon 09:00", step = 9 })
    eq(1, review.start().index)
  end)

  it("warns about unknown and invalid steps but keeps the valid ones", function()
    setup({ steps = { "inbox", "nope", 42, { "alsonope" }, "reflect" } })
    local s = review.start()
    eq(2, #s.steps)
    eq({ "unknown review step: nope", "invalid review step #3", "unknown review step: alsonope" }, warns)
  end)

  it("refuses to start with no valid step", function()
    setup({ steps = { "nope" } })
    eq(nil, review.start())
    eq("No review steps", warns[#warns])
    eq(nil, review.session)
  end)

  it("shows an empty inbox when the inbox file doesn't exist", function()
    setup({ inbox = dir .. "/missing.org" })
    local s = review.start("inbox")
    local items = review.collect(s.steps[s.index])
    eq({}, items)
  end)

  it("lists nothing, without errors, for empty agenda files", function()
    vim.fn.writefile({}, dir .. "/work.org")
    vim.fn.writefile({}, dir .. "/inbox.org")
    setup()
    local s = review.start()
    for i, step in ipairs(s.steps) do
      local items = review.collect(step)
      for _, it in ipairs(items) do
        ok(not (it.text or ""):find("^Error"), "step " .. i .. ": " .. tostring(it.text))
      end
      review.goto_step(i)
    end
  end)

  it("leaves a running clock out of the time spent", function()
    vim.fn.writefile({
      "* TODO Running",
      "  :LOGBOOK:",
      "  CLOCK: [2026-09-29 Tue 08:00]",
      "  :END:",
      "* TODO Closed",
      "  :LOGBOOK:",
      "  CLOCK: [2026-09-28 Mon 23:00]--[2026-09-29 Tue 01:00] =>  2:00",
      "  :END:",
    }, dir .. "/work.org")
    setup()
    local files = require("org.files").agenda_files()
    local list, total = steps.clock_summary(files, date.now(), 7)
    eq(120, total)
    eq(1, #list)
    eq("Closed", list[1].hl:plain_title())
  end)

  it("logs with no questions and clock_days = 0", function()
    setup({ questions = {}, clock_days = 0, steps = { "clock", "reflect" } })
    review.start()
    review.finish()
    local log = vim.fn.readfile(dir .. "/review.org")
    ok(table.concat(log, "\n"):find("Clocked in the last 0 days: 0:00", 1, true), table.concat(log, "\n"))
  end)

  it("creates the directory of a log_file that doesn't exist", function()
    setup({ log_file = dir .. "/sub/dir/log.org", steps = { "reflect" } })
    review.start()
    review.finish()
    eq({}, warns)
    eq(1, vim.fn.filereadable(dir .. "/sub/dir/log.org"))
  end)

  it("keeps the saved review when its log can't be written", function()
    -- under a file, not a directory: nothing can be created there
    setup({ log_file = dir .. "/work.org/log.org", steps = { "reflect" } })
    review.start()
    review.session.state.notes["1"] = "Worth keeping"
    review.finish()
    eq("The review could not be logged", warns[#warns])
    local st = review.load_state()
    ok(st)
    eq("Worth keeping", st.notes["1"])
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].modified then
        vim.bo[b].modified = false
      end
    end
  end)

  it("keeps unicode and multi-line answers in the log", function()
    setup({ steps = { "reflect" } })
    review.start()
    review.session.state.notes["1"] = "Très bien ✓\n\n日本語"
    review.finish()
    local log = vim.fn.readfile(dir .. "/review.org")
    local text = table.concat(log, "\n")
    ok(text:find("Très bien ✓", 1, true))
    ok(text:find("日本語", 1, true))
  end)
end)

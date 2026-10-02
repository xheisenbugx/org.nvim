local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))

local date = require("org.date")
local utils = require("org.utils")

local dir

local INBOX = {
  "* Call the dentist",
  "* Idea: learn Rust",
  "* Buy milk",
}

local WORK = {
  "* Projects",
  "** Website redesign :project:",
  "*** TODO Draft wireframes",
  "** Tax return :project:",
  "Notes only.",
  "** DONE Old project :project:",
  "* Tasks",
  "** WAITING Reply from Bob",
  "** TODO Pay rent",
  "   DEADLINE: <2026-09-25 Fri>",
  "** TODO Dentist appointment",
  "   SCHEDULED: <2026-10-03 Sat 10:00>",
  "** TODO Weekly sync",
  "   SCHEDULED: <2026-09-22 Tue +1w>",
  "** Learn guitar :someday:",
  "** SOMEDAY Sail around the world",
  "** TODO Write report",
  "   :LOGBOOK:",
  "   CLOCK: [2026-09-28 Mon 09:00]--[2026-09-28 Mon 11:30] =>  2:30",
  "   CLOCK: [2026-09-10 Thu 09:00]--[2026-09-10 Thu 10:00] =>  1:00",
  "   :END:",
  "** TODO Plan trip",
  "   :LOGBOOK:",
  "   CLOCK: [2026-09-27 Sun 20:00]--[2026-09-27 Sun 20:45] =>  0:45",
  "   :END:",
}

local function setup(ext)
  require("org").setup({
    org_directory = dir,
    agenda_files = { dir .. "/inbox.org", dir .. "/work.org" },
    default_notes_file = dir .. "/inbox.org",
    todo_keywords = { "TODO NEXT WAITING SOMEDAY | DONE" },
    agenda = { stuck_projects = { match = "+project/-DONE", todo_keywords = { "TODO", "NEXT" } } },
    extensions = ext ~= nil and {
      review = vim.tbl_extend("force", {
        state_file = dir .. "/review.json",
        log_file = dir .. "/review.org",
        confirm_delete = false,
      }, type(ext) == "table" and ext or {}),
    } or nil,
  })
end

local function restore()
  require("org").setup({
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
  })
end

local function read(name)
  return vim.fn.readfile(dir .. "/" .. name)
end

local function titles(items)
  return vim.tbl_map(function(it)
    return it.hl and it.hl:plain_title() or it.text
  end, items)
end

local saved = {}

local function freeze()
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
end

local function wipe()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find(dir, 1, true) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

local review = require("org.extensions.review")
local steps = require("org.extensions.review.steps")

local function row_of(text)
  for i, l in ipairs(buf_lines(review.session.buf)) do
    if l:find(text, 1, true) then
      return i
    end
  end
end

local function cursor_on(text)
  local row = row_of(text)
  ok(row, "no line with " .. text)
  vim.api.nvim_win_set_cursor(review.session.win, { row, 0 })
end

describe("review extension", function()
  before_each(function()
    dir = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname()))
    vim.fn.mkdir(dir, "p")
    saved.notify = utils.notify
    utils.notify = function() end
    vim.fn.writefile(INBOX, dir .. "/inbox.org")
    vim.fn.writefile(WORK, dir .. "/work.org")
    freeze()
    vim.cmd("enew!")
  end)
  after_each(function()
    if review.session then
      review.teardown()
    end
    date.today, date.now, date.today_days = saved.today, saved.now, saved.today_days
    utils.notify = saved.notify
    vim.cmd("silent! only")
    wipe()
    restore()
    vim.fn.delete(dir, "rf")
  end)

  describe("registration", function()
    it("is off unless enabled", function()
      setup(nil)
      eq(nil, require("org.actions").list.review)
      eq(nil, require("org.commands").extra.review)
      eq(nil, require("org.config").opts.mappings.global.review)
    end)

    it("registers actions, the command and <prefix>W when enabled, and removes them again", function()
      setup({})
      ok(require("org.actions").list.review)
      ok(require("org.actions").list.review_next)
      ok(require("org.commands").extra.review)
      eq("<prefix>W", require("org.config").opts.mappings.global.review)
      eq(true, require("org.extensions").enabled("review"))
      setup(nil)
      eq(nil, require("org.actions").list.review)
      eq(false, require("org.extensions").enabled("review"))
    end)

    it("merges user options over the defaults", function()
      setup({ upcoming_days = 3 })
      local o = require("org.extensions").opts("review")
      eq(3, o.upcoming_days)
      eq({ "WAITING" }, o.waiting_keywords)
    end)
  end)

  describe("steps", function()
    it("resolves builtin names, overrides, custom tables and functions", function()
      local fn = function()
        return {}
      end
      local list, errors = steps.resolve({
        "inbox",
        { "waiting", title = "Blocked" },
        { name = "mine", title = "Mine", items = fn },
        fn,
        "nope",
        { "bogus" },
      })
      eq(4, #list)
      eq({ "inbox", "Empty the inbox" }, { list[1].name, list[1].title })
      eq({ "waiting", "Blocked" }, { list[2].name, list[2].title })
      ok(list[2].items)
      eq({ "mine", "Mine" }, { list[3].name, list[3].title })
      eq("step4", list[4].name)
      eq(fn, list[4].items)
      eq({ "unknown review step: nope", "unknown review step: bogus" }, errors)
    end)

    it("uses the default order without a list", function()
      local list = steps.resolve(nil)
      eq(
        steps.order,
        vim.tbl_map(function(s)
          return s.name
        end, list)
      )
    end)

    describe("builtins", function()
      local ctx
      before_each(function()
        setup({})
        ctx = {
          opts = require("org.extensions").opts("review"),
          today = date.today(),
          now = date.now(),
          files = require("org.files").agenda_files(),
          state = {},
        }
      end)

      it("inbox: the top-level entries of the default notes file", function()
        eq({ "Call the dentist", "Idea: learn Rust", "Buy milk" }, titles(steps.builtin.inbox.items(ctx)))
      end)

      it("inbox: one or several files of the inbox option", function()
        ctx.opts = vim.tbl_extend("force", ctx.opts, { inbox = { dir .. "/inbox.org", dir .. "/work.org" } })
        eq(5, #steps.builtin.inbox.items(ctx))
      end)

      it("stuck: projects without a next action", function()
        eq({ "Tax return" }, titles(steps.builtin.stuck.items(ctx)))
      end)

      it("waiting: entries in a waiting state", function()
        eq({ "Reply from Bob" }, titles(steps.builtin.waiting.items(ctx)))
        ctx.opts = vim.tbl_extend("force", ctx.opts, { waiting_keywords = { "WAITING", "SOMEDAY" } })
        eq({ "Reply from Bob", "Sail around the world" }, titles(steps.builtin.waiting.items(ctx)))
      end)

      it("overdue: open entries dated before today, oldest first", function()
        local items = steps.builtin.overdue.items(ctx)
        eq({ "Weekly sync", "Pay rent" }, titles(items))
        eq("scheduled 7 d ago", items[1].info)
        eq("due 4 d ago", items[2].info)
      end)

      it("upcoming: the next days, with repeats, in date order", function()
        local items = steps.builtin.upcoming.items(ctx)
        eq({ "Weekly sync", "Dentist appointment" }, titles(items))
        eq("Tue 09-29 scheduled", items[1].info)
        eq("Sat 10-03 10:00 scheduled", items[2].info)
        ctx.opts = vim.tbl_extend("force", ctx.opts, { upcoming_days = 3 })
        eq({ "Weekly sync" }, titles(steps.builtin.upcoming.items(ctx)))
      end)

      it("someday: by tag or keyword, done entries left out", function()
        eq({ "Learn guitar", "Sail around the world" }, titles(steps.builtin.someday.items(ctx)))
      end)

      it("clock: time of the past week by entry, and the total", function()
        local items = steps.builtin.clock.items(ctx)
        eq({ "Write report", "Plan trip" }, titles(items))
        eq({ "2:30", "0:45" }, { items[1].info, items[2].info })
        eq({ "Clocked in the last 7 days: 3:15" }, steps.builtin.clock.lines(ctx))
        ctx.opts = vim.tbl_extend("force", ctx.opts, { clock_top = 1 })
        eq(1, #steps.builtin.clock.items(ctx))
      end)
    end)
  end)

  describe("session", function()
    it("opens a float at the first step with a progress line", function()
      setup({})
      review.start()
      local s = review.session
      ok(s)
      eq("editor", vim.api.nvim_win_get_config(s.win).relative)
      local lines = buf_lines(s.buf)
      ok(lines[1]:find("Step 1 of 8 · Empty the inbox", 1, true), lines[1])
      ok(lines[1]:find("◉ ○ ○", 1, true))
      ok(row_of("Call the dentist"))
      ok(row_of("Buy milk"))
      -- the cursor is on the first item
      eq(row_of("Call the dentist"), vim.api.nvim_win_get_cursor(s.win)[1])
    end)

    it("moves between steps with next and prev, and stops at the ends", function()
      setup({})
      review.start()
      review.prev()
      eq(1, review.session.index)
      review.next()
      eq(2, review.session.index)
      ok(buf_lines(review.session.buf)[1]:find("Stuck projects", 1, true))
      ok(buf_lines(review.session.buf)[1]:find("● ◉ ○", 1, true))
      ok(row_of("Tax return"))
      review.goto_step(99)
      eq(8, review.session.index)
      review.next()
      eq(8, review.session.index)
      review.prev()
      eq(7, review.session.index)
      ok(row_of("Clocked in the last 7 days: 3:15"))
    end)

    it("says when a step has nothing", function()
      setup({ steps = { "inbox", { "waiting", waiting_keywords = {} } }, waiting_keywords = { "NONE" } })
      review.start("waiting")
      ok(row_of("Nothing here."))
    end)

    it("starts at a step given by name or number, and warns about unknown ones", function()
      setup({})
      review.start("overdue")
      eq(4, review.session.index)
      review.quit()
      review.start("6")
      eq("someday", review.session.steps[review.session.index].name)
      review.quit()
      local warned
      local warn = utils.warn
      utils.warn = function(m)
        warned = m
      end
      review.start("nope")
      utils.warn = warn
      eq("Unknown review step: nope", warned)
    end)

    it("saves its state and resumes where it was left", function()
      setup({})
      review.start()
      review.next()
      review.next()
      review.quit()
      eq(nil, review.session)
      local state = vim.json.decode(table.concat(read("review.json"), "\n"))
      eq("waiting", state.step)
      eq("2026-09-29 Tue 10:00", state.started)
      review.start()
      eq(3, review.session.index)
      review.quit()
      review.start("restart")
      eq(1, review.session.index)
    end)

    it("the actions work on the running review", function()
      setup({})
      require("org.actions").run("review")
      ok(review.session)
      require("org.actions").run("review_next")
      eq(2, review.session.index)
      require("org.actions").run("review_prev")
      eq(1, review.session.index)
      require("org.actions").run("review_quit")
      eq(nil, review.session)
    end)

    it(":Org review takes a step", function()
      setup({})
      vim.cmd("Org review upcoming")
      eq("upcoming", review.session.steps[review.session.index].name)
    end)

    it(":Org review completes restart and the step names", function()
      setup({ steps = { "inbox", { name = "mine", items = function() end }, "reflect" } })
      eq({ "restart", "inbox", "mine", "reflect" }, require("org.commands").complete("", "Org review "))
      eq({ "restart", "reflect" }, require("org.commands").complete("re", "Org review re"))
    end)

    it("maps keys in the review buffer", function()
      setup({})
      review.start()
      local buf = review.session.buf
      for _, k in ipairs({ "n", "p", "<CR>", "r", "s", "t", "d", "x", "F", "<Esc>" }) do
        ok(
          vim.api.nvim_buf_call(buf, function()
            return vim.fn.maparg(k, "n") ~= ""
          end),
          "no key " .. k
        )
      end
      vim.api.nvim_feedkeys("n", "x", false)
      eq(2, review.session.index)
    end)
  end)

  describe("processing", function()
    before_each(function()
      setup({})
      review.start()
    end)

    it("skip marks the entry and moves on", function()
      cursor_on("Call the dentist")
      review.act("skip")
      ok(buf_lines(review.session.buf)[row_of("Call the dentist")]:find("(skipped)", 1, true))
      eq(1, review.session.state.stats.skipped)
      eq(row_of("Idea: learn Rust"), vim.api.nvim_win_get_cursor(review.session.win)[1])
      -- skipping again does not count twice
      cursor_on("Call the dentist")
      review.act("skip")
      eq(1, review.session.state.stats.skipped)
    end)

    it("delete removes the entry and saves the file", function()
      cursor_on("Buy milk")
      review.act("delete")
      eq({ "* Call the dentist", "* Idea: learn Rust" }, read("inbox.org"))
      eq(nil, row_of("Buy milk"))
      eq(1, review.session.state.stats.deleted)
    end)

    it("delete asks first with confirm_delete", function()
      setup({ confirm_delete = true })
      review.start()
      local confirm = utils.confirm
      utils.confirm = function()
        return false
      end
      cursor_on("Buy milk")
      review.act("delete")
      utils.confirm = confirm
      eq(INBOX, read("inbox.org"))
    end)

    it("schedule sets SCHEDULED from the date prompt", function()
      local cal = require("org.calendar")
      local pick = cal.pick
      cal.pick = function()
        return date.parse("<2026-10-02 Fri>")
      end
      cursor_on("Call the dentist")
      review.act("schedule")
      cal.pick = pick
      eq({ "* Call the dentist", "SCHEDULED: <2026-10-02 Fri>" }, vim.list_slice(read("inbox.org"), 1, 2))
      eq(1, review.session.state.stats.scheduled)
    end)

    it("deadline sets DEADLINE; a cancelled prompt changes nothing", function()
      local cal = require("org.calendar")
      local pick = cal.pick
      cal.pick = function()
        return nil
      end
      cursor_on("Buy milk")
      review.act("deadline")
      eq(INBOX, read("inbox.org"))
      cal.pick = function()
        return date.parse("<2026-10-05 Mon>")
      end
      cursor_on("Buy milk")
      review.act("deadline")
      cal.pick = pick
      eq("DEADLINE: <2026-10-05 Mon>", read("inbox.org")[4])
    end)

    it("todo sets the state chosen in a list", function()
      local select = vim.ui.select
      local offered
      vim.ui.select = function(items, _, cb)
        offered = items
        cb("NEXT")
      end
      cursor_on("Idea: learn Rust")
      utils.run(review.act, "todo")
      vim.wait(1000, function()
        return review.session.state.stats.todo == 1
      end)
      vim.ui.select = select
      eq({ "TODO", "NEXT", "WAITING", "SOMEDAY", "DONE", "(none)" }, offered)
      eq("* NEXT Idea: learn Rust", read("inbox.org")[2])
      eq(1, review.session.state.stats.todo)
    end)

    it("refile moves the entry to the chosen target", function()
      local refile = require("org.refile")
      local pick = refile.pick_target
      refile.pick_target = function()
        return {
          filename = dir .. "/work.org",
          lnum = 7,
          olp = { "Tasks" },
          level = 1,
          label = "Tasks",
          path = "Tasks/",
        }
      end
      cursor_on("Call the dentist")
      review.act("refile")
      refile.pick_target = pick
      eq({ "* Idea: learn Rust", "* Buy milk" }, read("inbox.org"))
      local work = read("work.org")
      eq("** Call the dentist", work[#work])
      eq(1, review.session.state.stats.refiled)
      eq(nil, row_of("Call the dentist"))
    end)

    it("acts on the listed entry even when one with the same title moved into its line", function()
      review.quit()
      vim.fn.writefile({ "* Call", "  body A", "* Call", "  body B", "* Buy milk" }, dir .. "/inbox.org")
      local buf = vim.fn.bufadd(dir .. "/inbox.org")
      vim.fn.bufload(buf)
      review.start()
      -- the file changes under the review: every entry moves down a line
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "#+TITLE: Inbox" })
      local rows = {}
      for i, l in ipairs(buf_lines(review.session.buf)) do
        if l:find("Call", 1, true) then
          rows[#rows + 1] = i
        end
      end
      vim.api.nvim_win_set_cursor(review.session.win, { rows[2], 0 })
      review.act("delete")
      eq({ "#+TITLE: Inbox", "* Call", "  body A", "* Buy milk" }, read("inbox.org"))
    end)

    it("refuses to guess between entries with the same title", function()
      review.quit()
      vim.fn.writefile({ "* Call", "  body A", "* Call", "  body B" }, dir .. "/inbox.org")
      review.start()
      -- changed on disk after the review listed it (no buffer to follow)
      local changed = { "#+TITLE: Inbox", "* Call", "  body A", "* Call", "  body B" }
      vim.fn.writefile(changed, dir .. "/inbox.org")
      local warned
      local warn = utils.warn
      utils.warn = function(m)
        warned = m
      end
      cursor_on("Call")
      review.act("delete")
      utils.warn = warn
      eq(changed, read("inbox.org"))
      ok(warned and warned:find("Several entries", 1, true), warned)
    end)

    it("open goes to the entry and pauses the review", function()
      review.next()
      cursor_on("Tax return")
      review.act("open")
      eq(nil, review.session)
      eq(dir .. "/work.org", vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
      eq(4, vim.api.nvim_win_get_cursor(0)[1])
      review.start()
      eq(2, review.session.index)
    end)
  end)

  describe("custom steps", function()
    it("lists a custom step's items and runs its keys", function()
      local called
      setup({
        steps = {
          {
            name = "mine",
            title = "My step",
            description = "Custom",
            lines = function()
              return { "hello" }
            end,
            items = function(ctx)
              return { { text = "a note" }, { hl = ctx.files[1].headlines[1], path = ctx.files[1].filename, lnum = 1 } }
            end,
            keys = {
              X = function(item)
                called = item
              end,
            },
          },
          function()
            return { { text = "from a function" } }
          end,
        },
      })
      review.start()
      ok(buf_lines(review.session.buf)[1]:find("My step", 1, true))
      ok(row_of("hello"))
      ok(row_of("a note"))
      cursor_on("Call the dentist")
      vim.api.nvim_feedkeys("X", "x", false)
      eq("Call the dentist", called.hl.title)
      review.next()
      ok(row_of("from a function"))
      -- the custom key is gone on the next step
      eq(
        "",
        vim.api.nvim_buf_call(review.session.buf, function()
          return vim.fn.maparg("X", "n")
        end)
      )
    end)

    it("shows the error of a failing step", function()
      setup({
        steps = {
          function()
            error("boom")
          end,
        },
      })
      review.start()
      ok(row_of("boom"))
    end)
  end)

  describe("finishing", function()
    it("answers questions and logs the review in a week date tree", function()
      setup({})
      review.start("reflect")
      local input = utils.input_note
      utils.input_note = function(o)
        return o.purpose == "What went well this week?" and "Shipped the release" or nil
      end
      cursor_on("What went well this week?")
      review.open()
      utils.input_note = input
      eq("Shipped the release", review.session.state.notes["1"])
      ok(row_of("    Shipped the release"))
      review.session.state.stats.deleted = 2
      review.session.state.counts.overdue = 2
      local bufnr = review.finish()
      eq(nil, review.session)
      eq(0, vim.fn.filereadable(dir .. "/review.json"))
      ok(bufnr)
      -- the new log starts with its date tree (no empty first line)
      local log = read("review.org")
      eq("* 2026", log[1])
      eq("** 2026-W40", log[2])
      eq("*** 2026-09-29 Tuesday", log[3])
      eq("**** Weekly review :review:", log[4]:gsub("%s+", " "))
      eq("[2026-09-29 Tue 10:00]", vim.trim(log[5]))
      eq("- Inbox: 2 processed (0 refiled, 0 scheduled, 0 state changes, 2 deleted), 0 skipped", vim.trim(log[6]))
      ok(vim.trim(log[7]):find("Overdue: 2", 1, true))
      eq("- Clocked in the last 7 days: 3:15", vim.trim(log[8]))
      eq("***** What went well this week?", log[9])
      eq("Shipped the release", vim.trim(log[10]))
      -- the log is shown at the new entry
      eq(dir .. "/review.org", vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
      eq(4, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("keeps answer lines from becoming headlines", function()
      setup({ open_log = false })
      review.start("reflect")
      review.session.state.notes["2"] = "* not a heading\nmore"
      review.finish()
      local log = read("review.org")
      eq("***** What could have gone better?", log[8])
      eq(" * not a heading", log[9])
      eq("more", log[10])
    end)

    it("indents the log entry for its level with adapt_indentation", function()
      require("org").setup({
        org_directory = dir,
        agenda_files = { dir .. "/inbox.org" },
        default_notes_file = dir .. "/inbox.org",
        adapt_indentation = true,
        extensions = {
          review = { state_file = dir .. "/review.json", log_file = dir .. "/review.org", open_log = false },
        },
      })
      review.start("reflect")
      review.session.state.notes["1"] = "Shipped it\n* and more"
      review.finish()
      local log = read("review.org")
      eq("**** Weekly review :review:", log[4]:gsub("%s+", " "))
      eq("     [2026-09-29 Tue 10:00]", log[5])
      eq("     - Inbox: 0 processed (0 refiled, 0 scheduled, 0 state changes, 0 deleted), 0 skipped", log[6])
      eq("***** What went well this week?", log[#log - 2])
      eq("      Shipped it", log[#log - 1])
      eq("      * and more", log[#log])
    end)

    it("uses a day tree with log_tree_type = day", function()
      setup({ log_tree_type = "day", open_log = false })
      review.start()
      review.finish()
      local log = read("review.org")
      eq({ "* 2026", "** 2026-09 September", "*** 2026-09-29 Tuesday" }, vim.list_slice(log, 1, 3))
    end)

    it("captures with capture_template instead", function()
      setup({ capture_template = "r" })
      review.start()
      local capture = require("org.capture")
      local orig = capture.capture
      local got
      capture.capture = function(key, o)
        got = { key, o.initial }
      end
      review.finish()
      capture.capture = orig
      eq("r", got[1])
      ok(got[2]:find("^%[2026%-09%-29 Tue 10:00%]\n%- Inbox: 0 processed"), got[2])
      eq(0, vim.fn.filereadable(dir .. "/review.org"))
    end)
  end)

  it("teardown closes the window and keeps the state", function()
    setup({})
    review.start()
    review.next()
    local win = review.session.win
    setup(nil)
    eq(nil, review.session)
    eq(false, vim.api.nvim_win_is_valid(win))
    setup({})
    review.start()
    eq(2, review.session.index)
  end)

  it("health reports the inbox and the log", function()
    setup({ steps = { "inbox", "nope" } })
    local out = {}
    local h = {
      ok = function(m)
        out[#out + 1] = "ok " .. m
      end,
      warn = function(m)
        out[#out + 1] = "warn " .. m
      end,
      error = function(m)
        out[#out + 1] = "error " .. m
      end,
      info = function(m)
        out[#out + 1] = "info " .. m
      end,
    }
    review.health(h, require("org.extensions").opts("review"))
    eq("error review: unknown review step: nope", out[1])
    eq("ok review inbox: " .. dir .. "/inbox.org", out[2])
    eq("info review log: " .. dir .. "/review.org", out[3])
  end)
end)

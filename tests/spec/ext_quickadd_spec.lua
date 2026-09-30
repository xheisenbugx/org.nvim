local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local date = require("org.date")
local utils = require("org.utils")
local capture = require("org.capture")

local function setup(qa, extra)
  require("org").setup(vim.tbl_extend("force", {
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
    extensions = qa ~= nil and { quickadd = qa } or nil,
  }, extra or {}))
end

-- Tuesday 2026-09-29 10:00
local NOW = date.Date.new({ year = 2026, month = 9, day = 29, hour = 10, min = 0 })
local KW = { keywords = { "TODO", "NEXT", "WAITING", "DONE" } }

local function P(text, o)
  return require("org.extensions.quickadd.parse").parse(text, NOW, vim.tbl_extend("force", KW, o or {}))
end

local function run(fn, ...)
  local res
  local args = { ... }
  ok(
    utils.run(function()
      res = { fn(unpack(args)) }
    end),
    "coroutine did not finish"
  )
  return unpack(res or {})
end

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

describe("quickadd tokenizer", function()
  local tok = require("org.extensions.quickadd.parse").tokenize
  it("splits on blanks", function()
    eq({ "a", "b", "c" }, vim.tbl_map(function(t)
      return t.text
    end, tok("  a b\tc ")))
  end)
  it("groups quoted words and marks them literal", function()
    local t = tok('say "hello world" \'fri 3pm\'')
    eq({ "say", "hello world", "fri 3pm" }, vim.tbl_map(function(x)
      return x.text
    end, t))
    eq({ true, false, false }, vim.tbl_map(function(x)
      return x.plain
    end, t))
  end)
  it("keeps apostrophes inside words and unclosed quotes", function()
    eq("Bob's", tok("Bob's car")[1].text)
    eq('"open', tok('"open quote')[1].text)
  end)
  it("escapes with a backslash", function()
    local t = tok("\\#tag a\\ b")
    eq("#tag", t[1].text)
    eq(nil, t[1].sigil)
    eq("a b", t[2].text)
  end)
  it("quotes after a sigil", function()
    local t = tok('@"Big Project"')
    eq("@Big Project", t[1].text)
    eq("@", t[1].sigil)
  end)
end)

describe("quickadd parse", function()
  it("parses the full example", function()
    local r = P("Call Bob fri 3pm #work #phone !A ~30m @Inbox due mon every week")
    eq("Call Bob", r.title)
    eq("TODO", r.todo)
    eq("A", r.priority)
    eq({ "work", "phone" }, r.tags)
    eq(30, r.effort)
    eq("<2026-10-02 Fri 15:00 +1w>", r.planning.scheduled)
    eq("<2026-10-05 Mon>", r.planning.deadline)
    eq({ raw = "Inbox", heading = "Inbox" }, r.target)
  end)

  it("keeps a plain title", function()
    local r = P("Buy milk")
    eq("Buy milk", r.title)
    eq({}, r.planning)
    eq({}, r.tags)
    eq(nil, r.priority)
    eq(nil, r.effort)
    eq(nil, r.target)
  end)

  -- dates
  local cases = {
    { "x today", "<2026-09-29 Tue>" },
    { "x tomorrow", "<2026-09-30 Wed>" },
    { "x tmr", "<2026-09-30 Wed>" },
    { "x fri", "<2026-10-02 Fri>" },
    { "x friday", "<2026-10-02 Fri>" },
    { "x tue", "<2026-10-06 Tue>" }, -- a weekday name is never today
    { "x thurs", "<2026-10-01 Thu>" },
    { "x fri 3pm", "<2026-10-02 Fri 15:00>" },
    { "x fri at 3pm", "<2026-10-02 Fri 15:00>" },
    { "x 3pm fri", "<2026-10-02 Fri 15:00>" },
    { "x at 14:30", "<2026-09-29 Tue 14:30>" },
    { "x 9am-10:30am", "<2026-09-29 Tue 09:00-10:30>" },
    { "x 14:00-15:00 tomorrow", "<2026-09-30 Wed 14:00-15:00>" },
    { "x +2w", "<2026-10-13 Tue>" },
    { "x +3d 9am", "<2026-10-02 Fri 09:00>" },
    { "x in 3 days", "<2026-10-02 Fri>" },
    { "x in a week", "<2026-10-06 Tue>" },
    { "x next week", "<2026-10-06 Tue>" },
    { "x next month", "<2026-10-29 Thu>" },
    { "x next fri", "<2026-10-02 Fri>" },
    { "x 2026-12-24", "<2026-12-24 Thu>" },
    { "x 12/24", "<2026-12-24 Thu>" },
    { "x 24.12.", "<2026-12-24 Thu>" },
    { "x dec 24", "<2026-12-24 Thu>" },
    { "x 24 dec", "<2026-12-24 Thu>" },
    { "x sep 1", "<2027-09-01 Wed>" }, -- past: next year
    { "x oct 1st", "<2026-10-01 Thu>" },
    { "x noon", "<2026-09-29 Tue 12:00>" },
    { "x w45", "<2026-11-02 Mon>" },
  }
  for _, c in ipairs(cases) do
    it("reads the date in " .. c[1], function()
      local r = P(c[1])
      eq("x", r.title)
      eq(c[2], r.planning.scheduled)
    end)
  end

  it("leaves words that only look like dates", function()
    eq("May call Bob", P("May call Bob").title)
    eq(nil, P("May call Bob").planning.scheduled)
    eq("Read chapter 5", P("Read chapter 5").title)
    eq("Look at this", P("Look at this").title)
    eq("Plan next steps", P("Plan next steps").title)
    eq("in 3 steps", P("in 3 steps").title)
  end)

  it("puts dates after due in DEADLINE", function()
    local r = P("Report due fri 5pm")
    eq("Report", r.title)
    eq(nil, r.planning.scheduled)
    eq("<2026-10-02 Fri 17:00>", r.planning.deadline)
    r = P("Taxes by apr 15")
    eq("<2027-04-15 Thu>", r.planning.deadline)
    eq("Pay due diligence", P("Pay due diligence").title)
  end)

  it("uses date_kind for dates without due", function()
    local r = P("Report fri", { date_kind = "deadline" })
    eq("<2026-10-02 Fri>", r.planning.deadline)
    eq(nil, r.planning.scheduled)
  end)

  it("keeps SCHEDULED and DEADLINE apart", function()
    local r = P("Draft mon due fri")
    eq("<2026-10-05 Mon>", r.planning.scheduled)
    eq("<2026-10-02 Fri>", r.planning.deadline)
  end)

  -- repeaters
  local reps = {
    { "x every day", "<2026-09-29 Tue +1d>" },
    { "x every week", "<2026-09-29 Tue +1w>" },
    { "x every month", "<2026-09-29 Tue +1m>" },
    { "x every year", "<2026-09-29 Tue +1y>" },
    { "x every 2w", "<2026-09-29 Tue +2w>" },
    { "x every 3 days", "<2026-09-29 Tue +3d>" },
    { "x every other week", "<2026-09-29 Tue +2w>" },
    { "x every mon", "<2026-10-05 Mon +1w>" },
    { "x every tue", "<2026-09-29 Tue +1w>" }, -- today when it is that day
    { "x every mon 9am", "<2026-10-05 Mon 09:00 +1w>" },
    { "x every! 2w", "<2026-09-29 Tue .+2w>" },
    { "x fri every week", "<2026-10-02 Fri +1w>" },
    { "x every week fri", "<2026-10-02 Fri +1w>" },
  }
  for _, c in ipairs(reps) do
    it("reads the repeater in " .. c[1], function()
      local r = P(c[1])
      eq("x", r.title)
      eq(c[2], r.planning.scheduled)
    end)
  end

  it("repeats a deadline when there is only a deadline", function()
    local r = P("Rent every month due oct 1")
    eq("<2026-10-01 Thu +1m>", r.planning.deadline)
    eq(nil, r.planning.scheduled)
  end)

  it("writes weekday and multi-day repeats as diary sexps", function()
    eq("<%%(memq (calendar-day-of-week date) '(1 2 3 4 5))>", P("x every weekday").planning.scheduled)
    eq(
      '<%%(when (memq (calendar-day-of-week date) \'(1 2 3 4 5)) "09:30")>',
      P("x every weekday 9:30").planning.scheduled
    )
    eq("<%%(memq (calendar-day-of-week date) '(0 6))>", P("x every weekend").planning.scheduled)
    eq(
      '<%%(when (memq (calendar-day-of-week date) \'(1 4)) "07:00")>',
      P("x every mon and thu at 7am").planning.scheduled
    )
    eq("<%%(memq (calendar-day-of-week date) '(1 3 5))>", P("x every mon,wed,fri").planning.scheduled)
  end)

  it("keeps every without a spec", function()
    eq("every little thing", P("every little thing").title)
  end)

  -- tags
  it("reads tags", function()
    eq({ "work", "phone" }, P("x #work #phone").tags)
    eq({ "work" }, P("x #work #work").tags)
    eq({ "a_b", "c@d" }, P("x #a_b #c@d").tags)
  end)
  it("leaves numbers and escaped tags in the title", function()
    local r = P("Fix bug #42 \\#notatag")
    eq("Fix bug #42 #notatag", r.title)
    eq({}, r.tags)
    eq("C# book", P("C# book").title)
  end)

  -- priorities
  it("reads priorities", function()
    eq("A", P("x !A").priority)
    eq("B", P("x !b").priority)
    eq("C", P("x !3").priority)
    eq("A", P("x p1").priority)
    eq("B", P("x p2").priority)
    eq("C", P("x p3").priority)
  end)
  it("leaves priorities out of range", function()
    local r = P("x !Z p4 !")
    eq(nil, r.priority)
    eq("x !Z p4 !", r.title)
    eq("E", P("x p5", { priority_lowest = "E" }).priority)
  end)

  -- effort
  it("reads efforts", function()
    eq(30, P("x ~30m").effort)
    eq(60, P("x ~1h").effort)
    eq(90, P("x ~1h30").effort)
    eq(90, P("x ~1h30m").effort)
    eq(90, P("x ~1:30").effort)
    eq(45, P("x ~45").effort)
    eq(90, P("x ~1.5h").effort)
    eq("x ~soon", P("x ~soon").title)
  end)

  -- keywords
  it("overrides the keyword", function()
    eq("NEXT", P("x *NEXT").todo)
    eq("WAITING", P("x *waiting").todo)
    eq(nil, P("x *-").todo)
    eq("x *bold*", P("x *bold*").title)
    eq(nil, P("x", { keyword = false }).todo)
  end)

  -- targets
  it("reads targets", function()
    eq({ raw = "Inbox", heading = "Inbox" }, P("x @Inbox").target)
    eq({ raw = "work/Projects", file = "work", heading = "Projects" }, P("x @work/Projects").target)
    eq({ raw = "work/", file = "work" }, P("x @work/").target)
    eq({ raw = "Big Project", heading = "Big Project" }, P('x @"Big Project"').target)
    eq("mail bob@example.com", P("mail bob@example.com").title)
    eq("x @", P("x @").title)
  end)

  -- escaping
  it("keeps quoted and escaped words literal", function()
    local r = P('Watch "Friday Night Lights" \\fri \\!A \\~30m')
    eq("Watch Friday Night Lights fri !A ~30m", r.title)
    eq({}, r.planning)
    eq(nil, r.priority)
    eq(nil, r.effort)
    eq("Read due fri", P("Read 'due fri'").title)
  end)

  it("does not change date.now", function()
    local before = date.now
    P("x fri")
    eq(before, date.now)
  end)
end)

describe("quickadd entries", function()
  local qa = require("org.extensions.quickadd")
  before_each(function()
    setup({})
  end)
  after_each(function()
    setup(nil)
  end)

  it("builds the entry lines", function()
    local item = qa.parse("Call Bob fri 3pm #work !A ~30m due mon", NOW)
    local lines = qa.lines(item, 1)
    ok(lines[1]:match("^%* TODO %[#A%] Call Bob%s+:work:$"), lines[1])
    eq({
      "DEADLINE: <2026-10-05 Mon> SCHEDULED: <2026-10-02 Fri 15:00>",
      ":PROPERTIES:",
      ":Effort:   0:30",
      ":END:",
    }, vim.list_slice(lines, 2))
  end)

  it("adds under a fuzzy-matched heading and saves", function()
    local d = tmpdir()
    vim.fn.writefile({ "* Inbox", "* Projects", "** Old" }, d .. "/work.org")
    vim.fn.writefile({}, d .. "/notes.org")
    setup({}, { org_directory = d, agenda_files = { d .. "/*.org" }, default_notes_file = d .. "/notes.org" })
    local buf, lnum = qa.add_text("Draft plan fri @proj", NOW)
    ok(buf)
    local lines = vim.fn.readfile(d .. "/work.org")
    eq("** TODO Draft plan", lines[lnum])
    eq("** Old", lines[lnum - 1])
    ok(lines[lnum + 1]:match("SCHEDULED: <2026%-10%-02 Fri>"))
  end)

  it("resolves file/heading, outline paths and the default file", function()
    local d = tmpdir()
    vim.fn.writefile({ "* Inbox", "* Projects", "** Inbox" }, d .. "/work.org")
    vim.fn.writefile({ "* Inbox" }, d .. "/home.org")
    setup({}, { org_directory = d, agenda_files = { d .. "/*.org" }, default_notes_file = d .. "/inbox.org" })
    local loc = qa.resolve_target({ raw = "home/Inbox", file = "home", heading = "Inbox" })
    eq(d .. "/home.org", loc.filename)
    eq(1, loc.lnum)
    loc = qa.resolve_target({ raw = "Projects/Inbox", heading = "Projects/Inbox" })
    eq(d .. "/work.org", loc.filename)
    eq(3, loc.lnum)
    loc = qa.resolve_target({ raw = "work/", file = "work" })
    eq(d .. "/work.org", loc.filename)
    eq(nil, loc.lnum)
    loc = qa.resolve_target({ raw = "Nowhere", heading = "Nowhere" })
    eq(d .. "/inbox.org", loc.filename)
    eq("Nowhere", loc.missing)
    loc = qa.resolve_target(nil)
    eq(d .. "/inbox.org", loc.filename)
  end)

  it("creates the configured headline in the default file", function()
    local d = tmpdir()
    setup({ file = "tasks.org", headline = "Inbox" }, { org_directory = d, agenda_files = { d .. "/*.org" } })
    qa.add_text("First #a", NOW)
    qa.add_text("Second", NOW)
    local lines = vim.fn.readfile(d .. "/tasks.org")
    eq("* Inbox", lines[1])
    ok(lines[2]:match("^%*%* TODO First%s+:a:$"))
    eq("** TODO Second", lines[3])
  end)

  it("adds :CREATED: with created = true and no keyword with keyword = false", function()
    local d = tmpdir()
    setup({ created = true, keyword = false }, { org_directory = d, default_notes_file = d .. "/n.org" })
    qa.add_text("Note", NOW)
    eq({ "* Note", ":PROPERTIES:", ":CREATED:  [2026-09-29 Tue 10:00]", ":END:" }, vim.fn.readfile(d .. "/n.org"))
  end)

  it("runs as an action and a command, asking with vim.ui.input", function()
    local d = tmpdir()
    setup({}, { org_directory = d, default_notes_file = d .. "/n.org" })
    local saved = vim.ui.input
    vim.ui.input = function(o, cb)
      eq("Quick add: ", o.prompt)
      cb("Asked #x")
    end
    local okk, err = pcall(function()
      require("org.actions").run("quickadd")
      vim.wait(200, function()
        return vim.fn.filereadable(d .. "/n.org") == 1
      end)
    end)
    vim.ui.input = saved
    assert(okk, err)
    ok(vim.fn.readfile(d .. "/n.org")[1]:match("^%* TODO Asked%s+:x:$"))
    require("org.commands").run({ fargs = { "quickadd", "Typed", "!B" } })
    eq("* TODO [#B] Typed", vim.fn.readfile(d .. "/n.org")[2])
  end)

  it("registers the action, command and key", function()
    ok(require("org.actions").list.quickadd)
    ok(require("org.commands").extra.quickadd)
    eq("<prefix>q", require("org.config").opts.mappings.global.quickadd)
  end)

  it("opens a prompt float with a live preview", function()
    vim.cmd("enew!")
    local got = "unset"
    local wins = #vim.api.nvim_list_wins()
    local buf = qa.open_prompt("Call fri #a", function(v)
      got = v
    end)
    eq(wins + 2, #vim.api.nvim_list_wins())
    local preview
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if b ~= buf and vim.api.nvim_win_get_config(w).relative ~= "" then
        preview = vim.api.nvim_buf_get_lines(b, 0, -1, false)
      end
    end
    ok(preview[1]:match("^TODO Call  :a:$"), vim.inspect(preview))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Other !A" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if b ~= buf and vim.api.nvim_win_get_config(w).relative ~= "" then
        preview = vim.api.nvim_buf_get_lines(b, 0, -1, false)
      end
    end
    eq("TODO [#A] Other", preview[1])
    vim.fn.maparg("<CR>", "n", false, true).callback()
    eq("Other !A", got)
    eq(wins, #vim.api.nvim_list_wins())
    vim.cmd("stopinsert")
  end)

  it("previews the parsed entry", function()
    local rows = qa.preview_lines("Call fri #a !A ~1h @Nowhere")
    local text = vim.tbl_map(function(r)
      return table.concat(vim.tbl_map(function(c)
        return c[1]
      end, r))
    end, rows)
    eq("TODO [#A] Call  :a:", text[1])
    ok(text[2]:match("^SCHEDULED: <"))
    eq("Effort:     1:00", text[3])
    ok(text[4]:match("no match for @Nowhere"))
  end)
end)

describe("quickadd capture templates", function()
  local saved_now
  before_each(function()
    saved_now = date.now
    date.now = function()
      return NOW:clone()
    end
  end)
  after_each(function()
    date.now = saved_now
    setup(nil)
  end)

  local function cap(p, template, extra)
    local tpl = { target = p, template = template, immediate_finish = true, quickadd = true }
    return run(capture.capture, vim.tbl_extend("force", tpl, extra or {}))
  end

  it("parses the headline of a quickadd template", function()
    setup({})
    local p = vim.fn.tempname() .. ".org"
    cap(p, "* TODO Call Bob fri 3pm #phone !A ~30m\n  Some notes")
    local lines = vim.fn.readfile(p)
    ok(lines[1]:match("^%* TODO %[#A%] Call Bob%s+:phone:$"), lines[1])
    eq("SCHEDULED: <2026-10-02 Fri 15:00>", lines[2])
    eq({ ":PROPERTIES:", ":Effort:   0:30", ":END:", "  Some notes" }, vim.list_slice(lines, 3, 6))
  end)

  it("merges with the template's planning and properties", function()
    setup({})
    local p = vim.fn.tempname() .. ".org"
    cap(p, "* Pay rent due oct 1 every month :home:\n  SCHEDULED: <2026-09-30 Wed>\n  :PROPERTIES:\n  :A: 1\n  :END:")
    local lines = vim.fn.readfile(p)
    ok(lines[1]:match("^%* Pay rent%s+:home:$"), lines[1])
    eq("  DEADLINE: <2026-10-01 Thu +1m> SCHEDULED: <2026-09-30 Wed>", lines[2])
    eq({ "  :PROPERTIES:", "  :A: 1", "  :END:" }, vim.list_slice(lines, 3, 5))
  end)

  it("leaves templates without quickadd alone", function()
    setup({})
    local p = vim.fn.tempname() .. ".org"
    cap(p, "* Call Bob fri #x", { quickadd = false })
    eq({ "* Call Bob fri #x" }, vim.fn.readfile(p))
  end)

  it("is inert when the extension is off", function()
    setup(nil)
    eq(nil, capture.store_filters.quickadd)
    eq(0, vim.tbl_count(capture.store_filters))
    local p = vim.fn.tempname() .. ".org"
    cap(p, "* Call Bob fri #x !A")
    eq({ "* Call Bob fri #x !A" }, vim.fn.readfile(p))
    eq(nil, require("org.actions").list.quickadd)
    eq(nil, require("org.commands").extra.quickadd)
  end)

  it("reports a failing filter without losing the capture", function()
    setup(nil)
    capture.store_filters.bad = function()
      error("boom")
    end
    local p = vim.fn.tempname() .. ".org"
    local saved = vim.notify
    local msgs = {}
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    cap(p, "* Kept")
    vim.notify = saved
    capture.store_filters.bad = nil
    eq({ "* Kept" }, vim.fn.readfile(p))
    ok(table.concat(msgs, "\n"):find("boom"))
  end)
end)

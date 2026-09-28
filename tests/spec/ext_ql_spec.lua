local date = require("org.date")
local utils = require("org.utils")

local today = date.today()
local function ts(offset, open, close)
  local s = today:add(offset, "d"):to_string({ brackets = false })
  return (open or "<") .. s .. (close or ">")
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/ql.org"
local other = dir .. "/other.org"

local LINES = {
  "#+TITLE: Q",
  "#+CATEGORY: q",
  "* TODO [#A] Write report :work:",
  "  DEADLINE: " .. ts(2),
  "  :PROPERTIES:",
  "  :Effort: 1:30",
  "  :END:",
  "  mentions the moon",
  "* NEXT Call Bob :work:phone:",
  "  SCHEDULED: " .. ts(0),
  "* DONE Old thing",
  "  CLOSED: " .. ts(-3, "[", "]"),
  "* Project :proj:",
  "  :PROPERTIES:",
  "  :CATEGORY: pr",
  "  :OWNER: me",
  "  :END:",
  "** TODO [#C] Subtask",
  "   Meeting " .. ts(5),
  "   Noted " .. ts(-1, "[", "]"),
  "   :LOGBOOK:",
  "   CLOCK: [" .. today:add(-1, "d"):to_string({ brackets = false }) .. " 10:00]--[" .. today
    :add(-1, "d")
    :to_string({ brackets = false }) .. " 11:00] =>  1:00",
  "   :END:",
  "*** WAITING Deep",
  "    #+begin_src python",
  "    print('hi')",
  "    #+end_src",
  "    See [[https://example.com][the site]]",
  "* TODO [#B] Habit :daily:",
  "  SCHEDULED: " .. ts(0, "<", " +1d>"),
  "  :PROPERTIES:",
  "  :STYLE: habit",
  "  :END:",
}

local function setup(extra)
  utils.writefile(path, LINES)
  utils.writefile(other, { "* TODO Elsewhere :work:" })
  for _, p in ipairs({ path, other }) do
    local b = utils.find_buffer(p)
    if b then
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end
  require("org").setup(vim.tbl_deep_extend("force", {
    org_directory = dir,
    agenda_files = { path, other },
    todo_keywords = { "TODO NEXT WAITING | DONE" },
    extensions = { ql = {} },
  }, extra or {}))
end

local function titles(hls)
  return vim.tbl_map(function(hl)
    return hl:plain_title()
  end, hls)
end

local function sel(q, o)
  return titles(require("org.extensions.ql").select({ path }, q, o))
end

describe("ql extension", function()
  before_each(function()
    setup()
  end)
  after_each(function()
    require("org").setup({
      org_directory = vim.fn.getcwd() .. "/tests/fixtures",
      agenda_files = { vim.fn.getcwd() .. "/tests/fixtures/*.org" },
    })
  end)

  describe("reading queries", function()
    local query = require("org.extensions.ql.query")
    it("reads sexps", function()
      eq(
        { "and", { "todo", "NEXT" }, { "not", { "tags", "x" } } },
        query.read_sexp('(and (todo "NEXT") (not (tags "x")))')
      )
      eq({ "priority", ">=", "B" }, query.read_sexp("(priority '>= \"B\")"))
      eq({ "deadline", ":to", "today", ":with-time", true }, query.read_sexp("(deadline :to today :with-time t)"))
      eq({ "ts", ":from", -7 }, query.read_sexp("(ts :from -7) ; comment"))
    end)
    it("reads plain queries", function()
      eq({ "todo" }, query.read_plain("todo:"))
      eq({ "todo", "SOMEDAY", "WAITING" }, query.read_plain("todo:SOMEDAY,WAITING"))
      eq({ "ts", ":on", "today" }, query.read_plain("ts:on=today"))
      eq(
        { "ts-active", ":from", "2017-01-01", ":to", "2018-01-01" },
        query.read_plain("ts-active:from=2017-01-01,to=2018-01-01")
      )
      eq({ "heading", "quoted phrase", "word" }, query.read_plain('heading:"quoted phrase",word'))
      eq({ "and", { "tags", "space" }, { "not", { "rifle", "moon" } } }, query.read_plain("tags:space !moon"))
      eq({ "and", { "rifle", "a b" }, { "rifle", "c" } }, query.read_plain('"a b" c'))
    end)
    it("reports errors", function()
      ok(not query.try_compile("(todo"))
      ok(not query.try_compile("(frobnicate)"))
      local _, err = query.try_compile("(frobnicate)")
      ok(err:find("frobnicate", 1, true))
    end)
  end)

  describe("predicates", function()
    it("todo, done, tags and boolean logic", function()
      eq({ "Write report", "Call Bob", "Subtask", "Deep", "Habit" }, sel("(todo)"))
      eq({ "Call Bob", "Deep" }, sel('(todo "NEXT" "WAITING")'))
      eq({ "Old thing" }, sel("(done)"))
      eq({ "Write report", "Call Bob" }, sel('(tags "work")'))
      eq({ "Call Bob" }, sel('(tags-all "work" "phone")'))
      eq({ "Project" }, sel('(tags-local "proj")'))
      eq({ "Subtask", "Deep" }, sel('(tags-inherited "proj")'))
      eq({ "Call Bob" }, sel('(tags-regexp "^ph")'))
      eq({ "Write report" }, sel('(and (todo) (not (todo "NEXT")) (tags "work"))'))
      eq({ "Call Bob", "Old thing" }, sel('(or (todo "NEXT") (done))'))
      eq({ "Call Bob" }, sel("todo:NEXT tags:work"))
      eq({ "Write report" }, sel("tags:work !phone"))
    end)
    it("priority", function()
      eq({ "Write report" }, sel('(priority "A")'))
      eq({ "Write report", "Habit" }, sel("(priority '>= \"B\")"))
      eq({ "Subtask" }, sel("(priority '< \"B\")"))
      eq({ "Write report", "Subtask", "Habit" }, sel("(priority)"))
    end)
    it("planning dates", function()
      eq({ "Write report" }, sel("(deadline)"))
      eq({ "Write report" }, sel("(deadline :from today :to 7)"))
      eq({}, sel("(deadline :to 1)"))
      eq({ "Write report" }, sel("(deadline 2)"))
      eq({ "Write report" }, sel("(deadline auto)"))
      eq({ "Call Bob", "Habit" }, sel("(scheduled :on today)"))
      eq({ "Old thing" }, sel("(closed :from -7)"))
      eq({}, sel("(closed :on today)"))
      eq({ "Write report", "Call Bob", "Old thing", "Habit" }, sel("(planning)"))
      eq({ "Call Bob", "Habit" }, sel("scheduled:to=today"))
      eq({ "Old thing" }, sel("closed:from=" .. today:add(-5, "d"):to_date_string()))
    end)
    it("timestamps and clocks", function()
      eq({ "Subtask" }, sel("(ts-active :from 4 :to 6)"))
      eq({ "Old thing", "Subtask" }, sel("(ts-inactive :from -5)"))
      eq({ "Write report", "Call Bob", "Subtask", "Habit" }, sel("(ts-active :from today)"))
      eq({ "Subtask" }, sel("(clocked)"))
      eq({ "Subtask" }, sel("(clocked :on -1)"))
      eq({}, sel("(clocked :on today)"))
      eq({}, sel("(ts :on today :with-time t)"))
    end)
    it("properties, effort, category, habit", function()
      eq({ "Project" }, sel('(property "OWNER")'))
      eq({ "Project" }, sel('(property "OWNER" "me")'))
      eq({ "Project", "Subtask", "Deep" }, sel('(property "OWNER" "me" :inherit t)'))
      eq({ "Write report" }, sel('(effort "1:30")'))
      eq({ "Write report" }, sel("(effort '> \"1:00\")"))
      eq({ "Write report" }, sel('(effort "1:00" "2:00")'))
      eq({ "Project", "Subtask", "Deep" }, sel('(category "pr")'))
      eq({ "Habit" }, sel("(habit)"))
    end)
    it("text, level, path and outline", function()
      eq({ "Call Bob" }, sel('(heading "bob")'))
      eq({ "Write report" }, sel('(heading-regexp "^wr.*rep")'))
      eq({ "Write report" }, sel('(regexp "moon")'))
      eq({ "Write report" }, sel("moon"))
      eq({ "Project", "Subtask", "Deep" }, sel('(rifle "project")'))
      eq({ "Subtask" }, sel("(level 2)"))
      eq({ "Subtask", "Deep" }, sel("(level '> 1)"))
      eq({ "Subtask", "Deep" }, sel("(level 2 3)"))
      eq(7, #sel('(path "ql.org")'))
      eq({}, sel('(path "other")'))
      eq({ "Deep" }, sel('(outline-path "proj" "deep")'))
      eq({ "Deep" }, sel('(olps "sub" "deep")'))
      eq({}, sel('(olps "proj" "deep")'))
    end)
    it("ancestors and descendants", function()
      eq({ "Subtask" }, sel('(parent (heading "project"))'))
      eq({ "Subtask", "Deep" }, sel('(ancestors (tags "proj"))'))
      eq({ "Project" }, sel('(children (todo "TODO"))'))
      eq({ "Project", "Subtask" }, sel('(descendants (todo "WAITING"))'))
      eq({ "Project", "Subtask" }, sel("(children)"))
    end)
    it("src, link, blocked and Lua predicates", function()
      eq({ "Deep" }, sel('(src :lang "python" :regexps ("print"))'))
      eq({}, sel('(src :lang "ruby")'))
      eq({ "Deep" }, sel('(link "the site")'))
      eq({ "Deep" }, sel('(link :target "example")'))
      eq({ "Habit" }, sel({ "pred", function(hl)
        return hl.title:find("Habit") ~= nil
      end }))
      eq({ "Call Bob" }, sel({ "and", { "todo", "NEXT" }, { "tags", "work" } }))
      local cfg = require("org.config").opts
      cfg.enforce_todo_dependencies = true
      local blocked = sel("(blocked)")
      cfg.enforce_todo_dependencies = false
      eq({ "Subtask" }, blocked)
    end)
  end)

  describe("sorting", function()
    local q = "(todo)"
    it("sorts by date, priority and todo", function()
      eq({ "Call Bob", "Habit", "Write report", "Subtask", "Deep" }, sel(q, { sort = "date" }))
      eq({ "Write report", "Habit", "Subtask", "Call Bob", "Deep" }, sel(q, { sort = "priority" }))
      eq({ "Write report", "Subtask", "Habit", "Call Bob", "Deep" }, sel(q, { sort = "todo" }))
      eq({ "Write report", "Call Bob", "Subtask", "Deep", "Habit" }, sel(q, { sort = "deadline" }))
    end)
    it("sorts by several keys, reverse, random and functions", function()
      eq({ "Habit", "Deep", "Subtask", "Call Bob", "Write report" }, sel(q, { sort = "reverse" }))
      eq({ "Write report", "Habit", "Subtask", "Call Bob", "Deep" }, sel(q, { sort = { "priority", "todo" } }))
      eq({ "Habit", "Call Bob", "Write report", "Subtask", "Deep" }, sel(q, { sort = { "scheduled", "priority" } }))
      eq({ "Deep", "Habit", "Subtask", "Call Bob", "Write report" }, sel(q, {
        sort = function(a, b)
          return #a.title < #b.title
        end,
      }))
      eq(5, #sel(q, { sort = "random" }))
    end)
  end)

  describe("views", function()
    local function buffer_lines()
      return vim.api.nvim_buf_get_lines(0, 0, -1, false)
    end
    it("opens a search in an agenda buffer where agenda keys work", function()
      require("org.extensions.ql").search("todo:NEXT,TODO tags:work", { sort = "priority" })
      local lines = buffer_lines()
      ok(lines[1]:find("Query: todo:NEXT,TODO tags:work", 1, true), lines[1])
      local items = {}
      for _, l in ipairs(lines) do
        if l:find("Write report") or l:find("Call Bob") or l:find("Elsewhere") then
          items[#items + 1] = l:match("(Write report)") or l:match("(Call Bob)") or l:match("(Elsewhere)")
        end
      end
      eq({ "Write report", "Call Bob", "Elsewhere" }, items)
      local view = require("org.agenda.view")
      local line
      for l, it in pairs(view.state.line_items) do
        if it.title:find("Call Bob") then
          line = l
        end
      end
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      require("org.agenda.view").actions.todo_next()
      local src = vim.api.nvim_buf_get_lines(utils.find_buffer(path), 0, -1, false)
      ok(src[9]:find("^%* WAITING Call Bob"), src[9])
    end)
    it("searches the current buffer only", function()
      vim.cmd.edit(path)
      require("org.extensions.ql").search("todo:TODO tags:work", { files = "buffer" })
      local text = table.concat(buffer_lines(), "\n")
      ok(text:find("Write report", 1, true))
      ok(not text:find("Elsewhere", 1, true))
    end)
    it("runs :Org ql_search and named views", function()
      setup({ extensions = { ql = { views = { Work = { query = '(tags "phone")', title = "Phone calls" } } } } })
      vim.cmd("Org ql_search heading:bob")
      ok(table.concat(buffer_lines(), "\n"):find("Call Bob", 1, true))
      vim.cmd("Org ql_view Work")
      local lines = buffer_lines()
      eq("Phone calls", lines[1])
      ok(table.concat(lines, "\n"):find("Call Bob", 1, true))
    end)
    it("works as an agenda custom command", function()
      setup({
        agenda = { custom_commands = { q = { type = "org-ql", query = "(habit)", description = "Habits" } } },
      })
      require("org.agenda").command("q")
      local text = table.concat(buffer_lines(), "\n")
      ok(text:find("Habit", 1, true))
      ok(not text:find("Call Bob", 1, true))
    end)
    it("shows invalid queries as errors", function()
      require("org.agenda").open({ type = "ql", query = "(nope)" })
      ok(table.concat(buffer_lines(), "\n"):find("unknown query predicate", 1, true))
    end)
  end)

  describe("dynamic block", function()
    it("writes a table of matching entries", function()
      local buf = org_buffer({
        "* TODO [#A] One",
        "  DEADLINE: <2026-10-01 Thu>",
        "* NEXT Two",
        "  :PROPERTIES:",
        "  :OWNER: ann",
        "  :END:",
        "* DONE Three",
        '#+BEGIN: org-ql :query "todo:" :sort priority'
          .. ' :columns (heading todo (priority "Pri") deadline ((property "OWNER") "Who"))',
        "#+END:",
      }, { 8, 0 })
      require("org.dblock").update_at_cursor()
      local lines = buf_lines(buf)
      -- links are aligned by their description, as they are displayed
      eq("| Heading | Todo | Pri |   Deadline | Who |", lines[9])
      eq("|---------+------+-----+------------+-----|", lines[10])
      eq("| [[*One][One]]     | TODO | A   | 2026-10-01 |     |", lines[11])
      eq("| [[*Two][Two]]     | NEXT |     |            | ann |", lines[12])
      eq("#+END:", lines[13])
    end)
    it("takes the first or last results", function()
      local buf = org_buffer({
        "* TODO a",
        "* TODO b",
        "* TODO c",
        "#+BEGIN: org-ql :query (todo) :take -1",
        "#+END:",
      }, { 4, 0 })
      require("org.dblock").update_at_cursor()
      local lines = buf_lines(buf)
      eq("| [[*c][c]]       | TODO |", lines[7])
      eq("#+END:", lines[8])
    end)
  end)

  it("does nothing when off", function()
    require("org").setup({ org_directory = dir, agenda_files = { path } })
    ok(not require("org.extensions").enabled("ql"))
    eq(nil, require("org.actions").list.ql_search)
    require("org.agenda").open({ type = "ql", query = "(todo)" })
    ok(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("not enabled", 1, true))
  end)
end)

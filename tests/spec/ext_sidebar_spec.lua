local date = require("org.date")
local utils = require("org.utils")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local today = date.today_days()
local function day(offset)
  return date.from_days(today + offset):to_string({ brackets = false })
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/today.org"
local inbox = dir .. "/inbox.org"

local LINES = {
  "* TODO Standup :team:",
  "  SCHEDULED: <" .. day(0) .. " 09:00>",
  "* TODO Review pull requests",
  "  SCHEDULED: <" .. day(0) .. " 14:00-15:00>",
  "* NEXT Ship the release",
  "  DEADLINE: <" .. day(2) .. ">",
  "  :PROPERTIES:",
  "  :Effort: 1:00",
  "  :END:",
  "* TODO Overdue report",
  "  DEADLINE: <" .. day(-1) .. ">",
  "* TODO Far deadline",
  "  DEADLINE: <" .. day(12) .. ">",
  "* WAITING Old scheduled",
  "  SCHEDULED: <" .. day(-2) .. ">",
  "* DONE Finished today",
  "  SCHEDULED: <" .. day(0) .. ">",
  "* TODO Stretch",
  "  SCHEDULED: <" .. day(0) .. " .+1d>",
  "  :PROPERTIES:",
  "  :STYLE: habit",
  "  :END:",
}

local function write()
  for _, p in ipairs({ path, inbox }) do
    local b = utils.find_buffer(p)
    if b then
      vim.api.nvim_buf_delete(b, { force = true })
    end
    require("org.files").invalidate(p)
  end
  utils.writefile(path, LINES)
  utils.writefile(inbox, { "* TODO Idea one", "* Idea two", "** Not counted", "* DONE Handled" })
end

local function setup(ext)
  require("org").setup({
    org_directory = dir,
    agenda_files = { path },
    default_notes_file = inbox,
    todo_keywords = { "TODO NEXT WAITING | DONE CANCELLED" },
    extensions = ext ~= nil and { sidebar = ext } or nil,
  })
end

local function restore()
  require("org").setup({
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
  })
end

local sidebar = require("org.extensions.sidebar")

-- a fixed time of day: 10:00 today
local real_now = date.now
local function fake_now()
  local t = date.today()
  return t:clone({ hour = 10, min = 0 })
end

local function text(st)
  return table.concat(buf_lines(st.buf), "\n")
end

local function line_of(st, s)
  for i, l in ipairs(buf_lines(st.buf)) do
    if l:find(s, 1, true) then
      return i, l
    end
  end
end

describe("sidebar extension", function()
  after_each(function()
    sidebar.close()
    restore()
  end)

  it("is off by default", function()
    setup(nil)
    eq(nil, require("org.actions").list.sidebar_toggle)
  end)

  it("registers its actions and key when enabled", function()
    setup({})
    ok(require("org.actions").list.sidebar_toggle)
    ok(require("org.actions").list.sidebar_open)
    ok(require("org.actions").list.sidebar_close)
    eq("<prefix>Vs", require("org.config").opts.mappings.global.sidebar_toggle)
  end)
end)

describe("sidebar", function()
  before_each(function()
    write()
    setup({})
    date.now = fake_now
    vim.cmd("silent! only")
    vim.cmd("enew!")
  end)
  after_each(function()
    date.now = real_now
    if require("org.clock").active() then
      require("org.clock").clock_cancel()
    end
    sidebar.close()
    restore()
  end)

  it("opens a fixed-width window at the side without taking the cursor", function()
    local prev = vim.api.nvim_get_current_win()
    local st = sidebar.open()
    eq(prev, vim.api.nvim_get_current_win())
    eq(40, vim.api.nvim_win_get_width(st.win))
    eq(true, vim.wo[st.win].winfixwidth)
    eq(false, vim.wo[st.win].number)
    eq("no", vim.wo[st.win].signcolumn)
    -- right of the other window
    ok(vim.api.nvim_win_get_position(st.win)[2] > vim.api.nvim_win_get_position(prev)[2])
    ok(sidebar.is_open())
  end)

  it("opens on the left with position = left and takes focus with focus = true", function()
    setup({ position = "left", width = 30, focus = true })
    local st = sidebar.open()
    eq(st.win, vim.api.nvim_get_current_win())
    eq(0, vim.api.nvim_win_get_position(st.win)[2])
    eq(30, vim.api.nvim_win_get_width(st.win))
  end)

  it("lists today's timed items, deadlines and scheduled items", function()
    local st = sidebar.open()
    local t = text(st)
    ok(t:find("09:00 TODO Standup", 1, true), t)
    ok(t:find("14:00 TODO Review pull requests", 1, true), t)
    ok(t:find("◆ TODO Overdue report", 1, true), t)
    ok(t:find("◆ NEXT Ship the release", 1, true), t)
    ok(t:find("▸ WAITING Old scheduled", 1, true), t)
    -- beyond deadline_days, and DONE entries, are left out
    eq(nil, t:find("Far deadline", 1, true))
    eq(nil, t:find("Finished today", 1, true))
    -- deadlines first, the overdue one on top
    ok(line_of(st, "Overdue report") < line_of(st, "Ship the release"))
    local _, l = line_of(st, "Overdue report")
    ok(l:find("yesterday", 1, true))
  end)

  it("shows the next appointment with a countdown", function()
    local st = sidebar.open()
    local _, l = line_of(st, "Next")
    ok(l:find("in 4h", 1, true), l)
    eq("14:00", st.data.next.time and string.format("%02d:%02d", st.data.next.time / 60, st.data.next.time % 60))
    -- the past standup is dimmed
    local lnum = line_of(st, "09:00 TODO Standup")
    local dim = false
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, -1, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })) do
      if m[4].hl_group == "OrgSidebarPast" then
        dim = true
      end
    end
    ok(dim)
  end)

  it("lists habits and counts the inbox", function()
    local st = sidebar.open()
    local t = text(st)
    local lnum = line_of(st, "Habits")
    ok(buf_lines(st.buf)[lnum + 1]:find("Stretch", 1, true), t)
    ok(t:find("Inbox  2 entries", 1, true), t)
  end)

  it("shows the running clock against its effort", function()
    local st = sidebar.open()
    ok(text(st):find("not clocked in", 1, true))
    sidebar.close()
    date.now = real_now
    local b = utils.load_buffer(path)
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    require("org.clock").clock_in()
    st = sidebar.open()
    local t = text(st)
    ok(t:find("Ship the release", 1, true), t)
    ok(t:find("0:00 / 1:00", 1, true), t)
    ok(t:find("▱", 1, true), t)
    -- <CR> on the clock goes to the clocked heading
    vim.api.nvim_set_current_win(st.win)
    vim.api.nvim_win_set_cursor(st.win, { line_of(st, "Clock") + 1, 0 })
    sidebar.jump()
    eq(b, vim.api.nvim_get_current_buf())
    eq(5, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("draws progress bars", function()
    eq({ "▰▰", "▱▱▱▱▱▱▱▱" }, { sidebar.bar(0.2, 10) })
    eq({ "▰▰▰▰", "" }, { sidebar.bar(3, 4) })
  end)

  it("jumps to an entry in another window and stays open", function()
    local st = sidebar.open()
    vim.api.nvim_set_current_win(st.win)
    vim.api.nvim_win_set_cursor(st.win, { line_of(st, "Review pull requests"), 0 })
    sidebar.jump()
    ok(vim.api.nvim_get_current_win() ~= st.win)
    eq(vim.uv.fs_realpath(path), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
    ok(sidebar.is_open())
    eq(40, vim.api.nvim_win_get_width(st.win))
  end)

  it("opens the inbox from its line", function()
    local st = sidebar.open()
    vim.api.nvim_set_current_win(st.win)
    vim.api.nvim_win_set_cursor(st.win, { line_of(st, "Inbox"), 0 })
    sidebar.jump()
    eq(vim.uv.fs_realpath(inbox), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))
  end)

  it("runs a timer while open and stops it when closed", function()
    local st = sidebar.open()
    local timer = st.timer
    ok(timer:is_active())
    sidebar.close()
    ok(timer:is_closing())
    eq(nil, sidebar.state)
  end)

  it("stops the timer when its window is closed", function()
    local st = sidebar.open()
    local timer = st.timer
    vim.api.nvim_win_close(st.win, true)
    ok(vim.wait(500, function()
      return timer:is_closing()
    end))
    eq(false, sidebar.is_open())
  end)

  it("toggles and leaves the layout as it was", function()
    vim.cmd("split")
    local layout = vim.fn.winrestcmd()
    local wins = #vim.api.nvim_list_wins()
    sidebar.toggle()
    ok(sidebar.is_open())
    eq(wins + 1, #vim.api.nvim_list_wins())
    sidebar.toggle()
    eq(false, sidebar.is_open())
    eq(wins, #vim.api.nvim_list_wins())
    eq(layout, vim.fn.winrestcmd())
    vim.cmd("only")
  end)

  it("moves to the current tab when toggled in another one", function()
    local st = sidebar.open()
    vim.cmd("tabnew")
    sidebar.toggle()
    local st2 = sidebar.state
    ok(st2 ~= st)
    eq(vim.api.nvim_get_current_tabpage(), vim.api.nvim_win_get_tabpage(st2.win))
    ok(not vim.api.nvim_win_is_valid(st.win))
    sidebar.close()
    vim.cmd("tabclose")
  end)

  it("redraws when an org file is written", function()
    local st = sidebar.open()
    local b = utils.load_buffer(path)
    vim.api.nvim_buf_set_lines(b, -1, -1, false, { "* TODO Added now", "  SCHEDULED: <" .. day(0) .. " 16:30>" })
    vim.api.nvim_buf_call(b, function()
      vim.cmd("silent write")
    end)
    ok(vim.wait(2000, function()
      return text(st):find("16:30 TODO Added now", 1, true) ~= nil
    end))
  end)

  it("is closed by a setup() that turns it off", function()
    local st = sidebar.open()
    setup(nil)
    eq(false, sidebar.is_open())
    ok(not vim.api.nvim_win_is_valid(st.win))
  end)
end)

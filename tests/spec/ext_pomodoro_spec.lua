local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function setup(pomodoro)
  require("org").setup({
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
    extensions = pomodoro ~= nil and { pomodoro = pomodoro } or nil,
  })
end

local pomodoro = require("org.extensions.pomodoro")
local clock = require("org.clock")

-- a fake clock in seconds
local now = 1000000
local real_time, real_notify

local function advance(minutes)
  now = now + minutes * 60
  pomodoro.tick()
end

-- the clock needs a file
local function file_buffer(lines, cursor)
  local path = vim.fn.tempname() .. ".org"
  vim.fn.writefile(lines, path)
  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_win_set_cursor(0, cursor)
  return buf
end

local function task_buffer()
  return file_buffer({ "* TODO Write report", "Body", "* TODO Other task" }, { 1, 0 })
end

local function lines_matching(buf, pat)
  local out = {}
  for _, l in ipairs(buf_lines(buf)) do
    if l:match(pat) then
      out[#out + 1] = l
    end
  end
  return out
end

describe("pomodoro", function()
  local notes
  before_each(function()
    setup({ system_notification = false })
    real_time, real_notify = pomodoro.time, pomodoro.notify
    pomodoro.time = function()
      return now
    end
    notes = {}
    local real = pomodoro.notify
    pomodoro.notify = function(msg)
      notes[#notes + 1] = msg
      return real(msg)
    end
  end)
  after_each(function()
    if pomodoro.state then
      pomodoro.stop()
    end
    if clock.state then
      clock.clock_out({ quiet = true, note = false })
    end
    pomodoro.time, pomodoro.notify = real_time, real_notify
    setup(nil)
  end)

  it("registers actions, the command, keys and the which-key group", function()
    local actions = require("org.actions")
    local names = { "pomodoro_start", "pomodoro_pause", "pomodoro_stop", "pomodoro_skip", "pomodoro_status" }
    for _, name in ipairs(names) do
      ok(actions.list[name], name)
    end
    ok(require("org.commands").extra.pomodoro)
    local maps = require("org.config").opts.mappings.global
    eq("<prefix>zs", maps.pomodoro_start)
    eq("<prefix>zp", maps.pomodoro_pause)
    eq("<prefix>zx", maps.pomodoro_stop)
    eq("<prefix>zn", maps.pomodoro_skip)
    eq({ { "z", "pomodoro" } }, pomodoro.groups)
  end)

  it("uses 25/5/15 minutes and a long break every 4 by default", function()
    local o = require("org.extensions").opts("pomodoro")
    eq({ 25, 5, 15, 4 }, { o.work, o.short_break, o.long_break, o.long_break_every })
    eq(false, o.sound)
    eq("POMODOROS", o.property)
  end)

  it("starts on the heading at point and clocks in", function()
    local buf = task_buffer()
    pomodoro.start()
    eq("work", pomodoro.state.phase)
    eq("Write report", pomodoro.state.title)
    ok(clock.state, "clock running")
    ok(clock.is_clocked_headline(buf, 1))
    eq(25 * 60, pomodoro.remaining())
    eq(1, #lines_matching(buf, "CLOCK: %["))
  end)

  it("warns outside a heading", function()
    org_buffer({ "no heading here" }, { 1, 0 })
    pomodoro.start()
    eq(nil, pomodoro.state)
  end)

  it("counts down in the statusline", function()
    task_buffer()
    pomodoro.start()
    eq("🍅 25:00", pomodoro.statusline())
    advance(1.5)
    eq("🍅 23:30", pomodoro.statusline())
    eq("work", pomodoro.state.phase)
  end)

  it("ends a pomodoro: counts it, clocks out and starts a short break", function()
    local buf = task_buffer()
    pomodoro.start()
    advance(25)
    eq("short_break", pomodoro.state.phase)
    eq(1, pomodoro.state.count)
    eq(nil, clock.state)
    ok(#lines_matching(buf, "^%s*:POMODOROS:%s+1$") == 1, vim.inspect(buf_lines(buf)))
    ok(#lines_matching(buf, "CLOCK: %[.*%]%-%-%[.*%] =>") == 1)
    ok(notes[1]:match("Pomodoro 1 done"), notes[1])
    ok(notes[1]:match("short break %(5 min%)"), notes[1])
    eq("☕ 5:00 (1)", pomodoro.statusline())
  end)

  it("waits after a break, then continues on the same entry", function()
    local buf = task_buffer()
    pomodoro.start()
    advance(25)
    advance(5)
    eq("ready", pomodoro.state.phase)
    ok(notes[2]:match("Break over"), notes[2])
    eq("🍅 ready (1)", pomodoro.statusline())
    -- from anywhere: the session's entry
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.cmd("new")
    pomodoro.start()
    vim.cmd("close")
    eq("work", pomodoro.state.phase)
    ok(clock.is_clocked_headline(buf, 1))
  end)

  it("increments an existing POMODOROS property", function()
    local buf = file_buffer({ "* TODO Task", ":PROPERTIES:", ":POMODOROS: 3", ":END:" }, { 1, 0 })
    pomodoro.start()
    advance(25)
    eq(1, #lines_matching(buf, "^:POMODOROS:%s+4$"))
  end)

  it("takes a long break after every 4th pomodoro", function()
    task_buffer()
    pomodoro.start()
    local phases = {}
    for _ = 1, 4 do
      advance(25)
      phases[#phases + 1] = pomodoro.state.phase
      advance(pomodoro.state.phase == "long_break" and 15 or 5)
      pomodoro.start()
    end
    eq({ "short_break", "short_break", "short_break", "long_break" }, phases)
    ok(notes[7]:match("long break %(15 min%)"), notes[7])
  end)

  it("auto_start_work continues after the break", function()
    require("org.config").opts.extensions.pomodoro.auto_start_work = true
    local buf = task_buffer()
    pomodoro.start()
    advance(25)
    advance(5)
    eq("work", pomodoro.state.phase)
    ok(clock.is_clocked_headline(buf, 1))
  end)

  it("catches up several phases after a long pause of the machine", function()
    require("org.config").opts.extensions.pomodoro.auto_start_work = true
    task_buffer()
    pomodoro.start()
    advance(25 + 5 + 25 + 1)
    eq("short_break", pomodoro.state.phase)
    eq(2, pomodoro.state.count)
  end)

  it("honours configured durations, fractional minutes included", function()
    setup({ work = 0.1, short_break = 0.05, system_notification = false })
    task_buffer()
    pomodoro.start()
    eq("🍅 0:06", pomodoro.statusline())
    advance(0.1)
    eq("short_break", pomodoro.state.phase)
    eq("☕ 0:03 (1)", pomodoro.statusline())
  end)

  it("pauses and resumes, stopping the clock meanwhile", function()
    local buf = task_buffer()
    pomodoro.start()
    advance(10)
    pomodoro.pause()
    ok(pomodoro.state.paused_at)
    eq(nil, clock.state)
    eq("⏸ 🍅 15:00", pomodoro.statusline())
    advance(60)
    eq("work", pomodoro.state.phase)
    eq(15 * 60, pomodoro.remaining())
    pomodoro.pause() -- toggles back
    eq(nil, pomodoro.state.paused_at)
    ok(clock.is_clocked_headline(buf, 1))
    advance(14)
    eq("work", pomodoro.state.phase)
    advance(1)
    eq("short_break", pomodoro.state.phase)
  end)

  it("stops without counting the pomodoro", function()
    local buf = task_buffer()
    pomodoro.start()
    advance(20)
    pomodoro.stop()
    eq(nil, pomodoro.state)
    eq(nil, clock.state)
    eq(0, #lines_matching(buf, "POMODOROS"))
    eq("", pomodoro.statusline())
  end)

  it("skip ends a pomodoro uncounted, and a break starts the next one", function()
    local buf = task_buffer()
    pomodoro.start()
    pomodoro.skip()
    eq("short_break", pomodoro.state.phase)
    eq(0, pomodoro.state.count)
    eq(0, #lines_matching(buf, "POMODOROS"))
    eq(0, #notes)
    pomodoro.skip()
    eq("work", pomodoro.state.phase)
    ok(clock.is_clocked_headline(buf, 1))
  end)

  it("moves to another heading, keeping the session count", function()
    local buf = task_buffer()
    pomodoro.start()
    advance(25)
    vim.api.nvim_win_set_cursor(0, { #buf_lines(buf), 0 })
    pomodoro.start()
    eq("Other task", pomodoro.state.title)
    eq(1, pomodoro.state.count)
    ok(clock.is_clocked_headline(buf, #buf_lines(buf)))
  end)

  it("follows the entry when lines are added above it", function()
    local buf = file_buffer({ "* Intro", "* TODO Task" }, { 2, 0 })
    pomodoro.start()
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "#+TITLE: x", "" })
    advance(25)
    eq(1, #lines_matching(buf, "^%s*:POMODOROS:%s+1$"))
    local l = buf_lines(buf)
    eq("* TODO Task", l[4])
  end)

  it("keeps the clock through breaks with clock_out_on_break off", function()
    setup({ clock_out_on_break = false, system_notification = false })
    task_buffer()
    pomodoro.start()
    advance(25)
    ok(clock.state)
  end)

  it("runs the sound command", function()
    local calls = {}
    local sys = vim.system
    vim.system = function(cmd, o)
      calls[#calls + 1] = cmd
      return { wait = function() end }
    end
    require("org.config").opts.extensions.pomodoro.sound = { "true", "ding" }
    local ok_, err = pcall(pomodoro.notify, "hello")
    vim.system = sys
    ok(ok_, err)
    eq({ { "true", "ding" } }, calls)
  end)

  it("fires OrgPomodoroPhase", function()
    local seen = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "OrgPomodoroPhase",
      callback = function(a)
        seen[#seen + 1] = a.data.phase
      end,
    })
    task_buffer()
    pomodoro.start()
    advance(25)
    vim.api.nvim_del_autocmd(id)
    eq({ "work", "short_break" }, seen)
  end)

  it("shows in require('org').statusline() and :Org pomodoro", function()
    task_buffer()
    vim.cmd("Org pomodoro start")
    ok(require("org").statusline():find("🍅 25:00", 1, true), require("org").statusline())
    vim.cmd("Org pomodoro stop")
    eq(nil, pomodoro.state)
  end)
end)

describe("pomodoro off", function()
  it("adds nothing to the statusline, actions or keys", function()
    setup({})
    setup(nil)
    eq({}, require("org").statusline_components)
    eq(nil, require("org.actions").list.pomodoro_start)
    eq(nil, require("org.commands").extra.pomodoro)
    eq(nil, require("org.config").opts.mappings.global.pomodoro_start)
    eq(nil, pomodoro.state)
    eq("", require("org").statusline())
  end)

  it("teardown stops a running session", function()
    setup({ system_notification = false })
    task_buffer()
    pomodoro.start()
    ok(pomodoro.state)
    setup(nil)
    eq(nil, pomodoro.state)
    eq(nil, clock.state)
  end)
end)

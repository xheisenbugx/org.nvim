-- Edge cases of the pomodoro extension: a damaged state file, the entry
-- deleted or renamed mid-pomodoro, commands with no session, zero-length
-- phases and long ones.
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))

local state_file = vim.fn.tempname() .. "-pomodoro-edge.json"

local function setup(pomodoro)
  if type(pomodoro) == "table" and pomodoro.state_file == nil then
    pomodoro = vim.tbl_extend("force", pomodoro, { state_file = state_file })
  end
  require("org").setup({
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
    extensions = pomodoro ~= nil and { pomodoro = pomodoro } or nil,
  })
end

local pomodoro = require("org.extensions.pomodoro")
local clock = require("org.clock")
local utils = require("org.utils")

local now = 2000000
local real_time

local function advance(minutes)
  now = now + minutes * 60
  pomodoro.tick()
end

local function file_buffer(lines, cursor)
  local path = vim.fn.tempname() .. ".org"
  vim.fn.writefile(lines, path)
  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_win_set_cursor(0, cursor or { 1, 0 })
  return buf
end

local function count_lines(buf, pat)
  local n = 0
  for _, l in ipairs(buf_lines(buf)) do
    if l:match(pat) then
      n = n + 1
    end
  end
  return n
end

describe("pomodoro edge cases", function()
  local notes, warns, errors
  local real_notify, real_warn, real_error
  before_each(function()
    setup(nil)
    vim.fn.delete(state_file)
    setup({ system_notification = false })
    real_time = pomodoro.time
    pomodoro.time = function()
      return now
    end
    notes, warns, errors = {}, {}, {}
    real_notify, real_warn, real_error = utils.notify, utils.warn, utils.error
    utils.notify = function(m)
      notes[#notes + 1] = m
    end
    utils.warn = function(m)
      warns[#warns + 1] = m
    end
    utils.error = function(m)
      errors[#errors + 1] = m
    end
  end)
  after_each(function()
    if pomodoro.state then
      pomodoro.stop()
    end
    if clock.state then
      clock.clock_out({ quiet = true, note = false })
    end
    utils.notify, utils.warn, utils.error = real_notify, real_warn, real_error
    pomodoro.time = real_time
    setup(nil)
    vim.fn.delete(state_file)
  end)

  it("ignores a state file that isn't JSON or has the wrong types", function()
    for _, content in ipairs({
      "{ not json",
      "",
      "[]",
      vim.json.encode({ phase = 3, started = now }),
      vim.json.encode({ phase = "work", started = "yesterday", duration = 60, path = "/x.org" }),
      vim.json.encode({ phase = "work", started = now, duration = 1500 }), -- no path
      vim.json.encode({ phase = "ready", started = now, duration = 0, path = "/x.org" }),
    }) do
      setup(nil)
      vim.fn.writefile({ content }, state_file)
      setup({ system_notification = false })
      eq(nil, pomodoro.state, content)
      eq("", pomodoro.statusline())
    end
    eq({}, errors)
  end)

  it("drops a restored session whose file is gone instead of failing when it ends", function()
    setup(nil)
    vim.fn.writefile({
      vim.json.encode({
        phase = "work",
        started = now - 60,
        duration = 25 * 60,
        count = 0,
        path = vim.fn.tempname() .. "-missing.org",
        lnum = 1,
        title = "Gone",
        pid = 999999999,
      }),
    }, state_file)
    setup({ system_notification = false })
    eq("work", pomodoro.state.phase)
    advance(25)
    eq({}, errors)
    -- the session went on to its break, but nothing was written anywhere
    eq("short_break", pomodoro.state.phase)
    eq(1, pomodoro.state.count)
  end)

  it("doesn't count a pomodoro on the next heading when its own was deleted", function()
    local buf = file_buffer({ "* TODO First", "* TODO Second" })
    pomodoro.start()
    eq("First", pomodoro.state.title)
    -- the whole entry, its new LOGBOOK included
    local second = vim.fn.indexof(buf_lines(buf), 'v:val ==# "* TODO Second"')
    vim.api.nvim_buf_set_lines(buf, 0, second, false, {})
    advance(25)
    eq({}, errors)
    eq(0, count_lines(buf, ":POMODOROS:"))
    eq({ "* TODO Second" }, buf_lines(buf))
  end)

  it("follows its heading through a title change, typed or the whole line changed", function()
    local buf = file_buffer({ "* TODO Draft", "* TODO Other" })
    pomodoro.start()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! A, renamed")
    advance(25)
    eq(1, count_lines(buf, "^%s*:POMODOROS:%s+1$"))
    eq("* TODO Draft, renamed", buf_lines(buf)[1])
    advance(5)
    pomodoro.start()
    vim.cmd("normal! ggcc* TODO Final title")
    eq("* TODO Final title", buf_lines(buf)[1])
    advance(25)
    eq(1, count_lines(buf, "^%s*:POMODOROS:%s+2$"))
    eq("* TODO Other", buf_lines(buf)[#buf_lines(buf)])
  end)

  it("keeps a unicode title in the state file and statusline", function()
    file_buffer({ "* TODO Écrire le rapport 📝 — 日本語" })
    pomodoro.start()
    local saved = vim.json.decode(table.concat(vim.fn.readfile(state_file), "\n"))
    eq("Écrire le rapport 📝 — 日本語", saved.title)
    eq("Écrire le rapport 📝 — 日本語", pomodoro.info().title)
    ok(pomodoro.statusline():find("25:00", 1, true))
  end)

  it("creates the directories of a state_file that doesn't exist yet", function()
    local nested = vim.fn.tempname() .. "/a/b/pomodoro.json"
    setup({ system_notification = false, state_file = nested })
    file_buffer({ "* TODO Task" })
    pomodoro.start()
    eq(1, vim.fn.filereadable(nested))
    pomodoro.stop()
    eq(0, vim.fn.filereadable(nested))
    vim.fn.delete(vim.fn.fnamemodify(nested, ":h:h:h"), "rf")
  end)

  it("writes nothing with state_file = false", function()
    setup({ system_notification = false, state_file = false })
    file_buffer({ "* TODO Task" })
    pomodoro.start()
    advance(25)
    eq(0, vim.fn.filereadable(state_file))
    eq("short_break", pomodoro.state.phase)
  end)

  it("answers pause, resume, stop, skip and status with no session", function()
    eq(nil, pomodoro.state)
    pomodoro.pause()
    pomodoro.resume()
    pomodoro.stop()
    pomodoro.skip()
    pomodoro.status()
    eq({ "No pomodoro running", "No paused pomodoro", "No pomodoro running", "No pomodoro running" }, {
      notes[1],
      notes[2],
      notes[3],
      notes[4],
    })
    eq("No pomodoro running", notes[5])
    eq({}, errors)
  end)

  it("resumes twice and pauses twice without moving the end", function()
    file_buffer({ "* TODO Task" })
    pomodoro.start()
    advance(5)
    pomodoro.pause()
    advance(10)
    -- a second pause resumes
    pomodoro.pause()
    eq(nil, pomodoro.state.paused_at)
    pomodoro.resume()
    eq("No paused pomodoro", notes[#notes])
    eq(20 * 60, pomodoro.remaining())
  end)

  it("rejects an unknown :Org pomodoro argument", function()
    pomodoro.command("  frobnicate ")
    eq({ "Unknown :Org pomodoro argument: frobnicate" }, errors)
    eq(nil, pomodoro.state)
  end)

  it("stops catching up after zero-length phases instead of looping forever", function()
    setup({ system_notification = false, work = 0, short_break = 0, long_break = 0, auto_start_work = true })
    local buf = file_buffer({ "* TODO Task" })
    pomodoro.start()
    advance(1)
    ok(pomodoro.state ~= nil)
    -- bounded: the guard stops after 100 phases
    ok(pomodoro.state.count <= 100, tostring(pomodoro.state.count))
    ok(count_lines(buf, ":POMODOROS:") == 1)
  end)

  it("shows hours in the statusline for a long pomodoro", function()
    setup({ system_notification = false, work = 90 })
    file_buffer({ "* TODO Deep work" })
    pomodoro.start()
    eq("🍅 1:30:00", pomodoro.statusline())
    advance(31)
    eq("🍅 59:00", pomodoro.statusline())
  end)

  it("falls back to the default icon for one left out of icons", function()
    setup({ system_notification = false, icons = { work = "W" } })
    file_buffer({ "* TODO Task" })
    pomodoro.start()
    eq("W 25:00", pomodoro.statusline())
    advance(25)
    eq("☕ 5:00 (1)", pomodoro.statusline())
  end)
end)

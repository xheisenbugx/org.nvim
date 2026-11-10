-- The caldav extension end to end: real curl against a local stand-in for
-- a CalDAV server (tests/support/caldav_server.lua) on 127.0.0.1. No
-- request leaves the machine.
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local Server = dofile(root .. "/tests/support/caldav_server.lua")
local date = require("org.date")
local sync = require("org.extensions.caldav.sync")

local TODAY = date.Date.new({ year = 2026, month = 11, day = 10 })

describe("caldav through curl", function()
  local tmp, path, srv
  local real = {}

  local function setup(cal)
    local c = vim.tbl_extend("force", {
      name = "Work",
      url = srv.url .. srv.home .. "work/",
      user = "me",
      password = 'se"cret pass',
      inbox = path,
    }, cal or {})
    require("org").setup({
      org_directory = tmp,
      extensions = {
        caldav = {
          calendars = { c },
          timezone = "UTC",
          state_dir = tmp .. "/state",
          delete_local = "always",
          delete_remote = "always",
          timeout = 20,
        },
      },
    })
  end

  local function run()
    local done, results = false, nil
    sync.run(nil, {
      done = function(r)
        results, done = r, true
      end,
    })
    vim.wait(60000, function()
      return done
    end, 5)
    ok(done, "the sync did not finish")
    return results and results[1]
  end

  local function buf()
    return require("org.utils").load_buffer(path)
  end

  local function org()
    return vim.api.nvim_buf_get_lines(buf(), 0, -1, false)
  end

  before_each(function()
    if vim.fn.executable("curl") == 0 then
      error({ skip = "no curl" }, 0)
    end
    tmp = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(tmp, "p")
    path = tmp .. "/cal.org"
    srv = Server.new({ user = "me", password = 'se"cret pass' })
    srv:calendar("work")
    srv:listen()
    real.today, real.now, real.notify = date.today, date.now, vim.notify
    date.today = function()
      return TODAY:clone()
    end
    date.now = function()
      return TODAY:clone({ hour = 12, min = 0 })
    end
    vim.notify = function() end
  end)

  after_each(function()
    if not srv then
      return
    end
    srv:close()
    date.today, date.now, vim.notify = real.today, real.now, real.notify
    require("org").setup({ extensions = {} })
    local b = vim.fn.bufnr(path)
    if b > 0 then
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end)

  it("syncs both ways: new, changed and deleted, with a password", function()
    srv:put("work", "a.ics", table.concat({
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "BEGIN:VEVENT",
      "UID:uid-a",
      "SUMMARY:Révision <a&b>",
      "DTSTART:20261112T150000Z",
      "DTEND:20261112T160000Z",
      "DESCRIPTION:" .. string.rep("long ", 40),
      "END:VEVENT",
      "END:VCALENDAR",
    }, "\r\n") .. "\r\n")
    vim.fn.writefile({ "* Dentist", "<2026-11-13 Fri 09:00-09:30>" }, path)
    setup()
    local res = run()
    eq(nil, res.failed)
    eq({}, res.errors)
    eq(1, res.pulled)
    eq(1, res.pushed)
    local lines = org()
    local id = lines[3]:match("^:ID:%s+(%S+)")
    ok(id, vim.inspect(lines))
    eq("* Révision <a&b>", lines[6])
    eq(vim.trim(string.rep("long ", 40)), lines[#lines])
    local want = { "a.ics", id .. ".ics" }
    table.sort(want)
    eq(want, srv:files("work"))
    ok(srv:get("work", id .. ".ics"):find("SUMMARY:Dentist\r\n", 1, true))
    -- the requests carried the password, and what was sent is conditional
    local put = srv:requests("PUT")[1]
    eq("*", put.headers["if-none-match"])
    ok(put.headers["content-type"]:find("text/calendar", 1, true))

    -- a change each way and a deletion
    vim.api.nvim_buf_set_lines(buf(), 5, 6, false, { "* Review" })
    srv:remove("work", id .. ".ics")
    res = run()
    eq(nil, res.failed)
    eq({}, res.errors)
    eq(1, res.pushed)
    eq(1, res.deleted_local)
    ok(srv:get("work", "a.ics"):find("SUMMARY:Review\r\n", 1, true))
    eq("* Review", org()[1])
    eq('"e1"', srv:requests("PUT")[2].headers["if-match"])

    -- and nothing the third time
    res = run()
    eq(0, res.pulled + res.pushed + res.deleted_local + res.deleted_remote)
  end)

  it("reports a refused password and an unreachable server", function()
    setup({ password = "wrong" })
    local res = run()
    ok(res.failed:find("401", 1, true), res.failed)
    srv:close()
    setup()
    res = run()
    ok(res.failed and res.failed ~= "", vim.inspect(res))
    eq(nil, vim.uv.fs_stat(path))
  end)

  it("finds the calendars of the account from the server's address", function()
    setup({ url = srv.url .. "/dav/" })
    local lines
    require("org.extensions.caldav").discover(nil, function(l)
      lines = l
    end)
    vim.wait(60000, function()
      return lines ~= nil
    end, 5)
    eq({
      "CalDAV calendars at " .. srv.url .. "/dav/",
      "",
      "work",
      "  url    " .. srv.url .. "/dav/calendars/me/work/",
      "  holds  events, tasks",
      "",
    }, lines)
  end)
end)

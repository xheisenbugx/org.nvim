-- Config for docs/media/tapes/gcal.tape: the gcal extension against the
-- local stand-in for Google (tests/support/gcal_server.lua) on 127.0.0.1.
-- No Google account and no network are involved, and the page says so.
--
--   export ORG_DEMO_DIR=/tmp/org-demo-gcal
--   nvim -u docs/media/demo/gcal/init.lua $ORG_DEMO_DIR/schedule.org
--
-- Builds on docs/media/demo/init.lua (captions, :Cap and :Do) and adds:
--   :DemoServer   show the events the stand-in server holds
--   :DemoWebEdit  change an event on the server, as if edited on the web
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h:h:h:h")
dofile(root .. "/docs/media/demo/init.lua")

local dir = vim.env.ORG_DEMO_DIR or "/tmp/org-nvim-demo"
local CAL = "team@example.com"
local Server = dofile(root .. "/tests/support/gcal_server.lua")
local srv = Server.start()
srv.page_size = 50

local function at(days, h, m)
  local t = os.date("*t", os.time() + days * 86400)
  t.hour, t.min, t.sec = h, m or 0, 0
  return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time(t))
end
local function day(days)
  return os.date("%Y-%m-%d", os.time() + days * 86400)
end

srv:calendar(CAL, "UTC")
srv:put(CAL, {
  id = "standup",
  summary = "Team standup",
  start = { dateTime = at(0, 9, 30) },
  ["end"] = { dateTime = at(0, 9, 45) },
})
srv:put(CAL, {
  id = "review",
  summary = "Design review",
  location = "Room 4",
  description = "Walk through the new agenda views.",
  start = { dateTime = at(0, 14) },
  ["end"] = { dateTime = at(0, 15) },
})
srv:put(CAL, {
  id = "lunch",
  summary = "Lunch with Sam",
  start = { dateTime = at(1, 12, 30) },
  ["end"] = { dateTime = at(1, 13, 30) },
})
srv:put(CAL, { id = "offsite", summary = "Offsite", start = { date = day(3) }, ["end"] = { date = day(5) } })
srv:grant("demo-access-token", "demo-refresh-token")

vim.fn.writefile({}, dir .. "/schedule.org")
require("org").setup({
  org_directory = dir,
  agenda_files = { dir .. "/schedule.org" },
  todo_keywords = { "TODO(t) NEXT(n) | DONE(d) CANCELLED(c)" },
  agenda = { span = "week", window = "only" },
  ui = { bullets = { "◉", "○", "✸", "✿" } },
  extensions = {
    gcal = {
      client_id = "demo-client.apps.googleusercontent.com",
      client_secret = "demo-secret",
      token_file = dir .. "/gcal-token.json",
      fetch_file_alist = { [CAL] = dir .. "/schedule.org" },
    },
  },
})
srv:install()
require("org.extensions.gcal.oauth").save(require("org.extensions.gcal").opts(), {
  access_token = "demo-access-token",
  refresh_token = "demo-refresh-token",
  expires_at = os.time() + 3600,
  sync_tokens = {},
})

-- A label that stays on screen (the tab line): this is a demo against a
-- local server.
vim.api.nvim_set_hl(0, "DemoBanner", { fg = "#14161b", bg = "#fce094", bold = true })
vim.api.nvim_set_hl(0, "DemoBannerFill", { bg = "#14161b" })
vim.o.showtabline = 2
vim.o.tabline = "%#DemoBannerFill#%=%#DemoBanner#"
  .. " DEMO · local stand-in for Google Calendar on 127.0.0.1 · no real account "
vim.o.hlsearch = false

local function fmt(t)
  if t.date then
    return t.date
  end
  local e = require("org.extensions.gcal.event")
  local c = e.epoch_to_local({}, (e.parse_rfc3339(t.dateTime)))
  return string.format("%04d-%02d-%02d %02d:%02d", c.year, c.month, c.day, c.hour, c.min)
end

vim.api.nvim_create_user_command("DemoServer", function()
  local lines = { " Events on the stand-in server", "" }
  local cal = srv.calendars[CAL]
  for _, id in ipairs(cal.order) do
    local ev = cal.events[id]
    if ev and ev.status ~= "cancelled" then
      lines[#lines + 1] = string.format(" %-16s  %-22s", fmt(ev.start), ev.summary)
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = " press q to close"
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local width = 46
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 3,
    col = vim.o.columns - width - 4,
    width = width,
    height = #lines,
    style = "minimal",
    border = "rounded",
    title = " server ",
  })
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })
end, {})

vim.api.nvim_create_user_command("DemoWebEdit", function()
  local ev = vim.deepcopy(srv.calendars[CAL].events.lunch)
  ev.summary = "Lunch with Sam and Alex"
  ev.start = { dateTime = at(1, 13) }
  ev["end"] = { dateTime = at(1, 14) }
  srv:put(CAL, ev)
  vim.notify("stand-in server: \"Lunch with Sam\" edited as if on the web")
end, {})

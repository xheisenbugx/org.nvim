-- Demo config for docs/media/tapes/caldav.tape: init.lua plus the caldav
-- extension, synced with a calendar of the stand-in server the specs use
-- (tests/support/caldav_server.lua), served on 127.0.0.1 by this Neovim
-- and reached through real curl. Nothing leaves the machine.
--
-- `:CalServer {file}` shows an event as the server stores it and
-- `:CalOther` changes one as another calendar program would; the tape
-- types them hidden.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h:h:h")
dofile(here .. "/init.lua")

local dir = vim.env.ORG_DEMO_DIR or "/tmp/org-nvim-demo"

--- The org date `offset` days from today.
local function day(offset)
  return os.date("%Y-%m-%d %a", os.time() + offset * 86400)
end

--- A UTC date-time for `h:m` local time, `offset` days from today.
local function utc(offset, h, m)
  local t = os.date("*t", os.time() + offset * 86400)
  t.hour, t.min, t.sec = h, m, 0
  return os.date("!%Y%m%dT%H%M%SZ", os.time(t))
end

local function ics(lines)
  local out = { "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Another calendar//EN", "BEGIN:VEVENT" }
  vim.list_extend(out, lines)
  vim.list_extend(out, { "END:VEVENT", "END:VCALENDAR" })
  return table.concat(out, "\r\n") .. "\r\n"
end

vim.fn.writefile({
  "#+TITLE: Calendar",
  "",
  "* Dentist",
  "<" .. day(2) .. " 09:00-09:30>",
  "Bring the x-rays.",
}, dir .. "/calendar.org")

local srv = dofile(root .. "/tests/support/caldav_server.lua").new({ user = "me", password = "demo" })
srv:calendar("home")
local function review(offset, location)
  return ics({
    "UID:design-review",
    "SUMMARY:Design review",
    "DTSTART:" .. utc(offset, 15, 0),
    "DTEND:" .. utc(offset, 16, 0),
    "LOCATION:" .. location,
    "DESCRIPTION:Bring the mockups.",
    "ATTENDEE;CN=Ana:mailto:ana@example.com",
    "BEGIN:VALARM",
    "ACTION:DISPLAY",
    "DESCRIPTION:Reminder",
    "TRIGGER:-PT10M",
    "END:VALARM",
  })
end
srv:put("home", "design-review.ics", review(1, "Room 4"))
srv:put(
  "home",
  "team-lunch.ics",
  ics({
    "UID:team-lunch",
    "SUMMARY:Team lunch",
    "DTSTART:" .. utc(3, 13, 0),
    "DTEND:" .. utc(3, 14, 0),
    "RRULE:FREQ=WEEKLY",
  })
)
srv:listen()

local opts = require("org.config").opts
opts.agenda_files = { dir .. "/calendar.org" }
opts.agenda.span = "week"
opts.extensions.caldav = {
  calendars = {
    {
      name = "Home",
      url = srv.url .. srv.home .. "home/",
      user = "me",
      password = "demo",
      inbox = dir .. "/calendar.org",
    },
  },
  state_dir = dir .. "/caldav-state",
}
require("org.extensions").setup()

vim.api.nvim_create_user_command("CalServer", function(o)
  local text = srv:get("home", o.args) or ""
  vim.cmd("botright 17new")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, require("org.extensions.ics.parser").unfold(text))
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  vim.bo[buf].filetype = "icalendar"
  pcall(vim.api.nvim_buf_set_name, buf, "the event on the server")
  -- from BEGIN:VEVENT, so the alarm at its end is on screen
  vim.cmd("normal! 4Gzt")
  vim.cmd("wincmd p")
end, { nargs = 1 })

vim.api.nvim_create_user_command("CalOther", function()
  -- another program moves the review a day later, to another room; it
  -- keeps the title the server has
  local now = srv:get("home", "design-review.ics") or ""
  local title = now:match("SUMMARY:([^\r\n]*)") or "Design review"
  srv:put("home", "design-review.ics", (review(2, "Room 7"):gsub("SUMMARY:Design review", "SUMMARY:" .. title)))
end, {})

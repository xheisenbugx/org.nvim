-- Extensions, each enabled in its scenario's `setup = { extensions = { ... } }`
-- (feature map: .claude/skills/verify-org/features/extensions.md): the
-- kanban board, the journal and presentations. The clock is Monday
-- 2026-10-12 09:00.
local board = {
  "* TODO Write the report",
  "* TODO Book the train",
  "* DONE Pay the rent",
}

return {
  {
    name = "kanban: a card moved to the next column changes its TODO keyword",
    files = { ["tasks.org"] = board },
    open = "tasks.org",
    setup = { agenda_files = { "{{dir}}/*.org" }, extensions = { kanban = { save = true } } },
    steps = {
      {
        key = "{{global.kanban_open}}",
        expect = { filetype = "orgkanban", screen = { "TODO  2", "DONE  1", "Write the report", "Pay the rent" } },
      },
      { key = "l", expect = { screen = { "TODO  1", "DONE  2" } } },
      {
        note = "save = true writes the file at once",
        expect = {
          file = { "tasks.org", lines = { "* DONE Write the report", "* TODO Book the train", "* DONE Pay the rent" } },
        },
      },
      { key = "q", expect = { filetype = "org", no_screen = "Kanban" } },
    },
  },
  {
    name = "kanban: without save a moved card changes the buffer, not the file",
    files = { ["tasks.org"] = board },
    open = "tasks.org",
    setup = { agenda_files = { "{{dir}}/*.org" }, extensions = { kanban = true } },
    steps = {
      { key = "{{global.kanban_open}}", expect = { screen = "TODO  2" } },
      { key = "l", expect = { screen = "DONE  2" } },
      { key = "q", expect = { filetype = "org", buffer = "^%* DONE Write the report$" } },
      { expect = { file = { "tasks.org", lines = board } } },
    },
  },
  {
    name = "journal: a new entry makes today's file, day and time headings",
    setup = { extensions = { journal = { directory = "{{dir}}/journal" } } },
    steps = {
      { key = "{{global.journal_new_entry}}", expect = { mode = "i", line = "^%*%* 09:00 $" } },
      { type = "Planted the bulbs" },
      { key = "<Esc>" },
      { cmd = "write" },
      {
        expect = {
          file = { "journal/20261012.org", lines = { "* Monday, 2026-10-12", "** 09:00 Planted the bulbs" } },
        },
      },
      { wait = 90 },
      { key = "{{global.journal_new_entry}}", expect = { mode = "i", line = "^%*%* 10:30 $" } },
      { type = "Watered them" },
      { key = "<Esc>" },
      { cmd = "write" },
      {
        expect = {
          file = {
            "journal/20261012.org",
            lines = { "* Monday, 2026-10-12", "** 09:00 Planted the bulbs", "** 10:30 Watered them" },
          },
        },
      },
    },
  },
  {
    name = "present: slides from the headlines, next and quit",
    files = {
      ["talk.org"] = {
        "#+TITLE: Gardening",
        "* Soil",
        "Dig it over.",
        "* Seeds",
        "Sow in rows.",
      },
    },
    open = "talk.org",
    setup = { extensions = { present = true } },
    steps = {
      { key = "{{org.present_start}}", expect = { screen = { "1/3", "Gardening" } } },
      { key = "n", expect = { screen = { "2/3", "Soil", "Dig it over." }, no_screen = "Sow in rows." } },
      { key = "n", expect = { screen = { "3/3", "Seeds", "Sow in rows." }, no_screen = "Dig it over." } },
      { key = "p", expect = { screen = "2/3" } },
      { key = "q", expect = { screen = { "#+TITLE: Gardening", "* Soil", "* Seeds" }, no_screen = "2/3" } },
      { note = "the cursor is back on the slide it left", expect = { line = "^%* Soil$" } },
    },
  },
  {
    name = "caldav: a sync brings events in, sends changes back and asks before deleting",
    files = { ["calendar.org"] = { "* Dentist", "<2026-10-14 Wed 09:00-09:30>" } },
    open = "calendar.org",
    setup = {
      extensions = {
        caldav = {
          calendars = {
            { name = "Home", url = "http://dav.test/dav/calendars/me/home/", inbox = "{{dir}}/calendar.org" },
          },
          timezone = "UTC",
          state_dir = "{{dir}}/state",
        },
      },
    },
    steps = {
      {
        note = "a stand-in for the server answers inside the child: nothing goes on the network",
        lua = [[
          local file = vim.api.nvim_get_runtime_file("tests/support/caldav_server.lua", false)[1]
          local srv = dofile(file).new()
          srv:calendar("home")
          srv:put("home", "a.ics", table.concat({
            "BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VEVENT", "UID:uid-a", "SUMMARY:Design review",
            "DTSTART:20261015T150000Z", "DTEND:20261015T160000Z", "LOCATION:Room 4",
            "ATTENDEE:mailto:ana@example.com", "END:VEVENT", "END:VCALENDAR",
          }, "\r\n") .. "\r\n")
          require("org.extensions.caldav.http").transport = srv:transport()
          _G.__caldav = srv
        ]],
      },
      {
        cmd = "Org caldav_sync",
        expect = {
          screen = {
            "caldav: Home: 1 from the calendar, 1 to the calendar",
            "* Design review",
            "<2026-10-15 Thu 15:00-16:00>",
          },
        },
      },
      { note = "its location is in the (folded) drawer", expect = { buffer = "^:LOCATION: Room 4$" } },
      { note = "the entry of the file was sent, with an ID", expect = { buffer = "^:ID: " } },
      { expect = { lua = "return #_G.__caldav:files('home') == 2" } },
      { note = "the file is saved", expect = { file = { "calendar.org", "^%* Design review$" } } },
      { at = "Design review" },
      { key = "A (moved)<Esc>" },
      { cmd = "Org caldav_sync", expect = { screen = "caldav: Home: 1 to the calendar" } },
      {
        note = "only the title changed in the event: the attendee is still there",
        expect = {
          lua = [[
            local ics = _G.__caldav:get("home", "a.ics")
            return ics:find("SUMMARY:Design review (moved)", 1, true) ~= nil
              and ics:find("ATTENDEE:mailto:ana@example.com", 1, true) ~= nil
          ]],
        },
      },
      { cmd = "1,5delete", note = "the Dentist entry deleted in org: its heading, drawer and timestamp" },
      {
        cmd = "Org caldav_sync",
        expect = { screen = { "1 entry was deleted in the org files. Delete it from the calendar too?", "Dentist" } },
      },
      {
        note = "typed, not a key step: Neovim answers nothing else while confirm() waits",
        type = "y",
        expect = { screen = "caldav: Home: 1 deleted in the calendar" },
      },
      { expect = { lua = "return #_G.__caldav:files('home') == 1" } },
    },
  },
}

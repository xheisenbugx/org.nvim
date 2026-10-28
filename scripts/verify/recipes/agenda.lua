-- The agenda (feature map: .claude/skills/verify-org/features/agenda.md).
-- The clock is Monday 2026-10-12 09:00.
local todo = {
  "* TODO Renew the passport",
  "  SCHEDULED: <2026-10-12 Mon>",
  "* TODO Call the bank",
  "  DEADLINE: <2026-10-14 Wed>",
  "* Dentist",
  "  <2026-10-15 Thu 14:00>",
}

local setup = { agenda_files = { "{{dir}}/todo.org" } }

return {
  {
    name = "week agenda lists scheduled, deadline and timestamp entries",
    files = { ["todo.org"] = todo },
    open = "todo.org",
    setup = setup,
    steps = {
      { key = "{{global.agenda}}", expect = { screen = "Agenda for current week or day" } },
      {
        key = "a",
        expect = {
          filetype = "orgagenda",
          screen = {
            "Week-agenda (W42):",
            "Scheduled:  TODO Renew the passport",
            "In   2 d.:  TODO Call the bank",
            "Deadline:   TODO Call the bank",
            "14:00 ┄┄┄┄┄ Dentist",
          },
        },
      },
      { key = "{{agenda.quit}}", expect = { filetype = "org", no_screen = "Week-agenda" } },
    },
  },
  {
    name = "a TODO marked done from the agenda changes the file",
    files = { ["todo.org"] = todo },
    open = "todo.org",
    -- org-log-done is off by default, as in Emacs
    setup = { agenda_files = setup.agenda_files, log_done = "time" },
    steps = {
      { key = "{{global.agenda}}a", expect = { filetype = "orgagenda" } },
      { at = "Renew the passport" },
      { key = "{{agenda.todo}}", expect = { screen = "Scheduled:  DONE Renew the passport", line = "DONE" } },
      { note = "the agenda edits the buffer; the file changes on save", key = "{{agenda.save_all}}" },
      { expect = { file = { "todo.org", "^%* DONE Renew the passport" } } },
      { expect = { file = { "todo.org", "^%s+CLOSED: %[2026%-10%-12 Mon 09:00%]" } } },
    },
  },
  {
    name = "later and earlier move the agenda a week",
    files = { ["todo.org"] = todo },
    open = "todo.org",
    setup = setup,
    steps = {
      { key = "{{global.agenda}}a", expect = { screen = "Week-agenda (W42):" } },
      { key = "{{agenda.later}}", expect = { screen = { "Week-agenda (W43):", "Monday     19 October 2026 W43" } } },
      { key = "{{agenda.earlier}}", expect = { screen = { "Week-agenda (W42):", "Monday     12 October 2026 W42" } } },
    },
  },
}

-- Dates and timestamps (feature map: .claude/skills/verify-org/features/dates.md).
-- The clock is Monday 2026-10-12 09:00.
return {
  {
    name = "insert a timestamp from the calendar",
    files = { ["todo.org"] = { "* Dentist", "" } },
    open = "todo.org",
    steps = {
      { at = "* Dentist" },
      { key = "j{{org.timestamp}}", expect = { screen = "October 2026" } },
      { key = "l", expect = { screen = "Tuesday" } },
      { key = "<CR>", expect = { line = "^<2026%-10%-13 Tue>$" } },
      { cmd = "write" },
      { expect = { file = { "todo.org", lines = { "* Dentist", "<2026-10-13 Tue>" } } } },
    },
  },
  {
    name = "S-Right and S-Up shift the day under the cursor",
    files = { ["todo.org"] = { "* Dentist", "<2026-10-12 Mon>" } },
    open = "todo.org",
    steps = {
      { at = "<2026", col = "12 Mon" },
      { key = "{{org.shift_right}}", expect = { line = "^<2026%-10%-13 Tue>$" } },
      { key = "{{org.shift_up}}", expect = { line = "^<2026%-10%-14 Wed>$" } },
      { at = "<2026", col = "10-14" },
      { key = "{{org.shift_up}}", expect = { line = "^<2026%-11%-14 Sat>$" } },
      { cmd = "write" },
      { expect = { file = { "todo.org", lines = { "* Dentist", "<2026-11-14 Sat>" } } } },
    },
  },
  {
    name = "schedule an entry with a typed date",
    files = { ["todo.org"] = { "* TODO Renew the passport" } },
    open = "todo.org",
    steps = {
      { key = "{{org.schedule}}", expect = { screen = "October 2026" } },
      { key = "i" },
      { type = "fri" },
      { key = "<CR>", expect = { buffer = "SCHEDULED" } },
      { cmd = "write" },
      {
        expect = {
          file = { "todo.org", lines = { "* TODO Renew the passport", "SCHEDULED: <2026-10-16 Fri>" } },
        },
      },
    },
  },
  {
    name = "a timestamp inserted twice in a row is a date range",
    files = { ["todo.org"] = { "* Conference", "" } },
    open = "todo.org",
    steps = {
      { at = "* Conference" },
      { key = "j{{org.timestamp}}<CR>", expect = { line = "^<2026%-10%-12 Mon>$" } },
      { key = "{{org.timestamp}}", expect = { screen = "October 2026" } },
      { key = "ll<CR>", expect = { line = "^<2026%-10%-12 Mon>%-%-<2026%-10%-14 Wed>$" } },
      { cmd = "write" },
      { expect = { file = { "todo.org", lines = { "* Conference", "<2026-10-12 Mon>--<2026-10-14 Wed>" } } } },
    },
  },
}

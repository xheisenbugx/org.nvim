-- TODO states, priorities and tags (feature map:
-- .claude/skills/verify-org/features/todo.md). The clock is Monday
-- 2026-10-12 09:00.
local chores = { "* Water the plants", "* TODO Pay rent" }

return {
  {
    name = "cycle a heading through TODO, DONE and no keyword",
    files = { ["chores.org"] = chores },
    open = "chores.org",
    steps = {
      { at = "Water the plants" },
      { key = "{{org.todo_next}}", expect = { line = "^%* TODO Water the plants$" } },
      { key = "{{org.todo_next}}", expect = { line = "^%* DONE Water the plants$" } },
      {
        note = "log_done is off by default: no CLOSED line",
        expect = { lua = [[return vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] == "* TODO Pay rent"]] },
      },
      { key = "{{org.todo_next}}", expect = { line = "^%* Water the plants$" } },
      { key = "{{org.todo_prev}}", expect = { line = "^%* DONE Water the plants$" } },
      { at = "Pay rent" },
      { key = "{{org.shift_right}}", expect = { line = "^%* DONE Pay rent$" } },
      { key = "{{emacs.todo}}", expect = { line = "^%* Pay rent$" } },
      { cmd = "write" },
      { expect = { file = { "chores.org", lines = { "* DONE Water the plants", "* Pay rent" } } } },
    },
  },
  {
    name = "log_done adds CLOSED when done, removes it when reopened",
    files = { ["chores.org"] = chores },
    open = "chores.org",
    setup = { log_done = "time" },
    steps = {
      { at = "Pay rent" },
      {
        key = "{{org.todo_next}}",
        expect = { line = "^%* DONE Pay rent$", screen = "CLOSED: [2026-10-12 Mon 09:00]" },
      },
      { cmd = "write" },
      {
        expect = {
          file = { "chores.org", lines = { "* Water the plants", "* DONE Pay rent", "CLOSED: [2026-10-12 Mon 09:00]" } },
        },
      },
      { key = "{{org.todo_prev}}", expect = { line = "^%* TODO Pay rent$", no_screen = "CLOSED:" } },
      { cmd = "write" },
      { expect = { file = { "chores.org", lines = chores } } },
    },
  },
  {
    name = "fast selection over keyword sets logs into the LOGBOOK",
    files = { ["work.org"] = { "* TODO Write the report", "Draft is in the shared folder." } },
    open = "work.org",
    setup = {
      todo_keywords = { "TODO(t) NEXT(n) | DONE(d!)", "WAITING(w@/!) | CANCELLED(c@)" },
      log_into_drawer = true,
    },
    steps = {
      { at = "Write the report" },
      { key = "{{emacs.todo}}", expect = { screen = { "NEXT", "WAITING", "CANCELLED" } } },
      { key = "n", expect = { line = "^%* NEXT Write the report$" } },
      {
        note = "NEXT has no logging flag: nothing logged",
        expect = { lua = [[return vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] == "Draft is in the shared folder."]] },
      },
      { key = "{{emacs.todo}}" },
      {
        note = "d! logs the state change; CLOSED only comes with log_done, as in Emacs",
        key = "d",
        expect = { line = "^%* DONE Write the report$", screen = ":LOGBOOK:", no_screen = "CLOSED:" },
      },
      { cmd = "write" },
      {
        expect = {
          file = {
            "work.org",
            lines = {
              "* DONE Write the report",
              ":LOGBOOK:",
              '- State "DONE"       from "NEXT"       [2026-10-12 Mon 09:00]',
              ":END:",
              "Draft is in the shared folder.",
            },
          },
        },
      },
    },
  },
  {
    name = "a state with @ asks for a note in the *Org Note* window",
    files = { ["work.org"] = { "* TODO Write the report" } },
    open = "work.org",
    setup = {
      todo_keywords = { "TODO(t) NEXT(n) | DONE(d!)", "WAITING(w@/!) | CANCELLED(c@)" },
      log_into_drawer = true,
    },
    steps = {
      { at = "Write the report" },
      { key = "{{emacs.todo}}" },
      { key = "w", expect = { screen = "*Org Note*" } },
      { type = "Waiting for the numbers" },
      { key = "<Esc><C-c><C-c>", expect = { no_screen = "*Org Note*", line = "^%* WAITING Write the report$" } },
      { cmd = "write" },
      {
        expect = {
          file = {
            "work.org",
            lines = {
              "* WAITING Write the report",
              ":LOGBOOK:",
              '- State "WAITING"    from "TODO"       [2026-10-12 Mon 09:00] \\\\',
              "  Waiting for the numbers",
              ":END:",
            },
          },
        },
      },
    },
  },
  {
    name = "set, shift and remove a priority",
    files = { ["chores.org"] = chores },
    open = "chores.org",
    steps = {
      { at = "Pay rent" },
      { key = "{{org.priority}}", expect = { screen = "Priority A-C, SPC to remove:" } },
      { key = "a", expect = { line = "^%* TODO %[#A%] Pay rent$" } },
      { key = "{{org.shift_down}}", expect = { line = "^%* TODO %[#B%] Pay rent$" } },
      { at = "Water the plants" },
      {
        note = "no cookie yet: S-Up starts at the default priority, B",
        key = "{{org.shift_up}}",
        expect = { line = "^%* %[#B%] Water the plants$" },
      },
      { key = "{{org.shift_up}}", expect = { line = "^%* %[#A%] Water the plants$" } },
      { key = "{{org.priority}}" },
      { key = "<Space>", expect = { line = "^%* Water the plants$" } },
      { cmd = "write" },
      { expect = { file = { "chores.org", lines = { "* Water the plants", "* TODO [#B] Pay rent" } } } },
    },
  },
  {
    name = "type tags with completion; they align at tags_column",
    files = { ["chores.org"] = chores },
    open = "chores.org",
    steps = {
      { at = "Pay rent" },
      { key = "{{org.set_tags}}", expect = { screen = "Tags:" } },
      { type = "home:money" },
      { key = "<CR>", expect = { line = "^%* TODO Pay rent%s+:home:money:$" } },
      {
        note = "right-aligned to column 77 (tags_column = -77)",
        expect = { lua = [[return #vim.api.nvim_get_current_line() == 77]] },
      },
      { cmd = "write" },
      {
        expect = {
          file = {
            "chores.org",
            lines = { "* Water the plants", "* TODO Pay rent" .. string.rep(" ", 50) .. ":home:money:" },
          },
        },
      },
    },
  },
  {
    name = "fast tag selection toggles tags by key",
    files = { ["chores.org"] = { "* Water the plants   :home:", "* TODO Pay rent" } },
    open = "chores.org",
    setup = { tags = { "home(h)", "work(w)", "money(m)" } },
    steps = {
      { at = "Water the plants" },
      { key = "{{org.set_tags}}", expect = { screen = { "home", "work", "money" } } },
      { key = "h", expect = { screen = "Current:   ", no_screen = "Current:   :home:" } },
      { key = "w", expect = { screen = "Current:   :work:" } },
      { key = "<CR>", expect = { line = "^%* Water the plants%s+:work:$" } },
      { cmd = "write" },
      {
        expect = {
          file = {
            "chores.org",
            lines = { "* Water the plants" .. string.rep(" ", 53) .. ":work:", "* TODO Pay rent" },
          },
        },
      },
    },
  },
}

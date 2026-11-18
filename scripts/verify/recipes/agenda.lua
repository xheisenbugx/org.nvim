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
  {
    -- an agenda line keeps a marker on its entry (org-hd-marker): another
    -- headline with the same text added above doesn't take its place
    name = "a TODO marked done after its file changed is the line's own entry",
    files = {
      ["same.org"] = { "* TODO Same", "  SCHEDULED: <2026-10-12 Mon>", "* TODO Same", "  DEADLINE: <2026-10-12 Mon>" },
    },
    open = "same.org",
    setup = { agenda_files = { "{{dir}}/same.org" } },
    steps = {
      { key = "{{global.agenda}}a", expect = { screen = { "Scheduled:  TODO Same", "Deadline:   TODO Same" } } },
      { note = "back to the file", key = "<C-w>w", expect = { filetype = "org" } },
      {
        note = "a headline with the same text at the top",
        key = "ggO* TODO Same<Esc>",
        expect = { buffer = "^%* TODO Same$", lua = "return vim.api.nvim_buf_line_count(0) == 5" },
      },
      { key = "<C-w>w", expect = { filetype = "orgagenda" } },
      { at = "Scheduled:" },
      { key = "{{agenda.todo}}", expect = { screen = "Scheduled:  DONE Same" } },
      { key = "{{agenda.save_all}}" },
      {
        note = "the scheduled entry is DONE, the new headline and the deadline untouched",
        expect = {
          file = {
            "same.org",
            lines = {
              "* TODO Same",
              "* DONE Same",
              "  SCHEDULED: <2026-10-12 Mon>",
              "* TODO Same",
              "  DEADLINE: <2026-10-12 Mon>",
            },
          },
        },
      },
    },
  },
  {
    -- org-fit-window-to-buffer leaves a window that isn't full-width alone
    name = "redoing an agenda beside its entry keeps the window height",
    files = { ["todo.org"] = todo },
    open = "todo.org",
    setup = setup,
    steps = {
      { key = "{{global.agenda}}t", expect = { filetype = "orgagenda" } },
      {
        note = "the agenda the only window",
        key = "<C-w>o",
        expect = { lua = "return #vim.api.nvim_list_wins() == 1" },
      },
      { at = "Renew the passport" },
      {
        note = "the entry opens beside the agenda",
        key = "{{agenda.goto}}",
        expect = { filetype = "org", lua = "return vim.api.nvim_win_get_width(0) < vim.o.columns" },
      },
      { key = "<C-w>w", expect = { filetype = "orgagenda" } },
      { lua = "_G.verify_fit = { vim.o.cmdheight, vim.api.nvim_win_get_height(0) }" },
      { key = "{{agenda.redo}}" },
      { key = "{{agenda.redo}}" },
      {
        note = "the command line and the agenda keep their heights",
        key = "{{agenda.redo}}",
        expect = {
          lua = "return vim.o.cmdheight == _G.verify_fit[1] and vim.api.nvim_win_get_height(0) == _G.verify_fit[2]",
        },
      },
    },
  },
  {
    -- org-agenda-skip skips a file whose #+FILETAGS has ARCHIVE, unless
    -- archived trees are included (org-agenda-archives-mode)
    name = "a file tagged ARCHIVE in its FILETAGS stays out until archives mode",
    files = {
      ["old.org"] = { "#+FILETAGS: :ARCHIVE:", "* TODO Old shelved task", "  SCHEDULED: <2026-10-12 Mon>" },
      ["live.org"] = { "* TODO Live task", "  SCHEDULED: <2026-10-12 Mon>" },
    },
    open = "live.org",
    setup = { agenda_files = { "{{dir}}/old.org", "{{dir}}/live.org" } },
    steps = {
      {
        key = "{{global.agenda}}a",
        expect = { screen = "Scheduled:  TODO Live task", no_screen = "Old shelved task" },
      },
      {
        key = "{{agenda.archives_mode}}",
        expect = { screen = { "Scheduled:  TODO Old shelved task", "Scheduled:  TODO Live task" } },
      },
      { key = "{{agenda.archives_mode}}", expect = { no_screen = "Old shelved task" } },
    },
  },
}

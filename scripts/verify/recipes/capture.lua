-- Capture (feature map: .claude/skills/verify-org/features/capture.md).
-- The clock is Monday 2026-10-12 09:00.
local setup = {
  capture = {
    templates = {
      t = { description = "Task", template = "* TODO %?\n  %U", target = "{{dir}}/inbox.org" },
      n = { description = "Note", template = "* %?", target = "{{dir}}/notes.org", headline = "Notes" },
    },
  },
}

return {
  {
    name = "a task captured with a template is filed in its target",
    files = { ["inbox.org"] = { "#+TITLE: Inbox" } },
    setup = setup,
    steps = {
      { key = "{{global.capture}}", expect = { screen = { "Task", "Note" } } },
      { key = "t", expect = { buffer = "^%* TODO $", mode = "i" } },
      { type = "Buy milk" },
      { key = "<Esc>{{capture.finalize}}", expect = { no_screen = "Buy milk" } },
      {
        expect = {
          file = { "inbox.org", lines = { "#+TITLE: Inbox", "* TODO Buy milk", "  [2026-10-12 Mon 09:00]" } },
        },
      },
    },
  },
  {
    name = "a note goes under its headline",
    files = { ["notes.org"] = { "* Notes", "* Other" } },
    setup = setup,
    steps = {
      { key = "{{global.capture}}n", expect = { mode = "i" } },
      { type = "Parking is on level 3" },
      { key = "<Esc>{{capture.finalize}}" },
      { expect = { file = { "notes.org", lines = { "* Notes", "** Parking is on level 3", "* Other" } } } },
    },
  },
  {
    name = "C-c C-c finalizes from Insert mode",
    files = { ["inbox.org"] = { "#+TITLE: Inbox" } },
    setup = setup,
    steps = {
      { key = "{{global.capture}}t", expect = { mode = "i" } },
      { type = "Water the plants" },
      { key = "<C-c><C-c>", expect = { no_screen = "Water the plants" } },
      { expect = { file = { "inbox.org", "^%* TODO Water the plants$" } } },
    },
  },
  {
    name = "an immediate capture whose target can't be saved keeps its text",
    files = { ["locked.org"] = { "* Inbox" } },
    -- (the warning names the file and the error: wide enough for it to
    -- show without a hit-enter prompt)
    width = 240,
    setup = {
      capture = {
        templates = {
          q = {
            description = "Quick",
            template = "* Call the bank",
            target = "{{dir}}/locked.org",
            headline = "Inbox",
            immediate_finish = true,
          },
        },
      },
    },
    steps = {
      { lua = "vim.fn.setfperm((...) .. '/locked.org', 'r--r--r--')", note = "the target file is read-only" },
      {
        key = "{{global.capture}}q",
        allow_error = true,
        expect = { screen = "Capture could not be saved" },
      },
      {
        cmd = "buffer locked.org",
        expect = { buffer = "^%*%* Call the bank$", lua = "return vim.bo.modified" },
        note = "the text is still in the target buffer, unsaved",
      },
      { expect = { file = { "locked.org", lines = { "* Inbox" } } } },
    },
  },
  {
    name = "a killed capture leaves the target alone",
    files = { ["inbox.org"] = { "#+TITLE: Inbox" } },
    setup = setup,
    steps = {
      { key = "{{global.capture}}t", expect = { mode = "i" } },
      { type = "Never mind" },
      { key = "<Esc>{{capture.kill}}", expect = { no_screen = "Never mind" } },
      { expect = { file = { "inbox.org", lines = { "#+TITLE: Inbox" } } } },
    },
  },
}

-- Try org.nvim without touching your own config:
--
--   nvim -u examples/minimal_init.lua examples/tutorial.org
--
-- The agenda reads the files in this directory, and captures go to a scratch
-- directory under stdpath("state"), so your real notes are never touched.
local examples = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(examples, ":h")
local scratch = vim.fn.stdpath("state") .. "/org-tutorial"
vim.fn.mkdir(scratch, "p")

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"
vim.opt.rtp:prepend(root)
vim.opt.termguicolors = true
vim.opt.swapfile = false

require("org").setup({
  org_directory = scratch,
  agenda_files = { examples .. "/*.org", scratch .. "/*.org" },
  default_notes_file = scratch .. "/inbox.org",
  enforce_todo_dependencies = true,
  -- Only the project heading itself is a project, not its tasks.
  tags_exclude_from_inheritance = { "project" },

  agenda = {
    stuck_projects = { match = "+project/-DONE" },
    custom_commands = {
      w = {
        description = "Work overview",
        types = {
          { type = "agenda", span = "day", header = "Today" },
          { type = "tags_todo", match = "+work/!", header = "Open work tasks" },
          { type = "todo", match = "WAITING", header = "Waiting for" },
        },
      },
      u = { description = "Urgent", type = "tags", match = 'PRIORITY="A"|+urgent' },
    },
  },

  capture = {
    templates = {
      t = { description = "Task", template = "* TODO %?\n  %U\n  %a\n  %i", target = "inbox.org" },
      w = "Work",
      wt = { description = "Work task", template = "* TODO %? :work:", target = "work.org", headline = "Inbox" },
      wm = {
        description = "Meeting",
        template = "* %^{Who} %^g\n  %T\n  %?",
        target = "work.org",
        olp = { "Meetings" },
        clock_in = true,
      },
      j = { description = "Journal", template = "* %<%H:%M> %?", target = "journal.org", datetree = true },
      s = {
        description = "Shopping item",
        type = "checkitem",
        template = "[ ] %?",
        target = "inbox.org",
        headline = "Shopping",
      },
      x = {
        description = "Expense",
        type = "table-line",
        template = "| %u | %^{Amount} | %^{What} |",
        target = "inbox.org",
        headline = "Expenses",
        immediate_finish = true,
      },
    },
  },

  -- Keep the clock and ID index of the tutorial separate from your own.
  clock = { persist_file = scratch .. "/clock.json" },
  id = { locations_file = scratch .. "/id-locations.json" },

  ui = {
    bullets = { "◉", "○", "✸", "✿" },
    checkboxes = { " ", "◐", "✓" },
  },
})

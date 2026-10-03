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

-- doc/tags is not in the repo (plugin managers build it), so build the help
-- tags of a copy of the manual under the scratch directory: `:h org` then
-- works from a plain clone without writing into it.
local help = scratch .. "/help"
vim.fn.mkdir(help .. "/doc", "p")
vim.fn.writefile(vim.fn.readfile(root .. "/doc/org.txt"), help .. "/doc/org.txt")
if pcall(vim.cmd.helptags, vim.fn.fnameescape(help .. "/doc")) then
  vim.opt.rtp:append(help)
end

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
        headline = "Meetings",
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

  -- Refile to any heading of the agenda files, labelled with its file and
  -- outline path (tutorial.org/Refile and archive/Refiling/Projects).
  refile = {
    targets = { { files = "agenda", max_level = 3 } },
    use_outline_path = "file",
  },

  -- Keep the clock and ID index of the tutorial separate from your own. A
  -- running clock is saved on exit and resumed (after asking) next time.
  clock = { persist = true, persist_file = scratch .. "/clock.json" },
  id = { locations_file = scratch .. "/id-locations.json" },

  ui = {
    bullets = { "◉", "○", "✸", "✿" },
    checkboxes = { " ", "◐", "✓" },
  },
})

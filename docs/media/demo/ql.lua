-- Config for the org-ql and super-agenda tapes: the demo config
-- (init.lua) with the two extensions turned on.
--
--   export ORG_DEMO_DIR=/tmp/org-nvim-demo
--   nvim -u docs/media/demo/ql.lua $ORG_DEMO_DIR/notes.org
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")

local opts = vim.deepcopy(require("org.config").opts)
opts.extensions = {
  ql = {
    views = {
      Deadlines = { query = "(deadline :to 7)", sort = "deadline", title = "Deadlines this week" },
    },
    views_file = false,
  },
  super_agenda = {
    groups = {
      { name = "Schedule", time_grid = true },
      { name = "Overdue", deadline = "past", scheduled = "past", order = 1 },
      { name = "Important", priority = "A", order = 2 },
      { name = "Habits", habit = true, order = 3 },
      { name = "Waiting on others", todo = "WAITING", order = 4 },
      { auto_category = true, order = 9 },
    },
  },
}
require("org").setup(opts)

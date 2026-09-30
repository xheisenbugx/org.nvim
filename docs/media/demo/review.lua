-- The demo config (init.lua) with the review extension on, for
-- tapes/review.tape. review/*.org are copied to $ORG_DEMO_DIR (with the
-- {{N}} dates of init.lua) and added to the agenda files.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")

local dir = vim.env.ORG_DEMO_DIR or "/tmp/org-nvim-demo"
for _, src in ipairs(vim.fn.glob(here .. "/review/*.org", false, true)) do
  local text = table.concat(vim.fn.readfile(src), "\n")
  text = text:gsub("{{(%-?%d+)}}", function(offset)
    return os.date("%Y-%m-%d %a", os.time() + tonumber(offset) * 86400)
  end)
  vim.fn.writefile(vim.split(text, "\n"), dir .. "/" .. vim.fn.fnamemodify(src, ":t"))
end

-- init.lua has run setup(): turn the extension on the way setup() does
local config = require("org.config")
table.insert(config.opts.agenda_files, dir .. "/goals.org")
config.opts.agenda.stuck_projects = { match = "+project+LEVEL=1/-DONE", todo_keywords = { "TODO", "NEXT" } }
config.opts.extensions = {
  review = {
    log_file = dir .. "/review.org",
    state_file = dir .. "/review.json",
    width = 84,
    height = 22,
    questions = { "What went well this week?", "What will I focus on next week?" },
  },
}
require("org.extensions").setup()
require("org.mappings").setup_global()

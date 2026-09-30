-- Demo config for tapes/kanban.tape: init.lua plus the kanban extension,
-- on views/board.org.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local dir = dofile(here .. "/views.lua")

local config = require("org.config")
config.opts.extensions = {
  kanban = {
    source = dir .. "/board.org",
    columns = { "TODO", "NEXT", "WAITING", "DONE" },
    wip = { NEXT = 3 },
    save = true,
  },
}
require("org.extensions").setup()
require("org.mappings").setup_global()

-- Demo config for tapes/sidebar.tape: init.lua plus the sidebar extension;
-- views/today.org adds two appointments later today to the agenda files.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local dir = dofile(here .. "/views.lua")

local config = require("org.config")
table.insert(config.opts.agenda_files, dir .. "/today.org")
config.opts.extensions = {
  sidebar = { width = 42, interval = 5 },
}
require("org.extensions").setup()
require("org.mappings").setup_global()

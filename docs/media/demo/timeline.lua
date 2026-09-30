-- Demo config for tapes/timeline.tape: init.lua plus the timeline
-- extension, on views/plan.org.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local dir = dofile(here .. "/views.lua")

local config = require("org.config")
config.opts.extensions = {
  timeline = { source = dir .. "/plan.org", show_done = true, label_width = 30 },
}
require("org.extensions").setup()
require("org.mappings").setup_global()

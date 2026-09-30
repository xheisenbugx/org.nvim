-- Demo config for tapes/heatmap.tape: init.lua plus the heatmap extension,
-- on views/clocklog.org (nine months of CLOCK lines and closed tasks).
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local dir = dofile(here .. "/views.lua")

local config = require("org.config")
config.opts.extensions = {
  heatmap = { source = dir .. "/clocklog.org" },
}
require("org.extensions").setup()
require("org.mappings").setup_global()

-- Minimal init for headless tests: only this plugin on the runtimepath.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp = { root, vim.env.VIMRUNTIME }
vim.opt.swapfile = false
vim.opt.hidden = true
vim.opt.shadafile = "NONE"
vim.g.mapleader = " "
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
vim.cmd("runtime plugin/org.lua")
-- Resolving dangling clocks on clock in prompts, which would block (or, on
-- EOF, quit) headless tests: off unless a test turns it on.
local config = require("org.config")
local config_setup = config.setup
config.setup = function(opts)
  return config_setup(vim.tbl_deep_extend("keep", opts or {}, { clock = { auto_clock_resolution = false } }))
end
require("org").setup({
  org_directory = root .. "/tests/fixtures",
  agenda_files = { root .. "/tests/fixtures/*.org" },
})

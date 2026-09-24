-- Minimal init for headless tests: only this plugin on the runtimepath.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp = { root, vim.env.VIMRUNTIME }
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.g.mapleader = " "
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
vim.cmd("runtime plugin/org.lua")
require("org").setup({
  org_directory = root .. "/tests/fixtures",
  agenda_files = { root .. "/tests/fixtures/*.org" },
})

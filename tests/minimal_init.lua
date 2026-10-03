-- Minimal init for headless tests: only this plugin on the runtimepath.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
-- `make coverage`: count the lines of lua/org that run, from the first
-- module loaded on (tests/coverage.lua)
if (vim.env.ORG_COVERAGE_DIR or "") ~= "" then
  package.loaded["tests.coverage"] = dofile(root .. "/tests/coverage.lua")
  package.loaded["tests.coverage"].start(vim.env.ORG_COVERAGE_DIR)
end
vim.opt.rtp = { root, vim.env.VIMRUNTIME }
vim.opt.swapfile = false
vim.opt.hidden = true
vim.opt.shadafile = "NONE"
vim.g.mapleader = " "
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
vim.cmd("runtime plugin/org.lua")
-- Specs delete their temp files while buffers may still show them. A
-- timestamp check (pending after any external command) would then raise
-- E211 from an unrelated :bwipeout in a later spec: ignore deleted files,
-- keep the default handling ("ask") of every other change.
vim.api.nvim_create_autocmd("FileChangedShell", {
  callback = function()
    vim.v.fcs_choice = vim.v.fcs_reason == "deleted" and "" or "ask"
  end,
})
-- Resolving dangling clocks on clock in, resuming a saved clock and
-- quitting with a running clock prompt, which would block (or, on EOF,
-- quit) headless tests: off unless a test turns them on.
local config = require("org.config")
local config_setup = config.setup
config.setup = function(opts)
  return config_setup(vim.tbl_deep_extend("keep", opts or {}, {
    clock = { auto_clock_resolution = false, ask_before_exiting = false, persist_query_resume = false },
  }))
end
require("org").setup({
  org_directory = root .. "/tests/fixtures",
  agenda_files = { root .. "/tests/fixtures/*.org" },
})

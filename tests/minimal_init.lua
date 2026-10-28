-- Minimal init for headless tests: only this plugin on the runtimepath.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
-- `make coverage`: count the lines of lua/org that run, from the first
-- module loaded on (tests/coverage.lua)
if (vim.env.ORG_COVERAGE_DIR or "") ~= "" then
  package.loaded["tests.coverage"] = dofile(root .. "/tests/coverage.lua")
  package.loaded["tests.coverage"].start(vim.env.ORG_COVERAGE_DIR)
  -- the `org` command line runs in a Neovim of its own (bin/org): start it
  -- through tests/cli_coverage.lua, so its lines count too
  local bin = vim.fs.normalize(root .. "/bin/org")
  local system = vim.system
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.system = function(cmd, opts, on_exit)
    if type(cmd) == "table" and type(cmd[1]) == "string" and vim.fs.normalize(cmd[1]) == bin then
      local nvim = opts and opts.env and opts.env.ORG_NVIM_BIN or vim.v.progpath
      cmd = vim.list_extend({ nvim, "--headless", "-l", root .. "/tests/cli_coverage.lua" }, cmd, 2)
    end
    return system(cmd, opts, on_exit)
  end
end
vim.opt.rtp = { root, vim.env.VIMRUNTIME }
-- never reach a session server of the user's own Neovim (:h org-remote):
-- the CLI specs and the Neovims they start inherit this
vim.env.ORG_NVIM_SERVER = "none"
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
-- quit) headless tests: off unless a test turns them on. The agenda index
-- stays on (agenda views use it and add to it as they are built), but
-- without background parsing and watchers, whose timing would vary from
-- run to run (agenda_index_spec.lua turns them on). Buffers aren't reloaded
-- when their file changes on disk either (specs rewrite fixture files under
-- open buffers; reload_spec.lua turns it on).
local config = require("org.config")
local config_setup = config.setup
config.setup = function(opts)
  return config_setup(vim.tbl_deep_extend("keep", opts or {}, {
    clock = { auto_clock_resolution = false, ask_before_exiting = false, persist_query_resume = false },
    agenda = { index = { background = false, watch = false } },
    reload_on_change = false,
  }))
end
require("org").setup({
  org_directory = root .. "/tests/fixtures",
  agenda_files = { root .. "/tests/fixtures/*.org" },
})

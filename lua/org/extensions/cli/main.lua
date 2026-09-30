-- Entry point of the `org` command line (bin/org):
--
--   nvim --headless -l lua/org/extensions/cli/main.lua agenda week
--
-- `nvim -l` skips the user's config and plugins, so this puts the plugin on
-- the runtimepath, runs the command and exits with its code.
local src = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.resolve(src), ":p:h:h:h:h:h")
vim.opt.rtp:prepend(root)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.more = false
vim.cmd("runtime plugin/org.lua")

local argv = {}
for i = 1, #(_G.arg or {}) do
  argv[i] = _G.arg[i]
end
local code = require("org.extensions.cli.run").main(argv)
io.stdout:flush()
io.stderr:flush()
os.exit(code, true)

-- Demo config for docs/media/tapes/quickadd.tape: init.lua plus the
-- quickadd extension, adding to demo/quickadd/planner.org.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")
local dir = vim.env.ORG_DEMO_DIR or "/tmp/org-nvim-demo"
for _, src in ipairs(vim.fn.glob(here .. "/quickadd/*.org", false, true)) do
  vim.fn.writefile(vim.fn.readfile(src), dir .. "/" .. vim.fn.fnamemodify(src, ":t"))
end
local opts = vim.deepcopy(require("org.config").opts)
opts.extensions = {
  quickadd = { file = "planner.org", headline = "Inbox", targets = { dir .. "/planner.org" } },
}
require("org").setup(opts)

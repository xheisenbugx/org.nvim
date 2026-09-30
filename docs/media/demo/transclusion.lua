-- The demo config (init.lua) with the transclusion extension on, for
-- tapes/transclusion.tape. The files in transclusion/ are copied to
-- $ORG_DEMO_DIR.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")

local dir = vim.env.ORG_DEMO_DIR or "/tmp/org-nvim-demo"
for _, src in ipairs(vim.fn.glob(here .. "/transclusion/*", false, true)) do
  vim.uv.fs_copyfile(src, dir .. "/" .. vim.fn.fnamemodify(src, ":t"))
end
-- the signs of inserted text
vim.opt.signcolumn = "yes:1"

-- init.lua has run setup(): turn the extension on the way setup() does
require("org.config").opts.extensions = { transclusion = { edit = { width = 72 } } }
require("org.extensions").setup()

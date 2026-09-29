-- The demo config (init.lua) with the org-roam extension on, for
-- tapes/roam.tape. The notes in roam/ are copied to $ORG_DEMO_DIR/roam.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")

local dir = (vim.env.ORG_DEMO_DIR or "/tmp/org-nvim-demo") .. "/roam"
vim.fn.mkdir(dir .. "/daily", "p")
for _, src in ipairs(vim.fn.glob(here .. "/roam/*.org", false, true)) do
  vim.uv.fs_copyfile(src, dir .. "/" .. vim.fn.fnamemodify(src, ":t"))
end

-- init.lua has run setup(): turn the extension on the way setup() does
local config = require("org.config")
config.opts.extensions = {
  roam = {
    directory = dir,
    index_file = dir .. "/../roam-index.json",
    buffer = { width = 52, sections = { "backlinks", "unlinked" } },
    capture_templates = {
      d = {
        description = "default",
        type = "plain",
        template = "%?",
        target = "${slug}.org",
        head = "#+title: ${title}\n",
        unnarrowed = true,
      },
    },
  },
}
require("org.extensions").setup()
require("org.mappings").setup_global()

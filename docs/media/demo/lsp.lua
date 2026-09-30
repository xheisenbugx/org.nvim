-- The demo config (init.lua) with the lsp extension on, for
-- tapes/lsp.tape. The files in lsp/ are copied to $ORG_DEMO_DIR/lsp.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")

local dir = (vim.env.ORG_DEMO_DIR or "/tmp/org-nvim-demo") .. "/lsp"
vim.fn.mkdir(dir, "p")
for _, src in ipairs(vim.fn.glob(here .. "/lsp/*.org", false, true)) do
  local text = table.concat(vim.fn.readfile(src), "\n"):gsub("{{(%-?%d+)}}", function(offset)
    return os.date("%Y-%m-%d %a", os.time() + tonumber(offset) * 86400)
  end)
  vim.fn.writefile(vim.split(text, "\n"), dir .. "/" .. vim.fn.fnamemodify(src, ":t"))
end

-- file names relative to the demo directory in the location list
vim.fn.chdir(vim.uv.fs_realpath(dir) or dir)

vim.diagnostic.config({ virtual_text = { prefix = "●" }, signs = false, severity_sort = true })
vim.o.winborder = "rounded"

-- init.lua has run setup(): turn the extension on the way setup() does
require("org.config").opts.extensions.lsp = { diagnostics = { debounce = 200 } }
require("org.extensions").setup()

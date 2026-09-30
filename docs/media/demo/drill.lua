-- The demo config (init.lua) with the drill extension on, for
-- tapes/drill.tape. The cards in drill/ are copied to $ORG_DEMO_DIR.
--
--   export ORG_DEMO_DIR=/tmp/org-demo-drill
--   nvim -u docs/media/demo/drill.lua $ORG_DEMO_DIR/cards.org
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")

local dir = vim.env.ORG_DEMO_DIR or "/tmp/org-nvim-demo"
for _, src in ipairs(vim.fn.glob(here .. "/drill/*.org", false, true)) do
  local text = table.concat(vim.fn.readfile(src), "\n")
  text = text:gsub("{{(%-?%d+)}}", function(offset)
    return os.date("%Y-%m-%d %a", os.time() + tonumber(offset) * 86400)
  end)
  vim.fn.writefile(vim.split(text, "\n"), dir .. "/" .. vim.fn.fnamemodify(src, ":t"))
end

-- init.lua has run setup(): turn the extension on the way setup() does
require("org.config").opts.extensions = { drill = { shuffle = false, width = 64 } }
require("org.extensions").setup()
require("org.mappings").setup_global()
-- the same side of the two-sided card every time
require("org.extensions.drill").random = function()
  return 2
end

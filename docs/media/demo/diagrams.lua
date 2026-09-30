-- Demo config for docs/media/tapes/diagrams.tape: init.lua plus the
-- diagrams extension, rendering on save. It needs mmdc (mermaid-cli): on
-- $PATH, or its path in $DEMO_MMDC; $DEMO_MMDC_PUPPETEER can name a
-- puppeteer config file (e.g. one pointing at an installed Chrome).
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")
require("org.config").opts.babel.confirm_evaluate = false
vim.o.warn = false
require("org.config").opts.extensions.diagrams = {
  mermaid = { command = vim.env.DEMO_MMDC or "mmdc", puppeteer_config = vim.env.DEMO_MMDC_PUPPETEER },
  cache_dir = (vim.env.ORG_DEMO_DIR or "/tmp/org-nvim-demo") .. "/.diagram-cache",
  render_on_save = true,
}
require("org.extensions").setup()

-- Demo config for docs/media/tapes/present.tape: init.lua plus the
-- present extension.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")
require("org.config").opts.extensions.present = { width = 64, padding_top = 3 }
require("org.extensions").setup()

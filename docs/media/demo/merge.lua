-- Demo config for docs/media/tapes/merge.tape: init.lua plus the merge
-- extension. The tape builds its git repository with merge-setup.sh.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")
require("org.config").opts.extensions.merge = {}
require("org.extensions").setup()

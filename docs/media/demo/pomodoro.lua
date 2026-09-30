-- Demo config for docs/media/tapes/pomodoro.tape: init.lua plus the
-- pomodoro extension, with pomodoros and breaks a few seconds long.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")

local opts = vim.deepcopy(require("org.config").opts)
opts.extensions = {
  pomodoro = { work = 0.15, short_break = 0.1, system_notification = false },
}
require("org").setup(opts)

-- Demo config for tapes/sidebar.tape: init.lua plus the sidebar extension;
-- views/today.org adds two appointments later today to the agenda files.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

-- The demo's clock starts at 10:00 today whenever it is recorded (and runs
-- on from there), so the {{now+N}} appointments of views/today.org never
-- cross midnight and the countdowns look the same in every recording.
do
  local real_time, real_date = os.time, os.date
  local t = real_date("*t")
  t.hour, t.min, t.sec = 10, 0, 0
  local offset = real_time(t) - real_time()
  os.time = function(tbl)
    if tbl ~= nil then
      return real_time(tbl)
    end
    return real_time() + offset
  end
  os.date = function(fmt, time)
    return real_date(fmt, time or os.time())
  end
end

local dir = dofile(here .. "/views.lua")

local config = require("org.config")
table.insert(config.opts.agenda_files, dir .. "/today.org")
config.opts.extensions = {
  sidebar = { width = 42, interval = 5 },
}
require("org.extensions").setup()
require("org.mappings").setup_global()

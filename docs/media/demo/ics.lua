-- Demo config for docs/media/tapes/ics.tape: init.lua plus the ics
-- extension, subscribed to demo/ics-*.ics. Like the org files, their
-- {{N}} become the date N days from today (as YYYYMMDD).
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")

local dir = vim.env.ORG_DEMO_DIR or "/tmp/org-nvim-demo"
vim.fn.mkdir(dir .. "/calendars", "p")
local calendars = {}
for _, src in ipairs(vim.fn.glob(here .. "/ics-*.ics", false, true)) do
  local text = table.concat(vim.fn.readfile(src), "\r\n")
  text = text:gsub("{{(%-?%d+)}}", function(offset)
    return os.date("%Y%m%d", os.time() + tonumber(offset) * 86400)
  end)
  local name = vim.fn.fnamemodify(src, ":t:r"):gsub("^ics%-", "")
  local dest = dir .. "/calendars/" .. name .. ".ics"
  local fh = assert(io.open(dest, "wb"))
  fh:write(text .. "\r\n")
  fh:close()
  calendars[#calendars + 1] = { name = name, path = dest, tags = { "cal" } }
end

require("org.config").opts.extensions.ics = { calendars = calendars, import_file = dir .. "/inbox.org" }
require("org.extensions").setup()

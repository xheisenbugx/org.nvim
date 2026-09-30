-- CLI config for docs/media/tapes/cli.tape: `org --config` (or
-- $ORG_NVIM_CONFIG) loads this file. The first run copies the demo *.org
-- files into $ORG_DEMO_DIR like init.lua ({{N}} becomes the date N days
-- from today); later runs reuse them, so captures and clocks stay.
--
--   export ORG_DEMO_DIR=/tmp/org-demo-cli ORG_NVIM_CONFIG=$PWD/docs/media/demo/cli.lua
--   bin/org agenda
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local dir = vim.env.ORG_DEMO_DIR or "/tmp/org-demo-cli"

if vim.fn.filereadable(dir .. "/.cli-demo") == 0 then
  vim.fn.mkdir(dir, "p")
  for _, name in ipairs({ "work.org", "life.org", "inbox.org" }) do
    local text = table.concat(vim.fn.readfile(here .. "/" .. name), "\n")
    text = text:gsub("{{(%-?%d+)%s*([%d:%-]*)}}", function(offset, time)
      local date = os.date("%Y-%m-%d %a", os.time() + tonumber(offset) * 86400)
      return time ~= "" and (date .. " " .. time) or date
    end)
    vim.fn.writefile(vim.split(text, "\n"), dir .. "/" .. name)
  end
  vim.fn.writefile({}, dir .. "/.cli-demo")
end

return {
  org_directory = dir,
  agenda_files = { dir .. "/work.org", dir .. "/life.org", dir .. "/inbox.org" },
  todo_keywords = { "TODO(t) NEXT(n) WAITING(w) | DONE(d) CANCELLED(c)" },
  agenda = { span = "day", time_grid = { type = { "daily", "today", "require-timed" }, times = {} } },
  capture = {
    templates = {
      t = { description = "Task", template = "* TODO %?\n  %U", target = dir .. "/inbox.org" },
    },
  },
  clock = { persist = true, persist_file = dir .. "/clock.json" },
  id = { locations_file = dir .. "/id-locations.json" },
}

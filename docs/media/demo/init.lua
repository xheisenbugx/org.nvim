-- Config used to record the screenshots and GIFs in docs/media.
--
--   export ORG_DEMO_DIR=/tmp/org-nvim-demo
--   nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/notes.org
--
-- On startup it copies the *.org files next to it into $ORG_DEMO_DIR,
-- turning {{N}} into the date N days from today ({{2 09:30}} adds a time),
-- so the agenda always has something to show.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h:h:h")
local dir = vim.env.ORG_DEMO_DIR or "/tmp/org-nvim-demo"

vim.fn.delete(dir, "rf")
vim.fn.mkdir(dir, "p")
for _, src in ipairs(vim.fn.glob(here .. "/*.org", false, true)) do
  local text = table.concat(vim.fn.readfile(src), "\n")
  text = text:gsub("{{(%-?%d+)%s*([%d:%-]*)}}", function(offset, time)
    local date = os.date("%Y-%m-%d %a", os.time() + tonumber(offset) * 86400)
    return time ~= "" and (date .. " " .. time) or date
  end)
  vim.fn.writefile(vim.split(text, "\n"), dir .. "/" .. vim.fn.fnamemodify(src, ":t"))
end

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"
vim.opt.rtp:prepend(root)
vim.opt.termguicolors = true
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.laststatus = 3
vim.opt.showmode = false
vim.opt.showcmd = false
vim.opt.ruler = false
vim.opt.cmdheight = 1
vim.opt.shortmess:append("IF")
vim.opt.signcolumn = "no"
vim.opt.fillchars = { eob = " " }

require("org").setup({
  org_directory = dir,
  agenda_files = { dir .. "/notes.org", dir .. "/work.org", dir .. "/life.org" },
  default_notes_file = dir .. "/inbox.org",
  log_done = "time",
  todo_keywords = { "TODO(t) NEXT(n) WAITING(w) | DONE(d) CANCELLED(c)" },
  agenda = { span = "day", window = "only" },
  babel = { confirm_evaluate = false },
  capture = {
    templates = {
      t = { description = "Task", template = "* TODO %?\n  %U", target = "inbox.org" },
      w = "Work",
      wt = { description = "Work task", template = "* TODO %? :work:", target = "work.org", headline = "Inbox" },
      wm = { description = "Meeting", template = "* %^{Who}\n  %T\n  %?", target = "work.org" },
      j = { description = "Journal", template = "* %<%H:%M> %?", target = "journal.org", datetree = true },
    },
  },
  clock = { persist_file = dir .. "/clock.json" },
  id = { locations_file = dir .. "/id-locations.json" },
  ui = {
    bullets = { "◉", "○", "✸", "✿" },
    checkboxes = { " ", "◐", "✓" },
  },
})

-- A statusline that shows the file name and the running clock.
vim.opt.statusline = " %t%m %= %{v:lua.require'org'.statusline()} "

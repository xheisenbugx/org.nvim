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
  agenda_files = { dir .. "/notes.org", dir .. "/work.org", dir .. "/life.org", dir .. "/dates.org" },
  default_notes_file = dir .. "/inbox.org",
  log_done = "time",
  todo_keywords = { "TODO(t) NEXT(n) WAITING(w) | DONE(d) CANCELLED(c)" },
  agenda = { span = "day", window = "only" },
  babel = { confirm_evaluate = false },
  refile = { max_level = 1, use_outline_path = "file", outline_path_complete_in_steps = false },
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

-- Key captions. `:Cap {keys} {what}` shows "{keys}  {what}" in the bottom
-- right corner, so a GIF says which key did what; `:Cap` alone hides it.
-- `:Do {keys} {what}` also presses {keys} (in <> notation), because VHS
-- can't send keys like <S-Right> or <M-Up>. The tapes type these hidden,
-- after <C-g>: it opens the command line in any mode, even in buffers
-- where org maps `:` (the agenda).
vim.api.nvim_set_hl(0, "DemoCaption", { fg = "#e0e2ea", bg = "#2c2e33" })
vim.api.nvim_set_hl(0, "DemoCaptionKey", { fg = "#fce094", bg = "#2c2e33", bold = true })
vim.api.nvim_set_hl(0, "DemoCaptionBorder", { fg = "#6b6f79", bg = "#2c2e33" })
local caption = {}
local function show_caption(args)
  if caption.win and vim.api.nvim_win_is_valid(caption.win) then
    vim.api.nvim_win_close(caption.win, true)
  end
  local keys, what = args:match("^(%S+)%s*(.*)$")
  if not keys then
    return
  end
  local text = " " .. keys .. (what ~= "" and ("  " .. what) or "") .. " "
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.api.nvim_buf_set_extmark(buf, vim.api.nvim_create_namespace("demo"), 0, 1, {
    end_col = 1 + #keys,
    hl_group = "DemoCaptionKey",
  })
  local width = vim.fn.strdisplaywidth(text)
  caption.win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = vim.o.lines - 6,
    col = vim.o.columns - width - 3,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = 250,
  })
  vim.wo[caption.win].winhighlight = "Normal:DemoCaption,FloatBorder:DemoCaptionBorder"
end
vim.keymap.set({ "n", "x" }, "<C-g>", ":<C-u>")
vim.keymap.set("i", "<C-g>", "<C-o>:")
vim.api.nvim_create_user_command("Cap", function(o)
  show_caption(o.args)
  vim.api.nvim_echo({ { "" } }, false, {})
end, { nargs = "*" })
vim.api.nvim_create_user_command("Do", function(o)
  show_caption(o.args)
  vim.api.nvim_echo({ { "" } }, false, {})
  local keys = o.args:match("^(%S+)")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "m", false)
end, { nargs = "+" })

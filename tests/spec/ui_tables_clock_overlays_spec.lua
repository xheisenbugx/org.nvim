-- UI sweep: tables, clock overlays, custom times and special windows.

--- Screen text of row `r` (1-based), trailing blanks trimmed.
local function screen_row(r)
  local s = {}
  for c = 1, vim.o.columns do
    s[#s + 1] = vim.fn.screenstring(r, c)
  end
  return (table.concat(s):gsub("%s+$", ""))
end

--- Display column (1-based) where `needle` starts on screen row `r`.
local function screen_col(r, needle)
  local row = screen_row(r)
  local b = row:find(needle, 1, true)
  return b and vim.fn.strdisplaywidth(row:sub(1, b - 1)) + 1 or nil
end

--- Run `fn` with the editor resized to `cols` x `lines`, then restore it.
local function with_size(cols, lines, fn)
  local c, l = vim.o.columns, vim.o.lines
  vim.o.columns, vim.o.lines = cols, lines
  local ok_, err = pcall(fn)
  vim.o.columns, vim.o.lines = c, l
  if not ok_ then
    error(err, 0)
  end
end

describe("special window float", function()
  it("is refitted and recentred on VimResized", function()
    with_size(80, 30, function()
      org_buffer({ "* A", "#+begin_src text", "x = 1", "#+end_src" }, { 3, 0 })
      require("org.context").edit_special()
      local win = vim.api.nvim_get_current_win()
      eq("editor", vim.api.nvim_win_get_config(win).relative)
      vim.o.columns, vim.o.lines = 50, 20
      vim.cmd("doautocmd VimResized")
      eq(40, vim.api.nvim_win_get_width(win))
      eq(14, vim.api.nvim_win_get_height(win))
      local cfg = vim.api.nvim_win_get_config(win)
      eq(5, cfg.col)
      vim.o.columns, vim.o.lines = 160, 40
      vim.cmd("doautocmd VimResized")
      eq(128, vim.api.nvim_win_get_width(win))
      eq(16, vim.api.nvim_win_get_config(win).col)
      vim.api.nvim_win_close(win, true)
    end)
  end)
end)

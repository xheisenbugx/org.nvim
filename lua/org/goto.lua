---@mod org.goto Outline browsing (org-goto)
---
--- `buffer_goto` (C-c C-j) looks up a location in the current file without
--- changing its folds. With `goto_interface = "outline"` (the Emacs
--- default) a read-only copy of the buffer opens in overview; browse it and
--- press <CR> to jump there, <C-g> to go back:
---
---   <CR>             jump to the location (org-goto-ret)
---   <Left> <Right>   on a headline: jump to it (org-goto-left / -right)
---   <C-g>            quit (org-goto-quit); also `q` without auto-isearch
---   <Tab>            cycle visibility
---   <Down> <Up>      next / previous visible headline
---   /                sparse tree (org-occur)
---   <C-c><C-n> <C-p> <C-f> <C-b> <C-u>   headline motions
---   typing           search the headlines (org-goto-local-auto-isearch)
---                    with `goto_auto_isearch`; else n p f b u move and q
---                    quits.
---
--- With `goto_interface = "outline-path-completion"` headlines are picked
--- by their outline path (down to `goto_max_level`). A count uses the other
--- interface.

local config = require("org.config")
local utils = require("org.utils")

local M = {}

local HELP = "RET=jump  C-g=quit  Up/Down=next/prev headline  TAB=cycle  /=sparse tree"

--- Make line `lnum` of the current window visible when it is hidden,
--- with the context `detail` (org-fold-show-set-visibility), or open the
--- folds around it (`zv`) outside an Org fold setup.
local function reveal(lnum, detail)
  local fold = require("org.fold")
  if fold.line_visible(lnum) then
    return
  end
  if not pcall(fold.show_context, lnum, detail) then
    pcall(vim.cmd, "normal! zv")
  end
end

local function jump(win, lnum, col)
  vim.api.nvim_set_current_win(win)
  vim.cmd("normal! m'")
  local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
  vim.api.nvim_win_set_cursor(win, { lnum, math.min(col or 0, math.max(#line - 1, 0)) })
  -- show the location, keeping the other folds (org-fold-show-context
  -- 'org-goto: `fold_show_context_detail`)
  reveal(lnum, require("org.fold").context_detail("org-goto"))
end

--- The outline path completion interface (org-refile-get-location "Goto"),
--- headlines down to `goto_max_level`.
function M.completion()
  local file = require("org.files").get_buffer(0)
  local max = config.opts.goto_max_level or 5
  local heads = vim.tbl_filter(function(h)
    return h.level <= max
  end, file.headlines)
  if #heads == 0 then
    utils.warn("No headlines in buffer")
    return
  end
  local choice = utils.select(heads, {
    prompt = "Goto",
    format_item = function(h)
      local path = h:outline_path()
      path[#path + 1] = h:plain_title()
      return table.concat(path, "/")
    end,
  })
  if choice then
    jump(vim.api.nvim_get_current_win(), choice.line)
  else
    utils.notify("Quit")
  end
end

--- Start the outline interface (org-goto-location).
function M.outline()
  local src_win = vim.api.nvim_get_current_win()
  local src_buf = vim.api.nvim_get_current_buf()
  local start = vim.api.nvim_win_get_cursor(src_win)
  local old = vim.fn.bufnr("*org-goto*")
  if old ~= -1 then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  pcall(vim.api.nvim_buf_set_name, buf, "*org-goto*")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.api.nvim_buf_get_lines(src_buf, 0, -1, false))
  -- the whole screen, like Emacs's full frame: a tab of its own
  vim.cmd("tab split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].filetype = "org"
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  local auto = config.opts.goto_auto_isearch ~= false
  vim.wo[win].winbar = HELP .. (auto and "  Just type for auto-isearch." or "  n/p/f/b/u to navigate, q to quit.")
  require("org.fold").overview()
  local start_line = math.min(start[1], vim.api.nvim_buf_line_count(buf))
  vim.api.nvim_win_set_cursor(win, { start_line, start[2] })
  reveal(start_line, "lineage")
  utils.notify("Select location and press RET")

  local done = false
  local function finish(lnum, col)
    if done then
      return
    end
    done = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    if vim.api.nvim_win_is_valid(src_win) then
      vim.api.nvim_set_current_win(src_win)
    end
    if lnum then
      jump(src_win, lnum, col)
    else
      utils.notify("Quit")
    end
  end
  local function cur()
    return vim.api.nvim_win_get_cursor(0)[1]
  end
  local function on_heading()
    return require("org.parser").headline_level(vim.api.nvim_get_current_line()) ~= nil
  end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "org-goto: " .. desc })
  end
  local structure = require("org.structure")
  -- <CR> and <Right> keep the column, <Left> goes to the line's start
  -- (org-goto-ret, org-goto-right, org-goto-left)
  local function col()
    return vim.api.nvim_win_get_cursor(0)[2]
  end
  map("<CR>", function()
    finish(cur(), col())
  end, "jump to the location")
  for _, key in ipairs({ "<Left>", "<Right>" }) do
    map(key, function()
      if on_heading() then
        finish(cur(), key == "<Right>" and col() or 0)
      else
        utils.warn("Not on a heading")
      end
    end, "jump to the headline")
  end
  map("<C-g>", function()
    finish(nil)
  end, "quit")
  map("<Tab>", function()
    require("org.fold").cycle()
  end, "cycle")
  map("<Down>", structure.next_heading, "next visible headline")
  map("<Up>", structure.prev_heading, "previous visible headline")
  map("<C-c><C-n>", structure.next_heading, "next visible headline")
  map("<C-c><C-p>", structure.prev_heading, "previous visible headline")
  map("<C-c><C-f>", structure.next_sibling, "next headline at the same level")
  map("<C-c><C-b>", structure.prev_sibling, "previous headline at the same level")
  map("<C-c><C-u>", structure.goto_parent, "up one level")
  map("/", function()
    utils.run(function()
      local re = utils.input({ prompt = "Regexp: " })
      if re and re ~= "" then
        require("org.agenda.sparse").regexp(re)
      end
    end)
  end, "sparse tree")
  if auto then
    -- a printable character starts a search in the headlines
    -- (org-goto-local-auto-isearch)
    for c = 33, 126 do
      local ch = string.char(c)
      if ch ~= "/" and ch ~= ":" and ch ~= "<" and ch ~= "|" and ch ~= "\\" then
        map(ch, function()
          M.isearch(ch)
        end, "search headlines")
      end
    end
    map("<lt>", function()
      M.isearch("<")
    end, "search headlines")
    map("<Bar>", function()
      M.isearch("|")
    end, "search headlines")
    map("<Bslash>", function()
      M.isearch("\\")
    end, "search headlines")
  else
    map("q", function()
      finish(nil)
    end, "quit")
    map("n", structure.next_heading, "next visible headline")
    map("p", structure.prev_heading, "previous visible headline")
    map("f", structure.next_sibling, "next headline at the same level")
    map("b", structure.prev_sibling, "previous headline at the same level")
    map("u", structure.goto_parent, "up one level")
  end
  -- closed some other way (:q): nothing left to do
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      done = true
    end,
  })
end

--- Search the headlines for text starting with `ch`: a `/` search that
--- only matches headline text (before the tags).
function M.isearch(ch)
  local prefix = [[^\*\+ \%(\%(\s\+:[[:alnum:]_@#%:]\+:\s*$\)\@!.\)\{-}\zs\V]]
  -- before keys already typed
  vim.api.nvim_feedkeys("/" .. prefix .. ch, "ni", false)
end

--- buffer_goto (org-goto): the interface of `goto_interface`, the other
--- one with a count.
function M.goto()
  local interface = config.opts.goto_interface or "outline"
  if vim.v.count > 0 then
    interface = interface == "outline" and "outline-path-completion" or "outline"
  end
  if interface == "outline" then
    return M.outline()
  end
  return M.completion()
end

return M

---@mod org.ui.images.commands Image commands
---
--- org-link-preview, org-latex-preview and their :Org commands.
--- Part of org.ui.images, which loads it.

local utils = require("org.utils")
local shared = require("org.ui.images.shared")

local M = require("org.ui.images")

local clear_data_cache = shared.clear_data_cache
local opts = shared.opts
local previews_in = shared.previews_in
local remove = shared.remove

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

--- Rows of the entry at the cursor: its headline to the line before the
--- next headline (the part before the first headline counts as one).
local function section_rows(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local first, last = 1, #lines
  for i = lnum, 1, -1 do
    if lines[i]:match("^%*+%s") then
      first = i
      break
    end
  end
  for i = lnum + 1, #lines do
    if lines[i]:match("^%*+%s") then
      last = i - 1
      break
    end
  end
  return first, last
end

--- The Visual selection as rows, leaving Visual mode.
local function visual_rows()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    vim.cmd("normal! \27")
    return math.min(a, b), math.max(a, b)
  end
end

local function count_arg()
  local c = vim.v.count
  return c ~= 0 and c or nil
end

local function notify(msg)
  utils.notify(msg)
end

--- Link previews of rows `first..last` (or `range`) on (`remove` false) or
--- off, with the messages of org-link-preview.
local function toggle_links(bufnr, first, last, scope, remove_them, include, range)
  if remove_them then
    local n = M.clear(bufnr, first, last, "link", range)
    notify(string.format("[%s] Inline link previews turned off (removed %d images)", scope, n))
    return
  end
  local n = M.show_links(bufnr, first, last, include, range)
  if not M.backend() then
    return
  end
  if n > 0 then
    notify(
      string.format(
        "[%s] Displaying %d images inline%s",
        scope,
        n,
        include and " (including images with description)" or ""
      )
    )
  elseif scope == "buffer" then
    notify("[buffer] No images to display inline")
  else
    notify(
      string.format("[%s] No images to display inline.  Use a count of 16 or 11 to preview the whole buffer", scope)
    )
  end
end

--- The link under the cursor: its row and 0-based column range.
local function link_at(bufnr, lnum, col)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  for _, lk in ipairs(require("org.links").real_links(line)) do
    if col >= lk.start_col - 1 and col < lk.end_col then
      return { row = lnum - 1, col = lk.start_col - 1, end_row = lnum - 1, end_col = lk.end_col }
    end
  end
end

--- org-link-preview (C-c C-x C-v): the link at the cursor, else the
--- current entry, or the rows `rows` ({ first, last }: a Visual selection
--- or an ex range). `arg` is the Emacs prefix as a count: 4 hides (the
--- preview at the cursor, else the entry or rows), 16 or 11 previews the
--- whole buffer, 64 hides it all, 1 and 11 (and other counts) also preview
--- links with a description; a plain call on an entry or rows always
--- displays, on a link toggles it.
function M.link_preview(arg, rows)
  arg = arg or count_arg()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum, col = utils.cursor()
  local include = arg ~= nil and arg ~= 4 and arg ~= 16 and arg ~= 64
  local first, last
  if rows then
    first, last = rows[1], rows[2]
  else
    first, last = visual_rows()
  end
  if first then
    return toggle_links(bufnr, first, last, "region", arg == 4, include)
  elseif arg == 4 then
    local here =
      previews_in(bufnr, 1, math.huge, "link", { row = lnum - 1, col = col, end_row = lnum - 1, end_col = col })
    if #here > 0 then
      for _, id in ipairs(here) do
        remove(bufnr, id)
      end
      return notify(string.format("[preview at point] Inline link previews turned off (removed %d images)", #here))
    end
    local s, e = section_rows(bufnr, lnum)
    return toggle_links(bufnr, s, e, "current section", true)
  elseif arg == 11 or arg == 16 then
    return toggle_links(bufnr, 1, math.huge, "buffer", false, arg == 11)
  elseif arg == 64 then
    return toggle_links(bufnr, 1, math.huge, "buffer", true)
  elseif arg == nil or arg == 1 then
    local lk = link_at(bufnr, lnum, col)
    if lk then
      local on = #previews_in(bufnr, 1, math.huge, "link", lk) > 0
      return toggle_links(bufnr, lnum, lnum, "image at point", on, include, lk)
    end
    local s, e = section_rows(bufnr, lnum)
    return toggle_links(bufnr, s, e, "current section", false, include)
  end
  -- any other count: the whole buffer, with described links
  return toggle_links(bufnr, 1, math.huge, "region", false, true)
end

--- org-link-preview-refresh (C-c C-x C-M-v): preview every image link of
--- the buffer again (after the files changed).
function M.link_preview_refresh()
  local bufnr = vim.api.nvim_get_current_buf()
  clear_data_cache()
  M.show_links(bufnr, 1, math.huge, nil, nil, true)
  M.sync(true)
end

--- org-link-preview-region: preview the image links of `rows` (default
--- the whole buffer); `include_linked` also previews described links,
--- `refresh` replaces existing previews (they are replaced anyway).
function M.link_preview_region(include_linked, rows)
  local bufnr = vim.api.nvim_get_current_buf()
  local first, last = rows and rows[1] or 1, rows and rows[2] or math.huge
  M.show_links(bufnr, first, last, include_linked)
end

--- org-link-preview-clear: remove the link previews of `rows` (default
--- the whole buffer).
function M.link_preview_clear(rows)
  local bufnr = vim.api.nvim_get_current_buf()
  M.clear(bufnr, rows and rows[1] or 1, rows and rows[2] or math.huge, "link")
end

--- org-clear-latex-preview: remove the LaTeX previews of `rows` (default
--- the whole buffer). Returns whether there were any.
function M.clear_latex_preview(rows)
  local bufnr = vim.api.nvim_get_current_buf()
  return M.clear(bufnr, rows and rows[1] or 1, rows and rows[2] or math.huge, "latex") > 0
end

local function latex_done(what)
  return function(n, err)
    if err then
      utils.warn("LaTeX preview: " .. err)
    end
    notify(string.format("Creating LaTeX preview%s... done.", what))
    return n
  end
end

--- The LaTeX fragment or environment under the cursor.
local function fragment_at(bufnr, lnum, col)
  for _, f in ipairs(M.find_latex_fragments(bufnr, 1, math.huge)) do
    local inside = (lnum > f.row or (lnum == f.row and col >= f.col))
      and (lnum < f.end_row or (lnum == f.end_row and col < f.end_col))
    if inside then
      return f
    end
  end
end

--- org-latex-preview (C-c C-x C-l): with the cursor on a fragment, toggle
--- its preview; else preview the current entry, or the rows `rows` (a
--- Visual selection or an ex range). 4 hides the entry's (or rows')
--- previews, 16 previews the whole buffer, 64 hides it all.
function M.latex_preview(arg, rows)
  arg = arg or count_arg()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum, col = utils.cursor()
  local first, last
  if rows then
    first, last = rows[1], rows[2]
  else
    first, last = visual_rows()
  end
  if arg == 64 then
    M.clear(bufnr, 1, math.huge, "latex")
    return notify("LaTeX previews removed from buffer")
  elseif arg == 16 then
    notify("Creating LaTeX previews in buffer...")
    return M.show_latex(bufnr, 1, math.huge, latex_done("s in buffer"))
  elseif arg == 4 then
    if not first then
      first, last = section_rows(bufnr, lnum)
    end
    M.clear(bufnr, first, last, "latex")
    return
  elseif first then
    notify("Creating LaTeX previews in region...")
    return M.show_latex(bufnr, first, last, latex_done("s in region"))
  end
  local f = fragment_at(bufnr, lnum, col)
  if f then
    local range = { row = f.row - 1, col = f.col, end_row = f.end_row - 1, end_col = f.end_col }
    if M.clear(bufnr, 1, math.huge, "latex", range) > 0 then
      return notify("LaTeX preview removed")
    end
    notify("Creating LaTeX preview...")
    return M.show_latex(bufnr, f.row, f.end_row, latex_done(""), range)
  end
  local s, e = section_rows(bufnr, lnum)
  notify("Creating LaTeX previews in section...")
  M.show_latex(bufnr, s, e, latex_done("s in section"))
end

--- org-cycle-display-link-previews (on org-cycle-hook): with
--- `ui.images.cycle_display`, TAB to CHILDREN previews the entry's links,
--- to SUBTREE those of the subtree, and FOLDED removes them.
---@param state "children"|"subtree"|"folded"
---@param line integer the headline
---@param end_line integer the subtree's last line
---@param first_child? integer the first child headline
function M.cycle_display(state, line, end_line, first_child)
  if not opts().cycle_display then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if state == "children" then
    M.show_links(bufnr, line, first_child and first_child - 1 or end_line)
  elseif state == "subtree" then
    M.show_links(bufnr, line, end_line)
  elseif state == "folded" then
    M.clear(bufnr, line, end_line, "link")
  end
end

--- `:[range]Org` handler for the preview commands: `args` is the text after
--- the name, `cmd` the user command's opts.
function M.command(name, args, cmd)
  local rows = cmd and cmd.range and cmd.range > 0 and { cmd.line1, cmd.line2 } or nil
  local n = tonumber((args or ""):match("^%s*(%d+)"))
  local linked = (args or ""):match("linked") ~= nil
  if name == "link_preview" or name == "toggle_inline_images" then
    return M.link_preview(n or (linked and 1) or nil, rows)
  elseif name == "link_preview_region" then
    return M.link_preview_region(linked or (n ~= nil), rows)
  elseif name == "link_preview_clear" or name == "remove_inline_images" then
    return M.link_preview_clear(rows)
  elseif name == "link_preview_refresh" or name == "redisplay_inline_images" then
    return M.link_preview_refresh()
  elseif name == "latex_preview" or name == "toggle_latex_fragment" or name == "preview_latex_fragment" then
    return M.latex_preview(n, rows)
  elseif name == "clear_latex_preview" then
    return M.clear_latex_preview(rows)
  end
end

-- `:Org <name>` entries (org.commands), each called with the arguments and
-- the user command's opts.
for _, name in ipairs({
  "link_preview",
  "link_preview_region",
  "link_preview_clear",
  "link_preview_refresh",
  "latex_preview",
  "clear_latex_preview",
  "toggle_inline_images",
  "remove_inline_images",
  "redisplay_inline_images",
  "toggle_latex_fragment",
  "preview_latex_fragment",
}) do
  M["ex_" .. name] = function(args, cmd)
    return M.command(name, args, cmd)
  end
end

return M

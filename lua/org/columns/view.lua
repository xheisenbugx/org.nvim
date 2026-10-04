---@mod org.columns.view Column view rendering
---
--- The table and the overlay (Emacs org-columns) views: drawing them,
--- the cell under the cursor, refreshing.
--- Part of org.columns, which loads it.

local config = require("org.config")
local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.columns.shared")

local M = require("org.columns")

local ns = shared.ns
local scope_for = shared.scope_for

---------------------------------------------------------------------------
-- Interactive view
---------------------------------------------------------------------------

--- Source line of the view's anchor (follows edits in the source buffer).
local function anchor_line(state)
  local pos = vim.api.nvim_buf_get_extmark_by_id(state.src, ns, state.mark, {})
  return (pos[1] or 0) + 1
end

--- Text of cell `i` of row `r` in the view: the displayed value; ITEM
--- with its stars (the leading ones blank with `hide`, like Emacs with
--- org-hide-leading-stars) and links shown as their descriptions.
local function view_text(r, i, col, hide)
  local v = r.display[i] or ""
  if col.prop:upper() == "ITEM" and v == r.cells[i] then
    v = v:gsub("%[%[([^%]]-)%]%[(.-)%]%]", "%2"):gsub("%[%[([^%]]-)%]%]", "%1")
    v = string.rep(hide and " " or "*", r.hl.level - 1) .. "* " .. v
  end
  return v
end

local function render_table(state)
  local file = files.get_buffer(state.src)
  local fmt, roots, holder = scope_for(file, not state.global and anchor_line(state) or nil)
  state.holder = holder
  state.cols = M.parse_format(fmt)
  -- like Emacs, summaries are written back to existing properties
  local rows = M.compute(roots, state.cols, { update = true })
  state.rows = rows
  local widths = {}
  for i, c in ipairs(state.cols) do
    local w = utils.width(c.title)
    for _, r in ipairs(rows) do
      w = math.max(w, utils.width(view_text(r, i, c)))
    end
    widths[i] = c.width and math.max(c.width, 1) or math.min(w, 60)
  end
  state.widths = widths
  local function line_for(cells)
    local parts = {}
    for i, v in ipairs(cells) do
      parts[i] = utils.pad_right(M.add_ellipses(v, widths[i]), widths[i])
    end
    return table.concat(parts, " │ ")
  end
  local header = {}
  for i, c in ipairs(state.cols) do
    header[i] = c.title
  end
  local lines = { line_for(header) }
  local sep = {}
  for i = 1, #widths do
    sep[i] = string.rep("─", widths[i])
  end
  lines[2] = table.concat(sep, "─┼─")
  for _, r in ipairs(rows) do
    local cells = {}
    for i, c in ipairs(state.cols) do
      cells[i] = view_text(r, i, c)
    end
    lines[#lines + 1] = line_for(cells)
  end
  local buf = state.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = #lines[1], hl_group = "Title" })
  vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_col = #lines[2], hl_group = "Comment" })
  for i, r in ipairs(rows) do
    local grp = "OrgHeadlineLevel" .. (((r.hl.level - 1) % 8) + 1)
    local end_col = math.min(#lines[i + 2], widths[1] + 3)
    vim.api.nvim_buf_set_extmark(buf, ns, i + 1, 0, { end_col = end_col, hl_group = grp })
  end
end

--- Row and column index under the cursor (in the view window).
local function table_current(state)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local r = state.rows[row - 2]
  if not r then
    return nil
  end
  -- column index from byte offset
  local line = vim.api.nvim_get_current_line()
  local prefix = line:sub(1, col)
  local _, seps = prefix:gsub("│", "")
  return r, math.min(seps + 1, #state.cols)
end

--- Put the cursor on view line `lnum`, column `ci`.
local function table_goto(state, lnum, ci)
  lnum = math.max(1, math.min(lnum, vim.api.nvim_buf_line_count(state.buf)))
  local line = vim.api.nvim_buf_get_lines(state.buf, lnum - 1, lnum, false)[1] or ""
  local col, n = 0, 1
  while n < ci do
    local _, e = line:find("│", col + 1, true)
    if not e then
      break
    end
    col, n = e + 1, n + 1
  end
  vim.api.nvim_win_set_cursor(0, { lnum, col })
end

-- Overlay view (the default, Emacs org-columns): the column row is drawn
-- over every headline of the org buffer itself, as an overlay extmark
-- blanking the rest of the line; the column titles are in the window's
-- winbar (Emacs header-line). Like Emacs' truncate-lines the window gets
-- 'nowrap', and 'virtualedit' so the cursor reaches every column of a
-- short headline.

local ns_ov = vim.api.nvim_create_namespace("org.columns.overlay")

--- Active overlay views by org buffer.
local views = {}

--- Is the overlay column view on in `bufnr`?
---@param bufnr integer
---@return boolean
function M.is_active(bufnr)
  return views[bufnr] ~= nil
end

--- The Column menu comes and goes with the view (org-columns-menu).
local function sync_menus()
  if package.loaded["org.menu"] then
    pcall(require("org.menu").sync)
  end
end

--- What changing a headline line of the view says (Emacs signals
--- text-read-only with this).
local READ_ONLY = "Text is read-only: Type ‘e’ to edit property"

--- Default links of the column view groups (Emacs org-column and
--- org-column-title).
local OV_HL = { OrgColumn = "Pmenu", OrgColumnTitle = "TabLineSel" }

--- Lines (1-based, as keys) showing a column row in `bufnr`, or nil. The
--- decorations leave these lines alone (Emacs turns org-num-mode off).
function M.overlay_lines(bufnr)
  local state = views[bufnr]
  return state and state.row_at
end

--- The display width of the column view row drawn over line `lnum` of
--- `bufnr` (what comes after it, like a fold's ellipsis, starts there).
function M.overlay_width(bufnr, lnum)
  local state = views[bufnr]
  return state and state.row_width and state.row_width[lnum] or 0
end

--- Is the overlay column view shown in `bufnr` (default: the current
--- buffer)?
function M.active(bufnr)
  return views[bufnr or vim.api.nvim_get_current_buf()] ~= nil
end

--- Faces of a cell (org-columns--overlay-text): the TODO keyword, priority
--- or tag face, else the level face of the headline, over OrgColumn.
local function cell_hl(r, col, value)
  local key = col.prop:upper()
  local v = vim.trim(value or "")
  local ui = config.opts.ui or {}
  local group = "OrgHeadlineLevel" .. (((r.hl.level - 1) % 8) + 1)
  if key == "TODO" and v ~= "" then
    if (ui.todo_keyword_faces or {})[v] then
      group = "orgTodoKw_" .. v:gsub("[^%w_]", "_")
    else
      group = r.hl.file.settings.todo:is_done(v) and "OrgDone" or "OrgTodo"
    end
  elseif key == "PRIORITY" and v ~= "" then
    if (ui.priority_faces or {})[v] then
      group = require("org.highlights").face_group("orgPriorityFace_", v)
    else
      group = ({ A = "OrgPriorityA", B = "OrgPriorityB", C = "OrgPriorityC" })[v] or "OrgPriority"
    end
  elseif key == "TAGS" and v ~= "" then
    group = "OrgTags"
  end
  return { "OrgColumn", group }
end

--- Emacs overlay text of a cell: "%-W.Ws | ", "%-W.Ws |" for the last one.
local function overlay_cell(v, w, last)
  return utils.pad_right(M.add_ellipses(v, w), w) .. (last and " |" or " | ")
end

--- `s` without its first `n` display cells.
local function drop_cells(s, n)
  local i, w, len = 0, 0, vim.fn.strchars(s)
  while i < len and w < n do
    w = w + utils.width(vim.fn.strcharpart(s, i, 1))
    i = i + 1
  end
  return vim.fn.strcharpart(s, i)
end

--- Show the column titles in the view window's winbar, after the number
--- and sign columns and scrolled along with the text (org-columns-hscroll-title).
local function update_winbar(state)
  local win = state.win
  if not state.saved_opts or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= state.src then
    return
  end
  local info = vim.fn.getwininfo(win)[1] or {}
  local leftcol = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().leftcol
  end)
  local title = drop_cells(state.title or "", leftcol):gsub("%%", "%%%%")
  local bar = "%#Normal#" .. string.rep(" ", info.textoff or 0) .. "%#OrgColumnTitle#" .. title .. "%#Normal#"
  vim.api.nvim_set_option_value("winbar", bar, { scope = "local", win = win })
end

--- Draw the column rows over the headlines of the view's scope. With
--- `update`, summaries are written back to existing properties (on open
--- and redo, like Emacs org-columns-compute-all).
local function overlay_render(state, update)
  local src = state.src
  local file = files.get_buffer(src)
  local fmt, roots, holder = scope_for(file, not state.global and anchor_line(state) or nil)
  state.holder = holder
  state.cols = M.parse_format(fmt)
  local rows = M.compute(roots, state.cols, { update = update })
  state.rows = rows
  local hide = require("org.ui.decorations").ui_options(src).hide_leading_stars
  local texts = {}
  for k, r in ipairs(rows) do
    texts[k] = {}
    for i, c in ipairs(state.cols) do
      texts[k][i] = view_text(r, i, c, hide)
    end
  end
  -- widths: the format's, else the widest value or title (org-columns--set-widths)
  local widths = {}
  for i, c in ipairs(state.cols) do
    local w = utils.width(c.title)
    for k = 1, #rows do
      w = math.max(w, utils.width(texts[k][i]))
    end
    widths[i] = c.width and math.max(c.width, 1) or w
  end
  state.widths = widths
  for group, link in pairs(OV_HL) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  vim.api.nvim_buf_clear_namespace(src, ns_ov, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)
  state.row_at, state.row_width = {}, {}
  for k, r in ipairs(rows) do
    local lnum = r.hl.line
    state.row_at[lnum] = r
    local chunks, total = {}, 0
    for i, c in ipairs(state.cols) do
      local s = overlay_cell(texts[k][i], widths[i], i == #state.cols)
      -- the cell face covers the value only: a keyword face with a
      -- background or an italic priority face must not spill onto the
      -- padding and the "|" separator
      local v = M.add_ellipses(texts[k][i], widths[i]):gsub("%s+$", "")
      if v ~= "" then
        chunks[#chunks + 1] = { v, cell_hl(r, c, r.cells[i]) }
      end
      chunks[#chunks + 1] = { s:sub(#v + 1), "OrgColumn" }
      total = total + utils.width(s)
    end
    -- make the rest of the line disappear
    local lw = vim.fn.strdisplaywidth(lines[lnum] or "")
    state.row_width[lnum] = math.max(lw, total)
    if lw > total then
      chunks[#chunks + 1] = { string.rep(" ", lw - total), "Normal" }
    end
    pcall(vim.api.nvim_buf_set_extmark, src, ns_ov, lnum - 1, 0, {
      virt_text = chunks,
      virt_text_pos = "overlay",
      hl_mode = "replace",
      priority = 1000,
    })
  end
  local titles = {}
  for i, c in ipairs(state.cols) do
    titles[i] = overlay_cell(c.title, widths[i], i == #state.cols)
  end
  state.title = table.concat(titles)
  update_winbar(state)
  require("org.ui.decorations").render(src)
end

--- Row and column index under the cursor in the org buffer.
local function overlay_current(state)
  if vim.api.nvim_get_current_buf() ~= state.src then
    return nil
  end
  local r = state.row_at and state.row_at[vim.api.nvim_win_get_cursor(0)[1]]
  if not r then
    return nil
  end
  local vcol = vim.fn.virtcol(".") - 1
  local x = 0
  for i, w in ipairs(state.widths) do
    x = x + w + 3
    if vcol < x then
      return r, i
    end
  end
  return r, #state.cols
end

--- Put the cursor on buffer line `lnum`, at the start of column `ci`.
local function overlay_goto(state, lnum, ci)
  lnum = math.max(1, math.min(lnum, vim.api.nvim_buf_line_count(state.src)))
  local x = 0
  for i = 1, math.min(ci or 1, #state.widths) - 1 do
    x = x + state.widths[i] + 3
  end
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  if x > 0 then
    vim.cmd("normal! " .. (x + 1) .. "|")
  end
end

local function render(state)
  if state.mode == "overlay" then
    overlay_render(state, true)
  else
    render_table(state)
  end
end

local function current(state)
  if state.mode == "overlay" then
    return overlay_current(state)
  end
  return table_current(state)
end

local function goto_cell(state, lnum, ci)
  if state.mode == "overlay" then
    overlay_goto(state, lnum, ci)
  else
    table_goto(state, lnum, ci)
  end
end

--- Re-render, keeping the cursor on its line, in column `ci`.
local function refresh(state, ci)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local _, cur_ci = current(state)
  render(state)
  goto_cell(state, lnum, ci or cur_ci or 1)
end

shared.READ_ONLY = READ_ONLY
shared.anchor_line = anchor_line
shared.current = current
shared.goto_cell = goto_cell
shared.ns_ov = ns_ov
shared.overlay_current = overlay_current
shared.overlay_goto = overlay_goto
shared.overlay_render = overlay_render
shared.refresh = refresh
shared.render = render
shared.sync_menus = sync_menus
shared.update_winbar = update_winbar
shared.views = views

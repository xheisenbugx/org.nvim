---@mod org.fold.hidden Hidden lines and the ellipsis
---
--- `conceal_lines` marks that hide lines while their fold is open
--- (conceal, unconceal, is_concealed, line_visible), and the ellipsis
--- drawn after a folded heading or one followed by hidden lines.
---
--- Part of org.fold, which loads it.

local parser = require("org.parser")
local shared = require("org.fold.shared")

local M = require("org.fold")

local ellipsis = shared.ellipsis
local ns_ellipsis = shared.ns_ellipsis
local ns_hide = shared.ns_hide

---------------------------------------------------------------------------
-- Hidden lines (conceal_lines)
---------------------------------------------------------------------------

local function curbuf()
  return vim.api.nvim_get_current_buf()
end

-- custom properties hidden by toggle_custom_properties_visibility
local ns_custom = vim.api.nvim_create_namespace("org.custom_properties")

--- The rows (0-based) in [s, e] hidden by a conceal_lines mark. A mark
--- whose line was replaced is invalid and hides nothing.
local function hidden_rows(bufnr, s, e)
  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns_hide, { s, 0 }, { e, -1 }, { details = true })) do
    if not m[4].invalid then
      rows[m[2]] = true
    end
  end
  return rows
end

--- Is line `lnum` hidden by a conceal_lines mark?
function M.is_concealed(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and curbuf() or bufnr
  return hidden_rows(bufnr, lnum - 1, lnum - 1)[lnum - 1] ~= nil
    or #vim.api.nvim_buf_get_extmarks(bufnr, ns_custom, { lnum - 1, 0 }, { lnum - 1, -1 }, { limit = 1 }) > 0
end

--- Hide lines [s, e] (1-based, inclusive).
function M.conceal(bufnr, s, e)
  if not M.conceal_supported then
    return
  end
  bufnr = (bufnr == nil or bufnr == 0) and curbuf() or bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  -- rows hidden already (one query for the range, not one per line)
  local hidden = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns_hide, { s - 1, 0 }, { e - 1, -1 }, { details = true })) do
    if m[4].invalid then
      vim.api.nvim_buf_del_extmark(bufnr, ns_hide, m[1])
    else
      hidden[m[2]] = true
    end
  end
  for i, l in ipairs(lines) do
    local row = s + i - 2
    if not hidden[row] then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_hide, row, 0, {
        end_row = row,
        end_col = #l,
        conceal_lines = "",
        invalidate = true,
        undo_restore = false,
      })
    end
  end
end

--- Show lines [s, e] hidden by `conceal`.
function M.unconceal(bufnr, s, e)
  bufnr = (bufnr == nil or bufnr == 0) and curbuf() or bufnr
  if e < s then
    return
  end
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_hide, { s - 1, 0 }, { e - 1, -1 }, {})
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_del_extmark(bufnr, ns_hide, m[1])
  end
end

--- Show every hidden line of the buffer.
function M.clear_hidden(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and curbuf() or bufnr
  vim.api.nvim_buf_clear_namespace(bufnr, ns_hide, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_ellipsis, 0, -1)
end

--- Is line `lnum` visible in the current window (not inside a closed fold
--- nor hidden)?
function M.line_visible(lnum)
  local fc = vim.fn.foldclosed(lnum)
  if fc ~= -1 and fc ~= lnum then
    return false
  end
  return not M.is_concealed(0, lnum)
end

local function file()
  return require("org.files").get_buffer(0)
end

---------------------------------------------------------------------------
-- Ellipsis
---------------------------------------------------------------------------

-- 'foldtext' is empty, so Neovim draws a closed fold's first line as it
-- draws it open, with its syntax groups and concealed text: a folded heading
-- keeps the faces of its TODO keyword, tags, links... as in Emacs, where
-- folding only hides the text after it. The ellipsis after it, and after
-- a heading whose text is hidden while its fold is open (Emacs shows "..."
-- wherever invisible text follows a heading), is an inline mark at the end
-- of the line (eol marks aren't drawn on a closed fold, and start one cell
-- after the line). The marks live in a namespace scoped to the window,
-- since folds are per window: each redraw compares them with the folds
-- and hidden lines on screen and moves them when they differ, so they
-- can't outlive what they stand for.
local closed_ns = {} -- winid -> namespace

local function win_ns(win)
  local ns = closed_ns[win]
  if not ns then
    ns = vim.api.nvim_create_namespace("org.fold.closed." .. win)
    closed_ns[win] = ns
    if vim.api.nvim__ns_set then
      pcall(vim.api.nvim__ns_set, ns, { wins = { win } })
    end
  end
  return ns
end

local function uses_empty_foldtext(win, buf)
  return vim.bo[buf].filetype == "org"
    and vim.wo[win].foldtext == ""
    and vim.wo[win].foldexpr == "v:lua.require'org.fold'.foldexpr(v:lnum)"
end

--- Whether the line `line` is an outline heading (inline tasks included).
local function is_heading(line)
  return line:byte(1) == 42 and parser.headline_level(line) ~= nil
end

--- The ellipsis marks rows [top, bot] (0-based) of `win` need: for the
--- closed folds and the headings followed by hidden lines, as
--- "row:col:wincol" keys (wincol -1 for an inline mark at col).
local function ellipsis_rows(win, buf, top, bot)
  local rows = {}
  local hidden = hidden_rows(buf, top, bot + 1)
  local columns = package.loaded["org.columns"]
  local overlay = columns and columns.overlay_lines and columns.overlay_lines(buf) or nil
  local leftcol = 0
  vim.api.nvim_win_call(win, function()
    if not vim.wo[win].wrap then
      leftcol = vim.fn.winsaveview().leftcol
    end
    local function add(l, line)
      local r = overlay and overlay[l]
      if r then
        -- a column view row: after the row, like Emacs
        rows[(l - 1) .. ":0:" .. (columns.overlay_width and columns.overlay_width(buf, l) or 0)] = true
      elseif leftcol == 0 or vim.fn.strdisplaywidth(line) > leftcol then
        -- (a line scrolled out of view shows no ellipsis: Neovim would
        -- draw it in the first column of a closed fold)
        rows[(l - 1) .. ":" .. #line .. ":-1"] = true
      end
    end
    local l = top + 1
    while l <= bot + 1 do
      local fc = vim.fn.foldclosed(l)
      if fc == -1 then
        if hidden[l] and not hidden[l - 1] then
          local line = vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ""
          if is_heading(line) then
            add(l, line)
          end
        end
        l = l + 1
      else
        if fc == l and not hidden[l - 1] then
          add(l, vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or "")
        end
        l = vim.fn.foldclosedend(l) + 1
      end
    end
  end)
  return rows
end

local function marked_rows(buf, ns, top, bot)
  local rows = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { top, 0 }, { bot, -1 }, { details = true })) do
    rows[m[2] .. ":" .. m[3] .. ":" .. (m[4].virt_text_win_col or -1)] = m[1]
  end
  return rows
end

local function same_keys(a, b)
  for k in pairs(a) do
    if b[k] == nil then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

local function sync_closed(win, buf, top, bot)
  if not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  if vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end
  local ns = win_ns(win)
  if not uses_empty_foldtext(win, buf) then
    -- a window that stopped folding like Org ('foldtext' or 'filetype'
    -- changed) keeps no ellipsis
    if #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { limit = 1 }) > 0 then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      vim.cmd("redraw")
    end
    return
  end
  local want, have = ellipsis_rows(win, buf, top, bot), marked_rows(buf, ns, top, bot)
  if same_keys(want, have) then
    return
  end
  for key, id in pairs(have) do
    if not want[key] then
      vim.api.nvim_buf_del_extmark(buf, ns, id)
    end
  end
  for key in pairs(want) do
    if not have[key] then
      local row, col, wincol = key:match("^(%d+):(%d+):(%-?%d+)$")
      local opts = { virt_text = { { ellipsis(), "Comment" } }, undo_restore = false }
      if wincol == "-1" then
        opts.virt_text_pos = "inline"
      else
        opts.virt_text_win_col = tonumber(wincol)
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, tonumber(row), tonumber(col), opts)
    end
  end
  vim.cmd("redraw")
end
M._sync_closed = sync_closed

--- Put the ellipsis after headlines whose text is hidden while the fold
--- is open, in a window that doesn't draw it itself (see above: a
--- 'foldtext' of its own).
local function refresh_ellipsis()
  local bufnr = curbuf()
  vim.api.nvim_buf_clear_namespace(bufnr, ns_ellipsis, 0, -1)
  if not M.conceal_supported or uses_empty_foldtext(vim.api.nvim_get_current_win(), bufnr) then
    return
  end
  for _, hl in ipairs(file().headlines) do
    if hl.end_line > hl.line and vim.fn.foldclosed(hl.line) == -1 and M.is_concealed(bufnr, hl.line + 1) then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_ellipsis, hl.line - 1, 0, {
        virt_text = { { ellipsis(), "Comment" } },
        virt_text_pos = "eol",
      })
    end
  end
end
M.refresh_ellipsis = refresh_ellipsis

local pending = {}
vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace("org.fold.closed"), {
  on_win = function(_, win, buf, top, bot)
    if pending[win] then
      return false
    end
    local stale
    if uses_empty_foldtext(win, buf) then
      stale = not same_keys(ellipsis_rows(win, buf, top, bot), marked_rows(buf, win_ns(win), top, bot))
    else
      local ns = closed_ns[win]
      stale = ns ~= nil and #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { limit = 1 }) > 0
    end
    if stale then
      -- marks can't change while the window is being drawn
      pending[win] = true
      vim.schedule(function()
        pending[win] = nil
        sync_closed(win, buf, top, bot)
      end)
    end
    return false
  end,
})

vim.api.nvim_create_autocmd("WinClosed", {
  group = vim.api.nvim_create_augroup("org.fold.closed", { clear = true }),
  callback = function(args)
    local win = tonumber(args.match)
    local ns = win and closed_ns[win]
    if ns then
      closed_ns[win] = nil
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
          vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
        end
      end
    end
  end,
})

shared.closed_ns = closed_ns
shared.curbuf = curbuf
shared.file = file
shared.refresh_ellipsis = refresh_ellipsis

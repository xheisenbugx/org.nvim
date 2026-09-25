---@mod org.table.shrink Shrunk table columns (Emacs org-table-shrink)
---
--- A shrunk column shows only the first W characters of each field (W
--- from the column's width cookie `<W>`, `<lW>`, ...; one character when
--- there is none) followed by `table_shrunk_column_indicator`. Emacs uses
--- overlays; here each field is concealed (`conceal` extmark, which needs
--- 'conceallevel' 2, set when shrinking) and replaced by inline virtual
--- text. The text itself is never changed. While you are in Insert mode
--- in a table, its columns are shown in full, and they shrink again when
--- you leave it. Table edits (align, moving or inserting columns ...)
--- keep the set of shrunk columns.

local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.table.shrink")
local anchor_ns = vim.api.nvim_create_namespace("org.table.shrink.anchor")

--- Per buffer: list of { mark = anchor extmark id, cols = { [c] = true } }.
local state = {}

local function tbl()
  return require("org.table")
end

local function tables_of(bufnr)
  state[bufnr] = state[bufnr] or {}
  return state[bufnr]
end

--- Current start line of an anchored table, or nil when it is gone.
local function anchor_line(bufnr, entry)
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, anchor_ns, entry.mark, {})
  if not pos[1] then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, pos[1], pos[1] + 1, false)[1]
  if not tbl().is_table_line(line) then
    return nil
  end
  return pos[1] + 1
end

--- The shrink entry of the table containing `lnum`, creating it when
--- `create` is set.
local function entry_for(bufnr, lnum, create)
  local info = tbl().find(bufnr, lnum)
  if not info then
    return nil
  end
  local list = tables_of(bufnr)
  for i = #list, 1, -1 do
    local l = anchor_line(bufnr, list[i])
    if not l then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, anchor_ns, list[i].mark)
      table.remove(list, i)
    elseif l >= info.start and l <= info.finish then
      if l ~= info.start then
        -- the table grew above its anchor
        pcall(vim.api.nvim_buf_del_extmark, bufnr, anchor_ns, list[i].mark)
        list[i].mark = vim.api.nvim_buf_set_extmark(bufnr, anchor_ns, info.start - 1, 0, { right_gravity = false })
      end
      return list[i], info
    end
  end
  if not create then
    return nil, info
  end
  local mark = vim.api.nvim_buf_set_extmark(bufnr, anchor_ns, info.start - 1, 0, { right_gravity = false })
  local e = { mark = mark, cols = {} }
  list[#list + 1] = e
  return e, info
end

--- Width cookies of a parsed table: column -> width.
function M.cookie_widths(t)
  local out = {}
  for _, row in ipairs(t.rows) do
    if not row.hline then
      for c, cell in ipairs(row.cells) do
        local w = cell:match("^<[lrc]?(%d+)>$")
        if w and not out[c] then
          out[c] = tonumber(w)
        end
      end
    end
  end
  return out
end

--- Prefix of `s` that is `width` display cells wide (or less).
local function take(s, width)
  local out, w = {}, 0
  for _, ch in ipairs(vim.fn.split(s, "\\zs")) do
    local cw = vim.fn.strdisplaywidth(ch)
    if w + cw > width then
      break
    end
    out[#out + 1] = ch
    w = w + cw
  end
  return table.concat(out), w
end

--- Display text of a shrunk field (org-table--shrink-field).
local function field_text(content, width, align, hline, indicator)
  if width == 0 then
    return indicator
  elseif hline then
    return string.rep("-", width + 1) .. indicator
  elseif content == "" then
    return string.rep(" ", width + 1) .. indicator
  end
  local cw = utils.width(content)
  if cw >= width then
    local s, w = take(content, width)
    return " " .. s .. string.rep(" ", width - w) .. indicator
  end
  local required = width - cw
  local before = align == "r" and required or (align == "c" and math.floor(required / 2) or 0)
  return " " .. string.rep(" ", before) .. content .. string.rep(" ", required - before) .. indicator
end

--- Draw the shrunk columns of the table at `start` (clearing old marks).
local function draw(bufnr, entry, start)
  local info = tbl().find(bufnr, start)
  if not info then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, info.start - 1, info.finish)
  if next(entry.cols) == nil then
    return
  end
  local t = tbl().parse(info.lines)
  local _, align = tbl().layout(t)
  local cookies = M.cookie_widths(t)
  local indicator = require("org.config").opts.table_shrunk_column_indicator or "…"
  for i, line in ipairs(info.lines) do
    local hline = t.rows[i] and t.rows[i].hline
    -- field separators (hlines separate fields with `+`)
    local pipes = {}
    for p in line:gmatch(hline and "()[+|]" or "()|") do
      pipes[#pipes + 1] = p
    end
    for c in pairs(entry.cols) do
      local a, b = pipes[c], pipes[c + 1]
      if a and b and b > a + 1 then
        local content = hline and "" or vim.trim(line:sub(a + 1, b - 1))
        local text = field_text(content, cookies[c] or 0, align[c], hline, indicator)
        vim.api.nvim_buf_set_extmark(bufnr, ns, info.start + i - 2, a, {
          end_col = b - 1,
          conceal = "",
          virt_text = { { text, hline and "OrgTableSeparator" or "OrgTable" } },
          virt_text_pos = "inline",
        })
      end
    end
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.wo[win].conceallevel < 2 then
      vim.wo[win].conceallevel = 2
    end
  end
end

local attached = {}

--- Autocommands: full columns while inserting in a table, redraw after
--- changes.
local function attach(bufnr)
  if attached[bufnr] then
    return
  end
  attached[bufnr] = true
  local group = vim.api.nvim_create_augroup("org.table.shrink." .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = bufnr,
    group = group,
    callback = function()
      local e, info = entry_for(bufnr, vim.api.nvim_win_get_cursor(0)[1], false)
      if e and info then
        vim.api.nvim_buf_clear_namespace(bufnr, ns, info.start - 1, info.finish)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, {
    buffer = bufnr,
    group = group,
    callback = function()
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) and vim.fn.mode() ~= "i" then
          M.refresh_all(bufnr)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    group = group,
    callback = function()
      state[bufnr], attached[bufnr] = nil, nil
    end,
  })
end

--- Redraw every shrunk table of the buffer.
function M.refresh_all(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local list = tables_of(bufnr)
  for i = #list, 1, -1 do
    local l = anchor_line(bufnr, list[i])
    if l then
      draw(bufnr, list[i], l)
    else
      table.remove(list, i)
    end
  end
end

--- Redraw the table at `lnum` when it has shrunk columns.
function M.refresh(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not state[bufnr] or #state[bufnr] == 0 then
    return
  end
  local e, info = entry_for(bufnr, lnum, false)
  if e then
    draw(bufnr, e, info.start)
  end
end

--- Set the shrunk columns of the table at `lnum`.
---@param cols table<integer, boolean>
function M.set(bufnr, lnum, cols)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local e, info = entry_for(bufnr, lnum, true)
  if not e then
    return false
  end
  e.cols = cols
  attach(bufnr)
  draw(bufnr, e, info.start)
  return true
end

--- Shrunk columns of the table at `lnum` (a set).
function M.get(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local e = entry_for(bufnr, lnum, false)
  return e and vim.deepcopy(e.cols) or {}
end

--- Shrink the columns with a width cookie and expand the others
--- (org-table-shrink).
function M.shrink(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local info = tbl().find(bufnr, lnum)
  if not info then
    return false
  end
  local cols = {}
  for c in pairs(M.cookie_widths(tbl().parse(info.lines))) do
    cols[c] = true
  end
  return M.set(bufnr, info.start, cols)
end

--- Expand every column of the table (org-table-expand).
function M.expand(bufnr, lnum)
  return M.set(bufnr, lnum, {})
end

--- Renumber the shrunk columns of the table at `lnum` with `map(c)` (nil
--- drops the column), after a column was inserted, deleted or moved.
function M.shift(bufnr, lnum, map)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local e, info = entry_for(bufnr, lnum, false)
  if not e then
    return
  end
  local cols = {}
  for c in pairs(e.cols) do
    local n = map(c)
    if n then
      cols[n] = true
    end
  end
  e.cols = cols
  draw(bufnr, e, info.start)
end

--- Parse column ranges like "2-4 6- -1 -" (org-table--read-column-selection).
function M.parse_ranges(s, max)
  local out = {}
  for part in s:gmatch("%S+") do
    local a, b = part:match("^(%d*)%-(%d*)$")
    if a then
      a = a == "" and 1 or tonumber(a)
      b = b == "" and max or tonumber(b)
      for c = a, math.min(b, max) do
        out[c] = true
      end
    elseif tonumber(part) then
      out[tonumber(part)] = true
    else
      error("Invalid column range: " .. part)
    end
  end
  return out
end

--- Shrink every table with a width cookie in the buffer (#+STARTUP:
--- shrink, startup_shrink_all_tables).
function M.shrink_all(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local l = 1
  while l <= #lines do
    if tbl().is_table_line(lines[l]) then
      local info = tbl().find(bufnr, l)
      if info and next(M.cookie_widths(tbl().parse(info.lines))) then
        M.shrink(bufnr, l)
      end
      l = (info and info.finish or l) + 1
    else
      l = l + 1
    end
  end
end

M.ns = ns

return M

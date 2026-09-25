---@mod org.agenda.columns Column view in the agenda (org-agenda-columns)
---
--- Overlays every agenda entry line with its column values, like Emacs
--- `org-agenda-columns` (C-c C-x C-c in the agenda). Date lines and block
--- headers show the summaries of the entries below them
--- (org-agenda-columns-show-summaries). The agenda keeps working: the
--- overlay is virtual text, so the entry under the cursor is still the
--- agenda entry. While active, `q` removes the column view, `e` edits the
--- value under the cursor, `n`/`p` (`<S-Right>`/`<S-Left>`) switch to the
--- next/previous allowed value and `v` shows the full value.

local columns = require("org.columns")
local config = require("org.config")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.agenda.columns")

--- Active column view: { buf, cols, widths, cells = { [lnum] = { values } }, maps }
local A = nil

--- Default links of the column view groups (Emacs org-column,
--- org-agenda-column-dateline, org-column-title).
local HL = { OrgAgendaColumn = "Pmenu", OrgAgendaColumnDateline = "PmenuSel", OrgAgendaColumnTitle = "TabLineSel" }

local KEYS = { "q", "e", "v", "n", "p", "<S-Right>", "<S-Left>" }

local function view_mod()
  return require("org.agenda.view")
end

--- Is the column view shown in agenda buffer `buf` (default: the agenda)?
function M.active(buf)
  buf = buf or view_mod().state.buf
  return A ~= nil and A.buf == buf and buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

--- The columns format (org-agenda-columns): `overriding_columns_format`,
--- else the COLUMNS property / #+COLUMNS of the entry at point, else of
--- the first entry of the agenda, else `columns_default_format`.
function M.format(S)
  local fmt = config.opts.agenda.overriding_columns_format
  if fmt and fmt ~= "" then
    return fmt
  end
  local function from_item(it)
    local hl = it and it.headline
    if not hl then
      return nil
    end
    local p = hl
    while p do
      if p.properties.COLUMNS then
        return p.properties.COLUMNS
      end
      p = p.parent
    end
    return hl.file.settings.columns or config.opts.columns_default_format
  end
  local at = S.win and vim.api.nvim_win_is_valid(S.win) and S.line_items[vim.api.nvim_win_get_cursor(S.win)[1]]
  local f = from_item(at)
  if f then
    return f
  end
  local lines = vim.tbl_keys(S.line_items)
  table.sort(lines)
  return from_item(S.line_items[lines[1]]) or config.opts.columns_default_format or "%25ITEM %TODO %3PRIORITY %TAGS"
end

--- Value of a column for an agenda item (ITEM without stars).
local function value(it, prop)
  local key = prop:upper()
  if key == "ITEM" then
    return it.display_title or it.title or ""
  end
  return columns.value(it.headline, prop) or ""
end

--- Emacs overlay text: "%-W.Ws | " per column, "%-W.Ws |" for the last.
local function row_text(cells, widths)
  local parts = {}
  for i, v in ipairs(cells) do
    local w = widths[i]
    local s = utils.truncate(v or "", w)
    s = utils.pad_right(s, w)
    parts[#parts + 1] = s .. (i == #cells and " |" or " | ")
  end
  return table.concat(parts)
end

local function clear(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

--- Draw the column overlays in the agenda buffer.
function M.apply()
  local S = view_mod().state
  local buf = S.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local fmt = M.format(S)
  local cols = columns.parse_format(fmt)
  if #cols == 0 then
    utils.error("Invalid columns format: " .. tostring(fmt))
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local cells = {}
  for l, it in pairs(S.line_items) do
    if it.headline then
      local row = {}
      for i, c in ipairs(cols) do
        row[i] = value(it, c.prop)
      end
      cells[l] = row
    end
  end
  -- summaries on date lines and block headers, from the bottom up
  local summaries = {}
  local show = config.opts.agenda.columns_show_summaries ~= false
  local has_summary = false
  for _, c in ipairs(cols) do
    if c.summary or c.prop:upper() == "CLOCKSUM" or c.prop:upper() == "CLOCKSUM_T" then
      has_summary = true
    end
  end
  if show and has_summary then
    -- summary lines: date lines and block headers (Emacs org-date-line or
    -- the org-agenda-structure face)
    local structural = {}
    for l in pairs(S.day_lines or {}) do
      structural[l] = true
    end
    local ans = vim.api.nvim_create_namespace("org.agenda")
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ans, 0, -1, { details = true })) do
      local g = m[4].hl_group
      if g == "OrgAgendaHeader" and m[3] == 0 then
        structural[m[2] + 1] = true
      end
    end
    local pending = {}
    for l = #lines, 1, -1 do
      if cells[l] then
        pending[#pending + 1] = cells[l]
      elseif structural[l] then
        if #pending > 0 then
          local row = {}
          for i, c in ipairs(cols) do
            local key = c.prop:upper()
            if key == "ITEM" then
              row[i] = lines[l]
            else
              local op = c.summary
              if key == "CLOCKSUM" or key == "CLOCKSUM_T" then
                op = ":"
              end
              if op then
                local vals = {}
                for _, r in ipairs(pending) do
                  vals[#vals + 1] = r[i]
                end
                row[i] = columns.summarize(op, vals, c.summary_fmt)
              else
                row[i] = ""
              end
            end
          end
          summaries[l] = row
          pending = {}
        end
      end
    end
  end
  local widths = {}
  for i, c in ipairs(cols) do
    if c.width then
      widths[i] = math.max(c.width, 1)
    else
      local w = utils.width(c.title)
      for _, row in pairs(cells) do
        w = math.max(w, utils.width(row[i] or ""))
      end
      widths[i] = w
    end
  end
  clear(buf)
  for group, link in pairs(HL) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  local function overlay(l, row, group)
    local text = row_text(row, widths)
    local lw = utils.width(lines[l] or "")
    if lw > utils.width(text) then
      text = text .. string.rep(" ", lw - utils.width(text))
    end
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, l - 1, 0, {
      virt_text = { { text, group } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
      priority = 300,
    })
  end
  for l, row in pairs(cells) do
    overlay(l, row, "OrgAgendaColumn")
  end
  for l, row in pairs(summaries) do
    overlay(l, row, "OrgAgendaColumnDateline")
  end
  local titles = {}
  for i, c in ipairs(cols) do
    titles[i] = c.title
  end
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, 0, 0, {
    virt_lines = { { { row_text(titles, widths), "OrgAgendaColumnTitle" } } },
    virt_lines_above = true,
  })
  local was = A
  A = { buf = buf, cols = cols, widths = widths, cells = cells, fmt = fmt, maps = was and was.buf == buf and was.maps }
  if not A.maps then
    M.map_keys(buf)
  end
  return true
end

--- Column index under the cursor (by display column).
local function current_column(win)
  local vcol = vim.fn.virtcol(".") - 1
  local x = 0
  for i, w in ipairs(A.widths) do
    x = x + w + 3
    if vcol < x then
      return i
    end
  end
  return #A.widths
end

--- The item and column under the cursor.
local function current(win)
  local S = view_mod().state
  local lnum = vim.api.nvim_win_get_cursor(win or 0)[1]
  local it = S.line_items[lnum]
  if not it or not A.cells[lnum] then
    return nil
  end
  local ci = current_column(win)
  return it, ci, lnum
end

--- Set a column value on the item's source entry.
local function set_value(it, prop, v)
  local view = view_mod()
  local target = view.resolve_target(it)
  if not target then
    return false
  end
  local key = prop:upper()
  if key == "TODO" then
    require("org.todo").change_state(target, v ~= "" and v or nil)
  elseif key == "PRIORITY" then
    require("org.priority").set(target, v)
  elseif key == "TAGS" then
    local tags = vim.split(v, ":", { trimempty = true })
    require("org.edit").update_headline(target.bufnr, target.lnum, { tags = tags })
  elseif key == "ITEM" then
    require("org.edit").update_headline(target.bufnr, target.lnum, { title = v })
  elseif columns.SPECIAL[key] then
    utils.warn("This special column cannot be edited")
    return false
  else
    require("org.edit").set_property(target.bufnr, target.lnum, prop, v)
  end
  if config.opts.agenda.save_after_edit then
    utils.save_buffer(target.bufnr)
  end
  return true
end

local function redo()
  view_mod().redo()
  if A then
    M.apply()
  end
end

--- Allowed values of a column for an item.
local function allowed(it, prop)
  local key = prop:upper()
  local hl = it.headline
  if key == "TODO" then
    return vim.list_extend(vim.deepcopy(hl.file.settings.todo:names()), { "" })
  elseif key == "PRIORITY" then
    local p = hl.file:priorities()
    local out = {}
    for b = p.highest:byte(), p.lowest:byte() do
      out[#out + 1] = string.char(b)
    end
    return out
  end
  local vals = hl:get_allowed_values(prop)
  if vals then
    return vim.tbl_filter(function(v)
      return v ~= ":ETC"
    end, vals)
  end
end

--- Edit the value under the cursor (e, org-columns-edit-value).
function M.edit()
  local it, ci = current()
  if not it then
    return
  end
  local col = A.cols[ci]
  local cur = A.cells[vim.api.nvim_win_get_cursor(0)[1]][ci] or ""
  local vals = allowed(it, col.prop)
  local v
  if vals and #vals > 0 then
    v = utils.select(vals, { prompt = col.prop .. " value" })
  else
    v = utils.input({ prompt = col.title .. ": ", default = cur })
  end
  if v == nil then
    return
  end
  if set_value(it, col.prop, vim.trim(v)) then
    redo()
  end
end

--- Next/previous allowed value (n / p, org-columns-next-allowed-value).
function M.next_allowed(dir)
  local it, ci, lnum = current()
  if not it then
    return
  end
  local col = A.cols[ci]
  local vals = allowed(it, col.prop)
  if not vals or #vals == 0 then
    utils.warn("Allowed values for this property have not been defined")
    return
  end
  local cur = vim.trim(A.cells[lnum][ci] or "")
  local idx
  for i, v in ipairs(vals) do
    if v == cur then
      idx = i
    end
  end
  local n = #vals
  local new = vals[idx and ((idx - 1 + dir) % n + 1) or (dir > 0 and 1 or n)]
  if set_value(it, col.prop, new) then
    redo()
  end
end

--- Show the full value under the cursor (v).
function M.show()
  local it, ci, lnum = current()
  if it then
    utils.notify(A.cols[ci].title .. ": " .. (A.cells[lnum][ci] or ""))
  end
end

--- Map the column-view keys in the agenda buffer, saving the agenda maps.
function M.map_keys(buf)
  local saved = {}
  for _, lhs in ipairs(KEYS) do
    local m = vim.fn.maparg(lhs, "n", false, true)
    if m and m.buffer == 1 then
      saved[#saved + 1] = m
    end
  end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      utils.run(fn)
    end, { buffer = buf, nowait = true, desc = "org agenda columns: " .. desc })
  end
  map("q", M.quit, "quit column view")
  map("e", M.edit, "edit value")
  map("v", M.show, "show value")
  map("n", function()
    M.next_allowed(1)
  end, "next allowed value")
  map("<S-Right>", function()
    M.next_allowed(1)
  end, "next allowed value")
  map("p", function()
    M.next_allowed(-1)
  end, "previous allowed value")
  map("<S-Left>", function()
    M.next_allowed(-1)
  end, "previous allowed value")
  A.maps = saved
end

--- Remove the column view and restore the agenda keys.
function M.quit()
  if not A then
    return
  end
  local buf = A.buf
  clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    for _, lhs in ipairs(KEYS) do
      pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    end
    vim.api.nvim_buf_call(buf, function()
      for _, m in ipairs(A.maps or {}) do
        pcall(vim.fn.mapset, "n", false, m)
      end
    end)
  end
  A = nil
end

--- Toggle the column view (C-c C-x C-c in the agenda).
function M.toggle()
  if M.active() then
    M.quit()
    return false
  end
  return M.apply()
end

--- Re-draw after the agenda was re-rendered (call at the end of
--- `view.refresh`); also honours `agenda.view_columns_initially` for a
--- freshly opened agenda when `initial` is set.
function M.refresh_if_active(initial)
  if M.active() then
    return M.apply()
  elseif initial and config.opts.agenda.view_columns_initially then
    return M.apply()
  end
  return false
end

--- Values shown for a line (for tests): the cells of agenda line `lnum`.
function M.cells(lnum)
  return A and A.cells[lnum]
end

return M

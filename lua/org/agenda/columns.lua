---@mod org.agenda.columns Column view in the agenda (org-agenda-columns)
---
--- Overlays every agenda entry line with its column values, like Emacs
--- `org-agenda-columns` (C-c C-x C-c in the agenda). Date lines and block
--- headers show the summaries of the entries below them
--- (org-agenda-columns-show-summaries). The agenda keeps working: the
--- overlay is virtual text, so the entry under the cursor is still the
--- agenda entry. While active, `q` removes the column view, `e` edits the
--- value under the cursor, `n`/`p` (`<S-Right>`/`<S-Left>`) switch to the
--- next/previous allowed value and `v` shows the full value. The column
--- titles are in the window's winbar (Emacs header-line).

local columns = require("org.columns")
local config = require("org.config")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.agenda.columns")

--- Active column view: { buf, cols, widths, cells = { [lnum] = { values } },
--- display = { [lnum] = { displayed values } }, maps }
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

--- The columns format (org-agenda-columns): `overriding_columns_format`
--- of the agenda's custom command `settings` (Emacs
--- org-overriding-columns-format, kept for the agenda buffer as
--- org-local-columns-format), else the global `overriding_columns_format`
--- (org-columns-default-format-for-agenda), else the COLUMNS property /
--- #+COLUMNS of the entry at point, else of the first entry of the
--- agenda, else `columns_default_format`.
function M.format(S)
  local s = S.view and S.view.settings
  for _, fmt in ipairs({ s and s.overriding_columns_format or false, config.opts.agenda.overriding_columns_format }) do
    if fmt and fmt ~= "" then
      return fmt
    end
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

--- Summaries of the agenda columns in the files of the agenda entries
--- (org-agenda-colview-compute): `{ [hl] = { [i] = summary } }`. For each
--- file, with the format of the whole file, a summary column is computed
--- when the file's first column of that property has the same operator
--- as the agenda's, and an agenda column shows the summary of the file
--- column with the same specification (Emacs looks the summary up by
--- the whole column spec: property, title, width, operator and format).
--- As in Emacs, a summary is written back to the property of an entry
--- that has it (org-columns-compute), in the file's buffer when it is
--- loaded. CLOCKSUM and CLOCKSUM_T are summed by `columns.value`.
local function agenda_summaries(S, cols)
  local files, order = {}, {}
  for _, it in pairs(S.line_items) do
    local file = it.headline and it.headline.file
    if file and not files[file] then
      files[file] = true
      order[#order + 1] = file
    end
  end
  local out = {}
  for _, file in ipairs(order) do
    local ffmt, roots = columns.file_scope(file)
    local fcols = columns.parse_format(ffmt)
    local first_op = {}
    for _, fc in ipairs(fcols) do
      local k = fc.prop:upper()
      if first_op[k] == nil then
        first_op[k] = fc.summary or false
      end
    end
    local props = {}
    for _, c in ipairs(cols) do
      local k = c.prop:upper()
      if c.summary and k ~= "CLOCKSUM" and k ~= "CLOCKSUM_T" and first_op[k] == c.summary then
        props[k] = true
      end
    end
    local sel = {}
    for _, fc in ipairs(fcols) do
      if props[fc.prop:upper()] then
        sel[#sel + 1] = fc
      end
    end
    if #sel > 0 then
      -- agenda column -> the file column with the same spec
      local match = {}
      for i, c in ipairs(cols) do
        for j, fc in ipairs(sel) do
          if
            not match[i]
            and fc.prop:upper() == c.prop:upper()
            and fc.title == c.title
            and fc.width == c.width
            and fc.summary == c.summary
            and fc.summary_fmt == c.summary_fmt
          then
            match[i] = j
          end
        end
      end
      for hl, row in pairs(columns.summaries(roots, sel, true)) do
        for i, j in pairs(match) do
          if row[j] then
            out[hl] = out[hl] or {}
            out[hl][i] = row[j]
          end
        end
      end
    end
  end
  return out
end

--- Real value of a column for an agenda item (what `e` edits and `v`
--- shows, Emacs org-columns-value): the summary of its children `summary`
--- first, then the entry's own value.
local function value(it, prop, summary)
  local key = prop:upper()
  if key == "ITEM" then
    return it.display_title or it.title or ""
  end
  if summary then
    return summary
  end
  local v = columns.value(it.headline, prop)
  if
    (v == nil or v == "")
    and config.opts.agenda.columns_add_appointments_to_effort_sum
    and key == (config.opts.effort_property or "Effort"):upper()
    and it.time
    and it.end_time
  then
    -- org-agenda-columns-add-appointments-to-effort-sum: the duration of
    -- the appointment stands for the missing effort
    return require("org.duration").from_minutes(it.end_time - it.time)
  end
  return v or ""
end

--- Displayed value of a column (org-columns--displayed-value with NO-STAR,
--- as org-agenda-columns calls it): the user's
--- `columns_modify_value_for_display_function` first, then ITEM without
--- stars and with its links shown as their description, active timestamps
--- of SCHEDULED/DEADLINE/TIMESTAMP as inactive ones, the column's printf
--- format.
local function displayed(col, v)
  if col.prop:upper() == "ITEM" then
    local modify = config.opts.columns_modify_value_for_display_function
    local m = type(modify) == "function" and modify(col.title, v) or nil
    if m ~= nil then
      return m
    end
    return require("org.agenda.render").display_title(v)
  end
  return columns.display_value(col, v)
end

--- Emacs overlay text: "%-W.Ws | " per column, "%-W.Ws |" for the last.
local function row_text(cells, widths)
  local parts = {}
  for i, v in ipairs(cells) do
    local w = widths[i]
    local s = require("org.columns").add_ellipses(v or "", w)
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

--- Change the agenda buffer's text without leaving it modifiable or
--- modified.
local function edit_text(buf, fn)
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  local ok, err = pcall(fn)
  vim.bo[buf].modifiable = modifiable
  vim.bo[buf].modified = false
  if not ok then
    error(err, 0)
  end
end

--- Pad line `l` of `buf` with spaces to `width` display cells, so that the
--- cursor reaches every cell of the row drawn over it. Emacs puts each
--- column on a character of the line and, when the line is shorter than
--- that, inserts spaces at its end (org-columns--display-here: "there has
--- to be at least as many characters available on the line as columns to
--- display"); here a cell takes as many cells of the line as of the row.
local function pad_line(buf, pads, l, line, width)
  local lw = utils.width(line)
  if lw >= width then
    return
  end
  vim.api.nvim_buf_set_text(buf, l - 1, #line, l - 1, #line, { string.rep(" ", width - lw) })
  pads[l] = #line
end

--- Is the padding of view `state` still in its buffer (not re-rendered
--- since)?
local function padded(state)
  return state.pads ~= nil
    and vim.api.nvim_buf_is_valid(state.buf)
    and vim.api.nvim_buf_get_changedtick(state.buf) == state.pad_tick
end

--- Remove the padding of `pad_line` (on quit and before the rows are drawn
--- again), unless the agenda was re-rendered since.
local function unpad(state)
  if padded(state) then
    local buf = state.buf
    edit_text(buf, function()
      for l, len in pairs(state.pads) do
        local line = vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1]
        if line and #line > len then
          vim.api.nvim_buf_set_text(buf, l - 1, len, l - 1, #line, { "" })
        end
      end
    end)
  end
  state.pads = nil
end

--- The lines of agenda buffer `buf` without the column view's padding
--- (what writing the agenda to a file exports).
function M.lines(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if A and A.buf == buf and padded(A) then
    for l, len in pairs(A.pads) do
      if lines[l] then
        lines[l] = lines[l]:sub(1, len)
      end
    end
  end
  return lines
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
  if A and A.buf == buf then
    unpad(A)
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- org-agenda-columns-compute-summary-properties: a parent entry shows
  -- the summary of its children
  local sums = {}
  if config.opts.agenda.columns_compute_summary_properties ~= false then
    sums = agenda_summaries(S, cols)
  end
  local cells, display = {}, {}
  for l, it in pairs(S.line_items) do
    if it.headline then
      local row, shown = {}, {}
      local hs = sums[it.headline] or {}
      for i, c in ipairs(cols) do
        row[i] = value(it, c.prop, hs[i])
        shown[i] = displayed(c, row[i])
      end
      cells[l], display[l] = row, shown
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
    for l, parts in pairs(S.line_parts or {}) do
      for _, h in ipairs(parts) do
        if h[3] == "OrgAgendaHeader" and h[1] == 0 then
          structural[l] = true
        end
      end
    end
    -- summaries combine the real values, not the displayed ones
    -- (org-agenda-colview-summarize)
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
      for _, row in pairs(display) do
        w = math.max(w, utils.width(row[i] or ""))
      end
      widths[i] = w
    end
  end
  clear(buf)
  for group, link in pairs(HL) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  local pads = {}
  local function overlay(l, row, group)
    local text = row_text(row, widths)
    local lw = utils.width(lines[l] or "")
    if lw > utils.width(text) then
      text = text .. string.rep(" ", lw - utils.width(text))
    elseif lines[l] then
      pad_line(buf, pads, l, lines[l], utils.width(text))
    end
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, l - 1, 0, {
      virt_text = { { text, group } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
      priority = 300,
    })
  end
  edit_text(buf, function()
    for l, row in pairs(display) do
      overlay(l, row, "OrgAgendaColumn")
    end
    for l, row in pairs(summaries) do
      overlay(l, row, "OrgAgendaColumnDateline")
    end
  end)
  local titles = {}
  for i, c in ipairs(cols) do
    titles[i] = c.title
  end
  local was = A
  A = {
    buf = buf,
    cols = cols,
    widths = widths,
    cells = cells,
    display = display,
    fmt = fmt,
    maps = was and was.buf == buf and was.maps,
    pads = pads,
    pad_tick = vim.api.nvim_buf_get_changedtick(buf),
  }
  -- the titles in the agenda window's winbar (Emacs header-line), after
  -- the number and sign columns
  local win = S.win
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
    local saved = was and was.buf == buf and was.win == win and was.saved_winbar
    if not saved then
      saved = vim.api.nvim_get_option_value("winbar", { scope = "local", win = win })
    end
    A.win, A.saved_winbar = win, saved
    local textoff = (vim.fn.getwininfo(win)[1] or {}).textoff or 0
    local title = row_text(titles, widths):gsub("%%", "%%%%")
    local bar = "%#Normal#" .. string.rep(" ", textoff) .. "%#OrgAgendaColumnTitle#" .. title .. "%#Normal#"
    vim.api.nvim_set_option_value("winbar", bar, { scope = "local", win = win })
  end
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
    utils.save_buffer_or_warn(target.bufnr)
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
  local key = col.prop:upper()
  if key == "SCHEDULED" or key == "DEADLINE" then
    -- the date prompt of org-schedule / org-deadline at the source entry,
    -- then the column view is redone (org-columns-edit-value)
    local target = view_mod().resolve_target(it)
    if not target then
      return
    end
    local ts = require("org.timestamps")
    if not (key == "SCHEDULED" and ts.schedule or ts.deadline)(target) then
      return
    end
    if config.opts.agenda.save_after_edit then
      utils.save_buffer_or_warn(target.bufnr)
    end
    redo()
    return
  elseif columns.SPECIAL[key] and key ~= "TODO" and key ~= "PRIORITY" and key ~= "TAGS" and key ~= "ITEM" then
    -- CLOCKSUM, CATEGORY, ... are computed: say so before any prompt
    utils.warn("This special column cannot be edited")
    return
  end
  -- the real value, not its displayed form (org-columns-value)
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

--- Show the full real value under the cursor (v, org-columns-show-value).
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
  unpad(A)
  if A.win and A.saved_winbar and vim.api.nvim_win_is_valid(A.win) then
    pcall(vim.api.nvim_set_option_value, "winbar", A.saved_winbar, { scope = "local", win = A.win })
  end
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
--- `view.refresh`); also honours `view_columns_initially` (of the custom
--- command's `settings`, else `agenda.view_columns_initially`) for a
--- freshly opened agenda when `initial` is set.
function M.refresh_if_active(initial)
  if M.active() then
    return M.apply()
  elseif initial and view_mod().command_option("view_columns_initially", view_mod().state) then
    return M.apply()
  end
  return false
end

--- Values shown for a line (for tests): the displayed cells of agenda
--- line `lnum`.
function M.cells(lnum)
  return A and A.display[lnum]
end

--- Real values of a line (for tests): what `e` edits and `v` shows.
function M.values(lnum)
  return A and A.cells[lnum]
end

return M

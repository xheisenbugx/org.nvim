---@mod org.columns.edit Editing in the column view
---
--- Editing values (allowed values, next / previous value), adding,
--- deleting, moving and widening columns, moving rows.
--- Part of org.columns, which loads it.

local config = require("org.config")
local date = require("org.date")
local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.columns.shared")

local M = require("org.columns")

local anchor_line = shared.anchor_line
local current = shared.current
local goto_cell = shared.goto_cell
local refresh = shared.refresh
local render = shared.render

--- Write a column format back: to the COLUMNS property that defines the
--- view, else the first `#+COLUMNS:` line, else a new `#+COLUMNS:` line
--- before the first heading. Emacs org-columns-store-format.
local function store_format(state, cols)
  local fmt = M.format_string(cols)
  if state.holder then
    require("org.edit").set_property(state.src, state.holder.line or 1, "COLUMNS", fmt)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(state.src, 0, -1, false)
  local file = files.get_buffer(state.src)
  local imported
  for _, entry in ipairs(file.settings.keyword_entries) do
    if entry.key == "COLUMNS" and entry.value ~= "" then
      if entry.filename == file.filename then
        local pre = lines[entry.line]:match("^(%s*#%+[^:]+:)")
        vim.api.nvim_buf_set_lines(state.src, entry.line - 1, entry.line, false, { pre .. " " .. fmt })
        return
      end
      imported = imported or entry
    end
  end
  if imported then
    -- Override the shared setup locally, before the directive that imports
    -- it. Never rewrite the shared file.
    local at = imported.source_line - 1
    vim.api.nvim_buf_set_lines(state.src, at, at, false, { "#+COLUMNS: " .. fmt })
    return
  end
  local at = #lines
  for i, l in ipairs(lines) do
    if l:match("^%*+%s") then
      at = i - 1
      break
    end
  end
  vim.api.nvim_buf_set_lines(state.src, at, at, false, { "#+COLUMNS: " .. fmt })
end

--- Allowed values for column `ci` of row `r`: TODO keywords, priorities,
--- `PROP_ALL`, else checkboxes for checkbox summaries, else the days
--- around a timestamp value (Emacs org-columns-next-allowed-value).
local function allowed_values(state, r, ci)
  local col = state.cols[ci]
  local key = col.prop:upper()
  local file = files.get_buffer(state.src)
  local vals
  if key == "TODO" then
    vals = vim.list_extend(vim.deepcopy(file.settings.todo:names()), { "" })
  elseif key == "PRIORITY" then
    local prio = require("org.priority")
    local range = prio.range(file)
    vals = {}
    for v = range.hi, range.lo do
      vals[#vals + 1] = prio.to_string(v)
    end
  elseif not M.SPECIAL[key] then
    vals = vim.tbl_filter(function(v)
      return v ~= ":ETC"
    end, r.hl:get_allowed_values(col.prop) or {})
  end
  if (not vals or #vals == 0) and (col.summary == "X" or col.summary == "X/" or col.summary == "X%") then
    vals = vim.deepcopy(config.opts.columns_checkbox_allowed_values or { "[ ]", "[X]" })
  end
  if not vals or #vals == 0 then
    local v = vim.trim(r.cells[ci] or "")
    local item = date.parse_all(v)[1]
    if item and item.raw == v then
      vals = {}
      for d = -1, 1 do
        vals[#vals + 1] = item.date:add(d, "d"):to_string()
      end
    end
  end
  return vals and #vals > 0 and vals or nil
end

--- Set column `ci` of row `r` to `value` in the source buffer.
local function set_value(state, r, ci, value)
  local prop = state.cols[ci].prop
  local key = prop:upper()
  local target = { bufnr = state.src, lnum = r.hl.line }
  if key == "TODO" then
    require("org.todo").change_state(target, value ~= "" and value or nil)
  elseif key == "PRIORITY" then
    require("org.priority").set(target, value)
  else
    require("org.edit").set_property(state.src, r.hl.line, prop, value)
  end
end

--- Switch to the next (`dir` = 1) or previous (-1) allowed value, or to
--- the `nth` one (0 = the last). Emacs n / p / S-<right> / S-<left>
--- (org-columns-next-allowed-value).
local function next_allowed(state, dir, nth)
  local r, ci = current(state)
  if not r then
    return
  end
  local col = state.cols[ci]
  local key = col.prop:upper()
  if key == "ITEM" then
    utils.warn("Cannot edit item headline from here")
    return
  elseif key == "SCHEDULED" or key == "DEADLINE" then
    local d = r.hl.planning[key:lower()]
    if d then
      require("org.edit").set_planning(state.src, r.hl.line, key:lower(), d:add_with_range(dir, "d"))
      refresh(state, ci)
    end
    return
  end
  local allowed = allowed_values(state, r, ci)
  if not allowed then
    utils.warn("Allowed values for this property have not been defined")
    return
  end
  local new
  if nth then
    if nth > #allowed then
      utils.warn(string.format("Only %d allowed values for property `%s'", #allowed, col.prop))
      return
    end
    new = allowed[(nth - 1) % #allowed + 1]
  else
    local list = allowed
    if dir < 0 then
      list = {}
      for i = #allowed, 1, -1 do
        list[#list + 1] = allowed[i]
      end
    end
    local value = vim.trim(r.cells[ci] or "")
    local idx
    for i, v in ipairs(list) do
      if v == value then
        idx = i
      end
    end
    if idx and #list == 1 then
      utils.warn("Only one allowed value for this property")
      return
    end
    new = idx and list[idx % #list + 1] or list[1]
  end
  set_value(state, r, ci, new)
  refresh(state, ci)
end

--- Edit a value with the regular command for the column. Emacs e
--- (org-columns-edit-value).
local function edit_cell(state)
  local r, ci = current(state)
  if not r then
    return
  end
  local col = state.cols[ci]
  local key = col.prop:upper()
  local target = { bufnr = state.src, lnum = r.hl.line }
  if key == "ITEM" then
    local v = utils.input({ prompt = "Headline: ", default = r.hl.title })
    if v then
      require("org.edit").update_headline(state.src, r.hl.line, { title = v })
    end
  elseif key == "TODO" then
    require("org.todo").select(target)
  elseif key == "PRIORITY" then
    require("org.priority").set(target)
  elseif key == "TAGS" then
    require("org.tags").set_tags(target)
  elseif key == "SCHEDULED" then
    require("org.timestamps").schedule(target)
  elseif key == "DEADLINE" then
    require("org.timestamps").deadline(target)
  elseif M.SPECIAL[key] then
    utils.warn("This special column cannot be edited")
    return
  else
    local allowed = allowed_values(state, r, ci)
    local v
    if allowed then
      v = utils.select(allowed, { prompt = col.prop .. " value" })
    else
      v = utils.input({ prompt = "Edit: ", default = r.cells[ci] or "" })
    end
    if v == nil or vim.trim(v) == (r.cells[ci] or "") then
      return
    end
    require("org.edit").set_property(state.src, r.hl.line, col.prop, vim.trim(v))
  end
  refresh(state, ci)
end

--- Edit the allowed values (`PROP_ALL`) of the current column where they
--- are defined, else at the top of the view: the entry holding its
--- COLUMNS, the headline it was opened on, or the start of the file for
--- the whole file (line 1: the file-level drawer, or the headline there).
--- Emacs a (org-columns-edit-allowed, org-columns-top-level-marker); a
--- `#+PROPERTY` value does not count as defined, as there.
local function edit_allowed(state)
  local r, ci = current(state)
  if not r then
    return
  end
  local prop = state.cols[ci].prop
  local key = prop:upper() .. "_ALL"
  local file = files.get_buffer(state.src)
  local where = r.hl
  while where and not where.properties[key] do
    where = where.parent
  end
  if not where and file.properties[key] then
    where = { line = 1 } -- inherited from the file-level drawer
  end
  if not where then
    where = state.holder or (not state.global and file:headline_at(anchor_line(state))) or { line = 1 }
  end
  -- the raw value keeps quoted items ("Deutsche Grammophon") intact
  local cur = r.hl:get_property(key, true)
  local v = utils.input({ prompt = "Allowed: ", default = cur or "" })
  if v == nil then
    return
  end
  require("org.edit").set_property(state.src, where.line or 1, prop .. "_ALL", vim.trim(v))
  refresh(state, ci)
end

--- Prompt for column attributes (defaults from `spec`).
local function read_column(state, spec)
  spec = spec or {}
  local prop = utils.input_complete("Property: ", require("org.properties").known_names(state.src), spec.prop)
  if not prop or vim.trim(prop) == "" then
    return nil
  end
  prop = vim.trim(prop)
  local default_title = spec.title and spec.title ~= spec.prop and spec.title or ""
  local title = utils.input({ prompt = "Column title [" .. prop .. "]: ", default = default_title })
  if title == nil then
    return nil
  end
  local width = utils.input({ prompt = "Column width: ", default = spec.width and tostring(spec.width) or "" })
  if width == nil then
    return nil
  end
  local summaries = { { value = "", label = "(none)" } }
  for _, s in ipairs(M.SUMMARY_TYPES) do
    summaries[#summaries + 1] = { value = s, desc = M.SUMMARY_DESCRIPTIONS[s] }
  end
  local summary = require("org.ui").choose({
    prompt = "Summary: ",
    title = "Summary type",
    items = summaries,
    default = spec.summary or "",
  })
  if summary == nil then
    return nil
  end
  local sfmt = utils.input({ prompt = "Format: ", default = spec.summary_fmt or "" })
  if sfmt == nil then
    return nil
  end
  title, summary, sfmt = vim.trim(title), vim.trim(summary), vim.trim(sfmt)
  return {
    prop = prop,
    title = title ~= "" and title or prop,
    width = tonumber(width),
    summary = summary ~= "" and summary or nil,
    summary_fmt = sfmt ~= "" and sfmt or nil,
  }
end

--- Insert a new column left of the current one or, with `edit`, change
--- the current column's attributes. Emacs M-S-<right> / s
--- (org-columns-new / org-columns-edit-attributes).
local function new_column(state, edit)
  local _, ci = current(state)
  ci = ci or 1
  local spec = read_column(state, edit and state.cols[ci] or nil)
  if not spec then
    return
  end
  local cols = vim.deepcopy(state.cols)
  if edit then
    cols[ci] = spec
  else
    table.insert(cols, ci, spec)
  end
  store_format(state, cols)
  refresh(state, ci)
end

--- Remove the current column from the format. Emacs M-S-<left>
--- (org-columns-delete).
local function delete_column(state)
  local _, ci = current(state)
  ci = ci or 1
  if #state.cols <= 1 then
    utils.warn("Cannot delete the last column")
    return
  end
  if not utils.confirm(string.format("Are you sure you want to remove column %s?", state.cols[ci].title)) then
    return
  end
  local cols = vim.deepcopy(state.cols)
  table.remove(cols, ci)
  store_format(state, cols)
  refresh(state, math.min(ci, #cols))
end

--- Swap the current column with its neighbour. Emacs M-<left> / M-<right>
--- (org-columns-move-left / right).
local function move_column(state, dir)
  local _, ci = current(state)
  ci = ci or 1
  local other = ci + dir
  if other < 1 or other > #state.cols then
    utils.warn("Cannot shift this column further to the " .. (dir < 0 and "left" or "right"))
    return
  end
  local cols = vim.deepcopy(state.cols)
  cols[ci], cols[other] = cols[other], cols[ci]
  store_format(state, cols)
  refresh(state, other)
end

--- Make the current column `delta` characters wider (narrower when
--- negative). Emacs > / < (org-columns-widen / narrow).
local function widen(state, delta)
  local _, ci = current(state)
  ci = ci or 1
  local cols = vim.deepcopy(state.cols)
  cols[ci].width = math.max(1, state.widths[ci] + delta)
  store_format(state, cols)
  refresh(state, ci)
end

--- Move the entry of the current row (with its subtree) up or down. Emacs
--- M-<up> / M-<down> (org-columns-move-row-up / down).
local function move_row(state, dir)
  local r, ci = current(state)
  if not r then
    return
  end
  local win = state.mode == "overlay" and vim.api.nvim_get_current_win() or vim.fn.win_findbuf(state.src)[1]
  if not win then
    utils.warn("The org buffer is not shown in a window")
    return
  end
  local line
  vim.api.nvim_win_call(win, function()
    vim.api.nvim_win_set_cursor(0, { r.hl.line, 0 })
    local structure = require("org.structure")
    if dir < 0 then
      structure.move_subtree_up()
    else
      structure.move_subtree_down()
    end
    line = vim.api.nvim_win_get_cursor(0)[1]
  end)
  render(state)
  for i, row in ipairs(state.rows) do
    if row.hl.line == line then
      goto_cell(state, state.mode == "overlay" and line or i + 2, ci)
      return
    end
  end
end

shared.delete_column = delete_column
shared.edit_allowed = edit_allowed
shared.edit_cell = edit_cell
shared.move_column = move_column
shared.move_row = move_row
shared.new_column = new_column
shared.next_allowed = next_allowed
shared.widen = widen

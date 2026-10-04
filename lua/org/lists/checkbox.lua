---@mod org.lists.checkbox Checkboxes
---
--- Toggling checkboxes and radio lists, resetting a subtree's boxes.
--- Part of org.lists, which loads it.

local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.lists.shared")

local M = require("org.lists")

local apply_struct = shared.apply_struct
local curbuf = shared.curbuf
local cursor_lnum = shared.cursor_lnum
local fix_box = shared.fix_box
local fix_bul = shared.fix_bul
local fix_ind = shared.fix_ind
local get_lines = shared.get_lines
local ordered_p = shared.ordered_p
local set_lines = shared.set_lines
local struct_changed = shared.struct_changed
local update_section = shared.update_section
local verbatim_lines = shared.verbatim_lines
local write_struct = shared.write_struct

---------------------------------------------------------------------------
-- Checkboxes
---------------------------------------------------------------------------

--- Is the list of `item` a radio list (`#+attr_org: :radio t` before it)?
function M.radio_list_p(bufnr, item)
  bufnr = curbuf(bufnr)
  local first = M.siblings(item)[1]
  local l = first.lnum - 1
  while l >= 1 do
    local line = get_lines(bufnr, l, l)[1]
    if not line:match("^%s*#%+[%w_]+") then
      break
    end
    local v = line:lower():match("^%s*#%+attr_org:.* :radio (%S+)")
    if v then
      return v ~= "nil"
    end
    l = l - 1
  end
  return false
end

--- org-toggle-radio-button: check the item at the cursor and uncheck
--- its siblings. `arg`: 4 removes the box, 16 sets `[-]`.
function M.toggle_radio_button(arg)
  arg = arg or (vim.v.count > 0 and vim.v.count or nil)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor_lnum()
  local struct, item = M.struct_at(bufnr, lnum)
  if not struct or item.lnum ~= lnum then
    utils.warn("Cannot toggle checkbox outside of a list")
    return
  end
  local cbox = item.checkbox
  local sibs = M.siblings(item)
  local new
  if not (cbox and arg == 4 and sibs[1] == item) then
    new = " "
  end
  for _, s in ipairs(sibs) do
    s.box = new
  end
  if new then
    if arg == 4 then
      item.box = not cbox and " " or nil
    elseif arg == 16 then
      item.box = not cbox and "-" or nil
    else
      item.box = cbox == "X" and " " or "X"
    end
  end
  write_struct(struct, ordered_p(bufnr, lnum))
  M.update_checkbox_count_maybe(bufnr, lnum)
end

--- Toggle org-list-checkbox-radio-mode in the current buffer: C-c C-c on
--- an item then toggles it like a radio button in every list, as if each
--- had `#+attr_org: :radio t`. Returns whether the mode is now on.
function M.checkbox_radio_mode()
  if not utils.is_org() then
    utils.error("Cannot turn this mode outside org-mode buffers")
    return nil
  end
  local on = not vim.b.org_checkbox_radio_mode
  vim.b.org_checkbox_radio_mode = on
  utils.notify("Org-List-Checkbox-Radio mode " .. (on and "enabled" or "disabled") .. " in current buffer")
  -- org-list-checkbox-radio-mode-hook
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "OrgListCheckboxRadioMode",
    data = { enabled = on, bufnr = vim.api.nvim_get_current_buf() },
    modeline = false,
  })
  return on
end

--- org-reset-checkbox-state-subtree: uncheck every checkbox of the
--- subtree at the cursor (`[X]` and `[-]` become `[ ]`), show the
--- subtree and update its statistics cookies.
function M.reset_checkbox_state_subtree()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(cursor_lnum())
  if not hl then
    utils.error("Not inside a tree")
    return
  end
  local s, e = hl.line, hl.end_line
  local verbatim = verbatim_lines(file.lines, s, e)
  for l = s, e do
    local line = file.lines[l]
    local it = not verbatim[l] and M.parse_item_line(line)
    if it and it.checkbox and it.checkbox ~= " " then
      -- the box must be followed by whitespace (org-at-item-checkbox-p)
      local p = it.indent + #it.bullet_ws
      local q = p + #(line:sub(p + 1):match("^%[@[^%]]*%][ \t]*") or "")
      if line:sub(q + 1, q + 3):match("^%[[xX%-]%]$") and line:sub(q + 4, q + 4):match("^[ \t]$") then
        set_lines(bufnr, l, l, { line:sub(1, q) .. "[ ]" .. line:sub(q + 4) })
      end
    end
  end
  if vim.api.nvim_get_current_buf() == bufnr then
    pcall(vim.cmd, s .. "," .. e .. "foldopen!")
  end
  if M.automatic_rule("checkbox") then
    file = files.get_buffer(bufnr)
    local hls = {}
    for _, h in ipairs(file.headlines) do
      if h.line >= s and h.line <= e then
        hls[#hls + 1] = { line = h.line, level = h.level }
      end
    end
    table.sort(hls, function(a, b)
      return a.level > b.level
    end)
    for _, x in ipairs(hls) do
      file = files.get_buffer(bufnr)
      local h = file:headline_on(x.line)
      if h then
        update_section(bufnr, file, h, h.line + 1, h.body_end)
      end
    end
  end
end

--- C-c C-c on an item (org-ctrl-c-ctrl-c): toggle its checkbox and
--- repair the list. `arg` 4 (C-u) adds or removes the checkbox, 16 (C-u
--- C-u) sets it to `[-]`. A parent checkbox follows its children, so
--- toggling it is refused. On an item without a checkbox, just repair.
function M.ctrl_c_ctrl_c_item(item, arg)
  local bufnr = vim.api.nvim_get_current_buf()
  if M.radio_list_p(bufnr, item) or vim.b[bufnr].org_checkbox_radio_mode then
    return M.toggle_radio_button(arg)
  end
  local struct, it = M.struct_at(bufnr, item.lnum)
  local box = it.checkbox
  local new
  if arg == 16 then
    new = "-"
  elseif not box and arg == 4 then
    new = " "
  elseif not box or arg == 4 then
    new = nil
  elseif box == "X" then
    new = " "
  else
    new = "X"
  end
  it.box = new
  fix_ind(struct)
  fix_bul(struct)
  fix_ind(struct)
  local block = fix_box(struct, ordered_p(bufnr, item.lnum))
  if box and not struct_changed(struct) then
    if arg == 16 then
      utils.notify("Checkboxes already reset")
    else
      utils.warn("Cannot toggle this checkbox: " .. (box == "X" and "all subitems checked" or "unchecked subitems"))
    end
    return
  end
  apply_struct(struct)
  M.update_checkbox_count_maybe(bufnr, item.lnum)
  if block then
    utils.notify(string.format("Checkboxes were removed due to empty box at line %d", block.lnum))
  end
end

--- org-toggle-checkbox on the items starting in [s, e] (`singlep` for a
--- single item).
local function toggle_checkbox_range(bufnr, s, e, arg, singlep)
  local lists = M.section_lists(bufnr, s)
  local first
  for _, l in ipairs(lists) do
    local function walk(its)
      for _, it in ipairs(its) do
        if it.lnum >= s and it.lnum <= e and (not first or it.lnum < first.lnum) then
          first = it
        end
        walk(it.children)
      end
    end
    walk(l.items)
  end
  if not first then
    return false
  end
  local ref
  if arg == 16 then
    ref = "-"
  elseif arg == 4 then
    ref = not first.checkbox and " " or nil
  elseif first.checkbox == "X" then
    ref = " "
  else
    ref = "X"
  end
  local ordered = ordered_p(bufnr, s)
  local lnum = first.lnum
  local done = {}
  while lnum and lnum <= e do
    local struct = M.struct_at(bufnr, lnum)
    if not struct or done[struct.first] then
      break
    end
    done[struct.first] = true
    for _, it in ipairs(struct.items) do
      if it.lnum >= s and it.lnum <= e and (it.checkbox or arg == 4) then
        it.box = ref
      end
    end
    fix_ind(struct)
    fix_bul(struct)
    fix_ind(struct)
    local block = fix_box(struct, ordered)
    if singlep and block and s > block.lnum then
      utils.warn(string.format("Checkbox blocked because of unchecked box at line %d", block.lnum))
      return
    elseif block then
      utils.notify(string.format("Checkboxes were removed due to unchecked box at line %d", block.lnum))
    end
    apply_struct(struct)
    -- next list starting in the range
    local next_lnum
    for _, l in ipairs(M.section_lists(bufnr, s)) do
      local fl = l.items[1].lnum
      if fl > struct.last and fl <= e and (not next_lnum or fl < next_lnum) then
        next_lnum = fl
      end
    end
    lnum = next_lnum
  end
  M.update_checkbox_count_maybe(bufnr, s)
  return true
end

--- Toggle checkboxes (org-toggle-checkbox, C-c C-x C-b): the item at the
--- cursor, every item of the Visual selection (following the first one),
--- or on a headline every item of the entry's text. Items without a
--- checkbox are left alone; with a count of 4 (C-u) checkboxes are added
--- or removed instead, and 16 (C-u C-u) sets them to `[-]`. A radio list
--- (`#+attr_org: :radio t`) toggles like a radio button. Returns false
--- when there is no item.
function M.toggle_checkbox()
  local bufnr = vim.api.nvim_get_current_buf()
  local arg = vim.v.count > 0 and vim.v.count or nil
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local s, _, e = utils.visual_range()
    utils.exit_visual()
    if toggle_checkbox_range(bufnr, s, e, arg, false) == false then
      utils.warn("No item in region")
    end
    return
  end
  local lnum = cursor_lnum()
  local file = files.get_buffer(bufnr)
  local hl = file:headline_on(lnum)
  if hl then
    local from = require("org.edit").meta_end(hl) + 1
    if toggle_checkbox_range(bufnr, from, hl.body_end, arg, false) == false then
      utils.warn("No item in subtree")
    end
    return
  end
  local item = M.item_on(bufnr, lnum)
  if not item then
    return false
  end
  if M.radio_list_p(bufnr, item) then
    return M.toggle_radio_button(arg)
  end
  toggle_checkbox_range(bufnr, lnum, lnum, arg, true)
end

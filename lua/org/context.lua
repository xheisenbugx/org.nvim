---@mod org.context Context-sensitive dispatch
---
--- Emacs binds many keys whose meaning depends on what is under the cursor
--- (C-c C-c, M-<arrows>, S-<arrows>, M-RET, C-c '). This module decides
--- which feature module handles the key. Returning `false` lets the
--- mapping fall back to the key's normal Vim behaviour.

local files = require("org.files")
local utils = require("org.utils")

local M = {}

local function line_at(lnum)
  return vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
end

local function cur()
  local lnum, col = utils.cursor()
  return lnum, col, line_at(lnum)
end

local function is_headline(line)
  return require("org.parser").headline_level(line) ~= nil
end

local function in_table(line)
  return line:match("^%s*|") ~= nil
end

local function list_item(lnum)
  return require("org.lists").item_at(0, lnum)
end

local function count()
  return math.max(vim.v.count, 1)
end

--- C-c C-c
function M.context_action()
  local sparse = require("org.agenda.sparse")
  if sparse.has_highlights() then
    -- like Emacs, the first C-c C-c after a sparse tree removes highlights
    return sparse.clear()
  end
  if require("org.clock").remove_overlays(0) then
    -- and the clock sums of org-clock-display
    utils.notify("Temporary highlights/overlays removed from current buffer")
    return true
  end
  local lnum, col, line = cur()
  if require("org.properties").at_property_line(0, lnum) then
    return require("org.properties").property_action()
  end
  if line:match("^%s*#%+[Tt][Bb][Ll][Ff][Mm]:") then
    return require("org.table").recalc()
  end
  if in_table(line) then
    return require("org.table").ctrl_c_ctrl_c()
  end
  local babel = require("org.babel")
  if babel.at_block(0, lnum) or babel.inline_at_cursor() then
    return babel.execute_block()
  end
  local dblock = require("org.dblock")
  if dblock.at_cursor() then
    return dblock.update_at_cursor()
  end
  if line:match("^%s*CLOCK:") then
    return require("org.clock").update_clock_line(0, lnum)
  end
  local footnotes = require("org.footnotes")
  if footnotes.at_point() then
    return footnotes.action_at_point()
  end
  if is_headline(line) then
    -- statistics cookie under cursor?
    local s, e = line:find("%[%d*[/%%]%d*%]")
    if s and col >= s and col <= e then
      return require("org.lists").update_statistics()
    end
    return require("org.tags").set_tags()
  end
  local item = list_item(lnum)
  if item then
    if item.checkbox then
      return require("org.lists").toggle_checkbox()
    end
    return require("org.lists").repair(0, lnum)
  end
  if line:match("<<<.->>>") then
    -- on a radio target: refresh radio link highlighting
    -- (org-update-radio-target-regexp)
    require("org.buffer").refresh(0)
    utils.notify("Radio targets updated")
    return
  end
  if line:match("^#%+") then
    require("org.buffer").refresh(0)
    utils.notify("Local setup has been refreshed")
    return
  end
  local ts = require("org.date").at_col(line, col)
  if ts then
    return require("org.timestamps").normalize_at_cursor()
  end
  utils.notify("C-c C-c: nothing to do here")
end

--- Open link / follow footnote / show agenda for timestamp.
function M.open_at_point()
  local links = require("org.links")
  if links.link_at_cursor() then
    return links.open_at_point()
  end
  local footnotes = require("org.footnotes")
  if footnotes.at_point() then
    return footnotes.action_at_point()
  end
  local _, col, line = cur()
  local ts = require("org.date").at_col(line, col)
  if ts then
    return require("org.agenda").open_day(ts.date)
  end
  return false
end

--- C-c ' : edit special
function M.edit_special()
  local lnum, _, line = cur()
  if in_table(line) or line:match("^%s*#%+[Tt][Bb][Ll][Ff][Mm]:") then
    return require("org.table").edit_formulas()
  end
  local babel = require("org.babel")
  if babel.at_block(0, lnum) then
    return babel.edit_special()
  end
  if require("org.special").edit_element(0, lnum) ~= false then
    return
  end
  -- #+INCLUDE / #+SETUPFILE / #+BIBLIOGRAPHY: visit the file
  if require("org.links").open_keyword_file(line, vim.api.nvim_get_current_buf()) then
    return
  end
  utils.warn("Nothing to edit here (place the cursor in a src block or table)")
end

---------------------------------------------------------------------------
-- M-RET
---------------------------------------------------------------------------

-- Like Emacs, leave the cursor on the new heading/item ready to type.
local function after_insert(_)
  vim.cmd("startinsert!")
end

function M.meta_return()
  local insert_mode = vim.fn.mode():sub(1, 1) == "i"
  local lnum, _, line = cur()
  if in_table(line) then
    require("org.table").insert_row(false)
    return
  end
  if list_item(lnum) and not is_headline(line) then
    require("org.lists").new_item({})
    after_insert(insert_mode)
    return
  end
  require("org.structure").meta_return_heading({})
  after_insert(insert_mode)
end

function M.meta_shift_return()
  local insert_mode = vim.fn.mode():sub(1, 1) == "i"
  local lnum, _, line = cur()
  if list_item(lnum) and not is_headline(line) then
    require("org.lists").new_item({ checkbox = true })
    after_insert(insert_mode)
    return
  end
  require("org.structure").meta_return_heading({ todo = true })
  after_insert(insert_mode)
end

--- Insert-mode TAB: next table field in a table; on an empty headline or
--- list item (e.g. right after M-RET), cycle its level
--- (org-cycle-level-after-item/entry-creation).
function M.insert_tab()
  local lnum, _, line = cur()
  if in_table(line) then
    return require("org.table").next_field()
  end
  if is_headline(line) then
    return require("org.structure").cycle_level()
  end
  if list_item(lnum) then
    return require("org.lists").cycle_item_indentation()
  end
  return false
end

---------------------------------------------------------------------------
-- Promote / demote / move
---------------------------------------------------------------------------

function M.promote()
  local lnum, _, line = cur()
  if is_headline(line) then
    for _ = 1, count() do
      require("org.structure").promote_heading()
    end
    return
  end
  if list_item(lnum) then
    return require("org.lists").indent_item(-1, false)
  end
  return false
end

function M.demote()
  local lnum, _, line = cur()
  if is_headline(line) then
    for _ = 1, count() do
      require("org.structure").demote_heading()
    end
    return
  end
  if list_item(lnum) then
    return require("org.lists").indent_item(1, false)
  end
  return false
end

function M.promote_subtree()
  local lnum, _, line = cur()
  if list_item(lnum) and not is_headline(line) then
    return require("org.lists").indent_item(-1, true)
  end
  if files.get_buffer(0):headline_at(lnum) then
    return require("org.structure").promote_subtree()
  end
  return false
end

function M.demote_subtree()
  local lnum, _, line = cur()
  if list_item(lnum) and not is_headline(line) then
    return require("org.lists").indent_item(1, true)
  end
  if files.get_buffer(0):headline_at(lnum) then
    return require("org.structure").demote_subtree()
  end
  return false
end

local function visual_active()
  return vim.fn.mode():match("^[vV\22]") ~= nil
end

function M.meta_left()
  if visual_active() then
    return require("org.structure").change_level_region(-1)
  end
  local _, _, line = cur()
  if in_table(line) then
    return require("org.table").move_column(-1)
  end
  return M.promote()
end

function M.meta_right()
  if visual_active() then
    return require("org.structure").change_level_region(1)
  end
  local _, _, line = cur()
  if in_table(line) then
    return require("org.table").move_column(1)
  end
  return M.demote()
end

function M.shift_meta_left()
  local _, _, line = cur()
  if in_table(line) then
    return require("org.table").delete_column()
  end
  if is_headline(line) or list_item(utils.cursor()) then
    return M.promote_subtree()
  end
  return false
end

function M.shift_meta_right()
  local _, _, line = cur()
  if in_table(line) then
    return require("org.table").insert_column()
  end
  if is_headline(line) or list_item(utils.cursor()) then
    return M.demote_subtree()
  end
  return false
end

function M.meta_up()
  local lnum, _, line = cur()
  if in_table(line) then
    return require("org.table").move_row(-1)
  end
  if is_headline(line) then
    return require("org.structure").move_subtree_up()
  end
  if list_item(lnum) then
    return require("org.lists").move_item(-1)
  end
  return false
end

function M.meta_down()
  local lnum, _, line = cur()
  if in_table(line) then
    return require("org.table").move_row(1)
  end
  if is_headline(line) then
    return require("org.structure").move_subtree_down()
  end
  if list_item(lnum) then
    return require("org.lists").move_item(1)
  end
  return false
end

local function timestamp_under_cursor()
  local _, col, line = cur()
  return require("org.date").at_col(line, col)
end

function M.shift_meta_up()
  local _, _, line = cur()
  if in_table(line) then
    return require("org.table").delete_row()
  end
  if line:match("^%s*CLOCK:") and timestamp_under_cursor() then
    return require("org.clock").timestamps_adjust_closest(count())
  end
  return require("org.structure").drag_line(-1)
end

function M.shift_meta_down()
  local _, _, line = cur()
  if in_table(line) then
    return require("org.table").insert_row(true)
  end
  if line:match("^%s*CLOCK:") and timestamp_under_cursor() then
    return require("org.clock").timestamps_adjust_closest(-count())
  end
  return require("org.structure").drag_line(1)
end

---------------------------------------------------------------------------
-- Shift arrows / increment
---------------------------------------------------------------------------

function M.shift_up()
  if timestamp_under_cursor() then
    return require("org.timestamps").increment(count())
  end
  if require("org.clock").clocktable_shift(count()) then
    return true
  end
  local lnum, _, line = cur()
  if is_headline(line) then
    return require("org.priority").shift(nil, 1)
  end
  if in_table(line) then
    return require("org.table").move_cell("up")
  end
  if require("org.lists").parse_item_line(line) and list_item(lnum) then
    return require("org.lists").prev_item()
  end
  return false
end

function M.shift_down()
  if timestamp_under_cursor() then
    return require("org.timestamps").increment(-count())
  end
  if require("org.clock").clocktable_shift(-count()) then
    return true
  end
  local lnum, _, line = cur()
  if is_headline(line) then
    return require("org.priority").shift(nil, -1)
  end
  if in_table(line) then
    return require("org.table").move_cell("down")
  end
  if require("org.lists").parse_item_line(line) and list_item(lnum) then
    return require("org.lists").next_item()
  end
  return false
end

--- C-S-<Right>/<Left>: switch to the next/previous TODO keyword set.
function M.shift_control_right()
  local _, _, line = cur()
  if not is_headline(line) then
    return false
  end
  return require("org.todo").next_sequence(nil, 1)
end

function M.shift_control_left()
  local _, _, line = cur()
  if not is_headline(line) then
    return false
  end
  return require("org.todo").next_sequence(nil, -1)
end

--- C-S-<Up>/<Down>: shift both timestamps of a CLOCK line.
function M.shift_control_up()
  return require("org.clock").timestamps_shift(count())
end

function M.shift_control_down()
  return require("org.clock").timestamps_shift(-count())
end

local function in_visual()
  return vim.fn.mode():match("^[vV\22]") ~= nil
end

--- C-c *: recalculate a table, else toggle heading.
function M.ctrl_c_star()
  local lnum, _, line = cur()
  if in_table(line) then
    if vim.v.count >= 16 then
      return require("org.table").recalc_buffer(0)
    end
    return require("org.table").recalc(0, lnum)
  end
  return require("org.structure").toggle_heading()
end

--- C-c -: table hline, else cycle the bullet of an item, else toggle item.
function M.ctrl_c_minus()
  local lnum, _, line = cur()
  if in_table(line) then
    return require("org.table").insert_hline(vim.v.count > 0)
  end
  if not in_visual() and not is_headline(line) and list_item(lnum) then
    return require("org.lists").cycle_bullet(1)
  end
  return require("org.lists").toggle_item()
end

--- C-c RET: hline and move in a table, else insert a heading.
function M.ctrl_c_ret()
  local _, _, line = cur()
  if in_table(line) then
    return require("org.table").hline_and_move(vim.v.count > 0)
  end
  return require("org.structure").insert_heading()
end

--- C-c C-x M-w / C-w / C-y: table rectangle in tables, else subtree.
function M.copy_special()
  local _, _, line = cur()
  if in_table(line) then
    return require("org.table").copy_region()
  end
  return require("org.structure").copy_subtree()
end

function M.cut_special()
  local _, _, line = cur()
  if in_table(line) then
    return require("org.table").cut_region()
  end
  return require("org.structure").cut_subtree()
end

function M.paste_special()
  local _, _, line = cur()
  if in_table(line) then
    return require("org.table").paste_rectangle()
  end
  return require("org.structure").paste_subtree()
end

--- C-c ^: sort a table column, else sort entries or list items.
function M.ctrl_c_caret()
  local _, _, line = cur()
  if in_table(line) then
    return require("org.table").sort_column()
  end
  return require("org.structure").sort()
end

function M.shift_right()
  if timestamp_under_cursor() then
    return require("org.timestamps").increment(count(), "d")
  end
  if require("org.clock").clocktable_shift(count()) then
    return true
  end
  local lnum, _, line = cur()
  if is_headline(line) then
    return require("org.todo").cycle_next()
  end
  if require("org.properties").at_property_line(0, lnum) then
    return require("org.properties").next_allowed_value(1)
  end
  if list_item(lnum) then
    return require("org.lists").cycle_bullet(1)
  end
  if in_table(line) then
    return require("org.table").move_cell("right")
  end
  return false
end

function M.shift_left()
  if timestamp_under_cursor() then
    return require("org.timestamps").increment(-count(), "d")
  end
  if require("org.clock").clocktable_shift(-count()) then
    return true
  end
  local lnum, _, line = cur()
  if is_headline(line) then
    return require("org.todo").cycle_prev()
  end
  if require("org.properties").at_property_line(0, lnum) then
    return require("org.properties").next_allowed_value(-1)
  end
  if list_item(lnum) then
    return require("org.lists").cycle_bullet(-1)
  end
  if in_table(line) then
    return require("org.table").move_cell("left")
  end
  return false
end

function M.increment()
  if timestamp_under_cursor() then
    return require("org.timestamps").increment(count())
  end
  local _, col, line = cur()
  local s, e = line:find("%[#%w%w?%]")
  if is_headline(line) and s and col >= s and col <= e then
    return require("org.priority").shift(nil, 1)
  end
  return false
end

function M.decrement()
  if timestamp_under_cursor() then
    return require("org.timestamps").increment(-count())
  end
  local _, col, line = cur()
  local s, e = line:find("%[#%w%w?%]")
  if is_headline(line) and s and col >= s and col <= e then
    return require("org.priority").shift(nil, -1)
  end
  return false
end

return M

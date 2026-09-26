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
    -- apply the formulas of this #+TBLFM line (org-table-calc-current-TBLFM)
    return require("org.table").calc_current_tblfm(0, lnum)
  end
  if line:match("^%s*#%+[Pp][Ll][Oo][Tt]:") then
    return require("org.table.plot").gnuplot(0, lnum)
  end
  if line:match("^%s*#%+[Oo][Rr][Gg][Tt][Bb][Ll]:") then
    -- recalculate the table below and send it (org-ctrl-c-ctrl-c on a table)
    local nxt = vim.api.nvim_buf_get_lines(0, lnum, lnum + 1, false)[1]
    if nxt and in_table(nxt) then
      require("org.table").recalc(0, lnum + 1)
      require("org.table.orgtbl").send_table(0, lnum + 1, true)
      return true
    end
  end
  if in_table(line) then
    return require("org.table").ctrl_c_ctrl_c()
  end
  local babel = require("org.babel")
  if babel.at_block(0, lnum) or babel.inline_at_cursor() then
    return babel.ctrl_c_ctrl_c()
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
  if item and item.lnum == lnum then
    local arg = vim.v.count > 0 and (vim.v.count >= 16 and 16 or 4) or nil
    return require("org.lists").ctrl_c_ctrl_c_item(item, arg)
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
  utils.warn("C-c C-c can do nothing useful here")
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
  local b = babel.at_block(0, lnum)
  if b and not b.call and lnum <= b.finish then
    return babel.edit_special({ session = vim.v.count > 0 })
  end
  local special = require("org.special")
  if special.edit_element(0, lnum) ~= false then
    return
  end
  -- #+INCLUDE / #+SETUPFILE / #+BIBLIOGRAPHY: visit the file
  if require("org.links").open_keyword_file(line, vim.api.nvim_get_current_buf()) then
    return
  end
  local _, col = cur()
  if special.edit_object(0, lnum, col) then
    return
  end
  utils.error("No special environment to edit here")
end

---------------------------------------------------------------------------
-- M-RET
---------------------------------------------------------------------------

-- Like Emacs, leave the cursor on the new heading/item ready to type.
local function after_insert(insert_mode)
  if insert_mode then
    return
  end
  utils.start_insert()
end

--- Where M-RET acts: in Insert mode at the cursor (splitting the line
--- when `meta_return_split_line` allows it); in Normal mode at the end of
--- the line without splitting, or at its beginning in column 0 (not on a
--- list item: the Normal-mode cursor sits on the bullet, so the new item
--- goes after it; `i<M-CR>` still adds one before it, as in Emacs).
local function meta_return_point(insert_mode, item)
  local pos = vim.api.nvim_win_get_cursor(0)
  if insert_mode then
    return pos, nil
  end
  if pos[2] == 0 and not item then
    return pos, false
  end
  return { pos[1], #vim.api.nvim_get_current_line() }, false
end

--- The C-u prefix of M-RET given as a count: 16 or more is C-u C-u.
local function prefix_arg()
  local c = vim.v.count
  if c == 0 then
    return nil
  end
  return c >= 16 and 16 or 4
end

--- M-RET (org-meta-return): a new item in a list, else a new headline
--- (org-insert-heading). With a count (C-u / C-u C-u), always a headline
--- after the subtree / at the end of the parent's subtree.
function M.meta_return()
  local insert_mode = vim.fn.mode():sub(1, 1) == "i"
  local lnum, _, line = cur()
  local arg = prefix_arg()
  if in_table(line) and not arg then
    require("org.table").insert_row(false)
    return
  end
  local item = not arg and list_item(lnum) and not is_headline(line)
  local pos, split = meta_return_point(insert_mode, item)
  if item then
    require("org.lists").new_item({ pos = pos, split = split })
    after_insert(insert_mode)
    return
  end
  require("org.structure").meta_return_heading({ pos = pos, split = split, arg = arg })
  after_insert(insert_mode)
end

--- M-S-RET (org-insert-todo-heading): a checkbox item in a list, else a
--- TODO headline with the keyword of the current entry (the first one
--- when it is done, or with a count).
function M.meta_shift_return()
  local insert_mode = vim.fn.mode():sub(1, 1) == "i"
  local lnum, _, line = cur()
  local item = list_item(lnum) and not is_headline(line)
  local pos, split = meta_return_point(insert_mode, item)
  if item then
    require("org.lists").new_item({ checkbox = true, pos = pos, split = split })
    after_insert(insert_mode)
    return
  end
  require("org.structure").meta_return_heading({ todo = true, pos = pos, split = split, arg = prefix_arg() })
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
  if require("org.config").opts.tempo and require("org.structure").tempo_expand() then
    return
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

local function item_line(lnum)
  return require("org.lists").item_on(0, lnum)
end

local function special_context_error()
  utils.warn("This command is active in special context like tables, headlines or items")
end

function M.promote()
  local lnum, _, line = cur()
  if is_headline(line) then
    for _ = 1, count() do
      require("org.structure").promote_heading()
    end
    return
  end
  if item_line(lnum) then
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
  if item_line(lnum) then
    return require("org.lists").indent_item(1, false)
  end
  return false
end

function M.promote_subtree()
  local lnum, _, line = cur()
  if item_line(lnum) and not is_headline(line) then
    return require("org.lists").indent_item(-1, true)
  end
  if files.get_buffer(0):headline_at(lnum) then
    return require("org.structure").promote_subtree()
  end
  return false
end

function M.demote_subtree()
  local lnum, _, line = cur()
  if item_line(lnum) and not is_headline(line) then
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

--- First non-blank line of the Visual selection, and the selection.
local function region()
  local s, _, e = utils.visual_range()
  local lines = vim.api.nvim_buf_get_lines(0, s - 1, e, false)
  local first = s
  for i, l in ipairs(lines) do
    if l:match("%S") then
      first = s + i - 1
      break
    end
  end
  return first, s, e
end

--- M-left / M-right with a Visual selection: promote / demote its
--- headlines, or outdent / indent its items (org-metaleft/right).
local function meta_left_right_region(delta)
  local first, s, e = region()
  local line = vim.api.nvim_buf_get_lines(0, first - 1, first, false)[1] or ""
  if is_headline(line) then
    return require("org.structure").change_level_region(delta)
  end
  if item_line(first) then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    return require("org.lists").indent_item(delta, false, { s, e })
  end
  return false
end

function M.meta_left()
  if visual_active() then
    return meta_left_right_region(-1)
  end
  local _, _, line = cur()
  if in_table(line) then
    return require("org.table").move_column(-1)
  end
  return M.promote()
end

function M.meta_right()
  if visual_active() then
    return meta_left_right_region(1)
  end
  local _, _, line = cur()
  if in_table(line) then
    return require("org.table").move_column(1)
  end
  return M.demote()
end

--- M-S-left / M-S-right: promote / demote the subtree, outdent / indent
--- the item with its children, delete / insert a table column.
function M.shift_meta_left()
  local lnum, _, line = cur()
  if in_table(line) then
    return require("org.table").delete_column()
  end
  if is_headline(line) then
    return require("org.structure").promote_subtree()
  end
  if item_line(lnum) then
    return require("org.lists").indent_item(-1, true)
  end
  special_context_error()
end

function M.shift_meta_right()
  local lnum, _, line = cur()
  if in_table(line) then
    return require("org.table").insert_column()
  end
  if is_headline(line) then
    return require("org.structure").demote_subtree()
  end
  if item_line(lnum) then
    return require("org.lists").indent_item(1, true)
  end
  special_context_error()
end

--- M-up (org-metaup): move the subtree, item or table row up; with a
--- Visual selection, the selected subtrees or lines; elsewhere drag the
--- element (paragraph, block, ...) above the previous one.
function M.meta_up()
  if visual_active() then
    return require("org.structure").move_region(-1)
  end
  local lnum, _, line = cur()
  if in_table(line) then
    return require("org.table").move_row(-1)
  end
  if is_headline(line) then
    return require("org.structure").move_subtree_up()
  end
  if item_line(lnum) then
    return require("org.lists").move_item(-1)
  end
  return require("org.element").drag_backward()
end

--- M-down (org-metadown), see meta_up.
function M.meta_down()
  if visual_active() then
    return require("org.structure").move_region(1)
  end
  local lnum, _, line = cur()
  if in_table(line) then
    return require("org.table").move_row(1)
  end
  if is_headline(line) then
    return require("org.structure").move_subtree_down()
  end
  if item_line(lnum) then
    return require("org.lists").move_item(1)
  end
  return require("org.element").drag_forward()
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

--- C-c TAB: in a table shrink or expand the column
--- (org-table-toggle-column-width), else show the children.
function M.ctrl_c_tab()
  local _, _, line = cur()
  if in_table(line) then
    return require("org.table").toggle_column_width(vim.v.count)
  end
  return require("org.fold").show_children()
end

--- C-c *: in a table recalculate the current row (count 4: the table,
--- 16: iterate it; org-table-recalculate), else toggle heading.
function M.ctrl_c_star()
  local _, _, line = cur()
  if in_table(line) then
    return require("org.table").recalculate(vim.v.count)
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

--- C-c RET (org-ctrl-c-ret): hline and move in a table, else insert a
--- heading like M-RET (org-insert-heading), even in a list.
function M.ctrl_c_ret()
  local _, _, line = cur()
  if in_table(line) then
    return require("org.table").hline_and_move(vim.v.count > 0)
  end
  local insert_mode = vim.fn.mode():sub(1, 1) == "i"
  local pos, split = meta_return_point(insert_mode)
  require("org.structure").meta_return_heading({ pos = pos, split = split, arg = prefix_arg() })
  after_insert(insert_mode)
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

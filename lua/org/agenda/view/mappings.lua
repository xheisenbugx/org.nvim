---@mod org.agenda.view.mappings Agenda key mappings and running actions
---
--- Part of org.agenda.view, which loads it.

local config = require("org.config")
local utils = require("org.utils")
local shared = require("org.agenda.view.shared")

local M = require("org.agenda.view")

local item_key = shared.item_key

---------------------------------------------------------------------------
-- Mappings
---------------------------------------------------------------------------

--- The previous agenda action, when the cursor has not moved since it
--- ran (Emacs's `last-command`), and the running one (`this-command`,
--- which an action may change).
M.last_command = nil
M.this_command = nil
M._last_run = nil

--- Run the agenda action `name` like a key press.
---@param name string
function M.run_action(name)
  local fn = M.actions[name]
  if not fn then
    utils.error("Unknown agenda action: " .. tostring(name))
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local buf = vim.api.nvim_get_current_buf()
  local lr = M._last_run
  M.last_command = (lr and lr.buf == buf and lr.lnum == lnum) and lr.name or nil
  M.this_command = name
  M._last_run = nil
  return utils.run(function()
    local ok, err = pcall(fn)
    M.last_command = nil
    M._last_run = {
      name = M.this_command,
      buf = vim.api.nvim_get_current_buf(),
      lnum = vim.api.nvim_win_get_cursor(0)[1],
    }
    if not ok then
      error(err, 0)
    end
  end)
end

--- Actions that act on each entry of a Visual selection
--- (org-agenda-loop-over-headlines-in-active-region; org-agenda-maybe-loop).
local LOOP_ACTIONS = {
  schedule = true,
  deadline = true,
  date_prompt = true,
  todo = true,
  archive = true,
  archive_default = true,
  archive_default_confirm = true,
  archive_sibling = true,
  toggle_archive_tag = true,
  kill = true,
  set_property = true,
  set_effort = true,
}
--- Actions that use the lines of a Visual selection (Emacs: the region).
local REGION_ACTIONS = { diary_entry = true }

--- Leave Visual mode and return the selected lines (first, last) and the
--- cursor line.
local function take_visual()
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  vim.cmd("normal! \27")
  return math.min(a, b), math.max(a, b), b
end

--- Run `name` for a Visual selection: with the region for REGION_ACTIONS,
--- else on each entry of the selection that
--- `agenda.loop_over_headlines_in_active_region` accepts: true (all),
--- "start-level" (the level of the first entry) or an Emacs regexp the
--- agenda line matches (org-agenda-do-in-region).
function M.run_in_region(name)
  local s, e, cur = take_visual()
  if REGION_ACTIONS[name] then
    M._region = { s, e }
    pcall(vim.api.nvim_win_set_cursor, 0, { cur, 0 })
    local ok, err = pcall(M.run_action, name)
    M._region = nil
    if not ok then
      error(err, 0)
    end
    return
  end
  local loop = config.opts.agenda.loop_over_headlines_in_active_region
  local re
  if type(loop) == "string" and loop ~= "start-level" then
    local ok, r = pcall(require("org.agenda.search").compile_emacs_regexp, loop, true)
    re = ok and r or nil
  end
  local lines = vim.api.nvim_buf_get_lines(M.state.buf, 0, -1, false)
  local keys, level = {}, nil
  for l = s, e do
    local item = M.state.line_items[l]
    if item then
      if level == nil then
        level = item.level or false
      end
      local take = loop == true
        or (loop == "start-level" and item.level == level)
        or (re and re:match_str(lines[l] or "") == 0)
      if take then
        keys[#keys + 1] = item_key(item)
      end
    end
  end
  utils.run(function()
    for _, k in ipairs(keys) do
      local lnum
      for l, it in pairs(M.state.line_items) do
        if item_key(it) == k and (not lnum or l < lnum) then
          lnum = l
        end
      end
      if lnum and M.state.win and vim.api.nvim_win_is_valid(M.state.win) then
        vim.api.nvim_set_current_win(M.state.win)
        vim.api.nvim_win_set_cursor(M.state.win, { lnum, 0 })
        M.this_command = name
        M.actions[name]()
      end
    end
  end)
end

--- Screen position and time (ms) of the mouse, for `mouse_1_release`.
local function mouse_pos()
  local pos = vim.fn.getmousepos()
  return { time = vim.uv.hrtime() / 1e6, row = pos.screenrow, col = pos.screencol }
end

--- After a <LeftRelease> with `agenda.mouse_1_follows_link`: a click
--- shorter than `links.mouse_1_follows_link` ms (450 unless that is a
--- number) that didn't move goes to the entry clicked, like <MiddleMouse>.
function M.mouse_1_release()
  local setting = (config.opts.links or {}).mouse_1_follows_link
  local press, release = M._mouse_press, M._mouse_release
  M._mouse_press = nil
  local limit = type(setting) == "number" and setting or 450
  if require("org.mouse").click_follows(limit, press, release or mouse_pos()) then
    M.run_action("goto_mouse")
  end
end

local function setup_mappings(buf)
  local maps = config.opts.mappings.agenda or {}
  local all = {}
  for name, value in pairs(maps) do
    for _, lhs in ipairs(config.lhs_list(value)) do
      all[#all + 1] = { name = name, lhs = lhs }
    end
  end
  if config.opts.agenda.mouse_1_follows_link then
    -- a short click without a drag goes to the entry, a longer one sets
    -- point ([follow-link] mouse-face, mouse-1-click-follows-link)
    local o = { buffer = buf, expr = true, replace_keycodes = true }
    vim.keymap.set("n", "<LeftMouse>", function()
      M._mouse_press = mouse_pos()
      return "<LeftMouse>"
    end, vim.tbl_extend("force", o, { desc = "org agenda: set point (a short click goes to the entry)" }))
    vim.keymap.set("n", "<LeftRelease>", function()
      M._mouse_release = mouse_pos()
      return "<LeftRelease><Cmd>lua require('org.agenda.view').mouse_1_release()<CR>"
    end, vim.tbl_extend("force", o, { desc = "org agenda: go to the entry clicked" }))
  end
  -- global Normal-mode keys and the leaders: an agenda key that starts one
  -- (<Space> with a space leader, \ with the default one) must wait for it
  local longer = {}
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    longer[#longer + 1] = vim.keycode(map.lhs)
  end
  for _, leader in ipairs({ vim.g.mapleader or "\\", vim.g.maplocalleader or "\\" }) do
    longer[#longer + 1] = vim.keycode(leader) .. "x"
  end
  for _, o in ipairs(all) do
    longer[#longer + 1] = vim.keycode(o.lhs)
  end
  for _, m in ipairs(all) do
    local fn = M.actions[m.name]
    if fn then
      -- nowait unless the key is a prefix of another agenda mapping, a
      -- global mapping or a leader
      local prefix_of_other = false
      local kc = vim.keycode(m.lhs)
      for _, ok in ipairs(longer) do
        if #ok > #kc and ok:sub(1, #kc) == kc then
          prefix_of_other = true
          break
        end
      end
      vim.keymap.set("n", m.lhs, function()
        M.run_action(m.name)
      end, { buffer = buf, nowait = not prefix_of_other, desc = "org agenda: " .. m.name:gsub("_", " ") })
      local loop = config.opts.agenda.loop_over_headlines_in_active_region
      -- Visual-mode motions stay motions (their <C-c> forms loop)
      local motion = m.lhs == "t" or m.lhs == "$" or m.lhs == "e" or m.lhs == "a"
      if REGION_ACTIONS[m.name] or (LOOP_ACTIONS[m.name] and loop ~= false and loop ~= nil and not motion) then
        vim.keymap.set("x", m.lhs, function()
          M.run_in_region(m.name)
        end, { buffer = buf, nowait = not prefix_of_other, desc = "org agenda: " .. m.name:gsub("_", " ") })
      end
    end
  end
  -- org-mouse (mouse.org_mouse): the context menu and gestures
  require("org.org_mouse").attach_agenda(buf)
end

shared.setup_mappings = setup_mappings

---@mod org.speed Speed commands (org-use-speed-commands)
---
--- With `use_speed_commands` on, a single letter typed in Insert mode at
--- the very beginning of a headline (before the stars, where Emacs would
--- insert it) runs a command instead, and the cursor stays at the start of
--- the headline it ends on. `?` lists the commands. `speed_commands` adds
--- or changes keys: `{ x = "archive_subtree", q = function() ... end,
--- n = false }` (an action name, a function, or false to drop a key).

local M = {}

local function run(name)
  return function()
    require("org.actions").run(name)
  end
end

--- org-speed-move-safe: run a motion and stay put unless it ends on a
--- headline.
local function move_safe(name)
  return function()
    local pos = vim.api.nvim_win_get_cursor(0)
    require("org.actions").run(name)
    local line = vim.api.nvim_get_current_line()
    if not require("org.parser").headline_level(line) then
      vim.api.nvim_win_set_cursor(0, pos)
      require("org.utils").warn("Boundary reached while executing " .. name)
    end
    local cur = vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_win_set_cursor(0, { cur[1], 0 })
  end
end

local function priority(which)
  return function()
    local file = require("org.files").get_buffer(0)
    local p = file:priorities()
    local value = which == "remove" and " " or p[which]
    require("org.priority").set(nil, value)
  end
end

local function outline_path()
  local hl = require("org.files").get_buffer(0):headline_at(vim.api.nvim_win_get_cursor(0)[1])
  if hl then
    local path = hl:outline_path()
    path[#path + 1] = hl:plain_title()
    vim.api.nvim_echo({ { table.concat(path, "/") } }, false, {})
  end
end

local function appt_warntime()
  local m = require("org.utils").input({ prompt = "Minutes before warning: " })
  if m and m ~= "" then
    local edit = require("org.edit")
    edit.set_property(vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1], "APPT_WARNTIME", m)
  end
end

--- The default speed commands (org-speed-commands), in Emacs order:
--- { key, command, description }.
M.defaults = {
  { "Outline Navigation" },
  { "n", move_safe("next_heading"), "next visible heading" },
  { "p", move_safe("prev_heading"), "previous visible heading" },
  { "f", move_safe("next_sibling"), "next heading at the same level" },
  { "b", move_safe("prev_sibling"), "previous heading at the same level" },
  { "F", run("next_block"), "next block" },
  { "B", run("previous_block"), "previous block" },
  { "u", move_safe("goto_parent"), "parent heading" },
  { "j", run("buffer_goto"), "go to a heading" },
  { "g", run("refile_goto"), "go to a refile target" },
  { "Outline Visibility" },
  { "c", run("cycle"), "cycle visibility" },
  { "C", run("global_cycle"), "cycle global visibility" },
  { " ", outline_path, "display the outline path" },
  { "s", run("narrow_subtree"), "narrow to the subtree" },
  { "k", run("cut_subtree"), "cut the subtree" },
  { "=", run("column_view"), "column view" },
  { "Outline Structure Editing" },
  { "U", run("meta_up"), "move the subtree up" },
  { "D", run("meta_down"), "move the subtree down" },
  { "r", run("meta_right"), "demote the heading" },
  { "l", run("meta_left"), "promote the heading" },
  { "R", run("shift_meta_right"), "demote the subtree" },
  { "L", run("shift_meta_left"), "promote the subtree" },
  { "i", run("insert_heading"), "insert a heading after the subtree" },
  { "^", run("sort"), "sort the children" },
  { "w", run("refile"), "refile" },
  { "a", run("archive_subtree"), "archive the subtree" },
  { "@", run("mark_subtree"), "select the subtree" },
  { "#", run("toggle_comment"), "toggle COMMENT" },
  { "Clock Commands" },
  { "I", run("clock_in"), "clock in" },
  { "O", run("clock_out"), "clock out" },
  { "Meta Data Editing" },
  { "t", run("todo"), "change the TODO state" },
  { ",", run("priority"), "set the priority" },
  { "0", priority("remove"), "remove the priority" },
  { "1", priority("highest"), "highest priority" },
  { "2", priority("default"), "default priority" },
  { "3", priority("lowest"), "lowest priority" },
  { ":", run("set_tags"), "set tags" },
  { "e", run("set_effort"), "set the effort" },
  { "E", run("inc_effort"), "next allowed effort" },
  { "W", appt_warntime, "set APPT_WARNTIME" },
  { "Agenda Views etc" },
  { "v", run("agenda"), "agenda" },
  { "/", run("sparse_tree"), "sparse tree" },
  { "Misc" },
  { "o", run("open_at_point"), "open the link at point" },
  { "?", function()
    M.help()
  end, "this help" },
  { "<", run("agenda_set_restriction_lock"), "lock the agenda to the subtree" },
  { ">", run("agenda_remove_restriction_lock"), "remove the agenda lock" },
}

--- key -> command, with the user's `speed_commands` applied.
function M.commands()
  local out = {}
  for _, e in ipairs(M.defaults) do
    if e[2] then
      out[e[1]] = e[2]
    end
  end
  for key, v in pairs(require("org.config").opts.speed_commands or {}) do
    if v == false then
      out[key] = nil
    elseif type(v) == "string" then
      out[key] = run(v)
    elseif type(v) == "function" then
      out[key] = v
    end
  end
  return out
end

--- Is the cursor where speed commands apply (org--speed-command-p)?
function M.active()
  local use = require("org.config").opts.use_speed_commands
  if not use then
    return false
  end
  if type(use) == "function" then
    return use() and true or false
  end
  local col = vim.api.nvim_win_get_cursor(0)[2]
  return col == 0 and require("org.parser").headline_level(vim.api.nvim_get_current_line()) ~= nil
end

--- The speed command for `char` at the cursor, or nil.
function M.lookup(char)
  if not M.active() then
    return nil
  end
  return M.commands()[char]
end

--- org-speed-command-help.
function M.help()
  local rows = {}
  local cmds = M.commands()
  for _, e in ipairs(M.defaults) do
    if e[2] and cmds[e[1]] then
      rows[#rows + 1] = { e[1] == " " and "SPC" or e[1], e[3] }
    end
  end
  for key, v in pairs(require("org.config").opts.speed_commands or {}) do
    if v then
      rows[#rows + 1] = { key, type(v) == "string" and v or "user command" }
    end
  end
  require("org.ui").help("Speed commands", rows)
end

--- InsertCharPre handler: swallow the character and run its command.
function M.on_insert_char()
  local cmd = M.lookup(vim.v.char)
  if not cmd then
    return
  end
  vim.v.char = ""
  vim.schedule(function()
    local ok, err = pcall(cmd)
    if not ok then
      require("org.utils").error(tostring(err))
    end
  end)
end

--- Install the handler in an org buffer.
function M.attach(bufnr)
  vim.api.nvim_create_autocmd("InsertCharPre", {
    buffer = bufnr,
    group = vim.api.nvim_create_augroup("org.speed." .. bufnr, { clear = true }),
    callback = M.on_insert_char,
  })
end

return M

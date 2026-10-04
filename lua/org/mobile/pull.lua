---@mod org.mobile.pull Pull: applying the inbox
---
--- Flags, applying the inbox entries (org-mobile-apply) and
--- org-mobile-pull.
--- Part of org.mobile, which loads it.

local utils = require("org.utils")
local shared = require("org.mobile.shared")

local M = require("org.mobile")

local blank = shared.blank
local cfg = shared.cfg
local heading_at = shared.heading_at
local inbox_path = shared.inbox_path
local run_hook = shared.run_hook
local subtree_end = shared.subtree_end
local text_of = shared.text_of

--- Flag the entry at target with `note` (the `F()` action).
local function flag(target, note)
  local hl = heading_at(target)
  if not hl then
    error("No heading to flag", 0)
  end
  if not vim.tbl_contains(hl.tags, "FLAGGED") then
    local tags = vim.list_extend(vim.deepcopy(hl.tags), { "FLAGGED" })
    require("org.edit").update_headline(target.bufnr, target.lnum, { tags = tags })
  end
  require("org.edit").set_property(target.bufnr, target.lnum, "THEFLAGGINGNOTE", (note:gsub("\n", "\\n")))
end

--- Write `#+LAST_MOBILE_CHANGE:` at the top of buffer `bufnr`, so that its
--- checksum changes (org-mobile-timestamp-buffer). Returns the line number
--- of a newly inserted line, or nil.
local function timestamp_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local stamp = "#+LAST_MOBILE_CHANGE: " .. os.date("%Y-%m-%d %H:%M:%S")
  for i, l in ipairs(lines) do
    local ind = l:match("^([ \t]*)#%+[Ll][Aa][Ss][Tt]_[Mm][Oo][Bb][Ii][Ll][Ee]_[Cc][Hh][Aa][Nn][Gg][Ee]:")
    if ind then
      vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { ind .. stamp })
      return nil
    end
  end
  local at = (lines[1] and lines[1]:match("%-%*%-.*%-%*%-")) and 1 or 0
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, { stamp })
  return at + 1
end

--- The actions of `F(action:data)` entries (org-mobile-action-alist):
--- `mobile.action_alist` entries (functions `fun(data, old, new, target)`)
--- added to the built-in "edit".
local function actions()
  local out = { edit = M.edit }
  for k, v in pairs(cfg().action_alist or {}) do
    out[k] = v
  end
  return out
end

--- The text after the `** <label>` line inside [s, e), up to the next heading.
local function section_value(lines, s, e, label)
  for i = s, e - 1 do
    if lines[i]:match("^%** " .. label .. "[ \t]*$") then
      local j = i + 1
      while j < e and not lines[j]:match("^%*+%s") do
        j = j + 1
      end
      local last = j - 1
      if j >= #lines + 1 then
        while last > i and not lines[last]:match("%S") do
          last = last - 1
        end
      end
      return text_of(vim.list_slice(lines, i + 1, last)), j
    end
  end
end

--- Apply the change requests in lines [first, last] of buffer `bufnr`
--- (default: the whole buffer) (org-mobile-apply). Applied requests are
--- removed; failed ones keep an error message after their stars.
---@param bufnr? integer
---@param first? integer
---@return { new: integer, edits: integer, flags: integer, errors: integer, flagged_files: string[] }
function M.apply(bufnr, first)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  first = first or 1
  local counts = { new = 0, edits = 0, flags = 0, errors = 0, flagged_files = {} }
  local function get_lines()
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  -- remove the Note IDs
  local lines = get_lines()
  for i = #lines, first, -1 do
    if lines[i]:match("^%*%* Note ID: [%-0-9A-F]+[ \t]*$") then
      vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, {})
    end
  end
  lines = get_lines()
  for i = first, #lines do
    local h = lines[i]:match("^%* (.*)")
    if h and #h >= 2 and h:sub(1, 2):lower() ~= "f(" then
      counts.new = counts.new + 1
    end
  end
  local stamped = {}
  local acts = actions()
  local pos = first
  while true do
    lines = get_lines()
    local bos, action, data, link
    for i = pos, #lines do
      local inner, rest = lines[i]:match("^%*+[ \t]+F%(([^()]*)%)[ \t]+%[%[(.*)$")
      if inner then
        local l = rest:match("^([^%]]+)")
        if l and (l:match("^id:") or l:match("^olp:")) then
          action, data = inner:match("^([^:]*):(.*)$")
          action = action or inner
          bos, link = i, l
          break
        end
      end
    end
    if not bos then
      break
    end
    local eos = subtree_end(lines, bos)
    -- an error message after the stars ("BAD FLAG" at the line start, as Emacs)
    local function mark(msg, col)
      col = col or 2
      local l = vim.api.nvim_buf_get_lines(bufnr, bos - 1, bos, false)[1]
      vim.api.nvim_buf_set_lines(bufnr, bos - 1, bos, false, { l:sub(1, col) .. msg .. l:sub(col + 1) })
      counts.errors = counts.errors + 1
      pos = bos + 1
    end
    local cmd
    if action == "" then
      local note = text_of(vim.list_slice(lines, bos + 1, eos - 1))
      cmd = function(_, _, _, target)
        counts.flags = counts.flags + 1
        flag(target, note)
      end
    else
      counts.edits = counts.edits + 1
      cmd = acts[action]
    end
    local ok, target = pcall(M.locate_entry, link)
    if not ok then
      target = tostring(target)
    end
    if type(target) == "table" and not stamped[target.bufnr] then
      stamped[target.bufnr] = true
      local at = timestamp_buffer(target.bufnr)
      if at and at <= target.lnum then
        target.lnum = target.lnum + 1
      end
    end
    if type(target) ~= "table" then
      mark(type(target) == "string" and (target .. " ") or "BAD REFERENCE ")
    elseif not cmd then
      mark("BAD FLAG ", 0)
    else
      lines = get_lines()
      local old, after = section_value(lines, bos, eos, "Old value")
      local new = section_value(lines, after or bos, eos, "New value")
      if blank(old) then
        old = nil
      end
      if blank(new) then
        new = nil
      end
      if data ~= "body" then
        old = old and vim.trim(old)
        new = new and vim.trim(new)
      end
      local cok, cerr = pcall(cmd, data, old, new, target)
      if not cok then
        mark(type(cerr) == "string" and (cerr .. " ") or "EXECUTION FAILED ")
      else
        if not vim.tbl_contains({ "delete", "archive", "archive-sibling", "addheading" }, data) then
          local hl = heading_at(target)
          if hl and vim.tbl_contains(hl.tags, "FLAGGED") then
            local name = vim.api.nvim_buf_get_name(target.bufnr)
            if not vim.tbl_contains(counts.flagged_files, name) then
              counts.flagged_files[#counts.flagged_files + 1] = name
            end
          end
        end
        -- applied: remove the request from the inbox
        lines = get_lines()
        vim.api.nvim_buf_set_lines(bufnr, bos - 1, subtree_end(lines, bos) - 1, false, {})
        pos = bos
      end
    end
  end
  if vim.api.nvim_buf_get_name(bufnr) ~= "" then
    utils.save_buffer_or_warn(bufnr)
  end
  utils.notify(
    string.format("%d new, %d edits, %d flags, %d errors", counts.new, counts.edits, counts.flags, counts.errors)
  )
  return counts
end

--- Pull the captured entries and edits from the mobile application and
--- apply them (org-mobile-pull). Shows the flagged entries of the changed
--- files in an agenda. Returns the counts of `apply`, or nil.
function M.pull()
  local ok, res = pcall(function()
    M.check_setup()
    run_hook("pre_pull_hook", "OrgMobilePrePull")
    local bufnr, start = M.move_capture()
    if not bufnr then
      utils.notify("No new items")
      return nil
    end
    run_hook("before_process_capture_hook", "OrgMobileBeforeProcessCapture", { bufnr = bufnr, line = start })
    local counts = M.apply(bufnr, start)
    run_hook("post_pull_hook", "OrgMobilePostPull")
    if #counts.flagged_files > 0 and cfg().show_flagged ~= false then
      M.flagged_agenda(counts.flagged_files)
    end
    return counts
  end)
  if not ok then
    utils.error(tostring(res))
    return nil
  end
  return res
end

--- Apply the change requests of the current buffer (org-mobile-apply).
function M.apply_command()
  return M.apply(0, 1)
end

--- Open the inbox file (mobile.inbox_for_pull).
function M.goto_inbox()
  local p = inbox_path()
  if not p then
    utils.warn("mobile.inbox_for_pull is not set")
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(p))
end

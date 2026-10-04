---@mod org.mobile.flagged Flagged entries
---
--- The flagged entries agenda, removing a flag and showing its note.
--- Part of org.mobile, which loads it.

local utils = require("org.utils")
local shared = require("org.mobile.shared")

local M = require("org.mobile")

local heading_at = shared.heading_at

---------------------------------------------------------------------------
-- Flagged entries in the agenda
---------------------------------------------------------------------------

local note_group = vim.api.nvim_create_augroup("org.mobile.note", { clear = true })

--- The FLAGGED entries (the agenda dispatcher's `?`), optionally only in
--- `restrict_files`; moving to an entry echoes its flagging note.
---@param restrict_files? string[]
function M.flagged_agenda(restrict_files)
  local block = { type = "tags", match = "+FLAGGED" }
  if restrict_files and #restrict_files > 0 then
    block.files = restrict_files
  end
  require("org.agenda").open(block)
  local view = require("org.agenda.view")
  local buf = view.state.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  vim.api.nvim_clear_autocmds({ group = note_group, buffer = buf })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = note_group,
    buffer = buf,
    callback = function()
      local it = view.item_at_cursor()
      local note = it and it.headline and it.headline.properties.THEFLAGGINGNOTE
      if note then
        vim.api.nvim_echo(
          { { "FLAGGING-NOTE ([?] for more info): " }, { (note:gsub("\\n", "//")), "WarningMsg" } },
          false,
          {}
        )
      end
    end,
  })
end

M._last_note = nil

--- Remove the FLAGGED tag and the flagging note of the entry at target
--- (org-agenda-remove-flag).
function M.remove_flag(target)
  local hl = heading_at(target)
  if not hl then
    return
  end
  if vim.tbl_contains(hl.tags, "FLAGGED") then
    local tags = vim.tbl_filter(function(t)
      return t ~= "FLAGGED"
    end, hl.tags)
    require("org.edit").update_headline(target.bufnr, target.lnum, { tags = tags })
  end
  require("org.edit").set_property(target.bufnr, target.lnum, "THEFLAGGINGNOTE", nil)
  utils.notify("Entry unflagged")
end

--- The agenda `?` key (org-agenda-show-the-flagging-note): show the
--- flagging note of the entry in another window and copy it to the
--- unnamed register; pressed again without moving, offer to remove the
--- FLAGGED tag and the note.
function M.show_flagging_note()
  local view = require("org.agenda.view")
  local item = view.item_at_cursor()
  if not (item and item.headline) then
    utils.warn("No linked entry at point")
    return
  end
  local agenda_win = vim.api.nvim_get_current_win()
  -- "pressed again": same agenda line and entry as the last `?`
  local key = table.concat({
    vim.api.nvim_get_current_buf(),
    vim.api.nvim_win_get_cursor(0)[1],
    item.filename or tostring(item.bufnr),
    item.headline.line,
  }, ":")
  local target = view.resolve_target(item)
  if not target then
    return
  end
  if M._last_note == key and utils.confirm("Unflag and remove any flagging note?") then
    M._last_note = nil
    M.remove_flag(target)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match("%*Flagging Note%*$") then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    if vim.api.nvim_win_is_valid(agenda_win) then
      vim.api.nvim_set_current_win(agenda_win)
    end
    view.redo()
    return
  end
  local hl = heading_at(target)
  local note = hl and hl.properties.THEFLAGGINGNOTE
  if not note then
    M._last_note = nil
    utils.warn("No flagging note")
    return
  end
  vim.fn.setreg('"', note)
  local text = vim.split((note:gsub("\\n", "\n")), "\n", { plain = true })
  local buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match("%*Flagging Note%*$") then
      buf = b
    end
  end
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, buf, "*Flagging Note*")
    vim.bo[buf].bufhidden = "hide"
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  if #vim.fn.win_findbuf(buf) == 0 then
    vim.cmd("rightbelow split")
    vim.api.nvim_win_set_buf(0, buf)
  end
  if vim.api.nvim_win_is_valid(agenda_win) then
    vim.api.nvim_set_current_win(agenda_win)
  end
  M._last_note = key
  utils.notify("Flagging note pushed to kill ring.  Press `?' again to remove tag and note")
end

return M

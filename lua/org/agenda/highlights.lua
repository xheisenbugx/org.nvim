---@mod org.agenda.highlights Agenda highlight groups

local M = {}

local links = {
  OrgAgendaHeader = "Title",
  OrgAgendaBlockSeparator = "Comment",
  OrgAgendaDate = "Function",
  OrgAgendaDateWeekend = "Special",
  OrgAgendaCategory = "Normal",
  OrgAgendaScheduled = "String",
  OrgAgendaScheduledPast = "WarningMsg",
  OrgAgendaDeadline = "ErrorMsg",
  OrgAgendaDeadlineUpcoming = "WarningMsg",
  OrgAgendaDeadlineDistant = "Normal",
  OrgAgendaTimestamp = "Normal",
  OrgAgendaDiary = "Normal",
  OrgAgendaDone = "Comment",
  OrgAgendaTimeGrid = "Comment",
  OrgAgendaCurrentTime = "Special",
  OrgAgendaTodoKeyword = "OrgTodo",
  OrgAgendaDoneKeyword = "OrgDone",
  OrgAgendaPriority = "OrgPriority",
  OrgAgendaTag = "OrgTags",
  OrgAgendaFilter = "WarningMsg",
  OrgAgendaMark = "DiagnosticInfo",
  OrgAgendaClocking = "Visual",
  -- the new date shown after a date change (secondary-selection)
  OrgAgendaNewTime = "PmenuSel",
  OrgAgendaLog = "Comment",
  OrgAgendaHint = "Comment",
  OrgAgendaEntryText = "Comment",
  OrgAgendaDimmed = "Comment",
  OrgAgendaColumn = "Pmenu",
  OrgAgendaColumnDateline = "PmenuSel",
  OrgAgendaColumnTitle = "TabLineSel",
  OrgSparseMatch = "Search",
}

local function exists(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name })
  return ok and hl and next(hl) ~= nil
end

local fallback = {
  OrgTodo = "DiagnosticError",
  OrgDone = "DiagnosticOk",
  OrgPriority = "Constant",
  OrgTags = "Comment",
}

local function get_hl(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  hl = ok and hl or {}
  -- a change of 'background' drops the flag
  hl.default = nil
  return hl
end

-- what the groups org computes looked like after it last set them
local owned = {}

--- Set a group whose colours org computes (from other groups or the
--- background) as a default group. A group org set before is replaced,
--- since the colours it came from may have changed; a group defined by the
--- user or the colorscheme is left alone.
local function set_computed(name, spec)
  local cur = get_hl(name)
  if next(cur) ~= nil then
    if not (owned[name] and vim.deep_equal(cur, owned[name])) then
      owned[name] = nil
      return
    end
    vim.api.nvim_set_hl(0, name, {})
  end
  spec.default = true
  vim.api.nvim_set_hl(0, name, spec)
  owned[name] = get_hl(name)
end

function M.define()
  -- the Org* groups the agenda links to
  require("org.highlights").ensure()
  for group, target in pairs(links) do
    if fallback[target] and not exists(target) then
      target = fallback[target]
    end
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
  -- today: bold + underline version of OrgAgendaDate
  local ok, base = pcall(vim.api.nvim_get_hl, 0, { name = "Function", link = false })
  local fg = ok and base and base.fg or nil
  set_computed("OrgAgendaDateToday", { fg = fg, bold = true, underline = true })
  -- highest / lowest priority cookies (org-agenda-fontify-priorities)
  local okp, prio = pcall(vim.api.nvim_get_hl, 0, { name = "OrgAgendaPriority", link = false })
  local pfg = okp and prio and prio.fg or nil
  set_computed("OrgAgendaPriorityHighest", { fg = pfg, bold = true })
  set_computed("OrgAgendaPriorityLowest", { fg = pfg, italic = true })
  -- habit consistency graph (Emacs org-habit faces)
  local light = vim.o.background == "light"
  local habit = {
    OrgAgendaHabitClear = light and "#8270f9" or "#0e3a8a",
    OrgAgendaHabitReady = light and "#4df946" or "#1a6b18",
    OrgAgendaHabitAlert = light and "#f5f946" or "#8a8a0e",
    OrgAgendaHabitOverdue = light and "#f9372d" or "#8a1a14",
    OrgAgendaHabitClearFuture = light and "#d6e4fc" or "#191970",
    OrgAgendaHabitReadyFuture = light and "#acfca9" or "#006400",
    OrgAgendaHabitAlertFuture = light and "#fafca9" or "#b8860b",
    OrgAgendaHabitOverdueFuture = light and "#fc9590" or "#8b0000",
  }
  for group, bg in pairs(habit) do
    set_computed(group, { bg = bg, fg = light and "#000000" or "#ffffff" })
  end
end

local did = false
function M.setup()
  if did then
    return
  end
  did = true
  M.define()
  local augroup = vim.api.nvim_create_augroup("org.agenda.highlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = augroup, callback = M.define })
  -- Neovim's built-in colours change with 'background' without a
  -- ColorScheme event: compute the derived groups again
  vim.api.nvim_create_autocmd("OptionSet", { group = augroup, pattern = "background", callback = M.define })
end

return M

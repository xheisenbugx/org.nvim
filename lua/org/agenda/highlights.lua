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
  OrgAgendaTimestamp = "Normal",
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
  OrgAgendaLog = "Comment",
  OrgAgendaHint = "Comment",
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

function M.define()
  for group, target in pairs(links) do
    if fallback[target] and not exists(target) then
      target = fallback[target]
    end
    vim.api.nvim_set_hl(0, group, { link = target, default = true })
  end
  -- today: bold + underline version of OrgAgendaDate
  local ok, base = pcall(vim.api.nvim_get_hl, 0, { name = "Function", link = false })
  local fg = ok and base and base.fg or nil
  vim.api.nvim_set_hl(0, "OrgAgendaDateToday", { fg = fg, bold = true, underline = true, default = true })
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
    vim.api.nvim_set_hl(0, group, { bg = bg, fg = light and "#000000" or "#ffffff", default = true })
  end
end

local did = false
function M.setup()
  if did then
    return
  end
  did = true
  M.define()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("org.agenda.highlights", { clear = true }),
    callback = M.define,
  })
end

return M

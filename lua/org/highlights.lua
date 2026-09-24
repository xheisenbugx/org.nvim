---@mod org.highlights Highlight groups
---
--- All groups are defined with `default = true`, so colorschemes and user
--- config (`vim.api.nvim_set_hl`) can override them. Headline levels link
--- to the colorscheme's markdown heading colours when available.
---
--- Groups (syntax name -> highlight group):
---   orgHeadlineLevel1..8 -> OrgHeadlineLevel1..8     orgTodo -> OrgTodo
---   orgDone -> OrgDone   orgPriority{A,B,C} -> OrgPriority{A,B,C}   orgTags -> OrgTags
---   orgTimestamp -> OrgTimestamp   orgTimestampInactive -> OrgTimestampInactive
---   ... see M.links below for the full list.

local M = {}

local function hl_exists(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, create = false })
  return ok and hl and next(hl) ~= nil
end

local function first_existing(names, fallback)
  for _, n in ipairs(names) do
    if hl_exists(n) then
      return n
    end
  end
  return fallback
end

--- Static links: syntax group -> target group.
M.links = {
  orgTodo = "OrgTodo",
  orgDone = "OrgDone",
  orgHeadlineDone = "OrgHeadlineDone",
  orgHeadlineComment = "OrgHeadlineComment",
  orgPriority = "OrgPriority",
  orgPriorityA = "OrgPriorityA",
  orgPriorityB = "OrgPriorityB",
  orgPriorityC = "OrgPriorityC",
  orgTags = "OrgTags",
  orgTimestamp = "OrgTimestamp",
  orgTimestampInactive = "OrgTimestampInactive",
  orgPlanning = "OrgPlanning",
  orgClock = "OrgPlanning",
  orgClockDuration = "OrgClockDuration",
  orgDrawer = "OrgDrawer",
  orgPropertyKey = "OrgPropertyKey",
  orgPropertyValue = "OrgPropertyValue",
  orgKeyword = "OrgKeyword",
  orgKeywordValue = "OrgKeywordValue",
  orgTitle = "OrgTitle",
  orgTitleKeyword = "OrgKeyword",
  orgComment = "OrgComment",
  orgBlock = "OrgBlock",
  orgQuoteBlock = "OrgQuoteBlock",
  orgDynamicBlock = "OrgBlock",
  orgBlockDelimiter = "OrgBlockDelimiter",
  orgBold = "OrgBold",
  orgBoldDelimiter = "OrgBold",
  orgItalic = "OrgItalic",
  orgItalicDelimiter = "OrgItalic",
  orgUnderline = "OrgUnderline",
  orgUnderlineDelimiter = "OrgUnderline",
  orgStrikethrough = "OrgStrikethrough",
  orgStrikethroughDelimiter = "OrgStrikethrough",
  orgVerbatim = "OrgVerbatim",
  orgVerbatimDelimiter = "OrgVerbatim",
  orgCode = "OrgCode",
  orgCodeDelimiter = "OrgCode",
  orgLink = "OrgLink",
  orgLinkPlain = "OrgLink",
  orgLinkBracket = "OrgLink",
  orgLinkTargetHidden = "OrgLink",
  orgListBullet = "OrgListBullet",
  orgListTerm = "OrgListTerm",
  orgCheckbox = "OrgCheckbox",
  orgCheckboxChecked = "OrgCheckboxChecked",
  orgCheckboxPartial = "OrgCheckboxPartial",
  orgStatistic = "OrgStatistic",
  orgTable = "OrgTable",
  orgTableSeparator = "OrgTableSeparator",
  orgTableHline = "OrgTableSeparator",
  orgTableFormula = "OrgTableFormula",
  orgFootnote = "OrgFootnote",
  orgTarget = "OrgTarget",
  orgLatex = "OrgLatex",
  orgLineBreak = "OrgLatex",
  orgHorizontalRule = "OrgHorizontalRule",
  orgFixedWidth = "OrgVerbatim",
  orgMacro = "OrgMacro",
}

--- Default definitions of the Org* groups.
local function defaults()
  local d = {
    OrgTodo = { link = first_existing({ "@comment.error", "DiagnosticError" }, "ErrorMsg") },
    OrgDone = { link = first_existing({ "@comment.note", "DiagnosticOk" }, "DiffAdd") },
    OrgHeadlineDone = { link = "Comment" },
    OrgHeadlineComment = { link = "Comment" },
    OrgPriority = { link = "Special" },
    OrgPriorityA = { link = "DiagnosticError" },
    OrgPriorityB = { link = "DiagnosticWarn" },
    OrgPriorityC = { link = "DiagnosticInfo" },
    OrgTags = { link = first_existing({ "@tag.attribute", "@property" }, "Type") },
    OrgTimestamp = { link = first_existing({ "@markup.link.url" }, "Underlined") },
    OrgTimestampInactive = { link = "Comment" },
    OrgPlanning = { link = first_existing({ "@keyword" }, "Keyword") },
    OrgClockDuration = { link = "Number" },
    OrgClockSum = { link = "Comment" },
    OrgDrawer = { link = "Comment" },
    OrgPropertyKey = { link = first_existing({ "@property" }, "Identifier") },
    OrgPropertyValue = { link = "String" },
    OrgKeyword = { link = "PreProc" },
    OrgKeywordValue = { link = "String" },
    OrgTitle = { link = "Title" },
    OrgComment = { link = "Comment" },
    OrgBlock = { link = first_existing({ "@markup.raw.block" }, "String") },
    OrgQuoteBlock = { link = first_existing({ "@markup.quote" }, "Normal") },
    OrgBlockDelimiter = { link = "Comment" },
    OrgBold = { bold = true },
    OrgItalic = { italic = true },
    OrgUnderline = { underline = true },
    OrgStrikethrough = { strikethrough = true },
    OrgVerbatim = { link = first_existing({ "@markup.raw" }, "String") },
    OrgCode = { link = first_existing({ "@markup.raw" }, "String") },
    OrgLink = { link = first_existing({ "@markup.link" }, "Underlined") },
    OrgListBullet = { link = first_existing({ "@markup.list" }, "Special") },
    OrgListTerm = { bold = true },
    OrgCheckbox = { link = first_existing({ "@markup.list.unchecked" }, "Special") },
    OrgCheckboxChecked = { link = first_existing({ "@markup.list.checked" }, "DiagnosticOk") },
    OrgCheckboxPartial = { link = "DiagnosticWarn" },
    OrgStatistic = { link = "Special" },
    OrgTable = { link = first_existing({ "@markup.raw" }, "Normal") },
    OrgTableSeparator = { link = "Delimiter" },
    OrgTableFormula = { link = "Comment" },
    OrgFootnote = { link = "Underlined" },
    OrgTarget = { link = "Underlined" },
    OrgLatex = { link = first_existing({ "@markup.math" }, "Statement") },
    OrgHorizontalRule = { link = "Comment" },
    OrgMacro = { link = "PreProc" },
    OrgBullet = { link = "OrgHeadlineLevel1" },
    OrgHiddenStars = { link = "Conceal" },
  }
  -- headline levels: prefer the colorscheme's markdown heading colours
  local fallbacks = { "Title", "Constant", "Identifier", "Statement", "PreProc", "Type", "Special", "Function" }
  for i = 1, 8 do
    local target = first_existing({
      "@markup.heading." .. i .. ".markdown",
      "@markup.heading." .. i,
      "markdownH" .. i,
    }, fallbacks[i])
    d["OrgHeadlineLevel" .. i] = { link = target }
  end
  return d
end

local function hl_from_face(face)
  if type(face) == "string" then
    -- "GroupName" or Emacs-style ":foreground red :weight bold"
    if not face:find(":") then
      return { link = face }
    end
    local out = {}
    local fg = face:match(":foreground%s+(%S+)")
    local bg = face:match(":background%s+(%S+)")
    if fg then
      out.fg = fg
    end
    if bg then
      out.bg = bg
    end
    if face:find(":weight%s+bold") then
      out.bold = true
    end
    if face:find(":slant%s+italic") then
      out.italic = true
    end
    if face:find(":underline%s+t") then
      out.underline = true
    end
    return out
  end
  return face
end

--- Define highlight groups for `ui.todo_keyword_faces`.
function M.apply_todo_faces()
  local faces = require("org.config").opts.ui.todo_keyword_faces or {}
  for name, face in pairs(faces) do
    local group = "orgTodoKw_" .. name:gsub("[^%w_]", "_")
    local def = hl_from_face(face)
    vim.api.nvim_set_hl(0, group, def)
  end
end

function M.define()
  for name, def in pairs(defaults()) do
    def.default = true
    vim.api.nvim_set_hl(0, name, def)
  end
  -- highlight group names are case-insensitive: orgBold IS OrgBold
  for from, to in pairs(M.links) do
    if from:lower() ~= to:lower() then
      vim.api.nvim_set_hl(0, from, { link = to, default = true })
    end
  end
  M.apply_todo_faces()
end

function M.setup()
  M.define()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("org.highlights", { clear = true }),
    callback = function()
      M.define()
    end,
  })
end

return M

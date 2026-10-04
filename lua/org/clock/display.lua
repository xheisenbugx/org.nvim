---@mod org.clock.display Clock sums shown on headlines (org-clock-display)
---
--- The overlays with each subtree's clocked time, drawn again on closed
--- folds, and the buffer-local setup that clears them.
---
--- Part of org.clock, which loads it.

local date = require("org.date")
local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.clock.shared")

local M = require("org.clock")

local clock_cfg = shared.clock_cfg
local clock_sum = shared.clock_sum
local display_ns = shared.display_ns

---------------------------------------------------------------------------
-- Clock sums on headlines
---------------------------------------------------------------------------

-- The sums are drawn over the text from the end of the title, which also
-- covers the inline ellipsis org.fold draws after a closed fold's heading.
-- On a closed fold the sum is drawn again with the ellipsis after it, as
-- in Emacs, where the overlay ends at the end of the line and the fold's
-- ellipsis follows. Folds are per window: done when each window redraws.
local folded_ns = vim.api.nvim_create_namespace("org.clock.display.folded")
local folded_rows = {} -- winid -> { [row] = extmark }
vim.api.nvim_set_decoration_provider(folded_ns, {
  on_win = function(_, win, buf, top, bot)
    folded_rows[win] = nil
    if vim.wo[win].foldtext ~= "" or not vim.wo[win].foldenable then
      return false
    end
    local marks = vim.api.nvim_buf_get_extmarks(buf, display_ns, { top, 0 }, { bot, -1 }, { details = true })
    local rows
    for _, m in ipairs(marks) do
      if m[4].virt_text then
        local lnum = m[2] + 1
        local closed = vim.api.nvim_win_call(win, function()
          return vim.fn.foldclosed(lnum)
        end)
        if closed == lnum then
          rows = rows or {}
          rows[m[2]] = m
        end
      end
    end
    if not rows then
      return false
    end
    folded_rows[win] = rows
  end,
  on_line = function(_, win, buf, row)
    local m = folded_rows[win] and folded_rows[win][row]
    if not m then
      return
    end
    local chunks = vim.deepcopy(m[4].virt_text)
    chunks[#chunks + 1] = { require("org.config").opts.ellipsis or "...", "Comment" }
    pcall(vim.api.nvim_buf_set_extmark, buf, folded_ns, row, m[3], {
      virt_text = chunks,
      virt_text_pos = "overlay",
      hl_mode = "combine",
      ephemeral = true,
    })
  end,
})

--- Remove the clock sums shown by `toggle_display` (org-clock-remove-overlays).
function M.remove_overlays(bufnr)
  bufnr = (type(bufnr) ~= "number" or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local had = #vim.api.nvim_buf_get_extmarks(bufnr, display_ns, 0, -1, { limit = 1 }) > 0
  vim.api.nvim_buf_clear_namespace(bufnr, display_ns, 0, -1)
  return had
end

--- Show the time clocked in each subtree next to its headline
--- (org-clock-display), for `clock.display_default_range` (this year by
--- default). With a count: 4 = today, 16 = ask for a range, 64 = only
--- report the total. Called again while the sums are shown, it hides them.
---@param bufnr? integer
---@param range? string a :block value (today, thisweek, untilnow, ...)
function M.toggle_display(bufnr, range)
  bufnr = (type(bufnr) ~= "number" or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local count = range == nil and vim.v.count or 0
  if M.remove_overlays(bufnr) and count == 0 and range == nil then
    return true
  end
  local label = ""
  if count >= 64 then
    range = "untilnow"
  elseif count >= 16 then
    range = utils.input_complete(
      "Range: ",
      { "today", "yesterday", "thisweek", "lastweek", "thismonth", "lastmonth", "thisyear", "lastyear", "untilnow" }
    )
    if not range or range == "" then
      return nil
    end
    label = " (custom)"
  elseif count > 0 then
    range = "today"
    label = " for today"
  end
  range = range or clock_cfg().display_default_range or "thisyear"
  local from, to = M.special_range(range)
  local file = files.get_buffer(bufnr)
  local times, total = clock_sum(file.children, from, to)
  if count < 64 then
    local o = require("org.ui").conceal_opts(bufnr)
    for _, hl in ipairs(file.headlines) do
      local m = times[hl]
      if m and m > 0 then
        -- org-clock-put-overlay: the overlay replaces the line from the end
        -- of the title (the tags are hidden), its dots fill up to column 60
        -- measured on the displayed title (org-string-width), then the
        -- time. It is drawn over the text ("overlay"): Neovim draws no eol
        -- text on a closed fold's line (Emacs shows the sums in overview),
        -- and inline text would make the line wrap sooner, as Neovim wraps
        -- a line at its width with the concealed text.
        local line = file.lines[hl.line]
        local title = line:match("^(.-)%s+:[%w_@#%%:\128-\255]+:%s*$") or line:gsub("%s+$", "")
        local dots = math.max(60 - require("org.ui").visible_width(title, o), 0)
        if #line > #title then
          vim.api.nvim_buf_set_extmark(bufnr, display_ns, hl.line - 1, #title, { end_col = #line, conceal = "" })
        end
        vim.api.nvim_buf_set_extmark(bufnr, display_ns, hl.line - 1, #title, {
          virt_text = {
            { string.rep("·", dots), "OrgClockOverlayDots" },
            { string.format(" %9s ", date.duration_to_string(m)), "OrgClockOverlay" },
          },
          virt_text_pos = "overlay",
          hl_mode = "combine",
        })
      end
    end
  end
  utils.notify(
    string.format(
      "Total file time%s: %s (%d hours and %d minutes)",
      label,
      date.duration_to_string(total),
      math.floor(total / 60),
      total % 60
    )
  )
  return true
end

--- Buffer-local setup: clear clock display on edits.
function M.attach(bufnr)
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertEnter" }, {
    buffer = bufnr,
    group = vim.api.nvim_create_augroup("org.clock.buf." .. bufnr, { clear = true }),
    callback = function()
      -- org-remove-highlights-with-change
      if require("org.config").opts.remove_highlights_with_change ~= false then
        vim.api.nvim_buf_clear_namespace(bufnr, display_ns, 0, -1)
      end
    end,
  })
  vim.api.nvim_set_hl(0, "OrgClockSum", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "OrgClockOverlay", { link = "OrgClockSum", default = true })
  vim.api.nvim_set_hl(0, "OrgClockOverlayDots", { link = "NonText", default = true })
end

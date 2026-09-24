---@mod org.agenda.sparse Sparse trees (C-c /)
---
--- Folds the buffer so only matches (and their ancestors) are visible,
--- highlights them and fills the location list (`:lnext` / `:lprev`).

local date = require("org.date")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.sparse")

function M.clear(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

--- Show matches. `matches` = list of { lnum, col?, end_col? } (1-based col).
---@param title string
function M.show(matches, title)
  require("org.agenda.highlights").setup()
  local bufnr = vim.api.nvim_get_current_buf()
  M.clear(bufnr)
  table.sort(matches, function(a, b)
    return a.lnum < b.lnum
  end)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local loc = {}
  local view = vim.fn.winsaveview()
  pcall(vim.cmd, "normal! zM")
  for _, m in ipairs(matches) do
    local line = lines[m.lnum] or ""
    if m.col then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, m.lnum - 1, m.col - 1, {
        end_col = math.min(m.end_col or #line, #line),
        hl_group = "OrgSparseMatch",
        priority = 150,
      })
    else
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, m.lnum - 1, 0, {
        end_col = #line,
        hl_group = "OrgSparseMatch",
        priority = 150,
      })
    end
    vim.api.nvim_win_set_cursor(0, { m.lnum, 0 })
    pcall(vim.cmd, "normal! zv")
    loc[#loc + 1] = { bufnr = bufnr, lnum = m.lnum, col = m.col or 1, text = line }
  end
  vim.fn.setloclist(0, {}, "r", { title = "Sparse tree: " .. title, items = loc })
  if #matches > 0 then
    vim.api.nvim_win_set_cursor(0, { matches[1].lnum, (matches[1].col or 1) - 1 })
  else
    vim.fn.winrestview(view)
  end
  utils.notify(string.format("%d match%s for %s", #matches, #matches == 1 and "" or "es", title))
  -- clear highlights on the next change
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = bufnr,
    once = true,
    callback = function()
      M.clear(bufnr)
    end,
  })
end

--- Headline matches for a predicate.
function M.headlines(pred, title)
  local file = files.get_buffer(0)
  local out = {}
  for _, hl in ipairs(file.headlines) do
    if pred(hl) then
      out[#out + 1] = { lnum = hl.line }
    end
  end
  M.show(out, title)
  return out
end

--- Regexp (Vim regex) occurrences.
function M.regexp(pattern)
  local ok, re = pcall(vim.regex, pattern)
  if not ok then
    utils.error("Invalid regexp: " .. pattern)
    return
  end
  local out = {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local s, e = re:match_str(line)
    if s then
      out[#out + 1] = { lnum = i, col = s + 1, end_col = e }
    end
  end
  M.show(out, "/" .. pattern .. "/")
  return out
end

local function entry_dates(hl)
  local out = {}
  for _, k in ipairs({ "scheduled", "deadline" }) do
    if hl.planning[k] then
      out[#out + 1] = hl.planning[k]
    end
  end
  for _, t in ipairs(hl.timestamps) do
    out[#out + 1] = t.date
  end
  return out
end

--- Dates relative to `d` (before / after / between).
function M.dates(kind, d1, d2)
  return M.headlines(function(hl)
    for _, d in ipairs(entry_dates(hl)) do
      local n = d:days()
      if kind == "before" and n < d1:days() then
        return true
      elseif kind == "after" and n > d1:days() then
        return true
      elseif kind == "between" and n >= d1:days() and n <= d2:days() then
        return true
      end
    end
    return false
  end, kind .. " " .. d1:to_date_string() .. (d2 and (" and " .. d2:to_date_string()) or ""))
end

--- Deadlines that are past due or within their warning period.
function M.deadlines()
  local today = date.today_days()
  local warn_default = require("org.config").opts.deadline_warning_days
  return M.headlines(function(hl)
    local dl = hl.planning.deadline
    if not dl or hl:is_done() then
      return false
    end
    return dl:days() - today <= date.warning_days(dl, warn_default)
  end, "deadlines")
end

local function pick_date(prompt)
  local ok, cal = pcall(require, "org.calendar")
  if ok and cal.pick then
    return cal.pick({ default = date.today(), prompt = prompt })
  end
  local input = utils.input({ prompt = prompt .. ": " })
  return input and date.read_date(input) or nil
end

function M.prompt()
  if not utils.ensure_org() then
    return
  end
  local choice = require("org.ui").menu({
    title = "Sparse tree",
    items = {
      { key = "/", label = "Regexp", value = "/" },
      { key = "t", label = "TODO entries (not done)", value = "t" },
      { key = "T", label = "Specific TODO keyword(s)", value = "T" },
      { key = "m", label = "Tags / property match", value = "m" },
      { key = "M", label = "Match, only TODO entries", value = "M" },
      { key = "p", label = "Property value", value = "p" },
      { key = "d", label = "Deadlines (due or in warning period)", value = "d" },
      { key = "b", label = "Dates before …", value = "b" },
      { key = "a", label = "Dates after …", value = "a" },
      { key = "D", label = "Dates between …", value = "D" },
      { key = "c", label = "Clear highlights", value = "c" },
    },
  })
  if not choice then
    return
  end
  local search = require("org.agenda.search")
  if choice == "/" then
    local re = utils.input({ prompt = "Regexp: " })
    if re and re ~= "" then
      M.regexp(re)
    end
  elseif choice == "t" then
    M.headlines(function(hl)
      return hl:is_todo()
    end, "TODO entries")
  elseif choice == "T" then
    local file = files.get_buffer(0)
    local kw = utils.input_complete("Keyword(s) (KW|KW2): ", file.settings.todo:names())
    if not kw or kw == "" then
      return
    end
    local set = {}
    for _, k in ipairs(vim.split(kw, "[|%s]+", { trimempty = true })) do
      set[k] = true
    end
    M.headlines(function(hl)
      return hl.todo ~= nil and set[hl.todo] == true
    end, kw)
  elseif choice == "m" or choice == "M" or choice == "p" then
    local prompt = choice == "p" and "Property (PROP=value): " or "Match: "
    local input = utils.input({ prompt = prompt })
    if not input or input == "" then
      return
    end
    if choice == "p" then
      local k, v = input:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
      if not k then
        utils.error("Expected PROP=value")
        return
      end
      if not v:match('^".*"$') then
        v = '"' .. v .. '"'
      end
      input = k .. "=" .. v
    end
    local pred, err = search.try_compile(input)
    if not pred then
      utils.error("Invalid match: " .. tostring(err))
      return
    end
    M.headlines(function(hl)
      if choice == "M" and not hl:is_todo() then
        return false
      end
      return pred(hl)
    end, input)
  elseif choice == "d" then
    M.deadlines()
  elseif choice == "b" or choice == "a" then
    local d = pick_date(choice == "b" and "Before date" or "After date")
    if d then
      M.dates(choice == "b" and "before" or "after", d)
    end
  elseif choice == "D" then
    local d1 = pick_date("From date")
    if not d1 then
      return
    end
    local d2 = pick_date("To date")
    if d2 then
      M.dates("between", d1, d2)
    end
  elseif choice == "c" then
    M.clear()
    vim.fn.setloclist(0, {}, "r")
  end
end

return M

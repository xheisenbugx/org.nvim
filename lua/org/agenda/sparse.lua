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

--- Are sparse-tree highlights shown in the buffer?
function M.has_highlights(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { limit = 1 }) > 0
end

--- Sparse tree of the entries matching a tags/property `match` string
--- (org-match-sparse-tree). `todo_only` keeps only TODO entries.
function M.match(match, todo_only)
  local pred, err = require("org.agenda.search").try_compile(match)
  if not pred then
    utils.error("Invalid match: " .. tostring(err))
    return
  end
  return M.headlines(function(hl)
    if todo_only and not hl:is_todo() then
      return false
    end
    return pred(hl)
  end, match, "tags")
end

--- Prompt for a match and show its sparse tree (C-c \). With a count,
--- only TODO entries match.
function M.tags_tree()
  if not utils.ensure_org() then
    return
  end
  local input = utils.input({ prompt = "Match: " })
  if not input or input == "" then
    return
  end
  return M.match(input, vim.v.count > 0)
end

--- Show matches. `matches` = list of { lnum, col?, end_col? } (1-based col).
--- `kind` "tags" is a tags/property match (org-match-sparse-tree), anything
--- else a search like org-occur: its highlights go away with the next
--- change (`remove_highlights_with_change`) and the OrgOccur User autocmd
--- runs after it (org-occur-hook).
--- Subtrees tagged :ARCHIVE: stay folded unless
--- `sparse_tree_open_archived_trees` (org-sparse-tree-open-archived-trees).
---@param title string
---@param kind? "occur"|"tags"
---@param message? string reported instead of "N matches for TITLE"
function M.show(matches, title, kind, message)
  local occur = kind ~= "tags"
  require("org.agenda.highlights").setup()
  local bufnr = vim.api.nvim_get_current_buf()
  M.clear(bufnr)
  table.sort(matches, function(a, b)
    return a.lnum < b.lnum or (a.lnum == b.lnum and (a.col or 0) < (b.col or 0))
  end)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local loc = {}
  local view = vim.fn.winsaveview()
  -- like org-occur: overview, then the context of each match (its
  -- headline, ancestors and, for a match in the text, the entry)
  local fold = require("org.fold")
  fold.overview()
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
    fold.show_context_for(m.lnum, occur and "occur-tree" or "tags-tree")
    loc[#loc + 1] = { bufnr = bufnr, lnum = m.lnum, col = m.col or 1, text = line }
  end
  if not require("org.config").opts.sparse_tree_open_archived_trees then
    fold.hide_archived_subtrees()
  end
  vim.fn.setloclist(0, {}, "r", { title = "Sparse tree: " .. title, items = loc })
  if #matches > 0 then
    vim.api.nvim_win_set_cursor(0, { matches[1].lnum, (matches[1].col or 1) - 1 })
  else
    vim.fn.winrestview(view)
  end
  utils.notify(message or string.format("%d match%s for %s", #matches, #matches == 1 and "" or "es", title))
  if occur and require("org.config").opts.remove_highlights_with_change ~= false then
    -- clear highlights on the next change (org-remove-highlights-with-change)
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = bufnr,
      group = vim.api.nvim_create_augroup("org.sparse." .. bufnr, { clear = true }),
      once = true,
      callback = function()
        M.clear(bufnr)
      end,
    })
  end
  if occur then
    -- org-occur-hook
    pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = "OrgOccur",
      data = { bufnr = bufnr, title = title, matches = #matches },
      modeline = false,
    })
  end
end

--- Headline matches for a predicate.
---@param kind? "occur"|"tags" (see `show`)
function M.headlines(pred, title, kind)
  local file = files.get_buffer(0)
  local out = {}
  for _, hl in ipairs(file.headlines) do
    if pred(hl) then
      out[#out + 1] = { lnum = hl.line }
    end
  end
  M.show(out, title, kind)
  return out
end

--- Does `pattern` search case-insensitively (org-occur-case-fold-search)?
--- An explicit `\c` or `\C` in the pattern wins.
local function occur_case_fold(pattern)
  local opt = require("org.config").opts.occur_case_fold_search
  if opt == "smart" then
    -- like isearch-no-upper-case-p: upper case after a backslash is a
    -- character class (\S, \W), not a letter
    return not pattern:gsub("\\.", ""):find("%u")
  end
  return opt ~= false
end

--- The regexp a sparse-tree search for `pattern` uses, or nil when it
--- is not a valid Vim regexp.
local function occur_regex(pattern)
  local re_pattern = pattern
  if not pattern:find("\\[cC]") then
    re_pattern = (occur_case_fold(pattern) and "\\c" or "\\C") .. pattern
  end
  local ok, re = pcall(vim.regex, re_pattern)
  return ok and re or nil
end

--- The first match of `re` in each line of `lines`: { lnum, col, end_col }.
--- With `budget` (nanoseconds), stops looking when it runs out.
local function occurrences(re, lines, budget)
  local out = {}
  local deadline = budget and (vim.uv.hrtime() + budget)
  for i, line in ipairs(lines) do
    local s, e = re:match_str(line)
    if s then
      out[#out + 1] = { lnum = i, col = s + 1, end_col = e }
    end
    if deadline and i % 256 == 0 and vim.uv.hrtime() > deadline then
      break
    end
  end
  return out
end

--- Regexp (Vim regex) occurrences.
function M.regexp(pattern)
  local re = occur_regex(pattern)
  if not re then
    utils.error("Invalid regexp: " .. pattern)
    return
  end
  local out = occurrences(re, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  M.show(out, "/" .. pattern .. "/")
  return out
end

--- `:Org occur [REGEXP]`: the sparse tree of REGEXP (org-occur, `C-c / /`);
--- without one, ask for it.
function M.occur_command(pattern)
  if not utils.ensure_org() then
    return
  end
  if pattern == nil or pattern == "" then
    pattern = utils.input({ prompt = "Regexp: " })
    if not pattern or pattern == "" then
      return
    end
  end
  return M.regexp(pattern)
end

--- `:Org tags_sparse_tree [MATCH]`: the sparse tree of a tags/property
--- match (org-match-sparse-tree); without one, ask for it (`C-c \`).
function M.tags_tree_command(match)
  if match == nil or match == "" then
    return M.tags_tree()
  end
  if not utils.ensure_org() then
    return
  end
  return M.match(match)
end

---------------------------------------------------------------------------
-- Live previews of :Org occur and :Org tags_sparse_tree ('inccommand')
---------------------------------------------------------------------------

--- How long a preview may look for matches, in nanoseconds.
M.preview_budget = 50 * 1e6

--- Highlight `matches` ({ lnum, col?, end_col? }) of the current buffer in
--- the preview namespace and, with `pbuf` ('inccommand' "split"), list
--- their lines there like |:s| does: `|lnum| text`.
local function preview_matches(matches, ns, pbuf)
  require("org.highlights").ensure()
  require("org.agenda.highlights").setup()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local out = {}
  for _, m in ipairs(matches) do
    local line = lines[m.lnum] or ""
    local s = m.col and (m.col - 1) or 0
    local e = m.col and math.min(m.end_col or #line, #line) or #line
    vim.api.nvim_buf_set_extmark(0, ns, m.lnum - 1, s, { end_col = e, hl_group = "OrgSparseMatch", priority = 150 })
    if pbuf then
      local prefix = "|" .. m.lnum .. "| "
      out[#out + 1] = { prefix .. line, #prefix + s, #prefix + e }
    end
  end
  if not pbuf or #out == 0 then
    return #matches > 0 and 1 or 0
  end
  vim.api.nvim_buf_set_lines(
    pbuf,
    0,
    -1,
    false,
    vim.tbl_map(function(o)
      return o[1]
    end, out)
  )
  for i, o in ipairs(out) do
    vim.api.nvim_buf_set_extmark(pbuf, ns, i - 1, o[2], { end_col = o[3], hl_group = "OrgSparseMatch" })
  end
  return 2
end

--- Live preview of `:Org occur REGEXP` (|:command-preview|): highlights
--- the first match in each line as you type. Nothing is folded until the
--- command runs.
---@return integer
function M.occur_preview(pattern, ns, pbuf)
  if pattern == nil or pattern == "" or vim.bo.filetype ~= "org" then
    return 0
  end
  local re = occur_regex(pattern)
  if not re then
    return 0
  end
  local matches = occurrences(re, vim.api.nvim_buf_get_lines(0, 0, -1, false), M.preview_budget)
  return preview_matches(matches, ns, pbuf)
end

--- Live preview of `:Org tags_sparse_tree MATCH`: highlights the
--- headlines MATCH selects. A match that does not parse yet shows nothing.
---@return integer
function M.match_preview(match, ns, pbuf)
  if match == nil or match == "" or vim.bo.filetype ~= "org" then
    return 0
  end
  local pred = require("org.agenda.search").try_compile(match)
  if not pred then
    return 0
  end
  local out = {}
  local deadline = vim.uv.hrtime() + M.preview_budget
  for i, hl in ipairs(files.get_buffer(0).headlines) do
    local ok, yes = pcall(pred, hl)
    if ok and yes then
      out[#out + 1] = { lnum = hl.line }
    end
    if i % 256 == 0 and vim.uv.hrtime() > deadline then
      break
    end
  end
  return preview_matches(out, ns, pbuf)
end

--- The date types of the before/after/range sparse trees, in the order `c`
--- cycles them (org-sparse-tree); nil = SCHEDULED or DEADLINE.
M.DATE_TYPES = { false, "all", "scheduled", "deadline", "active", "inactive", "closed" }

local DATE_TYPE_LABELS = {
  all = "all timestamps",
  scheduled = "only scheduled",
  deadline = "only deadline",
  active = "only active timestamps",
  inactive = "only inactive timestamps",
  closed = "with a closed timestamp",
}

--- How the menu names a date type.
function M.date_type_label(type)
  return DATE_TYPE_LABELS[type or ""] or "scheduled/deadline"
end

local PLANNING = {
  scheduled = "%f[%w]SCHEDULED: *(<[^>]+>)",
  deadline = "%f[%w]DEADLINE: *(<[^>]+>)",
  closed = "%f[%w]CLOSED: *(%[[^%]]+%])",
}

--- The timestamps a date sparse tree of `type` compares (org-re-timestamp
--- and the org-check-*-date callbacks): { lnum, col, end_col, date }. The
--- planning types match the planning line's `KEYWORD: <date>`; "all",
--- "active" and "inactive" match each timestamp in the text, but not in
--- planning lines, clock lines, property drawers, blocks, comments or
--- verbatim.
function M.dated(bufnr, type)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local file = files.get_buffer(bufnr)
  local planning = {}
  for _, hl in ipairs(file.headlines) do
    if hl.planning_line then
      planning[hl.planning_line] = true
    end
  end
  local out = {}
  if not type or PLANNING[type] then
    local kinds = type and { PLANNING[type] } or { PLANNING.deadline, PLANNING.scheduled }
    for lnum in pairs(planning) do
      local line = lines[lnum] or ""
      for _, pat in ipairs(kinds) do
        local init = 1
        while true do
          local s, e, stamp = line:find(pat, init)
          if not s then
            break
          end
          local d = date.parse(stamp)
          if d then
            out[#out + 1] = { lnum = lnum, col = s, end_col = e, date = d }
          end
          init = e + 1
        end
      end
    end
  else
    local links = require("org.links")
    local skip = links.ignored_lines(lines)
    for lnum, line in ipairs(lines) do
      if not skip[lnum] and not planning[lnum] and not line:match("^%s*CLOCK:") then
        local spans = links.verbatim_spans(line)
        local init = 1
        while true do
          local s, e, open, close = line:find("([<%[])%d%d%d%d%-%d%d?%-%d%d?[^<>%[%]\n]-([>%]])", init)
          if not s then
            break
          end
          local verbatim = false
          for _, sp in ipairs(spans) do
            verbatim = verbatim or (s >= sp[1] and s <= sp[2])
          end
          local active = open == "<"
          if
            not verbatim
            and (active and close == ">" or not active and close == "]")
            and (type == "all" or (type == "active") == active)
          then
            local d = date.parse(line:sub(s, e))
            if d then
              out[#out + 1] = { lnum = lnum, col = s, end_col = e, date = d }
            end
          end
          init = e + 1
        end
      end
    end
  end
  table.sort(out, function(a, b)
    return a.lnum < b.lnum or (a.lnum == b.lnum and a.col < b.col)
  end)
  return out
end

--- Sparse tree of the dates before `d1`, on or after it, or from `d1` up
--- to (not including) `d2` (org-check-before-date, org-check-after-date,
--- org-check-dates-range). `type` is a date type (default
--- `sparse_tree_default_date_type`). Each matching timestamp is
--- highlighted.
function M.dates(kind, d1, d2, type)
  if type == nil then
    type = require("org.config").opts.sparse_tree_default_date_type
  end
  local from, to = d1:days(), d2 and d2:days()
  local out = {}
  for _, m in ipairs(M.dated(0, type or nil)) do
    local n = m.date:days()
    if
      (kind == "before" and n < from)
      or (kind == "after" and n >= from)
      or (kind == "between" and n >= from and n < to)
    then
      out[#out + 1] = { lnum = m.lnum, col = m.col, end_col = m.end_col }
    end
  end
  local title = kind == "between" and string.format("between %s and %s", d1:to_date_string(), d2:to_date_string())
    or string.format("%s %s", kind, d1:to_date_string())
  M.show(out, title, nil, string.format("%d entries %s", #out, title))
  return out
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
    return dl:days() - today <= date.deadline_warning_days(dl, warn_default)
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

--- The sparse-tree menu (org-sparse-tree). `date_type` is the date type
--- of the date trees (default `sparse_tree_default_date_type`; false =
--- SCHEDULED/DEADLINE); `c` cycles it and shows the menu again.
function M.prompt(date_type)
  if not utils.ensure_org() then
    return
  end
  if date_type == nil then
    date_type = require("org.config").opts.sparse_tree_default_date_type or false
  end
  local choice = require("org.ui").menu({
    title = "Sparse tree (dates: " .. M.date_type_label(date_type) .. ")",
    items = {
      { key = "/", label = "Regexp", value = "/" },
      { key = "r", label = "Regexp", value = "/" },
      { key = "t", label = "TODO entries (not done)", value = "t" },
      { key = "T", label = "Specific TODO keyword(s)", value = "T" },
      { key = "m", label = "Tags / property match", value = "m" },
      { key = "M", label = "Match, only TODO entries", value = "M" },
      { key = "p", label = "Property value", value = "p" },
      { key = "d", label = "Deadlines (due or in warning period)", value = "d" },
      { key = "b", label = "Dates before …", value = "b" },
      { key = "a", label = "Dates after …", value = "a" },
      { key = "D", label = "Dates between …", value = "D" },
      { key = "c", label = "Cycle through date types", value = "c" },
      { key = "C", label = "Clear highlights", value = "C" },
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
    end, input, "tags")
  elseif choice == "d" then
    M.deadlines()
  elseif choice == "b" or choice == "a" then
    local d = pick_date(choice == "b" and "Before date" or "After date")
    if d then
      M.dates(choice == "b" and "before" or "after", d, nil, date_type)
    end
  elseif choice == "D" then
    local d1 = pick_date("From date")
    if not d1 then
      return
    end
    local d2 = pick_date("To date")
    if d2 then
      M.dates("between", d1, d2, date_type)
    end
  elseif choice == "c" then
    local nxt = M.DATE_TYPES[1]
    for i, t in ipairs(M.DATE_TYPES) do
      if t == date_type then
        nxt = M.DATE_TYPES[i % #M.DATE_TYPES + 1]
      end
    end
    return M.prompt(nxt)
  elseif choice == "C" then
    M.clear()
    vim.fn.setloclist(0, {}, "r")
  end
end

return M

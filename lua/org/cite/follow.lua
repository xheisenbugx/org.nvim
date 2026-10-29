---@mod org.cite.follow Following citations
---
--- The follow capability (org-cite-follow, org-cite-basic-goto), the key's
--- mouse-1 binding (org-cite-basic--set-keymap) and its help text. Part of
--- org.cite, which loads it.

local utils = require("org.utils")
local shared = require("org.cite.shared")

local M = require("org.cite")
local basic = M.basic
local field = basic.field
local user_error = M.user_error
local new_edit = shared.new_edit
local processor_for = shared.processor_for

--- Open the bibliography entry of `key` (org-cite-basic-goto).
function basic.goto_key(bufnr, key)
  local _, file = basic.get_entry(M.parse_bibliography(bufnr), key)
  if not file then
    user_error(string.format('Cannot find citation key: "%s"', key))
  end
  utils.open_file(file)
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local target, col = nil, 0
  if file:match("%.json$") then
    local esc = vim.pesc(key)
    local text = table.concat(lines, "\n")
    local s = text:find('"id":[ \t]*"' .. esc .. '"')
    if s then
      local brace = text:sub(1, s):match(".*(){")
      if brace then
        local before = text:sub(1, brace - 1)
        local _, nl = before:gsub("\n", "")
        target = nl + 1
        col = #(before:match("[^\n]*$"))
      end
    end
  else
    local lkey = key:lower()
    for i, l in ipairs(lines) do
      local k = l:match("^%s*@[%w_%-]+%s*[{(]%s*([^,%s]+)")
      if k and k:lower() == lkey then
        target = i
        col = #(l:match("^%s*"))
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, col })
    pcall(vim.api.nvim_command, "normal! zv")
  end
end

--- The basic follow function: a reference opens its key; on the rest of a
--- citation with several keys, choose one.
function basic.follow(ctx)
  local bufnr = ctx.region.bufnr
  local key
  if ctx.type == "citation-reference" then
    key = ctx.reference.key
  else
    local keys = {}
    for i, r in ipairs(ctx.citation.references) do
      keys[i] = r.key
    end
    if #keys == 1 then
      key = keys[1]
    else
      key = utils.select(keys, { prompt = "Select citation key: " })
      if not key then
        user_error("Aborted")
      end
    end
  end
  basic.goto_key(bufnr, key)
end

--- org-cite-follow: follow the citation at the cursor. Returns false when
--- the cursor is not on a citation.
function M.follow(arg)
  local ctx = M.at_point()
  if not ctx then
    return false
  end
  processor_for("follow", "follow_processor", "follow").follow(ctx, arg)
  return true
end

---------------------------------------------------------------------------
-- The key's mouse-1 binding (org-cite-basic--set-keymap)
---------------------------------------------------------------------------

--- A mouse click on a citation key, like Emacs' mouse-1 on an activated
--- key: a known key opens its entry, an unknown key is replaced with one
--- of the close keys (`export.cite.basic_max_key_distance`), or a key is
--- inserted when there is none. Returns false elsewhere.
function M.mouse_click()
  local mp = vim.fn.getmousepos()
  if mp.winid == 0 or mp.line == 0 then
    return false
  end
  local bufnr = vim.api.nvim_win_get_buf(mp.winid)
  if vim.bo[bufnr].filetype ~= "org" then
    return false
  end
  local row, col = mp.line, mp.column - 1
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  if col >= #line then
    return false
  end
  local ctx = M.at_cursor(bufnr, row, col)
  local r = ctx.reference
  if ctx.type ~= "citation-reference" or ctx.point < r.key_begin or ctx.point >= r.key_end then
    return false
  end
  local bib = M.parse_bibliography(bufnr)
  local keys = basic.all_keys(bib)
  local known = false
  for _, k in ipairs(keys) do
    if k == r.key then
      known = true
      break
    end
  end
  if known then
    M.follow()
    return true
  end
  local close = basic.close_keys(r.key, keys)
  if #close == 0 then
    M.insert()
    return true
  end
  local choice = #close == 1 and close[1] or utils.select(close, { prompt = "Did you mean: " })
  if choice then
    local ed = new_edit(ctx.region, ctx.point)
    ed:delete(r.key_begin, r.key_end)
    ed:insert(r.key_begin, "@" .. choice)
    ed.point = r.key_begin
    ed:apply()
  end
  return true
end

--- The help text Emacs shows over a key (help-echo): the entry of a known
--- key, the suggestions for an unknown one.
function M.key_help(bufnr, key)
  local bib = M.parse_bibliography(bufnr)
  local entry = basic.get_entry(bib, key)
  if entry then
    local author = field(entry, "author") or field(entry, "editor")
    local names = {}
    for _, n in ipairs(vim.split(author or "", " and ", { plain = true })) do
      if n ~= "" then
        names[#names + 1] = vim.split(n, ", ", { plain = true })[1]
      end
    end
    local from = field(entry, "publisher")
      or field(entry, "journal")
      or field(entry, "institution")
      or field(entry, "school")
    return (
      table.concat(names, ", ")
      .. ". "
      .. (field(entry, "title") or "")
      .. (from and (", " .. from) or "")
      .. ", "
      .. (basic.year(entry) or "")
      .. "."
    ):gsub("[{}]", "")
  end
  local close = basic.close_keys(key, basic.all_keys(bib))
  if #close > 0 then
    return "Suggestions (mouse-1 to substitute): " .. table.concat(close, " ")
  end
end

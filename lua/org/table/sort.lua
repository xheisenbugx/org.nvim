---@mod org.table.sort Sorting and transposing tables
---
--- org-table-sort-lines (C-c ^) and org-table-transpose-table-at-point.
---
--- Part of org.table, which loads it.

local utils = require("org.utils")
local shared = require("org.table.shared")

local M = require("org.table")

local cursor_pos = shared.cursor_pos
local dline = shared.dline
local in_visual = shared.in_visual
local pad_rows = shared.pad_rows
local set_cursor = shared.set_cursor
local write_table = shared.write_table

--- Text of a field without emphasis markers and link brackets (a link
--- sorts as its description). Emacs org-sort-remove-invisible.
function M.remove_invisible(s)
  s = s:gsub("%[%[([^%]]-)%]%[(.-)%]%]", "%2"):gsub("%[%[([^%]]-)%]%]", "%1")
  local out, i, n = {}, 1, #s
  while i <= n do
    local ch = s:sub(i, i)
    local prev = i == 1 and " " or s:sub(i - 1, i - 1)
    local close
    if ch:match("[*/_+=~]") and prev:match("[%s%-({'\"]") and s:sub(i + 1, i + 1):match("%S") then
      local j = i + 1
      while true do
        j = s:find(ch, j + 1, true)
        if not j then
          break
        end
        local after = j == n and " " or s:sub(j + 1, j + 1)
        if s:sub(j - 1, j - 1):match("%S") and after:match("[%s%-%.,:!?;'\")}%]]") then
          close = j
          break
        end
      end
    end
    if close then
      out[#out + 1] = M.remove_invisible(s:sub(i + 1, close - 1))
      i = close + 1
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end
  return table.concat(out)
end

--- Sort key of a field for sorting type `kind` (a, n, t).
local function sort_key(kind, v)
  if kind == "n" then
    return (require("org.table.formula").string_to_number(v))
  elseif kind == "t" then
    local date = require("org.date")
    local item = date.parse_all(v)[1]
    if item then
      return item.date:to_time()
    end
    local mins = date.parse_duration(v)
    if mins and (v:match("^%s*%d+:%d%d") or v:match("%a")) then
      return mins
    end
    local hm = v:match("%f[%d](%d+:%d%d)%f[^%d]")
    return hm and date.parse_duration(hm) or 0
  end
  return M.remove_invisible(v)
end

--- Read a Lua function for `f`/`F` sorting (an expression such as
--- `function(s) return #s end` or the name of a global function).
local function read_function(prompt, allow_empty)
  local text = utils.input({ prompt = prompt })
  if text == nil or (vim.trim(text) == "" and allow_empty) then
    return nil
  end
  local chunk = load("return " .. text, "sort", "t", setmetatable({}, { __index = _G }))
  local ok, fn = false, nil
  if chunk then
    ok, fn = pcall(chunk)
  end
  if not ok or type(fn) ~= "function" then
    utils.warn("Not a function: " .. text)
    utils.abort()
  end
  return fn
end

--- Sort the rows of the current hline-delimited section (or the rows of
--- the visual selection) by the current column. Types: a (text without
--- markup; case-insensitive unless `opts.with_case`, set by a count like
--- Emacs' C-u), n (numbers), t (timestamps, durations, H:MM), f (a key
--- function, prompted as Lua, with an optional comparison function);
--- uppercase sorts in reverse. Emacs org-table-sort-lines (C-c ^).
---@param opts? { type?: string, with_case?: boolean, getkey?: (fun(field: string): any), compare?: fun(a: any, b: any): boolean }
function M.sort_column(opts)
  opts = type(opts) == "table" and opts or {}
  local visual = in_visual()
  local srow, scol, erow
  if visual then
    srow, scol, erow = utils.visual_range()
    utils.exit_visual()
    vim.api.nvim_win_set_cursor(0, { srow, math.max(scol - 1, 0) })
  end
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  local t = info.tbl
  pad_rows(t)
  if t.rows[row].hline then
    utils.warn("Place the cursor on a data row")
    return
  end
  local with_case = opts.with_case
  if with_case == nil then
    with_case = vim.v.count > 0
  end
  local choice = opts.type
    or require("org.ui").menu({
      title = "Sort table by column " .. field,
      items = {
        { key = "a", label = "alphabetically", value = "a" },
        { key = "A", label = "alphabetically (reverse)", value = "A" },
        { key = "n", label = "numerically", value = "n" },
        { key = "N", label = "numerically (reverse)", value = "N" },
        { key = "t", label = "by time/date", value = "t" },
        { key = "T", label = "by time/date (reverse)", value = "T" },
        { key = "f", label = "by a key function", value = "f" },
        { key = "F", label = "by a key function (reverse)", value = "F" },
      },
    })
  if not choice then
    return
  end
  local s, e = row, row
  if visual then
    s = math.max(srow, info.start) - info.start + 1
    e = math.min(erow, info.finish) - info.start + 1
  else
    while s > 1 and not t.rows[s - 1].hline do
      s = s - 1
    end
    while e < #t.rows and not t.rows[e + 1].hline do
      e = e + 1
    end
  end
  local kind = choice:lower()
  local getkey, compare = opts.getkey, opts.compare
  if kind == "f" and not getkey then
    getkey = read_function("Function for extracting keys: ")
    compare = compare or read_function("Function for comparing keys (empty for default): ", true)
  end
  local reverse = choice ~= kind
  -- only data rows move; hlines inside a selected region stay in place
  local slots, slice = {}, {}
  for i = s, e do
    if not t.rows[i].hline then
      slots[#slots + 1] = i
      local r = t.rows[i]
      local v = vim.trim(r.cells[field] or "")
      local k
      if kind == "f" then
        k = getkey(v)
      else
        k = sort_key(kind, v)
        if kind == "a" and not with_case then
          k = k:lower()
        end
      end
      slice[#slice + 1] = { row = r, key = k, i = #slice + 1 }
    end
  end
  local less = compare
    or function(a, b)
      if type(a) == "string" and type(b) == "string" then
        return utils.string_lessp(a, b) -- org-sort-function
      end
      return a < b
    end
  table.sort(slice, function(a, b)
    local x, y = a.key, b.key
    if reverse then
      x, y = y, x
    end
    if less(x, y) then
      return true
    elseif less(y, x) then
      return false
    end
    return a.i < b.i
  end)
  for i, item in ipairs(slice) do
    t.rows[slots[i]] = item.row
  end
  local lines = write_table(info, t)
  set_cursor(info, lines, row, field, 0)
end

--- Transpose the table at the cursor: rows become columns. Hlines are
--- dropped. Emacs org-table-transpose-table-at-point.
function M.transpose()
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  local t = info.tbl
  pad_rows(t)
  local data = {}
  for _, r in ipairs(t.rows) do
    if not r.hline then
      data[#data + 1] = r.cells
    end
  end
  local out = { indent = t.indent, rows = {}, ncols = math.max(#data, 1) }
  for c = 1, t.ncols do
    local cells = {}
    for i, cells_in in ipairs(data) do
      cells[i] = cells_in[c] or ""
    end
    out.rows[c] = { cells = cells }
  end
  local lines = write_table(info, out)
  set_cursor(info, lines, field, t.rows[row].hline and 1 or dline(t, row), 0)
end

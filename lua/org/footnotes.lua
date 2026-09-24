---@mod org.footnotes Footnotes
---
--- References `[fn:label]`, definitions `[fn:label] text` at the start of a
--- line, inline definitions `[fn::text]` and `[fn:label:text]`.
--- New definitions go into a `* Footnotes` section when there is one,
--- otherwise to the end of the file (org-footnote-section).

local utils = require("org.utils")

local M = {}

M.section_title = "Footnotes"

--- Footnote at the cursor.
---@return { kind: "reference"|"definition"|"inline", label: string|nil, start_col: integer, end_col: integer }|nil
function M.at_point(bufnr, lnum, col)
  if not lnum then
    lnum, col = utils.cursor()
  end
  bufnr = bufnr or 0
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local init = 1
  while true do
    local s = line:find("[fn:", init, true)
    if not s then
      return nil
    end
    -- find the matching closing bracket (inline definitions may nest [])
    local depth, e = 0, nil
    for i = s, #line do
      local c = line:sub(i, i)
      if c == "[" then
        depth = depth + 1
      elseif c == "]" then
        depth = depth - 1
        if depth == 0 then
          e = i
          break
        end
      end
    end
    if not e then
      return nil
    end
    local inner = line:sub(s + 4, e - 1)
    if col >= s and col <= e then
      local label, rest = inner:match("^([^:%]]*):(.*)$")
      if label then
        return { kind = "inline", label = label ~= "" and label or nil, text = rest, start_col = s, end_col = e }
      end
      if s == 1 then
        return { kind = "definition", label = inner, start_col = s, end_col = e }
      end
      return { kind = "reference", label = inner, start_col = s, end_col = e }
    end
    init = e + 1
  end
end

local function find_definition(bufnr, label)
  local pat = "^%[fn:" .. utils.escape_pattern(label) .. "%]"
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:match(pat) then
      return i
    end
  end
  -- inline definition with label
  local inline = "[fn:" .. label .. ":"
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local s = l:find(inline, 1, true)
    if s then
      return i, s
    end
  end
end

local function find_reference(bufnr, label)
  local needle = "[fn:" .. label .. "]"
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local init = 1
    while true do
      local s = l:find(needle, init, true)
      if not s then
        break
      end
      if s > 1 then
        return i, s
      end
      init = s + 1
    end
  end
end

local function jump(lnum, col)
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { lnum, (col or 1) - 1 })
  pcall(vim.cmd, "normal! zv")
end

--- Jump between a reference and its definition.
function M.action_at_point()
  local fn = M.at_point()
  if not fn then
    return false
  end
  if fn.kind == "reference" then
    local l, c = find_definition(0, fn.label)
    if not l then
      utils.warn("No definition for footnote " .. fn.label)
      return
    end
    jump(l, c or 1)
  elseif fn.kind == "definition" then
    local l, c = find_reference(0, fn.label)
    if not l then
      utils.warn("No reference to footnote " .. fn.label)
      return
    end
    jump(l, c)
  else
    if fn.label then
      local l, c = find_reference(0, fn.label)
      if l then
        jump(l, c)
        return
      end
    end
    utils.notify("Inline footnote: " .. (fn.text or ""))
  end
end

--- Next free numeric label.
function M.next_label(bufnr)
  local max = 0
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr or 0, 0, -1, false)) do
    for n in l:gmatch("%[fn:(%d+)[%]:]") do
      max = math.max(max, tonumber(n))
    end
  end
  return tostring(max + 1)
end

--- Insert a new footnote reference at the cursor and create its definition.
---@param opts? { no_insert?: boolean }
function M.new_footnote(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local label = M.next_label(bufnr)
  local ref = "[fn:" .. label .. "]"
  local row, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local at = line == "" and 0 or math.min(col0 + 1, #line)
  vim.api.nvim_set_current_line(line:sub(1, at) .. ref .. line:sub(at + 1))

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local parser = require("org.parser")
  local section_line, section_end
  for i, l in ipairs(lines) do
    local p = parser.parse_headline_line(l)
    if p and p.title == M.section_title then
      section_line = i
      section_end = #lines
      for j = i + 1, #lines do
        local lvl = parser.headline_level(lines[j])
        if lvl and lvl <= p.level then
          section_end = j - 1
          break
        end
      end
      break
    end
  end
  local def = "[fn:" .. label .. "] "
  local target
  if section_line then
    local e = section_end
    while e > section_line and vim.trim(lines[e]) == "" do
      e = e - 1
    end
    local new = { def }
    if e > section_line then
      table.insert(new, 1, "")
    end
    vim.api.nvim_buf_set_lines(bufnr, e, e, false, new)
    target = e + #new
  else
    local e = #lines
    while e > 0 and vim.trim(lines[e]) == "" do
      e = e - 1
    end
    vim.api.nvim_buf_set_lines(bufnr, e, #lines, false, { "", def })
    target = e + 2
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { target, #def - 1 })
  pcall(vim.cmd, "normal! zv")
  if not opts.no_insert and not vim.g.org_test then
    vim.cmd("startinsert!")
  end
  return label, row
end

return M

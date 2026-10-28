---@mod org.ui.inspect What is drawn under the cursor (:Org inspect)
---
--- |:Inspect| (vim.inspect_pos()) lists the syntax groups, tree-sitter
--- captures and extmarks at a position, but not the ephemeral marks
--- decoration providers draw on each redraw: nearly all of an org buffer's
--- highlighting (the parser highlighter, org.ui.decorations),
--- and citations always (org.cite.attach). This lists those too.

local M = {}

---@class org.ui.inspect.Item
---@field source string "parser", "emphasis", "decorations", "citations", "syntax", "treesitter" or an extmark namespace
---@field hl_group? string
---@field priority? integer
---@field spell? boolean
---@field conceal? string

--- What is drawn at byte `col` (0-based) of row `row` (0-based) of
--- `bufnr`, lowest first in each source (the order :Inspect shows).
---@param bufnr integer
---@param row integer
---@param col integer
---@return org.ui.inspect.Item[]
function M.at(bufnr, row, col)
  local out = {} ---@type org.ui.inspect.Item[]
  local function covers(start, o)
    return col >= start and (col < (o.end_col or start + 1) or (o.end_row or row) > row)
  end
  local marks = {} ---@type org.ui.inspect.Item[]
  local deco = package.loaded["org.ui.decorations"]
  if deco then
    for _, m in ipairs(deco.line_marks(bufnr, row)) do
      local o = m[2]
      if covers(m[1], o) and (o.hl_group or o.spell ~= nil or o.conceal) then
        local source = (m[3] == "parser" or m[3] == "emphasis") and m[3] or "decorations"
        marks[#marks + 1] = {
          source = source,
          hl_group = o.hl_group,
          priority = o.priority,
          spell = o.spell,
          conceal = o.conceal,
        }
      end
    end
  end
  -- (the citations' marks: org.cite `marks` looks for them around the row)
  local cok, rows = pcall(function()
    return require("org.cite").marks(bufnr, row, row)
  end)
  for _, c in ipairs(cok and rows[row] or {}) do
    if col >= c[1] and col < c[2] then
      marks[#marks + 1] = { source = "citations", hl_group = c[3], priority = c[4] }
    end
  end
  table.sort(marks, function(a, b)
    return (a.priority or 0) < (b.priority or 0)
  end)
  vim.list_extend(out, marks)
  local ok, pos = pcall(
    vim.inspect_pos,
    bufnr,
    row,
    col,
    { syntax = true, treesitter = true, extmarks = true, semantic_tokens = false }
  )
  if ok then
    for _, s in ipairs(pos.syntax or {}) do
      out[#out + 1] = { source = "syntax", hl_group = s.hl_group }
    end
    for _, t in ipairs(pos.treesitter or {}) do
      out[#out + 1] = { source = "treesitter", hl_group = t.hl_group }
    end
    for _, x in ipairs(pos.extmarks or {}) do
      local o = x.opts or {}
      if o.hl_group or o.spell ~= nil or o.conceal then
        out[#out + 1] = {
          source = x.ns ~= "" and x.ns or tostring(x.ns_id),
          hl_group = o.hl_group,
          priority = o.priority,
          spell = o.spell,
          conceal = o.conceal,
        }
      end
    end
  end
  return out
end

--- The groups `group` links to, in turn.
---@return string[]
local function links(group)
  local out = {}
  local name = group
  while #out < 20 do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = true })
    if not ok or not hl.link then
      break
    end
    name = hl.link
    out[#out + 1] = name
  end
  return out
end

--- Show what is drawn under the cursor (the action `inspect`), like
--- |:Inspect| with the ephemeral marks.
function M.show()
  local bufnr = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  local items = M.at(bufnr, cur[1] - 1, cur[2])
  local chunks = {} ---@type string[][]
  if #items == 0 then
    chunks[1] = { "Nothing drawn under the cursor" }
  end
  local last
  for _, it in ipairs(items) do
    if it.source ~= last then
      chunks[#chunks + 1] = { (#chunks > 0 and "\n" or "") .. it.source .. "\n", "Title" }
      last = it.source
    end
    chunks[#chunks + 1] = { "  - " }
    if it.hl_group then
      chunks[#chunks + 1] = { it.hl_group, it.hl_group }
      for _, l in ipairs(links(it.hl_group)) do
        chunks[#chunks + 1] = { " -> " }
        chunks[#chunks + 1] = { l, l }
      end
    else
      chunks[#chunks + 1] = { "(no group)", "Comment" }
    end
    local extra = {}
    if it.priority then
      extra[#extra + 1] = "priority: " .. it.priority
    end
    if it.spell ~= nil then
      extra[#extra + 1] = "spell: " .. tostring(it.spell)
    end
    if it.conceal then
      extra[#extra + 1] = it.conceal == "" and "hidden" or ("conceal: " .. it.conceal)
    end
    if #extra > 0 then
      chunks[#chunks + 1] = { " " .. table.concat(extra, ", "), "Comment" }
    end
    chunks[#chunks + 1] = { "\n" }
  end
  if #items > 0 then
    chunks[#chunks] = nil
  end
  vim.api.nvim_echo(chunks, false, {})
end

return M

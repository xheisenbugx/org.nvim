---@mod org.footnotes Footnotes
---
--- References `[fn:label]`, definitions `[fn:label] text` at the start of a
--- line, inline definitions `[fn::text]` and `[fn:label:text]`.
--- New definitions go into the `footnote_section` heading (`* Footnotes`,
--- created at the end of the file when missing), or at the end of the
--- current section when `footnote_section` is false (org-footnote-section).
--- `sort`, `renumber`, `normalize` and `delete` mirror org-footnote-action's
--- C-u menu.

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

--- Heading that collects definitions, or nil (config `footnote_section`).
local function section_name()
  local s = require("org.config").opts.footnote_section
  if s == nil then
    return M.section_title
  end
  return s or nil
end

local function is_blank(l)
  return l == nil or l:match("^%s*$") ~= nil
end

--- Line range of the footnote section heading's own text, or nil.
---@return integer|nil heading, integer|nil last line of its section
local function find_section(lines, name)
  local parser = require("org.parser")
  for i, l in ipairs(lines) do
    local p = parser.parse_headline_line(l)
    if p and vim.trim(p.title) == name then
      local e = #lines
      for j = i + 1, #lines do
        if parser.headline_level(lines[j]) then
          e = j - 1
          break
        end
      end
      return i, e
    end
  end
end

--- Last line of the outline section containing `lnum` (before the next
--- headline), or of the file.
local function section_end(lines, lnum)
  local parser = require("org.parser")
  for j = lnum + 1, #lines do
    if parser.headline_level(lines[j]) then
      return j - 1
    end
  end
  return #lines
end

--- Insert `block` (definition lines) at the end of the region ending at
--- `e` (trailing blank lines skipped), separated by a blank line unless it
--- directly follows `heading`. Returns the new lines and the line of the
--- inserted definition.
local function insert_block(lines, heading, e, block)
  while e > (heading or 0) and is_blank(lines[e]) do
    e = e - 1
  end
  local new = vim.deepcopy(block)
  local lead = 0
  if e > 0 and e ~= heading then
    table.insert(new, 1, "")
    lead = 1
  end
  if lines[e + 1] and not is_blank(lines[e + 1]) then
    new[#new + 1] = ""
  end
  for i, l in ipairs(new) do
    table.insert(lines, e + i, l)
  end
  return lines, e + lead + 1
end

--- Footnote section heading line and section end in `lines`, creating
--- the heading at the end of the buffer when it is missing.
local function ensure_section(lines, name)
  local heading, e = find_section(lines, name)
  if heading then
    return heading, e
  end
  while #lines > 0 and is_blank(lines[#lines]) do
    table.remove(lines)
  end
  if #lines > 0 then
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = "* " .. name
  return #lines, #lines
end

--- Create a definition for `label` (org-footnote-create-definition): in
--- the footnote section (created at the end of the buffer when missing),
--- or at the end of the section containing `ref_lnum` when
--- `footnote_section` is false. Returns the definition's line.
function M.create_definition(bufnr, label, ref_lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local name = section_name()
  local heading, e
  if name then
    heading, e = ensure_section(lines, name)
  else
    e = section_end(lines, ref_lnum or 1)
  end
  local _, target = insert_block(lines, heading, e, { "[fn:" .. label .. "] " })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return target
end

--- Jump between a reference and its definition. On a reference without
--- definition, offer to create one.
function M.action_at_point()
  local fn = M.at_point()
  if not fn then
    return false
  end
  if fn.kind == "reference" then
    local l, c = find_definition(0, fn.label)
    if not l then
      if utils.confirm("No definition for " .. fn.label .. ". Create one?") then
        l = M.create_definition(vim.api.nvim_get_current_buf(), fn.label, vim.api.nvim_win_get_cursor(0)[1])
        jump(l, #("[fn:" .. fn.label .. "] "))
      end
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
  local target = M.create_definition(bufnr, label, row)
  local def = "[fn:" .. label .. "] "
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { target, #def - 1 })
  pcall(vim.cmd, "normal! zv")
  if not opts.no_insert and not vim.g.org_test then
    vim.cmd("startinsert!")
  end
  return label, row
end

---------------------------------------------------------------------------
-- Sorting, renumbering, normalizing, deleting
---------------------------------------------------------------------------

--- Every footnote reference of `lines`, in buffer order.
---@return { lnum: integer, s: integer, e: integer, label: string|nil, text: string|nil }[]
function M.collect_references(lines)
  local out = {}
  for lnum, line in ipairs(lines) do
    local init = 1
    while true do
      local s = line:find("[fn:", init, true)
      if not s then
        break
      end
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
        break
      end
      local inner = line:sub(s + 4, e - 1)
      local label, text = inner:match("^([^:%]]*):(.*)$")
      if label then
        out[#out + 1] = { lnum = lnum, s = s, e = e, label = label ~= "" and label or nil, text = text }
      elseif s > 1 then
        out[#out + 1] = { lnum = lnum, s = s, e = e, label = inner }
      end
      init = e + 1
    end
  end
  return out
end

--- Footnote definitions of `lines`: a line starting with `[fn:label]`,
--- up to the next definition, headline or two blank lines.
---@return { label: string, start: integer, stop: integer }[]
function M.collect_definitions(lines)
  local parser = require("org.parser")
  local out = {}
  local i = 1
  while i <= #lines do
    local label = lines[i]:match("^%[fn:([^%]:]+)%]")
    if label then
      local stop = i
      local j = i + 1
      while j <= #lines do
        local l = lines[j]
        if l:match("^%[fn:[^%]:]+%]") or parser.headline_level(l) then
          break
        end
        if is_blank(l) and is_blank(lines[j + 1]) then
          break
        end
        if not is_blank(l) then
          stop = j
        end
        j = j + 1
      end
      out[#out + 1] = { label = label, start = i, stop = stop }
      i = stop + 1
    else
      i = i + 1
    end
  end
  return out
end

--- Remove definition blocks (and the blank lines after them) from
--- `lines`. Returns label -> block lines and the labels in buffer order.
local function extract_definitions(lines)
  local defs = M.collect_definitions(lines)
  local blocks, order = {}, {}
  for i = #defs, 1, -1 do
    local d = defs[i]
    local stop = d.stop
    while lines[stop + 1] and is_blank(lines[stop + 1]) do
      stop = stop + 1
    end
    if not blocks[d.label] then
      table.insert(order, 1, d.label)
    end
    blocks[d.label] = vim.list_slice(lines, d.start, d.stop)
    for j = stop, d.start, -1 do
      table.remove(lines, j)
    end
  end
  return blocks, order
end

--- Insert definition blocks: all in the footnote section, or each at the
--- end of the section of its first reference.
---@param entries { block: string[], ref_lnum: integer|nil }[]
local function insert_definitions(lines, entries)
  local name = section_name()
  if name then
    local out = {}
    for i, en in ipairs(entries) do
      if i > 1 then
        out[#out + 1] = ""
      end
      vim.list_extend(out, en.block)
    end
    if #out == 0 then
      return lines
    end
    local heading, e = ensure_section(lines, name)
    insert_block(lines, heading, e, out)
    return lines
  end
  -- local placement, bottom-up so earlier line numbers stay valid
  local sorted = {}
  for i, en in ipairs(entries) do
    sorted[#sorted + 1] = { idx = i, lnum = en.ref_lnum or #lines, block = en.block }
  end
  table.sort(sorted, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum > b.lnum
    end
    return a.idx > b.idx
  end)
  for _, en in ipairs(sorted) do
    local e = section_end(lines, math.min(en.lnum, #lines))
    insert_block(lines, nil, e, en.block)
  end
  return lines
end

--- Rebuild definitions in reference order. `extra` adds label -> block
--- definitions (from normalized inline footnotes).
local function sort_lines(lines, extra)
  local blocks, order = extract_definitions(lines)
  for k, v in pairs(extra or {}) do
    blocks[k] = v
  end
  local refs = M.collect_references(lines)
  local entries, done = {}, {}
  for _, r in ipairs(refs) do
    if r.label and not r.text and not done[r.label] then
      done[r.label] = true
      entries[#entries + 1] = {
        block = blocks[r.label] or { "[fn:" .. r.label .. "] DEFINITION NOT FOUND." },
        ref_lnum = r.lnum,
      }
    end
  end
  for _, label in ipairs(order) do
    if not done[label] then
      done[label] = true
      entries[#entries + 1] = { block = blocks[label] }
    end
  end
  return insert_definitions(lines, entries)
end

local function buffer_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function set_buffer(bufnr, lines)
  local view = vim.fn.winsaveview()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.fn.winrestview(view)
end

--- Rearrange definitions to follow the order of the references
--- (org-footnote-sort). Inline footnotes are left alone.
function M.sort(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  set_buffer(bufnr, sort_lines(buffer_lines(bufnr)))
end

--- Renumber `fn:N` footnotes 1, 2, ... in order of first reference
--- (org-footnote-renumber-fn:N).
function M.renumber(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local lines = buffer_lines(bufnr)
  local map, n = {}, 0
  for _, r in ipairs(M.collect_references(lines)) do
    if r.label and r.label:match("^%d+$") and not map[r.label] then
      n = n + 1
      map[r.label] = tostring(n)
    end
  end
  for _, d in ipairs(M.collect_definitions(lines)) do
    if d.label:match("^%d+$") and not map[d.label] then
      n = n + 1
      map[d.label] = tostring(n)
    end
  end
  for i, l in ipairs(lines) do
    lines[i] = l:gsub("%[fn:(%d+)([%]:])", function(num, c)
      return "[fn:" .. (map[num] or num) .. c
    end)
  end
  set_buffer(bufnr, lines)
end

--- Turn every footnote into a numbered one with a regular definition,
--- numbered in order of reference, then sort (org-footnote-normalize).
function M.normalize(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local lines = buffer_lines(bufnr)
  local refs = M.collect_references(lines)
  local map, n, extra = {}, 0, {}
  local new_label = {}
  for i, r in ipairs(refs) do
    if not r.label then
      n = n + 1
      new_label[i] = tostring(n)
    else
      if not map[r.label] then
        n = n + 1
        map[r.label] = tostring(n)
      end
      new_label[i] = map[r.label]
    end
    if r.text then
      extra[new_label[i]] = { "[fn:" .. new_label[i] .. "] " .. vim.trim(r.text) }
    end
  end
  -- rewrite references right to left within each line
  for i = #refs, 1, -1 do
    local r = refs[i]
    local l = lines[r.lnum]
    lines[r.lnum] = l:sub(1, r.s - 1) .. "[fn:" .. new_label[i] .. "]" .. l:sub(r.e + 1)
  end
  -- relabel definitions; unreferenced ones get the next numbers
  for _, d in ipairs(M.collect_definitions(lines)) do
    if not map[d.label] then
      n = n + 1
      map[d.label] = tostring(n)
    end
    local l = lines[d.start]
    lines[d.start] = "[fn:" .. map[d.label] .. "]" .. l:sub(#("[fn:" .. d.label .. "]") + 1)
  end
  set_buffer(bufnr, sort_lines(lines, extra))
end

--- Delete the footnote at the cursor, or `label`: every reference and
--- definition (org-footnote-delete). An anonymous inline footnote is just
--- removed.
function M.delete(bufnr, label)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not label then
    local fn = M.at_point()
    if not fn then
      utils.warn("Don't know which footnote to remove")
      return
    end
    if not fn.label then
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      local l = vim.api.nvim_get_current_line()
      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { l:sub(1, fn.start_col - 1) .. l:sub(fn.end_col + 1) })
      utils.notify("Anonymous footnote removed")
      return
    end
    label = fn.label
  end
  local lines = buffer_lines(bufnr)
  local nref = 0
  local refs = M.collect_references(lines)
  for i = #refs, 1, -1 do
    local r = refs[i]
    if r.label == label then
      local l = lines[r.lnum]
      lines[r.lnum] = l:sub(1, r.s - 1) .. l:sub(r.e + 1)
      nref = nref + 1
    end
  end
  local ndef = 0
  local defs = M.collect_definitions(lines)
  for i = #defs, 1, -1 do
    local d = defs[i]
    if d.label == label then
      local stop = d.stop
      local prev = lines[d.start - 1]
      local glued = prev == nil or is_blank(prev) or require("org.parser").headline_level(prev) ~= nil
      while glued and lines[stop + 1] and is_blank(lines[stop + 1]) do
        stop = stop + 1
      end
      for j = stop, d.start, -1 do
        table.remove(lines, j)
      end
      ndef = ndef + 1
    end
  end
  set_buffer(bufnr, lines)
  utils.notify(string.format("%d definition(s) of and %d reference(s) of footnote %s removed", ndef, nref, label))
end

--- Footnote maintenance menu (org-footnote-action with C-u).
function M.menu()
  local choice = require("org.ui").menu({
    title = "Footnotes",
    items = {
      { key = "s", label = "Sort definitions", value = "s" },
      { key = "r", label = "Renumber fn:N labels", value = "r" },
      { key = "S", label = "Renumber and sort", value = "S" },
      { key = "n", label = "Normalize (number all, inline → regular)", value = "n" },
      { key = "d", label = "Delete footnote at point", value = "d" },
    },
  })
  if choice == "s" then
    M.sort()
  elseif choice == "r" then
    M.renumber()
  elseif choice == "S" then
    M.renumber()
    M.sort()
  elseif choice == "n" then
    M.normalize()
  elseif choice == "d" then
    M.delete()
  end
end

--- Do the right thing for footnotes (org-footnote-action): jump between
--- reference and definition, else create a new footnote. With a count,
--- show the maintenance menu.
function M.footnote_action()
  if vim.v.count > 0 then
    return M.menu()
  end
  if M.at_point() then
    return M.action_at_point()
  end
  return M.new_footnote()
end

return M

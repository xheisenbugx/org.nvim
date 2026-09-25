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
  local ok, file = pcall(require("org.files").get_buffer, 0)
  if ok and file.settings.startup and file.settings.startup.fnlocal then
    return nil
  end
  local s = require("org.config").opts.footnote_section
  if s == nil then
    return M.section_title
  end
  return s or nil
end

local function is_blank(l)
  return l == nil or l:match("^%s*$") ~= nil
end

--- Whether `blank_before_new_entry.heading` is on ("auto" counts), which
--- org-back-over-empty-lines and the footnote section creation look at.
local function heading_blank_setting()
  local b = require("org.config").opts.blank_before_new_entry
  local v = type(b) == "table" and b.heading or b
  return v ~= nil and v ~= false
end

--- Pattern for the footnote section headline.
local function section_line_p(line, name)
  local title = line:match("^%*+[ \t]+(.-)[ \t]*$")
  return title ~= nil and title == name
end

--- org-back-over-empty-lines on textbuf `tb`: move back to the first
--- empty line before point and return how many were passed.
local function tb_back_over_empty_lines(tb)
  local pos = tb.point
  if heading_blank_setting() then
    tb:skip_backward(" \t\n\r")
  elseif not tb:eobp() then
    tb:forward_line(-1)
  end
  tb:forward_line(1)
  tb:goto(math.min(tb.point, pos))
  local n = 0
  local p = tb.point
  while p < pos do
    local nl = tb.text:find("\n", p, true)
    if not nl or nl >= pos then
      break
    end
    n = n + 1
    p = nl + 1
  end
  return n
end

--- org-footnote--clear-footnote-section: remove every footnote section
--- and create a new one at the end of the buffer; point after it.
local function tb_clear_section(tb, name)
  local parser = require("org.parser")
  local lines = tb:lines()
  local i = 1
  local out = {}
  while i <= #lines do
    local l = lines[i]
    local lvl = parser.headline_level(l)
    if lvl and section_line_p(l, name) then
      local j = i + 1
      while j <= #lines do
        local lv = parser.headline_level(lines[j])
        if lv and lv <= lvl then
          break
        end
        j = j + 1
      end
      i = j
    else
      out[#out + 1] = l
      i = i + 1
    end
  end
  while #out > 0 and is_blank(out[#out]) do
    table.remove(out)
  end
  local text = table.concat(out, "\n")
  if #out > 0 then
    text = text .. "\n"
  end
  tb.text = text
  tb:goto(tb:point_max())
  if heading_blank_setting() then
    local save = tb.point
    if tb_back_over_empty_lines(tb) == 0 then
      tb:goto(save)
      tb:insert("\n")
    else
      tb:goto(save)
    end
  end
  tb:insert("* " .. name .. "\n")
end

--- org-footnote--goto-local-insertion-point: just before the next
--- headline, after the last non-blank line.
local function tb_local_insertion_point(tb)
  local parser = require("org.parser")
  local p = tb:line_beg()
  local target = tb:point_max()
  while true do
    local nl = tb.text:find("\n", p, true)
    if not nl or nl + 1 > #tb.text then
      break
    end
    p = nl + 1
    if parser.headline_level(tb:line(p)) then
      target = p
      break
    end
  end
  tb:goto(target)
  tb:skip_backward(" \t\n")
  if not tb:bobp() then
    tb:forward_line(1)
  end
  if not tb:bolp() then
    tb:insert("\n")
  end
end

--- Move after the planning line, drawers, clock lines and blank lines of
--- the headline at point (org-end-of-meta-data with FULL = t).
local function tb_end_of_meta_data(tb)
  tb:forward_line(1)
  local l = tb:line()
  if l:match("^%s*SCHEDULED:") or l:match("^%s*DEADLINE:") or l:match("^%s*CLOSED:") then
    tb:forward_line(1)
  end
  local parser = require("org.parser")
  while not tb:eobp() do
    l = tb:line()
    if parser.headline_level(l) then
      break
    elseif l:match("^%s*$") or l:match("^%s*CLOCK:") then
      tb:forward_line(1)
    elseif l:match("^%s*:[%w_%-]+:%s*$") then
      local found = false
      local p = tb.point
      while true do
        local nl = tb.text:find("\n", p, true)
        if not nl or nl + 1 > #tb.text then
          break
        end
        p = nl + 1
        local ln = tb:line(p)
        if parser.headline_level(ln) then
          break
        end
        if ln:match("^%s*:[Ee][Nn][Dd]:%s*$") then
          tb:goto(p)
          tb:forward_line(1)
          found = true
          break
        end
      end
      if not found then
        break
      end
    else
      break
    end
  end
end

--- Create a definition for `label` (org-footnote-create-definition): at
--- the top of the footnote section (created at the end of the buffer when
--- missing), or at the end of the section containing `ref_lnum` when
--- `footnote_section` is false. Returns the definition's line.
function M.create_definition(bufnr, label, ref_lnum)
  local name = section_name()
  local tb = require("org.textbuf").from_buffer(bufnr, { ref_lnum or 1, 0 })
  if not name then
    tb_local_insertion_point(tb)
  else
    local found
    local p = 1
    while p <= #tb.text do
      if section_line_p(tb:line(p), name) then
        found = p
        break
      end
      local nl = tb.text:find("\n", p, true)
      if not nl then
        break
      end
      p = nl + 1
    end
    if found then
      tb:goto(found)
      tb_end_of_meta_data(tb)
      if not tb:bolp() then
        tb:insert("\n")
      end
    else
      tb_clear_section(tb, name)
    end
  end
  if tb_back_over_empty_lines(tb) == 0 then
    tb:insert("\n")
  end
  local def_pos = tb.point
  tb:insert("[fn:" .. label .. "] \n")
  tb:apply(false)
  return (tb:rowcol(def_pos))
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

--- Every footnote label used in the buffer (org-footnote-all-labels).
function M.all_labels(bufnr)
  local seen, out = {}, {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr or 0, 0, -1, false)) do
    for label in l:gmatch("%[fn:([^%]:%s]+)[%]:]") do
      if not seen[label] then
        seen[label] = true
        out[#out + 1] = label
      end
    end
  end
  return out
end

--- The first unused numeric label (org-footnote-unique-label).
function M.next_label(bufnr)
  local used = {}
  for _, l in ipairs(M.all_labels(bufnr)) do
    used[l] = true
  end
  local n = 1
  while used[tostring(n)] do
    n = n + 1
  end
  return tostring(n)
end

--- A footnote option, `#+STARTUP` words first: "label" (auto label),
--- "adjust", "inline" or "section".
function M.option(bufnr, what)
  local cfg = require("org.config").opts
  local ok, file = pcall(require("org.files").get_buffer, bufnr or 0)
  local st = ok and file.settings.startup or {}
  if what == "label" then
    if st.fnauto then
      return true
    elseif st.fnprompt then
      return false
    elseif st.fnconfirm then
      return "confirm"
    elseif st.fnplain then
      return "plain"
    elseif st.fnanon then
      return "anonymous"
    end
    return cfg.footnote_auto_label
  elseif what == "adjust" then
    if st.fnadjust then
      return true
    elseif st.nofnadjust then
      return false
    end
    return cfg.footnote_auto_adjust
  elseif what == "inline" then
    if st.fninline then
      return true
    elseif st.nofninline then
      return false
    end
    return cfg.footnote_define_inline
  end
end

--- Renumber and / or sort after an insertion or deletion
--- (org-footnote-auto-adjust-maybe).
local function auto_adjust(bufnr)
  local v = M.option(bufnr, "adjust")
  if v == true or v == "renumber" then
    M.renumber(bufnr)
  end
  if v == true or v == "sort" then
    M.sort(bufnr)
  end
end

--- Insert a new footnote after the cursor (org-footnote-new). The label
--- follows `footnote_auto_label` (a prompt offers the existing labels; an
--- existing one only adds a reference); the definition goes in the
--- footnote section, or inline with `footnote_define_inline`.
---@param opts? { no_insert?: boolean }
function M.new_footnote(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local mode = M.option(bufnr, "label")
  local all = M.all_labels(bufnr)
  local label
  if mode == "anonymous" then
    label = nil
  elseif mode == "random" then
    label = string.format("%x", math.random(0, 0x7fffffff))
  elseif mode == true or mode == "plain" or mode == nil then
    label = M.next_label(bufnr)
  else
    local answer = utils.input({
      prompt = "Label (leave empty for anonymous): ",
      default = mode == "confirm" and M.next_label(bufnr) or nil,
    })
    if answer == nil then
      return
    end
    answer = vim.trim(answer):gsub("^fn:", "")
    label = answer ~= "" and answer or nil
  end
  local row, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local at = line == "" and 0 or math.min(col0 + 1, #line)
  local function put(ref, cursor_offset)
    vim.api.nvim_set_current_line(line:sub(1, at) .. ref .. line:sub(at + 1))
    vim.api.nvim_win_set_cursor(0, { row, at + cursor_offset })
    if not opts.no_insert and not vim.g.org_test then
      vim.cmd("startinsert")
    end
  end
  if not label then
    put("[fn::]", 5)
    return nil, row
  end
  if vim.tbl_contains(all, label) then
    put("[fn:" .. label .. "]", #label + 5)
    utils.notify("New reference to existing note")
    return label, row
  end
  if M.option(bufnr, "inline") then
    put("[fn:" .. label .. ":]", #label + 5)
    auto_adjust(bufnr)
    return label, row
  end
  vim.api.nvim_set_current_line(line:sub(1, at) .. "[fn:" .. label .. "]" .. line:sub(at + 1))
  M.create_definition(bufnr, label, row)
  auto_adjust(bufnr)
  local target = find_definition(bufnr, label)
  local def = "[fn:" .. label .. "] "
  vim.cmd("normal! m'")
  local l = vim.api.nvim_buf_get_lines(bufnr, target - 1, target, false)[1]
  vim.api.nvim_win_set_cursor(0, { target, math.min(#def, #l) })
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

--- Insert definition blocks like org-footnote-sort: the footnote sections
--- are removed and one is created at the end of the buffer with every
--- definition, each after a blank line; with `footnote_section` false,
--- each goes at the end of the outline section of its first reference.
---@param entries { block: string[], ref_lnum: integer|nil }[]
local function insert_definitions(lines, entries)
  local name = section_name()
  local text = table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
  local tb = setmetatable({ text = text, point = 1 }, require("org.textbuf"))
  if name then
    tb_clear_section(tb, name)
    for _, en in ipairs(entries) do
      tb:insert("\n" .. table.concat(en.block, "\n") .. "\n")
    end
  else
    local last
    for _, en in ipairs(entries) do
      if en.ref_lnum then
        tb:goto(tb:pos_of(en.ref_lnum, 0))
        tb_local_insertion_point(tb)
        -- later references move down with the inserted lines
        local row = tb:rowcol()
        local block = "\n" .. table.concat(en.block, "\n") .. "\n"
        local added = select(2, block:gsub("\n", ""))
        tb:insert(block)
        for _, other in ipairs(entries) do
          if other ~= en and other.ref_lnum and other.ref_lnum >= row then
            other.ref_lnum = other.ref_lnum + added
          end
        end
        last = tb.point
      end
    end
    tb:goto(last or tb:point_max())
    for _, en in ipairs(entries) do
      if not en.ref_lnum then
        tb:insert("\n" .. table.concat(en.block, "\n") .. "\n")
      end
    end
  end
  return tb:lines()
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
  auto_adjust(bufnr)
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

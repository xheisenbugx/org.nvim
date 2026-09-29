---@mod org.fill Filling paragraphs ('formatexpr')
---
--- A port of org-fill-paragraph for `gq` / `gw`: paragraphs (also inside
--- list items, drawers, quote blocks and footnote definitions), comments
--- and the contents of comment blocks are filled; tables are realigned;
--- headlines, keywords, other blocks, drawers' markers, planning and clock
--- lines are left alone. Filling follows Emacs: continuation lines of an
--- item start at its body column, a sentence end ([.?!]) at the end of a
--- joined line gets two spaces, lines are not broken after a period
--- followed by a single space, before text that would start a new element
--- (a bullet, `#`, `|`, ...), after `\\` or inside a timestamp, and
--- line breaks (`\\` at the end of a line) are kept.

local parser = require("org.parser")

local M = {}

local function is_blank(l)
  return l == nil or l:match("^%s*$") ~= nil
end

--- The fill column: 'textwidth', or 79 (like `gq`) when it is 0.
local function fill_column()
  local tw = vim.bo.textwidth
  if tw > 0 then
    return tw
  end
  return math.min(79, math.max(vim.api.nvim_win_get_width(0) - 1, 1))
end

local SENTENCE_END = "[.?!][%]%)}\"']*$"

--- Whether text starting with `s` would begin a new element
--- (org-element-paragraph-separate as 'paragraph-start').
local function starts_element(s)
  return s:match("^%*+ ") ~= nil
    or s:match("^%[fn:[%w_%-]+%]") ~= nil
    or s:match("^%%%%%(") ~= nil
    or s:match("^|") ~= nil
    or s:match("^%+%-+%+") ~= nil
    or s:match("^#$") ~= nil
    or s:match("^# ") ~= nil
    or s:match("^#%+[Bb][Ee][Gg][Ii][Nn]_%S") ~= nil
    or s:match("^#%+%S-:") ~= nil
    or s:match("^:$") ~= nil
    or s:match("^: ") ~= nil
    or s:match("^:[%w_%-]+:$") ~= nil
    or s:match("^%-%-%-%-%-+$") ~= nil
    or s:match("^\\begin{") ~= nil
    or s:match("^CLOCK:") ~= nil
    or s:match("^[-+*]$") ~= nil
    or s:match("^[-+*] ") ~= nil
    or s:match("^%d+[.)]$") ~= nil
    or s:match("^%d+[.)] ") ~= nil
end

--- Byte ranges of timestamps in `text`.
local function timestamp_spans(text)
  local spans = {}
  for _, pat in ipairs({ "()<%d%d%d%d%-%d%d%-%d%d[^>\n]*>()", "()%[%d%d%d%d%-%d%d%-%d%d[^%]\n]*%]()" }) do
    for s, e in text:gmatch(pat) do
      spans[#spans + 1] = { s, e - 1 }
    end
  end
  return spans
end

--- Fill `text` (a paragraph joined into one line, the part after the
--- first line's `head`) into lines no longer than `width`.
---@param head string text before the paragraph on its first line
---@param prefix string fill prefix of the other lines
---@param lines string[] the paragraph lines, first without `head`
---@return string[]
function M.fill_lines(head, prefix, lines, width)
  -- join the lines (fill-delete-newlines): two spaces after a sentence end
  local text = ""
  for i, l in ipairs(lines) do
    l = l:gsub("%s+$", "")
    if i > 1 then
      l = l:gsub("^%s+", "")
      if l ~= "" then
        text = text .. (text:match(SENTENCE_END) and "  " or " ")
      end
    end
    text = text .. l
  end
  text = text:gsub("^%s+", "")
  -- canonically-space-region: one space between words, two after a
  -- sentence end followed by two
  local words = {}
  local pos = 1
  while pos <= #text do
    local ws, we = text:find("[ \t]+", pos)
    local word = text:sub(pos, (ws or #text + 1) - 1)
    local spaces = ws and (we - ws + 1) or 0
    local start = pos
    if ws then
      spaces = (spaces >= 2 and word:match(SENTENCE_END)) and 2 or 1
    end
    words[#words + 1] = { word = word, spaces = spaces, start = start, stop = start + #word - 1 }
    pos = ws and we + 1 or #text + 1
  end
  local spans = timestamp_spans(text)
  --- May the line break between words[k] and words[k + 1]?
  local function can_break(k)
    local w, nxt = words[k], words[k + 1]
    if w.word:match("%.$") and w.spaces == 1 then
      return false -- sentence-end-double-space
    end
    local rest = text:sub(nxt.start)
    if starts_element(rest) then
      return false
    end
    if w.word:match("\\\\$") and not w.word:match("\\\\\\$") then
      return false -- would create a line break
    end
    for _, sp in ipairs(spans) do
      if w.stop >= sp[1] and nxt.start > sp[1] and nxt.start <= sp[2] then
        return false -- inside a timestamp
      end
    end
    return true
  end
  local out = {}
  local k = 1
  local lead = head
  while k <= #words do
    -- words k..j fit on this line
    local col = vim.fn.strdisplaywidth(lead)
    local j = k
    local len = col + vim.fn.strdisplaywidth(words[k].word)
    while j < #words do
      local add = words[j].spaces + vim.fn.strdisplaywidth(words[j + 1].word)
      if len + add > width then
        break
      end
      len = len + add
      j = j + 1
    end
    if j < #words then
      -- move back to a place where breaking is allowed, else forward
      local b = j
      while b >= k and not can_break(b) do
        b = b - 1
      end
      if b < k then
        b = j + 1
        while b < #words and not can_break(b) do
          b = b + 1
        end
      end
      j = b
    end
    local parts = {}
    for m = k, j do
      parts[#parts + 1] = words[m].word
      if m < j then
        parts[#parts + 1] = string.rep(" ", words[m].spaces)
      end
    end
    out[#out + 1] = (lead .. table.concat(parts)):gsub("%s+$", "")
    lead = prefix
    k = j + 1
  end
  if #out == 0 then
    out[1] = (head:gsub("%s+$", ""))
  end
  return out
end

local function leading(l)
  return (l or ""):match("^[ \t]*")
end

--- Fill prefix from the paragraph's first two lines (fill-context-prefix,
--- whitespace only).
local function context_prefix(lines)
  if #lines >= 2 then
    return leading(lines[2])
  end
  return leading(lines[1])
end

--- The part of an item's first line before its paragraph: indentation,
--- bullet, counter, checkbox and description tag.
local function item_head(line)
  local head = line:match("^%s*%S+%s*")
  local rest = line:sub(#head + 1)
  local counter = rest:match("^%[@[%w]+%]%s*")
  if counter then
    head, rest = head .. counter, rest:sub(#counter + 1)
  end
  local cb = rest:match("^%[[ xX%-]%]%s+") or rest:match("^%[[ xX%-]%]$")
  if cb then
    head, rest = head .. cb, rest:sub(#cb + 1)
  end
  local tag = rest:match("^.-%s::%s+") or rest:match("^.-%s::$")
  if tag then
    head = head .. tag
  end
  return head
end

--- Replace buffer lines [s, e] with `new` when different.
local function replace(bufnr, s, e, new)
  local old = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  if not vim.deep_equal(old, new) then
    vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, new)
  end
  return #new - #old
end

--- Fill buffer lines [s, e] as one paragraph, cutting at line breaks.
local function fill_paragraph(bufnr, s, e, head_of_first, prefix, width)
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  -- segments end at `\\` line breaks
  local segs, cur = {}, {}
  for i, l in ipairs(lines) do
    cur[#cur + 1] = l
    if l:match("\\\\%s*$") and not l:match("\\\\\\%s*$") and i < #lines then
      segs[#segs + 1] = cur
      cur = {}
    end
  end
  segs[#segs + 1] = cur
  local out = {}
  for n, seg in ipairs(segs) do
    local head
    if n == 1 then
      head = head_of_first
    else
      head = leading(seg[1])
      head = prefix ~= "" and prefix or head
    end
    local first = seg[1]:sub(#head + 1)
    if n > 1 then
      first = seg[1]:gsub("^%s+", "")
    end
    local body = { first }
    for i = 2, #seg do
      local l = seg[i]
      if prefix ~= "" and l:sub(1, #prefix) == prefix then
        l = l:sub(#prefix + 1)
      end
      body[#body + 1] = l
    end
    vim.list_extend(out, M.fill_lines(head, prefix, body, width))
  end
  return replace(bufnr, s, e, out)
end

--- Runs of lines of [s, e] that are not separators, as { first, last }.
local function runs(lines, s, separator)
  local out = {}
  local i = 1
  while i <= #lines do
    if separator(lines[i]) then
      i = i + 1
    else
      local j = i
      while j + 1 <= #lines and not separator(lines[j + 1]) do
        j = j + 1
      end
      out[#out + 1] = { s + i - 1, s + j - 1, vim.list_slice(lines, i, j) }
      i = j + 1
    end
  end
  return out
end

local function overlaps(a, b, from, to)
  return b >= from and a <= to
end

--- The section containing `lnum`, parsed into elements, with the buffer
--- line offset of its local lines; nil on a headline.
local function section(bufnr, lnum)
  local file = require("org.files").get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  local from, to
  if hl then
    if hl.line == lnum then
      return nil
    end
    from, to = hl.line + 1, hl.body_end
  else
    from, to = 1, file.preamble_end
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, from - 1, to, false)
  local i = 1
  local first = lines[1] or ""
  if hl and (first:match("^%s*SCHEDULED:") or first:match("^%s*DEADLINE:") or first:match("^%s*CLOSED:")) then
    i = 2
  end
  local els = i <= #lines and require("org.element").parse(lines, i, #lines) or {}
  return els, from - 1, to
end

--- Fill jobs for the elements of `els` overlapping [from, to]:
--- { s, e, run(bufnr, width) -> line delta }.
local function collect(bufnr, els, off, from, to, jobs)
  for _, el in ipairs(els) do
    local s, e = el.first + off, el.clast + off
    if overlaps(s, e, from, to) then
      local t = el.type
      if t == "paragraph" then
        local ps = el.post + off
        jobs[#jobs + 1] = {
          ps,
          e,
          function(width)
            local lines = vim.api.nvim_buf_get_lines(bufnr, ps - 1, e, false)
            local parent = el.parent
            local head, prefix
            if parent and parent.type == "item" then
              local it = parent.list_item
              prefix = string.rep(" ", it.indent + #it.bullet + 1)
              head = el.first == parent.first and item_head(lines[1]) or leading(lines[1])
            elseif parent and parent.type == "footnote-definition" and el.first == parent.first then
              head = lines[1]:match("^%[fn:[^%]]*%]%s*")
              prefix = #lines >= 2 and leading(lines[2]) or ""
            else
              head = leading(lines[1])
              prefix = context_prefix(lines)
            end
            return fill_paragraph(bufnr, ps, e, head, prefix, width)
          end,
        }
      elseif t == "comment" then
        -- the comment paragraphs (between `#` lines) overlapping the range
        local lines = vim.api.nvim_buf_get_lines(bufnr, el.post + off - 1, e, false)
        for _, r in
          ipairs(runs(lines, el.post + off, function(l)
            return l:match("^%s*#%s*$") ~= nil
          end))
        do
          if overlaps(r[1], r[2], from, to) then
            jobs[#jobs + 1] = {
              r[1],
              r[2],
              function(width)
                local mark = r[3][1]:match("^[ \t]*#")
                local after = r[3][1]:sub(#mark + 1):match("^[ \t]*")
                local prefix = mark .. (after ~= "" and after or " ")
                local body = {}
                for k, l in ipairs(r[3]) do
                  body[k] = (l:gsub("^[ \t]*#", "", 1))
                end
                return replace(bufnr, r[1], r[2], M.fill_lines(prefix, prefix, body, width))
              end,
            }
          end
        end
      elseif t == "comment-block" then
        -- the text between blank lines of the contents
        if el.clast - 1 >= el.post + 1 then
          local cs = el.post + 1 + off
          local lines = vim.api.nvim_buf_get_lines(bufnr, cs - 1, el.clast - 1 + off, false)
          -- on the #+end line, the text just above it
          local on_end = from <= el.clast + off and to >= el.clast + off
          for _, r in ipairs(runs(lines, cs, is_blank)) do
            if overlaps(r[1], r[2], from, to) or (on_end and r[2] == el.clast - 1 + off) then
              jobs[#jobs + 1] = {
                r[1],
                r[2],
                function(width)
                  return fill_paragraph(bufnr, r[1], r[2], leading(r[3][1]), context_prefix(r[3]), width)
                end,
              }
            end
          end
        end
      elseif t == "table" then
        if el.cfirst then
          jobs[#jobs + 1] = {
            el.post + off,
            e,
            function()
              require("org.table").align_at(bufnr, el.post + off)
              return 0
            end,
          }
        end
      elseif el.greater and el.children and #el.children > 0 then
        collect(bufnr, el.children, off, from, to, jobs)
      end
    end
  end
end

--- Fill the elements of buffer lines [from, to] (org-fill-paragraph with
--- a region): paragraphs, comments and comment blocks are filled, tables
--- realigned. Returns the last line of the filled text.
---@param bufnr integer
---@param from integer
---@param to integer
---@return integer
function M.fill_region(bufnr, from, to)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local width = fill_column()
  to = math.min(to, vim.api.nvim_buf_line_count(bufnr))
  local jobs = {}
  local l = from
  while l <= to do
    local els, off, send = section(bufnr, l)
    if els then
      collect(bufnr, els, off, from, to, jobs)
      l = send + 1
    else
      l = l + 1
    end
  end
  -- bottom up, so that line numbers above stay valid
  table.sort(jobs, function(a, b)
    return a[1] > b[1]
  end)
  local last
  for _, job in ipairs(jobs) do
    local delta = job[3](width)
    if last then
      last = last + delta
    else
      last = job[2] + delta
    end
  end
  return last or to
end

--- 'formatexpr' of org buffers: `gq` fills like org-fill-paragraph.
--- Automatic wrapping while typing (formatoptions `t`) is left to Vim,
--- except where Emacs does not auto-fill (headlines, keywords, tables,
--- blocks...).
function M.formatexpr()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum, count = vim.v.lnum, vim.v.count
  if vim.fn.mode():match("^[iR]") then
    return M.auto_fill_allowed(bufnr, lnum) and 1 or 0
  end
  local to = lnum + math.max(count, 1) - 1
  if lnum == to then
    -- on a blank line, fill the element after it
    local total = vim.api.nvim_buf_line_count(bufnr)
    while lnum < total and is_blank(vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]) do
      lnum = lnum + 1
    end
    to = lnum
  end
  local ok, last = pcall(M.fill_region, bufnr, lnum, to)
  if not ok then
    require("org.utils").error("fill: " .. tostring(last))
    return 0
  end
  last = math.max(1, math.min(last, vim.api.nvim_buf_line_count(bufnr)))
  local text = vim.api.nvim_buf_get_lines(bufnr, last - 1, last, false)[1]
  vim.api.nvim_win_set_cursor(0, { last, #text:match("^%s*") })
  return 0
end

--- Whether typing past 'textwidth' on line `lnum` may wrap it
--- (org-auto-fill-function: org-adaptive-fill-function gives a prefix).
function M.auto_fill_allowed(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  if parser.headline_level(line) then
    return false
  end
  local els, off = section(bufnr, lnum)
  if not els then
    return false
  end
  local found
  local function walk(list)
    for _, el in ipairs(list) do
      if el.first + off <= lnum and lnum <= el.last + off then
        found = el
        if el.children and #el.children > 0 then
          walk(el.children)
        end
        return
      end
    end
  end
  walk(els)
  if not found or lnum < found.post + off then
    return false
  end
  local t = found.type
  if t == "comment-block" then
    return lnum > found.post + off and lnum < found.clast + off
  end
  return t == "paragraph" or t == "comment" or t == "item" or t == "plain-list" or t == "footnote-definition"
end

return M

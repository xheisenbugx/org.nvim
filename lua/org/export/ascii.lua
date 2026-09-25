---@mod org.export.ascii Plain text back-end (port of Emacs ox-ascii.el)
---
--- Text is written with the `ascii`, `latin1` or `utf-8` charset
--- (`export.ascii.charset`, Emacs `org-ascii-charset`). Paragraphs are
--- filled like Emacs `fill-region` (two spaces after sentences, adaptive
--- fill prefixes, centered/right justification with tabs).

local ox = require("org.export.ox")
local element = require("org.export.element")
local entities = require("org.export.entities")

local M = {}

M.extension = "txt"

local fmt = string.format
local nw = ox.nw

--- Marker for a hard newline (line breaks, preserved breaks). Filling
--- never joins lines across it; it becomes "\n" once filled.
local HARD = "\1"
M.HARD = HARD

local function acfg()
  return (require("org.config").opts.export or {}).ascii or {}
end

local function charset(info)
  local c = info.ascii_charset or "ascii"
  if c == "utf8" then
    c = "utf-8"
  end
  return c
end

local function utf8p(info)
  return charset(info) == "utf-8"
end

---------------------------------------------------------------------------
-- Characters and columns
---------------------------------------------------------------------------

local CHAR_PAT = "[%z\1-\127\194-\244][\128-\191]*"

local function chars(s)
  local out = {}
  for ch in s:gmatch(CHAR_PAT) do
    out[#out + 1] = ch
  end
  return out
end

local width_cache = {}
local function cwidth(ch)
  local w = width_cache[ch]
  if not w then
    if ch == "\n" then
      w = 0
    elseif #ch == 1 and ch:byte() < 32 then
      w = ch == HARD and 0 or 2
    else
      w = vim.api.nvim_strwidth(ch)
    end
    width_cache[ch] = w
  end
  return w
end

--- string-width (no tabs expected).
local function swidth(s)
  if s == nil or s == "" then
    return 0
  end
  local w = 0
  for ch in s:gmatch(CHAR_PAT) do
    w = w + cwidth(ch)
  end
  return w
end
M.string_width = swidth

local function trim(s)
  return (s:gsub("^[ \t\n\r]+", ""):gsub("[ \t\n\r]+$", ""))
end

--- Column reached after the chars of B from `from` (a line start) up to `to` (exclusive).
local function column_between(B, from, to)
  local c = 0
  for i = from, to - 1 do
    local ch = B[i]
    if ch == "\t" then
      c = c + 8 - (c % 8)
    else
      c = c + cwidth(ch)
    end
  end
  return c
end

local function bol(B, pos)
  local p = pos
  while p > 1 and B[p - 1] ~= "\n" do
    p = p - 1
  end
  return p
end

local function eol(B, pos)
  local p = pos
  local n = #B
  while p <= n and B[p] ~= "\n" do
    p = p + 1
  end
  return p
end

local function insert_chars(B, pos, list)
  for i = #list, 1, -1 do
    table.insert(B, pos, list[i])
  end
  return #list
end

local function delete_range(B, a, b)
  -- delete chars in [a, b)
  for _ = a, b - 1 do
    table.remove(B, a)
  end
  return b - a
end

--- Whitespace inserted by `indent-to` from column FROMCOL to TOCOL.
local function indent_chars(fromcol, tocol, tabs)
  local out = {}
  if tocol <= fromcol then
    return out
  end
  local c = fromcol
  if tabs then
    local n = math.floor(tocol / 8) - math.floor(fromcol / 8)
    for _ = 1, n do
      out[#out + 1] = "\t"
    end
    if n > 0 then
      c = math.floor(tocol / 8) * 8
    end
  end
  for _ = c + 1, tocol do
    out[#out + 1] = " "
  end
  return out
end

local function trunc_div(a, b)
  local q = a / b
  if q >= 0 then
    return math.floor(q)
  end
  return math.ceil(q)
end

---------------------------------------------------------------------------
-- Filling (fill.el)
---------------------------------------------------------------------------

local ADAPTIVE = {
  ["-"] = true,
  ["–"] = true,
  ["!"] = true,
  ["|"] = true,
  ["#"] = true,
  ["%"] = true,
  [";"] = true,
  [">"] = true,
  ["*"] = true,
  ["·"] = true,
  ["•"] = true,
  ["‣"] = true,
  ["⁃"] = true,
  ["◦"] = true,
  [" "] = true,
  ["\t"] = true,
}

local SENTENCE_PUNCT = { ["."] = true, ["?"] = true, ["!"] = true, ["…"] = true, ["‽"] = true }
local CLOSERS = {
  ["]"] = true,
  ['"'] = true,
  ["'"] = true,
  ["”"] = true,
  ["’"] = true,
  [")"] = true,
  ["}"] = true,
  ["»"] = true,
  ["›"] = true,
}
-- characters skipped backward by canonically-space-region
local SKIP_BACK = { [" "] = true, ["]"] = true, ["}"] = true, [")"] = true, ['"'] = true, ["'"] = true }
local NBSP = "\194\160"
local CJK_END = { ["。"] = true, ["．"] = true, ["？"] = true, ["！"] = true }

local function is_sp(ch)
  return ch == " " or ch == "\t"
end

--- Length (chars) of the adaptive-fill-regexp match at pos.
local function adaptive_match(B, pos, limit)
  local p = pos
  limit = limit or #B + 1
  while p < limit and ADAPTIVE[B[p]] do
    p = p + 1
  end
  return p - pos
end

--- fill-match-adaptive-prefix at line start pos.
local function match_adaptive_prefix(B, pos, fc)
  local e = eol(B, pos)
  local n = adaptive_match(B, pos, e)
  if n >= fc then
    return nil
  end
  return table.concat(B, "", pos, pos + n - 1)
end

--- fill-context-prefix
local function context_prefix(B, from, to, fc)
  local p = from
  if B[p] == "\n" then
    p = p + 1
  end
  local first = match_adaptive_prefix(B, p, fc)
  local e = eol(B, p)
  local q = e + 1
  if q < to then
    local line = table.concat(B, "", q, eol(B, q) - 1)
    local second
    if line:match("^\f") or line:match("^[ \t]*$") then
      second = nil
    else
      second = match_adaptive_prefix(B, q, fc)
    end
    if second then
      first = first or ""
      -- the non-blank runs of the second prefix must appear in the first
      local pos = 1
      local ok = true
      for run in second:gmatch("[^ \t]+") do
        local a, b = first:find(run, pos, true)
        if not a then
          ok = false
          break
        end
        pos = b + 1
      end
      if ok then
        return second
      end
      local fc_ = chars(first)
      local sc = chars(second)
      local i = 1
      while i <= #fc_ and i <= #sc and fc_[i] == sc[i] do
        i = i + 1
      end
      if i == 1 then
        return nil
      end
      return table.concat(fc_, "", 1, i - 1)
    end
    return nil
  end
  if first then
    local result
    if first:match("^[ \t]*$") then
      result = first
    else
      result = string.rep(" ", swidth(first))
    end
    if (result .. "a"):match("^\f") then
      return nil
    end
    return result
  end
  return nil
end

--- Length (chars) of the fill-delete-prefix pattern match at pos.
local function fpre_match(B, pos, prefix, limit)
  local p = pos
  while p < limit and is_sp(B[p]) do
    p = p + 1
  end
  if prefix and not prefix:match("^[ \t]*$") then
    -- prefix with flexible blanks
    local pc = chars(prefix)
    local k = 1
    local q = p
    local ok = true
    while k <= #pc do
      if is_sp(pc[k]) then
        while k <= #pc and is_sp(pc[k]) do
          k = k + 1
        end
        while q < limit and is_sp(B[q]) do
          q = q + 1
        end
      else
        if B[q] ~= pc[k] then
          ok = false
          break
        end
        k = k + 1
        q = q + 1
      end
    end
    if ok then
      p = q
      while p < limit and is_sp(B[p]) do
        p = p + 1
      end
    end
  end
  return p - pos
end

--- fill-nobreak-p at pos (point before B[pos]).
local function nobreak_p(B, pos)
  if pos == bol(B, pos) then
    return false
  end
  local r = pos
  while r > 1 and B[r - 1] == " " do
    r = r - 1
  end
  if B[r - 1] == "." and B[r] == " " then
    local nx = B[r + 1]
    if nx ~= nil and nx ~= " " and nx ~= "\n" then
      return true
    end
  end
  return false
end

--- fill-move-to-break-point; returns the new point.
local function move_to_break_point(B, pt, linebeg)
  if linebeg > pt then
    pt = linebeg
  end
  while true do
    local q = pt - 1
    while q >= linebeg and not is_sp(B[q]) do
      q = q - 1
    end
    if q < linebeg then
      pt = linebeg
      break
    end
    pt = q + 1
    if nobreak_p(B, pt) then
      while pt > linebeg and is_sp(B[pt - 1]) do
        pt = pt - 1
      end
    else
      break
    end
  end
  while pt > 1 and is_sp(B[pt - 1]) do
    pt = pt - 1
  end
  if linebeg >= pt then
    local to2 = eol(B, linebeg)
    pt = linebeg
    local first = true
    while pt < to2 and (first or nobreak_p(B, pt)) do
      while pt < to2 and is_sp(B[pt]) do
        pt = pt + 1
      end
      while pt < to2 and not (is_sp(B[pt]) or B[pt] == "\n") do
        pt = pt + 1
      end
      first = false
    end
  end
  return pt
end

--- justify-current-line on the line starting at lstart. Returns the
--- number of chars inserted (negative when removed).
local function justify_line(B, lstart, how, fc, opts)
  if how ~= "right" and how ~= "center" then
    return 0
  end
  local e = eol(B, lstart)
  while e > lstart and is_sp(B[e - 1]) do
    e = e - 1
  end
  if e == lstart then
    return 0
  end
  if how == "right" and column_between(B, lstart, e) == fc then
    return 0
  end
  local p = lstart
  while p < e and is_sp(B[p]) do
    p = p + 1
  end
  local prefix = opts.prefix
  local pc = prefix and prefix ~= "" and chars(prefix) or nil
  local matched = false
  if pc then
    matched = true
    for k = 1, #pc do
      if B[p + k - 1] ~= pc[k] then
        matched = false
        break
      end
    end
  end
  if matched then
    p = p + #pc
  elseif opts.adaptive then
    p = p + adaptive_match(B, p, e)
  end
  local fp_end = p
  while p < e and is_sp(B[p]) do
    p = p + 1
  end
  local beg = p
  local indent = column_between(B, lstart, beg)
  local endcol = column_between(B, lstart, e)
  local ncols
  if how == "right" then
    ncols = fc - endcol
    if ncols < 0 then
      local target = indent + ncols
      local s = fp_end
      if column_between(B, lstart, s) < target then
        while s < beg and column_between(B, lstart, s) < target do
          s = s + 1
        end
      end
      return -delete_range(B, s, beg)
    end
    return insert_chars(B, beg, indent_chars(indent, indent + ncols, opts.tabs))
  end
  ncols = trunc_div(fc - (endcol - indent), 2)
  if ncols < indent then
    local s = fp_end
    if column_between(B, lstart, s) < ncols then
      while s < beg and column_between(B, lstart, s) < ncols do
        s = s + 1
      end
    end
    return -delete_range(B, s, beg)
  end
  return insert_chars(B, beg, indent_chars(indent, ncols, opts.tabs))
end

--- canonically-space-region on B[from, to); returns the new `to`.
local function canonically_space(B, from, to)
  for i = from, to - 1 do
    if B[i] == "\t" then
      B[i] = " "
    end
  end
  local pt = from
  while pt < to do
    -- leftmost match of sentence-end or "  +"
    local found
    local i = pt
    while i < to do
      local ch = B[i]
      if SENTENCE_PUNCT[ch] then
        local j = i + 1
        while j < to and CLOSERS[B[j]] do
          j = j + 1
        end
        local ok = false
        if j >= to then
          ok = true
        elseif (B[j] == " " or B[j] == NBSP) and j + 1 >= to then
          ok = true
        elseif B[j] == "\t" then
          ok = true
        elseif (B[j] == " " or B[j] == NBSP) and (B[j + 1] == " " or B[j + 1] == NBSP) then
          ok = true
        end
        if ok then
          local k = j
          while k < to and (B[k] == " " or B[k] == NBSP or B[k] == "\t" or B[k] == "\n") do
            k = k + 1
          end
          while k < to and B[k] == " " do
            k = k + 1
          end
          found = { kind = 1, mb = i, me = k }
          break
        end
      elseif CJK_END[ch] then
        local j = i
        while j < to and CJK_END[B[j]] do
          j = j + 1
        end
        local k = j
        while k < to and (B[k] == " " or B[k] == NBSP or B[k] == "\t" or B[k] == "\n") do
          k = k + 1
        end
        found = { kind = 1, mb = i, me = k }
        break
      end
      if ch == " " and B[i + 1] == " " and i + 1 < to then
        local k = i
        while k < to and B[k] == " " do
          k = k + 1
        end
        found = { kind = 2, mb = i, me = k }
        break
      end
      i = i + 1
    end
    if not found then
      break
    end
    local me = found.me
    local dstart
    if found.kind == 1 then
      local s = me
      while s > found.mb and B[s - 1] == " " do
        s = s - 1
      end
      dstart = math.min(me, s + 2)
    else
      local s = me
      while s > 1 and SKIP_BACK[B[s - 1]] do
        s = s - 1
      end
      local prev = B[s - 1]
      local keep
      if prev == "." or prev == "?" or prev == "!" then
        keep = 2
      elseif prev == "\n" then
        keep = 0
      else
        keep = 1
      end
      dstart = found.mb + keep
    end
    if dstart < me then
      local d = delete_range(B, dstart, me)
      to = to - d
      me = me - d
    end
    pt = me
  end
  return to
end

--- fill-region-as-paragraph on a chunk (array of chars). Returns the array.
local function fill_paragraph(B, fc, justify)
  local n = #B
  local p = 1
  while p <= n and (B[p] == " " or B[p] == "\t" or B[p] == "\n") do
    p = p + 1
  end
  local from_plus = p
  local from = bol(B, math.min(p, n + 1))
  -- delete all but one newline at the end
  local pt = #B + 1
  local oneleft = false
  while pt > from and B[pt - 1] == "\n" do
    if oneleft then
      table.remove(B, pt - 1)
      pt = pt - 1
    else
      pt = pt - 1
      oneleft = true
    end
  end
  local to = pt
  if not (to > from_plus) then
    return B
  end
  justify = justify or "left"
  local prefix = context_prefix(B, from, to, fc)
  local tabs = true
  if justify == "right" or justify == "center" then
    -- fill-indent-to-left-margin on the first line
    local k = from
    while k < to and is_sp(B[k]) do
      k = k + 1
    end
    to = to - delete_range(B, from, k)
  end
  -- fill-delete-prefix
  do
    local q = eol(B, from) + 1
    while q < to do
      local m = fpre_match(B, q, prefix, to)
      if m > 0 then
        to = to - delete_range(B, q, q + m)
      end
      q = eol(B, q) + 1
    end
    from = from + fpre_match(B, from, prefix, to)
  end
  -- fill-delete-newlines: sentences ending a line get an extra space
  do
    local k = from
    while k < to do
      if B[k] == "\n" then
        local c = B[k - 1]
        if k > from and not is_sp(c) then
          local j = k - 1
          while j >= from and CLOSERS[B[j]] do
            j = j - 1
          end
          if j >= from and SENTENCE_PUNCT[B[j]] then
            table.insert(B, k, " ")
            to = to + 1
            k = k + 1
          end
        end
      end
      k = k + 1
    end
    local s = from
    while s < to and is_sp(B[s]) do
      s = s + 1
    end
    for i = from, to - 1 do
      if B[i] == "\n" then
        B[i] = " "
      end
    end
    to = canonically_space(B, s, to)
    local t = to
    while t > from and is_sp(B[t - 1]) do
      t = t - 1
    end
    if t < to then
      to = to - delete_range(B, t, to)
    end
  end
  -- filling loop
  pt = from
  local opts = { prefix = prefix, adaptive = true, tabs = tabs }
  while pt < to do
    local linebeg = pt
    local lb = bol(B, pt)
    local le = eol(B, pt)
    -- move-to-column
    local q = lb
    local c = 0
    while q < le and c < fc do
      local ch = B[q]
      if ch == "\t" then
        c = c + 8 - (c % 8)
      else
        c = c + cwidth(ch)
      end
      q = q + 1
    end
    local cut = false
    if q < to and linebeg < to then
      if c <= fc then
        q = q + 1
      end
      q = move_to_break_point(B, q, linebeg)
      while q < to and is_sp(B[q]) do
        q = q + 1
      end
      cut = q < to
    end
    if cut then
      local r = q
      while r > 1 and is_sp(B[r - 1]) do
        r = r - 1
      end
      table.insert(B, r, "\n")
      to = to + 1
      local nl = r + 1
      local k = nl
      while k < to and is_sp(B[k]) do
        k = k + 1
      end
      to = to - delete_range(B, nl, k)
      local after = nl
      if prefix and prefix ~= "" then
        local ins = insert_chars(B, nl, chars(prefix))
        to = to + ins
        after = nl + ins
      end
      if justify ~= "left" then
        local d = justify_line(B, bol(B, r), justify, fc, opts)
        to = to + d
        after = after + d
      end
      pt = after
    else
      if justify ~= "left" then
        local d = justify_line(B, bol(B, to), justify, fc, opts)
        to = to + d
      end
      break
    end
  end
  return B
end

--- org-ascii--fill-string: fill S to TEXT-WIDTH (fill-region with hard
--- newlines).
function M.fill_string(s, text_width, info, justify)
  if type(s) ~= "string" then
    return nil
  end
  if info and info.preserve_breaks then
    s = s:gsub("\n", HARD)
  end
  local out = {}
  local start = 1
  while start <= #s do
    local h = s:find(HARD, start, true)
    local chunk
    if h then
      chunk = s:sub(start, h - 1) .. "\n"
      start = h + 1
    else
      chunk = s:sub(start)
      start = #s + 1
    end
    local B = fill_paragraph(chars(chunk), text_width, justify)
    out[#out + 1] = table.concat(B)
  end
  return table.concat(out)
end

--- org-ascii--justify-lines
function M.justify_lines(s, text_width, how)
  if how ~= "right" and how ~= "center" then
    return s
  end
  local B = chars(s)
  local pos = 1
  local opts = { tabs = false, adaptive = false }
  while pos <= #B do
    justify_line(B, pos, how, text_width, opts)
    pos = eol(B, pos) + 1
  end
  return table.concat(B)
end

local function indent_string(s, width)
  if type(s) ~= "string" then
    return s
  end
  if width <= 0 then
    return s
  end
  local pad = string.rep(" ", width)
  local out = {}
  local ends = s:sub(-1) == "\n"
  local body = ends and s:sub(1, -2) or s
  for line in (body .. "\n"):gmatch("(.-)\n") do
    if line:match("%S") then
      line = line:gsub("^[ \t]*", function(ws)
        return pad .. ws
      end, 1)
    end
    out[#out + 1] = line
  end
  local r = table.concat(out, "\n")
  if ends then
    r = r .. "\n"
  end
  return r
end
M.indent_string = indent_string

local function box_string(s, info)
  local u = utf8p(info)
  s = s:gsub("\n[ \t]*$", "")
  local pre = u and "│ " or "| "
  local lines = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = pre .. line
  end
  return fmt(u and "┌────\n%s\n└────" or ",----\n%s\n`----", table.concat(lines, "\n"))
end

local function checkbox(item, info)
  local u = utf8p(info)
  local c = item.checkbox
  if c == "on" then
    return u and "☑ " or "[X] "
  elseif c == "off" then
    return u and "☐ " or "[ ] "
  elseif c == "trans" then
    return u and "☒ " or "[-] "
  end
end

local function bullet_string(b)
  return (b or "-"):gsub("[ \t]+$", "") .. " "
end

function M.current_text_width(el, info)
  local t = el.type
  if t == "inlinetask" then
    return info.ascii_inlinetask_width
  elseif t == "headline" then
    local rank = ox.low_level_p(el, info)
    return info.ascii_text_width - (rank and rank * 2 or info.ascii_global_margin)
  end
  local genealogy = {}
  local n = el
  while n do
    genealogy[#genealogy + 1] = n
    n = n.parent
  end
  local in_task = false
  for _, g in ipairs(genealogy) do
    if g.type == "inlinetask" then
      in_task = true
    end
  end
  local total
  if in_task then
    total = info.ascii_inlinetask_width
  else
    local parent = element.lineage(el, "headline")
    local inner = 0
    if parent then
      local rank = ox.low_level_p(parent, info)
      inner = rank and rank * 2 or info.ascii_inner_margin
    end
    total = info.ascii_text_width - info.ascii_global_margin - inner
  end
  local quotes, lists, indentation = 0, 0, 0
  for _, g in ipairs(genealogy) do
    if g.type == "quote-block" or g.type == "verse-block" then
      quotes = quotes + 1
    elseif g.type == "plain-list" and not (g.parent and g.parent.type == "item") then
      lists = lists + 1
    elseif g.type == "item" then
      if g.parent and g.parent.list_type == "descriptive" then
        indentation = indentation + info.ascii_quote_margin
      else
        indentation = indentation + swidth(checkbox(g, info) or "") + swidth(g.bullet or "")
      end
    end
  end
  return total - (quotes * 2 * info.ascii_quote_margin + lists * info.ascii_list_margin + indentation)
end

function M.current_justification(el)
  local p = el.parent
  while p do
    if p.type == "center-block" then
      return "center"
    elseif p.type == "special-block" then
      if p.block_type == "JUSTIFYRIGHT" then
        return "right"
      elseif p.block_type == "JUSTIFYLEFT" then
        return "left"
      end
    end
    p = p.parent
  end
  return "left"
end

function M.justify_element(contents, el, info)
  if not nw(contents) then
    return contents
  end
  local width = M.current_text_width(el, info)
  local how = M.current_justification(el)
  if el.type == "paragraph" then
    return M.fill_string(contents, width, info, how)
  elseif how == "left" then
    return contents
  end
  local lines = {}
  local ends = contents:sub(-1) == "\n"
  local body = ends and contents:sub(1, -2) or contents
  for line in (body .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  local max = 0
  for _, l in ipairs(lines) do
    if not l:match("^[ \t]*$") then
      local c = column_between(chars(l), 1, #chars(l) + 1)
      if c >= width then
        return contents
      end
      max = math.max(max, c)
    end
  end
  local offset = trunc_div(width - max, how == "right" and 1 or 2)
  if offset == 0 then
    return contents
  end
  local pad = table.concat(indent_chars(0, offset, true))
  for i, l in ipairs(lines) do
    if not l:match("^[ \t]*$") then
      lines[i] = pad .. l
    end
  end
  return table.concat(lines, "\n") .. (ends and "\n" or "")
end

local function translate(s, info)
  return ox.translate(s, charset(info), info)
end

local function make_tag_string(tags)
  return ":" .. table.concat(tags, ":") .. ":"
end

function M.build_title(el, info, text_width, underline, notags, toc)
  local headlinep = el.type == "headline"
  local numbers = ""
  if headlinep and ox.numbered_headline_p(el, info) then
    local num = ox.get_headline_number(el, info) or {}
    if toc then
      numbers = fmt("%d. ", num[#num] or 0)
    else
      local parts = {}
      for i, x in ipairs(num) do
        parts[i] = tostring(x)
      end
      numbers = table.concat(parts, ".") .. " "
    end
  end
  local text = trim(ox.data((toc and headlinep) and ox.get_alt_title(el) or el.title, info))
  local todo = (info.with_todo_keywords and el.todo_keyword) and (el.todo_keyword .. " ") or ""
  local tags
  if not notags and info.with_tags then
    local tl = ox.get_tags(el, info)
    if #tl > 0 then
      tags = make_tag_string(tl)
    end
  end
  local priority = (info.with_priority and el.priority) and fmt("(#%s) ", el.priority) or ""
  local first = numbers .. todo .. priority .. text
  local s = first
  if tags then
    local w = math.max(text_width - (1 + swidth(first)), swidth(tags))
    s = s .. " " .. string.rep(" ", w - swidth(tags)) .. tags
  end
  if underline and headlinep then
    local unders = (info.ascii_underline or {})[charset(info)] or {}
    local ch = unders[ox.get_relative_level(el, info)]
    if ch then
      s = s .. "\n" .. string.rep(ch, math.floor(swidth(first) / math.max(1, swidth(ch))))
    end
  end
  return s
end

local function has_caption(el)
  return el.caption ~= nil
end

local function build_caption(el, info)
  local caption = ox.get_caption(el)
  if not caption then
    return nil
  end
  local reference = ox.get_ordinal(el, info, nil, has_caption)
  local title_fmt = translate(el.type == "table" and "Table %d:" or "Listing %d:", info)
  return M.fill_string(
    (title_fmt:gsub("%%d", tostring(reference))) .. " " .. ox.data(caption, info),
    M.current_text_width(el, info),
    info
  )
end

local function rule_title(title, info)
  return title .. "\n" .. string.rep(utf8p(info) and "─" or "_", swidth(title)) .. "\n\n"
end

function M.build_toc(info, n, keyword, scope)
  local out = {}
  if not scope then
    out[#out + 1] = rule_title(translate("Table of Contents", info), info)
  end
  local text_width = keyword and M.current_text_width(keyword, info)
    or (info.ascii_text_width - info.ascii_global_margin)
  local entries = {}
  for _, h in ipairs(ox.collect_headlines(info, n, scope)) do
    local level = ox.get_relative_level(h, info)
    local indent = (level - 1) * 3
    entries[#entries + 1] = (indent ~= 0 and (string.rep(".", indent - 1) .. " ") or "")
      .. M.build_title(h, info, text_width - indent, nil, (not info.with_tags) or info.with_tags == "not-in-toc", true)
  end
  out[#out + 1] = table.concat(entries, "\n")
  return table.concat(out)
end

local function list_of(kind, keyword, info)
  local title = translate(kind == "tables" and "List of Tables" or "List of Listings", info)
  local text_width = keyword and M.current_text_width(keyword, info)
    or (info.ascii_text_width - info.ascii_global_margin)
  local elems = kind == "tables" and ox.collect_tables(info) or ox.collect_listings(info)
  local count = 0
  local items = {}
  for _, e in ipairs(elems) do
    count = count + 1
    local initial = (translate(kind == "tables" and "Table %d:" or "Listing %d:", info):gsub("%%d", tostring(count)))
    local iw = swidth(initial)
    local caption = ox.get_caption(e, true) or ox.get_caption(e)
    items[#items + 1] = initial
      .. " "
      .. trim(indent_string(M.fill_string(ox.data(caption, info), text_width - iw, info), iw))
  end
  return rule_title(title, info) .. table.concat(items, "\n")
end

local function unique_links(el, info)
  local seen = {}
  local out = {}
  local data
  if el.type == "section" then
    data = el
  else
    data = { el.title or {}, el.contents[1] and el.contents[1].type == "section" and el.contents[1] or {} }
  end
  element.map(data, "link", function(link)
    local contents = #link.contents > 0 and trim(element.interpret(link.contents)):gsub("[ \r\t\n]+", " ") or ""
    local footprint = (link.raw_link or "") .. "\0" .. contents
    if nw(info.exported_data[link]) and not seen[footprint] then
      seen[footprint] = true
      out[#out + 1] = link
    end
  end, { ignore = info.ignore, no_recursion = { headline = true }, with_affiliated = true })
  return out
end

local function describe_datum(datum, info)
  local t = datum.type
  if t == "plain-text" then
    return fmt("See file %s", datum.value)
  elseif t == "headline" then
    local d
    if ox.numbered_headline_p(datum, info) then
      local parts = {}
      for i, x in ipairs(ox.get_headline_number(datum, info) or {}) do
        parts[i] = tostring(x)
      end
      d = table.concat(parts, ".")
    else
      d = ox.data(datum.title, info)
    end
    return (translate("See section %s", info):gsub("%%s", function()
      return d
    end))
  end
  local number = ox.get_ordinal(datum, info, nil, has_caption)
  local enumerable =
    element.lineage(datum, { headline = true, paragraph = true, ["src-block"] = true, table = true }, true)
  local et = enumerable and enumerable.type
  if et == "headline" then
    local d
    if ox.numbered_headline_p(enumerable, info) then
      local parts = {}
      for i, x in ipairs(number or {}) do
        parts[i] = tostring(x)
      end
      d = table.concat(parts, ".")
    else
      d = ox.data(enumerable.title, info)
    end
    return (translate("See section %s", info):gsub("%%s", function()
      return d
    end))
  elseif not number then
    return translate("Unknown reference", info)
  elseif et == "paragraph" then
    return (translate("See figure %s", info):gsub("%%s", tostring(number)))
  elseif et == "src-block" then
    return (translate("See listing %s", info):gsub("%%s", tostring(number)))
  elseif et == "table" then
    return (translate("See table %s", info):gsub("%%s", tostring(number)))
  end
  return translate("Unknown reference", info)
end

local function describe_links(links, width, info)
  local out = {}
  for _, link in ipairs(links) do
    local t = link.link_type
    local description = #link.contents > 0 and link.contents or nil
    local anchor = ox.data(description or link.raw_link, info)
    if t == "coderef" or t == "radio" then
      -- nothing
    elseif t == "custom-id" or t == "fuzzy" or t == "id" then
      if description then
        local ok, dest = pcall(function()
          if t == "fuzzy" then
            return ox.resolve_fuzzy_link(link, info)
          end
          return ox.resolve_id_link(link, info)
        end)
        if ok and dest then
          out[#out + 1] = M.fill_string(fmt("[%s] %s", anchor, describe_datum(dest, info)), width, info) .. "\n\n"
        end
      end
    elseif not description then
      -- the destination is already visible
    elseif ox.custom_protocol_maybe(link, anchor, "ascii", info) then
      -- handled by a custom export function
    else
      out[#out + 1] = M.fill_string(fmt("[%s] <%s>", anchor, link.raw_link), width, info) .. "\n\n"
    end
  end
  return table.concat(out)
end

local function with_opt(info, key, value)
  return setmetatable({ [key] = value }, { __index = info })
end

---------------------------------------------------------------------------
-- Template
---------------------------------------------------------------------------

local function document_title(info)
  local text_width = info.ascii_text_width
  info = with_opt(info, "ascii_links_to_notes", false)
  local with_title = info.with_title
  local title = ox.data(with_title and info.title or nil, info)
  local subtitle = ox.data(with_title and info.subtitle or nil, info)
  local author = info.with_author and info.author and ox.data(info.author, info) or nil
  local email = info.with_email and ox.data(info.email, info) or nil
  local date = nil
  if info.with_date then
    local d = ox.get_date(info)
    date = type(d) == "string" and d or ox.data(d, info)
  end
  if title == "" then
    if nw(date) and nw(author) then
      return author
        .. string.rep(" ", text_width - swidth(date) - swidth(author))
        .. date
        .. (nw(email) and ("\n" .. email) or "")
        .. "\n\n\n"
    elseif nw(date) and nw(email) then
      return email .. string.rep(" ", text_width - swidth(date) - swidth(email)) .. date .. "\n\n\n"
    elseif nw(date) then
      return M.justify_lines(date, text_width, "right") .. "\n\n\n"
    elseif nw(author) and nw(email) then
      return author .. "\n" .. email .. "\n\n\n"
    elseif nw(author) then
      return author .. "\n\n\n"
    elseif nw(email) then
      return email .. "\n\n\n"
    end
    return nil
  end
  local u = utf8p(info)
  local maxw = 0
  for line in (title .. "\n" .. subtitle .. "\n"):gmatch("(.-)\n") do
    maxw = math.max(maxw, swidth(line))
  end
  local title_len = math.min(maxw, math.floor(2 * text_width / 3))
  local formatted_title = M.fill_string(title, title_len, info)
  local formatted_subtitle = nw(subtitle) and M.fill_string(subtitle, title_len, info) or nil
  local line = string.rep(
    u and "━" or "_",
    math.min(math.max(title_len, swidth(author or ""), swidth(email or "")) + 2, text_width)
  )
  local s = line
    .. "\n"
    .. (u and "" or "\n")
    .. vim.fn.toupper(formatted_title)
    .. (formatted_subtitle and ("\n" .. formatted_subtitle) or "")
  if nw(author) and nw(email) then
    s = s .. "\n\n" .. author .. "\n" .. email
  elseif nw(author) then
    s = s .. "\n\n" .. author
  elseif nw(email) then
    s = s .. "\n\n" .. email
  end
  s = s .. "\n" .. line .. (nw(date) and ("\n\n\n" .. date) or "") .. "\n\n\n"
  return M.justify_lines(s, text_width, "center")
end

local function inner_template(contents, info)
  local margin = info.ascii_global_margin
  local s = contents
  local defs = ox.collect_footnote_definitions(info)
  if #defs > 0 then
    local ninfo = with_opt(info, "ascii_links_to_notes", false)
    local text_width = info.ascii_text_width - margin
    local parts = {}
    for _, ref in ipairs(defs) do
      local id = fmt("[%s] ", ref[1])
      local def = ref[3]
      local full = false
      for _, x in ipairs(def) do
        if element.ELEMENTS[x.type] then
          full = true
        end
      end
      local r
      if full then
        local first = def[1]
        if not first or first.type ~= "paragraph" then
          r = id .. "\n" .. ox.data(def, ninfo)
        else
          local t = element.text(id, first)
          table.insert(first.contents, 1, t)
          r = ox.data(def, ninfo)
        end
      else
        r = M.fill_string(id .. ox.data(def, ninfo), text_width, ninfo)
      end
      parts[#parts + 1] = trim(r)
    end
    s = s .. "\n\n\n" .. rule_title(translate("Footnotes", info), info) .. table.concat(parts, "\n\n")
  end
  return ox.normalize_string(indent_string(s, margin))
end

local function template(contents, info)
  local margin = info.ascii_global_margin
  local depth = info.with_toc
  local head = (document_title(info) or "")
    .. (depth and (M.build_toc(info, type(depth) == "number" and depth or nil) .. "\n\n\n") or "")
  local out = indent_string(head, margin) .. contents
  if info.with_creator then
    out = out
      .. indent_string(
        "\n\n\n" .. M.fill_string(info.creator or "", info.ascii_text_width - margin, info, "right"),
        margin
      )
  end
  return out
end

---------------------------------------------------------------------------
-- Transcoders
---------------------------------------------------------------------------

local T = {}

T.bold = function(_, contents)
  return fmt("*%s*", contents or "")
end
T.italic = function(_, contents)
  return fmt("/%s/", contents or "")
end
T.underline = function(_, contents)
  return fmt("_%s_", contents or "")
end
T["strike-through"] = function(_, contents)
  return fmt("+%s+", contents or "")
end

local function verbatim_format(value, info)
  return (info.ascii_verbatim_format:gsub("%%s", function()
    return value
  end))
end

T.code = function(el, _, info)
  return verbatim_format(el.value, info)
end
T.verbatim = T.code
T["inline-src-block"] = T.code

T["center-block"] = function(_, contents)
  return contents
end

T.clock = function(el, _, info)
  local s = "CLOCK: " .. ox.timestamp_translate(el.value)
  if el.duration then
    local parts = vim.split(el.duration, ":", { plain = true })
    s = s .. " => " .. fmt("%2s:%2s", parts[1] or "", parts[2] or "")
  end
  return M.justify_element(s, el, info)
end

T.drawer = function(el, contents, info)
  local width = M.current_text_width(el, info)
  local f = info.ascii_format_drawer_function
  if type(f) == "function" then
    return f(el.drawer_name, contents, width)
  end
  return contents
end

T["dynamic-block"] = function(_, contents)
  return contents
end

T.entity = function(el, _, info)
  local e = entities[el.name]
  if not e then
    return "\\" .. el.name
  end
  local c = charset(info)
  if c == "utf-8" then
    return e[6]
  elseif c == "latin1" then
    return e[5]
  end
  return e[4]
end

T["example-block"] = function(el, _, info)
  return M.justify_element(box_string(ox.format_code_default(el, info), info), el, info)
end

T["export-snippet"] = function(el)
  local tr = (require("org.config").opts.export or {}).snippet_translation or {}
  if (tr[el.back_end] or el.back_end) == "ascii" then
    return el.value
  end
end

T["export-block"] = function(el, _, info)
  if el.back_end_type == "ASCII" then
    return M.justify_element(el.value, el, info)
  end
end

T["fixed-width"] = function(el, _, info)
  local lines = element.remove_indentation(vim.split(el.value, "\n", { plain = true }))
  return M.justify_element(box_string(table.concat(lines, "\n"), info), el, info)
end

T["footnote-reference"] = function(el, _, info)
  return fmt("[%s]", ox.get_footnote_number(el, info))
end

T.headline = function(el, contents, info)
  if el.footnote_section_p then
    return nil
  end
  contents = contents or ""
  local low = ox.low_level_p(el, info)
  local width = M.current_text_width(el, info)
  local title = M.build_title(el, info, width, not low)
  local spacing = info.ascii_headline_spacing
  local pre = string.rep("\n", (spacing and spacing[1]) or el.pre_blank or 0)
  local links = info.ascii_links_to_notes and describe_links(unique_links(el, info), width, info) or nil
  local body = contents
  if nw(links) then
    local first = el.contents[1]
    local section = first and first.type == "section" and first or nil
    local parts = {}
    if section then
      parts[#parts + 1] = ox.normalize_string(ox.data(section, info)) .. "\n\n"
    end
    parts[#parts + 1] = links
    for i, e in ipairs(el.contents) do
      if not (section and i == 1) then
        parts[#parts + 1] = ox.data(e, info)
      end
    end
    body = table.concat(parts)
  end
  if low then
    local bullets = (info.ascii_bullets or {})[charset(info)] or { "*" }
    local bullet = bullets[((low - 1) % #bullets) + 1] .. " "
    return bullet .. title .. "\n" .. pre .. indent_string(body, #chars(bullet))
  end
  return title .. "\n" .. pre .. body
end

T["horizontal-rule"] = function(el, _, info)
  local text_width = M.current_text_width(el, info)
  local spec = ox.read_attribute("attr_ascii", el, "width")
  local w = (spec and spec:match("^%d+$")) and tonumber(spec) or text_width
  return M.justify_lines(string.rep(utf8p(info) and "―" or "-", w), text_width, "center")
end

function M.format_inlinetask_default(_todo, _type, _priority, _name, _tags, contents, width, inlinetask, info)
  local u = utf8p(info)
  width = width or info.ascii_inlinetask_width
  local title = M.build_title(inlinetask, info, width)
  if swidth(title) > width then
    title = M.fill_string(title, width, info)
  end
  local s = string.rep(u and "━" or "_", width)
    .. "\n"
    .. (u and "" or (string.rep(" ", width) .. "\n"))
    .. title
    .. "\n"
    .. (nw(contents) and (string.rep(u and "─" or "-", width) .. "\n" .. contents) or "")
    .. string.rep(u and "━" or "_", width)
  return indent_string(
    s,
    info.ascii_text_width
      - info.ascii_global_margin
      - (element.lineage(inlinetask, "headline") and info.ascii_inner_margin or 0)
      - M.current_text_width(inlinetask, info)
  )
end

T.inlinetask = function(el, contents, info)
  local width = M.current_text_width(el, info)
  local f = info.ascii_format_inlinetask_function
  if type(f) ~= "function" then
    f = M.format_inlinetask_default
  end
  return f(
    info.with_todo_keywords and el.todo_keyword or nil,
    el.todo_type,
    info.with_priority and el.priority or nil,
    ox.data(el.title, info),
    info.with_tags and el.tags or nil,
    contents,
    width,
    el,
    info
  )
end

T.item = function(el, contents, info)
  local u = utf8p(info)
  local cb = checkbox(el, info)
  local list_type = el.parent.list_type
  local bullet
  if list_type == "descriptive" then
    bullet = (cb or "") .. ox.data(el.tag, info)
  elseif list_type == "ordered" then
    local bul = bullet_string(el.bullet)
    local num = ox.get_ordinal(el, info)
    bullet = bul:gsub("[%w]+", tostring(num[#num]), 1)
  else
    local bul = bullet_string(el.bullet)
    if u then
      bul = bul:gsub("%*", "‣"):gsub("%+", "⁃"):gsub("%-", "•")
    end
    bullet = bul
  end
  local indentation = list_type == "descriptive" and info.ascii_quote_margin or swidth(bullet)
  local c = indent_string(contents, indentation)
  local rest
  local first_contrib
  for _, e in ipairs(el.contents) do
    if nw(ox.data(e, info)) then
      first_contrib = e
      break
    end
  end
  if list_type ~= "descriptive" and nw(c) and first_contrib and first_contrib.type == "paragraph" then
    rest = trim(c)
  else
    rest = "\n" .. (c or "")
  end
  return bullet .. (cb or "") .. rest
end

T.keyword = function(el, _, info)
  local key, value = el.key, el.value
  if key == "ASCII" then
    return M.justify_element(value, el, info)
  elseif key == "TOC" then
    local low = value:lower()
    local r
    if low:match("%f[%w]headlines%f[%W]") then
      local depth = tonumber(value:match("%f[%d](%d+)%f[%D]"))
      local scope
      local target = value:match(':target +(".-")') or value:match(":target +(%S+)")
      if target then
        scope = ox.resolve_link((target:gsub('^"(.*)"$', "%1")), info)
      elseif low:match("%f[%w]local%f[%W]") then
        scope = el
      end
      r = M.build_toc(info, depth, el, scope)
    elseif low:match("%f[%w]tables%f[%W]") then
      r = list_of("tables", el, info)
    elseif low:match("%f[%w]listings%f[%W]") then
      r = list_of("listings", el, info)
    end
    return M.justify_element(r, el, info)
  end
end

T["latex-environment"] = function(el, _, info)
  if info.with_latex then
    local lines = element.remove_indentation(vim.split((el.value:gsub("\n$", "")), "\n", { plain = true }))
    return M.justify_element(table.concat(lines, "\n") .. "\n", el, info)
  end
end

T["latex-fragment"] = function(el, _, info)
  if info.with_latex then
    return el.value
  end
end

T["line-break"] = function()
  return HARD
end

T.link = function(el, desc, info)
  local t = el.link_type
  local custom = ox.custom_protocol_maybe(el, desc, "ascii", info)
  if custom then
    return custom
  end
  if t == "coderef" then
    local ref = el.path
    local f = ox.get_coderef_format(ref, desc)
    local r = ox.resolve_coderef(ref, info)
    return (f:gsub("%%s", function()
      return tostring(r)
    end))
  elseif t == "radio" then
    return desc
  elseif t == "custom-id" or t == "fuzzy" or t == "id" then
    local dest = t == "fuzzy" and ox.resolve_fuzzy_link(el, info) or ox.resolve_id_link(el, info)
    if desc then
      if info.ascii_links_to_notes then
        return fmt("[%s]", desc)
      end
      return fmt("[%s] (%s)", desc, describe_datum(dest, info))
    end
    if dest.type == "plain-text" then
      return dest.value
    elseif dest.type == "headline" then
      if ox.numbered_headline_p(dest, info) then
        local parts = {}
        for i, x in ipairs(ox.get_headline_number(dest, info) or {}) do
          parts[i] = tostring(x)
        end
        return table.concat(parts, ".")
      end
      return ox.data(dest.title, info)
    end
    local number = ox.get_ordinal(dest, info, nil, has_caption)
    if number then
      if type(number) == "number" then
        return tostring(number)
      end
      local parts = {}
      for i, x in ipairs(number) do
        parts[i] = tostring(x)
      end
      return table.concat(parts, ".")
    end
    return "???"
  end
  local path = el.raw_link
  if not nw(desc) then
    return fmt("<%s>", path)
  end
  return fmt("[%s]", desc) .. ((not info.ascii_links_to_notes) and fmt(" (<%s>)", path) or "")
end

T["node-property"] = function(el)
  return fmt("%s:%s", el.key, el.value and (" " .. el.value) or "")
end

T.paragraph = function(el, contents, info)
  contents = (contents or ""):gsub("\n[ \t\n]*\n", "\n")
  local ilw = info.ascii_indented_line_width
  if type(ilw) == "number" and ilw >= 0 then
    local first_in_section = not ox.get_previous_element(el, info) and el.parent and el.parent.type == "section"
    contents = (first_in_section and "" or string.rep(" ", ilw)) .. contents:gsub("^[ \t]+", "")
  end
  return M.justify_element(contents, el, info)
end

T["plain-list"] = function(el, contents, info)
  local margin = info.ascii_list_margin
  if margin < 1 or (el.parent and el.parent.type == "item") then
    return contents
  end
  return indent_string(contents, margin)
end

function M.plain_text(text, info, node)
  local u = utf8p(info)
  if u and info.with_smart_quotes and node then
    text = ox.activate_smart_quotes(text, "utf-8", info, node)
  end
  if not info.with_special_strings then
    return text
  end
  text = text:gsub("\\%-", "")
  if not u then
    return text
  end
  return (text:gsub("%-%-%-", "—"):gsub("%-%-", "–"):gsub("%.%.%.", "…"))
end

T["plain-text"] = function(text, info, node)
  return M.plain_text(text, info, node)
end

T.planning = function(el, _, info)
  local parts = {}
  if el.closed then
    parts[#parts + 1] = "CLOSED: " .. ox.timestamp_translate(el.closed)
  end
  if el.deadline then
    parts[#parts + 1] = "DEADLINE: " .. ox.timestamp_translate(el.deadline)
  end
  if el.scheduled then
    parts[#parts + 1] = "SCHEDULED: " .. ox.timestamp_translate(el.scheduled)
  end
  return M.justify_element(table.concat(parts, " "), el, info)
end

T["property-drawer"] = function(el, contents, info)
  if nw(contents) then
    return M.justify_element(contents, el, info)
  end
end

T["quote-block"] = function(_, contents, info)
  return indent_string(contents, info.ascii_quote_margin)
end

T["radio-target"] = function(_, contents)
  return contents
end

T.section = function(el, contents, info)
  local headline = element.lineage(el, "headline")
  local links
  if info.ascii_links_to_notes and not headline then
    links = describe_links(unique_links(el, info), M.current_text_width(el, info), info)
  end
  local s = contents
  if nw(links) then
    s = ox.normalize_string(contents or "") .. "\n\n" .. links
  end
  local margin = (not headline or ox.low_level_p(headline, info)) and 0 or info.ascii_inner_margin
  return indent_string(s, margin)
end

T["special-block"] = function(_, contents)
  return contents
end

T["src-block"] = function(el, _, info)
  local caption = build_caption(el, info)
  local above = info.ascii_caption_above
  local code = ox.format_code_default(el, info)
  if code == "" then
    return ""
  end
  return M.justify_element(
    ((caption and above) and (caption .. "\n") or "")
      .. box_string(code, info)
      .. ((caption and not above) and ("\n" .. caption) or ""),
    el,
    info
  )
end

T["statistics-cookie"] = function(el)
  return el.value
end

T.subscript = function(el, contents)
  return el.use_brackets and fmt("_{%s}", contents or "") or fmt("_%s", contents or "")
end

T.superscript = function(el, contents)
  return el.use_brackets and fmt("^{%s}", contents or "") or fmt("^%s", contents or "")
end

T.table = function(el, contents, info)
  local caption = build_caption(el, info)
  local above = info.ascii_caption_above
  local body
  if el.table_type == "org" then
    body = contents or ""
  else
    local lines = element.remove_indentation(vim.split((el.value:gsub("\n$", "")), "\n", { plain = true }))
    body = table.concat(lines, "\n") .. "\n"
  end
  return M.justify_element(
    ((caption and above) and (caption .. "\n") or "") .. body .. ((caption and not above) and caption or ""),
    el,
    info
  )
end

local function column_index(cell)
  for i, c in ipairs(cell.parent.contents) do
    if c == cell then
      return i
    end
  end
end

local function table_cell_width(cell, info)
  local row = cell.parent
  local tbl = row.parent
  local col_i = column_index(cell)
  info.ascii_table_cell_width_cache = info.ascii_table_cell_width_cache or {}
  local cache = info.ascii_table_cell_width_cache
  cache[tbl] = cache[tbl] or {}
  if cache[tbl][col_i] then
    return cache[tbl][col_i]
  end
  local widen = info.ascii_table_widen_columns
  local cookie = ox.table_cell_width(cell, info)
  local w
  if not widen and cookie then
    w = cookie
  else
    local maxw = 0
    for _, r in ipairs(tbl.contents) do
      if not info.ignore[r] then
        local c = r.contents[col_i]
        maxw = math.max(swidth(ox.data(c and c.contents or {}, info)), maxw)
      end
    end
    if not cookie then
      w = maxw
    elseif widen then
      w = math.max(cookie, maxw)
    else
      w = cookie
    end
  end
  cache[tbl][col_i] = w
  return w
end

T["table-cell"] = function(el, contents, info)
  local width = table_cell_width(el, info)
  if not info.ascii_table_widen_columns and swidth(contents or "") > width then
    local cs = chars(contents)
    contents = table.concat(cs, "", 1, math.max(0, width - 2)) .. "=>"
  end
  local data
  if contents then
    data = M.justify_lines(contents, width, ox.table_cell_alignment(el, info))
  end
  contents = (data or "") .. string.rep(" ", math.max(0, width - swidth(data or "")))
  local s = fmt(" %s ", contents)
  if ox.table_cell_borders(el, info).right then
    s = s .. (utf8p(info) and "│" or "|")
  end
  return s
end

T["table-row"] = function(el, contents, info)
  if el.row_type ~= "standard" then
    return nil
  end
  local u = utf8p(info)
  local first_cell
  for _, c in ipairs(el.contents) do
    if not info.ignore[c] then
      first_cell = c
      break
    end
  end
  local function build_hline(lcorner, horiz, vert, rcorner)
    local parts = {}
    for _, cell in ipairs(el.contents) do
      if not info.ignore[cell] then
        local width = table_cell_width(cell, info)
        local borders = ox.table_cell_borders(cell, info)
        local s = ""
        if borders.left and first_cell == cell then
          s = s .. lcorner
        end
        s = s .. string.rep(horiz, width + 2)
        if borders.right then
          if el.contents[#el.contents] == cell then
            s = s .. rcorner
          else
            s = s .. vert
          end
        end
        parts[#parts + 1] = s
      end
    end
    return table.concat(parts) .. "\n"
  end
  local borders = first_cell and ox.table_cell_borders(first_cell, info) or {}
  local s = ""
  if borders.top and (u or borders.above) then
    s = u and build_hline("┍", "━", "┯", "┑") or build_hline("+", "-", "+", "+")
  elseif borders.above then
    s = u and build_hline("├", "─", "┼", "┤") or build_hline("+", "-", "+", "+")
  end
  if borders.left then
    s = s .. (u and "│" or "|")
  end
  s = s .. (contents or "") .. "\n"
  if borders.bottom and (u or borders.below) then
    s = s .. (u and build_hline("┕", "━", "┷", "┙") or build_hline("+", "-", "+", "+"))
  end
  return s
end

T.timestamp = function(el, _, info)
  return M.plain_text(ox.timestamp_translate(el), info)
end

T["verse-block"] = function(el, contents, info)
  contents = contents and contents:gsub(HARD, "\n") or contents
  return indent_string(M.justify_element(contents, el, info), info.ascii_quote_margin)
end

T.template = template
T.inner_template = inner_template

M.transcoders = T

---------------------------------------------------------------------------
-- Filters
---------------------------------------------------------------------------

--- org-ascii-filter-headline-blank-lines
local function headline_blank_lines(s, _, info)
  local spacing = info.ascii_headline_spacing
  if not spacing then
    return s
  end
  local blanks = string.rep("\n", 1 + spacing[2])
  -- leftmost match of "\n\(\n[ \t]*\)*\'"
  local last = #s
  while last > 0 and s:sub(last, last):match("[ \t\n]") do
    last = last - 1
  end
  local i = s:find("\n", last + 1, true)
  while i do
    local rest = s:sub(i + 1)
    local ok = true
    while rest ~= "" do
      if rest:sub(1, 1) ~= "\n" then
        ok = false
        break
      end
      rest = rest:sub(2):gsub("^[ \t]*", "")
    end
    if ok then
      return s:sub(1, i - 1) .. blanks
    end
    i = s:find("\n", i + 1, true)
  end
  return s
end

local function paragraph_spacing(tree, _, info)
  local sp = info.ascii_paragraph_spacing
  if type(sp) == "number" and sp >= 0 then
    element.map(tree, "paragraph", function(p)
      local nxt = ox.get_next_element(p, info)
      if nxt and nxt.type == "paragraph" then
        p.post_blank = sp
      end
    end, { ignore = info.ignore })
  end
  return tree
end

local function comment_spacing(tree, _, info)
  element.map(tree, { comment = true, ["comment-block"] = true }, function(c)
    local nxt = ox.get_next_element(c, info)
    if nxt and (nxt.type == "comment" or nxt.type == "comment-block") then
      c.post_blank = 0
    end
  end, { ignore = info.ignore })
  return tree
end

local function final_output(s)
  return (s:gsub(HARD, "\n"))
end

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

M.defaults = {
  bullets = { ascii = { "*", "+", "-" }, latin1 = { "§", "¶" }, ["utf-8"] = { "◊" } },
  caption_above = false,
  charset = "ascii",
  global_margin = 0,
  headline_spacing = { 1, 2 },
  indented_line_width = "auto",
  inlinetask_width = 30,
  inner_margin = 2,
  links_to_notes = true,
  list_margin = 0,
  paragraph_spacing = "auto",
  quote_margin = 6,
  table_keep_all_vertical_lines = false,
  table_use_ascii_art = false,
  table_widen_columns = true,
  text_width = 72,
  underline = {
    ascii = { "=", "~", "-" },
    latin1 = { "=", "~", "-" },
    ["utf-8"] = { "═", "─", "╌", "┄", "┈" },
  },
  verbatim_format = "`%s'",
}

function M.options()
  local c = acfg()
  local function v(name)
    if c[name] == nil then
      if name == "text_width" then
        local legacy = (require("org.config").opts.export or {}).text_width
        if legacy ~= nil then
          return legacy
        end
      end
      return M.defaults[name]
    end
    return c[name]
  end
  local function thunk(f)
    return function()
      return f
    end
  end
  return {
    { "subtitle", "SUBTITLE", nil, nil, "parse" },
    { "ascii_bullets", nil, nil, v("bullets") },
    { "ascii_caption_above", nil, nil, v("caption_above") },
    { "ascii_charset", nil, nil, v("charset") },
    { "ascii_global_margin", nil, nil, v("global_margin") },
    -- function defaults are thunks in ox, so wrap the functions
    { "ascii_format_drawer_function", nil, nil, thunk(c.format_drawer_function) },
    { "ascii_format_inlinetask_function", nil, nil, thunk(c.format_inlinetask_function) },
    { "ascii_headline_spacing", nil, nil, v("headline_spacing") },
    { "ascii_indented_line_width", nil, nil, v("indented_line_width") },
    { "ascii_inlinetask_width", nil, nil, v("inlinetask_width") },
    { "ascii_inner_margin", nil, nil, v("inner_margin") },
    { "ascii_links_to_notes", nil, nil, v("links_to_notes") },
    { "ascii_list_margin", nil, nil, v("list_margin") },
    { "ascii_paragraph_spacing", nil, nil, v("paragraph_spacing") },
    { "ascii_quote_margin", nil, nil, v("quote_margin") },
    { "ascii_table_keep_all_vertical_lines", nil, nil, v("table_keep_all_vertical_lines") },
    { "ascii_table_use_ascii_art", nil, nil, v("table_use_ascii_art") },
    { "ascii_table_widen_columns", nil, nil, v("table_widen_columns") },
    { "ascii_text_width", nil, nil, v("text_width") },
    { "ascii_underline", nil, nil, v("underline") },
    { "ascii_verbatim_format", nil, nil, v("verbatim_format") },
  }
end

M.backend = ox.define_backend("ascii", {
  transcoders = T,
  options = M.options,
  filters = {
    headline = { headline_blank_lines },
    section = { headline_blank_lines },
    ["parse-tree"] = { paragraph_spacing, comment_spacing },
    ["final-output"] = { final_output },
  },
})

return M

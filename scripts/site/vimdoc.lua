-- Vim help (vimdoc) to HTML, for the documentation website.
--
-- `split` cuts doc/org.txt into pages at its `====` chapter rules (and the
-- Extensions chapter at its `----` rules); `render` turns a page's lines into
-- HTML: `*tags*` become anchors, `|links|` hyperlinks (to the page holding the
-- tag, or to Neovim's own help for Vim tags), `>lang ... <` code blocks are
-- highlighted, `Heading ~` lines become headings, prose paragraphs and
-- bullet lists flow, and aligned text (key tables, option lists) stays
-- preformatted as in `:help`.
local html = require("site.html")

local M = {}

local RULE_LEN = 40

local function is_rule(line, ch)
  return #line >= RULE_LEN and line == string.rep(ch, #line)
end

--- Code block opener: the line ends with ">" or ">lang" after a space (or
--- is only that). Returns the text before the marker and the language.
local function code_open(line)
  local lang = line:match("^>(%w*)$")
  if lang then
    return "", lang
  end
  local before, l = line:match("^(.*%s)>(%w*)$")
  if before then
    return (before:gsub("%s+$", "")), l
  end
end
M.code_open = code_open

--- The tags of a line: `*tag*` preceded by the start of the line or white
--- space and followed by white space or the end, outside code spans.
local function line_tags(line)
  -- not inside `code` (like the vimdoc parser :helptags uses since 0.12)
  line = line:gsub("`[^`]+`", function(c)
    return string.rep(" ", #c)
  end)
  local tags = {}
  for s, tag, e in line:gmatch("()%*([^*%s|]+)%*()") do
    local before = s == 1 or line:sub(s - 1, s - 1):match("%s")
    local after = e > #line or line:sub(e, e):match("%s")
    if before and after then
      tags[#tags + 1] = tag
    end
  end
  return tags
end
M.line_tags = line_tags

--- Iterate over the lines that aren't inside a code block, with their index.
local function text_lines(lines)
  local i, in_code = 0, false
  return function()
    while true do
      i = i + 1
      local line = lines[i]
      if line == nil then
        return nil
      end
      if in_code then
        if line:match("^<") then
          in_code = false
        elseif line:match("^%S") then
          in_code = false
          if code_open(line) then
            in_code = true
          end
          return i, line
        end
      else
        if code_open(line) then
          in_code = true
        end
        return i, line
      end
    end
  end
end

--- Every tag defined in `lines`, in order.
function M.tags(lines)
  local out = {}
  for _, line in text_lines(lines) do
    for _, t in ipairs(line_tags(line)) do
      out[#out + 1] = t
    end
  end
  return out
end

--- Strip `*tags*` and the alignment before them from a header line.
local function header_text(line)
  local text = line:gsub("%s*%*[^*%s|]+%*", "")
  return vim.trim(text)
end

--- Chapter titles from the CONTENTS table: tag → "Document structure".
local function contents_titles(lines)
  local titles = {}
  for _, line in ipairs(lines) do
    local title, tag = line:match("^%s*%d+%.%s+(.-)%s+%.+%s+|([^|]+)|%s*$")
    if title then
      titles[tag] = title
    end
  end
  return titles
end

--- Split a help file into pages.
--- Returns a list of { name, title, lines, parent? }: `name` is the first
--- tag of the page's header line ("index" for the part before the first
--- chapter, which includes the CONTENTS), `lines` excludes the rule.
function M.split(lines)
  local titles = contents_titles(lines)
  local pages = {}
  local cur = { name = "index", title = "Contents", lines = {} }
  pages[1] = cur
  local chapter -- the current ====-chapter page, parent of ----sections
  local i = 1
  local in_code = false
  while i <= #lines do
    local line = lines[i]
    local rule = not in_code and (is_rule(line, "=") and "=" or is_rule(line, "-") and "-")
    if rule and lines[i + 1] then
      local header = lines[i + 1]
      local tags = line_tags(header)
      local name = tags[1]
      if not name or (rule == "=" and name:match("%-contents$")) then
        -- the CONTENTS chapter stays on the index page
        cur.lines[#cur.lines + 1] = line
      else
        local title = titles[name] or header_text(header)
        cur = { name = name, title = title, lines = {}, level = rule == "=" and 1 or 2 }
        if rule == "=" then
          chapter = cur
        else
          cur.parent = chapter and chapter.name
        end
        pages[#pages + 1] = cur
      end
    else
      cur.lines[#cur.lines + 1] = line
    end
    if in_code then
      if line:match("^<") then
        in_code = false
      elseif line:match("^%S") then
        in_code = code_open(line) ~= nil
      end
    elseif code_open(line) then
      in_code = true
    end
    i = i + 1
  end
  return pages
end

-- Inline markup ---------------------------------------------------------------

--- Render the inline markup of one line of text.
--- ctx.link(tag) → href or nil; ctx.tags[tag] → true for tags defined here
--- (rendered as anchors); ctx.on_tag(tag) called for each anchor.
local function inline(text, ctx)
  local out = {}
  local i = 1
  local n = #text
  while i <= n do
    local s = text:find("[|*`<h]", i)
    if not s then
      out[#out + 1] = html.escape(text:sub(i))
      break
    end
    out[#out + 1] = html.escape(text:sub(i, s - 1))
    local c = text:sub(s, s)
    local handled
    if c == "|" then
      local tag, e = text:match("^|([^|%s]+)|()", s)
      -- `true|false|"x"` and `[a|b|c]` are alternatives, not links
      local prev, nxt = text:sub(s - 1, s - 1), tag and text:sub(e, e) or ""
      if tag and (s == 1 or not prev:match("[%w\"'%]>_]")) and not nxt:match("[%w\"'%[<_]") then
        local href = ctx.link(tag)
        if href then
          out[#out + 1] = '<a class="hl" href="' .. html.escape(href) .. '">' .. html.escape(tag) .. "</a>"
        else
          out[#out + 1] = '<span class="hl">' .. html.escape(tag) .. "</span>"
        end
        i, handled = e, true
      end
    elseif c == "*" then
      local tag, e = text:match("^%*([^*%s|]+)%*()", s)
      local before = s == 1 or text:sub(s - 1, s - 1):match("%s")
      local after = tag and (e > n or text:sub(e, e):match("%s"))
      if tag and before and after and ctx.tags[tag] then
        if ctx.on_tag then
          ctx.on_tag(tag)
        end
        out[#out + 1] = '<a class="tag" id="'
          .. html.escape(tag)
          .. '" href="#'
          .. html.escape(html.urlencode(tag))
          .. '">'
          .. html.escape(tag)
          .. "</a>"
        i, handled = e, true
      end
    elseif c == "`" then
      local code, e = text:match("^`([^`]+)`()", s)
      if code and not code:find("\n.*\n") then
        out[#out + 1] = "<code>" .. html.escape(code) .. "</code>"
        i, handled = e, true
      end
    elseif c == "<" then
      local key, e = text:match("^(<[%a][%w%-]*>)()", s)
      if key then
        out[#out + 1] = '<span class="key">' .. html.escape(key) .. "</span>"
        i, handled = e, true
      end
    elseif c == "h" then
      local url, e = text:match("^(https?://[^%s<>\"'`|]+)()", s)
      if url and (s == 1 or not text:sub(s - 1, s - 1):match("[%w_]")) then
        local trail = url:match("[.,;:)]+$") or ""
        url = url:sub(1, #url - #trail)
        out[#out + 1] = '<a href="' .. html.escape(url) .. '">' .. html.escape(url) .. "</a>"
        i, handled = e - #trail, true
      end
    end
    if not handled then
      out[#out + 1] = html.escape(c)
      i = s + 1
    end
  end
  return table.concat(out)
end
M.inline = inline

-- Blocks ------------------------------------------------------------------------

--- :help conceals the backticks of `code` and the bars of |links|, and the
--- text is aligned as shown there. Take the hidden characters out of the
--- next alignment gap after them, so columns line up as on screen.
local function conceal_align(line)
  local out, debt, pos = {}, 0, #line:match("^%s*") + 1
  out[1] = line:sub(1, pos - 1)
  while pos <= #line do
    local s, e = line:find("`[^`]+`", pos)
    local s2, e2 = line:find("|[^|%s]+|", pos)
    local gs, ge = line:find("%s%s+", pos)
    local nxt = math.min(s or math.huge, s2 or math.huge, gs or math.huge)
    if nxt == math.huge then
      break
    end
    if nxt == gs then
      -- the next alignment gap pays for what was hidden before it (it
      -- keeps two spaces)
      local take = math.min(debt, ge - gs - 1)
      out[#out + 1] = line:sub(pos, ge - take)
      debt = 0
      pos = ge + 1
    else
      local stop = nxt == s and e or e2
      out[#out + 1] = line:sub(pos, stop)
      debt = debt + 2
      pos = stop + 1
    end
  end
  out[#out + 1] = line:sub(pos)
  return table.concat(out)
end
M.conceal_align = conceal_align

--- The byte of `line` shown at screen column `col` (1-based) by :help,
--- which hides the backticks of `code` and the bars of |links|.
local function raw_col(line, col)
  local hidden = {}
  for s, e in line:gmatch("()`[^`]+`()") do
    hidden[s], hidden[e - 1] = true, true
  end
  for s, e in line:gmatch("()|[^|%s]+|()") do
    hidden[s], hidden[e - 1] = true, true
  end
  -- (a hidden character just before the column belongs to the text there)
  local d = 0
  for i = 1, #line do
    if d == col - 1 then
      return i
    end
    if not hidden[i] then
      d = d + 1
    end
  end
end

--- A line of flowing prose: starts in column 0 and has no alignment gaps
--- (two spaces are fine after the end of a sentence).
local function prose_line(line)
  if line:match("^%s") then
    return false
  end
  -- spaces inside `code` or "a string" aren't alignment
  local gaps = line:gsub("`[^`]*`", "`x`"):gsub('"[^"]*"', '"x"'):gsub("([.!?:])  ", "%1 ")
  return not gaps:find("%S  +%S")
end

local function bullet(line)
  local ind, mark, rest = line:match("^(%s*)([-*•])%s+(%S.*)$")
  if ind then
    return #ind, #ind + #mark + (#line - #ind - #mark - #rest), rest, "ul"
  end
  ind, mark, rest = line:match("^(%s*)(%d+[.)])%s+(%S.*)$")
  if ind then
    return #ind, #ind + #mark + (#line - #ind - #mark - #rest), rest, "ol"
  end
end

local function lead(line)
  return #line:match("^%s*")
end

--- Split `text` at its first alignment gap (two or more spaces that don't
--- end a sentence). Returns the text before, the column (1-based, in
--- `text`) after the gap and the text after, or nil.
local function split_gap(text)
  local init = 1
  while true do
    local s, e = text:find("%S%s%s+()%S", init)
    if not s then
      return nil
    end
    local left = text:sub(1, s)
    -- "end.  Next": a sentence, not a column (but "f / b / ." is a term)
    if not left:match("%a[%a%)\"'`][.!?]$") or not left:find(" ") then
      local col = text:find("%S", s + 1)
      return left, col, text:sub(col)
    end
    init = s + 1
  end
end

--- A definition entry: a term, an alignment gap and its description, as in
--- key and option tables. Returns indent, term, description column (1-based)
--- and description (nil for a term alone on its line), or nil.
local function def_entry(line, col)
  if line:match("^%s*$") or bullet(line) then
    return nil
  end
  local ind = lead(line)
  local term, c, desc = split_gap(line:sub(ind + 1))
  if term then
    return ind, term, ind + c, desc
  end
  -- "<C-c><C-x><C-c> column view": one space, at the run's column (as
  -- shown, without the backticks of `code`)
  local r = col and col > ind + 2 and raw_col(line, col)
  if r then
    local left = line:sub(ind + 1, r - 2)
    if not left:find(" ") and line:sub(r - 1, r - 1) == " " and line:sub(r, r):match("%S") then
      return ind, left, col, line:sub(r)
    end
  end
end

--- A term at column 0 with one space before its description, whose next
--- line is indented to the description ("<C-c><C-x><C-t> Toggle the").
local function tight_entry(lines, j)
  local line, nxt = lines[j], lines[j + 1]
  local term = line:match("^(%S+) %S")
  -- a key or a command, not a word of prose
  if term and #term >= 3 and term:find("[^%w]") and nxt and lead(nxt) == #term + 1 and nxt:match("%S") then
    return 0, term, #term + 2, line:sub(#term + 2)
  end
end

--- A term alone at column 0, with its description on the next, indented
--- lines: a `command`, a <Key> or an :Ex command ("`org show TARGET`").
local function alone0(lines, j)
  local line, nxt = lines[j], lines[j + 1]
  if line:match("^[`<:]") and not line:match("[.:,;]$") and nxt and lead(nxt) >= 2 and nxt:match("%S") then
    local term, c, desc = split_gap(line)
    if term then
      return 0, term, c, desc
    end
    return 0, line, lead(nxt) + 1, nil
  end
end

--- A definition entry at `lines[j]`: as def_entry, or a term alone on its
--- line with the description on the next, indented lines.
local function entry_at(lines, j, col)
  local ind, term, c, desc = def_entry(lines[j], col)
  if ind then
    return ind, term, c, desc
  end
  ind, term, c, desc = tight_entry(lines, j)
  if ind then
    return ind, term, c, desc
  end
  ind, term, c, desc = alone0(lines, j)
  if ind then
    return ind, term, c, desc
  end
  local line, nxt = lines[j], lines[j + 1]
  ind = lead(line)
  if ind > 0 and nxt and lead(nxt) > ind and not bullet(line) and nxt:match("%S") then
    return ind, vim.trim(line), lead(nxt) + 1, nil
  end
end

local render_block

--- A list from `lines[i]`: items at the same indent and their continuation
--- lines (indented deeper than the bullet). Returns the HTML and the index
--- after it, or nil.
local function list_run(lines, i, ctx)
  local ind0, _, _, kind = bullet(lines[i])
  if not ind0 then
    return nil
  end
  local items = {}
  while i <= #lines do
    local line = lines[i]
    local ind, width, rest, k = bullet(line)
    if ind == ind0 and k == kind then
      items[#items + 1] = { width = width, lines = { rest } }
    elseif lead(line) > ind0 then
      -- continuation lines are dedented to the item's text column (or as
      -- far as they go)
      local item = items[#items]
      item.lines[#item.lines + 1] = line:sub(math.min(lead(line), item.width) + 1)
    else
      break
    end
    i = i + 1
  end
  local out = { "<" .. kind .. ">" }
  for _, item in ipairs(items) do
    out[#out + 1] = "<li>" .. render_block(item.lines, ctx, true) .. "</li>"
  end
  out[#out + 1] = "</" .. kind .. ">"
  return table.concat(out, "\n"), i
end

--- The most common value of a list of numbers, and how often it occurs.
local function mode(list)
  local count, best = {}, nil
  for _, v in ipairs(list) do
    count[v] = (count[v] or 0) + 1
    if not best or count[v] > count[best] or (count[v] == count[best] and v < best) then
      best = v
    end
  end
  return best, best and count[best] or 0
end

--- Dedent `lines` by their common indent.
local function dedent(lines)
  local min
  for _, l in ipairs(lines) do
    if l:match("%S") then
      min = math.min(min or math.huge, lead(l))
    end
  end
  local out = {}
  for _, l in ipairs(lines) do
    out[#out + 1] = l:sub((min or 0) + 1)
  end
  return out
end

--- A definition list from `lines[i]`: entries (term, gap, description) at
--- the same indent, with the description's continuation lines indented
--- deeper. Option tables with a default value between the name and the
--- description get three columns. Returns the HTML and the index after it,
--- or nil.
local function def_run(lines, i, ctx)
  local ind0, _, col0, desc0 = entry_at(lines, i)
  if not ind0 then
    return nil
  end
  -- (a term alone has no column to align one-space entries to)
  if not desc0 then
    col0 = nil
  end
  local entries = {}
  local j = i
  while j <= #lines do
    local line = lines[j]
    local ind, term, col, desc = entry_at(lines, j, col0)
    if
      ind == ind0
      and term
      and not (ind0 == 0 and prose_line(line) and not tight_entry(lines, j) and not alone0(lines, j))
    then
      entries[#entries + 1] = { line = line, term = term, col = col, first = desc, more = {} }
    elseif #entries > 0 and lead(line) > ind0 and not line:match("^%s*$") then
      local e = entries[#entries]
      e.more[#e.more + 1] = line
    else
      break
    end
    j = j + 1
  end
  -- "<prefix>id  Insert a drawer at the cursor (Insert mode splits the line,"
  -- "<C-c><C-x>d  like Emacs), or around ...": two keys of one command, the
  -- second line going on with the sentence of the first
  if ind0 == 0 then
    local merged = {}
    for _, e in ipairs(entries) do
      local prev = merged[#merged]
      if
        prev
        and prev.term:match("^<")
        and e.term:match("^<")
        and #prev.more == 0
        and prev.first
        and not prev.first:match("[.;:!?]$")
        and e.first
        and e.first:match("^[%l(]")
      then
        prev.term = prev.term .. ", " .. e.term
        prev.first = prev.first .. " " .. e.first
        prev.more = e.more
      else
        merged[#merged + 1] = e
      end
    end
    entries = merged
  end
  -- one entry is a table only with a continuation line at its column
  local single = entries[1] and #entries == 1
  if #entries == 0 or (single and not (entries[1].more[1] and lead(entries[1].more[1]) == entries[1].col - 1)) then
    return nil
  end
  -- the run's description column: a term with spaces of its own
  -- ("file:path  ./rel  ~/p") ends there, not at its first gap
  local cols, leads = {}, {}
  for _, e in ipairs(entries) do
    if e.first then
      cols[#cols + 1] = e.col
    end
    for _, l in ipairs(e.more) do
      leads[#leads + 1] = lead(l)
    end
  end
  local run_col, n_col = mode(cols)
  -- where continuation lines flow (a term wider than the column has its
  -- description after the gap, and its next lines at the column)
  local flow = mode(leads)
  for _, e in ipairs(entries) do
    local l = e.line
    local r = run_col and raw_col(l, run_col)
    local at_col = r and l:sub(r, r):match("%S") and l:sub(r - 1, r - 1) == " "
    if n_col >= 3 and at_col then
      local left = l:sub(ind0 + 1, r - 1)
      if e.col < run_col and left:match("  $") and n_col >= #entries / 2 then
        e.term, e.col, e.first = vim.trim(left), run_col, l:sub(r)
      elseif e.col > run_col and not vim.trim(left):find(" ") then
        -- "startup_shrink_all_tables false": one space, at the column
        e.term, e.col, e.first = vim.trim(left), run_col, l:sub(r)
      end
    end
  end
  -- three columns: name, value and note (most entries' description has a
  -- gap of its own, at a column shared by the run)
  local notes = {}
  for _, e in ipairs(entries) do
    local value, c, note
    if e.first then
      value, c, note = split_gap(e.first)
    end
    if value and not value:match("[,;]$") then
      e.value, e.note = value, note
      notes[#notes + 1] = e.col - 1 + c
    end
  end
  local three = #entries >= 3 and #notes >= math.max(2, #entries / 4)
  local note_col = three and mode(notes)
  -- a value one space before the note column ("default" the key ...),
  -- outside a string or a table
  if three then
    for _, e in ipairs(entries) do
      local l = e.line
      local c = note_col
      if
        e.first
        and e.col < c - 1
        and l:sub(c - 1, c - 1) == " "
        and l:sub(c - 2, c - 2):match("%S")
        and l:sub(c, c):match("%S")
      then
        local value = vim.trim(l:sub(e.col, c - 1))
        local _, quotes = value:gsub('"', "")
        local _, open = value:gsub("{", "")
        local _, close = value:gsub("}", "")
        if not e.note and quotes % 2 == 0 and open == close then
          e.value, e.note = value, l:sub(c)
        end
      end
    end
  end
  local out = { three and '<table class="defs defs3">' or '<table class="defs">' }
  for _, e in ipairs(entries) do
    -- short terms (keys, most names) don't wrap
    local cls = #e.term > 24 and "term long" or "term"
    local text = inline(e.term, ctx)
    if #e.term > 24 and e.term:match("^[%w_./%-]+$") then
      -- option names break after an underscore, not inside a word
      text = text:gsub("_", "_<wbr>")
    end
    local term = '<td class="' .. cls .. '">' .. text .. "</td>"
    if three then
      local value = { e.value or e.first or "" }
      local note = { e.note }
      for _, l in ipairs(e.more) do
        if lead(l) + 1 >= note_col then
          note[#note + 1] = vim.trim(l)
        else
          value[#value + 1] = l
        end
      end
      -- the value keeps its lines (a Lua table over several lines)
      local v = value[1]
      if #value > 1 then
        local rest = dedent(vim.list_slice(value, 2))
        local pad = string.rep(" ", lead(value[2]) - (e.col - 1))
        for k, l in ipairs(rest) do
          rest[k] = pad .. l
        end
        v = v .. "\n" .. table.concat(rest, "\n")
      end
      local n = #note > 0 and render_block(note, ctx, true) or ""
      out[#out + 1] = "<tr>"
        .. term
        .. '<td class="value"><code>'
        .. html.escape(v)
        .. "</code></td><td>"
        .. n
        .. "</td></tr>"
    else
      -- continuation lines at the description column flow with it; deeper
      -- or shallower ones keep their offset (a nested table, a list)
      local desc = { e.first }
      if not e.first then
        desc = {}
      end
      -- continuation lines flow at their least indent (from the column
      -- on); deeper ones keep their offset (a nested table), and so do
      -- shallower ones
      local col = math.min(e.col - 1, flow or math.huge)
      for _, l in ipairs(e.more) do
        if lead(l) == e.col - 1 then
          col = e.col - 1
        end
      end
      local base
      for _, l in ipairs(e.more) do
        if lead(l) >= col then
          base = math.min(base or math.huge, lead(l))
        end
      end
      for _, l in ipairs(e.more) do
        desc[#desc + 1] = l:sub((lead(l) >= col and base or ind0 + 1) + 1)
      end
      local d = #desc > 0 and render_block(desc, ctx, true) or ""
      out[#out + 1] = "<tr>" .. term .. "<td>" .. d .. "</td></tr>"
    end
  end
  out[#out + 1] = "</table>"
  return table.concat(out, "\n"), j
end

--- The cells of an aligned row: { { col, text }, ... }, split at gaps of
--- two or more spaces.
local function cells(line)
  local out = {}
  local pos = 1
  while true do
    local s, text, e = line:match("()(%S.-)%s%s+()", pos)
    if not s then
      local s2, rest = line:match("()(%S.*)$", pos)
      if s2 then
        out[#out + 1] = { s2, (rest:gsub("%s+$", "")) }
      end
      return out
    end
    out[#out + 1] = { s, text }
    pos = e
  end
end

--- A grid from `lines[i]`: a header row of column names, indented deeper
--- than the rows under it, whose cells start at the header's columns
--- (a comparison table). Returns the HTML and the index after it, or nil.
local function grid_run(lines, i, ctx)
  local head = cells(lines[i])
  if #head < 2 or lead(lines[i]) == 0 then
    return nil
  end
  local rows = {}
  local j = i + 1
  while j <= #lines do
    local row = cells(lines[j])
    if #row ~= #head + 1 or row[1][1] >= head[1][1] then
      break
    end
    for k, c in ipairs(head) do
      if row[k + 1][1] ~= c[1] then
        return nil
      end
    end
    rows[#rows + 1] = row
    j = j + 1
  end
  if #rows < 2 then
    return nil
  end
  local out = { '<table class="grid">', "<thead><tr><th></th>" }
  for _, c in ipairs(head) do
    out[#out + 1] = "<th>" .. inline(c[2], ctx) .. "</th>"
  end
  out[#out + 1] = "</tr></thead><tbody>"
  for _, row in ipairs(rows) do
    local tr = { "<tr>" }
    for _, c in ipairs(row) do
      tr[#tr + 1] = "<td>" .. inline(c[2], ctx) .. "</td>"
    end
    out[#out + 1] = table.concat(tr) .. "</tr>"
  end
  out[#out + 1] = "</tbody></table>"
  return table.concat(out, "\n"), j
end

--- Indented prose from `lines[i]`: lines at the same indent without
--- alignment gaps, wrapped (every line but the last nearly full), like the
--- comma-separated option lists. Returns the lines and the index after.
local function indented_prose(lines, i)
  local ind = lead(lines[i])
  local run = {}
  local j = i
  while j <= #lines and lead(lines[j]) == ind and prose_line(lines[j]:sub(ind + 1)) and not bullet(lines[j]) do
    run[#run + 1] = lines[j]
    j = j + 1
  end
  if ind == 0 or #run == 0 then
    return nil
  end
  -- wrapped: lines that fill the width or end a list item with a comma
  -- (one line alone needs a comma)
  local wrapped = 0
  for k = 1, #run - 1 do
    if #run[k] >= 60 or run[k]:match(",$") then
      wrapped = wrapped + 1
    end
  end
  if #run == 1 and not (run[1]:find(", ") or run[1]:match("%.$")) then
    return nil
  end
  if wrapped < (#run - 1) * 0.6 then
    return nil
  end
  return run, j
end

local function prose(lines, ctx, bare)
  local parts = {}
  for _, l in ipairs(lines) do
    parts[#parts + 1] = vim.trim(l)
  end
  -- one call, so `code` can wrap across lines
  local text = inline(table.concat(parts, " "), ctx)
  return bare and text or ("<p>" .. text .. "</p>")
end

--- Render a run of non-blank text lines: paragraphs of prose, lists,
--- definition tables and, for what is none of these, preformatted text.
--- `bare` (a list item's or table cell's text) leaves a single paragraph
--- unwrapped.
function render_block(lines, ctx, bare)
  local parts = {}
  local para, pre = {}, {}
  local function flush()
    if #para > 0 then
      parts[#parts + 1] = { prose = true, lines = para }
      para = {}
    end
    if #pre > 0 then
      parts[#parts + 1] = '<pre class="help">' .. inline(table.concat(pre, "\n"), ctx) .. "</pre>"
      pre = {}
    end
  end
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local out, nxt
    if bullet(line) then
      out, nxt = list_run(lines, i, ctx)
    elseif not prose_line(line) or tight_entry(lines, i) or alone0(lines, i) then
      out, nxt = grid_run(lines, i, ctx)
      if not out then
        out, nxt = def_run(lines, i, ctx)
      end
      if not out then
        local run, j = indented_prose(lines, i)
        if run then
          out, nxt = prose(run, ctx), j
        end
      end
    end
    if out then
      flush()
      parts[#parts + 1] = out
      i = nxt
    else
      if prose_line(line) then
        if #pre > 0 then
          flush()
        end
        para[#para + 1] = line
      else
        if #para > 0 then
          flush()
        end
        pre[#pre + 1] = line
      end
      i = i + 1
    end
  end
  flush()
  if bare and #parts == 1 and type(parts[1]) == "table" then
    return prose(parts[1].lines, ctx, true)
  end
  for k, p in ipairs(parts) do
    if type(p) == "table" then
      parts[k] = prose(p.lines, ctx)
    end
  end
  return table.concat(parts, "\n")
end

--- Render a code block (lines between `>lang` and `<`), dedented.
local function code_block(lines, lang)
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    lines[#lines] = nil
  end
  local indent
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local w = #l:match("^%s*")
      indent = indent and math.min(indent, w) or w
    end
  end
  local out = {}
  for _, l in ipairs(lines) do
    out[#out + 1] = l:sub((indent or 0) + 1)
  end
  local code = table.concat(out, "\n")
  local cls = lang ~= "" and (' class="language-' .. html.escape(lang) .. '"') or ""
  return '<pre class="code"><code' .. cls .. ">" .. html.highlight(code, lang) .. "</code></pre>"
end

--- Render the tags at the end of a line (after an alignment gap) as an
--- anchor bar, and return the rest of the line.
local function trailing_tags(line, ctx)
  local text = line:gsub("%s+$", "")
  local tags = {}
  while true do
    local rest, gap, t = text:match("^(.-)(%s*)%*([^*%s|]+)%*$")
    if not t or not ctx.tags[t] or (rest ~= "" and gap == "") then
      break
    end
    table.insert(tags, 1, t)
    text = rest
    if rest == "" or #gap >= 2 then
      break -- the start of the line, or the alignment gap before the tags
    end
    -- one space: part of a run of tags, or a tag inside the text
    if not rest:match("%*[^*%s|]+%*$") then
      return line, nil
    end
  end
  if #tags == 0 then
    return line, nil
  end
  local out = {}
  for _, t in ipairs(tags) do
    out[#out + 1] = inline("*" .. t .. "*", ctx)
  end
  return text, '<div class="tags">' .. table.concat(out, " ") .. "</div>"
end

--- Render a page's lines. `ctx`:
---   link(tag) → href|nil   where a |link| points
---   tags                   set of the tags defined in the whole help file
---   on_tag(tag, heading)   called for every anchor, with the heading it's under
---   on_heading(id, text, level)
---   title                  the page's title (for its <h1>)
function M.render(lines, ctx)
  lines = vim.list_slice(lines)
  local out = {}
  local heading = ctx.title
  local on_tag = ctx.on_tag
  local rctx = setmetatable({
    on_tag = on_tag and function(t)
      on_tag(t, heading)
    end,
  }, { __index = ctx })
  local block = {}
  local function flush()
    if #block > 0 then
      out[#out + 1] = render_block(vim.tbl_map(conceal_align, block), rctx)
      block = {}
    end
  end
  local i = 1
  -- the page's header line (after the rule) becomes the <h1>
  if ctx.header then
    local _, bar = trailing_tags(lines[1] or "", rctx)
    out[#out + 1] = "<h1>" .. html.escape(ctx.title) .. "</h1>"
    if bar then
      out[#out + 1] = bar
    end
    i = 2
  end
  while i <= #lines do
    local line = lines[i]
    local before, lang = code_open(line)
    if before then
      if before ~= "" then
        local text, bar = trailing_tags(before, rctx)
        if bar then
          flush()
          out[#out + 1] = bar
        end
        if text ~= "" then
          block[#block + 1] = text
        end
      end
      flush()
      local code = {}
      i = i + 1
      while i <= #lines do
        local l = lines[i]
        if l:match("^<") then
          -- text after the "<" is the next line ("<or run `:Org x`")
          if l:match("^<%s*$") then
            i = i + 1
          else
            lines[i] = l:sub(2)
          end
          break
        elseif l:match("^%S") then
          break
        end
        code[#code + 1] = l
        i = i + 1
      end
      out[#out + 1] = code_block(code, lang)
    elseif line:match("^%s*$") or line:match("^%s+vim:.*:%s*$") then
      -- (and the modeline at the end of the file)
      flush()
      i = i + 1
    elseif is_rule(line, "=") or is_rule(line, "-") then
      flush()
      out[#out + 1] = "<hr>"
      i = i + 1
    elseif line:match("%s~$") or line == "~" then
      flush()
      local text, bar = trailing_tags(line:gsub("%s*~$", ""), rctx)
      if bar then
        out[#out + 1] = bar
      end
      text = vim.trim(text)
      heading = text
      local id = "h-" .. html.slug(text, ctx.slugs)
      if ctx.on_heading then
        ctx.on_heading(id, text, 3)
      end
      out[#out + 1] = '<h3 id="' .. html.escape(id) .. '">' .. inline(text, rctx) .. "</h3>"
      i = i + 1
    else
      local text, bar = trailing_tags(line, rctx)
      if bar and #block > 0 and text:match("^%s+%S") then
        -- a tag at the end of an indented line inside a block (a table's
        -- description): an anchor in the text, not a break in the table
        block[#block + 1] = text .. " " .. line:match("%*[^*%s|]+%*.*$"):gsub("%s+", " ")
        bar = nil
      elseif bar then
        flush()
        out[#out + 1] = bar
        local title = vim.trim(text)
        if
          text:match("^%S")
          and #title < 60
          and prose_line(title)
          and not title:match("[.,;:]$")
          and not title:match("^[`<:|]")
          and lines[i + 1]
          and not lines[i + 1]:match("^%s+%S")
        then
          -- "Where images work      *org-images-troubleshooting*": the title
          -- of the paragraph below ("Texinfo ~   *tag*": a heading)
          if title:match("%s~$") then
            title = vim.trim(title:gsub("%s*~$", ""))
            heading = title
            local id = "h-" .. html.slug(title, ctx.slugs)
            if ctx.on_heading then
              ctx.on_heading(id, title, 3)
            end
            out[#out + 1] = '<h3 id="' .. html.escape(id) .. '">' .. inline(title, rctx) .. "</h3>"
          else
            out[#out + 1] = "<h4>" .. inline(title, rctx) .. "</h4>"
          end
        elseif text:match("%S") then
          block[#block + 1] = text
        end
      else
        block[#block + 1] = line
      end
      i = i + 1
    end
  end
  flush()
  return table.concat(out, "\n")
end

return M

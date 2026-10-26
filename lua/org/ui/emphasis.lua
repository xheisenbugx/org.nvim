---@mod org.ui.emphasis Emphasis and link brackets drawn from the text
---
--- With `ui.highlighter = "parser"`, the markup of org-do-emphasis-faces
--- (bold, italic, underline, strike-through, verbatim and code) and the
--- hidden parts of bracket links (org-activate-links) are drawn by the
--- decoration provider (org.ui.decorations) from a scan of the lines on
--- screen, instead of by the `:syntax` regions of org.syntax.
---
--- The scan is a port of Emacs's fontification, not of the regions: every
--- marker that can open emphasis is tried on its own (org-emph-re, with the
--- shortest text up to a closing marker, over at most one line break), so
--- markup may overlap the way it does in Emacs, and the lines decide the
--- rest (no markup in src and example blocks, no faces in comments, ...).
--- It takes time linear in the length of a line and has no 'synmaxcol' or
--- 'maxmempattern' to run out of. tests/spec/emacs_fontify_parity_spec.lua
--- compares it with what Emacs Org draws (tests/fixtures/emacs/fontify/).

local M = {}

local byte = string.byte

--- Marker -> syntax group of its emphasis (org-emphasis-alist).
M.GROUPS = {
  ["*"] = "orgBold",
  ["/"] = "orgItalic",
  ["_"] = "orgUnderline",
  ["+"] = "orgStrikethrough",
  ["="] = "orgVerbatim",
  ["~"] = "orgCode",
}

local MARKERS = {} ---@type table<integer, string>
for m in pairs(M.GROUPS) do
  MARKERS[byte(m)] = m
end

local function set_of(chars)
  local t = {}
  for i = 1, #chars do
    t[byte(chars, i)] = true
  end
  return t
end

-- org-emphasis-regexp-components: blanks ([[:space:]]), the characters
-- allowed before an opening marker and after a closing one
local SPACE = set_of(" \t\v\f\r\n")
local PRE = set_of(" \t\v\f\r\n('\"{-")
local POST = set_of(" \t\v\f\r\n.,:!?;'\")}[-")

--- Whether `ui.highlighter` makes buffer `bufnr` draw emphasis this way
--- (a buffer's `b:org_ui` can set it, like the other `ui` options).
---@param bufnr? integer
---@return boolean
function M.active(bufnr)
  local ui = require("org.config").opts.ui or {}
  local h = ui.highlighter
  if bufnr and bufnr ~= 0 and vim.api.nvim_buf_is_valid(bufnr) then
    local b = vim.b[bufnr].org_ui
    if type(b) == "table" and b.highlighter ~= nil then
      h = b.highlighter
    end
  end
  return h == "parser"
end

-- Lines ---------------------------------------------------------------------

local VERBATIM_BLOCKS = { src = true, example = true, export = true }
-- (org-element-document-info-keywords: drawn in their own face, which
-- covers the emphasis in them; their markers and links are still hidden)
local INFO = { title = true, author = true, date = true, email = true, subtitle = true }

---@alias org.ui.emphasis.Kind
---| "text" # markup and links
---| "table" # a table row: no markup over a "|"
---| "comment" # links, no markup faces, markers shown (org-at-comment-p)
---| "info" # a document info keyword: markers and links hidden, no faces
---| "fixed" # fixed width: markup faces, markers shown
---| "none" # nothing: src, example and export blocks, other keywords

--- What line `line` holds, outside src, example and export blocks.
---@param line string
---@return org.ui.emphasis.Kind
local function classify(line)
  local s = line:match("^[ \t]*()") ---@type integer
  local c = byte(line, s)
  if c == 35 then -- #
    local c2 = byte(line, s + 1)
    if c2 == nil or c2 == 32 then
      return "comment" -- org-comment-regexp
    end
    if c2 == 43 then -- #+
      local key = line:match("^#%+(%S-):", s)
      if key then
        return INFO[key:lower()] and "info" or "none"
      end
      if line:find("^#%+[bB][eE][gG][iI][nN]_", s) or line:find("^#%+[eE][nN][dD]_", s) then
        return "none"
      end
    end
  elseif c == 58 then -- :
    local c2 = byte(line, s + 1)
    if c2 == nil or c2 == 32 then
      return "fixed"
    end
  elseif c == 124 then -- |
    return "table"
  end
  return "text"
end
M._classify = classify

-- org-element-paragraph-separate, matched at the start of a part of a line
-- (string-match-p on the text of the markup: "^" after a line break, "$"
-- at the end of the part). Emphasis whose text holds one isn't drawn.
local function separates(s)
  if s:find("^%*+ ") or s:find("^%[fn:[-_%w\128-\255]+%]") or s:find("^%%%%%(") then
    return true
  end
  local i = s:match("^[ \t]*()") ---@type integer
  local c = byte(s, i)
  if c == nil or c == 124 then
    return true
  elseif c == 43 then
    -- "+" then "-...-+" groups
    local cells = s:match("^%+([-+]+)[ \t]*$", i)
    return cells ~= nil and cells:find("^%-") ~= nil and cells:find("%+$") ~= nil and not cells:find("++", 1, true)
  elseif c == 35 then
    local c2 = byte(s, i + 1)
    if c2 == nil or c2 == 32 then
      return true
    end
    return c2 == 43
      and (
        s:find("^#%+[bB][eE][gG][iI][nN]_%S", i) ~= nil
        or s:find("^#%+%S-:", i) ~= nil
        or s:find("^#%+%S-%[.*%]:", i) ~= nil
      )
  elseif c == 58 then
    local c2 = byte(s, i + 1)
    return c2 == nil or c2 == 32 or s:find("^:[-_%w\128-\255]+:[ \t]*$", i) ~= nil
  elseif c == 45 and s:find("^%-%-%-%-%-+[ \t]*$", i) then
    return true
  elseif c == 92 and s:find("^\\begin{[%w*]+}", i) then
    return true
  elseif s:find("^[Cc][Ll][Oo][Cc][Kk]:", i) then
    -- a clock line, as a whole: [ts] and an optional --[ts] => H:MM, or
    -- just => H:MM
    local rest = s:sub(i + 6)
    local ts = "%[%d%d%d%d%-%d%d%-%d%d[^%]]*%]"
    local dur = "[ \t]+=>[ \t]+%d+:%d%d"
    return rest:find("^[ \t]+" .. ts .. "[ \t]*$") ~= nil
      or rest:find("^[ \t]+" .. ts .. "%-%-" .. ts .. dur .. "[ \t]*$") ~= nil
      or rest:find("^" .. dur .. "[ \t]*$") ~= nil
  end
  return s:find("^[-+*][ \t]", i) ~= nil
    or s:find("^[-+*]$", i) ~= nil
    or s:find("^%d+[.)][ \t]", i) ~= nil
    or s:find("^%d+[.)]$", i) ~= nil
end
M._separates = separates

-- The scan ------------------------------------------------------------------

---@class org.ui.emphasis.Region
---@field m string the marker
---@field open integer byte of the opening marker
---@field close integer byte of the closing marker

--- The bracket links of `s` (org-link-bracket-re) on the bytes `ok`
--- allows, as the byte ranges descriptive display hides: "[[target][" and
--- "]]", or "[[" and "]]".
---@param s string
---@param ok fun(i: integer): boolean
---@return integer[][]
local function links(s, ok)
  local out = {}
  local i = 1
  while true do
    local p = s:find("[[", i, true)
    if not p then
      return out
    end
    i = p + 1
    if ok(p) then
      -- the target: no unescaped brackets (a line break is allowed)
      local j = p + 2 ---@type integer?
      while true do
        ---@cast j integer
        local b = byte(s, j)
        if b == nil or b == 91 then
          j = nil
          break
        elseif b == 92 then
          while byte(s, j) == 92 do
            j = j + 1
          end
          if byte(s, j) == nil then
            j = nil
            break
          end
          j = j + 1
        elseif b == 93 then
          break
        else
          j = j + 1
        end
      end
      if j and j > p + 2 then
        local nb = byte(s, j + 1)
        if nb == 93 then
          out[#out + 1] = { p, p + 1 }
          out[#out + 1] = { j, j + 1 }
          i = j + 2
        elseif nb == 91 then
          -- the description: anything, up to the first "]]"
          local k = s:find("]]", j + 3, true)
          if k then
            out[#out + 1] = { p, j + 1 }
            out[#out + 1] = { k, k + 1 }
            i = k + 2
          end
        end
      end
    end
  end
end

--- The emphasis of `s` (lines joined by "\n"), in the order of their
--- opening markers, as org-do-emphasis-faces finds it: every marker after
--- a blank, one of -('"{ or the start of a line, before a non-blank, with
--- the shortest text up to the same marker after a non-blank and before a
--- blank, one of -.,:!?;'")}[ or the end of a line, over at most one line
--- break; not when that text holds the start of a paragraph, not over a
--- "|" in a table row, no headline stars, no "+" in a table rule.
---@param s string
---@param line_of fun(i: integer): integer the line (index) of byte i
---@param line_start fun(l: integer): integer the first byte of line l
---@param kind_of fun(l: integer): org.ui.emphasis.Kind
---@return org.ui.emphasis.Region[]
local function emphasis(s, line_of, line_start, kind_of)
  local n = #s
  -- per marker, the bytes where it can close emphasis
  local closes = {} ---@type table<string, integer[]>
  for m in pairs(M.GROUPS) do
    closes[m] = {}
  end
  for i = 2, n do
    local m = MARKERS[byte(s, i)]
    if m then
      local before, after = byte(s, i - 1), byte(s, i + 1)
      if not SPACE[before] and (after == nil or POST[after]) then
        local t = closes[m]
        t[#t + 1] = i
      end
    end
  end
  local next_at = {} ---@type table<string, integer>
  for m in pairs(M.GROUPS) do
    next_at[m] = 1
  end
  local out = {}
  for p = 1, n - 2 do
    local m = MARKERS[byte(s, p)]
    if m then
      local before, after = byte(s, p - 1), byte(s, p + 1)
      local l = line_of(p)
      local kind = kind_of(l)
      if (before == nil or PRE[before]) and after and not SPACE[after] and kind ~= "none" then
        -- the first closing marker at p + 2 or after (openings go up, and
        -- so does the closing found for them)
        local t, k = closes[m], next_at[m]
        while t[k] and t[k] < p + 2 do
          k = k + 1
        end
        next_at[m] = k
        local c = t[k]
        local ls = line_start(l)
        local ok = c ~= nil
        if c then
          local l2 = line_of(c)
          if l2 > l + 1 then
            ok = false
          elseif l2 == l + 1 then
            -- the second line, up to the closing marker
            ok = not separates(s:sub(line_start(l2), c)) and kind_of(l2) ~= "none"
          end
          local head = s:sub(p, l2 == l and c or line_start(l + 1) - 2)
          ok = ok and not separates(head)
          -- headline stars: not as an opening marker
          if ok and m == "*" and p == ls and s:find("^%*+ ", ls) then
            ok = false
          end
          if ok and kind == "table" then
            local bar = s:find("|", p + 1, true)
            ok = not (bar and bar < c)
          end
          if ok and m == "+" then
            -- a table rule (|---+---| or +---+---+)
            local e = (s:find("\n", ls, true) or n + 1) - 1
            local line = s:sub(ls, e)
            if line:find("^[ \t]*|[-+]+|?[ \t]*$") or line:find("^[ \t]*%+[-+]+%+[ \t]*$") then
              ok = false
            end
          end
          if ok then
            out[#out + 1] = { m = m, open = p, close = c }
          end
        end
      end
    end
  end
  return out
end

--- What each of `lines` holds (see `classify`), from a line not in a src,
--- example or export block, or in the one `block` names.
---@param lines string[]
---@param block? string|false
---@return org.ui.emphasis.Kind[]
function M.kinds(lines, block)
  local kinds = {} ---@type org.ui.emphasis.Kind[]
  block = block or false
  for i, line in ipairs(lines) do
    local kind = "none"
    if line:byte(1) == 42 and line:find("^%*+[ \t]") then
      block = false
      kind = "text"
    elseif block then
      local name = line:match("^[ \t]*#%+[eE][nN][dD]_(%S+)")
      if name and name:lower() == block then
        block = false
      end
    else
      local name = line:match("^[ \t]*#%+[bB][eE][gG][iI][nN]_(%S+)")
      if name and VERBATIM_BLOCKS[name:lower()] then
        block = name:lower()
      else
        kind = classify(line)
      end
    end
    kinds[i] = kind
  end
  return kinds
end

--- The bodies of the inline src blocks of `s` (src_LANG[HEADERS]{BODY}),
--- drawn natively in Emacs: no emphasis faces in them, byte -> true.
---@param s string
---@return table<integer, boolean>
local function inline_src(s)
  local out = {}
  local i = 1
  while true do
    local p = s:find("src_", i, true)
    if not p then
      return out
    end
    i = p + 4
    if p == 1 or not s:sub(p - 1, p - 1):find("[%w_]") then
      local e = s:match("^src_[^%s%[{]+()", p)
      if e then
        e = s:match("^%[[^%]\n]*%]()", e) or e
        local last = s:match("^{[^}\n]*}()", e)
        if last then
          for b = e + 1, last - 2 do
            out[b] = true
          end
          i = last
        end
      end
    end
  end
end

--- Emphasis and link marks for `lines`, buffer lines from row `row0`
--- (0-based) on, the first of them not in a src, example or export block
--- unless `opts.block` names it. Marks for rows `first` to `last` are added
--- to `rows`: `{ [row] = { { col, opts, nil, "emphasis" }, ... } }`.
---@param lines string[]
---@param row0 integer
---@param first integer
---@param last integer
---@param opts { hide_markers: boolean, conceal_links: boolean, block?: string|false }
---@param rows table<integer, table[]>
function M.marks(lines, row0, first, last, opts, rows)
  local kinds = M.kinds(lines, opts.block)

  local s = table.concat(lines, "\n")
  local starts = {}
  local pos = 1
  for i, line in ipairs(lines) do
    starts[i] = pos
    pos = pos + #line + 1
  end
  local li = 1
  local function line_of(i)
    if starts[li] > i then
      li = 1
    end
    while starts[li + 1] and starts[li + 1] <= i do
      li = li + 1
    end
    return li
  end
  local function line_start(l)
    return starts[l] or #s + 2
  end
  local function kind_of(l)
    return kinds[l] or "none"
  end

  -- what is hidden, byte by byte: links first (org-activate-links), then
  -- the markers of each emphasis in turn; verbatim and code show what is
  -- hidden in them, then hide their own markers
  local hidden = {} ---@type table<integer, boolean>
  if opts.conceal_links then
    for _, r in
      ipairs(links(s, function(i)
        local k = kind_of(line_of(i))
        return k ~= "none" and k ~= "fixed"
      end))
    do
      for b = r[1], r[2] do
        hidden[b] = true
      end
    end
  end
  local regions = emphasis(s, line_of, line_start, kind_of)
  for _, r in ipairs(regions) do
    if r.m == "=" or r.m == "~" then
      for b = r.open, r.close do
        hidden[b] = nil
      end
    end
    local k = kind_of(line_of(r.open))
    if opts.hide_markers and k ~= "comment" and k ~= "fixed" then
      hidden[r.open], hidden[r.close] = true, true
    end
  end

  -- (an inline src block in verbatim or code is no inline src block)
  local native = s:find("src_", 1, true) and inline_src(s) or {}
  if next(native) then
    for _, r in ipairs(regions) do
      if r.m == "=" or r.m == "~" then
        for b = r.open, r.close do
          native[b] = nil
        end
      end
    end
  end

  -- marks on the rows asked for
  local function add(row, col, o)
    if row < first or row > last then
      return
    end
    local t = rows[row]
    if not t then
      t = {}
      rows[row] = t
    end
    t[#t + 1] = { col, o, nil, "emphasis" }
  end
  --- Mark bytes [a, b] of `s`, on the lines that allow `o` (faces: not
  --- comments and document info keywords), line by line. Whether a mark
  --- was made.
  ---@return boolean
  local function span(a, b, o, face)
    local made = false
    while a <= b do
      local l = line_of(a)
      local e = math.min(b, line_start(l + 1) - 2)
      local k = kind_of(l)
      if e >= a and not (face and (k == "comment" or k == "info" or k == "none")) then
        -- (faces: not in inline src blocks)
        local x = a
        while x <= e do
          while face and x <= e and native[x] do
            x = x + 1
          end
          local y = x
          while y < e and not (face and native[y + 1]) do
            y = y + 1
          end
          if x <= e then
            made = true
            add(row0 + l - 1, x - starts[l], {
              end_col = y - starts[l] + 1,
              hl_group = o.hl_group,
              conceal = o.conceal,
              priority = o.priority,
              spell = o.spell,
              ephemeral = true,
            })
          end
          x = y + 1
        end
      end
      a = line_start(l + 1)
    end
    return made
  end
  -- Later markup over earlier (Emacs prepends each face): the priority is
  -- the number of markups still open where one opens, which a scan that
  -- starts elsewhere finds the same.
  local open = {} ---@type integer[] closing markers of the markups open
  local covered = {} ---@type table<integer, boolean> hidden by a marker's mark
  for _, r in ipairs(regions) do
    local group = M.GROUPS[r.m]
    local verbatim = r.m == "=" or r.m == "~"
    local k = 1
    while k <= #open do
      if open[k] < r.open then
        table.remove(open, k)
      else
        k = k + 1
      end
    end
    local prio = 101 + math.min(#open, 50)
    open[#open + 1] = r.close
    local spell ---@type boolean?
    if verbatim then
      spell = false -- (like the syntax regions: no @Spell)
    end
    span(r.open + 1, r.close - 1, { hl_group = group, priority = prio, spell = spell }, true)
    for _, b in ipairs({ r.open, r.close }) do
      -- markers have the face when shown, and the delimiter face where the
      -- cursor line shows them (not when verbatim showed them again); a
      -- hidden one is hidden by the same mark
      if not opts.hide_markers or hidden[b] then
        local delim = { hl_group = group .. "Delimiter", priority = prio, spell = spell }
        delim.conceal = hidden[b] and "" or nil
        if span(b, b, delim, true) and hidden[b] then
          covered[b] = true
        end
      end
    end
  end
  -- the rest of what is hidden
  local b = 1
  while b <= #s do
    if hidden[b] and not covered[b] and byte(s, b) ~= 10 then
      local e = b
      while hidden[e + 1] and not covered[e + 1] and byte(s, e + 1) ~= 10 do
        e = e + 1
      end
      span(b, e, { conceal = "", priority = 100 })
      b = e + 1
    else
      b = b + 1
    end
  end
end

-- The buffer ----------------------------------------------------------------

--- How far back the scan looks for the headline above (the blocks open
--- there).
local LOOKBACK = 3000

--- Emphasis and link marks of rows `first` to `last` (0-based) of buffer
--- `bufnr`, added to `rows` (the format of org.ui.decorations `compute`).
---@param bufnr integer
---@param first integer
---@param last integer
---@param ui table the buffer's `ui` options
---@param rows table<integer, table[]>
function M.add_marks(bufnr, first, last, ui, rows)
  local n = vim.api.nvim_buf_line_count(bufnr)
  -- markup can start on the line above the first one asked for, and a
  -- link's description can go on over lines: the scan starts two lines up,
  -- in the block state there
  local scan_row = math.max(0, first - 2)
  local start = math.max(0, scan_row - LOOKBACK)
  local before = vim.api.nvim_buf_get_lines(bufnr, start, scan_row, false)
  local block = false ---@type string|false
  for k = #before, 1, -1 do
    local line = before[k]
    if k == 1 and start == 0 or line:byte(1) == 42 and line:find("^%*+[ \t]") then
      -- from the headline above (or the top): the blocks opened since
      for j = (k == 1 and start == 0 and not line:find("^%*+[ \t]")) and k or k + 1, #before do
        local l = before[j]
        if block then
          local name = l:match("^[ \t]*#%+[eE][nN][dD]_(%S+)")
          if name and name:lower() == block then
            block = false
          end
        else
          local name = l:match("^[ \t]*#%+[bB][eE][gG][iI][nN]_(%S+)")
          if name and VERBATIM_BLOCKS[name:lower()] then
            block = name:lower()
          end
        end
      end
      break
    end
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, scan_row, math.min(n, last + 2), false)
  local b = vim.b[bufnr]
  local hide = ui.hide_emphasis_markers and true or false
  if b.org_hide_emphasis_markers ~= nil then
    hide = b.org_hide_emphasis_markers and true or false
  end
  local conceal_links = ui.conceal_links ~= false
  if b.org_link_descriptive ~= nil then
    conceal_links = b.org_link_descriptive and true or false
  end
  M.marks(lines, scan_row, first, last, { hide_markers = hide, conceal_links = conceal_links, block = block }, rows)
end

return M

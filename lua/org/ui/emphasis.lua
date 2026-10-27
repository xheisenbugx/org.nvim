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
--- markup may overlap the way it does in Emacs; links are found the way
--- org-activate-links finds them; then the lines decide what is drawn (no
--- markup in src and example blocks, no faces in comments, ...). It takes
--- time linear in the length of the text and has no 'synmaxcol' or
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
local POST = set_of(" \t\v\f\r\n.,:!?;'\")}[\\-")

-- Characters that are blanks in Org's syntax table too: no-break space,
-- U+2000..U+200B, U+202F, U+205F and U+3000 (UTF-8).
local USPACES = { ["\194\160"] = true, ["\226\128\175"] = true, ["\226\129\159"] = true, ["\227\128\128"] = true }
for c = 0x80, 0x8b do
  USPACES["\226\128" .. string.char(c)] = true
end

--- Whether a non-ASCII blank ends at byte i of s.
local function uspace_ends(s, i)
  local b = byte(s, i)
  if not b or b < 128 then
    return false
  end
  return USPACES[s:sub(i - 1, i)] or USPACES[s:sub(i - 2, i)] or false
end

--- Whether a non-ASCII blank starts at byte i of s.
local function uspace_starts(s, i)
  local b = byte(s, i)
  if not b or b < 194 then
    return false
  end
  return USPACES[s:sub(i, i + 1)] or USPACES[s:sub(i, i + 2)] or false
end

--- Whether `ui.highlighter` makes buffer `bufnr` draw emphasis this way
--- (a buffer's `b:org_ui` can set it, like the other `ui` options). Only
--- org buffers do: one that just uses the org syntax keeps its regions.
---@param bufnr? integer
---@return boolean
function M.active(bufnr)
  local ui = require("org.config").opts.ui or {}
  local h = ui.highlighter
  if bufnr and bufnr ~= 0 and vim.api.nvim_buf_is_valid(bufnr) then
    -- (the decorations draw org buffers only: a buffer with just the org
    -- syntax, like the drill window, keeps the syntax regions)
    if vim.bo[bufnr].filetype ~= "org" then
      return false
    end
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
---| "table" # a table row
---| "comment" # links, no markup faces, markers shown (org-at-comment-p)
---| "qcomment" # a comment in a quote block: faces, markers shown
---| "info" # a document info keyword or block line: markers and links hidden, no faces
---| "fixed" # fixed width: markup faces, nothing hidden
---| "none" # nothing drawn: src, example and export blocks, other keywords

--- What line `line` holds, outside blocks (see `M.kinds`).
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
    -- a meta line: "#+" and letters (org-fontify-meta-lines-and-blocks)
    if c2 == 43 and line:find("^#%+%a", s) then
      local key = line:match("^#%+(%a+):", s)
      if key and INFO[key:lower()] then
        return "info"
      end
      -- the begin line of a quote, center or special block, drawn in its
      -- own face like the info keywords (`M.kinds` draws an unterminated
      -- one as text, and a block's end line like its begin line; an end
      -- line that closes nothing draws nothing)
      if line:find("^#%+[bB][eE][gG][iI][nN]_", s) then
        return "info"
      end
      return "none"
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
-- (string-match-p on the text of the markup or link: "^" after a line
-- break, "$" at the end of the part; case-sensitive, as font-lock
-- matches). Emphasis or a link whose text holds one isn't drawn.
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
    if cells and cells:find("^%-") and cells:find("%+$") and not cells:find("++", 1, true) then
      return true
    end
  elseif c == 35 then
    local c2 = byte(s, i + 1)
    if c2 == nil or c2 == 32 then
      return true
    end
    return c2 == 43
      and (s:find("^#%+BEGIN_%S", i) ~= nil or s:find("^#%+%S+:", i) ~= nil or s:find("^#%+%S+%[.*%]:", i) ~= nil)
  elseif c == 58 then
    local c2 = byte(s, i + 1)
    return c2 == nil or c2 == 32 or s:find("^:[-_%w\128-\255]+:[ \t]*$", i) ~= nil
  elseif c == 45 and s:find("^%-%-%-%-%-+[ \t]*$", i) then
    return true
  elseif c == 92 and s:find("^\\begin{[%w*]+}", i) then
    return true
  elseif s:find("^CLOCK:", i) then
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
M.separates = separates

--- Whether `line` ends the search for a block's end line: a headline or a
--- line of stars only (Emacs: "^\*+[[:space:]]").
local function star_line(line)
  return byte(line, 1) == 42 and (line:find("^%*+[ \t]") ~= nil or line:find("^%*+$") ~= nil)
end

--- The name of the block a `#+begin_NAME` / `#+end_NAME` line opens or
--- closes (lowercase), and whether it begins one. Names are letters
--- (`#+begin_src_x` begins a src block); an end line's name ends at a
--- character that isn't part of a word (`#+end_verse_` closes a verse
--- block, `#+end_verse1` nothing).
---@return string?, boolean?
local function block_line(line)
  local name = line:match("^[ \t]*#%+[bB][eE][gG][iI][nN]_(%a+)")
  if name then
    return name:lower(), true
  end
  local e
  name, e = line:match("^[ \t]*#%+[eE][nN][dD]_(%a+)()")
  local b = name and byte(line, e)
  -- (word characters in Org's syntax table: letters, digits, $ % ')
  if name and not (b and (b >= 128 or b == 36 or b == 37 or b == 39 or (b >= 48 and b <= 57))) then
    return name:lower(), false
  end
end

---@class org.ui.emphasis.Block
---@field name string
---@field verbatim boolean src, example or export (nothing drawn in it)
---@field row? integer 0-based row of its begin line (when found above the lines drawn)
---@field line? string its begin line (likewise)

---@class org.ui.emphasis.Role
---@field block org.ui.emphasis.Block the block the line is in
---@field role "begin"|"body"|"end"

--- What each of `lines` holds, from the block state of the line before
--- them (`block`). A `#+begin_NAME` opens a block when a `#+end_NAME` or a
--- line of stars follows (`closed_after`: whether one follows the last of
--- `lines`). In a src, example or export block nothing is drawn; in other
--- blocks the lines aren't keywords or comments (Emacs draws their body as
--- text), and their begin and end lines are drawn like info keywords. The
--- second result: per line in a block, which block and its role there.
---@param lines string[]
---@param block? org.ui.emphasis.Block|false
---@param closed_after? fun(name: string): boolean
---@return org.ui.emphasis.Kind[], table<integer, org.ui.emphasis.Role>
function M.kinds(lines, block, closed_after)
  local n = #lines
  -- the next line of stars, and the end lines by name
  local next_star = {} ---@type table<integer, integer>
  local ns ---@type integer?
  for i = n, 1, -1 do
    if star_line(lines[i]) then
      ns = i
    end
    next_star[i] = ns
  end
  local ends = {} ---@type table<string, integer[]>
  for i, line in ipairs(lines) do
    local name, begins = block_line(line)
    if name and not begins then
      local t = ends[name] or {}
      t[#t + 1] = i
      ends[name] = t
    end
  end
  local at = {} ---@type table<string, integer>
  local function closed(i, name)
    if next_star[i + 1] then
      return true
    end
    local t, k = ends[name] or {}, at[name] or 1
    while t[k] and t[k] <= i do
      k = k + 1
    end
    at[name] = k
    if t[k] then
      return true
    end
    return closed_after ~= nil and closed_after(name)
  end

  local kinds = {} ---@type org.ui.emphasis.Kind[]
  local roles = {} ---@type table<integer, org.ui.emphasis.Role>
  local cur = block or false ---@type org.ui.emphasis.Block|false
  if cur and not closed(0, cur.name) then
    cur = false
  end
  for i, line in ipairs(lines) do
    local kind
    local name, begins = block_line(line)
    if star_line(line) then
      cur = false
      kind = classify(line)
    elseif cur then
      if name == cur.name and not begins then
        kind = cur.verbatim and "none" or "info"
        roles[i] = { block = cur, role = "end" }
        cur = false
      elseif cur.verbatim then
        kind = "none"
        roles[i] = { block = cur, role = "body" }
      else
        roles[i] = { block = cur, role = "body" }
        local k = classify(line)
        kind = (k == "none" or k == "info") and "text" or k == "comment" and "qcomment" or k
      end
    elseif name and begins then
      if closed(i, name) then
        cur = { name = name, verbatim = VERBATIM_BLOCKS[name] == true }
        kind = cur.verbatim and "none" or "info"
        roles[i] = { block = cur, role = "begin" }
      else
        -- (no end: no block, and its line is text)
        kind = "text"
      end
    else
      kind = classify(line)
    end
    kinds[i] = kind
  end
  return kinds, roles
end

M.star_line = star_line
M.block_line = block_line
M.VERBATIM_BLOCKS = VERBATIM_BLOCKS

-- The scan ------------------------------------------------------------------

--- The first occurrence of `needle` in `s` at or after a position, for
--- positions that mostly go up: the last answer stands for every position
--- between the one it was asked for and itself (many openings before one
--- closing, or none, search the text once, not once each).
---@return fun(from: integer): integer?
local function finder(s, needle)
  local last_from, last_at = math.huge, nil ---@type integer, integer?
  return function(from)
    if from >= last_from and (last_at == nil or from <= last_at) then
      return last_at
    end
    last_from, last_at = from, s:find(needle, from, true)
    return last_at
  end
end

-- Link types Emacs knows (org-link-types) besides org.nvim's
local EMACS_TYPES = { rmail = true, mhe = true, gnus = true, bbdb = true, shortdoc = true }

--- The link types of plain and angle links: org.nvim's, `links.types`
--- and Emacs's.
---@return table<string, boolean>
function M.link_types()
  local types = {}
  for k in pairs(require("org.links.schemes")) do
    types[k] = true
  end
  for k in pairs(EMACS_TYPES) do
    types[k] = true
  end
  local custom = (require("org.config").opts.links or {}).types or {}
  for k in pairs(custom) do
    if type(k) == "string" then
      types[k] = true
    end
  end
  return types
end

-- a plain link path character (org-link-plain-re): no brackets, blanks,
-- parentheses or angles
local PATH_STOP = set_of(" \t\n[]()<>")
local OPEN_GROUP = set_of("(<[")
local CLOSE_GROUP = set_of(")>]")
local PUNCT = set_of([=[!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~]=])

--- The bracket links of `s` and the ends of its angle and plain links, as
--- org-activate-links finds them (org-link-any-re, from left to right: a
--- plain link that runs into a bracket link takes it in), as the byte
--- ranges of bracket links descriptive display hides: "[[target][" and
--- "]]", or "[[" and "]]". A link whose text holds the start of a
--- paragraph after a line break isn't one. The second result: the links
--- found, as { first byte, last byte, style } ("bracket", "angle" or
--- "plain"), for org.ui.highlight.object.
---@param s string
---@param types table<string, boolean>
---@param line_of fun(i: integer): integer
---@param line_start fun(l: integer): integer
---@return integer[][], { [1]: integer, [2]: integer, [3]: string }[]
local function links(s, types, line_of, line_start)
  local n = #s
  local out = {}
  local found = {} ---@type { [1]: integer, [2]: integer, [3]: string }[]
  local find_bracket = finder(s, "[[")
  local find_angle = finder(s, "<")
  local find_colon = finder(s, ":")
  local find_close = finder(s, "]]")

  --- Whether the text of a link at [a, e] holds no paragraph start.
  local function one_paragraph(a, e)
    local l1, l2 = line_of(a), line_of(e)
    for l = l1 + 1, l2 do
      local ls = line_start(l)
      local le = math.min(e, line_start(l + 1) - 2)
      if separates(s:sub(ls, le)) then
        return false
      end
    end
    return true
  end

  local function bracket(p)
    -- the target: no unescaped brackets (an odd number of backslashes
    -- escapes one); a line break is allowed
    local j = p + 2
    while true do
      local b = byte(s, j)
      if b == nil or b == 91 then
        return
      elseif b == 92 then
        local k = j
        while byte(s, j) == 92 do
          j = j + 1
        end
        local c = byte(s, j)
        if c == nil then
          return
        elseif (c == 91 or c == 93) and (j - k) % 2 == 1 then
          j = j + 1
        end
      elseif b == 93 then
        break
      else
        j = j + 1
      end
    end
    if j == p + 2 then
      return
    end
    local nb = byte(s, j + 1)
    if nb == 93 then
      return j + 1, { { p, p + 1 }, { j, j + 1 } }
    elseif nb == 91 then
      -- the description: anything, up to the first "]]"
      local k = find_close(j + 3)
      if k then
        return k + 1, { { p, j + 1 }, { k, k + 1 } }
      end
    end
  end

  local function angle(p)
    -- <type:path>: the path may go on over lines that don't start with ">"
    local j = s:match("^<[%w_+%-]+:()", p)
    while j do
      local b = byte(s, j)
      if b == nil then
        return
      elseif b == 62 then
        return j
      elseif b == 10 then
        local q = s:match("^[ \t]*()", j + 1)
        local c = byte(s, q)
        if c == nil or c == 62 or c == 10 then
          return
        end
        j = q
      else
        j = j + 1
      end
    end
  end

  --- The end of a group "(...)", "<...>" or "[...]" of a plain link path
  --- (one level of groups in it) at byte j, or nil.
  local function group(j)
    local k = j + 1
    while true do
      local c = byte(s, k)
      if c == nil then
        return
      elseif CLOSE_GROUP[c] then
        return k
      elseif OPEN_GROUP[c] then
        local m = k + 1
        while byte(s, m) and not PATH_STOP[byte(s, m)] do
          m = m + 1
        end
        if not CLOSE_GROUP[byte(s, m) or 0] then
          return
        end
        k = m + 1
      elseif not PATH_STOP[c] then
        k = k + 1
      else
        return
      end
    end
  end

  local function plain(q)
    -- the path after "type:": characters and groups, the last one not
    -- punctuation (but "/" and "-")
    local j, last = q, nil
    while j <= n do
      local b = byte(s, j)
      if OPEN_GROUP[b] then
        local e = group(j)
        if not e then
          break
        end
        last, j = e, e + 1
      elseif not PATH_STOP[b] then
        if not (PUNCT[b] or SPACE[b]) or b == 47 or b == 45 then
          last = j
        end
        j = j + 1
      else
        break
      end
    end
    return last
  end

  local function word_start(x)
    local b = byte(s, x - 1)
    return b == nil or not (b >= 128 or s:sub(x - 1, x - 1):find("%w"))
  end

  -- the next start of each kind at or after a position
  local next_b, next_a, next_p, next_p_path ---@type integer?, integer?, integer?, integer?
  local colon_from = 1
  local i = 1
  while i <= n do
    if not next_b or next_b < i then
      next_b = find_bracket(i) or n + 1
    end
    if not next_a or next_a < i then
      local q = i
      next_a = n + 1
      while true do
        local a = find_angle(q)
        if not a then
          break
        end
        local t = s:match("^<([%w_+%-]+):", a)
        if t and types[t] then
          next_a = a
          break
        end
        q = a + 1
      end
    end
    if not next_p or next_p < i then
      next_p = n + 1
      local q = math.max(colon_from, i)
      while true do
        local c = find_colon(q)
        if not c then
          break
        end
        -- the leftmost link type ending at the colon, at a word start
        local r = c
        while r > i and r > c - 24 and s:sub(r - 1, r - 1):find("[%w_+%-]") do
          r = r - 1
        end
        local found
        for x = r, c - 1 do
          if word_start(x) and types[s:sub(x, c - 1)] then
            found = x
            break
          end
        end
        if found then
          next_p, next_p_path = found, c + 1
          colon_from = c
          break
        end
        q = c + 1
      end
    end
    local p = math.min(next_b, next_a, next_p)
    if p > n then
      break
    end
    local e, hide
    if p == next_b then
      e, hide = bracket(p)
    elseif p == next_a then
      e = angle(p)
    else
      e = plain(next_p_path)
    end
    if e and one_paragraph(p, e) then
      found[#found + 1] = { p, e, p == next_b and "bracket" or p == next_a and "angle" or "plain" }
      for _, h in ipairs(hide or {}) do
        out[#out + 1] = h
      end
      i = e + 1
    else
      i = p + 1
    end
  end
  return out, found
end
M._links = links

--- The inline src blocks of `s` (src_LANG[HEADERS]{BODY}), drawn natively
--- in Emacs: no emphasis faces on their braces and body, byte -> true.
---@param s string
---@return table<integer, boolean>
local function inline_src(s)
  local out = {}
  -- (\_<: not after a symbol constituent)
  local symbol = set_of("$%&'*+-/=_|~\\")
  local function matching(j, open, close, lines)
    local depth, breaks = 0, 0
    while true do
      local c = byte(s, j)
      if c == nil then
        return
      elseif c == open then
        depth = depth + 1
      elseif c == close then
        depth = depth - 1
        if depth == 0 then
          return j
        end
      elseif c == 10 then
        breaks = breaks + 1
        if breaks > lines then
          return
        end
      end
      j = j + 1
    end
  end
  local i = 1
  while true do
    local p = s:find("src_", i, true)
    if not p then
      return out
    end
    i = p + 4
    local b = byte(s, p - 1)
    if b == nil or not (b >= 128 or symbol[b] or s:sub(p - 1, p - 1):find("%w")) then
      local e = s:match("^src_[^ \t\n%[{]+()", p)
      if e and byte(s, e) == 91 then
        local h = matching(e, 91, 93, 0)
        e = h and h + 1
      end
      local last = e and byte(s, e) == 123 and matching(e, 123, 125, 1)
      if last then
        for x = e, last do
          out[x] = true
        end
        i = last + 1
      end
    end
  end
end

---@class org.ui.emphasis.Region
---@field m string the marker
---@field open integer byte of the opening marker
---@field close integer byte of the closing marker

--- The emphasis of `s` (lines joined by "\n"), in the order of their
--- opening markers, as org-do-emphasis-faces finds it: every marker after
--- a blank, one of -('"{ or the start of a line, before a non-blank, with
--- the shortest text up to the same marker after a non-blank and before a
--- blank, one of -.,:!?;'")}[\ or the end of a line, over at most one line
--- break; not when that text holds the start of a paragraph, not over a
--- "|" in a table row, no headline stars, no "+" in a table rule. (Lines
--- don't matter here: what a line draws of it is decided after.)
---@param s string
---@param line_of fun(i: integer): integer the line (index) of byte i
---@param line_start fun(l: integer): integer the first byte of line l
---@param line_text fun(l: integer): string? line l (0: the line before)
---@return org.ui.emphasis.Region[]
local function emphasis(s, line_of, line_start, line_text)
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
      if
        not SPACE[before]
        and not uspace_ends(s, i - 1)
        and (after == nil or POST[after] or uspace_starts(s, i + 1))
      then
        local t = closes[m]
        t[#t + 1] = i
      end
    end
  end
  local next_at = {} ---@type table<string, integer>
  for m in pairs(M.GROUPS) do
    next_at[m] = 1
  end
  local find_bar = finder(s, "|")
  local second = {} ---@type table<integer, boolean> closing marker -> separates
  local rule = {} ---@type table<integer, boolean> line -> a table rule
  local out = {}
  for p = 1, n - 2 do
    local m = MARKERS[byte(s, p)]
    if m then
      local before, after = byte(s, p - 1), byte(s, p + 1)
      if
        (before == nil or PRE[before] or uspace_ends(s, p - 1))
        and after
        and not SPACE[after]
        and not uspace_starts(s, p + 1)
      then
        -- the first closing marker at p + 2 or after (openings go up, and
        -- so does the closing found for them)
        local t, k = closes[m], next_at[m]
        while t[k] and t[k] < p + 2 do
          k = k + 1
        end
        next_at[m] = k
        local c = t[k]
        local l = line_of(p)
        local ls = line_start(l)
        if c then
          local ok = true
          local l2 = line_of(c)
          if l2 > l + 1 then
            ok = false
          elseif l2 == l + 1 then
            -- the second line, up to the closing marker
            local sep = second[c]
            if sep == nil then
              sep = separates(s:sub(line_start(l2), c))
              second[c] = sep
            end
            ok = not sep
          end
          -- the text from the opening marker on: of the separators, only
          -- stars and a space ("** x") or a table.el rule ("+--+") can start
          -- with a marker
          local head_end = l2 == l and c or line_start(l + 1) - 2
          local stars_end = m == "*" and s:match("^%*+() ", p)
          if ok and stars_end and stars_end <= head_end then
            ok = false
          elseif ok and m == "+" then
            local e = p
            while e < head_end and (byte(s, e + 1) == 43 or byte(s, e + 1) == 45) do
              e = e + 1
            end
            if e == head_end or s:sub(e + 1, head_end):find("^[ \t]*$") then
              ok = not separates(s:sub(p, head_end))
            end
          end
          -- headline stars: not as an opening marker
          if ok and m == "*" and p == ls and s:find("^%*+ ", ls) then
            ok = false
          end
          -- Emacs looks at the line of the character before the marker:
          -- for a marker at the start of a line, the line above
          -- (at the top of the buffer, the line itself)
          local tl = p == ls and l - 1 or l
          local text = line_text(tl)
          if tl == 0 and text == nil then
            tl, text = l, line_text(l)
          end
          if ok and text and text:find("^[ \t]*|") then
            -- not over a "|" in a table row
            local bar = find_bar(p + 1)
            ok = not (bar and bar < c)
          end
          if ok and m == "+" and text then
            -- a table rule (|---+---| or +---+---+)
            local r = rule[tl]
            if r == nil then
              r = text:find("^[ \t]*|[-+]+|?[ \t]*$") ~= nil or text:find("^[ \t]*%+[-+]+%+[ \t]*$") ~= nil
              rule[tl] = r
            end
            ok = not r
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

M._emphasis = emphasis

---@class org.ui.emphasis.MarksOpts
---@field hide_markers boolean ui.hide_emphasis_markers
---@field conceal_links boolean ui.conceal_links (descriptive links)
---@field reveal? boolean hide nothing, the markers that would be hidden drawn as text (the body of an org src block: Emacs copies only the faces of the Org buffer it fontifies it in)
---@field block? org.ui.emphasis.Block|false the block open before `lines`
---@field prev? string the line before `lines`
---@field closed_after? fun(name: string): boolean (see `M.kinds`)
---@field types? table<string, boolean> link types (default `M.link_types()`)

--- Emphasis and link marks for `lines`, buffer lines from row `row0`
--- (0-based) on, in the block state `opts.block` (see `M.kinds`), after
--- the line `opts.prev` (nil at the top of the buffer). Marks for rows
--- `first` to `last` are added to `rows`:
--- `{ [row] = { { col, opts, nil, "emphasis" }, ... } }`.
---@param lines string[]
---@param row0 integer
---@param first integer
---@param last integer
---@param opts org.ui.emphasis.MarksOpts
---@param rows table<integer, table[]>
function M.marks(lines, row0, first, last, opts, rows)
  local kinds = M.kinds(lines, opts.block, opts.closed_after)

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
  local function line_text(l)
    if l == 0 then
      return opts.prev
    end
    return lines[l]
  end

  -- What is hidden, byte by byte. Emacs hides link brackets first
  -- (org-activate-links), then goes through the emphasis in order: verbatim
  -- and code show what is hidden in them, then each emphasis hides its
  -- markers (not when it opens in a comment, org-at-comment-p). So a byte
  -- is hidden when the last emphasis that hid it as a marker comes after
  -- the last verbatim over it, or, with no verbatim over it, when it is
  -- part of a link or a marker. Lines that draw nothing (src blocks,
  -- keywords) and fixed-width lines show everything.
  local link_hidden = {} ---@type table<integer, boolean>
  if opts.conceal_links then
    for _, r in ipairs(links(s, opts.types or M.link_types(), line_of, line_start)) do
      for x = r[1], r[2] do
        link_hidden[x] = true
      end
    end
  end
  local regions = emphasis(s, line_of, line_start, line_text)
  local marker_at = {} ---@type table<integer, integer> byte -> last emphasis hiding it
  local spans = {} ---@type integer[][] verbatim and code: { open, close, index }
  for i, r in ipairs(regions) do
    if r.m == "=" or r.m == "~" then
      spans[#spans + 1] = { r.open, r.close, i }
    end
    local k = kind_of(line_of(r.open))
    if opts.hide_markers and k ~= "comment" and k ~= "qcomment" then
      marker_at[r.open], marker_at[r.close] = i, i
    end
  end
  local native = s:find("src_", 1, true) and inline_src(s) or {}
  local hidden = {} ---@type table<integer, boolean>
  -- The last verbatim over each byte, in one pass: a stack of the spans
  -- open there, each later one closing before the one under it (a later
  -- span that closes after an earlier one stands for it from then on).
  local stack, vi = {}, 1
  for x = 1, #s do
    while spans[vi] and spans[vi][1] <= x do
      local sp = spans[vi]
      while stack[#stack] and stack[#stack][2] <= sp[2] do
        stack[#stack] = nil
      end
      stack[#stack + 1] = sp
      vi = vi + 1
    end
    while stack[#stack] and stack[#stack][2] < x do
      stack[#stack] = nil
    end
    local over = stack[#stack] and stack[#stack][3]
    local hide
    if over then
      hide = marker_at[x] ~= nil and marker_at[x] >= over
    else
      hide = link_hidden[x] or marker_at[x] ~= nil
    end
    if hide then
      local k = kind_of(line_of(x))
      if k ~= "fixed" and k ~= "none" then
        hidden[x] = true
      end
    end
  end

  if opts.reveal then
    hidden = {}
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
  --- Mark bytes [a, b] of `s`, line by line; with `face`, only on the
  --- lines that draw markup faces (not comments, keywords, src blocks) and
  --- not on inline src blocks. Whether a mark was made.
  ---@return boolean
  local function span(a, b, o, face)
    local made = false
    while a <= b do
      local l = line_of(a)
      local e = math.min(b, line_start(l + 1) - 2)
      local k = kind_of(l)
      if e >= a and not (face and (k == "comment" or k == "info" or k == "none")) then
        local skip = face and next(native) ~= nil
        local x = a
        while x <= e do
          while skip and x <= e and native[x] do
            x = x + 1
          end
          local y = skip and x or e
          while skip and y < e and not native[y + 1] do
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
  -- the number of markups still open where one opens (a min-heap of their
  -- closing markers), which a scan that starts elsewhere finds the same.
  local heap = {} ---@type integer[]
  local function push(v)
    heap[#heap + 1] = v
    local i = #heap
    while i > 1 and heap[math.floor(i / 2)] > heap[i] do
      local j = math.floor(i / 2)
      heap[i], heap[j] = heap[j], heap[i]
      i = j
    end
  end
  local function pop()
    local n = #heap
    heap[1] = heap[n]
    heap[n] = nil
    local i = 1
    while true do
      local l, r, m = 2 * i, 2 * i + 1, i
      if heap[l] and heap[l] < heap[m] then
        m = l
      end
      if heap[r] and heap[r] < heap[m] then
        m = r
      end
      if m == i then
        return
      end
      heap[i], heap[m] = heap[m], heap[i]
      i = m
    end
  end
  -- The texts of markup of one kind that overlap draw as their union: one
  -- mark per run (many openings with one far closing marker would put as
  -- many marks over the same bytes).
  local runs = {} ---@type table<string, { [1]: integer, [2]: integer, [3]: integer }>
  local function flush(m)
    local run = runs[m]
    if run then
      local spell ---@type boolean?
      if m == "=" or m == "~" then
        spell = false -- (like the syntax regions: no @Spell)
      end
      span(run[1], run[2], { hl_group = M.GROUPS[m], priority = run[3], spell = spell }, true)
      runs[m] = nil
    end
  end
  local covered = {} ---@type table<integer, boolean> hidden by a marker's mark
  for _, r in ipairs(regions) do
    local group = M.GROUPS[r.m]
    while heap[1] and heap[1] < r.open do
      pop()
    end
    local prio = 101 + math.min(#heap, 50)
    push(r.close)
    local run = runs[r.m]
    -- (same priority only: a drawing of rows found elsewhere in the
    -- buffer sees the same runs; the priority stops growing at 50)
    if run and run[3] == prio and r.open + 1 <= run[2] + 1 then
      run[2] = math.max(run[2], r.close - 1)
    else
      flush(r.m)
      runs[r.m] = { r.open + 1, r.close - 1, prio }
    end
    local spell ---@type boolean?
    if r.m == "=" or r.m == "~" then
      spell = false
    end
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
  for m in pairs(M.GROUPS) do
    flush(m)
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

--- Emphasis and link marks of rows `first` to `last` (0-based) of buffer
--- `bufnr`, added to `rows` (the format of org.ui.decorations `compute`),
--- from the window org.ui.highlight scans for them.
---@param bufnr integer
---@param first integer
---@param last integer
---@param ui table the buffer's `ui` options
---@param rows table<integer, table[]>
function M.add_marks(bufnr, first, last, ui, rows)
  local w = require("org.ui.highlight").window(bufnr, first, last)
  local b = vim.b[bufnr]
  local hide = ui.hide_emphasis_markers and true or false
  if b.org_hide_emphasis_markers ~= nil then
    hide = b.org_hide_emphasis_markers and true or false
  end
  local conceal_links = ui.conceal_links ~= false
  if b.org_link_descriptive ~= nil then
    conceal_links = b.org_link_descriptive and true or false
  end
  M.marks(w.lines, w.row0, first, last, {
    hide_markers = hide,
    conceal_links = conceal_links,
    block = w.block,
    prev = w.prev,
    closed_after = w.closed_after,
  }, rows)
end

return M

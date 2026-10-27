---@mod org.ui.highlight.object Links and other objects
---
--- Part of org.ui.highlight (the parser highlighter): the faces of bracket, angle, plain and radio links (`links.types` faces; what descriptive display hides is org.ui.emphasis), footnotes, targets, macros (`ui.hide_macro_markers`), export snippets, inline src blocks and line breaks.
---
--- A port of what org-set-font-lock-defaults draws for them, in its order
--- (each later rule prepends its face, so it gets a higher priority here):
--- org-activate-links, org-activate-target-links (radio links),
--- org-activate-footnote-links, the radio target and target regexps,
--- org-fontify-macros, the export snippet regexp and
--- org-fontify-inline-src-blocks. The objects are looked for in the text of
--- all the lines scanned (joined by "\n"), the way Emacs searches the
--- buffer, then the lines decide what is drawn: org-fontify-meta-lines-and-
--- blocks gives comments, keywords, info keywords and block lines their own
--- face over everything found before it (only inline src blocks come
--- after), and src, example and export blocks are drawn natively. Citations
--- are org.cite's (org.cite.attach draws them). Every search goes through
--- the text once or remembers what it found, so the time is linear in the
--- length of the lines.

-- Not compiled by the JIT, like org.ui.highlight (see the comment there).
if jit then
  jit.off(true, true)
end

local M = {}

local E = require("org.ui.emphasis")
local PRIO = require("org.ui.highlight").PRIO

local byte = string.byte

-- Later rules over earlier ones (org-set-font-lock-defaults prepends them
-- in this order), all under emphasis (101 and up).
local P = {
  link = PRIO.object,
  footnote = PRIO.object + 1,
  target = PRIO.object + 2,
  macro = PRIO.object + 3,
  snippet = PRIO.object + 3,
  inline_src = PRIO.object + 4,
}

-- The kinds of lines (org.ui.emphasis `kinds`) whose objects have their
-- faces: not comments, keywords and block lines (drawn over by
-- org-fontify-meta-lines-and-blocks), nor src, example and export blocks
-- (fontified natively).
local DRAWN = { text = true, table = true, fixed = true, qcomment = true }
-- Lines where only the spelling of a link is left out (Emacs removes the
-- flyspell overlays of links before the line's face is put over them; the
-- other objects of a comment are spell checked, as flyspell and the syntax
-- engine check all of a comment).
local NOSPELL = { comment = true, info = true }
-- The document info keywords (org-fontify-meta-lines-and-blocks).
local INFO_KEYWORDS = { title = true, subtitle = true, author = true, email = true, date = true }

--- The highlight group of the custom link type `name` with face `face`
--- (`links.types.<name>.face`), defined (default link) once.
local defined = {} ---@type table<string, string>
local function type_group(name, face)
  local group = "orgLinkType_" .. name:gsub("[^%w_]", "_")
  if defined[group] ~= face then
    defined[group] = face
    vim.api.nvim_set_hl(0, group, { link = face, default = true })
  end
  return group
end
-- (a colorscheme clears them)
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("org.ui.highlight.object", { clear = true }),
  callback = function()
    defined = {}
  end,
})

--- The faces of the custom link types: type -> group.
---@return table<string, string>
local function custom_groups()
  local out = {}
  local types = (require("org.config").opts.links or {}).types or {}
  for name, def in pairs(types) do
    local face = type(def) == "table" and def.face or nil
    if type(name) == "string" and type(face) == "string" and name:match("^[%w_+%-]+$") then
      out[name] = type_group(name, face)
    end
  end
  return out
end

-- Radio targets --------------------------------------------------------------

-- (org-radio-target-regexp: "<<<", a non-blank, anything but angles and
-- line breaks, a non-blank, ">>>")
local BORDER_STOP = { [60] = true, [62] = true, [10] = true, [13] = true, [32] = true, [9] = true }

--- The end (byte of the last ">") of a target at byte p of s, opened by
--- `n` "<" (2: <<target>>, 3: <<<radio>>>), or nil (org-target-regexp,
--- org-radio-target-regexp).
---@return integer?
local function target_end(s, p, n)
  local b = byte(s, p + n)
  if not b or BORDER_STOP[b] then
    return
  end
  local q = s:find("[<>\n\r]", p + n + 1) or #s + 1
  -- (the character before the closing angles is a border)
  if BORDER_STOP[byte(s, q - 1)] then
    return
  end
  for k = 0, n - 1 do
    if byte(s, q + k) ~= 62 then
      return
    end
  end
  return q + n - 1
end

--- The radio targets of a parse (org-update-radio-target-regexp): the text
--- of each <<<target>>> outside comments, keywords, fixed width lines, src
--- and example blocks, bracket links, verbatim and code (where
--- org-element-context finds no radio target), longest first; kept per
--- parse.
local radio_cache = setmetatable({}, { __mode = "k" }) ---@type table<table, string[]>
---@param file org.File
---@return string[]
local function radio_targets(file)
  local cached = radio_cache[file]
  if cached then
    return cached
  end
  local lines = file.lines or {}
  local any = false
  for _, l in ipairs(lines) do
    if l:find("<<<", 1, true) then
      any = true
      break
    end
  end
  local out, seen = {}, {}
  if any then
    local kinds = E.kinds(lines)
    local types = E.link_types()
    for i, l in ipairs(lines) do
      local k = kinds[i]
      if k ~= "none" and k ~= "comment" and k ~= "info" and k ~= "fixed" and l:find("<<<", 1, true) then
        local function line_of()
          return 1
        end
        local function line_start(x)
          return x == 1 and 1 or #l + 2
        end
        local _, found = E._links(l, types, line_of, line_start)
        -- (in verbatim or code, it is text)
        local verbatim = {}
        for _, r in
          ipairs(E._emphasis(l, line_of, line_start, function(x)
            return x == 0 and lines[i - 1] or l
          end))
        do
          if r.m == "=" or r.m == "~" then
            verbatim[#verbatim + 1] = r
          end
        end
        local p = 1 ---@type integer?
        while true do
          p = l:find("<<<", p, true)
          if not p then
            break
          end
          local e = target_end(l, p, 3)
          local inside = false
          for _, f in ipairs(found) do
            if f[3] == "bracket" and p >= f[1] and p <= f[2] then
              inside = true
            end
          end
          for _, r in ipairs(verbatim) do
            if p > r.open and p < r.close then
              inside = true
            end
          end
          if e and not inside then
            local t = l:sub(p + 3, e - 3)
            if not seen[t] then
              seen[t] = true
              out[#out + 1] = t
            end
            p = e + 1
          else
            p = p + 1
          end
        end
      end
    end
    -- (a stable sort, as Emacs's: of two of the same length, the later one)
    local order = {}
    for i, t in ipairs(out) do
      order[t] = i
    end
    table.sort(out, function(a, b)
      if #a ~= #b then
        return #a > #b
      end
      return order[a] > order[b]
    end)
  end
  radio_cache[file] = out
  return out
end

-- org-footnote-forbidden-blocks
local FORBIDDEN = { comment = true, example = true, export = true, src = true }

--- Whether line `l`, in the body of a block, is in a comment, example,
--- export or src block nested in it (org-in-block-p: the nearest begin
--- line above, its end line below), which org.ui.emphasis `kinds` doesn't
--- track.
---@param lines string[]
---@param roles table<integer, org.ui.emphasis.Role>
---@param l integer
local function nested_forbidden(lines, roles, l)
  for j = l - 1, 1, -1 do
    local r = roles[j]
    if not r or r.role ~= "body" then
      return false
    end
    local name, begins = E.block_line(lines[j])
    if name then
      if not (begins and FORBIDDEN[name]) then
        return false
      end
      for k = l + 1, #lines do
        local r2 = roles[k]
        if not r2 or r2.role ~= "body" then
          return false
        end
        local n2, b2 = E.block_line(lines[k])
        if n2 == name and not b2 then
          return true
        end
      end
      return false
    end
  end
  return false
end

--- Whether the character before byte i of s (`after`: the one at byte i)
--- keeps a radio link from starting (ending) there: [[:alnum:]] and not
--- line-breakable (\\c|, such as CJK characters), org-update-radio-target-
--- regexp's boundaries.
---@param s string
---@param i integer
---@param after? boolean
local function alnum(s, i, after)
  local b = byte(s, after and i or i - 1)
  if b == nil then
    return false
  elseif b < 128 then
    return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
  end
  local chars = require("org.ui.chars")
  local cp = after and chars.at(s, i) or not after and chars.before(s, i - 1)
  return cp and chars.alnum_unbreakable(cp) or false
end

--- The radio links of `s` (org-activate-target-links): the leftmost
--- occurrence of a target (ignoring case, its spaces matching any blanks)
--- between non-alphanumerics, of the targets in order at one place; then
--- the next one after it. A list of { first, last } bytes.
---@param s string
---@param targets string[]
---@return integer[][]
local function radio_links(s, targets)
  local lower = s:lower()
  -- per start byte, the first target (in order) that matches there
  local best = {} ---@type table<integer, { [1]: integer, [2]: integer }>
  for k, t in ipairs(targets) do
    local parts = vim.split(t:lower(), " +", { trimempty = true })
    local plain = #parts == 1
    local pat = plain and parts[1] or table.concat(vim.tbl_map(vim.pesc, parts), "[ \t\n]+")
    if pat ~= "" then
      local init = 1
      while true do
        local a, e = lower:find(pat, init, plain)
        if not a then
          break
        end
        if not alnum(s, a) and not alnum(s, e + 1, true) then
          local cur = best[a]
          if not cur or cur[2] > k then
            best[a] = { e, k }
          end
        end
        init = a + 1
      end
    end
  end
  local starts = vim.tbl_keys(best)
  table.sort(starts)
  local out = {}
  local after = 0
  for _, a in ipairs(starts) do
    if a > after then
      local e = best[a][1]
      out[#out + 1] = { a, e }
      -- (the character after it is the one before the next)
      after = e + 1
    end
  end
  return out
end

-- Footnotes ------------------------------------------------------------------

-- org-mode-syntax-table: the parentheses scan-sexps pairs (any closing
-- one closes any opening one, as Emacs's scan_lists doesn't check), and
-- the string quote
local OPEN = { [40] = true, [91] = true, [123] = true, [60] = true }
local CLOSE = { [41] = true, [93] = true, [125] = true, [62] = true }

--- scan-sexps from the "[" at byte p of s with org-mode-syntax-table: the
--- byte of its closing bracket, or nil. `memo` keeps the closing bracket
--- (or false) of every opening one met outside strings, which a scan from
--- there would find the same: nested footnotes don't scan again.
--- The scan stops at byte `limit` (default: the end of s), the line break
--- before the next line of stars: org.nvim's footnote references don't
--- run on over a headline (see `M.reaching`).
---@param memo table<integer, integer|false>
---@param limit? integer
---@return integer?
local function scan_sexp(s, p, memo, limit)
  local m = memo[p]
  if m ~= nil then
    return m or nil
  end
  local stack = { p }
  local j = p + 1
  local n = limit or #s
  while j <= n do
    local b = byte(s, j)
    if b == 34 then
      local q = s:find('"', j + 1, true)
      if not q or q > n then
        break
      end
      j = q
    elseif OPEN[b] then
      stack[#stack + 1] = j
    elseif CLOSE[b] then
      local o = stack[#stack]
      stack[#stack] = nil
      memo[o] = j
      if o == p then
        return j
      end
    end
    j = j + 1
  end
  for _, o in ipairs(stack) do
    memo[o] = false
  end
end

--- Whether the footnote at byte p of s is an argument of a LaTeX macro
--- (org-inside-latex-macro-p: "\name", an optional "*", then [..] or {..}
--- groups up to it, on its line).
local function after_latex_macro(s, p, ls)
  local j = p - 1
  -- the groups before it
  while j >= ls do
    local b = byte(s, j)
    local open = b == 125 and 123 or b == 93 and 91 or nil
    if not open then
      break
    end
    local k = j - 1
    while k >= ls do
      local c = byte(s, k)
      if c == open then
        break
      elseif c == 123 or c == 125 or (open == 91 and (c == 91 or c == 93)) then
        return false
      end
      k = k - 1
    end
    if k < ls then
      return false
    end
    j = k - 1
  end
  if j >= ls and byte(s, j) == 42 then
    j = j - 1
  end
  local e = j
  while j >= ls and s:sub(j, j):find("%a") do
    j = j - 1
  end
  return j < e and j >= ls and byte(s, j) == 92
end

--- The macros and footnote references of `s` (lines joined by "\n") that
--- run on past its end, as `M.paint` finds them in a text that goes on
--- after s: the byte of the first macro opening ("{{{name") with no
--- "}}}" after it before an empty line (the macros after it are in it),
--- and those of the footnote references with no closing bracket (or an
--- open string) in s. Not after a line of stars: unlike Emacs, whose
--- font-lock paints one over every line up to its end (scan-sexps, or a
--- "}}}" before an empty line), org.nvim ends both before the next line of
--- stars, so that the scan of a window (org.ui.highlight `window_of`) need
--- not read back further than the headline above to find them.
---@param s string
---@return integer? macro
---@return integer[]? footnotes
function M.reaching(s)
  local has_macro, has_fn = s:find("{{{", 1, true) ~= nil, s:find("[fn:", 1, true) ~= nil
  if not (has_macro or has_fn) then
    return nil, nil
  end
  -- the start of the line after the last line of stars (plain searches:
  -- a pattern search tries every byte)
  local after_star = 1
  local at = 1
  while true do
    local p = s:find("\n*", at, true)
    if not p then
      break
    end
    local q = s:match("^%*+()", p + 1)
    local c = byte(s, q)
    if c == nil or c == 10 or c == 32 or c == 9 then
      after_star = p + 1
    end
    at = q
  end
  local macro ---@type integer?
  if has_macro then
    -- (the line break before the first empty line from byte `from` on, for
    -- positions that go up; an empty last line too)
    local t = #s
    while byte(s, t) == 32 or byte(s, t) == 9 do
      t = t - 1
    end
    local tail = byte(s, t) == 10 and t or nil ---@type integer?
    local nb_from, nb_at = math.huge, nil ---@type integer, integer?
    local function next_empty(from)
      if not (from >= nb_from and (nb_at == nil or from <= nb_at)) then
        nb_from, nb_at = from, s:find("\n[ \t]*\n", from)
        if not nb_at and tail and tail >= from then
          nb_at = tail
        end
      end
      return nb_at
    end
    local function empty_in(a, b)
      local e = next_empty(a)
      return e and e <= b and e or nil
    end
    local i = after_star
    while true do
      local p = s:find("{{{", i, true)
      if not p then
        break
      end
      local ne = s:match("^{{{%a[-%w_]*()", p)
      if not ne then
        i = p + 1
      else
        local c = s:find("}}}", ne, true)
        local e = empty_in(ne, c or #s)
        if e then
          -- (no macro: an empty line before its "}}}", or before the end)
          -- (the openings before it fail the same way)
          i = e
        elseif c then
          i = c + 3
        else
          macro = p
          break
        end
      end
    end
  end
  local fns ---@type integer[]?
  if has_fn then
    local memo = {} ---@type table<integer, integer|false>
    local i = after_star
    while true do
      local p = s:find("[fn:", i, true)
      if not p then
        break
      end
      i = p + 1
      local q = E.word_end(s, p + 4)
      local c = byte(s, q)
      if p > 1 and byte(s, p - 1) ~= 10 and (c == 58 or (c == 93 and q > p + 4)) and not scan_sexp(s, p, memo) then
        fns = fns or {}
        fns[#fns + 1] = p
      end
    end
  end
  return macro, fns
end

--- The byte of the closing bracket of the footnote reference at byte p of
--- s (scan-sexps), nil when there is none in s.
---@param s string
---@param p integer
---@return integer?
function M.reference_end(s, p)
  return scan_sexp(s, p, {})
end

-- Painting ---------------------------------------------------------------------

--- Whether `s` holds "src_" in any case (an inline src block can start
--- there): a plain search for "_" and a look at the bytes before it,
--- faster than the pattern on prose.
---@param s string
---@return boolean
local function has_src(s)
  local p = s:find("_", 4, true)
  while p do
    local a, b, c = byte(s, p - 3, p - 1)
    if (a == 115 or a == 83) and (b == 114 or b == 82) and (c == 99 or c == 67) then
      return true
    end
    p = s:find("_", p + 1, true)
  end
  return false
end

--- Paint the rows of `ctx` (see org.ui.highlight `Ctx`).
---@param ctx org.ui.highlight.Ctx
function M.paint(ctx)
  local lines = ctx.lines
  if #lines == 0 then
    return
  end
  local s = table.concat(lines, "\n")
  local n = #s
  local kinds = ctx.kinds
  local starts = {} ---@type integer[]
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
    return starts[l] or n + 2
  end

  -- What inline src blocks give their own faces (org-fontify-inline-src-
  -- blocks removes the faces of the objects found before it from their
  -- braces and body): byte -> true.
  local native = {} ---@type table<integer, boolean>
  local inline = {} ---@type { [1]: integer, [2]: integer, [3]: string }[]

  -- whether line l is a `#+CAPTION:` (spell checked, but not its links,
  -- org--flyspell-object-check-p)
  local captions = {} ---@type table<integer, boolean>
  local function caption_line(l)
    local v = captions[l]
    if v == nil then
      v = lines[l]:find("^[ \t]*#%+[cC][aA][pP][tT][iI][oO][nN]") ~= nil
      captions[l] = v
    end
    return v
  end

  --- Mark bytes [a, b] of s, line by line, on the lines that draw objects
  --- (`any`: every line), not on what inline src blocks draw (`over`: on
  --- it too).
  ---@param o org.ui.highlight.MarkOpts
  local function span(a, b, o, any, over)
    -- (bytes [x, y] of line l, but those inline src blocks draw)
    local function put(l, x, y, opts)
      while x <= y do
        while not over and x <= y and native[x] do
          x = x + 1
        end
        local z = x
        while z < y and (over or not native[z + 1]) do
          z = z + 1
        end
        if x <= y then
          ctx.emit(l, x - starts[l], z - starts[l] + 1, opts)
        end
        x = z + 1
      end
    end
    while a <= b do
      local l = line_of(a)
      local e = math.min(b, line_start(l + 1) - 2)
      local k = kinds[l] or "none"
      local opts = o ---@type org.ui.highlight.MarkOpts?
      local g1, g2 ---@type integer?, integer?
      if not any and not DRAWN[k] then
        local nospell = o.link and (NOSPELL[k] or caption_line(l))
        opts = nospell and { spell = false, priority = o.priority } or nil
        if k == "info" then
          -- (the blanks between a document info keyword and its value,
          -- which org-fontify-meta-lines-and-blocks gives no face: a macro
          -- or footnote reference over the line keeps its face there)
          local key, x, y = lines[l]:match("^[ \t]*#%+(%a+):()[ \t]*()")
          if key and INFO_KEYWORDS[key:lower()] and y > x then
            g1, g2 = math.max(a, starts[l] + x - 1), math.min(e, starts[l] + y - 2)
          end
        end
      elseif (k == "comment" or k == "qcomment") and o.spell == false and not o.link then
        -- (all of a comment is spell checked but its links)
        opts = { hl_group = o.hl_group, priority = o.priority, conceal = o.conceal }
      end
      if g1 and g2 and g1 <= g2 then
        if opts then
          put(l, a, g1 - 1, opts)
          put(l, g2 + 1, e, opts)
        end
        put(l, g1, g2, o)
      elseif opts and e >= a then
        put(l, a, e, opts)
      end
      a = line_start(l + 1)
    end
  end

  -- inline src blocks: src_LANG, then [HEADERS] and {BODY}, paired over
  -- at most one line break
  if has_src(s) then
    local symbol = {}
    for c in ("$%&'*+-/=_|~\\"):gmatch(".") do
      symbol[byte(c)] = true
    end
    local lower = s:lower()
    -- (scan-lists with only one kind of bracket: the closing one of every
    -- opening one met is kept, with the limit it was found under, so
    -- openings inside one another scan once)
    local memo = { [91] = {}, [123] = {} } ---@type table<integer, table<integer, { [1]: integer, [2]: integer|false }>>
    local function paired(j, open, close, limit)
      local m = memo[open]
      local known = m[j]
      if known and known[1] == limit then
        return known[2] or nil
      end
      local stack = {}
      local x = j
      while x < limit do
        local c = byte(s, x)
        if c == open then
          stack[#stack + 1] = x
        elseif c == close then
          local o = stack[#stack]
          stack[#stack] = nil
          m[o] = { limit, x }
          if o == j then
            return x
          end
        end
        x = x + 1
      end
      for _, o in ipairs(stack) do
        m[o] = { limit, false }
      end
    end
    local i = 1
    while true do
      local p = lower:find("src_", i, true)
      if not p then
        break
      end
      i = p + 4
      if E.symbol_start(s, p, symbol) then
        local le = s:match("^[^ \t\n%[{]+()", p + 4)
        if le then
          inline[#inline + 1] = { p, p + 3, "orgInlineSrcMarker" }
          inline[#inline + 1] = { p + 4, le - 1, "orgInlineSrcLang" }
          local pt = le
          -- (narrowed to the line and the next one)
          local limit = line_start(line_of(p) + 2) - 1
          if byte(s, pt) == 91 then
            local h = paired(pt, 91, 93, limit)
            if h then
              inline[#inline + 1] = { pt, h, "orgInlineSrcHeader" }
              pt = h + 1
            end
          end
          if byte(s, pt) == 123 then
            local c = paired(pt, 123, 125, limit)
            if c then
              for x = pt, c do
                native[x] = true
              end
              inline[#inline + 1] = { pt, pt, "orgInlineSrcMarker" }
              if c > pt + 1 then
                inline[#inline + 1] = { pt + 1, c - 1, "orgInlineSrcBody" }
              end
              inline[#inline + 1] = { c, c, "orgInlineSrcMarker" }
              pt = c + 1
            end
          end
          i = pt
        end
      end
    end
  end

  -- links (org-activate-links, as org.ui.emphasis finds them)
  local types = ctx.link_types or E.link_types()
  local groups = custom_groups()
  local found = ctx.links or select(2, E._links(s, types, line_of, line_start))
  local brackets = {} ---@type integer[][]
  for _, f in ipairs(found) do
    local a, b, style = f[1], f[2], f[3]
    local t
    if style == "bracket" then
      brackets[#brackets + 1] = { a, b }
      t = s:match("^%[%[([%w_+%-]+):", a)
    elseif style == "angle" then
      t = s:match("^<([%w_+%-]+):", a)
    else
      t = s:match("^([%w_+%-]+):", a)
    end
    local skip = false
    if style == "plain" then
      -- not a tag of a headline (Emacs: not after a character in org-tag)
      local l = line_of(a)
      local line = lines[l]
      if byte(line, 1) == 42 and line:find("^%*+ ") then
        local ts = line:match("[ \t]():[%w_@#%%:]+:[ \t]*$")
        skip = ts ~= nil and a - starts[l] + 1 > ts
      end
    end
    if not skip then
      local group = (t and groups[t]) or (style == "bracket" and "orgLink" or "orgLinkPlain")
      span(a, b, { hl_group = group, priority = P.link, spell = false, link = true })
    end
  end

  -- radio links (org-activate-target-links)
  if s:find("%a") then
    local targets = ctx.file and radio_targets(ctx.file) or {}
    if #targets > 0 then
      for _, r in ipairs(radio_links(s, targets)) do
        span(r[1], r[2], { hl_group = "orgRadioLink", priority = P.link, spell = false, link = true })
      end
    end
  end

  -- footnotes (org-activate-footnote-links): a reference anywhere but at
  -- the start of a line, up to its closing bracket (scan-sexps), not in a
  -- bracket link or a LaTeX macro's argument; a definition's label at the
  -- start of a line, not in a comment, fixed width line or a src, example,
  -- export or comment block
  -- (the line break before the next line of stars after each line: a
  -- macro or a footnote reference ends before it, see `M.reaching`)
  local star_after ---@type table<integer, integer|false>?
  local function bound_after(l)
    if not star_after then
      star_after = {}
      local at = false ---@type integer|false
      for k = #lines, 1, -1 do
        star_after[k] = at
        if E.star_line(lines[k]) then
          at = starts[k] - 1
        end
      end
    end
    return star_after[l] or nil
  end
  if s:find("[fn:", 1, true) then
    local memo = {} ---@type table<integer, integer|false>
    local bi = 1
    local i = 1
    while true do
      local p = s:find("[fn:", i, true)
      if not p then
        break
      end
      i = p + 1
      local q = E.word_end(s, p + 4)
      local label = q - p - 4
      local c = byte(s, q)
      local l = line_of(p)
      if p ~= starts[l] then
        if c == 58 or (c == 93 and label > 0) then
          local e = scan_sexp(s, p, memo, bound_after(l))
          while brackets[bi] and brackets[bi][2] < p do
            bi = bi + 1
          end
          local in_link = brackets[bi] and brackets[bi][1] <= p and p < brackets[bi][2]
          -- (or the path of a "[[fn:...]]" a plain link took in: Emacs
          -- asks org-link-bracket-re, not what was drawn)
          in_link = in_link or (byte(s, p - 1) == 91 and s:find("^%[%[[^%[%]]+%]", p - 1) ~= nil)
          if e and not in_link and not after_latex_macro(s, p, starts[l]) then
            local head = c == 58 and q or e
            span(p, head, { hl_group = "orgFootnote", priority = P.footnote, spell = false })
            if head < e then
              span(head + 1, e - 1, { hl_group = "orgFootnote", priority = P.footnote })
              span(e, e, { hl_group = "orgFootnote", priority = P.footnote, spell = false })
            end
          end
        end
      elseif c == 93 and label > 0 then
        local k = kinds[l]
        local role = ctx.roles[l]
        local block = role and role.role == "body" and role.block.name
        if
          k ~= "comment"
          and k ~= "qcomment"
          and k ~= "fixed"
          and block ~= "comment"
          and block ~= "example"
          and block ~= "export"
          and block ~= "src"
          and not (block and nested_forbidden(lines, ctx.roles, l))
        then
          span(p, q, { hl_group = "orgFootnote", priority = P.footnote, spell = false })
        end
      end
    end
  end

  -- targets: radio targets, then targets (org-radio-target-regexp,
  -- org-target-regexp)
  if s:find("<<", 1, true) then
    for _, depth in ipairs({ 3, 2 }) do
      local open = depth == 3 and "<<<" or "<<"
      local i = 1
      while true do
        local p = s:find(open, i, true)
        if not p then
          break
        end
        local e = target_end(s, p, depth)
        if e then
          span(p, e, { hl_group = "orgTarget", priority = P.target, spell = false })
          i = e + 1
        else
          i = p + 1
        end
      end
    end
  end

  -- macros (org-fontify-macros): {{{name, then the first }}} before an
  -- empty line (or a line of stars, see `M.reaching`)
  if s:find("{{{", 1, true) then
    local hide = ctx.ui.hide_macro_markers and true or false
    -- the empty lines (blanks only) and lines of stars, in order
    local empty = {} ---@type integer[]
    for l = 2, #lines do
      if not lines[l]:find("[^ \t]") or E.star_line(lines[l]) then
        empty[#empty + 1] = l
      end
    end
    -- the first "}}}" at or after a position, for positions that go up
    local last_from, last_at = math.huge, nil ---@type integer, integer?
    local function find_close(from)
      if not (from >= last_from and (last_at == nil or from <= last_at)) then
        last_from, last_at = from, s:find("}}}", from, true)
      end
      return last_at
    end
    local ei = 1
    local i = 1
    while true do
      local p = s:find("{{{", i, true)
      if not p then
        break
      end
      local ne = s:match("^{{{%a[-%w_]*()", p)
      if not ne then
        i = p + 1
      else
        local c = find_close(ne)
        -- (the line break before the next empty line)
        while empty[ei] and starts[empty[ei]] - 1 < ne do
          ei = ei + 1
        end
        local blank = empty[ei] and starts[empty[ei]] - 1
        if c and not (blank and blank < c) then
          span(p, c + 2, { hl_group = "orgMacro", priority = P.macro, spell = false })
          for _, m in ipairs({ p, c }) do
            span(
              m,
              m + 2,
              { hl_group = "orgMacroMarker", priority = P.macro, spell = false, conceal = hide and "" or nil }
            )
          end
          i = c + 3
        else
          i = ne
        end
      end
    end
  end

  -- export snippets: @@backend:value@@ on one line
  if s:find("@@", 1, true) then
    local i = 1
    while true do
      local p = s:find("@@", i, true)
      if not p then
        break
      end
      local q = s:match("^@@[a-z-]+:()", p)
      local c = q and s:find("@@", q, true)
      if c and not s:sub(q, c - 1):find("\n", 1, true) then
        span(p, c + 1, { priority = P.snippet, spell = false })
        span(p, p + 1, { hl_group = "orgExportSnippetMarker", priority = P.snippet })
        span(p + 2, q - 1, { hl_group = "orgExportSnippetBackend", priority = P.snippet })
        span(c, c + 1, { hl_group = "orgExportSnippetMarker", priority = P.snippet })
        i = c + 2
      else
        i = p + 1
      end
    end
  end

  -- line breaks: \\ at the end of a line (no face in Emacs; the syntax
  -- engine's orgLineBreak)
  for l = math.max(1, ctx.first - ctx.row0 + 1), math.min(#lines, ctx.last - ctx.row0 + 1) do
    local line, k = lines[l], kinds[l]
    if k == "text" or k == "qcomment" then
      -- ("\\\\[ \t]*$", read back from the end of the line)
      local e = #line
      local b = byte(line, e)
      while b == 32 or b == 9 do
        e = e - 1
        b = byte(line, e)
      end
      if b == 92 and byte(line, e - 1) == 92 then
        ctx.emit(l, e - 2, #line, { hl_group = "orgLineBreak", priority = P.link, spell = false })
      end
    end
  end

  -- inline src blocks last (they come after the meta lines: drawn on every
  -- line)
  for _, r in ipairs(inline) do
    span(r[1], r[2], { hl_group = r[3], priority = P.inline_src, spell = false }, true, true)
  end
end

return M

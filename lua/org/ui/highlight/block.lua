---@mod org.ui.highlight.block Blocks and LaTeX
---
--- Part of org.ui.highlight (the parser highlighter): block delimiter lines, the bodies of example, export, comment, quote and verse blocks (src block bodies: org.ui.src_highlight and the included syntaxes), dynamic blocks, and LaTeX fragments and environments (`ui.highlight_latex_and_related`).
---
--- Blocks are a port of org-fontify-meta-lines-and-blocks-1: a
--- `#+begin_NAME` line opens a block when a `#+end_NAME` line or a
--- headline follows (org.ui.emphasis `kinds` finds them); its begin and end
--- lines are drawn whole in orgBlockDelimiter (org-block-begin-line,
--- org-block-end-line), never spell checked. The body of a src, export or
--- example block (org-protecting-blocks) is org-block under the faces of
--- its language: when an included syntax or tree-sitter draws the language
--- (org.syntax `orgSrcBlock_*` regions, org.ui.src_highlight), its colours
--- are left alone and the body gets orgSrcBlock, a group without
--- attributes (one can be given to it); otherwise it is orgBlock. None of
--- it is spell checked but what an included syntax checks (its comments). Quote and verse bodies
--- are Org text, on orgQuoteBlock / orgVerseBlock with
--- `ui.fontify_quote_and_verse_blocks` (org-fontify-quote-and-verse-blocks:
--- every byte of the body, under the faces of its text, even the lines
--- of a block or a keyword in it, which font-lock skips). Comment, center and special
--- blocks draw only their delimiters (their body is Org text to Emacs's
--- font-lock: it isn't a protecting block), and dynamic blocks nothing
--- here: `#+BEGIN:` and `#+END:` are keyword lines (org-meta-line, the
--- meta part). The value of a `#+CAPTION:` is org-block.
---
--- LaTeX is a port of org-do-latex-and-related: fragments (`$x$`, `$...$`,
--- `$$...$$`, `\(...\)`, `\[...\]`) and environments (`\begin{x}` at the
--- start of a line up to `\end{x}`) in orgLatex, entities (`\alpha`) in
--- orgLatexEntity and sub/superscripts (`ui.use_sub_superscripts`, a
--- buffer's `#+OPTIONS: ^:`) in orgLatexScript, found left to right the
--- way Emacs's combined regexp finds them, none spell checked. `\(`, `\[`
--- and `$$` fragments don't go over an empty line (org-do-latex-and-related)
--- and nothing goes over a headline. With "native", what is found (entities
--- and scripts too, as in Emacs) is drawn by Vim's tex syntax over
--- orgSrcBlock instead (org.ui.highlight.native).

-- Not compiled by the JIT, like org.ui.highlight (see the comment there).
if jit then
  jit.off(true, true)
end

local M = {}

local E = require("org.ui.emphasis")
local H = require("org.ui.highlight")

local byte, find = string.byte, string.find

--- How far up the begin line of a block open before the lines drawn is
--- looked for (as far as org.ui.highlight `window` looks for the block).
local BLOCK_LOOK = 3000
--- How far up the begin line of a LaTeX environment open before the lines
--- drawn is looked for, and down its end.
local LOOK = 1000
--- The priority of the tex groups of a fragment drawn natively: over
--- emphasis (101 and up), whose faces Emacs takes off it.
local TEX_PRIO = 120

--- The groups of org-code, org-verbatim, underline and org-special-keyword
--- (see `protected` in `paint_latex`).
local PROTECTED = {
  orgVerbatim = true,
  orgVerbatimDelimiter = true,
  orgCode = true,
  orgCodeDelimiter = true,
  orgUnderline = true,
  orgUnderlineDelimiter = true,
  orgPropertyKey = true,
  orgPlanning = true,
  orgClock = true,
  orgHeadlineComment = true,
}

-- Blocks --------------------------------------------------------------------

--- Per Vim syntax and runtimepath / engine: how src bodies of it are drawn
--- ("treesitter", "syntax" or false), as org.syntax `drawn_by` decides.
local drawn_cache = {} ---@type table<string, string|false>
local drawn_key ---@type string?

local function has_syntax(name)
  return #vim.api.nvim_get_runtime_file("syntax/" .. name .. ".vim", false) > 0
    or #vim.api.nvim_get_runtime_file("syntax/" .. name .. ".lua", false) > 0
end

--- How the body of a src or export block of `lang` is drawn by another
--- highlighter: "treesitter" (org.ui.src_highlight), "syntax" (the
--- language's syntax included by org.syntax) or false (not at all: it is
--- orgBlock).
---@param lang string
---@return string|false
local function drawn_by(lang)
  local ts = require("org.ui.src_highlight")
  local engine = ts.engine()
  if not engine then
    return false
  end
  local key = vim.o.runtimepath .. "\0" .. tostring(engine)
  if key ~= drawn_key then
    drawn_key, drawn_cache = key, {}
  end
  local syn = require("org.syntax").syntax_of(lang)
  local v = drawn_cache[syn]
  if v == nil then
    v = false
    if engine ~= "syntax" and ts.ts_lang_of_syntax(syn) then
      v = "treesitter"
    elseif
      engine ~= "treesitter"
      and syn ~= ""
      and syn:lower() ~= "org"
      and syn:match("^[%w_]+$")
      and has_syntax(syn)
    then
      v = "syntax"
    end
    drawn_cache[syn] = v
  end
  return v
end
M._drawn_by = drawn_by

--- The language of a `#+begin_src LANG` or `#+begin_export LANG` line
--- (ending at a blank, as the org.syntax regions take it).
---@param line string
---@return string?
local function language(line)
  local kind, lang = line:match("^[ \t]*#%+[bB][eE][gG][iI][nN]_(%a+)[ \t]+([^ \t]+)")
  if kind and (kind:lower() == "src" or kind:lower() == "export") then
    return lang
  end
end

--- `#+CAPTION:` or `#+CAPTION[short]:` and the blanks after it: the byte
--- the value starts at (org-block in Emacs), or nil.
---@param line string
---@return integer?
local function caption_value(line)
  local s = line:match("^[ \t]*()#%+")
  if not s or not line:sub(s + 2, s + 8):lower():find("^caption") then
    return nil
  end
  local p = s + 9
  local c = byte(line, p)
  if c == 91 then -- "[": up to the last "]:" (a greedy ".*")
    local last
    local from = p
    while true do
      local e = find(line, "]:", from, true)
      if not e then
        break
      end
      last, from = e, e + 1
    end
    if not last then
      return nil
    end
    p = last + 1
  elseif c ~= 58 then
    return nil
  end
  return line:match("^[ \t]*()", p + 1)
end

---@param ctx org.ui.highlight.Ctx
local function paint_blocks(ctx)
  local lines, roles, emit = ctx.lines, ctx.roles, ctx.emit
  local element = H.PRIO.element
  local delimiter = { hl_group = "orgBlockDelimiter", priority = element, spell = false }
  local verbatim = { hl_group = "orgBlock", priority = element, spell = false }
  -- (no attributes: org-block under the faces of the language)
  local native = { hl_group = "orgSrcBlock", priority = element }
  local native_nospell = { hl_group = "orgSrcBlock", priority = element, spell = false }
  -- (org-fontify-quote-and-verse-blocks: nil by default, like Emacs)
  local quote_verse = ctx.ui.fontify_quote_and_verse_blocks
      and {
        quote = { hl_group = "orgQuoteBlock", priority = element },
        verse = { hl_group = "orgVerseBlock", priority = element },
      }
    or {}
  -- (spell checked, as by Emacs's flyspell, but its links: see
  -- org.ui.highlight.object)
  local caption = { hl_group = "orgBlock", priority = element }
  -- a keyword or block line in the body of a quote, verse, center or
  -- special block: Org text to font-lock, but a keyword or a block to
  -- org-element, not spell checked
  local meta_nospell = { priority = element, spell = false }
  -- how each verbatim block's body is drawn (by its begin line)
  local how = {} ---@type table<org.ui.emphasis.Block, string|false>
  local function body_of(block, i)
    local v = how[block]
    if v ~= nil then
      return v
    end
    v = false
    if block.name == "src" or block.name == "export" then
      -- the begin line: above, in the lines or before them
      local begin
      for j = i - 1, 1, -1 do
        local r = roles[j]
        if not r or r.block ~= block then
          break
        end
        if r.role == "begin" then
          begin = lines[j]
          break
        end
      end
      if not begin and block.line then
        -- (the block open before the lines: org.ui.highlight `window` found
        -- its begin line, which a line like it in the body above the lines
        -- isn't)
        begin = block.line
      end
      if not begin and roles[1] and roles[1].block == block and roles[1].role ~= "begin" then
        local above = ctx.get_lines(ctx.row0 - BLOCK_LOOK, ctx.row0)
        for j = #above, 1, -1 do
          local name, begins = E.block_line(above[j])
          if name == block.name and begins then
            begin = above[j]
            break
          end
        end
      end
      local lang = begin and language(begin)
      if lang then
        v = drawn_by(lang) or drawn_by(lang:lower())
      end
    end
    how[block] = v
    return v
  end
  -- The bodies of the src, example and export blocks in a quote, verse,
  -- center or special block (in the lines), per outer block: line -> true.
  -- Org text to font-lock, but blocks to org-element, which flyspell
  -- doesn't check (org-mode-flyspell-verify); a src block whose language
  -- is drawn is left to its syntax.
  local inner = {} ---@type table<org.ui.emphasis.Block, table<integer, true>>
  local function inner_of(block, i)
    local v = inner[block]
    if v then
      return v
    end
    v = {}
    inner[block] = v
    local j = i
    while j > 1 and roles[j - 1] and roles[j - 1].block == block do
      j = j - 1
    end
    while j <= #lines and roles[j] and roles[j].block == block do
      local name, begins = nil, nil
      if roles[j].role == "body" then
        name, begins = E.block_line(lines[j])
      end
      local lang = name == "src" and language(lines[j])
      if
        begins
        and (name == "example" or name == "export" or name == "src")
        and not (lang and (drawn_by(lang) or drawn_by(lang:lower())))
      then
        local k = j + 1
        while k <= #lines and roles[k] and roles[k].block == block and roles[k].role == "body" do
          local n2, b2 = E.block_line(lines[k])
          if n2 == name and not b2 then
            break
          end
          k = k + 1
        end
        if k <= #lines and roles[k] and roles[k].block == block and roles[k].role == "body" then
          for x = j + 1, k - 1 do
            v[x] = true
          end
          j = k
        end
      end
      j = j + 1
    end
    return v
  end
  -- (the rows drawn only: nothing is carried from one line to the next)
  for i = math.max(1, ctx.first - ctx.row0 + 1), math.min(#lines, ctx.last - ctx.row0 + 1) do
    local line = lines[i]
    local r = roles[i]
    if r then
      local n = #line
      if r.role ~= "body" then
        emit(i, 0, n, delimiter)
      elseif n > 0 then
        local block = r.block
        if block.verbatim then
          local v = body_of(block, i)
          if not v then
            emit(i, 0, n, verbatim)
          elseif v == "treesitter" then
            -- (the orgSrcBlock_ region of org.syntax keeps it out of spell
            -- checking too)
            emit(i, 0, n, native_nospell)
          else
            -- (spelling: as the included syntax says)
            emit(i, 0, n, native)
          end
        else
          local q = quote_verse[block.name]
          if q then
            -- (but on the braces and body of an inline src block, whose
            -- faces org-fontify-inline-src-blocks removes)
            local cancel = find(line, "src_", 1, true) and E.inline_src(line) or {}
            local from = 0
            for x = 1, n + 1 do
              if x > n or cancel[x] then
                if x - 1 > from then
                  emit(i, from, x - 1, q)
                end
                from = x
              end
            end
          end
          if block.name ~= "comment" and (line:find("^[ \t]*#%+%S") or inner_of(block, i)[i]) then
            emit(i, 0, n, meta_nospell)
          end
        end
      end
    else
      local v = caption_value(line)
      if v and v <= #line then
        emit(i, v - 1, #line, caption)
      end
    end
  end
end

-- LaTeX ---------------------------------------------------------------------

---@param c? integer
local function blank(c)
  return c == 32 or c == 9
end

--- A letter ([[:alpha:]]: bytes of non-ASCII characters count as letters).
---@param c? integer
local function alpha(c)
  return c ~= nil and ((c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c >= 128)
end

---@param c? integer
local function alnum(c)
  return c ~= nil and (alpha(c) or (c >= 48 and c <= 57))
end

--- The ASCII bytes that are punctuation, brackets or a string quote in
--- Org's syntax table (`\s.`, `\s(`, `\s)`, `\s"`), and "'": `% & * + - /
--- = \ _ | ~` are symbol or word constituents there, and `$` a word one.
local AFTER_DOLLAR = {}
for c in ([[!#,.:;?@^`()<>[]{}"']]):gmatch(".") do
  AFTER_DOLLAR[c:byte()] = true
end

--- What may follow the closing `$` of an inline fragment: punctuation, a
--- blank, a bracket or a quote, or the end of the line (in Org's syntax
--- table: "$x$*" is no fragment).
---@param c? integer
local function after_dollar(c)
  return c == nil or c == 10 or blank(c) or AFTER_DOLLAR[c] == true
end

--- Bytes that can't start an inline `$` fragment's text ([^ \t\n,;.$]).
---@param c? integer
local function bad_first(c)
  return c == nil or c == 10 or blank(c) or c == 44 or c == 59 or c == 46 or c == 36
end

--- The body of a sub/superscript at byte `p` of `s`, after its `_` or `^`
--- (org-match-substring-regexp): braces or parentheses nested up to three
--- deep (on one line), `*`, or an optional sign and letters, digits, `.`,
--- `,` and `\` ending with a letter or digit; with `braces` only braces.
--- The byte after it, or nil.
---@param s string
---@param p integer
---@param braces boolean
---@return integer?
local function script_body(s, p, braces)
  local c = byte(s, p)
  if c == 123 or (c == 40 and not braces) then
    local close = c == 123 and 125 or 41
    local depth = 0
    for k = p, #s do
      local b = byte(s, k)
      if b == 10 then
        return nil
      elseif b == c then
        depth = depth + 1
        if depth > 3 then
          return nil
        end
      elseif b == close then
        depth = depth - 1
        if depth == 0 then
          return k + 1
        end
      end
    end
    return nil
  end
  if braces then
    return nil
  end
  if c == 42 then
    return p + 1
  end
  local k = p
  if c == 43 or c == 45 then
    k = k + 1
  end
  local last
  while true do
    local b = byte(s, k)
    if alnum(b) then
      last = k
    elseif b ~= 46 and b ~= 44 and b ~= 92 then
      break
    end
    k = k + 1
  end
  return last and last + 1
end

--- An entity at the backslash at byte `t` of `s`: `\there4`, `\sup1`..3,
--- `\frac12` and the like or `\` and letters, followed by the end of the
--- line, `{}` or anything but a letter, which it takes (unless a blank, the
--- way Emacs leaves trailing blanks out). The byte after it, or nil.
---@param s string
---@param t integer
---@return integer?
local function entity(s, t)
  local e
  for _, special in ipairs({ "there4", "sup[123]", "frac[13][24]" }) do
    local m = s:match("^" .. special .. "()", t + 1)
    if m and not alpha(byte(s, m)) then
      e = m
      break
    end
  end
  if not e then
    local m = s:match("^%a+()", t + 1)
    if not m or alpha(byte(s, m)) then
      return nil
    end
    e = m
  end
  local b = byte(s, e)
  if b == 123 and byte(s, e + 1) == 125 then
    return e + 2
  elseif b and b ~= 10 and not blank(b) then
    return e + 1
  end
  return e
end

---@class org.ui.highlight.block.Latex
---@field fragments boolean "latex" or "native"
---@field native boolean "native": what is found is drawn by the tex syntax
---@field entities boolean
---@field scripts boolean|string false, true or "{}"

--- What LaTeX the buffer highlights (`ui.highlight_latex_and_related`,
--- org-compute-latex-and-related-regexp), or nil for nothing.
---@param ui table
---@return org.ui.highlight.block.Latex?
local function latex_options(ui)
  local list = ui.highlight_latex_and_related
  if type(list) ~= "table" or #list == 0 then
    return nil
  end
  local set = {}
  for _, v in ipairs(list) do
    set[v] = true
  end
  local scripts = false ---@type boolean|string
  if set.script and ui.use_sub_superscripts ~= false then
    scripts = ui.use_sub_superscripts == "{}" and "{}" or true
  end
  local fragments = (set.latex or set.native) == true
  if not (fragments or set.entities or scripts) then
    return nil
  end
  return { fragments = fragments, native = set.native == true, entities = set.entities == true, scripts = scripts }
end

--- The name of the environment a line begins (`\begin{NAME}` after
--- blanks), and the byte after its `}`.
---@param line string
---@return string?, integer?
local function env_begin(line)
  return line:match("^[ \t]*\\begin{([%w*]+)}()")
end

--- The kinds of lines LaTeX is looked for in: Org text, tables and the
--- comments of quote blocks; not keywords, comments, fixed-width lines,
--- the info keywords and block delimiters (Emacs draws its own face over
--- them), nor the bodies of src, example and export blocks.
local SCANNED = { text = true, table = true, qcomment = true }

---@param ctx org.ui.highlight.Ctx
---@param o org.ui.highlight.block.Latex
local function paint_latex(ctx, o)
  local lines, kinds, roles = ctx.lines, ctx.kinds, ctx.roles
  local n = #lines
  local s = table.concat(lines, "\n")
  -- (lines without a backslash can still be in an environment open above
  -- them that ends below them)
  if
    not (find(s, "\\", 1, true) or (o.fragments and find(s, "$", 1, true)) or (o.scripts and find(s, "[_^]")))
    and not (o.fragments and ctx.row0 > ctx.top)
  then
    return
  end
  local starts = {} ---@type integer[]
  local scanned = {} ---@type boolean[]
  local star = {} ---@type boolean[]
  local pos = 1
  for i, line in ipairs(lines) do
    starts[i] = pos
    pos = pos + #line + 1
    local r = roles[i]
    scanned[i] = SCANNED[kinds[i]] == true and not (r and r.role ~= "body")
    star[i] = E.star_line(line)
  end
  starts[n + 1] = #s + 2
  -- Per line: where an inline fragment that starts on it has to end (the
  -- start of the next empty, headline or unscanned line), and where an
  -- environment (the next headline).
  local inline_stop, env_stop = {}, {} ---@type integer[], integer[]
  local istop, estop = #s + 1, #s + 1
  for i = n, 1, -1 do
    inline_stop[i], env_stop[i] = istop, estop
    if star[i] or not scanned[i] or not find(lines[i], "%S") then
      istop = starts[i]
    end
    if star[i] then
      estop = starts[i]
    end
  end
  --- The line of byte `p` (a binary search).
  local function line_at(p)
    local lo, hi = 1, n
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if starts[mid] <= p then
        lo = mid
      else
        hi = mid - 1
      end
    end
    return lo
  end

  local prio = H.PRIO.object
  local LATEX = { hl_group = "orgLatex", priority = prio, spell = false }
  local ENTITY = { hl_group = "orgLatexEntity", priority = prio, spell = false }
  local SCRIPT = { hl_group = "orgLatexScript", priority = prio, spell = false }
  -- (marks come in the order of the text)
  local li = 1
  --- Mark bytes [a, b) of `s`, on the scanned lines.
  local function mark(a, b, opts)
    while starts[li + 1] <= a do
      li = li + 1
    end
    local l = li
    while l <= n and starts[l] < b do
      if scanned[l] then
        local ls = starts[l]
        ctx.emit(l, math.max(a, ls) - ls, math.min(b, ls + #lines[l]) - ls, opts)
      end
      l = l + 1
    end
  end

  -- "native": the text found drawn by Vim's tex syntax
  -- (org-src-font-lock-fontify-block "latex"), over org-block (orgSrcBlock,
  -- like the body of a src block a syntax draws), or org-block alone when
  -- there is no tex syntax (no latex-mode)
  local N = o.native and require("org.ui.highlight.native") or nil
  local tex = N and N.available()
  local BASE = { hl_group = tex and "orgSrcBlock" or "orgBlock", priority = prio, spell = false }
  local groups = {} ---@type table<string, org.ui.highlight.MarkOpts>
  if N then
    N.watch(ctx.bufnr)
  end
  --- Draw bytes [a, b) of `s` natively. `pre`: the lines of the text above
  --- the lines (an environment open before them), each ending with "\n";
  --- `post`: the text below them (an environment that ends past them).
  local function native(a, b, pre, post)
    mark(a, b, BASE)
    if not tex then
      return
    end
    local fl = line_at(a)
    local ll = line_at(math.max(a, b - 1))
    local pre_rows = pre and select(2, pre:gsub("\n", "")) or 0
    local text = (pre or "") .. s:sub(a, math.min(b - 1, #s)) .. (post or "")
    -- (the row of the text's first line, and the column it starts at)
    local fs = ctx.row0 + fl - 1 - pre_rows
    local c0 = pre and 0 or a - starts[fl]
    local r0 = math.max(ctx.first, ctx.row0 + fl - 1) - fs
    local r1 = math.min(ctx.last, ctx.row0 + ll - 1) - fs
    if r1 < r0 then
      return
    end
    local rows = assert(N).spans(ctx.bufnr, text, r0, r1)
    for r = r0, r1 do
      local i = fs + r - ctx.row0 + 1
      local spans = rows[r]
      if spans and scanned[i] then
        local off = r == 0 and c0 or 0
        for _, sp in ipairs(spans) do
          local g = groups[sp[3]]
          if not g then
            g = { hl_group = sp[3], priority = TEX_PRIO, spell = false }
            groups[sp[3]] = g
          end
          ctx.emit(i, sp[1] + off, sp[2] + off, g)
        end
      end
    end
  end
  --- Whether byte `q` of `s` is drawn in verbatim, code, underline or
  --- org-special-keyword: Emacs leaves a match alone when the byte after
  --- its start has one of those faces (org-do-latex-and-related).
  --- (per line, the spans of those marks, sorted, found at the first
  --- question: they were drawn before this part)
  local spans_of = {} ---@type table<integer, { [1]: integer, [2]: integer }[]>
  local function protected(q)
    local l = line_at(q)
    local col = q - starts[l]
    local sp = spans_of[l]
    if not sp then
      sp = {}
      for _, m in ipairs(ctx.marks and ctx.marks(l) or {}) do
        if PROTECTED[m[2].hl_group or ""] then
          sp[#sp + 1] = { m[1], m[2].end_col or m[1] + 1 }
        end
      end
      table.sort(sp, function(x, y)
        return x[1] < y[1]
      end)
      -- (merged: a marker and the text next to it are two marks)
      local merged = {} ---@type { [1]: integer, [2]: integer }[]
      for _, x in ipairs(sp) do
        local last = merged[#merged]
        if last and x[1] <= last[2] then
          last[2] = math.max(last[2], x[2])
        else
          merged[#merged + 1] = { x[1], x[2] }
        end
      end
      sp = merged
      spans_of[l] = sp
    end
    -- (the last span starting at or before `col`)
    local lo, hi = 1, #sp
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      if sp[mid][1] <= col then
        lo = mid + 1
      else
        hi = mid - 1
      end
    end
    return hi >= 1 and col < sp[hi][2]
  end
  --- Draw bytes [a, b) of `s` found as `opts`, unless byte `q` is
  --- `protected`.
  local function draw(a, b, opts, pre, post, q)
    if q and protected(q) then
      return
    end
    if N then
      native(a, b, pre, post)
    else
      mark(a, b, opts)
    end
  end

  -- The next match of a plain string at or after a byte, kept while the
  -- bytes asked for grow: the scan stays linear however many openers find
  -- no closer.
  local memo = {} ---@type table<string, integer|false>
  local function next_of(needle, from)
    local m = memo[needle]
    if m == nil or (m and m < from) then
      m = find(s, needle, from, true) or false
      memo[needle] = m
    end
    return m or nil
  end

  -- Whether `\end{NAME}` follows the lines before a headline (in the
  -- buffer, LOOK lines at most).
  local below = {} ---@type table<string, boolean>
  local function closed_below(name)
    local v = below[name]
    if v ~= nil then
      return v
    end
    v = false
    local needle = "\\end{" .. name .. "}"
    local row = ctx.row0 + n
    local stop = math.min(ctx.bottom, row + LOOK)
    while row < stop do
      local chunk = ctx.get_lines(row, math.min(stop, row + 256))
      local found = nil ---@type boolean?
      for _, line in ipairs(chunk) do
        if E.star_line(line) then
          found = false
          break
        elseif find(line, needle, 1, true) then
          found = true
          break
        end
      end
      if found ~= nil then
        v = found
        break
      end
      row = row + #chunk
    end
    below[name] = v
    return v
  end
  --- The text of environment NAME below the lines, up to its `\end{NAME}`
  --- (closed there: `closed_below`), each line after a "\n".
  local function text_below(name)
    local needle = "\\end{" .. name .. "}"
    local row = ctx.row0 + n
    local stop = math.min(ctx.bottom, row + LOOK)
    local out = {} ---@type string[]
    while row < stop do
      for _, line in ipairs(ctx.get_lines(row, math.min(stop, row + 256))) do
        local e = find(line, needle, 1, true)
        out[#out + 1] = e and line:sub(1, e + #needle - 1) or line
        if e then
          return "\n" .. table.concat(out, "\n")
        end
      end
      row = row + 256
    end
    return "\n" .. table.concat(out, "\n")
  end
  --- The end of the environment NAME whose `\begin{NAME}` ends before byte
  --- `from`, when it closes before byte `stop` (or below the lines): the
  --- byte after its `\end{NAME}` and the blanks after it, which the match
  --- takes (`[ \t]*\n?`), and the byte it is drawn to: the blanks are
  --- left out but before the end of the line (Emacs skips back over the
  --- blanks only, and the match took the newline).
  ---@return integer?, integer?
  local function env_end(name, from, stop)
    local needle = "\\end{" .. name .. "}"
    local e = find(s, needle, from + 1, true)
    if e and e + #needle <= stop then
      local d = e + #needle
      e = d
      while blank(byte(s, e)) do
        e = e + 1
      end
      -- (past the lines: the next line follows, whose newline it takes)
      return e, (e > #s or byte(s, e) == 10) and e or d
    end
    if stop > #s and closed_below(name) then
      return #s + 1, #s + 1
    end
  end

  local p = 1
  -- An environment open before the lines: its begin line is above them,
  -- after the headline above.
  if o.fragments and ctx.row0 > ctx.top and not star[1] then
    -- (the lines after the headline above: read up to it only)
    local h = ctx.star_above(ctx.row0, LOOK)
    local above = ctx.get_lines(h and h + 1 or ctx.row0 - LOOK, ctx.row0)
    local open ---@type string?
    local from ---@type integer?
    for k = #above, 1, -1 do
      local line = above[k]
      local name, after = env_begin(line)
      if name then
        open, from = name, k
        -- (whether it is closed before the lines)
        if find(line, "\\end{" .. name .. "}", after, true) then
          open = nil
        else
          for j = k + 1, #above do
            if find(above[j], "\\end{" .. name .. "}", 1, true) then
              open = nil
              break
            end
          end
        end
        break
      end
    end
    if open then
      local e, d = env_end(open, 0, env_stop[1])
      if e and d then
        local pre = N and table.concat(above, "\n", from) .. "\n" or nil
        draw(1, d, LATEX, pre, N and e > #s and text_below(open) or nil)
        p = e
      end
    end
  end

  local trigger = o.fragments and "[%$\\_%^]" or o.scripts and "[\\_%^]" or "\\"
  while true do
    local t = find(s, trigger, p)
    if not t then
      break
    end
    local l = line_at(t)
    if not scanned[l] then
      p = starts[l + 1]
    else
      local c = byte(s, t)
      local stop = inline_stop[l]
      local done ---@type integer?
      -- Emacs's combined regexp: the match that starts first, and of those
      -- the first of latex, entities, scripts
      if c == 94 or c == 95 then
        -- a script after the byte before (org-match-substring-regexp)
        local b = byte(s, t - 1)
        if o.scripts and t > p and b and b ~= 10 and not blank(b) then
          done = script_body(s, t + 1, o.scripts == "{}")
          if done then
            draw(t, done, SCRIPT, nil, nil, t)
          end
        end
      elseif c == 36 then
        -- $x$ and $...$ (from the byte before, or the start of a line)
        local b = t > 1 and byte(s, t - 1) or nil
        local c2 = byte(s, t + 1)
        if o.fragments and b ~= 36 and (t > p or b == nil or b == 10) and not bad_first(c2) then
          if byte(s, t + 2) == 36 then
            if after_dollar(byte(s, t + 3)) then
              done = t + 3
            end
          else
            local e = next_of("$", t + 1)
            local last = e and byte(s, e - 1)
            if
              e
              and e < stop
              and (last == 59 or not bad_first(last))
              and after_dollar(byte(s, e + 1))
              and line_at(e) - l <= 2
            then
              done = e + 1
            end
          end
          if done then
            -- (the match takes the byte before, and the punctuation,
            -- bracket or quote after: org-latex-regexps; a blank after is
            -- left out with the trailing blanks)
            local f = byte(s, done)
            if f and f ~= 10 and not blank(f) then
              done = done + 1
            end
            draw((b and b ~= 10) and t - 1 or t, done, LATEX, nil, nil, t)
          end
        end
        if not done and o.fragments and c2 == 36 then
          local e = next_of("$$", t + 2)
          if e and e + 2 <= stop then
            done = e + 2
            draw(t, done, LATEX, nil, nil, t + 1)
          end
        end
      else
        local c2 = byte(s, t + 1)
        local ls = starts[l]
        if o.fragments and c2 == 98 and ls >= p then
          -- \begin{NAME} at the start of the line, from the line's start
          local name, after = env_begin(lines[l])
          if name and ls + #lines[l]:match("^[ \t]*") == t then
            local d
            done, d = env_end(name, ls + after - 1, env_stop[l])
            if done and d then
              draw(ls, d, LATEX, nil, N and done > #s and text_below(name) or nil, ls + 1)
            end
          end
        end
        if not done and o.fragments and (c2 == 40 or c2 == 91) then
          local e = next_of(c2 == 40 and "\\)" or "\\]", t + 2)
          if e and e + 2 <= stop then
            done = e + 2
            draw(t, done, LATEX, nil, nil, t + 1)
          end
        end
        if not done and o.entities and c2 and c2 < 128 and alpha(c2) then
          done = entity(s, t)
          if done then
            draw(t, done, ENTITY, nil, nil, t + 1)
          end
        end
      end
      if not done and o.scripts and c ~= 94 and c ~= 95 then
        -- a script after this byte
        local c2 = byte(s, t + 1)
        if c2 == 94 or c2 == 95 then
          done = script_body(s, t + 2, o.scripts == "{}")
          if done then
            draw(t + 1, done, SCRIPT, nil, nil, t + 1)
          end
        end
      end
      p = done or t + 1
    end
  end
end

--- Paint the rows of `ctx` (see org.ui.highlight `Ctx`).
---@param ctx org.ui.highlight.Ctx
function M.paint(ctx)
  paint_blocks(ctx)
  local o = latex_options(ctx.ui)
  if o then
    paint_latex(ctx, o)
  end
end

return M
